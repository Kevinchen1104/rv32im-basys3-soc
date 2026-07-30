# Script entry points

Run scripts from the repository root in PowerShell.

## Portable verification

```powershell
powershell -ExecutionPolicy Bypass -File scripts/assemble.ps1 -Check
powershell -ExecutionPolicy Bypass -File scripts/run.ps1 -Test <name>
powershell -ExecutionPolicy Bypass -File scripts/check.ps1
```

`run.ps1` uses the executable test manifest and `check.ps1` runs the complete
portable gate. `check-test-catalog.ps1` verifies that the machine-readable
catalog remains synchronized with the manifest.

### Local firmware assembler

`assemble.ps1` is a dependency-free, two-pass assembler written for this
repository's firmware and regression flow. It supports the implemented RV32I
and RV32M instruction subset, selected machine-mode CSR instructions, labels,
the `li`, `la`, `mv`, `j`, `call`, and `ret` pseudo-instructions, and the
`.word`, `.byte`, `.half`, `.string`, and `.align` directives. It is not a
general-purpose GNU assembler replacement; unsupported instructions,
directives, relocations, and object-file formats are rejected.

## Optional tool gates

```powershell
powershell -ExecutionPolicy Bypass -File scripts/verilator-lint.ps1
powershell -ExecutionPolicy Bypass -File scripts/synth-smoke.ps1
powershell -ExecutionPolicy Bypass -File scripts/formal-smoke.ps1
powershell -ExecutionPolicy Bypass -File scripts/formal-matvec-smoke.ps1
powershell -ExecutionPolicy Bypass -File scripts/vivado-detect.ps1
powershell -ExecutionPolicy Bypass -File scripts/vivado-basys3-build.ps1 -Implementation -Bitstream -OutDir build/vivado/basys3_full_100mhz_current
powershell -ExecutionPolicy Bypass -File scripts/vivado-basys3-robustness.ps1
```

Vivado timing is accepted only from a matching post-route report with
`WNS >= 0` and `TNS = 0`. Bitstream generation does not establish physical
board behavior. The robustness flow runs five documented implementation
directive profiles sequentially and requires all five to meet setup, hold, and
constraint checks with release-approved DRC reports. It separately reports
whether the optional `+0.200 ns`
minimum-margin target was met; that target is not the definition of timing
closure. The sweep is not random-seed or exhaustive placement evidence.

## Generated evidence packages

```powershell
powershell -ExecutionPolicy Bypass -File scripts/release-freeze.ps1
powershell -ExecutionPolicy Bypass -File scripts/final-audit.ps1
```

`release-freeze.ps1` orchestrates the evidence index, both FPGA profile
packages, and `release/final/`. It does not reuse a Vivado artifact unless its
source fingerprint matches. The Basys3 package also verifies the durable
scoped physical summary and exact transcripts before promotion.
Portable regression, lint, Yosys, formal, and catalog summaries carry the
canonical verification-input fingerprint and synthesis commit. Documentation
gates run after package generation and carry a separate public
documentation/package fingerprint plus the evidence-generation HEAD. Stale
summaries in either provenance domain are rejected rather than repackaged.

Hardware programming and serial-board scripts are intentionally separate from
all verification and release gates; none of the commands above opens a serial
port or programs a device.
