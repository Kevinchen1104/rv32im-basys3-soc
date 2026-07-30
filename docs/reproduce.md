# Reproduce the results

Run commands from the repository root in PowerShell.

## Portable gate

```powershell
powershell -ExecutionPolicy Bypass -File scripts/project-doctor.ps1
powershell -ExecutionPolicy Bypass -File scripts/assemble.ps1 -Check
powershell -ExecutionPolicy Bypass -File scripts/check-test-catalog.ps1
powershell -ExecutionPolicy Bypass -File scripts/check.ps1
```

`check.ps1` assembles/checks deterministic firmware and fixtures, runs static
audits, executes the full directed regression, creates the regression evidence
summary, and runs the portable FPGA wrapper smoke.

## Focused accelerator gate

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Test mmio_decode -SkipAssemble
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Test mmio_read_mux -SkipAssemble
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Test int8_matvec_scratchpad_accelerator -SkipAssemble
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Test matvec_perf_counters -SkipAssemble
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Test int8_matvec_dma_lite -SkipAssemble
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Test program_matvec_scratchpad -SkipAssemble
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Test program_matvec_dma_demo -SkipAssemble
powershell -ExecutionPolicy Bypass -File scripts/formal-matvec-smoke.ps1
```

## Optional local tools and audits

```powershell
powershell -ExecutionPolicy Bypass -File scripts/verilator-lint.ps1
powershell -ExecutionPolicy Bypass -File scripts/synth-smoke.ps1
powershell -ExecutionPolicy Bypass -File scripts/formal-smoke.ps1
powershell -ExecutionPolicy Bypass -File scripts/docs-link-audit.ps1
powershell -ExecutionPolicy Bypass -File scripts/claim-audit.ps1
powershell -ExecutionPolicy Bypass -File scripts/final-audit.ps1
```

## Generated packages

After all source checks are stable, regenerate review packages with:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/release-freeze.ps1
powershell -ExecutionPolicy Bypass -File scripts/final-audit.ps1
```

`release-freeze.ps1` rebuilds the release evidence index and both FPGA profile
packages before assembling `release/final/`; `final-audit.ps1` verifies the
result. Source-bound gates must match the committed canonical Vivado source
fingerprint and commit. Repository-bound documentation gates run after package
generation and must match the evidence-generation HEAD and documentation
fingerprint. The Vivado DRC parser also requires complete rule-count
reconciliation and rejects unreviewed warnings by default.

Do not hand-edit generated evidence to manufacture a pass. A missing tool or
unperformed board run must remain `blocked` or `not_run`.
