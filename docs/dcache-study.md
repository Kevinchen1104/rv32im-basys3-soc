# Data cache design study

## Question and baseline

Can a small victim cache recover data reuse more efficiently than simply
enlarging the direct-mapped data cache? The RTL supports four or eight 16-byte
primary lines (64 or 128 bytes), write-back/write-allocate stores, MMIO bypass,
and a local DMA snoop path. The 64-byte implementation remains the default.

The first step replays hash-verified retired traces from the saved I-cache
study. Effective addresses are decoded from the pre-instruction register
state; startup accesses warm each model before the benchmark interval. All
20 original 64-byte miss counts must reconcile with the RTL counters.
This is a locality/traffic screen, not a cycle or FPGA cost model.

```powershell
.venv/Scripts/python.exe -B scripts/architecture_benchmark.py --memory-screen
```

Results replace `results/architecture/dcache-screen/`. They retain source
evidence identity, executable hashes, geometry and analysis-script identity.
The existing simulation runner remains the entry point.

## Candidate selection

The screen compares direct-mapped and two-way caches at 64/128/256/512 bytes,
plus the existing 64-byte cache with 1/2/4/8 fully associative victim lines.
All models use 16-byte lines and LRU replacement. A victim hit swaps the
requested line with the primary-cache victim, preserving dirty state.
Only eviction from the combined hierarchy generates a writeback.

For FIR `-O2`, 64-byte direct mapping gives 452 fills and 67 writebacks.
A four-line victim buffer gives 35 fills and 22 writebacks using 128 bytes
of total data storage. At the same 128-byte data capacity, a two-way cache
gives 119 fills and 46 writebacks; a 512-byte direct-mapped cache still gives
130 fills and 81 writebacks. Tags, comparators, replacement state and timing
are not included in those data-capacity numbers. Hardware measurements must
decide whether the candidate is worthwhile.

The conflict traversal is a counterexample: it reads only eight words
(32 useful bytes) but occupies eight distinct 16-byte lines (128 bytes of
line footprint). All map to one primary index. Four victim lines plus that
primary slot cannot retain all eight, so the four-entry candidate still
needs 1,025 measured fills. The 64-byte fully associative shadow also
cannot hold the footprint: under conventional 3C classification this is
capacity pressure at 64 bytes, not purely a conflict miss stream. At larger
capacities, the same address mapping can become conflict-limited.

The first selected candidate used a four-line, miss-path victim buffer; the
complete implementation study also evaluates one, two and eight entries.
None is a claim to solve every conflict pattern. `DCACHE_VICTIM_LINES` accepts
0/1/2/4/8, with zero preserving the default. Victim tags are compared in
parallel with the primary lookup; a primary miss captures the match flags.
The following victim state consumes those registered flags. A hit swaps
lines; a miss evicts the LRU victim, writing it back first if dirty. This
adds a lookup cycle to a backing-memory miss. Primary hits complete without
waiting for the victim state.

## Cycle results: saved transfers must repay the lookup

The RTL matrix uses 17 workloads, two compiler optimizations and six cache
profiles, for 204 executions: 64/128-byte direct mapping and the 64-byte
primary cache with 1/2/4/8 victim lines. The I-cache is fixed at banked 1 KiB.
Every comparison uses the same executable and retired instruction sequence;
Unicorn execution, final data memory and an independent algorithm oracle are
checked. A separate cache-reference model must match primary misses, victim
hits, line fills and writebacks exactly.

Selected `-O2` results with the synchronous BRAM backend:

| Workload | 64 B direct | 128 B direct | 1 victim | 2 victims | 4 victims | 8 victims |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| FIR | 11,301 | 10,705 | 10,804 | 10,379 | 9,950 | 9,959 |
| CRC-32 | 8,371 | 8,291 | 8,430 | 8,429 | 8,419 | 8,423 |
| Sort | 13,626 | 12,798 | 13,767 | 13,625 | 13,265 | 12,785 |
| Resident | 7,220 | 7,220 | 7,228 | 7,228 | 7,228 | 7,228 |
| Sequential | 8,228 | 8,240 | 8,488 | 8,491 | 8,497 | 8,509 |
| Eight-line same-index traversal | 11,291 | 11,294 | 12,319 | 12,322 | 12,328 | 8,269 |

