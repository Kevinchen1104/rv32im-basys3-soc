"""Screen D-cache organizations using verified architectural memory accesses.

This is a locality/traffic model, not a cycle model or an FPGA cost estimate.
Startup accesses warm each model before the retired benchmark markers.
"""

import csv
import hashlib
import json
from pathlib import Path

from execution_context import parse_symbols
from result_json import write_result_json


PROFILES = {
    "dm64": (64, 1, 0),
    "dm128": (128, 1, 0),
    "dm256": (256, 1, 0),
    "dm512": (512, 1, 0),
    "two_way64": (64, 2, 0),
    "two_way128": (128, 2, 0),
    "two_way256": (256, 2, 0),
    "two_way512": (512, 2, 0),
    "victim1": (64, 1, 1),
    "victim2": (64, 1, 2),
    "victim4": (64, 1, 4),
    "victim8": (64, 1, 8),
}


class Cache:
    """Write-back/write-allocate, 16-byte lines, LRU sets and victim buffer."""

    def __init__(self, capacity, ways=1, victims=0):
        if ways < 1 or capacity < 16 or capacity % (16 * ways) or victims < 0:
            raise ValueError("invalid cache geometry")
        self.ways = ways
        self.sets = [[] for _ in range(capacity // (16 * ways))]
        self.victims = []
        self.victim_count = victims

    def access(self, address, write=False):
        block = address // 16
        entries = self.sets[block % len(self.sets)]
        # Each entry is [full line address, dirty]. Oldest entry is first.
        for index, entry in enumerate(entries):
            if entry[0] == block:
                entries.append(entries.pop(index))
                entry[1] |= write
                return {"primary_misses": 0, "victim_hits": 0, "line_fills": 0, "writebacks": 0}
        incoming = [block, write]
        victim_hit = 0
        for index, entry in enumerate(self.victims):
            if entry[0] == block:
                incoming = self.victims.pop(index)
                incoming[1] |= write
                victim_hit = 1
                break
        writeback = 0
        if len(entries) == self.ways:
            outgoing = entries.pop(0)
            if self.victim_count:
                if len(self.victims) == self.victim_count:
                    writeback = int(self.victims.pop(0)[1])
                self.victims.append(outgoing)
            else:
                writeback = int(outgoing[1])
        entries.append(incoming)
        return {"primary_misses": 1, "victim_hits": victim_hit,
                "line_fills": 1 - victim_hit, "writebacks": writeback}


def memory_accesses(trace, begin_pc, end_pc):
    """Decode effective addresses before applying the retired destination value."""
    registers = list(range(32))  # Core reset convention; x0 is always zero.
    active = False
    began = ended = False
    accesses = []
    for pc, instruction, destination, value in trace:
        if pc == begin_pc:
            if began:
                raise ValueError("repeated begin marker")
            began = active = True
        if pc == end_pc:
            if not active or ended:
                raise ValueError("unexpected end marker")
            active = False
            ended = True
        opcode = instruction & 127
        if opcode in (0x03, 0x23):
            immediate = instruction >> 20 if opcode == 0x03 else (
                ((instruction >> 25) << 5) | ((instruction >> 7) & 31))
            if immediate & 0x800:
                immediate -= 4096
            address = (registers[(instruction >> 15) & 31] + immediate) & 0xFFFFFFFF
            funct3 = (instruction >> 12) & 7
            valid = (0, 1, 2, 4, 5) if opcode == 3 else (0, 1, 2)
            if funct3 not in valid:
                raise ValueError("unsupported load/store width")
            size = 1 << (funct3 & 3)
            if address < 0x3000 or address + size > 0x4000 or address % size:
                raise ValueError(f"access outside aligned ordinary-RAM profile: {address:#x}")
            accesses.append((address, opcode == 0x23, active))
        if destination & 32 and destination & 31:
            registers[destination & 31] = value
        registers[0] = 0
    if not began or not ended:
        raise ValueError("missing benchmark markers")
    return accesses


def evaluate(accesses, capacity, ways=1, victims=0):
    cache = Cache(capacity, ways, victims)
    total_bytes = capacity + 16 * victims
    shadow = Cache(total_bytes, total_bytes // 16)
    seen = set()
    counts = dict.fromkeys(("accesses", "loads", "stores", "primary_misses", "victim_hits",
                           "line_fills", "writebacks", "compulsory", "capacity", "conflict"), 0)
    for address, write, active in accesses:
        block = address // 16
        event = cache.access(address, write)
        shadow_event = shadow.access(address, write)
        if active:
            counts["accesses"] += 1
            counts["stores" if write else "loads"] += 1
            for key, value in event.items():
                counts[key] += value
            if event["line_fills"]:
                category = "compulsory" if block not in seen else (
                    "capacity" if shadow_event["line_fills"] else "conflict")
                counts[category] += 1
        seen.add(block)
    counts["transfer_bytes"] = 16 * (counts["line_fills"] + counts["writebacks"])
    counts["data_capacity_bytes"] = total_bytes
    return counts


def screen(root, source, output):
    """Read hash-verified saved evidence; write separate, replaceable screening results."""
    source = Path(source)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    report = {"status": "running", "scope": "trace locality/traffic screening; not RTL cycles or hardware cost",
              "source_summary": source.relative_to(root).as_posix(), "cases": []}
    write_result_json(report, output / "summary.json")
    (output / "RESULTS.md").write_text("# D-cache screening\n\nStatus: running\n", encoding="utf-8")
    (output / "measurements.csv").unlink(missing_ok=True)
    try:
        raw = source.read_bytes()
        saved = json.loads(raw)
        if saved["status"] != "passed":
            raise ValueError("source experiment did not pass")
        report["source_summary_sha256"] = hashlib.sha256(raw).hexdigest()
        report["source_identity"] = saved["source"]
        report["profiles"] = {name: dict(capacity_bytes=c, ways=w, victim_lines=v)
                              for name, (c, w, v) in PROFILES.items()}
        for row in saved["cases"]:
            if row["profile"] != "parallel64":
                continue
            label = f"{row['workload']}-{row['optimization']}"
            files = [source.parent / f"{label}-parallel64/trace.txt",
                     source.parent / f"build/{label}/symbols.log"]
            for path in files:
                expected = saved["artifacts"][path.relative_to(source.parent).as_posix()]
                if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                    raise ValueError(f"source artifact changed: {path}")
            trace = [tuple(int(word, 16) for word in line.split()) for line in files[0].read_text().splitlines()]
            symbols = parse_symbols(files[1].read_text())
            accesses = memory_accesses(trace, symbols.get("benchmark_begin", symbols["main"]),
                                       symbols.get("benchmark_end", symbols["program_done"]))
            baseline = evaluate(accesses, 64)
            if baseline["line_fills"] != row["dcache_misses"]:
                raise ValueError(f"decoded baseline misses differ from RTL: {label}")
            for name, geometry in PROFILES.items():
                counts = evaluate(accesses, *geometry)
                report["cases"].append(dict(workload=row["workload"], optimization=row["optimization"],
                    profile=name, image_sha256=row["image_sha256"],
                    source_rtl_dcache_misses=row["dcache_misses"], **counts))
        if not report["cases"]:
            raise ValueError("no baseline cases in source experiment")
        report["status"] = "passed"
        report["baseline_miss_reconciliation"] = "all decoded dm64 intervals match their RTL miss counters"
    except Exception as error:
        report.update(status="failed", error=str(error))
        raise
    finally:
        report["analysis_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        write_result_json(report, output / "summary.json")
        rows = report["cases"]
        if rows:
            with (output / "measurements.csv").open("w", newline="", encoding="utf-8") as stream:
                writer = csv.DictWriter(stream, fieldnames=list(rows[0]), lineterminator="\n")
                writer.writeheader()
                writer.writerows(rows)
        lines = ["# D-cache locality and traffic screening", "", f"Status: **{report['status']}**", "",
                 "Retired memory accesses, warmed by startup; 16-byte lines and write-back/write-allocate.",
                 "This is not cycle simulation. Dirty lines still resident at interval end are not flushed.",
                 "3C categories use an LRU fully associative shadow with the same total data capacity.",
                 "RTL counters use clock-edge markers; the trace uses retired-instruction markers.",
                 "", "[All measurements](measurements.csv) | [Provenance](summary.json)", "",
                 "| Workload | Profile | Data bytes | Fills | Writebacks | Traffic bytes |",
                 "| --- | --- | ---: | ---: | ---: | ---: |"]
        for row in rows:
            if row["optimization"] == "O2":
                lines.append(f"| {row['workload']} | {row['profile']} | {row['data_capacity_bytes']} | "
                             f"{row['line_fills']} | {row['writebacks']} | {row['transfer_bytes']} |")
        if report.get("error"):
            lines.extend(["", "Error: " + report["error"]])
        (output / "RESULTS.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return report
