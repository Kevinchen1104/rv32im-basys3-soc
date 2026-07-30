# FPGA Evidence Package

This evidence-only directory is generated from the repository root. The source
manifest identifies the repository files used by the build; source trees and
binary bitstreams are intentionally not copied into this package.
The working_tree_dirty field covers the repository except generated release/** outputs.
source_commit identifies the fingerprint-matched synthesis inputs; repository_head identifies the package-generation HEAD.

Rebuild package:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/fpga-release.ps1 -BoardProfile generic_uart_boot_runtime
```

This generic profile is a portable integration package without board-specific timing or physical-validation claims.
Select a concrete board, constraints, and vendor flow before making implementation claims.
