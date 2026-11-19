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

- XSDB: run `scripts/xsdb-basys3-program.ps1` for a one-shot JTAG flow when
  XSDB is allowed by the host.
- Vivado Hardware Manager: run `scripts/vivado-basys3-program.ps1` when the
  Vivado runtime and cable services are available.

Both paths configure a selected bitstream; neither proves UART, LED, reset,
or accelerator behavior by itself. See [bringup_checklist.md](bringup_checklist.md)
for the board-side checks.

The current routed default build at `fd52074` meets 100 MHz timing
(WNS `+0.021 ns`, WHS `+0.034 ns`); it has no board run yet. The latest
board-validated build, `9d46f04`, passed the
[automatic board acceptance](../../../docs/fpga/board_evidence/automatic_acceptance_5c1c4c0/README.md):
JTAG/UART, RV32M, timer-interrupt and DMA checks, plus two complete 90-case
MATVEC runs, including after JTAG reload. See
[`docs/fpga_basys3.md`](../../../docs/fpga_basys3.md).

Physical host preflight checks the current 100-MHz Vivado bitstream build,
post-route timing/DRC, synthesis-source fingerprint and local bitstream hash.
Historical board records and optional multi-strategy experiments are separate:
neither is a prerequisite for testing a new, timing-closed build. A host-script
edit does not change the bitstream's synthesis inputs.

The `Matvec` demo captures hardware cycle counters and all numerical outputs;
see the [measurement method](../../../docs/matvec-benchmark.md#physical-board-measurements).
JTAG configured-state confirmation and UART capture are automated. LED and
physical reset-button observations are recorded by the operator.
