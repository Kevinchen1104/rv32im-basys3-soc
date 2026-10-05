# Portable verification snapshot

Source revision: `ddfce23cef5c1bbf05b6830b51f1385610f57f30`.

Full workflow: 31 stages; RTL regression: 169 tests.

Read `package.json` for included gates and omitted optional tools; `evidence/` contains their recorded summaries.

`source-inputs.json` identifies the tested input files. `artifacts.json` checks every packaged file by size and SHA-256.

Verify integrity with `powershell -File scripts/final-audit.ps1 -PackagedEvidence` from the repository root.
Add `-RequireCurrent` when checking that this snapshot matches the current checkout.
