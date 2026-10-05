"""Preflight, explicitly load when requested, and open the FPGA signal viewer."""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib
import json
import os
from pathlib import Path
import shutil

from result_json import format_result_json, write_result_json

ROOT = Path(__file__).resolve().parents[1]
PACKET = ROOT / "build/signal-console/program.boot.bin"
TIMING = ROOT / "results/timing/signal-console-summary.json"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def select_port(requested, ports):
    if requested:
        if not any(p.device.lower() == requested.lower() for p in ports):
            raise ValueError(f"{requested} is not present; use --list-ports")
        return next(p.device for p in ports if p.device.lower() == requested.lower())
    candidates = [p.device for p in ports if p.vid == 0x0403 and p.pid == 0x6010]
    if len(candidates) != 1:
        raise ValueError("Specify --port from --list-ports; automatic selection needs exactly one FT2232 UART")
    return candidates[0]


def firmware_ready():
    from signal_console_check import inputs
    saved = json.loads((ROOT / "results/signal-console/summary.json").read_text(encoding="utf-8-sig"))
    if (saved.get("status") not in ("built", "passed") or saved.get("inputs") != inputs() or
            digest(PACKET) != saved.get("firmware", {}).get("packet_sha256")):
        raise ValueError("Firmware inputs changed; run scripts/signal_console_check.py before uploading")
    return digest(PACKET)


def application_image(timing_path=TIMING):
    saved = json.loads(timing_path.read_text(encoding="utf-8-sig"))
    if (saved.get("architecture_profile") != "fast_cpu" or
            saved.get("top") != "RISCVCPU_basys3_top" or saved.get("part") != "xc7a35tcpg236-1" or
            any(saved.get(k) != "pass" for k in ("status", "timing_status", "drc_status", "bitstream_status"))):
        raise ValueError("Build the fast_cpu FIR application image with passing timing and DRC first")
    if not saved.get("source_inputs"):
        raise ValueError("FPGA build has no source identity; rebuild it")
    for item in saved["source_inputs"]:
        if digest(ROOT / item["path"]) != item["sha256"]:
            raise ValueError(f"FPGA build inputs changed: {item['path']}; rebuild the application image")
    bitstream = (ROOT / saved["bitstream"]).resolve()
    if not bitstream.is_file():
        raise ValueError("Application bitstream is missing; build it first")
    if digest(bitstream) != saved.get("bitstream_sha256"):
        raise ValueError("Bitstream differs from its build hash, or the older record has no hash; rebuild it")
    return bitstream


