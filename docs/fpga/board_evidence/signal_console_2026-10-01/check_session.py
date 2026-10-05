"""Replay the FIR test plan on a board after reset; results/signal-console/board holds captures."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "scripts"))
import serial
from serial.tools.list_ports import comports
from result_json import write_result_json
from signal_console import ACK, Client, boot, config_payload, decode_frame, parse_response, read_byte, sample_payload
from signal_console_check import inputs, sha256, test_plan


def check(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--session", choices=("initial", "after-reset"), required=True)
    parser.add_argument("--expected-switches", type=lambda value: int(value, 0))
    args = parser.parse_args()
    directory = ROOT / "results/signal-console/board"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / (args.session + ".json")
    report = {"status": "running", "started_at_utc": datetime.now(timezone.utc).isoformat(),
              "session": args.session, "port": args.port, "responses": [], "client_examples": []}
    write_result_json(report, path)
    try:
        saved = json.loads((ROOT / "results/signal-console/summary.json").read_text())
        current_inputs = inputs()
        check(saved["status"] == "passed" and saved["inputs"] == current_inputs, "simulation inputs changed")
        packet = ROOT / "build/signal-console/program.boot.bin"
        check(sha256(packet) == saved["firmware"]["packet_sha256"], "boot packet changed")
        report["packet_sha256"] = sha256(packet)
        report["simulation_summary_sha256"] = sha256(ROOT / "results/signal-console/summary.json")
        report["checker_sha256"] = sha256(Path(__file__))
        report["usb_identity"] = [item.hwid for item in comports() if item.device == args.port]
        commands, cases = test_plan()
        with serial.Serial(args.port, 115200, timeout=3, write_timeout=3) as port:
            boot(port, packet)
            report["boot_greeting"] = "FIR1\n"
            request = bytearray()
            switches = None
            for token in commands:
                if token == 0x101:
                    break  # Operator presses physical reset between the two sessions.
                if token != 0x100:
                    if not request:
                        start = time.perf_counter()
                    request.append(token)
                    port.write(bytes([token]))
                    check(read_byte(port) == ACK, "missing byte ACK")
                    continue
                case = cases[len(report["responses"])]
                wire = bytearray(read_byte(port))
                check(wire[0] == 0x7e, "missing response delimiter")
                while len(wire) <= 324:
                    wire.extend(read_byte(port))
                    if wire[-1] == 0x7e:
                        break
                check(len(wire) <= 324, "response too large")
                row = {"sequence": case["sequence"], "command": case["command"],
                       "request_hex": request.hex(), "response_hex": wire.hex(),
                       "round_trip_ms": round((time.perf_counter() - start) * 1000, 3)}
                report["responses"].append(row)
                if case["error"]:
                    check(decode_frame(wire) == bytes([case["sequence"], ord(case["command"]),
                                                      case["error"], 0]), "wrong rejection response")
                    row["result"] = {"rejected": case["error"]}
                else:
                    actual = parse_response(wire, case["sequence"], case["command"])
                    row["result"] = dict(actual)
                    cycles = actual.pop("compute_cycles", None)
                    answer = dict(case["answer"])
                    if "switches" in answer:
                        if switches is None:
                            switches = actual["switches"]
                            if args.expected_switches is not None:
                                check(switches == args.expected_switches, "physical switch change mismatch")
                        answer["switches"] = switches
                    check(actual == answer, f"response {case['sequence']}: {actual} != {answer}")
                    check(cycles is None or 0 < cycles < 1000000, "invalid compute cycle count")
                row["status"] = "passed"
                write_result_json(report, path)
                request.clear()
            client = Client(port)
            report["client_examples"].append({"command": "synchronize", "result": client.synchronize()})
            examples = [("C", config_payload([1, 1, 1, 1], 2, 5), None), ("L", b"\xaa", None),
                        ("D", sample_payload([0, 4, 8, 12]), [0, 1, 3, 6]),
                        ("D", sample_payload([16, 20]), [10, 14])]
            for command, payload, outputs in examples:
                result = client.exchange(command, payload)
                report["client_examples"].append({"command": command, "result": result})
                if outputs is not None:
                    check(result["outputs"] == outputs and result["gpio"] == 0xab, "client example mismatch")
            status = client.exchange("S")
            report["client_examples"].append({"command": "S", "result": status})
            check(status["samples_processed"] == 6 and status["threshold_events"] == 3 and
                  status["gpio"] == 0xab and status["switches"] == switches and not status["uart_overrun"],
                  "unexpected final application state")
            report["switches"] = switches
            report["expected_led15_to_led8"] = "10101011"
        check(inputs() == current_inputs, "source changed during physical test")
        report["commands_checked"] = len(report["responses"])
        report["samples_checked"] = sum(len(row["result"].get("outputs", [])) for row in report["responses"])
        report["rejections_checked"] = sum("rejected" in row["result"] for row in report["responses"])
        report["client_commands_checked"] = len(report["client_examples"])
        report["client_samples_checked"] = 6
        report["status"] = "passed"
    except Exception as error:
        report["status"] = "failed"
        report["error"] = str(error)
        raise
    finally:
        report["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
        write_result_json(report, path)
    print(f"PASS: {report['commands_checked']} test commands, {report['samples_checked']} samples, "
          f"{report['rejections_checked']} rejections; 6 client commands, 6 samples; "
          f"switches=0x{report['switches']:04x}; LEDs=10101011")


if __name__ == "__main__":
    main()
