"""Cross-check saved architectural-test signatures with the upstream Sail model."""

import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import os
import shutil
import struct
import subprocess
from datetime import datetime, timezone

from compiled_programs import ROOT, run
from execution_context import RunLock, selection_context
from result_json import QUOTED, write_result_json

VERSION = "0.14.1"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_config(text):
    """The model prints JSON with line comments and optional trailing commas."""
    text = re.sub(rf'{QUOTED}|//[^\n]*', lambda m: m[0] if m[0].startswith('"') else "", text)
    text = re.sub(rf'{QUOTED}|,\s*(?=[}}\]])', lambda m: m[0] if m[0].startswith('"') else "", text)
    return json.loads(text)


def reference_config(default, memory_words):
    config = copy.deepcopy(default)
    config["base"]["writable_misa"] = False
    config["base"]["mstatus"]["fs_legal_states"] = "ExtContext_Off"
    config["base"]["mstatus"]["vs_legal_states"] = "ExtContext_Off"
    config["extensions"]["V"]["support_level"] = "Disabled"
    config["extensions"]["V"]["vlen_exp"] = 3
    config["extensions"]["V"]["elen_exp"] = 3
    config["extensions"]["V"]["max_index_eew_exp"] = 3
    for name, extension in config["extensions"].items():
        if "supported" in extension:
            extension["supported"] = name in ("M", "Zicsr", "Zifencei")
    for extension in config["extensions"]["Stateen"].values():
        if isinstance(extension, dict) and "supported" in extension:
            extension["supported"] = False
    region = next(item for item in config["memory"]["regions"]
                  if item["attributes"]["mem_type"] == "MainMemory")
    region["base"]["value"] = "0x0"
    region["size"]["value"] = hex(memory_words * 4)
    config["memory"]["regions"] = [region]
    config["memory"]["physaddr_bits"] = 32
    config["memory"]["dtb_address"]["value"] = hex(memory_words * 4 - 4096)
    config["memory"]["misaligned"]["exceptions"]["load_store"] = {"Some": "AlignmentException"}
    config["platform"]["clint"]["supported"] = False
    config["platform"]["simple_interrupt_generator"]["supported"] = False
    return config


def matching_elf(elf, program):
    """Keep ELF symbols but load exactly the DUT image, including padding NOPs.

    The existing arch-test adapter replaces zero words in executable sections
    with NOPs. No nonzero instruction or data byte may change here.
    """
    if elf[:7] != b"\x7fELF\x01\x01\x01":
        raise ValueError("expected little-endian ELF32")
    result = bytearray(elf)
    offset = struct.unpack_from("<I", elf, 28)[0]
    entry_size, count = struct.unpack_from("<HH", elf, 42)
    patched_words = 0
    for index in range(count):
        kind, file_offset, virtual, physical, size, _, flags, _ = struct.unpack_from(
            "<8I", elf, offset + index * entry_size)
        if kind != 1 or size == 0:
            continue
        if virtual != physical or physical + size > len(program) or file_offset + size > len(elf):
            raise ValueError("ELF load segment is outside the DUT image")
        old, new = elf[file_offset:file_offset+size], program[physical:physical+size]
        if old != new:
            if not flags & 1 or size % 4 or physical % 4:
                raise ValueError("non-executable or unaligned ELF segment differs from DUT image")
            for position in range(0, size, 4):
                if old[position:position+4] != new[position:position+4]:
                    if old[position:position+4] != bytes(4) or new[position:position+4] != b"\x13\x00\x00\x00":
                        raise ValueError("DUT image changed an instruction or data, not padding")
                    patched_words += 1
            result[file_offset:file_offset+size] = new
    return bytes(result), patched_words


def tool_path(path, wsl):
    path = Path(path).resolve()
    if not wsl:
        return str(path)
    if not re.fullmatch(r"[A-Za-z]:", path.drive):
        raise ValueError("WSL references require a local drive path")
    return "/mnt/" + path.drive[0].lower() + path.as_posix()[2:]


