# Reproduce the results

Run commands from the repository root using Windows PowerShell 5.1 (`powershell`).
Keep the checkout path short, for example `C:\src\rv32im-basys3-soc`;
deeply nested checkouts can exceed the path-length limit in the Full self-tests.

## Python tools and the FIR application

After the [native Python setup](compiled-programs.md), install the two requirement
files and run the common unit-test entry point:

```powershell
.venv/Scripts/python.exe -m pip install -r scripts/signal-viewer-requirements.txt -r tools/compiled-programs/requirements.txt
.venv/Scripts/python.exe -B scripts/python_tests.py --gui
```

This requires no board or RISC-V compiler. The result and log go to
`results/python-tests/`. Omit `--gui` only when a desktop is unavailable; the
skipped Tk test stays visible in the count. The same test command runs in CI.
The [signal application guide](signal-console.md) covers firmware/FPGA builds,
the unified startup command, reset/power-loss recovery and physical validation.
Quick/Full below keep their original PowerShell and Icarus prerequisites.

## Quick and Full checks

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check.ps1 -Mode Quick
powershell -ExecutionPolicy Bypass -File scripts/check.ps1 -Mode Full
```

Quick runs four stages: firmware freshness, static RTL checks, catalog validation,
and six representative simulations. Read `results/quick-RESULTS.md`.

Full assembles/checks deterministic firmware and fixtures, runs static
audits, executes the full directed regression, creates the regression evidence
summary, and runs the portable FPGA wrapper smoke.

Read `results/RESULTS.md` first, then `results/regression.csv` for test-by-test
status. `results/full-RESULTS.md` lists the Full stages. The index labels saved
results against the current source inputs; refresh it after optional checks with
`powershell -ExecutionPolicy Bypass -File scripts/results-overview.ps1`.
JSON files retain machine-readable details. Each stage has its own log
under `results/logs/check/quick/` or `results/logs/check/full/`; the report links
to it. A failed stage stops the gate and records its name and log.

JSON uses two-space indentation and compact short scalar arrays. Full checks
that the registered result writers use this shared format.
The overview's supporting-record section includes auxiliary
summaries and their freshness status; a recorded PASS without a matching source
identity is not treated as a current verification gate.

`run.ps1 -Test <name>` reruns one test. `run.ps1 -Test quick` runs only the six
Quick simulations; it does not run the other Quick checks.

## Artifact layout

- `build/sim/`: Icarus executables.
- `build/tests/`: isolated fixtures; successful runner/workflow/integrity tests
  remove their temporary inputs and keep logs under `results/logs/self-tests/`.
  Failed tests retain their fixture path in the summary.
- `build/reference/`: extra-seed generated trace inputs.
- `build/arch-test/`: compiled architectural-test programs and one shared simulator per batch.
- `results/`: current reports and JSON/CSV summaries.
- `results/runs/`: isolated simulation summaries, command logs, and VCD files.
- `results/logs/`: workflow, lint, synthesis, and formal command logs.
- `results/archive/`: retained logs from older output layouts.
- `release/`: recorded release snapshots.

The scripts create their output directories as needed. `build/` and `results/`
are ignored by Git. Historical `wave/` outputs are retired; required physical
captures are preserved beside their dated board record. Quick and Full summaries are separate. Repeating the
same test with the same summary destination and simulator arguments replaces
only that context's logs and VCDs; a different context has its own directory.

The development checkout is where source edits, tests, and local commits belong.
Exported public snapshots belong outside the development checkout. Preserve
their Git metadata and local changes before retiring them. `release/` contains
the compact recorded packages; publish updated packages deliberately.

### Disk usage and cleanup

Icarus creates a `.vvp` executable for each test. Full regression can leave
hundreds of MiB in `build/sim/`; these are compiled copies, not source files.
The runner recompiles them on the next invocation. After simulations finish,
preview or remove them with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/clean-artifacts.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/clean-artifacts.ps1 -Apply
```

Default cleanup covers simulator executables in `build/sim/`,
`build/arch-test/`, `build/compiled-programs/` and legacy `wave/`, plus Vivado
root scratch files. The tool refuses tracked files, linked paths and active
hardware/simulation tools. An applied cleanup records every removed file in
`results/cleanup-summary.json`. `clean-simulators.ps1` remains an alias for
the simulator-only category.

Optional categories are `LegacyFormal` (old generated subdirectories beside
the formal sources) and `RetiredCheckpoints` (old `.dcp`/`.rtd` files). The
latter requires explicitly selected `-RetiredBuildDirectory` paths under
`build/vivado/`; it does not infer retirement from a directory's name or age.
All categories preserve reports, bitstreams, current result
JSON/logs/waveforms, release packages, third-party dependencies and `.venv`.
Review the [artifact lifecycle](artifact-lifecycle.md) before retiring evidence.

