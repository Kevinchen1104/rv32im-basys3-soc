# Documentation review

Use this checklist when a design or result changes:

1. Explain what the block does, its interface, and the sequence a user follows.
   Keep constraints next to the operation they affect.
2. Check diagrams against RTL signal paths. Distinguish data, control, and
   module hierarchy instead of combining all three into one diagram.
3. Tie result counts to current summaries. Tie FPGA measurements to a named
   source revision and tool/board record.
4. Give tests a useful purpose and expected observation. State assumptions
   where they matter; a fixed English header format is not required.
5. Describe software prerequisites, commands, generated files, and failure
   diagnostics. Check local links after renaming files.
6. Read for repetition: explain a constraint once and link to it where needed.
   Words such as "complete", "coherent", or "speedup" need context and evidence,
   not an automatic ban.

Optional helpers:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/documentation-coverage-audit.ps1
powershell -ExecutionPolicy Bypass -File scripts/claim-audit.ps1
powershell -ExecutionPolicy Bypass -File scripts/docs-link-audit.ps1
```

The first two generate advisory reports with `status=completed`; findings
need human judgment and do not fail the portable regression or release.
Missing inputs and script errors still fail execution. The link audit checks
local targets and fails on broken references. Each advisory report records its
documentation fingerprint. These writing aids are separate from package integrity.