At equal 128-byte **data** capacity, the 128-byte direct-mapped cache takes
10,705 FIR cycles versus 9,950 for the 64-byte primary plus four victims.
The victim organization recovers more displaced reuse, but it is not generally
better: direct mapping wins on CRC-32, sort and sequential access in this
comparison. The one- and two-entry results show the benefit growing toward
four entries for FIR; eight entries add no FIR benefit. Tags, associative
comparators and replacement state must be compared separately from data bytes.

Thus four victims reduce FIR cycles by 11.95%, but increase sequential
cycles by 3.27% and the eight-line same-index traversal by 9.18%. It is an
optional workload-dependent configuration, not a universal replacement.
For FIR, completed 16-byte line transfers fall from 519 (452 fills + 67
writebacks) to 57 (35 + 22), an 89.02% traffic reduction. This much larger
traffic reduction is **not** an 89% program speedup: computation, other stalls
and lookup cycles remain.

## Controlled mapping and latency experiments

The seven memory scenarios use identical code bytes within each compiler
optimization. Only four data parameters change: number of touched lines,
stride, starting-word offset, and store period. This separates address-layout
effects from changing the compiled algorithm.

Eight words separated by 64 bytes all map to one of the four 64-byte-primary slots.
With four victims, that pattern takes 21,548 cycles. Changing the stride to
80 bytes distributes the eight lines across four primary slots and takes
17,493 cycles. The useful bytes and instruction sequence are unchanged.
Shifting the starting word by four bytes within each line leaves that second
result unchanged. These are controlled synthetic probes, not application
throughput claims.

The additional latency sweep repeats FIR, sequential, conflict and mixed
read/write scenarios at both `-O2` and `-Os`, with 4 or 12 extra wait cycles
before each backing-memory request. There are 96 additional executions,
bringing the complete study to 300.
This is a serialized latency model, not a DDR-controller or bandwidth model.
The line size, executable, memory contents, cache events and algorithm answer
remain fixed.

For `-O2` FIR, 64-byte direct / 128-byte direct / four-victim cycle counts
are 13,377 / 12,189 / 10,178 at four extra cycles and
17,529 / 15,157 / 10,634 at twelve. Higher transfer latency makes
recovered reuse more valuable. Sequential still loses at both latencies,
because its fills are not avoided. The experiment therefore supports a
specific mechanism, rather than the claim that a slower memory always makes
any larger cache worthwhile.

## FPGA implementation boundary

### Complete six-profile comparison

All six current configurations meet setup/hold timing and DRC at 100 MHz.
They use the same `fast_cpu`, banked 1 KiB I-cache, build-input hashes,
constraints and implementation directives. Every row uses 2 BRAM tiles and
4 DSP blocks. The physical column measures the same FIR2 firmware and input
stream on one Basys3, not the C benchmark above.

| D-cache configuration | LUT | FF | Setup slack (ns) | Hold slack (ns) | Physical FIR median cycles |
| --- | ---: | ---: | ---: | ---: | ---: |
| 64 B direct | 6,967 | 4,741 | +0.116 | +0.039 | 9,372 |
| 128 B direct | 7,869 | 5,361 | +0.158 | +0.023 | 7,545 |
| 64 B + 1 victim | 7,042 | 4,908 | +0.095 | +0.037 | 8,772 |
| 64 B + 2 victims | 7,381 | 5,075 | +0.017 | +0.035 | 8,486 |
| 64 B + 4 victims | 7,804 | 5,388 | +0.306 | +0.036 | 7,681 |
| 64 B + 8 victims | 8,028 | 6,040 | +0.135 | +0.029 | 7,609 |

