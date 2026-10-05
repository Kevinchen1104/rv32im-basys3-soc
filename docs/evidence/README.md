# Evidence packages

Use the generated `results/RESULTS.md` when working locally. It indexes current
verification and timing runs, with older inputs explicitly labeled.
Committed review snapshots are grouped by what they measure:

| Directory | Contents |
| --- | --- |
| `release/current/` | Full portable workflow, RTL regression, catalog, and available current optional-tool summaries |
| `release/implementation/basys3/` | One source-matched routed implementation, reports, and input hashes |
| `release/configuration/generic_uart_boot_runtime/` | Generic board integration configuration |
| `release/final/`, `release/fpga/` | Preserved `d7f1afe` historical release snapshots |
| [Automatic board acceptance](../fpga/board_evidence/automatic_acceptance_5c1c4c0/README.md) | Source-matched default SoC/application builds, JTAG/UART/MATVEC/FIR/viewer checks and reload records |
| [Earlier operator-confirmed board record](../fpga/board_evidence/basys3_full_direct_100mhz_2026-09-30/README.md) | The 2026-09-30 programming, UART, MATVEC measurement, and LED/BTN C observations |
| [Cache-capacity comparison](../benchmarks/dcache/capacity/) | 300 same-binary runs and six source-matched routed/physical cache configurations; checked with `scripts/publish_cache_study.py --check` |

## Public history and recorded revisions

Public updates combine development work into a release commit. The export
origin is recorded in [`SOURCE_IDENTITY.json`](../../SOURCE_IDENTITY.json).
A `source_commit` in a measurement is the original development revision, not
necessarily a commit available in this public repository. Those values and
the original measurement dates are preserved; publication is not a new
hardware measurement.

Use each package's `source-inputs.json` and artifact manifest to inspect the
actual inputs and outputs. `final-audit.ps1 -PackagedEvidence` verifies the
bundled records without requiring the complete development history or local
build directories. Adding `-RequireCurrent` verifies that the selected
packages' inputs also match this checkout; explicitly historical packages
remain labeled historical. The cache-study records separately identify their
configuration, firmware image and measured source inputs.

Fresh Quick/Full/Python checks test the public checkout. They do not turn an
earlier simulation or board result into a new physical measurement, and the
scoped Sail tests do not constitute full RISC-V compliance certification.

The dated architecture/cache simulation manifests also include the shared
`matvec_benchmark.py` reporting helper. Its report-link handling was later
updated for different Windows drives, so those complete manifests are not
byte-for-byte current. Their measured RTL, firmware and testbench inputs are
unchanged; the original records are preserved rather than relabeled as new
runs. The separate 90-case MATVEC benchmark was rerun after this change, with
identical measurement CSV values and refreshed provenance.

## Publish a portable snapshot

Commit verification inputs, run the Full workflow, then package the results:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check.ps1 -Mode Full
powershell -ExecutionPolicy Bypass -File scripts/release-freeze.ps1
powershell -ExecutionPolicy Bypass -File scripts/final-audit.ps1 -Scope portable -RequireCurrent
```

Full, regression, catalog, and coverage records must agree on input hashes and
counts. Current passing Verilator, Yosys, formal, and selected architectural
test records are included when available. Missing or different-input optional
records are listed under `omitted_optional`; a failed current record stops
publication. GCC/Unicorn's separate input domain remains under
`results/compiled-programs/`, described in [its guide](../compiled-programs.md).
The optional Sail signature-comparison summary is included in its own
`evidence/arch-test/sail/` directory when current and passing. Its original
model logs and signatures remain in the local results directory.

## Export a measured FPGA implementation

```powershell
powershell -ExecutionPolicy Bypass -File scripts/fpga-release.ps1 `
  -BoardProfile basys3 `
  -SummaryPath results/vivado-basys3-build-summary.json
```

The input hashes must match. Setup, hold, constraint coverage, and parsed DRC
must pass. Reports are copied into a self-contained review directory and
linked from `implementation.json`. Physical observations retain their own
dated source and bitstream identity. A multi-strategy sweep is a separate
experiment, not a prerequisite for exporting one measured implementation.

## Check a downloaded snapshot

```powershell
powershell -ExecutionPolicy Bypass -File scripts/final-audit.ps1 -PackagedEvidence
```

This verifies file inventory, sizes, SHA-256 hashes, gate consistency, and the
recorded source manifest. It reports input freshness as `current` or
`historical`. `-RequireCurrent` additionally rejects different current inputs
for the selected scope. Use `-Scope portable` to check only software/RTL
verification, or `implementation` / `configuration` for a specific export;
the default `all` also verifies historical snapshots and the board record.
The **Evidence integrity** CI job runs the snapshot audit; the **Check** job
tests the checkout's current source.

Publication validates a staging directory before replacing a snapshot. Failed
validation leaves the previous package untouched and retains diagnostics under
`build/release/`. Advisory wording/comment scans are independent review aids.
