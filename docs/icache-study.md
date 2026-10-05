# Instruction cache design study

This experiment asks whether the CPU is losing useful time to its 64-byte
instruction cache, and how much FPGA hardware a larger cache costs. The
program bytes, fast multiplier, predictor, 64-byte D-cache and memory response
timing are held constant. Capacity is not credited for compiler changes.

The measured working sets reach their main performance gain at **256 B**.
That configuration now meets the 100 MHz routed target and costs less than
1 KiB. The **banked 1 KiB cache** remains the fixed instruction-side baseline
for the physical FIR comparison and separate [D-cache study](dcache-study.md):
it cuts CRC-32 `-O2` cycles by 32.1% and uses 3.7% more whole-SoC LUTs but
10.3% fewer FFs than the original 64 B design. It is a tested study baseline,
not a claim that every workload needs 1 KiB. The default remains 64 B.

## A 256-byte cache covers the CRC loop

For the same `-O2` CRC-32 image, 256 bytes reduce execution from **12,321 to
8,377 cycles**, a **32.0% cycle reduction or 1.47x cycle speedup**. I-cache
miss events fall from **2,056 to 24**. Both cases retire 7,578 instructions,
record 184 D-cache misses and two branch misses, and match the same Unicorn
instruction/writeback trace and independent CRC oracle.

The disassembly explains the change. The repeated loop at `0x108c..0x1174`
spans 16 aligned 16-byte lines, `0x1080..0x1170`. The 64-byte cache has two
sets: eight loop lines compete for two ways in each set. A 256-byte cache has
eight sets: exactly two loop lines map to each set. The hot loop now fits,
although the complete measured instruction region touches 22 different lines.
The relevant footprint is the repeated working set, not the size of the
entire firmware image.

Increasing capacity again to 1024 bytes saves only six more cycles in this
case. Across all 20 workload/compiler pairs, its largest additional reduction
over 256 bytes is 1.32%, on the short `calls -O2` example. Capacity beyond the
working set therefore needs a hardware-cost justification.

## The benefit depends on the workload

These are within-image comparisons. Each row uses the same executable and
measurement markers across cache configurations; unrelated row cycle counts
are not a ranking of algorithm efficiency.

| Workload and compiler | 64 B cycles | 256 B cycles | 1024 B cycles | Reduction at 256 B |
| --- | ---: | ---: | ---: | ---: |
| CRC-32 `-O2` | 12,321 | 8,377 | 8,371 | 32.01% |
| CRC-32 `-Os` | 11,147 | 10,379 | 10,379 | 6.89% |
| Calls `-O2` | 595 | 456 | 450 | 23.36% |
| FIR `-O2` | 11,870 | 11,301 | 11,301 | 4.79% |
| Insertion sort `-O2` | 14,334 | 13,626 | 13,626 | 4.94% |
| Resident loads `-O2` | 7,220 | 7,220 | 7,220 | 0% |
| Sequential loads `-O2` | 8,228 | 8,228 | 8,228 | 0% |
| Conflict loads `-O2` | 11,291 | 11,291 | 11,291 | 0% |

The load traversals have only three measured I-cache miss events each. Their
D-cache misses are 5, 257 and 1,025 respectively; enlarging I-cache cannot
resolve those data-side misses. This is a useful counterexample to a blanket
claim that a larger cache makes the CPU faster.

Compiler choice also interacts with capacity. With 64 bytes, `-Os` CRC is
faster than `-O2`; with 256 bytes, `-O2` wins. The hardware comparison is still
made within each fixed image. Comparing different optimization levels alone
would mix footprint, instruction count, layout and branch behavior.

## Capacity is not the only implementation decision

All four rows below use source `5c1c4c0`, the complete `fast_cpu` Basys3 SoC,
the same 10 ns clock constraint and the same implementation directives.
Each uses **2 BRAM and 4 DSP**. LUT counts include LUT RAM; FF and LUT counts
are separate resources, not interchangeable area units.