def compare_signatures(expected, actual, words):
    if len(expected) != words or len(actual) != words or words <= 0:
        raise RuntimeError("Sail/DUT signature length mismatch")
    if any(not re.fullmatch(r"[0-9a-f]{8}", word) for word in [*actual, *expected]):
        raise RuntimeError("invalid signature word")
    if actual != expected:
        index = next(i for i, pair in enumerate(zip(actual, expected)) if pair[0] != pair[1])
        raise RuntimeError(f"signature word {index}: DUT {actual[index]}, Sail {expected[index]}")


def run_case(command, wsl, config, row, output):
    original = ROOT / row["program_hex_path"]
    if digest(original) != row["program_hex_sha256"]:
        raise ValueError("DUT program image no longer matches its simulation record")
    program = b"".join(struct.pack("<I", int(line, 16)) for line in original.read_text().splitlines())
    elf_path = original.with_suffix(".elf")
    if row.get("program_elf_sha256") and digest(elf_path) != row["program_elf_sha256"]:
        raise ValueError("ELF no longer matches its simulation record")
    elf, padding = matching_elf(elf_path.read_bytes(), program)
    work = ROOT / "build/arch-test/sail" / row["id"]
    work.mkdir(parents=True, exist_ok=True)
    matched = work / "program.elf"
    matched.write_bytes(elf)
    directory = output / row["id"]
    directory.mkdir(parents=True, exist_ok=True)
    signature = directory / "sail.signature.hex"
    signature.unlink(missing_ok=True)
    log = directory / "sail.log"
    text = run([*command, "--config", tool_path(config, wsl), "--inst-limit", "250000",
                "--test-signature", tool_path(signature, wsl), "--signature-granularity", "4",
                tool_path(matched, wsl)], log, timeout=120)
    if not signature.is_file() or not re.search(r"^SUCCESS$", text, re.MULTILINE):
        raise RuntimeError("Sail did not report successful termination with a signature")
    expected = signature.read_text().lower().split()
    dut = ROOT / row["dut_signature_path"]
    if row.get("dut_signature_sha256") and digest(dut) != row["dut_signature_sha256"]:
        raise ValueError("DUT signature no longer matches its simulation record")
    actual = dut.read_text().lower().split()
    compare_signatures(expected, actual, row["signature_words"])
    return {"id": row["id"], "status": "passed", "signature_words": len(expected),
            "padding_nops": padding, "elf_sha256": digest(elf_path), "matched_elf_sha256": digest(matched),
            "program_hex_sha256": digest(original), "dut_signature_sha256": digest(dut),
            "files": {f"{row['id']}/sail.signature.hex": digest(signature), f"{row['id']}/sail.log": digest(log)}}


