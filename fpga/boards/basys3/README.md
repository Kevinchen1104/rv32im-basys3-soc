# Basys3 board profile

This profile packages the three Basys3 tops, `basys3.xdc`, and the Vivado batch
flow for `xc7a35tcpg236-1`.

- `RISCVCPU_basys3_top`: default-feature direct-100-MHz SoC.
- `RISCVCPU_basys3_full_lowfreq_top`: default-feature 6.25-MHz SoC.
- `RISCVCPU_basys3_board_smoke_top`: reduced straight-line board-smoke
  configuration with control redirects and CSR traps disabled.

Run builds through `scripts/vivado-basys3-build.ps1`; do not invoke programming
or serial-port scripts as part of a normal regression. A timing claim requires
a matching post-route report with nonnegative WNS and zero TNS. A bitstream is
not physical validation.

## Programming paths

- USB host: copy the canonical `.bit` file to a FAT32 USB drive and use the
  Basys3 USB-host configuration sequence documented in
  [`docs/fpga_basys3.md`](../../../docs/fpga_basys3.md).
- XSDB: run `scripts/xsdb-basys3-program.ps1` for a one-shot JTAG flow when
  XSDB is allowed by the host.
- Vivado Hardware Manager: run `scripts/vivado-basys3-program.ps1` when the
  Vivado runtime and cable services are available.

All three paths configure a selected bitstream; none proves UART, LED, reset,
or accelerator behavior by itself. See [bringup_checklist.md](bringup_checklist.md)
for the board-side checks.

The source-matched Vivado 2026.1 build at commit `d7f1afe` met 100 MHz timing,
generated a bitstream, completed five implementation profiles that each
reported nonnegative WNS and zero TNS,
and passed the scoped 2026-07-30 XSDB/UART/LED/reset suite. The profile sweep
is not random-seed evidence, and its worst WNS `+0.079 ns` missed the optional
`+0.200 ns` margin target. See
[`docs/fpga_basys3.md`](../../../docs/fpga_basys3.md).

After evidence promotion, physical host preflight resolves canonical identity
from the evidence-only Basys3 status, Vivado summary, source fingerprint,
source manifest, and local bitstream size/hash. It does not require repository
HEAD to equal the synthesis source commit when later commits contain only
evidence.
The physical evidence does not claim on-board bitstream readback or hash
verification.