| I-cache implementation | SoC LUT | SoC FF | Setup WNS (ns) | Hold WHS (ns) | 100 MHz |
| --- | ---: | ---: | ---: | ---: | --- |
| Original parallel 64 B | 6,718 | 5,287 | +0.067 | +0.010 | Met |
| Banked 64 B | 6,888 | 4,657 | +0.142 | +0.038 | Met |
| Banked 256 B | 6,905 | 4,669 | +0.331 | +0.028 | Met |
| Banked 1024 B | 6,967 | 4,741 | +0.116 | +0.039 | Met |

All four completed routing, met setup/hold constraints and passed DRC with
zero warnings. The 256 B candidate's limiting path runs from `IDEXIR[20]`
to `EXMEMALUOut[21]`, rather than through I-cache storage. Cache geometry
changes whole-design placement and routing; these are individual builds,
not evidence that cache capacity alone determines the achievable clock.

Both 256 B and 1024 B use **224 I-cache LUT RAMs**. For this FPGA mapping,
the larger depth uses existing physical memory capacity; total cost still
increases through indexing, tags, valid/LRU state and logic. The 1 KiB SoC
adds 62 LUT and 72 FF over 256 B for at most 1.32% additional cycle reduction
in this matrix. **256 B is therefore the lower-cost choice for these measured
instruction working sets.** The existing 1 KiB physical and D-cache experiments
are retained as fixed, source-matched comparisons; changing their I-cache
while comparing D-cache organizations would introduce another variable.
Only the 64 B parallel and 1 KiB banked images have the physical FIR evidence
below. The 256 B result is RTL simulation plus routed implementation, not a
physical-board measurement.

## Physical FIR comparison

In the source-matched `5c1c4c0` repeat, the original 64 B and banked 1 KiB
fast-CPU images were each programmed through JTAG onto the same Basys3 and loaded with the identical
FIR2 firmware packet. Each checked 42 directed commands and 6,608 outputs:
202 directed, 6,400 sustained-stream, and six interactive-example outputs.
Both sessions passed, including malformed-packet checks and no UART overrun.
Switches were read as zero; no operator LED confirmation is claimed for this
unattended session. JTAG reconfiguration starts a new boot; a physical BTN C
press was not part of this comparison.

The median CPU count for the 200 eight-tap, 32-sample stress batches decreased
from 10,054 to 9,372 cycles (6.78%). This is firmware processing time, not
serial round-trip speedup. The short four-tap examples decreased from 868 to
771 and from 474 to 423 cycles. The 32.1% CRC result above remains a simulation
result; this board experiment does not turn it into a physical CRC claim.

The [paired board record](benchmarks/icache/board-comparison.json) identifies
the build, programming record, firmware and responses for both images. It
references the current automatic acceptance and D-cache capacity snapshots
without duplicating their raw captures. The earlier
[board snapshot](benchmarks/icache/board/) remains historical evidence with
its own source and bitstream hashes.

## What is implemented

The cache remains two-way set associative with 16-byte lines, invalid-way-first
replacement followed by per-set LRU, and one outstanding refill. Hit latency
and the CPU-facing interface are unchanged. Return-prediction metadata is
generated on refill and selected with its instruction word.

`ICACHE_BYTES` accepts powers of two from 64 to 4096. The default
`ICACHE_PARALLEL_LOOKUP=1` preserves the original 64-byte implementation.
The indexed implementation uses `ICACHE_PARALLEL_LOOKUP=0`. Basys3 build
arguments expose both parameters without changing the board's clock or
backing-memory capacity. Default cache settings are not silently replaced.

Each indexed way has a tag bank and four word banks. A word bank stores the
32-bit instruction together with its one-bit return hint. Each bank has one
refill write port and one asynchronous lookup port. Payloads are not reset;
resetting the valid bits prevents uninitialized contents from becoming hits.
This structure enables distributed LUT RAM while preserving the existing
same-cycle hit interface. Using synchronous block RAM instead would require
a fetch-latency change, not just a memory-style annotation.

This was an implementation-driven revision. The first indexed version used
a three-dimensional array with common refill writes. At 256 B, Vivado mapped
the cache to 2,569 flip-flops and zero LUT RAM; the whole SoC used 7,363 LUT
and 7,181 FF, with only +0.023 ns setup slack at 100 MHz. Simply removing
payload reset had not produced the intended memory implementation. Explicit
banking addresses the write-port topology rather than hiding the resource
cost behind a larger cache parameter.

