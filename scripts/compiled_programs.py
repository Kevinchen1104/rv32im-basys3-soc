"""Build freestanding RV32IM C programs and compare RTL execution with Unicorn."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import struct
import subprocess
import sys
from datetime import datetime, timezone
from result_json import write_result_json
from execution_context import RunLock, parse_symbols, selection_context

ROOT = Path(__file__).resolve().parents[1]
MEMORY_BYTES = 0x4000
DATA_START = 0x3000
SIGNATURE = 0x3800
MASK32 = 0xFFFFFFFF
CASES = ("arithmetic", "memory", "calls", "matvec")
OPTIMIZATIONS = ("O0", "O2", "Os")
WRITE_OPCODES = {0x03, 0x13, 0x17, 0x33, 0x37, 0x67, 0x6F}
ALLOWED_OPCODES = WRITE_OPCODES | {0x23, 0x63}


def run(command, log, timeout=180):
    """Save command/output even on failure; never accept an old output as a pass."""
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w", encoding="utf-8") as stream:
        stream.write(f"Task: {log.parent.name}/{log.stem}\n")
        stream.write(f"Started: {datetime.now(timezone.utc).isoformat()}\n")
        stream.write("Command: " + subprocess.list2cmdline([str(x) for x in command]) + "\n")
        stream.write(f"Timeout: {timeout} seconds\n\n")
        stream.flush()
        try:
            environment = os.environ.copy()
            # GCC's cc1/as children must find this toolchain's DLLs first.
            environment["PATH"] = str(Path(command[0]).parent) + os.pathsep + environment.get("PATH", "")
            process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, env=environment,
                                       start_new_session=(os.name != "nt"))
            try:
                captured, _ = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired as error:
                captured = error.output or b""
                try:
                    if os.name == "nt":
                        if process.poll() is None:
                            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT, timeout=2)
                    else:
                        os.killpg(process.pid, signal.SIGKILL)
                except (OSError, subprocess.TimeoutExpired) as cleanup_error:
                    stream.write(f"Cleanup: {cleanup_error}\n")
                # An exited parent may have left a pipe open in a descendant.
                # Bound cleanup too, and always finish the timeout log.
                try:
                    captured, _ = process.communicate(timeout=2)
                except subprocess.TimeoutExpired as pending:
                    captured = pending.output or captured
                stream.write(captured.decode("utf-8", errors="replace"))
                stream.write(f"\nTIMEOUT after {timeout} seconds\n")
                stream.write(f"Result: timed_out\nFinished: {datetime.now(timezone.utc).isoformat()}\n")
                raise RuntimeError(f"tool timed out; see {log}") from error
        except OSError as error:
            stream.write(f"\nSTART FAILED: {error}\n")
            stream.write(f"Result: start_failed\nFinished: {datetime.now(timezone.utc).isoformat()}\n")
            raise RuntimeError(f"could not start tool; see {log}") from error
        output = captured.decode("utf-8", errors="replace").replace("\r\r\n", "\n").replace("\r\n", "\n")
        stream.write(output)
        status = "passed" if process.returncode == 0 else "failed"
        stream.write(f"\nResult: {status}\nExit code: {process.returncode}\n")
        stream.write(f"Finished: {datetime.now(timezone.utc).isoformat()}\n")
    if process.returncode:
        raise RuntimeError(f"tool exited {process.returncode}; see {log}")
    return output


def simulator_file(path):
    """Keep the checkout's Unicode path out of Verilog string plusargs."""
    return Path(path).relative_to(ROOT).as_posix()


def find_tool(name, directory=None):
    candidate = shutil.which(str(Path(directory) / name) if directory else name)
    if not candidate:
        raise RuntimeError(f"missing tool: {name}; set PATH or --toolchain-bin")
    return candidate


def source_identity():
    paths = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "--",
         "rtl", "firmware/c", "scripts/compiled_programs.py",
         "scripts/tests/test_compiled_programs.py", "scripts/result_json.py", "scripts/execution_context.py", "tb/reference/tb_compiled_program.v",
         "tools/compiled-programs", "fpga/fpga_sources.f"], cwd=ROOT, text=True).splitlines()
    hashes = {}
    for name in sorted(set(paths)):
        data = (ROOT / name).read_bytes().replace(b"\r\n", b"\n")
        hashes[name] = hashlib.sha256(data).hexdigest()
    fingerprint = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
    return {
        "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "working_tree_dirty": bool(subprocess.check_output(
            ["git", "status", "--porcelain"], cwd=ROOT, text=True).strip()),
        "input_fingerprint": fingerprint,
        "inputs": hashes,
    }


