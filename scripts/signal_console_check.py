"""Build the FIR firmware and check full-SoC UART sessions against a Python oracle."""
import argparse
import hashlib
import json
import random
import re
import statistics
import struct
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

from compiled_programs import ROOT, find_tool, run, simulator_file
from execution_context import RunLock, parse_symbols
from result_json import write_result_json
from signal_console import (Client, boot, config_payload, sample_payload, request_frame,
                            encode_frame, decode_frame, parse_response, send_frame, receive_frame)

BUILD = ROOT / "build/signal-console"
RESULTS = ROOT / "results/signal-console"


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs():
    names = ["firmware/c/signal_console.c", "firmware/c/board.ld", "firmware/c/start.S",
             "scripts/signal_console.py", "scripts/signal_console_check.py",
             "scripts/tests/test_signal_console.py",
             "scripts/architecture_benchmark.py",
             "scripts/compiled_programs.py", "scripts/execution_context.py", "scripts/result_json.py",
             "tb/reference/tb_signal_console.v", "fpga/fpga_sources.f"]
    names += [line.strip() for line in (ROOT / "fpga/fpga_sources.f").read_text().splitlines()
              if line.strip() and not line.strip().startswith("#")]
    return {name: sha256(ROOT / name) for name in sorted(set(names))}


def build(toolchain):
    gcc = find_tool("riscv64-unknown-elf-gcc", toolchain)
    objcopy = find_tool("riscv64-unknown-elf-objcopy", toolchain)
    nm = find_tool("riscv64-unknown-elf-nm", toolchain)
    elf = BUILD / "program.elf"
    binary = BUILD / "program.bin"
    for old in (elf, binary, BUILD / "program.boot.bin"):
        old.unlink(missing_ok=True)
    run([gcc, "-std=c11", "-march=rv32im", "-mabi=ilp32", "-mno-relax", "-mstrict-align",
         "-msmall-data-limit=0", "-ffreestanding", "-fno-builtin", "-fno-pic", "-fno-stack-protector",
         "-nostdlib", "-nostartfiles", "-Wall", "-Wextra", "-Werror", "--param=min-pagesize=0",
         "-fno-jump-tables", "-Os", "-fstack-usage", "-Wl,--no-relax,--build-id=none",
         "-T", "firmware/c/board.ld", "firmware/c/start.S", "firmware/c/signal_console.c",
         "-o", str(elf)], RESULTS / "gcc.log")
    run([objcopy, "-O", "binary", str(elf), str(binary)], RESULTS / "objcopy.log")
    data = binary.read_bytes()
    if not data or len(data) > 4096 or len(data) % 4:
        raise RuntimeError("firmware must fit aligned 4-KiB IMEM")
    words = struct.unpack(f"<{len(data)//4}I", data)
    packet = struct.pack("<5I", 0x52564254, 1, 0, len(words), sum(words) & 0xffffffff) + data
    (BUILD / "program.boot.bin").write_bytes(packet)
    symbols = parse_symbols(run([nm, str(elf)], RESULTS / "symbols.log"))
    return {"imem_bytes": len(data), "bss_bytes": symbols["__bss_end"] - symbols["__bss_start"],
            "stack_space_bytes": symbols["__stack_top"] - symbols["__bss_end"],
            "packet_sha256": sha256(BUILD / "program.boot.bin"), "elf_sha256": sha256(elf),
            "compiler": run([gcc, "--version"], RESULTS / "compiler.log").splitlines()[0]}


class Session:
    """Algorithm-level reference: append past samples, then evaluate the FIR sum."""
    def __init__(self):
        self.coefficients = [1] * 4
        self.scale = 2
        self.threshold = 1000
        self.samples = []
        self.events = 0
        self.gpio = 0

    def status(self):
        return {"coefficients": self.coefficients[:], "scale": self.scale, "threshold": self.threshold,
                "samples_processed": len(self.samples), "threshold_events": self.events,
                "gpio": self.gpio, "switches": 0xa55a, "uart_overrun": False, "batch_limit": 32}

    def clear(self):
        self.samples = []
        self.events = 0
        self.gpio &= 0xfe

    def data(self, values):
        outputs = []
        for value in values:
            self.samples.append(value)
            recent = self.samples[-len(self.coefficients):][::-1]
            total = sum(c * x for c, x in zip(self.coefficients, recent))
            magnitude = abs(total) // (2 ** self.scale)
            outputs.append(-magnitude if total < 0 else magnitude)
        events = sum(y >= self.threshold for y in outputs)
        self.events += events
        self.gpio = (self.gpio & 0xfe) | bool(events)
        return {"outputs": outputs, "threshold_events": events, "gpio": self.gpio}