Each image passed 42 directed commands and 6,608 output checks, including
200 eight-tap, 32-sample stress batches. The direct-mapped, one-entry and
two-entry captures have constant batch counts; four-entry ranges from
7,681 to 7,684 cycles, and eight-entry from 7,598 to 7,609.
The [complete snapshot](benchmarks/dcache/capacity/comparison.json) links
the [routed reports](benchmarks/dcache/capacity/implementation/) and
[programming/response records](benchmarks/dcache/capacity/board/).

At equal 128 B data capacity, four victims save 65 whole-SoC LUTs but use
27 more FFs than direct mapping in these individual routed runs. Neither
resource difference establishes a general area advantage. More importantly,
the fixed-coefficient `-O2` C FIR favors four victims (9,950 versus 10,705
cycles), whereas the interactive `-Os` FIR favors 128 B direct mapping
(7,545 versus 7,681). The interactive program has configurable coefficients,
history shifting, scaling, threshold checks and different data-array layouts.
Cache reuse is determined by those actual accesses, not the shared name FIR.

The physical reductions relative to 64 B direct are 19.49% for 128 B direct
and 18.04% for four victims. These are CPU processing-cycle reductions;
host-paced UART time is outside the interval. Eight victims improve the
same-index synthetic traversal but add no C-FIR benefit and use more resources.
The design decision is therefore to retain the original default and expose
both optional organizations. The measured application can select 128 B direct;
reuse-heavy code with costly refills can favor the victim organization.

Each timing row is one routed implementation, not a multi-seed distribution
or a demonstrated higher operating frequency. The two-entry setup margin is
only 17 ps. Build records retain their original commit and dirty-tree flags;
all six were rebuilt at `5c1c4c0`. Documentation was updated during the batch,
while all 45 hardware/build inputs remained identical and matched that commit.
The [automatic acceptance](fpga/board_evidence/automatic_acceptance_5c1c4c0/README.md)
also repeats the 128 B direct and four-victim sessions after JTAG reload.
Both reproduce all 200 stress-batch cycle counts, not only the median.

### Earlier two-configuration comparison

The initial implementations both meet the 100 MHz target on `xc7a35tcpg236-1`, using the
same fast CPU, banked 1 KiB I-cache, board constraints and implementation
directives. MATVEC accelerators are disabled for this application comparison.

| Configuration | LUT | FF | BRAM | DSP | Setup slack (ns) | Hold slack (ns) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 64 B primary only | 7,029 | 4,741 | 2 | 4 | +0.074 | +0.037 |
| Primary + 4 victim lines | 8,493 | 5,424 | 2 | 4 | +0.050 | +0.015 |

In that implementation, the four-entry buffer costs 1,464 LUT and 683 FF at whole-SoC level, despite
adding only 64 bytes of data capacity. Associative matching, line swaps,
write ports and replacement control have real cost. This implementation is
not automatically preferable when area or streaming throughput dominates.

The original candidate's worst setup path starts at captured miss-address bit 7 and
ends at `MEMWBValue[11]`, through victim-match/completion and load selection.
The 9.882 ns data path contains 3.011 ns logic and 6.871 ns routing; a nearby
path also reaches trap-value capture. Moving lookup off the primary-hit path
does not make its completion/control fanout free. Positive 0.050 ns slack
establishes this routed 100 MHz result, not a comfortable margin or a higher
validated operating frequency.

### Datapath refinement

The refinement keeps four victim entries, the banked 1 KiB I-cache, clock,
CPU profile, constraints and implementation directives fixed. Only
`rtl/memory/cache/dcache_unit.v` changes among the FPGA build inputs.
All figures below are whole-SoC routed measurements; every row uses
2 BRAM and 4 DSP blocks.

| Four-entry implementation | LUT | FF | Setup slack (ns) | Hold slack (ns) |
| --- | ---: | ---: | ---: | ---: |
| Original, payloads move with LRU order | 8,493 | 5,424 | +0.050 | +0.015 |
| Registered matches, fixed ways, indexed writes | 8,949 | 5,426 | +0.034 | +0.039 |
| Decoded per-way victim writes | 8,583 | 5,430 | +0.179 | +0.038 |
| Shared primary fill path and decoded word writes, selected | 7,762 | 5,388 | +0.054 | +0.072 |

