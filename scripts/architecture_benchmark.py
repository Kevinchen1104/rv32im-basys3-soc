"""Compare CPU design choices with identical GCC images and checked outputs."""

import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import zlib

import compiled_programs as compiled
import matvec_benchmark as matvec
from execution_context import RunLock, parse_symbols
from result_json import write_result_json

ROOT = compiled.ROOT
PROFILES = {
    "iterative_cpu": (0, 1, 1, 1, 0, 0),
    "fast_cpu": (1, 1, 1, 1, 0, 0),
    "fast_scratchpad": (1, 1, 1, 1, 1, 0),
    "fast_dma": (1, 1, 1, 1, 0, 1),
    "fast_no_prediction": (1, 1, 1, 0, 0, 0),
    "fast_ideal_memory": (1, 0, 0, 1, 0, 0),
}
PARAMETERS = ("FAST_MULTIPLY", "ICACHE", "DCACHE", "PREDICTION", "SCRATCHPAD", "DMA")
ICACHE_PROFILES = {"parallel64": (64, 1), "indexed64": (64, 0),
                   "indexed256": (256, 0), "indexed1024": (1024, 0)}
DCACHE_PROFILES = {"dm64": (64, 0), "dm128": (128, 0), "victim1": (64, 1),
                   "victim2": (64, 2), "victim4": (64, 4), "victim8": (64, 8)}
CAUSES = ("uart", "dma", "dcache", "rv32m", "icache", "load_use")
WORKLOADS = ("fir", "crc32", "sort", "resident", "sequential", "conflict")
MEMORY_SCENARIOS = {
    "pair_stride64": (2, 16, 0, 0),
    "four_stride64": (4, 16, 0, 0),
    "eight_stride64": (8, 16, 0, 0),
    "eight_stride80": (8, 20, 0, 0),
    "eight_shifted": (8, 20, 1, 0),
    "thirtytwo_lines": (32, 4, 0, 0),
    "mixed_stride80": (8, 20, 0, 4),
}
COUNTERS = ("cycles", "retired", "stalls", "icache_misses", "dcache_misses", "branch_misses",
            "no_retire_no_stall", "retire_with_stall", "busy_cycles", "compute_cycles",
            "data_line_fills", "data_writebacks", "victim_hits")


def source_identity():
    names = subprocess.check_output([
        "git", "ls-files", "--cached", "--others", "--exclude-standard", "--",
        "rtl", "firmware/c", "fpga/fpga_sources.f", "tb/reference", "scripts/architecture_benchmark.py",
        "scripts/compiled_programs.py", "scripts/matvec_benchmark.py", "scripts/execution_context.py",
        "scripts/result_json.py", "scripts/tests/test_architecture_benchmark.py",
        "scripts/dcache_analysis.py"], cwd=ROOT, text=True).splitlines()
    hashes = {name: hashlib.sha256((ROOT / name).read_bytes().replace(b"\r\n", b"\n")).hexdigest()
              for name in sorted(set(names))}
    return {"commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
            "working_tree_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip()),
            "input_fingerprint": hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest(),
            "inputs": hashes}


def parse_profile(text):
    matches = re.findall(r"^PROFILE (.*)$", text, re.MULTILINE)
    if len(matches) != 1:
        raise RuntimeError("expected one complete profiling interval")
    fields = matches[0].split()
    if any(not re.fullmatch(r"\w+=\d+", field) for field in fields):
        raise RuntimeError("malformed profile counter")
    counters = {key: int(value) for key, value in (field.split("=") for field in fields)}
    if len(fields) != len(counters) or set(counters) != set(COUNTERS):
        raise RuntimeError("profile counter schema mismatch")
    pairs = [(int(mask), int(count)) for mask, count in re.findall(r"^MASK (\d+) (\d+)$", text, re.MULTILINE)]
    if sorted(mask for mask, _ in pairs) != list(range(64)):
        raise RuntimeError("incomplete or duplicated overlap histogram")
    histogram = dict(pairs)
    if counters["cycles"] <= 0 or counters["retired"] <= 0:
        raise RuntimeError("empty profiling interval")
    if sum(histogram.values()) != counters["cycles"]:
        raise RuntimeError("histogram does not cover the cycle interval")
    if counters["cycles"] - histogram[0] != counters["stalls"]:
        raise RuntimeError("stall union differs from hardware counter")
    if counters["retired"] + counters["stalls"] + counters["no_retire_no_stall"] - counters["retire_with_stall"] != counters["cycles"]:
        raise RuntimeError("retirement/stall accounting does not reconcile")
    if not 0 <= counters["compute_cycles"] <= counters["busy_cycles"] <= counters["cycles"]:
        raise RuntimeError("invalid accelerator activity counts")
    counters["cpi"] = counters["cycles"] / counters["retired"]
    counters["data_transfer_bytes"] = 16 * (counters["data_line_fills"] + counters["data_writebacks"])
    counters["overlap_cycles"] = sum(count for mask, count in pairs if mask & (mask - 1))
    counters["no_stall_cycles"] = histogram[0]
    for bit, cause in enumerate(CAUSES):
        counters[f"{cause}_raw"] = sum(count for mask, count in pairs if mask & (1 << bit))
        counters[f"{cause}_exclusive"] = sum(count for mask, count in pairs if mask & (1 << bit) and not mask & ((1 << bit) - 1))
    counters["stall_mask_counts"] = [histogram[index] for index in range(64)]
    return counters


