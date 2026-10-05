# Timing optimization history

This is the retained experiment narrative through RTL revision `e96f878`
(2026-09-29). Counts below describe those historical runs. Start with
[current timing and resources](timing_baseline.md) for the selected design;
the generated `results/RESULTS.md` reports current verification freshness.

The retained RTL (`e96f878`) adds I-cache return hints and MATVEC byte-write
enables to the banked-IMEM/frontend/cache baseline. At **100 MHz**, setup
slack improves from **0.124 ns to 0.399 ns**, with **9,654 LUTs** versus
9,595 previously: 59 additional LUTs (0.6%). No pipeline stage or instruction
cycle was added. This version also meets **9.5 ns (105.26 MHz)**; its 9.0-ns
experiment does not meet setup timing.

The Basys3 clock and recorded physical run remain at 100 MHz. These newer
measurements come from routed Vivado implementations; no new bitstream was
generated or programmed during this comparison.

## Measurement setup

- Run date: 2026-09-29; Vivado 2026.1, build 6511674.
- Top: `RISCVCPU_basys3_top`, default parameters; part `xc7a35tcpg236-1`.
- Board profile: 100 MHz (10 ns), using the existing Basys3 XDC.
  Separate implementation experiments target 9.5 ns and 9.0 ns.
- Synthesis: `PerformanceOptimized`, hierarchy retained, FSM extraction off.
- Implementation: `ExploreWithRemap` / `Explore` / `Explore` /
  `NoTimingRelaxation` for opt / place / phys-opt / route; one tool thread.
- Each table reports one implementation per revision and target period.
  Setup, hold, constraint coverage, and DRC are checked separately.

## Return-hint and byte-write results

| RTL | Target period | WNS (ns) | WHS (ns) | LUTs | FFs | Timing |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Baseline `5110399` | 10.0 ns | +0.124 | +0.036 | 9,595 | 7,158 | Met |
| Retained `e96f878` | 10.0 ns | +0.399 | +0.018 | 9,654 | 7,166 | Met |
| Baseline `5110399` | 9.5 ns | +0.139 | +0.034 | 9,568 | 7,160 | Met |
| Retained `e96f878` | 9.5 ns | +0.096 | +0.023 | 9,807 | 7,168 | Met |
| Baseline `5110399` | 9.0 ns | -0.099 | +0.039 | 9,663 | 7,171 | Not met |
| Retained `e96f878` | 9.0 ns | -0.265 | +0.031 | 9,860 | 7,174 | Not met |

The first return-hint/byte-write candidate (`3aeaad9`, measured at
`0bc5c5e`) already met all three targets, but the scratchpad word merge
introduced an unnecessary second array read. The retained version uses
per-byte storage enables and the existing selected-row readback register
for preserved bytes. At 100 MHz this refinement reduces usage from 9,789
to 9,654 LUTs and raises WNS from 0.159 to 0.399 ns.

| First candidate target | WNS (ns) | WHS (ns) | LUTs | FFs |
| --- | ---: | ---: | ---: | ---: |
| 10.0 ns | +0.159 | +0.043 | 9,789 | 7,166 |
| 9.5 ns | +0.080 | +0.030 | 9,930 | 7,174 |
| 9.0 ns | +0.009 | +0.035 | 10,007 | 7,177 |

Its 9.0-ns result has only 9 ps of setup margin. The measurements are kept
as individual experiments rather than a guarantee across placement seeds
or implementation settings. Every row uses two BRAM tiles and no DSP blocks.

The native-byte version is retained for its larger margin at the deployed
100-MHz clock and lower LUT count than the first candidate at all three
targets. The first candidate remains a measured 9.0-ns option, not the
current RTL. All runs pass hold, constraint coverage, and DRC. The retained
9.0-ns run has -4.645 ns total negative setup slack; its failed timing check
also makes the build's overall status fail even though Vivado executed
successfully. The passing runs have zero total negative setup/hold slack.

