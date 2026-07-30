# Generated Evidence Package

This compact directory contains machine-readable evidence summaries and source
manifests. The repository README and docs/README.md are the primary reading path.

Recorded regression: 163/163 passed.
Vivado evidence: current.
Timing closure: met.
DRC: pass; errors 0; critical warnings 0; unapproved warnings 0; REQP-1839 0.
Bitstream: generated_current_sources; binary intentionally not packaged.
Physical validation: passed (scoped; see evidence/physical/summary.json).
source_commit identifies the fingerprint-matched synthesis inputs; repository_head identifies the evidence-generation HEAD.

See evidence-index.md and release-summary.json. Top-level FPGA evidence packages
are referenced rather than duplicated here.

## Regenerating this package

1. Start from a clean, committed source revision.
2. From clean HEAD, rebuild the canonical Vivado implementation and bitstream.
3. Run scripts/release-freeze.ps1; it rebuilds the evidence index and both FPGA profile packages.
4. Run scripts/final-audit.ps1.
5. Commit generated release evidence separately from source changes.
