# Generated evidence packages

`release/` contains generated review packages so a reviewer can inspect source
manifests, test summaries, tool reports, and explicit claim boundaries without
rerunning every tool. It is not the primary documentation path and does not
override RTL, tests, or current source documents.

- `release/final/` is the compact summary and source-manifest evidence package.
- `release/fpga/basys3/` contains source-matched Basys3 implementation evidence.
- `docs/fpga/board_evidence/basys3_full_direct_100mhz_2026-07-30/` is the
  current durable physical record for commit `d7f1afe`. Its bitstream has a
  matching post-route report with WNS `+0.318 ns` and TNS `0`, five
  implementation profiles that each reported nonnegative WNS and zero TNS,
  and scoped XSDB, UART, and
  operator-observed LED/reset evidence.
- `docs/fpga/board_evidence/basys3_full_direct_100mhz_2026-07-29/` is retained
  as historical evidence for commit `a32df5f`; it is not current evidence for
  later revisions.
- JSON summaries state `pass`, `fail`, `blocked`, or `not_run`; omitted physical
  work must not be inferred from a generated bitstream.

Run `scripts/release-freeze.ps1` to orchestrate the evidence index, both FPGA
profile packages, and `release/final/`, then run `scripts/final-audit.ps1`.
The Basys3 direct-100-MHz package verifies and copies durable physical evidence
only when it matches the current source revision. Vivado reports are packaged only
when their synthesis-input fingerprint matches the current RTL manifest, RTL
files, XDC, and build Tcl. The generated bitstream is identified by path, size,
and SHA-256 but is intentionally not included in the Git package.

The physical evidence keeps evidence levels distinct: XSDB target selection,
programming/configured state, and UART transcript bytes are machine-captured;
LED/reset observations are operator-reported. It does not claim FPGA readback
or hashing of the configured bitstream.
