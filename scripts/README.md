# Script entry points

Run scripts from the repository root with Windows PowerShell 5.1 (`powershell`).
Start with Quick for daily work, Full for complete portable verification, and
the [release / FPGA flow](../docs/reproduce.md#release--fpga) when packaging evidence.

## Interactive application

For the interactive application, use `signal_console.py` for text commands or
`signal_viewer.py` for live input/output curves. Both use the same physical UART
protocol; see [signal console setup and controls](../docs/signal-console.md).
The viewer's optional dependencies are in `signal-viewer-requirements.txt`.

## Portable verification

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check.ps1 -Mode Quick
powershell -ExecutionPolicy Bypass -File scripts/check.ps1 -Mode Full
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Test <name>
```

`check.ps1` defaults to Full. Quick checks firmware, RTL, catalog metadata, and
six representative simulations. Full runs the complete portable functional
and result-integrity checks.
Read `results/RESULTS.md` for the project index, `results/full-RESULTS.md` for Full
stages, or `results/quick-RESULTS.md` for Quick stages; the corresponding
`quick-regression.csv` or `regression.csv` lists individual test results.
Each check stage uses the shared process runner and has its own deadline/log.

`run.ps1` uses the executable test manifest. `check-test-catalog.ps1` verifies
that the schema-3 catalog stays synchronized with it. `test-catalog.ps1` expands
the three shared metadata defaults; per-test values override them, including
explicit `false` values. Reporting and release scripts use this same reader.

### Runner results and failure diagnostics

Each compilation and simulation has a 180-second deadline. Override it with
`-TimeoutSeconds 300` when needed. The runner stops at the first failing test;
a failure also propagates to `check.ps1`.

`run.ps1` writes `results/regression-summary.json` for `-Test all` and
`results/quick-regression-summary.json` for `-Test quick`, and
`results/test-summary.json` for one test, or the path supplied by `-SummaryJson`.
The summary includes overall status, attempted/requested counts, tool versions,
and per-test command arguments, exit codes, timestamps, and log paths.
Executables are under `build/sim/`. Each input context has its own summary,
compiler/simulator logs, and waveforms under `results/runs/`. A context is
identified by the summary destination, test selection, and simulator arguments.
A repeat updates the same context; Quick, Full, individual tests, and different
seeds do not overwrite each other's evidence. Log SHA-256 values are checked by
the regression evidence report.
A timeout keeps the output
captured before the tool was terminated. A missing executable is recorded as
`compile_start_failed` or `simulation_start_failed`.

Tests initially write `results/waveforms/tb_<name>.vcd`, except `main`
(`results/waveforms/dump.vcd`) and the explicit no-waveform list beside the
manifest. The runner moves each VCD into its context after simulation. A runner
lock serializes this staging step. Before each test, its old executable and
staging VCD are removed. The result's `waveform` is `null` unless that run
produced the file. A failing simulation can leave a `partial` waveform.
`-OpenWave` opens only an existing waveform and reports when a test has none.

Run `scripts/runner-self-test.ps1` to check the failure paths with isolated
synthetic testbenches. This is also part of `check.ps1`.
`scripts/workflow-self-test.ps1` checks catalog inheritance, readable summaries,
mode separation, and stale-result handling. Temporary fixtures stay under
`build/tests/`; successful runs remove them after preserving diagnostic logs.
Failed runs keep their fixture and identify it in the result summary.

`clean-artifacts.ps1` previews rebuildable simulator/tool artifacts; `-Apply`
removes the selected categories. See [artifact lifecycle](../docs/artifact-lifecycle.md)
for retention rules and optional checkpoint cleanup.

### Result formatting

All PowerShell result JSON writers use `result-format.ps1`; Python result writers
use `result_json.py`. Objects use two-space indentation. Scalar arrays stay on one
line when the line fits within 120 columns; long arrays and arrays of records
remain expanded. Files use UTF-8, LF endings, and escaped Unicode for reliable
reading with Windows PowerShell 5.1. Formatting preserves field names and values.

`result-format-self-test.ps1` is part of Full. It checks round trips, array types,
escaping, and the inventory of JSON writers across `scripts/` and `tools/`.
Golden fixture generators retain their byte-compared input format; these explicit
exceptions are checked too. Python formatter tests run with:

```powershell
.venv/Scripts/python.exe -B -m unittest discover -s scripts/tests -p test_result_json.py -v
```

Tool-native reports, waveform data, serial transcripts, and archived releases keep
their original contents. The overview separates supporting records from the main
gates and marks records without a source identity as `identity unavailable`.
Earlier verification records are collapsed separately from current results.
CPU/accelerator studies list internal RAM and synchronous BRAM as separate
matrices. FPGA records are collected from both `results/timing/` and
`results/architecture/*-implementation.json`; byte-identical copies share one
row, with all copy paths retained in `overview.json` under `aliases`. Different
builds are never merged merely because their configurations or timing agree.

### Repeated runs and result identity

Normal compiler outputs and waveforms remain available after a run. Repeating
the same command reuses its result directory and replaces its generated files;
it does not create a timestamped copy. Different test inputs/selections have
separate contexts so a subset cannot overwrite the complete result. The check,
simulation, architectural-test, C-program and benchmark runners reject overlapping
runs that share their working paths. Process-owned locks release on exit.

Verification summaries retain the input fingerprint captured at the start.
A changed fingerprint at completion makes the run fail. Cached architectural
test programs additionally require matching build-input and output hashes;
run without `-UseCachedPrograms` to rebuild an invalid cache.

### Performance-counter exports

Full uses `perf-counter-export.ps1`: it measures both scenarios once, compares
them with the separate regression expectations, and exports JSON and CSV from
the same rows. Comparator threshold self-tests use synthetic fixtures.

`perf-counter-export.ps1` is the single export entrypoint. It runs `perf_counters`
and `program_counter_loop`, then parses their current simulation logs. Use
`-SkipAssemble` only when firmware images are already current. JSON includes
the measurement time, starting source identity, and expectation-check status.

`Get-ExpectedPerfCounterRows` in `perf-counter-data.ps1` holds the separate
regression expectations. The exporter checks them by default. Use `-MeasureOnly`
to collect a deliberate performance change before reviewing its new expected
values; the JSON then says `measured`, not `pass`.

### Local firmware assembler

`assemble.ps1` is a dependency-free, two-pass assembler written for this
repository's firmware and regression flow. It supports the implemented RV32I
and RV32M instruction subset, selected machine-mode CSR instructions, labels,
the `li`, `la`, `mv`, `j`, `call`, and `ret` pseudo-instructions, and the
`.word`, `.byte`, `.half`, `.string`, and `.align` directives. It emits hex
images directly; GNU object files and relocations are outside its input format.

## Optional tool gates

### End-to-end MATVEC measurements

Run `.venv/Scripts/python.exe -B scripts/matvec_benchmark.py` to compare
software, Scratchpad and DMA-lite using GCC -O2 and the same RAM operands.
Read `results/matvec-benchmark/RESULTS.md`; it links to one counter CSV and
source/tool metadata. The complete matrix contains 90 cases. Subset runs use
separate directories and cannot overwrite the complete result.
See the [benchmark guide](../docs/matvec-benchmark.md) for measurement boundaries,
interpretation, and the optional checked publication snapshot.

### Lint, structure, formal and architecture checks

The selected architectural-test batch compiles its common RTL harness once,
then runs every program with separate signature and log files. Its overall
status is `pass` only when every selected test passes; missing prerequisites,
incomplete coverage, and failures return a nonzero exit code. The result records
whether each signature comparison used a local or official reference.

Lint, synthesis, and formal writers replace their summaries with `running`
before starting tools and record failures with an error message. Their work
directories live under `build/`; readable diagnostics are under `results/logs/`.
Formal checks allow 900 seconds per harness; use `-TimeoutSeconds` to adjust
the tool deadline without changing proof depth or assumptions.
Vivado records `execution_status` separately from overall `status`: an
implementation is successful only when the requested timing, constraint, and
DRC checks pass.

Refresh the project index after optional checks with:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/results-overview.ps1
```

The index labels current, stale, historical, and unidentified evidence from
recorded source hashes. Archived releases and physical-board records stay separate.

The [compiled C workflow](../docs/compiled-programs.md) is a separate optional
entry point: `.venv/Scripts/python.exe -B scripts/compiled_programs.py`.
It rebuilds C sources with RISC-V GCC and compares RTL retirement/data against
Unicorn. Its readable summary is `results/compiled-programs/RESULTS.md`.

```powershell
powershell -ExecutionPolicy Bypass -File scripts/verilator-lint.ps1
powershell -ExecutionPolicy Bypass -File scripts/synth-smoke.ps1
powershell -ExecutionPolicy Bypass -File scripts/formal-smoke.ps1
powershell -ExecutionPolicy Bypass -File scripts/formal-smoke.ps1 -Group Matvec
powershell -ExecutionPolicy Bypass -File scripts/vivado-detect.ps1
powershell -ExecutionPolicy Bypass -File scripts/vivado-basys3-build.ps1 -Implementation -Bitstream -OutDir build/vivado/basys3_full_100mhz_current
powershell -ExecutionPolicy Bypass -File scripts/vivado-basys3-robustness.ps1
```

Vivado timing is accepted only from a matching post-route report with
`WNS >= 0` and `TNS = 0`. Physical observations are recorded in a separate
board run. The robustness flow runs five documented implementation
directive profiles sequentially and requires all five to meet setup, hold, and
constraint checks with release-approved DRC reports. It separately reports
whether the optional `+0.200 ns`
minimum-margin target was met; that target is not the definition of timing
closure.

## Documentation review

`documentation-coverage-audit.ps1` reports whether source files have an
introductory comment. It accepts plain-language comments without fixed header
fields. Use `-Kind rtl`, `testbench`, `firmware`, or `script` to select one
category; the default `-Kind all` combines them in one report.
`claim-audit.ps1` lists wording for human review without interpreting negation
or requiring disclaimers. Both write advisory `status=completed` summaries.
They are separate from Quick/Full.

`docs-link-audit.ps1` still fails on broken local paths. The
[review checklist](../docs/documentation-review.md) covers clarity, diagrams,
result identity, and repetition.

## Generated evidence packages

```powershell
powershell -ExecutionPolicy Bypass -File scripts/release-freeze.ps1
powershell -ExecutionPolicy Bypass -File scripts/final-audit.ps1 -Scope portable -RequireCurrent
```

`release-freeze.ps1` publishes portable evidence to `release/current/`.
`release-evidence.ps1` checks required Full/regression/catalog/coverage records
and lists available current optional tools. `fpga-release.ps1` separately
exports a measured implementation or generic configuration. Shared integrity
and publication helpers live in `release-package.ps1`.

Publication checks the staged inventory before replacing the previous package.
`final-audit.ps1 -PackagedEvidence` verifies a downloaded snapshot and reports
source freshness; `-RequireCurrent` additionally rejects historical inputs.
`-Scope portable` keeps this check independent of FPGA exports; the default
`-Scope all` also checks implementation/configuration and historical snapshots.
The original `release/final/` and `release/fpga/` snapshots remain unchanged.
See the [package guide](../docs/evidence/README.md) for commands and CI behavior.

Hardware programming and serial-board scripts are intentionally separate from
all verification and release gates; none of the commands above opens a serial
port or programs a device.
