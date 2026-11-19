# FPGA Board Profiles

This directory holds the portable integration profile and the evidence-backed
Basys3 target used by the FPGA release flow.

Current profiles:

| Profile | Top module | Status |
| --- | --- | --- |
| `generic_uart_boot_runtime` | `RISCVCPU_uart_boot_runtime_soc_top` | Portable integration configuration and pinout checklist |
| [`basys3`](basys3/README.md) | `RISCVCPU_basys3_top` | Digilent Basys3, 100 MHz; current routed build `fd52074` has WNS `+0.021 ns`; latest board acceptance on build `9d46f04` |

The [generic pinout checklist](generic_uart_boot_runtime/pinout_checklist.md)
lists the signals that must be mapped when adapting the portable profile.

Use [`basys3/board.json`](basys3/board.json) for hardware configuration and its
link to revision-specific recorded board evidence. Current verification and
implementation results are indexed in `results/RESULTS.md`.
The [2026-09-30 evidence](../../docs/fpga/board_evidence/basys3_full_direct_100mhz_2026-09-30/README.md)
records build `849270b`, including 90 MATVEC cases and 2,418 output values before
and after reset. The [2026-07-30 record](../../docs/fpga/board_evidence/basys3_full_direct_100mhz_2026-07-30/README.md)
preserves the earlier implementation sweep and board observations.

## Reproducing a board result

Each board record identifies the measured source and bitstream. For a changed
checkout, rebuild the selected top, check timing, and repeat the UART and reset
procedure in the [Basys3 guide](basys3/README.md). Saved measurements remain
associated with their recorded revision.