def expected_workload(name):
    if name in MEMORY_SCENARIOS:
        lines, stride, offset, period = MEMORY_SCENARIOS[name]
        data = [i * 37 + 11 for i in range(256)]
        answer = 0
        for i in range(1024):
            index = offset + (i % lines) * stride
            if period and i % period == 0:
                data[index] += i
            answer += data[index]
        return answer & 0xFFFFFFFF
    data = [((i * 37 + 11) & 255) - 128 for i in range(128)]
    if name == "fir":
        taps = (3, -2, 7, 1, -5, 4, -1, 2)
        answer = sum(sum(taps[t] * data[i-t] for t in range(min(i+1, 8))) for i in range(64))
    elif name == "crc32":
        answer = zlib.crc32(bytes(value & 255 for value in data))
    elif name == "sort":
        answer = 0
        for value in sorted(data[:64]):
            answer = ((answer << 1) ^ value) & 0xFFFFFFFF
    else:
        indices = {"resident": lambda i: i & 15,
                   "sequential": lambda i: i & 127,
                   "conflict": lambda i: (i & 7) << 4}
        answer = sum(data[indices[name](i)] for i in range(1024))
    return answer & 0xFFFFFFFF


def build_workload(tools, name, optimization, build, output):
    work = build / "images" / f"{name}-{optimization}"
    work.mkdir(parents=True, exist_ok=True)
    logs = output / "build" / f"{name}-{optimization}"
    elf, binary = work / "program.elf", work / "program.bin"
    extra = [f"-DWORKLOAD={WORKLOADS.index(name)}"] if name in WORKLOADS else []
    source = "architecture_workload" if extra else name
    if name in MEMORY_SCENARIOS:
        source = "memory_sweep"
    compiled.run([tools["gcc"], "-std=c11", "-march=rv32im", "-mabi=ilp32", "-mno-relax",
                  "-mstrict-align", "-msmall-data-limit=0", "-ffreestanding", "-fno-builtin",
                  "-fno-pic", "-fno-stack-protector", "-nostdlib", "-nostartfiles", "-Wall",
                  "-Wextra", "-Werror", f"-{optimization}", *extra, "-Wl,--no-relax,--build-id=none",
                  "-T", "firmware/c/link.ld", "firmware/c/start.S", f"firmware/c/{source}.c",
                  "-o", str(elf)], logs / "gcc.log")
    compiled.run([tools["objcopy"], "-O", "binary", str(elf), str(binary)], logs / "objcopy.log")
    compiled.run([tools["objdump"], "-d", str(elf)], logs / "disassembly.log")
    symbols = parse_symbols(compiled.run([tools["nm"], "-n", "--defined-only", str(elf)], logs / "symbols.log"))
    raw = binary.read_bytes()
    if len(raw) > 0x3800:
        raise RuntimeError("workload overlaps signature region")
    image = bytearray(16384)
    image[0x3000:] = b"\xa5" * 4096
    image[:len(raw)] = raw
    if name in MEMORY_SCENARIOS:
        struct.pack_into("<4I", image, symbols["memory_config"], *MEMORY_SCENARIOS[name])
    return image, symbols


