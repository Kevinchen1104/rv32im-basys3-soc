# Portable verification snapshot

Source revision: `fd520745fcf361b09d164b77cb4568241c9593e6`.

Full workflow: 31 stages; RTL regression: 173 tests.

Read `package.json` for included gates and omitted optional tools; `evidence/` contains their recorded summaries.

`source-inputs.json` identifies the tested input files. `artifacts.json` checks every packaged file by size and SHA-256.

Verify integrity with `powershell -File scripts/final-audit.ps1 -PackagedEvidence` from the repository root.
Add `-Scope portable -RequireCurrent` to check this portable snapshot against the current checkout.