def program_image(bitstream, xsdb, timing_path=TIMING, output=None):
    """One explicit JTAG operation, with the actual programmed file identified."""
    from compiled_programs import run
    executable = shutil.which(xsdb)
    if not executable:
        raise ValueError("XSDB is not on PATH; pass --xsdb C:/path/to/Vivado/bin/xsdb.bat")
    output = output or ROOT / "results/signal-console/start-programming.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    report = {"status": "running", "started_at_utc": datetime.now(timezone.utc).isoformat(),
              "bitstream": bitstream.relative_to(ROOT).as_posix(), "bitstream_sha256": digest(bitstream),
              "build_summary": timing_path.relative_to(ROOT).as_posix(),
              "build_summary_sha256": digest(timing_path)}
    report["inputs"] = {p.relative_to(ROOT).as_posix(): digest(p)
                        for p in (bitstream, timing_path, Path(__file__), ROOT / "fpga/xsdb/basys3_program.tcl")}
    write_result_json(report, output)
    try:
        raw = ROOT / "build/signal-console/programming.json"
        raw.parent.mkdir(parents=True, exist_ok=True)
        raw.unlink(missing_ok=True)
        # Reuse the existing one-target XSDB script; never retry programming.
        # Match xsdb-basys3-program.ps1: AMD Tcl can mis-normalize AppData/Desktop.
        temporary = Path.home() / ".xsdb-tmp"
        temporary.mkdir(exist_ok=True)
        previous = {name: os.environ.get(name) for name in ("TEMP", "TMP", "TMPDIR")}
        try:
            os.environ.update({name: temporary.as_posix() for name in previous})
            run([executable, (ROOT / "fpga/xsdb/basys3_program.tcl").as_posix(),
                 "-bitstream", bitstream.as_posix(), "-device_selector", "*xc7a35t*", "-result_path", raw.as_posix()],
                output.with_suffix(".log"), timeout=120)
        finally:
            for name, value in previous.items():
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value
        result = json.loads(raw.read_text(encoding="utf-8-sig"))
        if result.get("status") != "pass" or not result.get("configuration_verified"):
            raise RuntimeError("XSDB did not confirm successful configuration")
        if digest(bitstream) != report["bitstream_sha256"]:
            raise RuntimeError("Bitstream changed during programming")
        report.update(status="passed", programming=result)
    except Exception as error:
        report.update(status="failed", error=str(error))
        raise
    finally:
        report["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
        if output.with_suffix(".log").exists():
            report["files"] = {output.with_suffix(".log").name: digest(output.with_suffix(".log"))}
        write_result_json(report, output)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", help="COM3, for example; auto-select only one matching FT2232 UART")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--list-ports", action="store_true")
    mode.add_argument("--check", action="store_true", help="check local dependencies and selected port, without opening it")
    mode.add_argument("--probe", action="store_true", help="query FIR2 status, then close; no filter reconfiguration")
    parser.add_argument("--upload", action="store_true", help="upload firmware after BTN C; never inferred from an error")
    parser.add_argument("--program", action="store_true", help="explicitly replace volatile FPGA image, then upload firmware")
    parser.add_argument("--xsdb", default="xsdb", help="XSDB executable; needed only with --program")
    parser.add_argument("--build-summary", type=Path, help="explicit alternative fast_cpu build summary; requires --program")
    parser.add_argument("--batches", type=int, default=0, help="finite headless capture instead of the desktop viewer")
    parser.add_argument("--output", type=Path, help="snapshot filename stem")
    args = parser.parse_args(argv)
    if args.batches < 0:
        parser.error("--batches must be nonnegative")
    if args.build_summary and not args.program:
        parser.error("--build-summary requires --program")
    if args.build_summary:
        args.build_summary = args.build_summary.resolve()
    if args.list_ports and (args.upload or args.program):
        parser.error("--list-ports cannot load hardware or firmware")
    from serial.tools.list_ports import comports
    ports = list(comports())
    if args.list_ports:
        for p in ports:
            print(f"{p.device}: {p.description} [{p.hwid}]")
        if not ports:
            print("No serial ports found. Connect and power the Basys3.")
        return
    port = select_port(args.port, ports)
    if not args.probe:
        importlib.import_module("matplotlib")
        if not args.batches:
            importlib.import_module("tkinter")
    packet = PACKET if args.upload or args.program else None
    if packet:
        firmware_ready()
    bitstream = (application_image(args.build_summary) if args.build_summary else application_image()) if args.program else None
    if bitstream and not shutil.which(args.xsdb):
        raise ValueError("XSDB is not on PATH; pass --xsdb C:/path/to/Vivado/bin/xsdb.bat")
    print(f"Port: {port}; firmware: {'upload requested' if packet else 'use running FIR2'}")
    if args.check:
        print("Preflight passed. UART was not opened; no FPGA or firmware was loaded.")
        return
    if bitstream:
        print("Programming the FIR application into volatile FPGA memory...")
        if args.build_summary:
            program_image(bitstream, args.xsdb, timing_path=args.build_summary)
        else:
            program_image(bitstream, args.xsdb)
    from signal_viewer import connect, main as viewer_main
    if args.probe:
        client = connect(port, packet)
        try:
            print(format_result_json(client.exchange("S")), end="")
        finally:
            client.port.close()
        return
    viewer_args = ["--port", port, "--batches", str(args.batches)]
    if packet:
        viewer_args += ["--boot", str(packet)]
    if args.output:
        viewer_args += ["--output", str(args.output)]
    viewer_main(viewer_args)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, ImportError) as error:
        raise SystemExit(f"Startup stopped: {error}\nSee docs/signal-console.md#startup-and-recovery. "
                         "No automatic reset, upload, or programming retry was attempted.")