def verification_identity():
    shell = shutil.which("pwsh") or shutil.which("powershell")
    if not shell:
        raise RuntimeError("PowerShell is required for the project's shared source-identity check")
    environment = {key: value for key, value in os.environ.items() if key.upper() != "PSMODULEPATH"}
    text = subprocess.check_output([shell, "-NoProfile", "-Command",
        ". ./scripts/verification-source-identity.ps1; . ./scripts/result-format.ps1; "
        "ConvertTo-ResultJson (Get-VerificationSourceIdentity)"], cwd=ROOT, env=environment, text=True)
    return json.loads(text)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sail", default="sail_riscv_sim")
    parser.add_argument("--wsl", help="WSL distribution; omit for native Linux/macOS")
    parser.add_argument("--wsl-user", default="root")
    parser.add_argument("--case", help="one named case for diagnosing the adapter")
    args = parser.parse_args(argv)
    command = (["wsl", "-d", args.wsl, "-u", args.wsl_user, "--exec"] if args.wsl else []) + [args.sail]
    base_output = ROOT / "results/arch-test/sail"
    base_output.mkdir(parents=True, exist_ok=True)
    # Diagnostics must not replace the complete comparison. Keep one lock
    # because both modes use the same adapted ELF work directory.
    lock = RunLock(base_output / "run.lock")
    context = selection_context(((args.case,),), ((),)) if args.case else ""
    output = base_output / context
    output.mkdir(parents=True, exist_ok=True)
    path = output / "summary.json"
    report = {"status": "running", "started_at_utc": datetime.now(timezone.utc).isoformat(), "cases": []}
    write_result_json(report, path)
    try:
        version = run([*command, "--version"], output / "version.log").strip()
        if version != VERSION:
            raise ValueError(f"Sail {VERSION} is required; got {version}")
        report["reference_version"] = version
        record = ROOT / "results/arch-test-results.json"
        saved = json.loads(record.read_text(encoding="utf-8-sig"))
        if saved["status"] != "pass":
            raise ValueError("run passing architectural-test simulations first")
        profile_path = ROOT / saved["profile_path"]
        profile = json.loads(profile_path.read_text(encoding="utf-8-sig"))
        if (saved["upstream_commit"] != profile["upstream"]["revision"] or
                sorted(row["id"] for row in saved["tests"]) != sorted(row["id"] for row in profile["tests"])):
            raise ValueError("architectural-test profile and saved matrix differ")
        identity = verification_identity()
        current = saved.get("verification_input_fingerprint") == identity["verification_input_fingerprint"]
        if not args.case and not current:
            raise ValueError("architectural-test results are stale; rerun arch-test-run.ps1 before this full comparison")
        if not args.case:
            if any(not row.get("dut_signature_sha256") or not row.get("program_elf_sha256") for row in saved["tests"]):
                raise ValueError("architectural-test artifact hashes are missing; rerun arch-test-run.ps1")
            report.update(identity)
        report["scope"] = "single-case adapter diagnostic" if args.case else "selected upstream tests; not full ISA compliance"
        default = parse_config(run([*command, "--rv32", "--print-default-config"], output / "default-config.log"))
        config = output / "config.json"
        write_result_json(reference_config(default, profile["target"]["memory_words"]), config)
        report["isa"] = run([*command, "--config", tool_path(config, args.wsl), "--print-isa-string"], output / "isa.log").strip()
        if report["isa"] != "rv32im_zicsr_zifencei":
            raise ValueError(f"unexpected Sail ISA configuration: {report['isa']}")
        report["input_record"] = {"path": record.relative_to(ROOT).as_posix(), "sha256": digest(record)}
        report["upstream_commit"] = saved["upstream_commit"]
        report["tool_build"] = run([*command, "--build-info"], output / "build-info.log").strip()
        if args.wsl:
            report["tool_sha256"] = run([*command[:-1], "sha256sum", args.sail], output / "binary-hash.log").split()[0]
        else:
            report["tool_sha256"] = digest(Path(shutil.which(args.sail) or args.sail))
        rows = [row for row in saved["tests"] if not args.case or row["id"] == args.case]
        if not rows:
            raise ValueError("requested case was not found")
        report["planned_cases"] = len(rows)
        for row in rows:
            report["active_case"] = row["id"]
            write_result_json(report, path)
            report["cases"].append(run_case(command, args.wsl, config, row, output))
            print("PASS Sail " + row["id"], flush=True)
        if digest(record) != report["input_record"]["sha256"] or verification_identity()["verification_input_fingerprint"] != identity["verification_input_fingerprint"]:
            raise RuntimeError("reference inputs changed during execution")
        report["files"] = {name: digest(output / name) for name in
                           ("config.json", "default-config.log", "version.log", "isa.log", "build-info.log")}
        for row in report["cases"]:
            report["files"].update(row["files"])
        report["status"] = "diagnostic_passed" if args.case else "passed"
    except Exception as error:
        report.update(status="failed", error=str(error))
        raise
    finally:
        report["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
        write_result_json(report, path)
        lock.close()


if __name__ == "__main__":
    main()