def test_plan():
    commands, expected = [], []
    state = Session()

    def exchange(command, payload=b"", answer=None, wire=None, error=0):
        seq = len(expected) & 255
        wire = request_frame(seq, command, payload) if wire is None else wire
        commands.extend(wire)
        commands.append(0x100)
        expected.append({"sequence": seq, "command": command, "error": error,
                         "answer": state.status() if answer is None else answer,
                         "gpio": state.gpio})

    def config(coefficients, scale, threshold):
        state.coefficients, state.scale, state.threshold = coefficients, scale, threshold
        state.clear()
        exchange("C", config_payload(coefficients, scale, threshold))

    def data(values):
        exchange("D", sample_payload(values), state.data(values))

    exchange("S")
    state.gpio = 0xaa
    exchange("L", b"\xaa")
    data([0, 4, 8, 12, 4000, -4000])
    data([12, 8, 4, 0])
    exchange("S")
    state.clear()
    exchange("R")
    data([0])
    randomizer = random.Random(20261001)
    for coefficients, scale, threshold in [([1, -1], 0, 0), ([-128] * 8, 0, 1000000),
                                            ([127] * 8, 15, -1), ([125, 126, -3], 2, 250)]:
        config(coefficients, scale, threshold)
        data([-32768, 32767, -1, 0, 1, 125, 126, 32125])
        data([randomizer.randint(-32768, 32767) for _ in range(32)])
        data([randomizer.randint(-32768, 32767) for _ in range(7)])
        exchange("S")
    # Rejections must leave filter history/configuration/counters unchanged.
    exchange("?", error=3)
    for command, payload in [("D", b""), ("D", b"\x00"), ("D", bytes(66)),
                             ("C", b"\x00" * 7), ("C", b"\x09" + bytes(14)),
                             ("C", b"\x01\x10" + bytes(5)), ("R", b"\x00"), ("L", b"")]:
        exchange(command, payload, error=2)
    seq = len(expected)
    corrupted = bytearray(request_frame(seq, "D", b"\x00\x00"))
    corrupted[4] ^= 1
    exchange("D", wire=bytes(corrupted), error=1)
    seq = len(expected)
    exchange("D", wire=encode_frame(bytes([seq, ord("D"), 8, 0, 0])), error=1)
    seq = len(expected)
    exchange("D", wire=bytes([0x7e, seq, ord("D"), 0x7d, 0x7e]), error=1)
    seq = len(expected)
    exchange("D", wire=encode_frame(bytes([seq, ord("D"), 0]) + bytes(180)), error=1)
    exchange("S")
    data([11, -13, 27])
    # A board reset reloads firmware and reinitializes retained data RAM.
    commands.append(0x101)
    state = Session()
    exchange("S")
    data([4, 4, 4, 4])
    return commands, expected