def simulate(tools, executable, image, symbols, work, result):
    work.mkdir(parents=True, exist_ok=True)
    result.mkdir(parents=True, exist_ok=True)
    image_path = work / "image.hex"
    image_path.write_text("".join(f"{word[0]:08x}\n" for word in struct.iter_unpack("<I", image)), encoding="ascii")
    trace = result / "trace.txt"
    memory = result / "memory.hex"
    # Remove prior outputs before invocation; failed runs cannot inherit them.
    trace.unlink(missing_ok=True)
    memory.unlink(missing_ok=True)
    log = compiled.run([tools["vvp"], str(executable), f"+image={compiled.simulator_file(image_path)}",
                        f"+trace={compiled.simulator_file(trace)}", f"+memory={compiled.simulator_file(memory)}",
                        f"+begin_pc={symbols.get('benchmark_begin', symbols['main']):x}",
                        f"+end_pc={symbols.get('benchmark_end', symbols['program_done']):x}",
                        f"+done_pc={symbols['program_done']:x}"], result / "simulation.log")
    if "PASS: architecture workload completed" not in log:
        raise RuntimeError("simulation did not complete")
    actual_trace = [tuple(int(word, 16) for word in line.split()) for line in trace.read_text().splitlines()]
    actual_memory = b"".join(struct.pack("<I", int(line, 16)) for line in memory.read_text().splitlines())
    counters = parse_profile(log)
    begin = next(i for i, row in enumerate(actual_trace) if row[0] == symbols.get("benchmark_begin", symbols["main"]))
    end = next(i for i, row in enumerate(actual_trace) if row[0] == symbols.get("benchmark_end", symbols["program_done"]))
    if end - begin != counters["retired"]:
        raise RuntimeError("retired trace and hardware counter interval disagree")
    counters["image_sha256"] = hashlib.sha256(image).hexdigest()
    counters["code_sha256"] = hashlib.sha256(image[:symbols["__text_end"]]).hexdigest()
    return counters, actual_trace, actual_memory