## Measurement and validation

The matrix contains ten C workloads, each compiled at `-O2` and `-Os`, with
four configurations: original parallel 64 B, indexed 64 B, indexed 256 B and
indexed 1024 B. Each image is compiled once, then reused byte-for-byte across
all four configurations. The same-capacity comparison checks that changes
to storage/lookup implementation preserve every recorded cycle counter.

All 80 cases were also repeated after the storage-banking revision. Every
case field matched the first implementation, including the executable hash,
cycle/miss counters and all 64 stall-mask bins. The
[paired revision check](benchmarks/icache/storage-revision-check.json)
records both source fingerprints; this is simulation evidence, not a formal
equivalence proof. The current 80-row snapshot was regenerated at `5c1c4c0`;
same-capacity parallel and banked runs still match every cycle counter.

Simulation uses 16 KiB IMEM and DMEM. The data backend is the board's
`external_dmem_bram`, scaled to 16 KiB. Instruction memory is an asynchronous
line-response model with ready asserted in the request cycle, matching the
boot-complete board interface; UART boot itself is not part of this test.
The board instruction memory is **not synchronous BRAM**. Routed hardware
measurements use the real Basys3 top with its 4 KiB backing memories.

Each case starts from reset. Startup and input initialization may warm caches
before measurement. Existing examples measure retired `main` to
`program_done`; the six architecture workloads use retired begin/end markers
around the algorithm. The profiler reconciles hardware counters, independently
counted cycles, the retired trace and all 64 combinations of stall causes.

I-cache misses are hardware miss events, not misses divided by retired
instructions. Speculative fetch and cancelled refills can contribute to these
events. Raw stall causes overlap; they cannot simply be summed or interpreted
as the cycles saved by removing one cause. D-cache miss counts and retired
instructions must agree within each four-way comparison.

The interface-driven cache test checks 12 cache/backend combinations and
5,460 completed accesses, covering all sets and word offsets, conflict/LRU
replacement, high-address tags, delayed responses, cancellation, reset during
refill and return metadata. Core integration tests reject invalid capacities
and unsupported lookup combinations. These checks support the measured
configurations; they are not an ISA compliance claim.

Cycle ratios are simulated program performance. FPGA implementation reports
establish area and whether 100 MHz meets setup/hold constraints; they are not
new physical-board elapsed-time measurements or ASIC power/area estimates.
One place/route result per design is not a seed sweep or proof of maximum
frequency.

The initial flat-array 1024 B implementation was stopped during routing.
Its saved tool record is incomplete, not a completed timing result. The three
finished flat-array runs remain in the historical implementation directories;
the current implementation table contains only the four refreshed configurations.

## Reproduce

Use the dependencies in [compiled C setup](compiled-programs.md):

```powershell
.venv/Scripts/python.exe -B scripts/architecture_benchmark.py --icache-study
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run.ps1 -Test icache_geometry
```

`--smoke` runs one image across four configurations in a separate context.
Complete runs overwrite `results/architecture/icache-complete-external`;
build products use the matching directory under `build/architecture`.
The existing benchmark entrypoint is reused rather than adding another
simulation framework. Summaries include image/source hashes, tool versions,
profile parameters, counters and stall histograms. A failed or incomplete
matrix cannot retain an old successful status.

The reviewed snapshot keeps the [80-row cycle table](benchmarks/icache/measurements.csv),
[source and tool metadata](benchmarks/icache/run-metadata.json), and
[whole-SoC implementation table](benchmarks/icache/implementation.csv).
Each implementation directory contains its source hashes and routed reports.
Published reports normalize line endings and omit the local checkout path
and host name; metadata records hashes of both original and published files.

To implement one candidate without programming the board:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/vivado-basys3-build.ps1 -Implementation -ArchitectureProfile fast_cpu -ICacheBytes 1024 -ICacheParallelLookup 0 -OutDir build/vivado/icache-banked1024 -SummaryPath results/timing/icache-banked1024.json -LogPath results/timing/icache-banked1024.log
```

Use `64 / 1`, `64 / 0` or `256 / 0` for the other byte/lookup pairs, with
distinct output paths. The old physical-board records remain attached to
their recorded sources; these experiments do not relabel them as new runs.