def simulate(fast, cache=None):
    cache = cache or {"ICACHE_BYTES": 64, "ICACHE_PARALLEL_LOOKUP": 1, "DCACHE_BYTES": 64, "DCACHE_VICTIM_LINES": 0}
    label = "fast" if fast else "iterative"
    if cache != {"ICACHE_BYTES": 64, "ICACHE_PARALLEL_LOOKUP": 1, "DCACHE_BYTES": 64, "DCACHE_VICTIM_LINES": 0}:
        label += f"-i{cache['ICACHE_BYTES']}-p{cache['ICACHE_PARALLEL_LOOKUP']}-d{cache['DCACHE_BYTES']}-v{cache['DCACHE_VICTIM_LINES']}"
    directory = RESULTS / label
    directory.mkdir(parents=True, exist_ok=True)
    commands, expected = test_plan()
    stimulus = BUILD / "commands.hex"
    stimulus.write_text("".join(f"{value:03x}\n" for value in commands), encoding="ascii")
    executable = BUILD / f"console-{label}.vvp"
    run([find_tool("iverilog"), "-g2012", "-s", "tb_signal_console",
         f"-Ptb_signal_console.FAST_MULTIPLY={fast}", "-o", str(executable),
         *[f"-Ptb_signal_console.{key}={value}" for key, value in cache.items()],
         "-f", "fpga/fpga_sources.f", "tb/reference/tb_signal_console.v"], directory / "compile.log")
    capture = directory / "responses.txt"
    capture.unlink(missing_ok=True)
    run([find_tool("vvp"), str(executable), f"+packet={simulator_file(BUILD/'program.boot.bin')}",
         f"+script={simulator_file(stimulus)}", f"+output={simulator_file(capture)}"],
        directory / "simulation.log", timeout=600)
    lines = capture.read_text().splitlines()
    if len(lines) != len(expected):
        raise RuntimeError("missing or extra responses")
    rows = []
    for line, case in zip(lines, expected):
        encoded, gpio = line.split()
        wire = bytes.fromhex(encoded)
        body = decode_frame(wire)
        if int(gpio, 16) != case["gpio"]:
            raise RuntimeError(f"physical LED mismatch for {case}")
        if case["error"]:
            if body != bytes([case["sequence"], ord(case["command"]), case["error"], 0]):
                raise RuntimeError(f"incorrect rejection for {case}")
            result = {"rejected": case["error"]}
        else:
            result = parse_response(wire, case["sequence"], case["command"])
            cycles = result.pop("compute_cycles", None)
            if result != case["answer"] or (cycles is not None and not 0 < cycles < 1000000):
                raise RuntimeError(f"response mismatch: {case}; got {result}; cycles={cycles}")
            if cycles is not None:
                result["compute_cycles"] = cycles
        rows.append({"command": case["command"], **result})
    write_result_json(rows, directory / "responses.json")
    return {"profile": "fast_cpu" if fast else "iterative_cpu", "cache": cache, "directory": label,
            "commands_checked": len(rows),
            "samples_checked": sum(len(row.get("outputs", [])) for row in rows),
            "rejections_checked": sum("rejected" in row for row in rows),
            "capture_sha256": sha256(capture), "results_sha256": sha256(directory / "responses.json")}


