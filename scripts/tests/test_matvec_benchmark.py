"""Oracle, activity-counter and failed-summary checks for MATVEC measurements."""

from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import matvec_benchmark as flow


class MatvecBenchmarkTests(unittest.TestCase):
    def test_known_signed_dot_product(self):
        matrix, vectors, expected = flow.workload(1, 1, "stream")
        self.assertEqual(matrix[0], flow.pack([-128, -99, -70, -41]))
        self.assertEqual(vectors[0], flow.pack([-128, -45, 38, 121]))
        self.assertEqual(expected, [13218])

    def test_all_workloads_independent_packed_oracle(self):
        def lanes(word):
            return struct.unpack("4b", struct.pack("<I", word))
        for rows in flow.ROWS:
            for jobs in flow.JOBS:
                for scenario in flow.SCENARIOS:
                    matrix, vectors, expected = flow.workload(rows, jobs, scenario)
                    calculated = []
                    for job in range(jobs):
                        for row in range(rows):
                            offset = row if scenario == "reuse" else job * rows + row
                            calculated.append(sum(a*b for a, b in zip(lanes(matrix[offset]), lanes(vectors[job]))) & 0xFFFFFFFF)
                    self.assertEqual(calculated, expected)

    def test_activity_counts_for_chunked_dma(self):
        text = "METRICS cycles=1000 retired=200 stalls=100 icache_misses=2 dcache_misses=3 busy_cycles=300 arithmetic_cycles=128 starts=16"
        self.assertEqual(flow.parse_metrics(text, "dma", 16, 4)["starts"], 16)
        for altered in (text.replace("starts=16", "starts=4"), text.replace("arithmetic_cycles=128", "arithmetic_cycles=64"),
                        text.replace("busy_cycles=300", "busy_cycles=1100"), text + "\n" + text,
                        text + " starts=16", text + " garbage", ""):
            with self.assertRaises(RuntimeError):
                flow.parse_metrics(altered, "dma", 16, 4)

    def test_software_has_no_accelerator_activity(self):
        text = "METRICS cycles=300 retired=200 stalls=90 icache_misses=2 dcache_misses=3 busy_cycles=0 arithmetic_cycles=0 starts=0"
        flow.parse_metrics(text, "software", 4, 1)
        with self.assertRaises(RuntimeError):
            flow.parse_metrics(text.replace("busy_cycles=0", "busy_cycles=1"), "software", 4, 1)

    def test_output_and_input_corruption_rejected(self):
        symbols = {"benchmark_matrix": 0x3000, "benchmark_vectors": 0x3200,
                   "benchmark_output": 0x3300, "signature": 0x3800}
        matrix, vectors, expected = flow.workload(4, 4, "stream")
        memory = bytearray(4096)
        for name, values in (("benchmark_matrix", matrix), ("benchmark_vectors", vectors),
                             ("benchmark_output", expected), ("signature", [0x600DCAFE])):
            struct.pack_into(f"<{len(values)}I", memory, symbols[name] - 0x3000, *values)
        flow.check_memory(memory, symbols, matrix, vectors, expected)
        for offset in (0, 0x200, 0x300, 0x300 + len(expected)*4, 0x800):
            corrupted = bytearray(memory)
            corrupted[offset] ^= 1
            with self.assertRaises(RuntimeError):
                flow.check_memory(corrupted, symbols, matrix, vectors, expected)

    def test_failed_run_does_not_keep_success_table(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            summary = {"status": "failed", "rows": [1], "jobs": [1], "scenarios": ["reuse"],
                       "cases": [], "error": "simulator failed"}
            (output / "RESULTS.md").write_text("old passed run")
            flow.write_summary(summary, output)
            text = (output / "RESULTS.md").read_text(encoding="utf-8")
            self.assertIn("**failed**", text)
            self.assertNotIn("old passed", text)
            self.assertEqual(len((output / "measurements.csv").read_text(encoding="utf-8").splitlines()), 1)

    def test_summary_link_supports_different_windows_drives(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            summary = dict(status="failed", rows=[], jobs=[], scenarios=[], cases=[])
            root = output / "project with spaces"
            with patch.object(flow, "ROOT", root), \
                    patch.object(flow.os.path, "relpath", side_effect=ValueError("different drives")):
                flow.write_summary(summary, output)
            text = (output / "RESULTS.md").read_text(encoding="utf-8")
            self.assertIn(f"(<{(root / 'docs/matvec-benchmark.md').as_uri()}>)", text)

    def test_summary_link_stays_relative_on_same_drive(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            summary = dict(status="failed", rows=[], jobs=[], scenarios=[], cases=[])
            with patch.object(flow, "ROOT", output):
                flow.write_summary(summary, output)
            text = (output / "RESULTS.md").read_text(encoding="utf-8")
            self.assertIn("(<docs/matvec-benchmark.md>)", text)

    def test_snapshot_hash_source_and_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            cases = []
            for scenario in flow.SCENARIOS:
                for rows in flow.ROWS:
                    for jobs in flow.JOBS:
                        for method in flow.METHODS:
                            accelerated = method != "software"
                            cases.append(dict(scenario=scenario, rows=rows, jobs=jobs, method=method,
                                              status="passed", outputs_checked=rows*jobs, cycles=10000,
                                              retired=300, stalls=100, icache_misses=5, dcache_misses=5,
                                              starts=jobs*((rows+3)//4 if method == "dma" else 1) if accelerated else 0,
                                              arithmetic_cycles=2*rows*jobs if accelerated else 0,
                                              busy_cycles=1000 if accelerated else 0))
            summary = dict(status="passed", rows=flow.ROWS, jobs=flow.JOBS, scenarios=flow.SCENARIOS, cases=cases)
            flow.write_summary(summary, output)
            record = dict(status="passed", cases_passed=90, source={"input_fingerprint": "known"},
                          measurements_sha256=flow.sha256(output / "measurements.csv"))
            flow.write_result_json(record, output / "run.json")
            with patch.object(flow, "source_identity", return_value={"input_fingerprint": "known"}):
                flow.check_snapshot(output)
                record["cases_passed"] = 89
                flow.write_result_json(record, output / "run.json")
                with self.assertRaisesRegex(RuntimeError, "incomplete"):
                    flow.check_snapshot(output)
            with patch.object(flow, "source_identity", return_value={"input_fingerprint": "changed"}):
                with self.assertRaisesRegex(RuntimeError, "different benchmark inputs"):
                    flow.check_snapshot(output)
            (output / "measurements.csv").write_text("modified")
            with self.assertRaisesRegex(RuntimeError, "hash mismatch"):
                flow.check_snapshot(output)


if __name__ == "__main__":
    unittest.main()
