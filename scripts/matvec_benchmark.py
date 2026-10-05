"""Measure RAM-to-RAM software, Scratchpad and DMA-lite MATVEC in RTL."""

import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile

from compiled_programs import ROOT, find_tool, run, simulator_file
from result_json import write_result_json
from execution_context import RunLock, parse_symbols
from publication import publish_directory

METHODS = ("software", "scratchpad", "dma")
ROWS = (1, 2, 4, 8, 16)
JOBS = (1, 4, 8)
SCENARIOS = ("stream", "reuse")
METRICS = ("cycles", "retired", "stalls", "icache_misses", "dcache_misses",
           "busy_cycles", "arithmetic_cycles", "starts")


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def source_identity():
    paths = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "--",
         "rtl", "firmware/c", "fpga/fpga_sources.f", "scripts/compiled_programs.py",
         "scripts/result_json.py", "scripts/matvec_benchmark.py", "scripts/execution_context.py", "scripts/publication.py",
         "scripts/tests/test_matvec_benchmark.py", "tb/reference/tb_matvec_benchmark.v"],
        cwd=ROOT, text=True).splitlines()
    hashes = {name: hashlib.sha256((ROOT / name).read_bytes().replace(b"\r\n", b"\n")).hexdigest()
              for name in sorted(set(paths))}
    return {
        "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "working_tree_dirty": bool(subprocess.check_output(
            ["git", "status", "--porcelain"], cwd=ROOT, text=True).strip()),
        "input_fingerprint": hashlib.sha256("\n".join(
            f"{name}:{value}" for name, value in hashes.items()).encode()).hexdigest(),
        "inputs": hashes,
    }


def pack(lanes):
    return sum((lane & 255) << (8 * index) for index, lane in enumerate(lanes))


def workload(rows, jobs, scenario):
    """Signed Python dot products form the oracle before operand packing."""
    matrices = [[[((job * 11 + row * 17 + lane * 29) % 256) - 128
                  for lane in range(4)] for row in range(rows)]
                for job in range(1 if scenario == "reuse" else jobs)]
    vectors = [[((job * 37 + lane * 83) % 256) - 128 for lane in range(4)]
               for job in range(jobs)]
    expected = []
    for job, vector in enumerate(vectors):
        for row in matrices[0 if scenario == "reuse" else job]:
            expected.append(sum(a * b for a, b in zip(row, vector)) & 0xFFFFFFFF)
    matrix_words = [pack(row) for matrix in matrices for row in matrix]
    vector_words = [pack(vector) for vector in vectors]
    return matrix_words + [0] * (128 - len(matrix_words)), vector_words + [0] * (8 - jobs), expected