The selected implementation removes **731 LUT (8.61%) and 36 FF** relative
to the original four-entry implementation, while retaining the 100 MHz
target. The first fixed-way rewrite increased area: moving only LRU indices
instead of complete lines was not sufficient. Explicit per-way/word write
enables reduced the indexed-write logic, and sharing the primary-cache
refill and victim-swap write path removed duplicated fill/store selection.
DMA snoops retain their existing word-write priority.

Victim match flags are now registered at primary-miss acceptance, and payload
selection depends on the victim state rather than the late match result.
Neither change adds a request cycle. Re-running all 200 cases preserves
every recorded numeric counter, executable hash, retired trace and final
memory image. The unit test also checks captured matches against the pending
address and checks that the LRU index list remains a permutation.

The system-wide setup margin is essentially unchanged: +0.050 to +0.054 ns
is only 4 ps, not evidence of a useful frequency increase. The worst routed
path now runs from `EXMEMValid` to `EXMEMALUOut[5]`, with 9.862 ns data delay
(1.800 ns logic and 8.062 ns routing). The victim-only decoded-write variant
has more setup margin but uses 821 more LUT than the selected implementation.
These are individual constrained implementations, not a multi-seed or
maximum-frequency characterization.

The original no-victim resource row above belongs to the initial capacity
comparison; this refinement compares old and new implementations at the
same four-entry geometry. The separate default FIR image was also rebuilt
with its original 64 B parallel I-cache and zero victims: 6,709 LUT,
5,287 FF, 2 BRAM, 4 DSP, setup +0.026 ns and hold +0.071 ns at 100 MHz.
No default parameter was changed. Setup margins remain small in both images.

[Comparison checks](benchmarks/dcache/optimization/comparison.json),
[routed reports](benchmarks/dcache/optimization/implementation/) and
[publication hashes](benchmarks/dcache/optimization/publication.json)
retain all three refinement trials, including the larger first attempt.

## Earlier physical FIR comparison

The no-victim and four-victim images were programmed onto the same Basys3,
then loaded with an identical 1,888-byte FIR2 program. Both use the banked
1 KiB I-cache and 100 MHz clock. Their synthesis/build input fingerprints
are identical; the commit labels differ because verification-only changes
were committed while implementation ran. RTL inputs did not change.

Each session checked 42 directed commands and 6,608 outputs (202 directed,
6,400 sustained-stream and six example outputs), including malformed frames,
counters and absence of UART overrun. For 200 eight-tap, 32-sample batches,
the baseline always reports 9,372 compute cycles. The four-victim candidate
ranges from 7,681 to 7,684, with median 7,681: **18.04% fewer cycles**.
A second JTAG reconfiguration and firmware reload repeated the candidate
session with the same range and median, again checking all 6,608 outputs.
This tests reload reproducibility, not a manual BTN C press or visual LED check.

The selected datapath refinement was then programmed and tested in two more
JTAG/firmware-load sessions. Each again passed all 6,608 output checks with
no UART overrun. Both 200-batch captures retained the 7,681--7,684 cycle range
and 7,681 median. Firmware bytes, directed commands and stress input samples
match the original four-victim capture exactly. The
[refinement board records](benchmarks/dcache/optimization/board/) bind these
sessions to the selected build's bitstream and source hashes.

These are firmware-reported CPU processing cycles, not UART round-trip
speedup. The interactive firmware and input stream differ from the C
architecture benchmark, so the physical 18.04% and simulated 11.95%
reductions are separate observations, not contradictory measurements.

The cache remains optional. The capacity experiment changes program cycles;
the implementation refinement reduces hardware cost at unchanged capacity
and cycle counts. Streaming regressions and narrow setup margins still
matter, so all existing default cache parameters are preserved.

## Measurement boundaries

- Screened values are architectural memory-reference counts, not timing.
- Startup runs before the measured interval; an end-of-run flush is not
  added. Still-resident dirty lines are not charged as completed traffic.
- Compulsory/capacity/conflict categories use a fully associative LRU shadow
  with the same *total* data capacity, including victim storage.