The 100-MHz gain does not imply that every clock constraint gains the same
slack: at 9.5 ns the retained version has 0.096 ns versus the baseline's
0.139 ns. Placement, routing, and the worst endpoint change with the target.

### Remaining critical paths

| Target | Worst routed path | Logic levels | Data delay | Routing portion |
| --- | --- | ---: | ---: | ---: |
| 10.0 ns | EX/MEM forwarding selection -> store-alignment/trap qualification -> `PC[14]` | 12 | 9.494 ns | 7.179 ns |
| 9.5 ns | `EXMEMForwardUsePCPlus4` -> execute forwarding/ALU -> `EXMEMALUOut[6]` | 9 | 9.283 ns | 7.337 ns |
| 9.0 ns | `EXMEMValid` -> execute forwarding/shifter -> `EXMEMALUOut[6]` | 10 | 9.232 ns | 7.536 ns |

These worst paths are different from the baseline's I-cache/RAS and
MMIO/MATVEC paths. At 9.0 ns, forwarding and the shared shifter now form the
limiting path, with 82% of its delay in routing. Any further edit should be evaluated against
whole-design routed timing and cycle counts, since optimizing one path can
move the limiting endpoint elsewhere.

### Verification of the retained changes

The following counts describe verification at the time of the RTL comparison.
The current workflow also includes the result-format/writer-inventory self-test;
see `results/RESULTS.md` for its latest stage count and evidence.

- Full workflow: 29/29 stages, including 164/164 RTL simulations and eight
  FPGA-wrapper elaborations. Quick: 4/4 stages and 6/6 simulations.
- GCC/Unicorn: 12/12 compiled-program comparisons, with unchanged images,
  retired instructions, cycle counts, stalls, cache misses, and result words.
- Selected upstream architectural tests: 36/36 DUT signatures matched the
  local independent RV32IM reference.
- Verilator: nine tops. Yosys: fourteen tops. Bounded formal: seven core
  harnesses and one Scratchpad harness at their existing depths.
- Byte-write tests cover every byte and halfword lane, low-byte control/index
  qualification, and full-word firmware. The formal checks include disabled
  byte preservation and coherence between the selected row and its readback.

The generated `results/RESULTS.md` links the current evidence and labels older
source identities. Raw implementation reports remain in the build directories
listed at the end of this page.

## Earlier 100-MHz routed comparison

| Revision | Change | WNS (ns) | WHS (ns) | LUTs | FFs |
| --- | --- | ---: | ---: | ---: | ---: |
| `5c9e03d` | Registered forwarding | +0.179 | +0.050 | 12,487 | 7,158 |
| `87fdf6a` | Shared shifter | +0.135 | +0.019 | 12,024 | 7,158 |
| `2f80e9c` | Add banked IMEM | +0.063 | +0.028 | 9,476 | 7,158 |
| `c20bbc2` | Separate exception requests | +0.009 | +0.033 | 9,570 | 7,158 |
| `5110399` | Add state-selected cache payload | +0.124 | +0.036 | 9,595 | 7,158 |
| `611e3a8` | Parallel alignment candidates (not retained) | +0.127 | +0.047 | 9,532 | 7,152 |

All rows have zero total negative setup/hold slack, two BRAM tiles, and no
DSP blocks. The `5110399` implementation uses 8,891 logic LUTs and 704 memory
LUTs (46.13% of device LUTs in total). It retains most of the earlier area
savings: 23.2% fewer total LUTs than `5c9e03d`. Whole-design mapping changes
can alter resource counts in modules whose RTL was not edited.

The request-only experiment did not improve timing. The combined `5110399`
version was selected as the next baseline for its small setup/hold-margin improvement at a cost of 119 LUTs
over `2f80e9c`. These measurements use one implementation per revision under
the same settings; the configured clock remains 100 MHz. The later parallel
candidate's 3-ps gain is too small to support a useful timing-improvement
claim from one implementation per version. Its 63-LUT reduction (0.7%)
also does not justify the extra candidate datapaths and interface signals.
The candidate was reverted in `e0f81ce`; its measurements and proof remain
available for comparison.