def expected_signature(case):
    """Algorithm-level answers, separate from the instruction emulator."""
    if case == "arithmetic":
        a, b, u, v = -1234567, 97, 0xFFFFFFFE, 3
        quotient = -(abs(a) // b)  # C signed division truncates toward zero.
        values = [a + b, a - b, a * b, quotient, a - quotient * b,
                  u * v, u // v, u % v, (u >> 5) ^ (u << 7),
                  int(a < b), int(u < v), (u & 0x55AA55AA) | 0x10001]
    elif case == "memory":
        values = [0, sum((i * 7 + 3) & 255 for i in range(80)),
                  sum((i * 1703 + 0x8001) & 65535 for i in range(40)),
                  -4, (79 * 7 + 3) & 255, (39 * 1703 + 0x8001) & 65535]
    elif case == "calls":
        def mix(a, b):
            return ((a * 17) ^ ((b + 5) & MASK32)) & MASK32
        total = 0
        for i in range(13):
            total = ((total + mix(i, total)) if i & 1 else total ^ mix(total, i)) & MASK32
        values = [total, mix(total, 29), 0]
    elif case == "matvec":
        values = [-78, 1030, 312, -133]
    else:
        raise ValueError(f"unknown case: {case}")
    return [value & MASK32 for value in values] + [0] * (16 - len(values))


def run_reference(image, done_pc, text_end, max_instructions=100000):
    import unicorn
    from unicorn.riscv_const import UC_RISCV_REG_PC, UC_RISCV_REG_X0

    cpu = unicorn.Uc(unicorn.UC_ARCH_RISCV, unicorn.UC_MODE_RISCV32)
    cpu.mem_map(0, MEMORY_BYTES)
    cpu.mem_write(0, image)
    for register in range(32):
        cpu.reg_write(UC_RISCV_REG_X0 + register, register)
    cpu.reg_write(UC_RISCV_REG_PC, 0)

    def check_data_access(uc, access, address, size, value, user_data):
        if address < DATA_START or address + size > MEMORY_BYTES or address % size:
            raise RuntimeError(f"reference data access outside aligned RAM: 0x{address:x}, size={size}")

    cpu.hook_add(unicorn.UC_HOOK_MEM_READ | unicorn.UC_HOOK_MEM_WRITE, check_data_access)
    trace = []
    for _ in range(max_instructions):
        pc = cpu.reg_read(UC_RISCV_REG_PC)
        if pc % 4 or not (0 <= pc < 0x100 or 0x1000 <= pc < text_end):
            raise RuntimeError(f"reference PC outside executable regions: 0x{pc:x}")
        instruction = int.from_bytes(cpu.mem_read(pc, 4), "little")
        opcode = instruction & 0x7F
        if opcode not in ALLOWED_OPCODES:
            raise RuntimeError(f"instruction outside compiled-program profile: 0x{instruction:08x}")
        rd = (instruction >> 7) & 31
        writes = opcode in WRITE_OPCODES and rd != 0
        cpu.emu_start(pc, MEMORY_BYTES, count=1)
        value = cpu.reg_read(UC_RISCV_REG_X0 + rd) if writes else 0
        trace.append((pc, instruction, (32 | rd) if writes else 0, value))
        if pc == done_pc:
            if cpu.reg_read(UC_RISCV_REG_X0 + 10) != 0:
                raise RuntimeError("C main returned a nonzero status")
            return trace, bytes(cpu.mem_read(DATA_START, MEMORY_BYTES - DATA_START))
    raise RuntimeError("reference instruction limit reached before program_done")


def compare_trace(expected, actual):
    for index, (ref, dut) in enumerate(zip(expected, actual)):
        # Destination bits have no architectural meaning without register write.
        meta = dut[2] if dut[2] & 32 else 0
        observed = (dut[0], dut[1], meta, dut[3] if meta else 0)
        if observed != ref:
            raise RuntimeError(f"retirement {index}: expected {ref}, got {observed}")
    if len(expected) != len(actual):
        raise RuntimeError(f"retired count differs: reference={len(expected)}, RTL={len(actual)}")


def compare_memory(expected, actual):
    if len(expected) != len(actual):
        raise RuntimeError("data RAM snapshot length differs")
    for offset, (ref, dut) in enumerate(zip(expected, actual)):
        if ref != dut:
            raise RuntimeError(f"data RAM mismatch at 0x{DATA_START + offset:04x}: expected {ref:02x}, got {dut:02x}")


def write_summary(summary, output):
    write_result_json(summary, output / "summary.json")
    lines = ["# Compiled C program checks", "", f"Status: **{summary['status']}**", "",
             "Each case compares GCC-generated code against Unicorn: retired PC, instruction,",
             "register writeback, the 4 KiB data-RAM snapshot, and sixteen result words.", "",
             "| Program | Optimization | Result | Retired instructions | Cycles |",
             "| --- | --- | --- | ---: | ---: |"]
    for row in summary["cases"]:
        lines.append(f"| {row['program']} | -{row['optimization']} | {row['status']} | "
                     f"{row.get('retired_instructions', '-')} | {row.get('cycles', '-')} |")
    if summary.get("error"):
        lines.extend(["", "Error: " + summary["error"]])
    lines.extend(["", "Case folders contain compiler/simulator logs, disassembly, and both traces.",
                  "[Run metadata](summary.json) records tools, source identity, and image hashes."])
    (output / "RESULTS.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toolchain-bin", default=os.environ.get("RISCV_TOOLCHAIN_BIN"))
    parser.add_argument("--prefix", default=os.environ.get("RISCV_PREFIX", "riscv64-unknown-elf-"))
    parser.add_argument("--cases", nargs="+", choices=CASES, default=list(CASES))
    parser.add_argument("--optimizations", nargs="+", choices=OPTIMIZATIONS, default=list(OPTIMIZATIONS))
    args = parser.parse_args()
    args.cases = sorted(set(args.cases))
    args.optimizations = sorted(set(args.optimizations))
    context = selection_context((args.cases, args.optimizations), (CASES, OPTIMIZATIONS))
    build = ROOT / "build/compiled-programs" / context
    output = ROOT / "results/compiled-programs" / context
    build.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    try:
        lock = RunLock(build / "running.lock")
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 1
    summary = {"status": "running", "started_at_utc": datetime.now(timezone.utc).isoformat(),
               "profile": {"march": "rv32im", "mabi": "ilp32", "memory_bytes": MEMORY_BYTES,
                           "icache": True, "dcache": True, "branch_prediction": True},
               "reference": "Unicorn RV32", "planned_cases": len(args.cases) * len(args.optimizations),
               "cases": []}
    try:
        write_summary(summary, output)
        import unicorn
        summary["reference_version"] = unicorn.__version__
        summary["source"] = source_identity()
        tools = {name: find_tool(args.prefix + name, args.toolchain_bin)
                 for name in ("gcc", "objcopy", "objdump", "nm")}
        tools.update({name: find_tool(name) for name in ("iverilog", "vvp")})
        summary["tools"] = {name: {"path": path, "version": run(
            [path, "-V" if name in ("iverilog", "vvp") else "--version"],
            output / f"{name}-version.log").splitlines()[0]} for name, path in tools.items()}
        sources = [line.strip() for line in (ROOT / "fpga/fpga_sources.f").read_text().splitlines()
                   if line.strip() and not line.startswith("#")]
        executable = build / "compiled_program.vvp"
        executable.unlink(missing_ok=True)
        run([tools["iverilog"], "-g2012", "-s", "tb_compiled_program", "-o", str(executable),
             *sources, "tb/reference/tb_compiled_program.v"], output / "iverilog.log")
        for case in args.cases:
            for optimization in args.optimizations:
                name = f"{case}-{optimization}"
                work = build / name
                result_dir = output / name
                work.mkdir(parents=True, exist_ok=True)
                result_dir.mkdir(parents=True, exist_ok=True)
                row = {"program": case, "optimization": optimization, "status": "running"}
                summary["cases"].append(row)
                write_summary(summary, output)
                elf = work / "program.elf"
                binary = work / "program.bin"
                image_path = work / "program.hex"
                dut_trace = result_dir / "rtl-trace.txt"
                dut_memory = result_dir / "rtl-memory.hex"
                for stale in (elf, binary, image_path, dut_trace, dut_memory,
                              result_dir / "reference-trace.txt", result_dir / "reference-memory.hex"):
                    stale.unlink(missing_ok=True)
                run([tools["gcc"], "-std=c11", "-march=rv32im", "-mabi=ilp32", "-mno-relax", "-mstrict-align",
                     "-msmall-data-limit=0", "-ffreestanding", "-fno-builtin", "-fno-pic",
                     "-fno-stack-protector", "-nostdlib", "-nostartfiles", "-Wall", "-Wextra", "-Werror",
                     f"-{optimization}", "-Wl,--no-relax,--build-id=none", "-T", "firmware/c/link.ld",
                     "firmware/c/start.S", f"firmware/c/{case}.c", "-o", str(elf)], result_dir / "gcc.log")
                run([tools["objcopy"], "-O", "binary", str(elf), str(binary)], result_dir / "objcopy.log")
                run([tools["objdump"], "-d", str(elf)], result_dir / "disassembly.log")
                nm_output = run([tools["nm"], "-n", "--defined-only", str(elf)], result_dir / "symbols.log")
                symbols = parse_symbols(nm_output)
                raw = binary.read_bytes()
                if len(raw) > MEMORY_BYTES:
                    raise RuntimeError("compiled image exceeds simulated memory")
                image = bytearray(MEMORY_BYTES)
                # Nonzero BSS verifies that the startup zeroing loop actually runs.
                image[DATA_START:] = b"\xa5" * (MEMORY_BYTES - DATA_START)
                image[:len(raw)] = raw
                image_path.write_text("".join(f"{word[0]:08x}\n" for word in struct.iter_unpack("<I", image)), encoding="ascii")
                reference_trace, reference_memory = run_reference(bytes(image), symbols["program_done"], symbols["__text_end"])
                actual_signature = list(struct.unpack_from("<16I", reference_memory, SIGNATURE - DATA_START))
                if actual_signature != expected_signature(case):
                    raise RuntimeError(f"algorithm result mismatch: {actual_signature}")
                (result_dir / "reference-trace.txt").write_text(
                    "".join(" ".join(f"{value:08x}" for value in entry) + "\n" for entry in reference_trace), encoding="ascii")
                (result_dir / "reference-memory.hex").write_text(
                    "".join(f"{word[0]:08x}\n" for word in struct.iter_unpack("<I", reference_memory)), encoding="ascii")
                log = run([tools["vvp"], str(executable), f"+image={simulator_file(image_path)}",
                           f"+trace={simulator_file(dut_trace)}", f"+memory={simulator_file(dut_memory)}",
                           f"+done_pc={symbols['program_done']:x}"], result_dir / "simulation.log")
                observed_trace = [tuple(int(word, 16) for word in line.split())
                                  for line in dut_trace.read_text().splitlines()]
                compare_trace(reference_trace, observed_trace)
                observed_memory = b"".join(struct.pack("<I", int(line, 16))
                                           for line in dut_memory.read_text().splitlines())
                compare_memory(reference_memory, observed_memory)
                metrics = re.search(r"METRICS cycles=(\d+) retired=(\d+) stalls=(\d+) icache_misses=(\d+) dcache_misses=(\d+)", log)
                if not metrics:
                    raise RuntimeError("simulation omitted completion metrics")
                row.update(zip(("cycles", "counter_retired", "stalls", "icache_misses", "dcache_misses"),
                               map(int, metrics.groups())))
                if row["counter_retired"] != len(reference_trace):
                    raise RuntimeError("retired performance counter disagrees with the trace")
                row.update(status="passed", retired_instructions=len(reference_trace),
                           data_bytes_compared=len(reference_memory), signature=actual_signature,
                           image_sha256=hashlib.sha256(image).hexdigest())
                write_summary(summary, output)
                print(f"PASS {name}: {len(reference_trace)} retired instructions, {row['cycles']} cycles", flush=True)
        if source_identity()["input_fingerprint"] != summary["source"]["input_fingerprint"]:
            raise RuntimeError("source inputs changed during the run; rerun with stable sources")
        summary["status"] = "passed"
    except Exception as error:
        summary["status"] = "failed"
        summary["error"] = str(error)
        if summary["cases"] and summary["cases"][-1]["status"] == "running":
            summary["cases"][-1]["status"] = "failed"
        print(f"FAIL: {error}", file=sys.stderr)
    finally:
        try:
            summary["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
            write_summary(summary, output)
        finally:
            lock.close()
    print(output / "RESULTS.md")
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
