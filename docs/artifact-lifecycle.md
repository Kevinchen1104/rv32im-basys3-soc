# Artifact lifecycle

| Content | Location | Retention |
| --- | --- | --- |
| Design, tests and hand-written tooling | `rtl/`, `tb/`, `scripts/`, `formal/`, `tools/` | Git tracked |
| Generated simulator/program/formal work | `build/` | Rebuildable; selected cleanup categories |
| Latest source-identified evidence | `results/` | Keep summaries and the files they reference together |
| Timing experiments | `results/timing/` and `build/vivado/` | Keep text reports; retire unnecessary checkpoints |
| Physical measurements | `docs/fpga/board_evidence/<date>/` | Immutable records and raw captures |
| Published evidence packages | `release/` | Preserve until explicitly replacing a release |
| Upstream architecture tests | `external/riscv-arch-test/` | Pinned sparse checkout; never edit individual upstream files |
| Python dependencies | `.venv/` | Recreate from `tools/compiled-programs/requirements.txt` and `scripts/signal-viewer-requirements.txt` |

## Daily cleanup

From the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/clean-artifacts.ps1
powershell -ExecutionPolicy Bypass -File scripts/clean-artifacts.ps1 -Apply
```

The default categories are `Simulators` and `ToolScratch`. Preview is read-only;
add `-ListFiles` to inspect every candidate path and size.
Use `-Category RetiredCheckpoints -RetiredBuildDirectory build/vivado/<old-run>`
to preview checkpoint cleanup for a build you have explicitly retired, then
add `-Apply` after reviewing it. The script does not scan all builds and guess
which are obsolete. The named native-byte-lane experiments and historical
canonical board build remain protected. Keep checkpoints needed for active
builds or further timing analysis outside the selected directories.
No category removes current result waveforms or logs, bitstreams, dependencies,
release packages, source files or nested Git repositories.

Runner/workflow/integrity self-tests delete successful fixtures automatically.
Their latest diagnostic logs remain in `results/logs/self-tests/`. A failed
self-test retains its fixture for inspection rather than silently cleaning it.

## Source and evidence are separate

Timing proof sources live in [formal/experiments](../formal/experiments/README.md)
and `scripts/timing/`; their generated harnesses and logs are disposable only
when the corresponding experiment no longer needs them. A `build/` or
`results/` directory must not be the only copy of hand-written source.

`fpga/boards/basys3/board.json` holds hardware configuration and selects a dated
physical record. The evidence reader derives measurement fields from that
record instead of copying PASS, WNS and bitstream hashes into the board config.
Original capture paths inside historical records remain unchanged; the reader
resolves old `wave/` paths to byte-identical files in the record's `captures/`
directory. Existing physical summaries and release package hashes stay intact.

## Retiring an old checkout

Exported repositories should not remain nested in the active checkout. Archive
their complete contents, including `.git`, uncommitted changes and untracked
files. Verify archive entries against original file hashes before removing the
copy. An old checkout is not automatically disposable merely because `dist/`
is ignored. Local migration archives and their manifests live outside this
repository; `results/artifact-migration.json` records their locations.

Keep result JSON files separate by test/experiment and use `results/RESULTS.md`
as the common entry point. Merging unrelated tool logs or summaries would lose
their independent source identity and failure context.