The earlier `bf6ef16` baseline had 0.039 ns setup slack and 12,499 LUTs.
Registered write qualification raised its slack to 0.179 ns before the two
area optimizations above. The
[2026-07-30 board record](./fpga/board_evidence/basys3_full_direct_100mhz_2026-07-30/README.md)
continues to identify the previously programmed `d7f1afe` bitstream.

## Earlier target-period exploration

The same baseline RTL (`5110399`, measured with the `1735b01` timing-flow
update) was implemented under tighter clock constraints:

| Target period | Frequency | WNS (ns) | WHS (ns) | LUTs | FFs | Timing |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 10.0 ns | 100.00 MHz | +0.124 | +0.036 | 9,595 | 7,158 | Met |
| 9.5 ns | 105.26 MHz | +0.139 | +0.034 | 9,568 | 7,160 | Met |
| 9.0 ns | 111.11 MHz | -0.099 | +0.039 | 9,663 | 7,171 | Not met |

Both tighter runs passed constraint coverage and DRC. The 9.0-ns run has
-0.262 ns total negative setup slack; the other two have zero negative
setup slack, and all three have zero negative hold slack. Each uses two
BRAM tiles and no DSP blocks. Mapping and physical optimization can change
LUT/FF counts even when the RTL is identical.

The 9.5-ns result establishes a higher passing implementation target for the
baseline, not a speedup caused by a new RTL change. No pipeline cycles were
changed in this experiment. At a physically supplied 105.26-MHz clock, an
unchanged-cycle program would take 5% less time than at 100 MHz; the board
configuration and recorded board run still use 100 MHz.

The worst path changes with placement and routing. At 9.5 ns it runs from
`EXMEMALUOut[28]` through MMIO decoding to the MATVEC
`selected_row_data_readback[9]` register: nine logic levels, 9.440-ns data
delay, of which 7.730 ns is routing. At 9.0 ns the worst path runs from an
I-cache tag through instruction selection and return-address prediction
to `PC[3]`: nine logic levels, 8.960-ns data delay, of which 7.120 ns is
routing. A local change to the earlier alignment path therefore needs a
whole-SoC measurement before it can be treated as a frequency improvement.

The parallel candidate at 9.0 ns also finishes with **-0.099-ns WNS**,
**-0.538-ns TNS**, **+0.034-ns WHS**, 9,688 LUTs, and 7,158 FFs.
Constraint coverage and DRC pass, but setup timing does not. Its worst
path runs from `PC[18]` through the I-cache/prediction path back to `PC[4]`.
Neither of these earlier 9.0-ns implementations met setup timing.

## What changed and why

### I-cache return predecode and MATVEC byte writes

The `3aeaad9` change targets the two paths identified in the tighter-period
runs. Neither change adds a pipeline stage or changes instruction latency.

The I-cache stores a one-bit return-instruction hint beside each cached word.
Refill computes the hint once; a hit selects that bit with the same set, way,
and word offset as the instruction. The RAS uses the hint instead of decoding
the selected 32-bit instruction on the tag-to-PC path. The cache adds 16 hint
bits. The uncached configuration keeps the equivalent combinational decode.
Tests compare the hint with the fetched instruction and check return, non-return,
refill, reset, and invalidation behavior.

MATVEC stores now deliver aligned write data and four byte-enable bits to the
accelerator. The vector and scratchpad write only the enabled byte lanes.
Previously, the CPU selected the addressed register's old value, merged the
subword store, and sent the resulting word back through the write decoding.
Removing that shared read-modify-write mux shortens the EX/MEM-address-to-MATVEC
path. Low-byte enables also gate the control and index fields, so an upper-byte
store cannot start an operation or change an index. Tests exercise all four
byte lanes, both halfword lanes, index/control upper-byte writes, and existing
full-word firmware behavior.