def physical_session(port_name, session_name, expected_switches, cache=None, programming=None):
    """Use the same independent oracle with physical serial I/O and paced bursts."""
    import serial
    from serial.tools.list_ports import comports
    path = RESULTS / "board-burst" / (session_name + ".json")
    report = {"status": "running", "started_at_utc": datetime.now(timezone.utc).isoformat(),
              "port": port_name,
              "usb_identity": [p.hwid for p in comports() if p.device == port_name],
              "responses": [], "stress": [], "client_examples": []}
    write_result_json(report, path)
    try:
        saved = json.loads((RESULTS / "summary.json").read_text())
        source = inputs()
        packet = BUILD / "program.boot.bin"
        if saved["status"] != "passed" or saved["inputs"] != source or sha256(packet) != saved["firmware"]["packet_sha256"]:
            raise RuntimeError("run passing source-matched simulation before the physical session")
        cache = cache or {"ICACHE_BYTES": 64, "ICACHE_PARALLEL_LOOKUP": 1, "DCACHE_BYTES": 64, "DCACHE_VICTIM_LINES": 0}
        if not any(row["profile"] == "fast_cpu" and row.get("cache") == cache for row in saved["sessions"]):
            raise RuntimeError("the selected cache configuration has no passing full-SoC UART simulation")
        report["cache"] = cache
        if programming:
            report["programming"] = programming
        report.update(inputs=source, packet_sha256=sha256(packet))
        commands, cases = test_plan()
        with serial.Serial(port_name, 115200, timeout=3, write_timeout=3) as port:
            boot(port, packet)
            report["boot_greeting"] = "FIR2\n"
            switches = None
            request = bytearray()
            for token in commands:
                if token == 0x101:
                    break
                if token != 0x100:
                    request.append(token)
                    continue
                case = cases[len(report["responses"])]
                start = time.perf_counter()
                send_frame(port, bytes(request))
                wire = receive_frame(port)
                row = {"sequence": case["sequence"], "command": case["command"],
                       "request_hex": request.hex(), "response_hex": wire.hex(),
                       "round_trip_ms": round((time.perf_counter() - start) * 1000, 3)}
                report["responses"].append(row)
                if case["error"]:
                    if decode_frame(wire) != bytes([case["sequence"], ord(case["command"]), case["error"], 0]):
                        raise RuntimeError("incorrect physical rejection")
                    row["result"] = {"rejected": case["error"]}
                else:
                    actual = parse_response(wire, case["sequence"], case["command"])
                    row["result"] = dict(actual)
                    cycles = actual.pop("compute_cycles", None)
                    answer = dict(case["answer"])
                    if "switches" in answer:
                        if switches is None:
                            switches = actual["switches"]
                            if expected_switches is not None and switches != expected_switches:
                                raise RuntimeError("physical switch change mismatch")
                        answer["switches"] = switches
                    if actual != answer or (cycles is not None and not 0 < cycles < 1000000):
                        raise RuntimeError(f"physical response mismatch: {case}; {actual}")
                row["status"] = "passed"
                write_result_json(report, path)
                request.clear()

            client = Client(port)
            client.synchronize()
            model = Session()
            model.coefficients, model.scale, model.threshold = [-128] * 8, 0, 1000000
            client.exchange("C", config_payload(model.coefficients, model.scale, model.threshold))
            generator = random.Random(20261001)
            for batch in range(200):
                # Include framing bytes at high frequency as well as signed extremes.
                values = ([0x7d7e, -32768, 32767, 0] * 8 if batch % 10 == 0 else
                          [generator.randint(-32768, 32767) for _ in range(32)])
                expected = model.data(values)
                result = client.exchange("D", sample_payload(values))
                if any(result[key] != expected[key] for key in ("outputs", "threshold_events")):
                    raise RuntimeError(f"stress batch mismatch: {batch}")
                report["stress"].append({"batch": batch, "inputs": values, **result})
            status = client.exchange("S")
            if status["samples_processed"] != 6400 or status["threshold_events"] != model.events or status["uart_overrun"]:
                raise RuntimeError("stress counters or UART overrun mismatch")
            report["stress_status"] = status

            for command, payload, expected in [
                    ("C", config_payload([1] * 4, 2, 5), None), ("L", b"\xaa", None),
                    ("D", sample_payload([0, 4, 8, 12]), [0, 1, 3, 6]),
                    ("D", sample_payload([16, 20]), [10, 14])]:
                result = client.exchange(command, payload)
                report["client_examples"].append({"command": command, "result": result})
                if expected is not None and (result["outputs"] != expected or result["gpio"] != 0xab):
                    raise RuntimeError("interactive example mismatch")
            report["final_status"] = client.exchange("S")
            status = report["final_status"]
            if (status["samples_processed"] != 6 or status["threshold_events"] != 3 or
                    status["gpio"] != 0xab or status["switches"] != switches or status["uart_overrun"]):
                raise RuntimeError("final interactive status mismatch")
            report["switches"] = switches
        if inputs() != source:
            raise RuntimeError("source changed during physical session")
        report["test_commands_checked"] = len(report["responses"])
        report["test_samples_checked"] = sum(len(r["result"].get("outputs", [])) for r in report["responses"])
        report["rejections_checked"] = sum("rejected" in r["result"] for r in report["responses"])
        report["stress_batches_checked"] = len(report["stress"])
        report["stress_samples_checked"] = 6400
        report["client_samples_checked"] = 6
        report["status"] = "passed"
    except Exception as error:
        report["status"] = "failed"
        report["error"] = str(error)
        raise
    finally:
        report["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
        write_result_json(report, path)
    print(f"PASS: {report['test_commands_checked']} commands, 202 test + 6400 stress + 6 example outputs; "
          f"switches={switches:#06x}; see {path}")


def check_viewer_case(client, preset, source, batches, output=None):
    """Check every returned sample; keep only the normal bounded viewer capture."""
    from signal_viewer import PRESETS, StreamSession, SignalPlot, save_snapshot
    session = StreamSession(client, preset, source, 300, 700, 1)
    model = Session()
    model.coefficients, model.scale = PRESETS[preset]
    model.threshold = 700
    latencies = []
    for batch in range(batches):
        result = session.next_batch()
        values = [r["input"] for r in list(session.records)[-32:]]
        expected = model.data(values)
        if result["outputs"] != expected["outputs"] or result["threshold_events"] != expected["threshold_events"]:
            raise RuntimeError(f"viewer output mismatch: {preset}/{source}, batch {batch}")
        latencies.append(result["round_trip_ms"])
    session.check_status()
    if len(session.records) != min(512, batches * 32):
        raise RuntimeError("viewer history was not bounded to 512 samples")
    if output is not None:
        from matplotlib.backends.backend_agg import FigureCanvasAgg
        plot = SignalPlot()
        FigureCanvasAgg(plot.figure)
        save_snapshot(session, plot, output, client.port.port)
    return {"status": "passed", "preset": preset, "source": source, "batches": batches,
            "samples_checked": batches * 32, "round_trip_ms_median": round(statistics.median(latencies), 3),
            "final_status": session.device}


def physical_viewer_session(port_name, programming=None):
    import serial
    from signal_viewer import PRESETS
    report = {"status": "running", "started_at_utc": datetime.now(timezone.utc).isoformat(),
              "port": port_name, "cases": [], "planned_cases": 10,
              "case_unit": "sessions", "noise": 300, "threshold": 700, "seed": 1}
    if programming:
        report["programming"] = programming
    path = RESULTS / "viewer-validation.json"
    write_result_json(report, path)
    try:
        saved = json.loads((RESULTS / "summary.json").read_text())
        source = inputs()
        packet = BUILD / "program.boot.bin"
        if (saved["status"] != "passed" or saved["inputs"] != source or
                sha256(packet) != saved["firmware"]["packet_sha256"]):
            raise RuntimeError("run passing source-matched simulation before physical viewer validation")
        source.update({name: sha256(ROOT / name) for name in
                       ("scripts/signal_viewer.py", "scripts/tests/test_signal_viewer.py")})
        report.update(inputs=source, packet_sha256=sha256(packet),
                      source_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip())
        with serial.Serial(port_name, 115200, timeout=3, write_timeout=3) as port:
            boot(port, packet)
            client = Client(port)
            client.synchronize()
            capture = RESULTS / "viewer-checked"
            report["cases"].append(check_viewer_case(client, "average4", "sine", 16, capture))
            report["files"] = {"viewer-checked" + ext: sha256(capture.with_suffix(ext))
                               for ext in (".csv", ".png", ".json")}
            for preset in PRESETS:
                for signal in ("sine", "step"):
                    report["cases"].append(check_viewer_case(client, preset, signal, 16))
                    write_result_json(report, path)
            report["cases"].append(check_viewer_case(client, "average8", "sine", 128))
        if any(sha256(ROOT / name) != value for name, value in source.items()) or sha256(packet) != report["packet_sha256"]:
            raise RuntimeError("viewer validation inputs changed during execution")
        report["samples_checked"] = sum(case["samples_checked"] for case in report["cases"])
        report["status"] = "passed"
    except Exception as error:
        report.update(status="failed", error=str(error))
        raise
    finally:
        report["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
        write_result_json(report, path)
    print(f"PASS: {len(report['cases'])} viewer sessions; {report['samples_checked']} independently checked outputs")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--toolchain-bin")
    parser.add_argument("--cache-study", action="store_true", help="also simulate all six D-cache study profiles with the 1 KiB I-cache")
    parser.add_argument("--port", help="upload and test on this physical port after board reset")
    parser.add_argument("--session", default="initial", help="output label: letters, digits, hyphen or underscore")
    parser.add_argument("--program", action="store_true", help="explicitly load the volatile FPGA image before UART tests; never writes Flash")
    parser.add_argument("--build-summary", type=Path, help="fast_cpu FPGA build record; used with --port --program")
    parser.add_argument("--xsdb", default="xsdb", help="XSDB executable for --program")
    parser.add_argument("--expected-switches", type=lambda value: int(value, 0))
    parser.add_argument("--viewer", action="store_true", help="with --port: upload and validate all viewer presets and a sustained stream")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", args.session):
        parser.error("--session must be 1-64 letters, digits, hyphens or underscores")
    if args.program and not args.port:
        parser.error("--program requires --port")
    if args.build_summary and not args.program:
        parser.error("--build-summary requires --program so the tested FPGA image is identified")
    if args.viewer and not args.port:
        parser.error("--viewer requires --port and a board reset before upload")
    if args.port:
        if args.build_only:
            parser.error("--port and --build-only are mutually exclusive")
        lock = RunLock(BUILD / "run.lock")
        try:
            cache, programming = None, None
            if args.program:
                from signal_start import TIMING, application_image, firmware_ready, program_image
                timing = (args.build_summary or TIMING).resolve()
                firmware_ready()
                bitstream = application_image(timing)
                build_record = json.loads(timing.read_text(encoding="utf-8-sig"))
                cache = {key: build_record.get(key.lower(), default) for key, default in
                         (("ICACHE_BYTES", 64), ("ICACHE_PARALLEL_LOOKUP", 1),
                          ("DCACHE_BYTES", 64), ("DCACHE_VICTIM_LINES", 0))}
                saved = json.loads((RESULTS / "summary.json").read_text())
                if saved["status"] != "passed" or not any(
                        row["profile"] == "fast_cpu" and row.get("cache") == cache for row in saved["sessions"]):
                    raise RuntimeError("run the selected full-SoC UART simulation before programming")
                record = RESULTS / "board-burst" / (args.session + "-programming.json")
                program_image(bitstream, args.xsdb, timing_path=timing, output=record)
                programming = {"record": record.relative_to(ROOT).as_posix(), "sha256": sha256(record),
                               "bitstream_sha256": sha256(bitstream), "cache": cache}
            if args.viewer:
                physical_viewer_session(args.port, programming)
            else:
                physical_session(args.port, args.session, args.expected_switches, cache, programming)
        finally:
            lock.close()
        return
    BUILD.mkdir(parents=True, exist_ok=True)
    lock = RunLock(BUILD / "run.lock")
    summary = {"status": "running", "started_at_utc": datetime.now(timezone.utc).isoformat()}
    path = RESULTS / "summary.json"
    overview = RESULTS / "RESULTS.md"
    overview.unlink(missing_ok=True)
    write_result_json(summary, path)
    try:
        summary["inputs"] = inputs()
        summary["source_commit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        summary["working_tree_dirty"] = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip())
        summary["firmware"] = build(args.toolchain_bin)
        summary["sessions"] = [] if args.build_only else [simulate(1), simulate(0)]
        if args.cache_study and not args.build_only:
            from architecture_benchmark import DCACHE_PROFILES
            summary["sessions"] += [simulate(1, {"ICACHE_BYTES": 1024, "ICACHE_PARALLEL_LOOKUP": 0,
                                               "DCACHE_BYTES": primary, "DCACHE_VICTIM_LINES": count})
                                    for primary, count in DCACHE_PROFILES.values()]
        if summary["inputs"] != inputs():
            raise RuntimeError("source changed during execution")
        summary["status"] = "built" if args.build_only else "passed"
        firmware = summary["firmware"]
        lines = ["# Signal console results", "", f"Status: **{summary['status']}**.", "",
                 f"Firmware: {firmware['imem_bytes']} / 4096 instruction bytes; "
                 f"{firmware['bss_bytes']} static data bytes; {firmware['stack_space_bytes']} bytes above BSS.", "",
                 "| CPU profile | Commands | Samples | Rejected packets | Details |",
                 "| --- | ---: | ---: | ---: | --- |"]
        for session in summary["sessions"]:
            folder = session["directory"]
            lines.append(f"| {folder} | {session['commands_checked']} | {session['samples_checked']} | "
                         f"{session['rejections_checked']} | [responses]({folder}/responses.json) |")
        lines += ["", "All configurations use serial boot and UART pins, GPIO outputs, synchronous BRAM, and a board reset/reboot.",
                  "Compute cycles cover the FIR loop; physical UART round-trip time is printed by the interactive client.",
                  "", "[Source hashes and compiler identity](summary.json). Repeating the command overwrites this run's files."]
        if args.build_only:
            lines = lines[:5] + ["", "Simulation was not requested.", "", "[Build identity](summary.json)."]
        overview.write_text("\n".join(lines) + "\n", encoding="utf-8")
    except Exception as error:
        summary["status"] = "failed"
        summary["error"] = str(error)
        raise
    finally:
        summary["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
        write_result_json(summary, path)
        lock.close()
    print(f"{summary['status'].upper()}: {summary['firmware']['imem_bytes']}/4096 IMEM bytes; "
          f"{len(summary['sessions'])} serial sessions; see {path}")


if __name__ == "__main__":
    main()