- Hardware primary misses, victim hits and backing-memory fills are separate
  events. A victim hit need not reduce the existing primary-miss counter.
- RTL comparisons hold the executable, I-cache and backend constant.
  Physical board results and simulated cycles are reported separately.

The earlier [200-row table](benchmarks/dcache/measurements.csv),
[verification snapshot](benchmarks/dcache/verification.json),
[implementation reports](benchmarks/dcache/implementation/) and
[raw board responses](benchmarks/dcache/board/) are retained in Git as historical evidence.
[Publication metadata](benchmarks/dcache/publication.json) connects original
and normalized-copy hashes. Embedded tool-run hashes retain their original
meaning; publication records identify copies with checkout paths removed.

## Reproduce and inspect

```powershell
.venv/Scripts/python.exe -B scripts/architecture_benchmark.py --dcache-study
.venv/Scripts/python.exe -B scripts/architecture_benchmark.py --dcache-study --memory-latency 4
.venv/Scripts/python.exe -B scripts/architecture_benchmark.py --dcache-study --memory-latency 12
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run.ps1 -Test dcache_victim
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run.ps1 -Test external_dmem_matvec_dma
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run.ps1 -Test assert_matvec_dma_arbitration
.venv/Scripts/python.exe -B scripts/signal_console_check.py --cache-study
```

Each matrix replaces its own fixed directory under `results/architecture`;
`--smoke` uses a separate six-case context. The victim-cache unit test checks
27,216 completed accesses across twelve cache/backend configurations, including dirty
evictions, subword stores, delayed response stability, DMA snoops and reset.
DMA integration runs 64/128-byte primary caches with zero and four victims; the ownership assertion
uses four. This preserves the existing serialized DMA contract, not general
multi-master coherence. Full-SoC UART simulation covers default fast and
iterative CPUs plus all six 1 KiB I-cache / D-cache study configurations.

Build the candidate without silently replacing the default application path:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/vivado-basys3-build.ps1 -Bitstream -ArchitectureProfile fast_cpu -ICacheBytes 1024 -ICacheParallelLookup 0 -DCacheVictimLines 4 -OutDir build/vivado/dcache-victim4-word-writes -SummaryPath results/timing/dcache-victim4-word-writes.json -LogPath results/timing/dcache-victim4-word-writes.log
```

Use zero victims and distinct `dcache-baseline` paths for the paired build.
Programming is a separate explicit action; simulation or synthesis does not
establish physical-board correctness.

For the six-profile comparison, build each profile with a distinct
`dcache-capacity-<profile>` summary under `results/timing/` and a matching
directory under `build/vivado/dcache-capacity/`. Use `-DCacheBytes 128` and
zero victims for `dm128`; use 64 bytes and 0/1/2/4/8 victims for
`dm64`/`victim1`/`victim2`/`victim4`/`victim8`. All use the same flags above.
After passing implementation and the full-SoC cache matrix, an explicit
volatile JTAG load and physical test can be reproduced as follows:

```powershell
.venv/Scripts/python.exe -B scripts/signal_console_check.py --port COM3 --program --build-summary results/timing/dcache-capacity-dm128.json --xsdb C:/path/to/Vivado/bin/xsdb.bat --session capacity-dm128
```

Substitute the profile in both names for each passing implementation. This
does not write configuration Flash. A timing-failed candidate remains in the
comparison as a negative result and is not programmed at the failed clock.

Once all three matrices, six implementations and the physical sessions are
complete, publish the bounded review snapshot:

```powershell
.venv/Scripts/python.exe -B scripts/publish_cache_study.py
.venv/Scripts/python.exe -B scripts/publish_cache_study.py --check
```

Publication verifies 300 cases, identical program/retirement counts across
cache profiles, latency accounting, common FPGA inputs/constraints, and the
physical programming-to-bitstream hash chain. The `--check` command verifies
published file integrity without requiring local Vivado work directories.
The new `capacity/` snapshot is separate from the original `optimization/`
history; it does not overwrite the earlier area-reduction experiment.
