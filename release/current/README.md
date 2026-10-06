# Portable verification snapshot

Source revision: `c85280d49904d62367d54b7fb8561601db7831a9`.

Full workflow: 31 stages; RTL regression: 169 tests.

Read `package.json` for included gates and omitted optional tools; `evidence/` contains their recorded summaries.

`source-inputs.json` identifies the tested input files. `artifacts.json` checks every packaged file by size and SHA-256.

Verify integrity with `powershell -File scripts/final-audit.ps1 -PackagedEvidence` from the repository root.
Add `-Scope portable -RequireCurrent` to check this portable snapshot against the current checkout.
