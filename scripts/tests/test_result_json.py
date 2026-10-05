"""Check the Python result layout without changing JSON values."""

import json
import hashlib
import os
import io
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from result_json import format_result_json, write_result_json


class ResultJsonTests(unittest.TestCase):
    def make_overview_fixture(self, root):
        scripts = Path(__file__).resolve().parents[1]
        (root / "scripts").mkdir()
        (root / "results").mkdir()
        for name in ("results-overview.ps1", "result-format.ps1"):
            shutil.copyfile(scripts / name, root / "scripts" / name)
        (root / "scripts/verification-source-identity.ps1").write_text(
            "function Get-VerificationSourceIdentity { @{source_commit='abcdef012345'; verification_input_fingerprint='0123456789abcdef'} }\n"
            "function Get-DocumentationInputIdentity { @{documentation_input_fingerprint='docs'} }\n")

    def run_overview(self, root):
        # A Python child of pwsh otherwise forwards PowerShell 7's module path to 5.1.
        environment = {k: v for k, v in os.environ.items() if k.upper() != "PSMODULEPATH"}
        result = subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
             str(root / "scripts/results-overview.ps1")], cwd=root,
            capture_output=True, text=True, timeout=30, env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads((root / "results/overview.json").read_text(encoding="utf-8-sig"))

    def test_multiple_subtest_failures_do_not_distort_pass_count(self):
        from python_tests import CountingResult

        class Broken(unittest.TestCase):
            def runTest(self):
                for value in (1, 2):
                    with self.subTest(value=value):
                        self.assertEqual(value, 0)

        class Good(unittest.TestCase):
            def runTest(self):
                self.assertTrue(True)

        result = unittest.TextTestRunner(stream=io.StringIO(), resultclass=CountingResult).run(
            unittest.TestSuite([Broken(), Good()]))
        self.assertEqual(result.testsRun, 2)
        self.assertEqual(len(result.failures), 2)
        self.assertEqual(result.passed, 1)
        self.assertFalse(result.wasSuccessful())

    def test_roundtrip(self):
        sample = {"text": '"quote" C:\\path [1,  2] colon:  space',
                  "unicode": "\u6e2c\u8a66", "values": [1, -2.5, True, False, None],
                  "empty": [], "single": ["only"], "objects": [{"a": 1}]}
        self.assertEqual(json.loads(format_result_json(sample)), sample)

    def test_short_arrays(self):
        text = format_result_json({"args": ["-g2012", "-Wall"], "empty": []})
        self.assertIn('"args": ["-g2012", "-Wall"]', text)
        self.assertIn('"empty": []', text)
        self.assertNotIn("\r", text)

    def test_large_arrays_and_objects(self):
        text = format_result_json({"objects": [{"a": 1}], "long": ["a" * 100, "b" * 100]})
        self.assertIn('"objects": [\n    {', text)
        self.assertIn('"long": [\n', text)

    def test_root_values(self):
        for value in ([], [1], None, "test", 123):
            self.assertEqual(json.loads(format_result_json(value)), value)

    def test_long_numeric_arrays_are_wrapped_without_changing_values(self):
        sample = {"nested": {"histogram": list(range(64))}, "wide": [12345678901234567890] * 12}
        text = format_result_json(sample)
        self.assertEqual(json.loads(text), sample)
        self.assertIn("      0, 1, 2, 3, 4, 5, 6, 7,\n", text)
        self.assertTrue(all(len(line) <= 120 for line in text.splitlines()))
        self.assertEqual(format_result_json(json.loads(text)), text)

    def test_write_and_reject_nan(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "nested/result.json"
            write_result_json({"x": [1, 2]}, path)
            self.assertEqual(path.read_bytes(), b'{\n  "x": [1, 2]\n}\n')
        with self.assertRaises(ValueError):
            format_result_json({"x": float("nan")})

    def test_overview_separates_source_freshness_and_capture_integrity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_overview_fixture(root)
            data = root / "results/signal-console"
            data.mkdir(parents=True)
            source = root / "scripts/signal_viewer.py"
            source.write_text("original\n")
            capture = data / "viewer.csv"
            capture.write_text("sample,input,output\n0,0,0\n")
            record = {"status": "captured", "saved_samples": 1, "captured_at_utc": "fixture",
                      "source_hashes": {"signal_viewer.py": hashlib.sha256(source.read_bytes()).hexdigest()},
                      "files": {"viewer.csv": hashlib.sha256(capture.read_bytes()).hexdigest()}}
            write_result_json(record, data / "viewer.json")
            matrix = root / "results/architecture/dcache-complete-external/summary.json"
            write_result_json({"status": "passed", "cases": [{"status": "passed"}],
                               "verification_input_fingerprint": "0123456789abcdef"}, matrix)
            board = root / "results/architecture/dcache-board/victim4-fir.json"
            write_result_json({"status": "passed", "test_samples_checked": 202,
                               "stress_samples_checked": 6400, "client_samples_checked": 6,
                               "stress_batches_checked": 200}, board)
            for victims in (0, 4):
                timing = {"architecture_profile": "fast_cpu", "icache_bytes": 1024,
                          "icache_parallel_lookup": 0, "dcache_victim_lines": victims,
                          "timing_period_ns": 10, "timing_status": "pass",
                          "source_commit": "abcdef012345", "reports": {"post_route_timing": {
                              "present": True, "wns_ns": 0.05, "whs_ns": 0.015}}}
                write_result_json(timing, root / f"results/timing/victim{victims}.json")

            def overview():
                index = self.run_overview(root)
                results = {row["path"]: row for row in index["verification"]}
                self.assertEqual(results["architecture/dcache-complete-external/summary.json"]["detail"], "1/1 programs")
                self.assertEqual(results["architecture/dcache-board/victim4-fir.json"]["detail"], "6608 outputs; 200 stress batches")
                self.assertEqual({row["profile"] for row in index["timing"]}, {
                    f"fast_cpu, I-cache 1024 B / lookup 0, D-cache victims {victims}" for victims in (0, 4)})
                rows = index["supporting"]
                return next(row for row in rows if row["path"] == "signal-console/viewer.json")

            row = overview()
            self.assertEqual(row["identity"], "matching build inputs")
            self.assertEqual(row["artifacts"], "hashes match")
            source.write_text("changed\n")
            self.assertEqual(overview()["identity"], "stale")
            capture.write_text("corrupt\n")
            self.assertEqual(overview()["artifacts"], "missing or changed")
            (root / "results/check-summary.json").write_text('{"status": broken')
            (root / "results/timing/broken.json").write_text("[]")
            overview()
            index = json.loads((root / "results/overview.json").read_text(encoding="utf-8-sig"))
            self.assertEqual(index["status"], "incomplete")
            self.assertEqual(len(index["errors"]), 2)
            full = next(row for row in index["verification"] if row["path"] == "check-summary.json")
            self.assertEqual(full["status"], "invalid record")
            self.assertIn("Unreadable records", (root / "results/RESULTS.md").read_text(encoding="utf-8-sig"))

    def test_overview_includes_studies_and_only_merges_identical_builds(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_overview_fixture(root)
            source = root / "rtl.v"
            source.write_text("hardware fixture\n")
            source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
            for backend, statuses, planned in (
                ("complete", ["passed", "failed"], 3),
                ("complete-external", ["passed"], 1),
            ):
                write_result_json({
                    "status": "failed" if "failed" in statuses else "passed",
                    "planned_cases": planned, "cases": [{"status": s} for s in statuses],
                    "verification_input_fingerprint": "0123456789abcdef",
                }, root / f"results/architecture/{backend}/summary.json")
            write_result_json({"status": "passed", "verification_input_fingerprint": "old"},
                              root / "results/architecture/dcache-board/victim4-fir.json")
            write_result_json({"status": "passed"}, root / "results/arch-test-results.json")
            timing = {
                "architecture_profile": "default", "top": "fixture", "timing_period_ns": 10,
                "timing_status": "pass", "source_commit": "abcdef012345",
                "source_inputs": [{"path": "rtl.v", "sha256": source_hash}],
                "generated_at_utc": "2026-10-01T00:00:00Z",
                "reports": {"post_route_timing": {"present": True, "wns_ns": 0.1, "whs_ns": 0.02}},
            }
            write_result_json(timing, root / "results/vivado-basys3-build-summary.json")
            write_result_json(timing, root / "results/timing/default-copy.json")
            write_result_json(timing, root / "results/architecture/default-implementation.json")
            # Equal configuration and timing are not sufficient to merge separate runs.
            write_result_json(dict(timing, generated_at_utc="2026-10-02T00:00:00Z"),
                              root / "results/timing/repeat.json")
            for profile in ("iterative_cpu", "fast_scratchpad", "fast_dma"):
                write_result_json(dict(timing, architecture_profile=profile),
                                  root / f"results/architecture/{profile}-implementation.json")

            index = self.run_overview(root)
            self.assertEqual(index["status"], "complete")
            rows = {row["path"]: row for row in index["verification"]}
            internal = rows["architecture/complete/summary.json"]
            self.assertEqual(internal["detail"], "1/3 programs")
            self.assertEqual(internal["status"], "failed")
            self.assertEqual(rows["architecture/complete-external/summary.json"]["detail"], "1/1 programs")
            self.assertEqual(len(index["timing"]), 5)
            canonical = next(row for row in index["timing"] if row["path"] == "vivado-basys3-build-summary.json")
            self.assertEqual(canonical["aliases"], ["timing/default-copy.json", "architecture/default-implementation.json"])
            self.assertTrue(all(row["identity"] == "matching build inputs" for row in index["timing"]))

            markdown = (root / "results/RESULTS.md").read_text(encoding="utf-8-sig")
            main, history = markdown.split("<summary>Earlier verification records", 1)
            self.assertIn("architecture/complete/summary.json", main)
            self.assertNotIn("architecture/dcache-board/victim4-fir.json", main)
            self.assertIn("architecture/dcache-board/victim4-fir.json", history)
            self.assertIn("identity unavailable", main)
            self.assertNotIn("timing/default-copy.json", markdown)
            repeated = self.run_overview(root)
            for key in ("verification", "timing", "supporting", "errors"):
                self.assertEqual(repeated[key], index[key])
            # A source change must move all physical implementations to history.
            source.write_text("changed hardware\n")
            changed = self.run_overview(root)
            self.assertTrue(all(row["identity"] == "historical" for row in changed["timing"]))
            markdown = (root / "results/RESULTS.md").read_text(encoding="utf-8-sig")
            current = markdown.split("## Current FPGA implementation", 1)[1].split("<details>", 1)[0]
            self.assertNotIn("[record]", current)


if __name__ == "__main__":
    unittest.main()
