"""Build/check the 4-KiB Basys3 MATVEC firmware; no physical-device access."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import struct
import subprocess
from datetime import datetime, timezone

from compiled_programs import ROOT, find_tool, run, simulator_file
from matvec_benchmark import workload, METHODS, ROWS, JOBS, SCENARIOS
from result_json import write_result_json
from execution_context import RunLock

BUILD = ROOT / "build/board-matvec"
RESULTS = ROOT / "results/board-matvec"


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def firmware_inputs():
    names = ("firmware/c/board_matvec.c", "firmware/c/board.ld", "firmware/c/start.S",
             "scripts/board_matvec.py", "scripts/matvec_benchmark.py",
             "scripts/compiled_programs.py", "scripts/result_json.py", "scripts/execution_context.py")
    return {name: sha256(ROOT / name) for name in names}


def build(toolchain):
    BUILD.mkdir(parents=True, exist_ok=True)
    inputs = firmware_inputs()
    logs = RESULTS / "build"
    gcc = find_tool("riscv64-unknown-elf-gcc", toolchain)
    objcopy = find_tool("riscv64-unknown-elf-objcopy", toolchain)
    elf = BUILD / "program.elf"
    binary = BUILD / "program.bin"
    for old in (elf, binary, BUILD / "build.json"):
        old.unlink(missing_ok=True)
    run([gcc, "-std=c11", "-march=rv32im", "-mabi=ilp32", "-mno-relax", "-mstrict-align",
         "-msmall-data-limit=0", "-ffreestanding", "-fno-builtin", "-fno-pic", "-fno-stack-protector",
         "-nostdlib", "-nostartfiles", "-Wall", "-Wextra", "-Werror", "--param=min-pagesize=0",
         "-fno-toplevel-reorder", "-O2", "-Wl,--no-relax,--build-id=none",
         "-T", "firmware/c/board.ld", "firmware/c/start.S", "firmware/c/board_matvec.c",
         "-o", str(elf)], logs / "gcc.log")
    run([objcopy, "-O", "binary", str(elf), str(binary)], logs / "objcopy.log")
    data = binary.read_bytes()
    if not data or len(data) > 4096 or len(data) % 4:
        raise RuntimeError("firmware must fit aligned 4-KiB board IMEM")
    words = struct.unpack(f"<{len(data)//4}I", data)
    packet = struct.pack("<5I", 0x52564254, 1, 0, len(words), sum(words) & 0xffffffff) + data
    (BUILD / "program.boot.bin").write_bytes(packet)
    image = data + struct.pack("<I", 0x13) * ((4096-len(data))//4)
    (BUILD / "program.hex").write_text("".join(f"{word:08x}\n" for word in struct.unpack("<1024I", image)))
    record = {"status": "passed", "source_commit": subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "inputs": inputs, "firmware_bytes": len(data),
        "working_tree_dirty": bool(subprocess.check_output(["git", "status", "--porcelain", "--", *inputs], cwd=ROOT, text=True).strip()),
        "packet_sha256": sha256(BUILD / "program.boot.bin"),
        "elf_sha256": sha256(elf), "compiler": run([gcc, "--version"], logs / "version.log").splitlines()[0]}
    if firmware_inputs() != inputs:
        raise RuntimeError("board firmware inputs changed during compilation")
    write_result_json(record, BUILD / "build.json")
    print(f"PASS: board firmware {len(data)} / 4096 IMEM bytes")


def parse_transcript(text):
    lines = text.replace("\r\n", "\n").splitlines()
    if not lines or lines[0] != "B 00000001" or lines[-1] != "E 0000005a":
        raise ValueError("missing board benchmark start/end record")
    records = []
    expected_keys = {(s, r, j, m) for s in range(2) for r in ROWS for j in JOBS for m in range(3)}
    seen = set()
    for line in lines[1:-1]:
        parts = line.split()
        if len(parts) < 7 or parts[0] != "M" or any(len(p) != 8 for p in parts[1:]):
            raise ValueError("malformed measurement row")
        reuse, rows, jobs, method, cycles, *outputs = [int(p, 16) for p in parts[1:]]
        key = reuse, rows, jobs, method
        if key not in expected_keys or key in seen or not 0 < cycles < 1000000:
            raise ValueError(f"invalid, duplicated or incomplete case {key}")
        expected = workload(rows, jobs, SCENARIOS[reuse])[2]
        if outputs != expected:
            raise ValueError(f"incorrect output values for {key}")
        seen.add(key)
        records.append({"scenario": SCENARIOS[reuse], "rows": rows, "jobs": jobs,
                        "method": METHODS[method], "cycles": cycles, "cycles_per_job": cycles/jobs,
                        "outputs_checked": len(outputs)})
    if seen != expected_keys or len(records) != 90:
        raise ValueError("expected all 90 cases")
    return records


def begin_comparison(directory):
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "measurements.csv").unlink(missing_ok=True)
    write_result_json({"status": "running"}, directory / "comparison.json")


def check(path):
    begin_comparison(path.parent)
    try:
        check_contents(path)
    except Exception as error:
        write_result_json({"status": "failed", "error": str(error)}, path.parent / "comparison.json")
        raise


def check_contents(path):
    record = json.loads((BUILD / "build.json").read_text())
    if record["inputs"] != firmware_inputs() or record["packet_sha256"] != sha256(BUILD / "program.boot.bin"):
        raise RuntimeError("board firmware inputs/packet changed; rebuild before capture")
    rows = parse_transcript(path.read_text(encoding="ascii"))
    directory = path.parent
    with (directory / "measurements.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]), lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    summary = {"status": "passed", "checked_at_utc": datetime.now(timezone.utc).isoformat(),
               "cases_passed": len(rows), "outputs_checked": sum(r["outputs_checked"] for r in rows),
               "transcript_sha256": sha256(path), "firmware": record,
               "measurements_sha256": sha256(directory / "measurements.csv")}
    write_result_json(summary, directory / "comparison.json")
    print(f"PASS: {len(rows)} measurements and {summary['outputs_checked']} output values")


def simulate():
    directory = RESULTS / "simulation"
    begin_comparison(directory)
    try:
        executable = BUILD / "board.vvp"
        transcript = directory / "uart.txt"
        transcript.unlink(missing_ok=True)
        run([find_tool("iverilog"), "-g2012", "-s", "tb_board_matvec", "-o", str(executable),
             "-f", "fpga/fpga_sources.f", "tb/reference/tb_board_matvec.v"], directory / "compile.log")
        run([find_tool("vvp"), str(executable), f"+image={simulator_file(BUILD/'program.hex')}",
             f"+output={simulator_file(transcript)}"], directory / "simulation.log", timeout=300)
        check_contents(transcript)
    except Exception as error:
        write_result_json({"status": "failed", "error": str(error)}, directory / "comparison.json")
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--simulate", action="store_true")
    parser.add_argument("--check-transcript", type=Path)
    parser.add_argument("--toolchain-bin")
    args = parser.parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    lock = RunLock(BUILD / "run.lock")
    try:
        if args.build:
            build(args.toolchain_bin)
        if args.simulate:
            simulate()
        if args.check_transcript:
            check(args.check_transcript)
    finally:
        lock.close()


if __name__ == "__main__":
    main()