def parse_metrics(text, method, rows, jobs):
    lines = re.findall(r"^METRICS (.+)$", text, re.MULTILINE)
    if len(lines) != 1:
        raise RuntimeError("expected exactly one measurement interval")
    fields = lines[0].split()
    if any(not re.fullmatch(r"\w+=\d+", field) for field in fields):
        raise RuntimeError("malformed measurement counter")
    values = {key: int(value) for key, value in (field.split("=") for field in fields)}
    if len(fields) != len(values) or set(values) != set(METRICS) or values["cycles"] <= 0:
        raise RuntimeError("missing or invalid measurement counters")
    expected_starts = 0 if method == "software" else jobs * ((rows + 3) // 4 if method == "dma" else 1)
    expected_arithmetic = 0 if method == "software" else 2 * rows * jobs
    if values["starts"] != expected_starts or values["arithmetic_cycles"] != expected_arithmetic:
        raise RuntimeError("accelerator job/arithmetic count disagrees with workload")
    if not (values["arithmetic_cycles"] <= values["busy_cycles"] <= values["cycles"]):
        raise RuntimeError("inconsistent activity counters")
    if method == "software" and values["busy_cycles"] != 0:
        raise RuntimeError("accelerator unexpectedly active in software baseline")
    return values


def check_memory(memory, symbols, matrix, vectors, expected):
    checks = {
        "benchmark_matrix": matrix,
        "benchmark_vectors": vectors,
        "benchmark_output": expected + [0] * (128 - len(expected)),
        "signature": [0x600DCAFE] + [0] * 15,
    }
    if len(memory) != 4096:
        raise RuntimeError("incomplete data-memory snapshot")
    for name, wanted in checks.items():
        actual = list(struct.unpack_from(f"<{len(wanted)}I", memory, symbols[name] - 0x3000))
        if actual != wanted:
            index = next(i for i, pair in enumerate(zip(actual, wanted)) if pair[0] != pair[1])
            raise RuntimeError(f"{name}[{index}]: expected {wanted[index]:08x}, got {actual[index]:08x}")


def write_summary(summary, output):
    write_result_json(summary, output / "summary.json")
    method_path = ROOT / "docs/matvec-benchmark.md"
    try:
        method_link = os.path.relpath(method_path, output).replace(os.sep, "/")
    except ValueError:
        # Windows cannot form a relative path between different drives.
        method_link = method_path.as_uri()
    lines = ["# MATVEC end-to-end benchmark", "", f"Status: **{summary['status']}**", "",
             "RAM inputs to RAM outputs; GCC -O2; caches and prediction enabled.",
             "Cycles include driver setup, data movement, polling and output stores.",
             f"[Method and interpretation](<{method_link}>) | [Counters](measurements.csv) | [Source and tools](summary.json)", ""]
    passed = { (r["scenario"], r["rows"], r["jobs"], r["method"]): r
               for r in summary["cases"] if r["status"] == "passed" }
    for scenario in summary["scenarios"]:
        lines.extend([f"## {scenario.title()}", "",
                      "| Rows x 4 | Jobs | Software cycles | Scratchpad cycles | DMA cycles | Scratchpad speedup | DMA speedup |",
                      "| ---: | ---: | ---: | ---: | ---: | ---: | ---: |"])
        for rows in summary["rows"]:
            for jobs in summary["jobs"]:
                trio = [passed.get((scenario, rows, jobs, method)) for method in METHODS]
                if all(trio):
                    sw, sp, dma = [row["cycles"] for row in trio]
                    lines.append(f"| {rows} | {jobs} | {sw:,} | {sp:,} | {dma:,} | {sw/sp:.2f}x | {sw/dma:.2f}x |")
        lines.append("")
    if summary.get("error"):
        lines.extend(["Error: " + summary["error"], ""])
    lines.extend(["Speedup = software cycles / method cycles; values below 1 mean slower.",
                  "CSV also separates accelerator busy cycles from multiply/reduce cycles.",
                  "Each case folder retains the simulator log and cache-visible output snapshot."])
    (output / "RESULTS.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    fields = ["scenario", "rows", "jobs", "method", "status", *METRICS, "cycles_per_job", "outputs_checked"]
    with (output / "measurements.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, extrasaction="ignore", lineterminator="\n")
        writer.writeheader()
        writer.writerows(summary["cases"])


def build_program(tools, method, build, output):
    work = build / method
    logs = output / "build" / method
    work.mkdir(parents=True, exist_ok=True)
    elf = work / "program.elf"
    binary = work / "program.bin"
    elf.unlink(missing_ok=True)
    binary.unlink(missing_ok=True)
    run([tools["gcc"], "-std=c11", "-march=rv32im", "-mabi=ilp32", "-mno-relax", "-mstrict-align",
         "-msmall-data-limit=0", "-ffreestanding", "-fno-builtin", "-fno-pic", "-fno-stack-protector",
         "-nostdlib", "-nostartfiles", "-Wall", "-Wextra", "-Werror", "--param=min-pagesize=0",
         "-fno-toplevel-reorder",
         "-O2", f"-DMETHOD={METHODS.index(method)}",
         "-Wl,--no-relax,--build-id=none", "-T", "firmware/c/link.ld", "firmware/c/start.S",
         "firmware/c/matvec_benchmark.c", "-o", str(elf)], logs / "gcc.log")
    run([tools["objcopy"], "-O", "binary", str(elf), str(binary)], logs / "objcopy.log")
    run([tools["objdump"], "-d", str(elf)], logs / "disassembly.log")
    symbols = run([tools["nm"], "-n", "--defined-only", str(elf)], logs / "symbols.log")
    symbols = parse_symbols(symbols)
    raw = binary.read_bytes()
    if len(raw) > 0x3800:
        raise RuntimeError("program image overlaps signature/stack")
    return raw, symbols


def check_snapshot(directory, require_current=True):
    record = json.loads((directory / "run.json").read_text(encoding="utf-8"))
    if record["status"] != "passed":
        raise RuntimeError("published run was not successful")
    if sha256(directory / "measurements.csv") != record["measurements_sha256"]:
        raise RuntimeError("published measurement CSV hash mismatch")
    if require_current and source_identity()["input_fingerprint"] != record["source"]["input_fingerprint"]:
        raise RuntimeError("published measurements describe different benchmark inputs")
    with (directory / "measurements.csv").open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    required = {(s, r, j, m) for s in SCENARIOS for r in ROWS for j in JOBS for m in METHODS}
    observed = {(r["scenario"], int(r["rows"]), int(r["jobs"]), r["method"]) for r in rows}
    if len(rows) != len(required) or observed != required or record["cases_passed"] != len(rows):
        raise RuntimeError("published benchmark matrix is incomplete")
    for row in rows:
        if row["status"] != "passed" or int(row["outputs_checked"]) != int(row["rows"]) * int(row["jobs"]):
            raise RuntimeError("published case did not check every output")
        parse_metrics("METRICS " + " ".join(f"{key}={row[key]}" for key in METRICS),
                      row["method"], int(row["rows"]), int(row["jobs"]))
    print(f"PASS: {len(rows)} published measurements, CSV hash and source identity")


def publish_snapshot(summary, output):
    if summary["status"] != "passed" or summary["source"]["working_tree_dirty"]:
        raise RuntimeError("publish requires a successful run from committed sources")
    directory = ROOT / "docs/benchmarks/matvec"
    record = {"status": "passed", "cases_passed": len(summary["cases"]),
              "outputs_checked": sum(row["outputs_checked"] for row in summary["cases"]),
              "measured_at_utc": summary["finished_at_utc"], "source": summary["source"],
              "profile": summary["profile"], "ram_layout": summary["ram_layout"],
              "tools": {name: value["version"] for name, value in summary["tools"].items()},
              "measurements_sha256": sha256(output / "measurements.csv")}
    staging = ROOT / "build/publication"
    staging.mkdir(parents=True, exist_ok=True)

    def validate(directory):
        if {p.name for p in directory.iterdir()} != {"measurements.csv", "run.json"}:
            raise RuntimeError("unexpected files in MATVEC publication; preserve them before replacing it")
        check_snapshot(directory, require_current=False)

    with tempfile.TemporaryDirectory(prefix="matvec-", dir=staging) as temporary:
        stage = Path(temporary)
        shutil.copyfile(output / "measurements.csv", stage / "measurements.csv")
        write_result_json(record, stage / "run.json")
        check_snapshot(stage)
        # The prior snapshot may describe older sources; its integrity must
        # still hold before replacing it with the current, checked run.
        publish_directory(stage, directory, ROOT, validate)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toolchain-bin", default=os.environ.get("RISCV_TOOLCHAIN_BIN"))
    parser.add_argument("--prefix", default=os.environ.get("RISCV_PREFIX", "riscv64-unknown-elf-"))
    parser.add_argument("--rows", nargs="+", type=int, choices=ROWS, default=list(ROWS))
    parser.add_argument("--jobs", nargs="+", type=int, choices=JOBS, default=list(JOBS))
    parser.add_argument("--scenarios", nargs="+", choices=SCENARIOS, default=list(SCENARIOS))
    parser.add_argument("--publish", action="store_true", help="publish the complete clean-source run in docs/benchmarks/matvec")
    parser.add_argument("--check-snapshot", action="store_true", help="verify published CSV, coverage and source hashes without tools")
    args = parser.parse_args()
    if args.check_snapshot:
        check_snapshot(ROOT / "docs/benchmarks/matvec")
        return 0
    # The input selection names a context so a smoke run cannot replace the full matrix.
    selection = (sorted(set(args.rows)), sorted(set(args.jobs)), sorted(set(args.scenarios)))
    complete = selection == (list(ROWS), list(JOBS), sorted(SCENARIOS))
    if args.publish and not complete:
        parser.error("--publish requires the complete matrix")
    if args.publish and source_identity()["working_tree_dirty"]:
        parser.error("commit source changes before --publish")
    context = "" if complete else "subset-" + hashlib.sha256(repr(selection).encode()).hexdigest()[:10]
    build = ROOT / "build/matvec-benchmark" / context
    output = ROOT / "results/matvec-benchmark" / context
    build.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    try:
        lock = RunLock(build / "running.lock")
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 1
    summary = {"status": "running", "started_at_utc": datetime.now(timezone.utc).isoformat(),
               "rows": selection[0], "jobs": selection[1], "scenarios": selection[2],
               "planned_cases": len(selection[0]) * len(selection[1]) * len(selection[2]) * 3,
               "profile": {"optimization": "O2", "memory_bytes": 16384, "icache_bytes": 64,
                           "dcache_bytes": 64, "branch_prediction": True, "completion": "polling",
                           "memory_backend": "internal RTL memory", "input_seed": "deterministic formulas"},
               "cases": []}
    try:
        write_summary(summary, output)
        summary["source"] = source_identity()
        tools = {name: find_tool(args.prefix + name, args.toolchain_bin)
                 for name in ("gcc", "objcopy", "objdump", "nm")}
        tools.update({name: find_tool(name) for name in ("iverilog", "vvp")})
        summary["tools"] = {name: {"path": path, "version": run(
            [path, "-V" if name in ("iverilog", "vvp") else "--version"],
            output / "build" / f"{name}-version.log").splitlines()[0]} for name, path in tools.items()}
        sources = [line.strip() for line in (ROOT / "fpga/fpga_sources.f").read_text().splitlines()
                   if line.strip() and not line.startswith("#")]
        executable = build / "matvec.vvp"
        executable.unlink(missing_ok=True)
        run([tools["iverilog"], "-g2012", "-s", "tb_matvec_benchmark", "-o", str(executable),
             *sources, "tb/reference/tb_matvec_benchmark.v"], output / "build/iverilog.log")
        programs = {method: build_program(tools, method, build, output) for method in METHODS}
        layout = {method: {name: symbols[name] for name in
                          ("benchmark_config", "benchmark_matrix", "benchmark_vectors", "benchmark_output")}
                  for method, (_, symbols) in programs.items()}
        if any(addresses != layout["software"] for addresses in layout.values()):
            raise RuntimeError("operand/output RAM layout differs between methods")
        summary["ram_layout"] = layout["software"]
        for scenario in summary["scenarios"]:
            for rows in summary["rows"]:
                for jobs in summary["jobs"]:
                    matrix, vectors, expected = workload(rows, jobs, scenario)
                    for method in METHODS:
                        name = f"{scenario}-r{rows}-j{jobs}-{method}"
                        case_dir = output / name
                        case_dir.mkdir(parents=True, exist_ok=True)
                        row = {"scenario": scenario, "rows": rows, "jobs": jobs, "method": method, "status": "running"}
                        summary["cases"].append(row)
                        write_summary(summary, output)
                        raw, symbols = programs[method]
                        image = bytearray(0x4000)
                        image[:len(raw)] = raw
                        for symbol, values in (("benchmark_config", [rows, jobs, int(scenario == "reuse")]),
                                               ("benchmark_matrix", matrix), ("benchmark_vectors", vectors)):
                            struct.pack_into(f"<{len(values)}I", image, symbols[symbol], *values)
                        image_path = build / f"{name}.hex"
                        image_path.write_text("".join(f"{word[0]:08x}\n" for word in struct.iter_unpack("<I", image)), encoding="ascii")
                        snapshot = case_dir / "memory.hex"
                        snapshot.unlink(missing_ok=True)
                        log = run([tools["vvp"], str(executable), f"+image={simulator_file(image_path)}",
                                   f"+memory={simulator_file(snapshot)}", f"+begin_pc={symbols['benchmark_begin']:x}",
                                   f"+end_pc={symbols['benchmark_end']:x}", f"+done_pc={symbols['program_done']:x}"],
                                  case_dir / "simulation.log")
                        metrics = parse_metrics(log, method, rows, jobs)
                        memory = b"".join(struct.pack("<I", int(line, 16)) for line in snapshot.read_text().splitlines())
                        check_memory(memory, symbols, matrix, vectors, expected)
                        row.update(metrics)
                        row.update(status="passed", outputs_checked=len(expected), cycles_per_job=metrics["cycles"] / jobs,
                                   image_sha256=hashlib.sha256(image).hexdigest(), log=f"{name}/simulation.log",
                                   memory=f"{name}/memory.hex", expected_output=expected,
                                   symbols={key: symbols[key] for key in ("benchmark_begin", "benchmark_end", "program_done",
                                                                        "benchmark_matrix", "benchmark_vectors", "benchmark_output")})
                        print(f"PASS {name}: {metrics['cycles']} cycles, {len(expected)} outputs", flush=True)
        if source_identity()["input_fingerprint"] != summary["source"]["input_fingerprint"]:
            raise RuntimeError("source inputs changed during the benchmark")
        summary["status"] = "passed"
    except Exception as error:
        summary["status"] = "failed"
        summary["error"] = str(error)
        if summary["cases"] and summary["cases"][-1]["status"] == "running":
            summary["cases"][-1]["status"] = "failed"
        print(f"FAIL: {error}", file=sys.stderr)
    finally:
        summary["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
        summary["artifacts"] = {p.relative_to(output).as_posix(): sha256(p)
                                for p in sorted(output.rglob("*")) if p.is_file()
                                and p.suffix in (".log", ".hex") and "subset-" not in p.relative_to(output).parts[0]}
        try:
            write_summary(summary, output)
        finally:
            lock.close()
    print(output / "RESULTS.md")
    if args.publish and summary["status"] == "passed":
        publish_snapshot(summary, output)
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