The first implementation read the selected row again to merge old bytes.
`e96f878` removes that extra read mux: the already-maintained
`selected_row_data_readback` supplies preserved bytes for the readback update,
and per-byte enables update the scratchpad itself. A formal assertion checks
that the shadow register equals the selected scratchpad row after reset,
including simultaneous row-index and row-data writes.

All twelve GCC/Unicorn cases retain identical program images, cycle counts,
retired-instruction counts, stalls, cache misses, and result signatures relative
to the pre-change baseline. Functional results are indexed in the generated
`results/RESULTS.md`.

### Registered forwarding qualification

In [`riscv_cpu_core.v`](../rtl/core/riscv_cpu_core.v), `IDEXWritesRegister`
already excludes x0 before destination/write metadata enters EX/MEM.
MEM/WB also qualifies its registered write flag with incoming stage validity.
Forwarding reuses those properties instead of checking them again on the
operand path. EX/MEM retains its Valid check because a bubble can retain old
write metadata. Tests check these invariants and the original qualification
expressions.

### One shared shifter

[`riscv_alu.v`](../rtl/core/execute/riscv_alu.v) now shares one variable right
shifter across SLL/SRL/SRA and their immediate forms. Reversing the input and
output bit order implements a left shift; a one-bit extension selects zero
or sign fill. The opcode selects the five-bit amount from `rhs` or `imm_i`.
Instruction legality checks, result selection, and pipeline latency stay
unchanged.

The preceding critical path ran from the rs2 register match through forwarding
and the ALU; `rhs[3]` drove 160 loads. Sharing the shifter reduced ALU usage
from 1,061 to 573 LUTs in the isolated experiment. Overall slack nevertheless
fell to 0.135 ns as the worst path moved to the instruction-cache/predictor
feedback into PC. This is why the complete routed design is measured after
each change, rather than inferring timing from the smaller ALU.

### Four instruction-memory banks

[`uart_packet_boot_imem.v`](../rtl/boot/uart/uart_packet_boot_imem.v) previously
read four addresses from a single word array. The implementation used 2,816
memory LUTs. A line always contains words `4*k` through `4*k+3`, so each word
can live in a separate bank at row `k`:

- Word address `w` writes bank `w % 4`, row `w / 4`.
- A line read takes one word from each bank at the same row.
- UART payload, tail cleanup, and error cleanup each update one bank per cycle.

At 1,024 words, Vivado infers four 256-by-32 banks. Memory LUT usage drops
to 704, a **75% reduction**. Reads remain combinational; the packet parser,
CPU-release timing, NOP padding, and capacity are unchanged. Partial lines
and high-address reads preserve their per-word bounds checks.

### Pending exception requests before acceptance

The `c20bbc2` change separates `exception_pending` from `exception_taken`.
Previously, D-cache backpressure qualified an immediate exception before
that signal entered the redirect request and target muxes; frontend control
then applied the memory-stall guard again. Now the frontend selects a pending
exception, mret, interrupt, or control-recovery target before acceptance.
The final PC/stage update still waits for backpressure to clear, and CSR
updates continue to use accepted trap entry. No stage or cycle was added.

The integrated combinational test compares 8,192 combinations of validity,
redirect state, memory faults/holds, alignment faults, illegal instructions,
mret, interrupts, and frontend stalls against the previous PC and acceptance
equations. Directed load-miss tests additionally check that the pending trap
target is visible while PC and CSR state remain held, followed by one trap
entry on release.

An additional Yosys SAT check extracts the affected assignments from the
current core and instantiates the actual redirect and pipeline-control
modules. Arbitrary control inputs and 32-bit PC candidates produce the same
next PC, eight stage-control outputs, and exception/mret/interrupt acceptance
as the previous equations. The extraction script and proof log are retained
in `results/timing/redirect_request/`; the generated model is
`build/frontend_equivalence.sv`, generated by
[`scripts/timing/prove_frontend.ps1`](../scripts/timing/prove_frontend.ps1).

