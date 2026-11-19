# Current timing and resources

The default RTL profile rebuilt at `fd52074` meets **100 MHz with +0.021 ns setup slack**
and uses **9,359 LUTs, 7,176 FFs, two BRAM tiles, and no DSP blocks**.
Hold timing, constraint coverage, and DRC also pass. This build adds the
trap, UART RX, debug-status, read-only `mip` and MMIO readback changes; it has
routed reports but no bitstream or board run. Its worst path is the existing
D-cache tag compare to control-redirect path; the same logic routed with
+0.188 to +0.263 ns in earlier builds of these changes, so the margin varies
with placement. The latest board-validated default build is `9d46f04`.

The default still uses iterative multiplication, both accelerators, a 64 B
I-cache with parallel lookup, and a 64 B direct-mapped D-cache without victims.
The optional fast multiplier retains its pipelined four-DSP, three-cycle path.
The cache-capacity study does not silently replace these defaults.
Current routed reports are in the
[implementation package](../release/implementation/basys3/README.md).

## Measured targets

| Revision | Target period | Frequency | WNS (ns) | WHS (ns) | LUTs | FFs | Timing |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Current default `fd52074` | 10.0 ns | 100.00 MHz | +0.021 | +0.034 | 9,359 | 7,176 | Met |
| Board build `9d46f04` | 10.0 ns | 100.00 MHz | +0.323 | +0.040 | 9,476 | 7,179 | Met |
| Earlier `a98a8d3` | 10.0 ns | 100.00 MHz | +0.323 | +0.040 | 9,476 | 7,179 | Met |
| Earlier `bdff5e2` | 10.0 ns | 100.00 MHz | +0.056 | +0.023 | 9,643 | 7,168 | Met |
| Earlier `adbd1db` | 10.0 ns | 100.00 MHz | +0.056 | +0.023 | 9,643 | 7,168 | Met |
| Earlier `8c7d5a6` | 10.0 ns | 100.00 MHz | +0.184 | +0.046 | 9,691 | 7,168 | Met |
| Board build `849270b` | 10.0 ns | 100.00 MHz | +0.399 | +0.018 | 9,654 | 7,166 | Met |
| Earlier `e96f878` | 9.5 ns | 105.26 MHz | +0.096 | +0.023 | 9,807 | 7,168 | Met |
| Earlier `e96f878` | 9.0 ns | 111.11 MHz | -0.265 | +0.031 | 9,860 | 7,174 | Not met |

All listed runs pass hold, constraint coverage, and DRC. The earlier 9.0-ns
experiment has -4.645 ns total negative setup slack. The tighter-period rows
describe `e96f878`; the current revision was evaluated at the deployed
10.0-ns target. Each row is one implementation rather than a distribution
across placement settings.

## Configuration changes and application performance

The current default uses 167 fewer LUTs and 11 more FFs than the earlier
`bdff5e2` result, with setup slack increasing from +0.056 to +0.323 ns.
These are whole-revision, single routed outcomes, not an isolated causal
measurement or evidence of repeatable placement improvement. The review
rebuild reproduces the preceding `a98a8d3` resource counts and setup/hold slack.
The 169-test RTL regression includes uncached CPU/DMA ownership checks.
The 90-case MATVEC snapshot was regenerated after tightening driver input
validation; its documentation records the resulting code-layout-dependent
cycle changes separately from hardware timing.

The [architecture study](architecture-evaluation.md) separately compares
iterative CPU, fast CPU, fast + Scratchpad and fast + DMA profiles. All four
were rebuilt at `5c1c4c0` and meet 100-MHz setup/hold constraints. The three
fast profiles use four DSPs with input, multiplier and output pipeline registers,
and all pass routed DRC with zero warnings. Fast-CPU setup/hold slack is
+0.067/+0.010 ns; Scratchpad is +0.399/+0.034 ns; DMA is +0.111/+0.045 ns.
Their performance benefit comes from fewer execution cycles, not a higher
clock. Fast multiply latency remains three cycles. All 380 architecture cases
were regenerated: MATVEC driver validation changed compiled layout and some
cycle counts, while the non-MATVEC counts remained unchanged. The current
tables include those driver costs rather than preserving older cycle numbers.
The [D-cache study](dcache-study.md#complete-six-profile-comparison)
has six source-identified cache implementations and physical comparisons;
all meet 100 MHz, but the two-victim setup margin is only 17 ps.

The earlier optimization work introduced the shared shifter, banked IMEM,
frontend/cache-path changes, return hints, and native MATVEC byte writes.
The [optimization history](timing_history.md) preserves those measurements
and the 9.5-ns/9.0-ns experiments.

## Current critical path

| Path | Logic levels | Data delay | Routing portion |
| --- | ---: | ---: | ---: |
| `EXMEMALUOut[5]` -> D-cache tag compare -> `cache_miss` -> trap acceptance -> `control_alignment_capture` -> `ControlRedirectPending` | 12 | 9.674 ns | 7.730 ns (79.9%) |

The limiting path starts at `soc/cpu/EXMEMALUOut_reg[5]/C` and ends at
`soc/cpu/ControlRedirectPending_reg/D`. The memory-stage address drives the
D-cache tag compare; its miss result holds the pipeline, which gates trap
acceptance and the registered control-redirect capture. Routing is about 80%
of the delay. Registering the D-cache miss or moving the redirect capture would
change pipeline cycles, so a future optimization must compare whole-design
timing and execution cycles, not only shorten this combinational path. The
earlier data-BRAM-to-`MEMWBValue` and `IDEXIR`-to-`PC` paths belong to
previous builds.

## Reproduce and inspect

Measurements used Vivado 2026.1 build 6511674, `RISCVCPU_basys3_top`,
`xc7a35tcpg236-1`, retained hierarchy, FSM extraction off, and one tool thread.
The synthesis directive was `PerformanceOptimized`; opt/place/phys-opt/route
used `ExploreWithRemap` / `Explore` / `Explore` / `NoTimingRelaxation`.

```powershell
powershell -ExecutionPolicy Bypass -File scripts/vivado-basys3-build.ps1 `
  -Implementation `
  -OutDir build/vivado/timing_current `
  -SummaryPath results/timing/current-summary.json `
  -LogPath results/timing/current-build.log
```

Add `-TimingPeriodNs 9.5` for a tighter target and use distinct output paths
for each experiment. A generated clock override leaves the board XDC intact.
Non-10-ns experiments reject bitstream generation.

The current local summary is
`results/vivado-basys3-build-summary.json`; raw reports are under
`build/vivado/basys3/reports/`. The earlier clock sweep remains
under `results/timing/native_byte_lanes/`. The generated `results/RESULTS.md`
shows matching-input runs first and groups earlier experiments separately.

The [implementation package guide](evidence/README.md) explains how to export
the measured reports for a checkout without Vivado.