Vivado experiments should use separate output directories. Keep their text
reports and source-identified summaries when retiring a checkpoint; do not
delete an entire build directory while implementation is running.

Vivado build/program processes run inside their `build/vivado/` work directory;
native logs, journals and ancillary timing diagnostics stay there.

### Selected architectural-test dependency

`tools/arch-test/rv32im-selected.json` pins the exact upstream revision and the
three required source directories. Setup uses Git sparse checkout while keeping
upstream root license/readme files and Git identity:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/arch-test-setup.ps1
powershell -ExecutionPolicy Bypass -File scripts/arch-test-run.ps1
```

An existing matching checkout is reused without fetching. Local changes or a
different revision stop setup without discarding work. `-NoUpdate` remains
accepted for older commands; matching pinned checkouts never update implicitly.

## GCC / external-model checks

The [compiled C flow](compiled-programs.md) builds four programs at three
optimization levels and compares their retired instructions and data RAM with
Unicorn. It has separate dependencies and results, so Quick/Full remain usable
without a RISC-V compiler or Python emulator package.

After the one-time environment setup in that guide:

```powershell
.venv/Scripts/python.exe -B scripts/compiled_programs.py
```

Read `results/compiled-programs/RESULTS.md`; build outputs are under
`build/compiled-programs/`.

## Focused accelerator gate

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Test mmio_decode -SkipAssemble
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Test mmio_read_mux -SkipAssemble
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Test int8_matvec_scratchpad_accelerator -SkipAssemble
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Test matvec_perf_counters -SkipAssemble
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Test int8_matvec_dma_lite -SkipAssemble
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Test program_matvec_scratchpad -SkipAssemble
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Test program_matvec_dma_demo -SkipAssemble
powershell -ExecutionPolicy Bypass -File scripts/formal-smoke.ps1 -Group Matvec
```

## Optional local tools and audits

```powershell
powershell -ExecutionPolicy Bypass -File scripts/verilator-lint.ps1
powershell -ExecutionPolicy Bypass -File scripts/synth-smoke.ps1
powershell -ExecutionPolicy Bypass -File scripts/formal-smoke.ps1 -TimeoutSeconds 3600
powershell -ExecutionPolicy Bypass -File scripts/docs-link-audit.ps1
powershell -ExecutionPolicy Bypass -File scripts/documentation-coverage-audit.ps1
powershell -ExecutionPolicy Bypass -File scripts/claim-audit.ps1
powershell -ExecutionPolicy Bypass -File scripts/final-audit.ps1
```

Formal solve time varies by solver and host. The command above allows up to
one hour per harness; the wrapper's default is 900 seconds. `-TimeoutSeconds`
controls wall-clock time, while each `.sby` file sets the verification depth.
A timeout leaves an incomplete check and preserves its log for inspection.

Comment coverage and wording reports are advisory; see the
[documentation review checklist](documentation-review.md). Broken local links
remain an integrity error.

## Release / FPGA

To inspect a downloaded snapshot's integrity and source freshness:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/final-audit.ps1 -PackagedEvidence
```

The audit checks artifact hashes and recorded gate identities, then reports
whether the inputs match the checkout. Add `-RequireCurrent` to reject historical
inputs. Quick and Full leave recorded releases untouched.

For a new FPGA result, follow [the Basys3 flow](../fpga/boards/basys3/README.md).
Implementation needs Vivado; physical measurements additionally need the board.

After committing verification inputs and completing Full, publish a portable
snapshot with:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/release-freeze.ps1
powershell -ExecutionPolicy Bypass -File scripts/final-audit.ps1 -Scope portable -RequireCurrent
```

This writes `release/current/` from current source-matched verification.
Optional missing/different-input tools are listed explicitly; current failures
stop publication. Export a routed implementation separately:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/fpga-release.ps1 `
  -BoardProfile basys3 `
  -SummaryPath results/vivado-basys3-build-summary.json
```

This writes `release/implementation/basys3/` after checking source hashes,
setup, hold, constraints, and DRC. Generic board configuration can be exported
with `-BoardProfile generic_uart_boot_runtime`. The existing `release/final/`
and `release/fpga/` directories preserve earlier evidence. See the
[package guide](evidence/README.md) for inventory checks and CI behavior.

Missing tools and unperformed board runs are recorded as `blocked` or
`not_run`, with the reason in the corresponding summary.