The request-only change passed functional checks but routed at 0.009-ns
setup slack and 9,570 LUTs. Its worst path moved to MMIO/access-fault
qualification, D-cache hit, read-data selection, and MEM/WB writeback.
It did not improve whole-design timing by itself.

### Registered-state cache payload selection

In `5110399`, [`dcache_unit.v`](../rtl/memory/cache/dcache_unit.v) selects
refill data in `CACHE_REFILL` and the cache word otherwise. The separate
`load_word_valid` signal still checks a read hit or accepted refill; the CPU
uses this valid signal to capture the data. Tag/MMIO/access-fault qualification
therefore no longer selects the 32-bit payload before load formatting.

An additional SAT proof extracts the relevant assignments and checks arbitrary
states, request flags, ready signals, and 32-bit candidate words. Every valid
response matches the previous hit-selected expression. The proof and extraction
script are saved in `results/timing/refill_data_select/`.

### Parallel low-address candidates

The `611e3a8` experiment moved the two-bit load/store address additions
ahead of the forwarding selection. The ID/EX, EX/MEM, and MEM/WB source
values each form a load candidate and a store candidate in parallel with
register matching. The late forwarding decision then selects one completed
candidate, preserving EX/MEM priority over MEM/WB. The full 32-bit execute
operand and the pipeline registers were unchanged.

The candidate's alignment test enumerated 4,096 combinations of source low bits,
load/store offsets, and producer selections. A Yosys SAT proof also checks
arbitrary forwarding inputs and offsets against the previous
`forwarded_operand[1:0] + offset[1:0]` equations. The proof covers all
combinational inputs, including simultaneous EX/MEM and MEM/WB matches.
At 100 MHz the worst path changed from 14 levels and 9.837-ns data delay
to 11 levels and 9.718 ns. Different clock skew and routing left only the
3-ps setup-slack gain shown above, so the simpler original datapath remains.

A later cleanup (`ea6b9fa`) makes the three IMEM bank/row width conversions
explicit. It removes Verilator truncation warnings without changing the
expressions' values; a separate SAT check covers widths 1 through 32.
The Vivado experiments identify the earlier source revision in their
summaries, while simulation and lint also cover this width-only cleanup.

## Earlier alignment bottleneck

The `5110399` implementation's worst setup path is:

```text
IDEXIR[17] (rs1 selector)
  -> forwarding match and low-address operand selection
  -> store-address alignment check
  -> exception_pending and redirect request
  -> frontend redirect/PC selection
  -> PC[4]
```

It has 14 logic levels and a 9.837-ns data-path delay: 2.254 ns in logic
and 7.583 ns in routing (77.09%). `exception_pending` drives 94 loads and
`if_redirect` drives 132. This path motivated the parallel low-address
experiment while keeping precise trap acceptance unchanged.

For comparison, the `2f80e9c` worst path ran from `EXMEMALUOut[5]` through
D-cache hit/miss and accepted-exception qualification into `PC[4]`. The
request-only version moved the worst path to cache load-data selection;
the combined change moves it again to alignment-exception recovery.

## Earlier validation

Both the then-selected `e0f81ce` version and the candidate `ea6b9fa` version passed:

- Full workflow: **31/31 stages and 164/164 RTL tests**.
- GCC/Unicorn: **12/12 cases**. Firmware images, cycles, retired instructions,
  stalls, and cache misses match the `5110399` baseline.
- Verilator lint: all nine top-level configurations.
- All eight existing bounded-formal harnesses, including forwarding/alignment
  equivalence and MATVEC Scratchpad control.

The candidate's additional forwarding SAT proof and the shared IMEM
width-conversion SAT proof also passed.

The preceding `5110399` checks also covered:

- ALU: **13,056 shift checks**, covering 68 patterns, all 32 amounts, and
  six shift instructions, plus CPU forwarding dependencies.
- Banked IMEM: ten capacities (`1, 2, 3, 4, 5, 7, 9, 17, 1024, 1025` words),
  checking every word/lane, full images, shorter reloads, error scrubbing,
  retries, byte-address alignment, and out-of-range reads.
- ALU formal comparison: Yosys 0.56 proved all combinational assertions
  against the existing independent reference expressions, including
  unsupported decode combinations.
- Frontend and cache-payload SAT checks passed, as described above. The
  frontend simulation also passed all 8,192 boundary-input combinations.

The original loader tests now inspect the line-read interface instead of
depending on the internal memory-array layout.

Reproduce the combinational ALU proof with:

```powershell
yosys -p "read_verilog -formal rtl/core/execute/riscv_alu.v formal/alu_result_classification.sv; prep -top alu_result_classification -flatten; chformal -lower; sat -verify -prove-asserts"
```

## Reproduce the hardware measurements

From the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/vivado-basys3-build.ps1 `
  -Implementation `
  -OutDir build/vivado/timing_current `
  -SummaryPath results/timing/current-summary.json `
  -LogPath results/timing/current-build.log
```

The summary records source identity, implementation settings, timing,
constraints, DRC, and resources. The output's `reports` directory includes:

- `post_route_timing_summary.rpt`: setup/hold slack and constraint coverage.
- `post_route_critical_paths.rpt`: detailed paths by clock group.
- `post_route_top50_paths.rpt`: 50 worst setup paths, one per endpoint.
- `post_route_hierarchy.rpt`: resource ownership by module.

To explore a tighter target while keeping the board XDC unchanged, add
`-TimingPeriodNs 9.5` (105.26 MHz) or `-TimingPeriodNs 9.0` (111.11 MHz).
The script reads a generated clock-override XDC after the board constraints,
then reruns synthesis, placement, and routing. The summary records the target
period and `clock_profile=timing_experiment`. Each output directory also owns
its native Vivado log/journal so independent experiments do not overwrite
one another. A non-10-ns override rejects bitstream generation and alternate
tops; the physical board remains on its 100-MHz oscillator.

The same-name override follows AMD's
[create_clock semantics](https://docs.amd.com/r/2021.2-English/ug835-vivado-tcl-commands/create_clock).

Local experiment outputs are retained in matching directories:

| Revision | Build directory | Result directory |
| --- | --- | --- |
| `bf6ef16` | `build/vivado/timing_baseline_bf6ef16/` | `results/timing/bf6ef16/` |
| `5c9e03d` | `build/vivado/timing_registered_forwarding/` | `results/timing/registered_forwarding/` |
| `87fdf6a` | `build/vivado/timing_shared_shifter/` | `results/timing/shared_shifter/` |
| `2f80e9c` | `build/vivado/timing_banked_imem/` | `results/timing/banked_imem/` |
| `c20bbc2` | `build/vivado/timing_redirect_request/` | `results/timing/redirect_request/` |
| `5110399` | `build/vivado/timing_refill_data_select/` | `results/timing/refill_data_select/` |
| `1735b01`, baseline RTL | `build/vivado/sweep_9p5/`, `build/vivado/sweep_9p0/` | `results/timing/period_sweep/` |
| `611e3a8`, parallel candidates | `build/vivado/sweep_alignment_9p0/`, `build/vivado/sweep_alignment_10p0/` | `results/timing/parallel_alignment/` |
| `3aeaad9`, return hint and word-merged writes | `build/vivado/predecode_bytewrites_10p0/`, `_9p5/`, `_9p0/` | `results/timing/predecode_bytewrites/` |
| `e96f878`, native byte lanes | `build/vivado/native_byte_lanes_10p0/`, `_9p5/`, `_9p0/` | `results/timing/native_byte_lanes/` |

Use a separate output directory for each experiment and compare both timing
and resources under the same settings.
