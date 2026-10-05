"""Validate and publish the bounded six-profile D-cache comparison."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import statistics
import tempfile

from architecture_benchmark import DCACHE_PROFILES, source_identity
from compiled_programs import ROOT
from result_json import write_result_json
from signal_console_check import inputs as console_inputs
from publication import publish_directory

DEST = ROOT / "docs/benchmarks/dcache/capacity"
REPORTS = ("post_route_timing_summary.rpt", "post_route_critical_paths.rpt",
           "post_route_utilization.rpt", "post_route_hierarchy.rpt", "post_route_drc.rpt")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_files(directory, files):
    for name, expected in files.items():
        path = (directory / name).resolve()
        require(path.is_relative_to(directory.resolve()), f"artifact escapes its directory: {name}")
        require(path.is_file() and digest(path) == expected, f"changed or missing artifact: {path}")


def normalize(value):
    if isinstance(value, str):
        for path, label in ((ROOT, "."), (Path.home(), "<user-profile>")):
            value = value.replace(str(path), label).replace(path.as_posix(), label)
        return value
    if isinstance(value, list):
        return [normalize(item) for item in value]
    if isinstance(value, dict):
        return {normalize(key): normalize(item) for key, item in value.items()}
    return value


def validate_measurements(rows):
    key = lambda row: (row["extra_wait"], row["workload"], row["optimization"], row["profile"])
    lookup = {key(row): row for row in rows}
    require(len(lookup) == len(rows), "duplicate measured case")
    groups = {(r["extra_wait"], r["workload"], r["optimization"]) for r in rows}
    for delay, workload, optimization in groups:
        group = [lookup.get((delay, workload, optimization, profile)) for profile in DCACHE_PROFILES]
        require(all(group), f"incomplete profile group: {workload}/{optimization}/{delay}")
        require(len({r["image_sha256"] for r in group}) == 1, "cache comparison changed executable")
        require(len({r["retired"] for r in group}) == 1, "cache comparison changed retired instructions")
    for row in rows:
        require((row["dcache_bytes"], row["dcache_victim_lines"]) == DCACHE_PROFILES[row["profile"]], "profile geometry mismatch")
        base = lookup[0, row["workload"], row["optimization"], row["profile"]]
        for field in ("image_sha256", "retired", "data_line_fills", "data_writebacks", "victim_hits"):
            require(row[field] == base[field], f"latency sweep changed {field}")
        expected = base["cycles"] + row["extra_wait"] * (row["data_line_fills"] + row["data_writebacks"])
        require(row["cycles"] == expected, "serialized memory latency accounting mismatch")


def collect(stage):
    records, rows = [], []
    comparison = {"status": "passed", "matrices": [], "implementations": {}, "board": {}}

    def copy(source, relative):
        target = stage / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.suffix == ".json":
            value = normalize(read(source))
            value["publication_note"] = "Run hashes identify originals; publication.json identifies normalized copies."
            write_result_json(value, target)
        else:
            text = normalize(source.read_text(encoding="utf-8-sig")).replace("\r\n", "\n")
            text = re.sub(r"(?m)^\|?\s*Host\s*:.*\n", "", text)
            target.write_text(text, encoding="utf-8", newline="\n")
        records.append({"source": source.relative_to(ROOT).as_posix(), "original_sha256": digest(source),
                        "published": relative, "sha256": digest(target)})

    for delay, count in ((0, 204), (4, 48), (12, 48)):
        context = f"dcache-latency{delay}-complete-external" if delay else "dcache-complete-external"
        source = ROOT / "results/architecture" / context / "summary.json"
        matrix = read(source)
        require(matrix["status"] == "passed" and len(matrix["cases"]) == count, f"incomplete matrix: {context}")
        require(matrix["source"]["input_fingerprint"] == source_identity()["input_fingerprint"], "stale architecture study")
        check_files(source.parent, matrix["artifacts"])
        rows.extend(dict(row, extra_wait=delay) for row in matrix["cases"])
        copy(source, f"latency-{delay}.json")
        comparison["matrices"].append({"extra_wait": delay, "cases": count})
    validate_measurements(rows)
    fields = ["workload", "optimization", "profile", "dcache_bytes", "dcache_victim_lines", "extra_wait",
              "cycles", "retired", "dcache_misses", "data_line_fills", "data_writebacks", "victim_hits",
              "data_transfer_bytes", "image_sha256"]
    with (stage / "measurements.csv").open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, extrasaction="ignore", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)

    first_build = first_board = None
    for profile, geometry in DCACHE_PROFILES.items():
        source = ROOT / f"results/timing/dcache-capacity-{profile}.json"
        build = read(source)
        require(build["execution_status"] == "pass" and build["timing_status"] in ("pass", "fail"), f"incomplete implementation: {profile}")
        require((build["dcache_bytes"], build["dcache_victim_lines"]) == geometry, f"incorrect build geometry: {profile}")
        require((build["architecture_profile"], build["icache_bytes"], build["icache_parallel_lookup"],
                 build["timing_period_ns"]) == ("fast_cpu", 1024, 0, 10), "incorrect comparison baseline")
        for item in build["source_inputs"]:
            require(digest(ROOT / item["path"]) == item["sha256"], f"stale build input: {item['path']}")
        if first_build is not None:
            for field in ("source_inputs", "part", "top", "architecture_profile", "icache_bytes",
                          "icache_parallel_lookup", "timing_period_ns", "clock_profile", "implementation_strategy"):
                require(build[field] == first_build[field], f"FPGA comparison changed {field}")
        first_build = build
        copied = set()
        for artifact in build["report_artifacts"]:
            report = ROOT / artifact["path"]
            require(digest(report) == artifact["sha256"], f"changed FPGA report: {report}")
            if report.name in REPORTS:
                copy(report, f"implementation/{profile}/{report.name}")
                copied.add(report.name)
        require(copied == set(REPORTS), f"missing implementation reports: {profile}")
        copy(source, f"implementation/{profile}/metadata.json")
        comparison["implementations"][profile] = {"status": build["status"],
            "resources": build["reports"]["post_route_utilization"], "timing": build["reports"]["post_route_timing"]}
        if build["status"] != "pass":
            comparison["board"][profile] = {"status": "not_run", "reason": "implementation did not pass acceptance"}
            continue
        require(all(build[field] == "pass" for field in ("timing_status", "drc_status", "bitstream_status")), "incomplete board image")
        board_path = ROOT / f"results/signal-console/board-burst/capacity-{profile}.json"
        board = read(board_path)
        require(board["status"] == "passed" and board["inputs"] == console_inputs(), "failed or stale physical validation")
        require(board["cache"] == {"ICACHE_BYTES": 1024, "ICACHE_PARALLEL_LOOKUP": 0,
                                  "DCACHE_BYTES": geometry[0], "DCACHE_VICTIM_LINES": geometry[1]}, "physical cache mismatch")
        program_path = ROOT / board["programming"]["record"]
        require(digest(program_path) == board["programming"]["sha256"], "changed programming record")
        program = read(program_path)
        require(program["status"] == "passed" and program["build_summary_sha256"] == digest(source), "programming/build mismatch")
        require(program["bitstream_sha256"] == build["bitstream_sha256"], "programming bitstream mismatch")
        check_files(program_path.parent, program["files"])
        require(not board["final_status"]["uart_overrun"], "physical UART overrun")
        require([board[k] for k in ("test_commands_checked", "test_samples_checked", "stress_samples_checked", "client_samples_checked")] == [42, 202, 6400, 6], "incomplete physical coverage")
        if first_board is not None:
            require(board["packet_sha256"] == first_board["packet_sha256"], "physical comparison changed firmware")
            for section, field in (("stress", "inputs"), ("responses", "request_hex")):
                require([r[field] for r in board[section]] == [r[field] for r in first_board[section]], "physical comparison changed stimulus")
        first_board = board
        cycles = [row["compute_cycles"] for row in board["stress"]]
        require(len(cycles) == 200, "incomplete stress capture")
        comparison["board"][profile] = {"status": "passed", "outputs_checked": 6608,
            "batches": len(cycles), "cycles_min": min(cycles), "cycles_median": statistics.median(cycles), "cycles_max": max(cycles)}
        for path in (board_path, program_path, program_path.with_suffix(".log")):
            copy(path, "board/" + path.name)
    write_result_json(normalize(comparison), stage / "comparison.json")
    for name in ("measurements.csv", "comparison.json"):
        records.append({"published": name, "sha256": digest(stage / name)})
    write_result_json({"status": "passed", "generator": "scripts/publish_cache_study.py",
                       "generator_sha256": digest(Path(__file__)),
                       "normalization": "UTF-8/LF; checkout/user paths and report host headers removed; embedded original hashes preserved",
                       "checks": ["300 complete cases", "same executable and retired count across caches",
                                  "exact serialized-latency accounting", "same FPGA inputs and constraints",
                                  "same physical firmware/stimulus", "programming-to-build hash chain"],
                       "records": records}, stage / "publication.json")


def check_publication(directory):
    manifest = read(directory / "publication.json")
    require(manifest["status"] == "passed", "publication is incomplete")
    files = {row["published"]: row["sha256"] for row in manifest["records"]}
    require(len(files) == len(manifest["records"]), "duplicate publication path")
    check_files(directory, files)
    actual = {p.relative_to(directory).as_posix() for p in directory.rglob("*") if p.is_file()}
    require(actual == set(files) | {"publication.json"}, "unlisted publication file")
    return len(files)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify the committed snapshot without local build results")
    args = parser.parse_args()
    if args.check:
        print(f"PASS: {check_publication(DEST)} published files; source revision is recorded in the evidence")
        return
    staging = ROOT / "build/publication"
    staging.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="dcache-capacity-", dir=staging) as temporary:
        stage = Path(temporary)
        collect(stage)
        count = check_publication(stage)
        publish_directory(stage, DEST, ROOT, check_publication)
    print(f"Published 300 measured cases and {count} files to {DEST.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