def save(summary, output):
    write_result_json(summary, output / "summary.json")
    rows = summary["cases"]
    fields = ["workload", "optimization", "profile", "icache_bytes", "icache_parallel_lookup", "dcache_bytes", "dcache_victim_lines", "scenario", "rows", "jobs", "method",
              "status", *COUNTERS, "data_transfer_bytes", "cpi", "overlap_cycles", "no_stall_cycles",
              *[f"{cause}_{kind}" for kind in ("raw", "exclusive") for cause in CAUSES], "image_sha256", "code_sha256"]
    with (output / "measurements.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, extrasaction="ignore", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    lines = ["# Architecture measurements", "", f"Status: **{summary['status']}**", "",
             "[Measurements](measurements.csv) | [Source, tools and overlap histograms](summary.json)", "",
             "| Workload | Profile | Optimization | Cycles | Retired | CPI |", "| --- | --- | --- | ---: | ---: | ---: |"]
    for row in rows:
        if row["status"] == "passed":
            label = row["workload"] if row["workload"] != "matvec_driver" else f"{row['scenario']} {row['rows']}x4 x {row['jobs']} jobs ({row['method']})"
            lines.append(f"| {label} | {row['profile']} | {row['optimization']} | {row['cycles']:,} | {row['retired']:,} | {row['cpi']:.3f} |")
    if summary.get("error"):
        lines.extend(["", "Error: " + summary["error"]])
    (output / "RESULTS.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def check_icache_comparisons(cases):
    """Each comparison must use one binary and retire the same instructions."""
    groups = {}
    for row in cases:
        groups.setdefault((row["workload"], row["optimization"]), []).append(row)
    for key, rows in groups.items():
        if sorted(row["profile"] for row in rows) != sorted(ICACHE_PROFILES):
            raise RuntimeError(f"incomplete I-cache comparison: {key}")
        for field in ("image_sha256", "retired", "dcache_misses"):
            if len({row[field] for row in rows}) != 1:
                raise RuntimeError(f"I-cache comparison changed {field}: {key}")
        # Both 64-byte implementations must be cycle-equivalent, not just
        # produce the same algorithm answer.
        reference = next(row for row in rows if row["profile"] == "parallel64")
        indexed = next(row for row in rows if row["profile"] == "indexed64")
        if any(reference[field] != indexed[field] for field in COUNTERS):
            raise RuntimeError(f"64-byte implementations changed cycle behavior: {key}")


def check_dcache_comparisons(cases):
    groups = {}
    for row in cases:
        groups.setdefault((row["workload"], row["optimization"]), []).append(row)
    for key, rows in groups.items():
        if sorted(row["profile"] for row in rows) != sorted(DCACHE_PROFILES):
            raise RuntimeError(f"incomplete D-cache comparison: {key}")
        for field in ("image_sha256", "retired"):
            if len({row[field] for row in rows}) != 1:
                raise RuntimeError(f"D-cache comparison changed {field}: {key}")
        for row in rows:
            if (row["dcache_bytes"], row["dcache_victim_lines"]) != DCACHE_PROFILES[row["profile"]]:
                raise RuntimeError(f"D-cache profile geometry mismatch: {key}")
            if row["data_line_fills"] + row["victim_hits"] != row["dcache_misses"]:
                raise RuntimeError(f"primary misses do not reconcile with fills/victim hits: {key}")
    for optimization in ("O2", "Os"):
        hashes = {row["code_sha256"] for row in cases
                  if row["workload"] in MEMORY_SCENARIOS and row["optimization"] == optimization}
        if len(hashes) > 1:
            raise RuntimeError(f"memory scenarios changed code bytes: {optimization}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toolchain-bin", default=os.environ.get("RISCV_TOOLCHAIN_BIN"))
    parser.add_argument("--prefix", default=os.environ.get("RISCV_PREFIX", "riscv64-unknown-elf-"))
    parser.add_argument("--smoke", action="store_true", help="isolated small matrix for harness checks")
    parser.add_argument("--external-dmem", action="store_true", help="use the board's synchronous DMEM backend, scaled to 16 KiB")
    parser.add_argument("--icache-study", action="store_true", help="fixed fast CPU; compare I-cache organization/capacity with synchronous DMEM")
    parser.add_argument("--memory-screen", action="store_true", help="screen D-cache locality using the saved, hash-checked I-cache baseline traces")
    parser.add_argument("--dcache-study", action="store_true", help="fixed 1 KiB I-cache and fast CPU; compare 64/128-byte direct-mapped and 1/2/4/8 victim lines")
    parser.add_argument("--memory-latency", type=int, choices=(0, 4, 12), default=0,
                        help="with --dcache-study: extra BRAM-request wait cycles; nonzero selects four representative workloads")
    args = parser.parse_args()
    if args.memory_screen:
        if args.smoke or args.external_dmem or args.icache_study or args.dcache_study or args.memory_latency:
            parser.error("--memory-screen reads existing evidence; do not combine it with simulation flags")
        from dcache_analysis import screen
        output = ROOT / "results/architecture/dcache-screen"
        screen(ROOT, ROOT / "results/architecture/icache-complete-external/summary.json", output)
        print(f"PASS: D-cache locality screening; see {output / 'RESULTS.md'}")
        return 0
    if args.icache_study and args.dcache_study:
        parser.error("select one cache study at a time")
    if args.memory_latency and not args.dcache_study:
        parser.error("--memory-latency requires --dcache-study")
    cache_study = args.icache_study or args.dcache_study
    workload_names = (*compiled.CASES, *WORKLOADS, *MEMORY_SCENARIOS) if args.dcache_study else (*compiled.CASES, *WORKLOADS)
    if args.memory_latency:
        workload_names = ("fir", "sequential", "conflict", "mixed_stride80")
    if cache_study:
        args.external_dmem = True
    context = "smoke" if args.smoke else "complete"
    if args.external_dmem:
        context += "-external"
    profiles = {name: values for name, values in PROFILES.items()
                if not args.external_dmem or name != "fast_ideal_memory"}
    parameters = PARAMETERS
    if args.icache_study:
        context = "icache-" + context
        parameters += ("ICACHE_BYTES", "ICACHE_PARALLEL_LOOKUP")
        profiles = {name: PROFILES["fast_cpu"] + geometry for name, geometry in ICACHE_PROFILES.items()}
    elif args.dcache_study:
        context = (f"dcache-latency{args.memory_latency}-" if args.memory_latency else "dcache-") + context
        parameters += ("ICACHE_BYTES", "ICACHE_PARALLEL_LOOKUP", "DCACHE_BYTES", "DCACHE_VICTIM_LINES")
        profiles = {name: PROFILES["fast_cpu"] + (1024, 0, *geometry) for name, geometry in DCACHE_PROFILES.items()}
    build, output = ROOT / "build/architecture" / context, ROOT / "results/architecture" / context
    build.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    lock = RunLock(build / "running.lock")
    summary = {"status": "running", "started_at_utc": datetime.now(timezone.utc).isoformat(),
               "profiles": {name: dict(zip(parameters, values), EXTERNAL_DMEM=int(args.external_dmem),
                                       EXTERNAL_IMEM=int(cache_study), DMEM_EXTRA_WAIT=args.memory_latency) for name, values in profiles.items()},
               "cases": [], "memory_model": ("external_dmem_bram scaled to 16 KiB; internal IMEM" if args.external_dmem else
                                                "internal Harvard RAM, one-cycle cache refill; ideal_memory removes caches"),
               "stall_priority": list(CAUSES)}
    summary["planned_cases"] = (7 if args.external_dmem else 8) if args.smoke else (180 if args.external_dmem else 200)
    if cache_study:
        summary["memory_model"] = "asynchronous external IMEM handshake model and external_dmem_bram; both scaled to 16 KiB"
        summary["planned_cases"] = len(profiles) * (1 if args.smoke else 2 * len(workload_names))
        summary["controlled_variables"] = {"icache_ways": 2, "line_bytes": 16, "dcache_bytes": 64,
            "icache_replacement": "invalid way first, then per-set LRU", "fast_multiply": True,
            "branch_prediction": True, "accelerators": False,
            "interval": "retired benchmark markers, otherwise main to program_done",
            "initial_state": "reset before each run; initialization before the interval may warm caches",
            "imem_refill": "ready in the request cycle, matching the boot-complete board IMEM interface; UART boot is not simulated",
            "scope": "cycle-accurate simulation, not physical-board elapsed time"}
        if args.dcache_study:
            del summary["controlled_variables"]["dcache_bytes"]
            summary["memory_scenarios"] = {name: dict(zip(("lines", "stride_words", "offset_words", "write_period"), values))
                                           for name, values in MEMORY_SCENARIOS.items()}
            summary["controlled_variables"].update(icache_bytes=1024, icache_parallel_lookup=0,
                dcache_primary_bytes="64 or 128, per profile", victim_line_bytes=16,
                dcache_primary_mapping="direct-mapped",
                victim_replacement="exclusive LRU buffer; hit swaps with primary and moves outgoing line to MRU",
                dmem_extra_wait_cycles=args.memory_latency,
                latency_scope="extra serialized request wait; not a DDR controller or bandwidth model",
                counter_semantics="dcache_misses counts primary misses; data_line_fills counts completed backing refills")
    try:
        save(summary, output)
        summary["source"] = source_identity()
        tools = {name: compiled.find_tool(args.prefix + name, args.toolchain_bin) for name in ("gcc", "objcopy", "objdump", "nm")}
        tools.update({name: compiled.find_tool(name) for name in ("iverilog", "vvp")})
        import unicorn
        summary["reference_version"] = unicorn.__version__
        summary["tools"] = {name: {"path": path, "version": compiled.run(
            [path, "-V" if name in ("iverilog", "vvp") else "--version"], output / f"{name}-version.log").splitlines()[0]}
            for name, path in tools.items()}
        sources = [line.strip() for line in (ROOT / "fpga/fpga_sources.f").read_text().splitlines() if line.strip() and not line.startswith("#")]
        executables = {}
        for profile, values in profiles.items():
            executable = build / f"{profile}.vvp"
            compiled.run([tools["iverilog"], "-g2012", "-s", "tb_architecture_benchmark",
                          *[f"-Ptb_architecture_benchmark.{key}={value}" for key, value in zip(parameters, values)],
                          f"-Ptb_architecture_benchmark.EXTERNAL_DMEM={int(args.external_dmem)}",
                          f"-Ptb_architecture_benchmark.EXTERNAL_IMEM={int(cache_study)}",
                          f"-Ptb_architecture_benchmark.DMEM_EXTRA_WAIT={args.memory_latency}",
                          "-o", str(executable), *sources, "tb/reference/tb_architecture_benchmark.v"], output / "build" / f"{profile}.log")
            executables[profile] = executable
        for name in (("fir",) if args.smoke else workload_names):
            for optimization in (("O2",) if args.smoke else ("O2", "Os")):
                image, symbols = build_workload(tools, name, optimization, build, output)
                reference_trace, reference_memory = compiled.run_reference(bytes(image), symbols["program_done"], symbols["__text_end"])
                signature = list(struct.unpack_from("<16I", reference_memory, 0x800))
                expected = [expected_workload(name)] + [0] * 15 if name in WORKLOADS or name in MEMORY_SCENARIOS else compiled.expected_signature(name)
                if signature != expected:
                    raise RuntimeError(f"algorithm oracle mismatch: {name}")
                for profile in (profiles if cache_study else ("iterative_cpu", "fast_cpu", "fast_no_prediction", "fast_ideal_memory")):
                    if profile not in profiles:
                        continue
                    label = f"{name}-{optimization}-{profile}"
                    summary["active_case"] = label
                    counters, trace, memory = simulate(tools, executables[profile], image, symbols, build / label, output / label)
                    compiled.compare_trace(reference_trace, trace)
                    compiled.compare_memory(reference_memory, memory)
                    geometry = ICACHE_PROFILES[profile] if args.icache_study else (64, 1)
                    if args.dcache_study:
                        geometry = (1024, 0)
                        from dcache_analysis import evaluate, memory_accesses
                        accesses = memory_accesses(reference_trace, symbols.get("benchmark_begin", symbols["main"]),
                                                   symbols.get("benchmark_end", symbols["program_done"]))
                        primary_bytes, victims = DCACHE_PROFILES[profile]
                        expected_cache = evaluate(accesses, primary_bytes, victims=victims)
                        for hardware, model in (("dcache_misses", "primary_misses"), ("data_line_fills", "line_fills"),
                                                ("data_writebacks", "writebacks"), ("victim_hits", "victim_hits")):
                            if counters[hardware] != expected_cache[model]:
                                raise RuntimeError(f"cache model/RTL mismatch {label} {hardware}: {counters[hardware]} != {expected_cache[model]}")
                    summary["cases"].append(dict(workload=name, optimization=optimization, profile=profile,
                                                icache_bytes=geometry[0], icache_parallel_lookup=geometry[1],
                                                dcache_bytes=DCACHE_PROFILES[profile][0] if args.dcache_study else 64,
                                                dcache_victim_lines=DCACHE_PROFILES[profile][1] if args.dcache_study else 0,
                                                status="passed", **counters))
                    save(summary, output)
                    print(f"PASS {label}: {counters['cycles']} cycles", flush=True)
        programs = {} if cache_study else {method: matvec.build_program(tools, method, build / "matvec", output / "matvec") for method in matvec.METHODS}
        for scenario in (() if cache_study else (("stream",) if args.smoke else matvec.SCENARIOS)):
            for rows in ((4,) if args.smoke else matvec.ROWS):
                for jobs in ((1,) if args.smoke else matvec.JOBS):
                    matrix, vectors, expected = matvec.workload(rows, jobs, scenario)
                    for profile, method in (("iterative_cpu", "software"), ("fast_cpu", "software"),
                                            ("fast_scratchpad", "scratchpad"), ("fast_dma", "dma")):
                        raw, symbols = programs[method]
                        image = bytearray(16384)
                        image[:len(raw)] = raw
                        struct.pack_into("<3I", image, symbols["benchmark_config"], rows, jobs, int(scenario == "reuse"))
                        struct.pack_into("<128I", image, symbols["benchmark_matrix"], *matrix)
                        struct.pack_into("<8I", image, symbols["benchmark_vectors"], *vectors)
                        label = f"{scenario}-r{rows}-j{jobs}-{profile}"
                        summary["active_case"] = label
                        counters, trace, memory = simulate(tools, executables[profile], image, symbols, build / label, output / label)
                        matvec.check_memory(memory, symbols, matrix, vectors, expected)
                        if counters["compute_cycles"] != (0 if method == "software" else 2 * rows * jobs):
                            raise RuntimeError("accelerator arithmetic cycle mismatch")
                        summary["cases"].append(dict(workload="matvec_driver", optimization="O2", profile=profile,
                                                     scenario=scenario, rows=rows, jobs=jobs, method=method,
                                                     status="passed", **counters))
                        save(summary, output)
                        print(f"PASS {label}: {counters['cycles']} cycles", flush=True)
        if len(summary["cases"]) != summary["planned_cases"]:
            raise RuntimeError("incomplete experiment matrix")
        if args.icache_study:
            check_icache_comparisons(summary["cases"])
        if args.dcache_study:
            check_dcache_comparisons(summary["cases"])
        if source_identity()["input_fingerprint"] != summary["source"]["input_fingerprint"]:
            raise RuntimeError("source changed during measurement")
        summary["artifacts"] = {path.relative_to(output).as_posix(): matvec.sha256(path)
                                for path in sorted(output.rglob("*")) if path.is_file() and path.suffix in (".log", ".hex", ".txt")}
        summary["status"] = "passed"
        summary.pop("active_case", None)
    except Exception as error:
        summary["status"] = "failed"
        summary["error"] = str(error)
        print(f"FAIL: {error}", file=sys.stderr)
    finally:
        summary["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
        save(summary, output)
        lock.close()
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
