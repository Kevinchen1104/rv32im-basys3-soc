# FPGA Board Profiles

This directory holds the portable integration profile and the evidence-backed
Basys3 target used by the FPGA release flow.

Current profiles:

| Profile | Top module | Status |
| --- | --- | --- |
| `generic_uart_boot_runtime` | `RISCVCPU_uart_boot_runtime_soc_top` | FPGA timing-readiness package profile; constraints template only until a board is selected, physical FPGA validation not run yet, no timing closure claim |
| [`basys3`](basys3/README.md) | `RISCVCPU_basys3_top` | Digilent Basys3 target; current `d7f1afe` source has a bitstream with WNS `+0.318 ns` and TNS `0`, a five-profile implementation sweep, and a scoped physical pass |

The [generic pinout checklist](generic_uart_boot_runtime/pinout_checklist.md)
lists the signals that must be mapped when adapting the portable profile.

Use [`basys3/board.json`](basys3/board.json) for current machine-readable status.
The [2026-07-30 evidence](../../docs/fpga/board_evidence/basys3_full_direct_100mhz_2026-07-30/README.md)
is the current source-matched record for commit `d7f1afe`.

## Claim boundary

The repository includes a portable FPGA integration profile and a Digilent
Basys3 target. The current Basys3 claim is limited to the source-matched
timing, implementation-strategy, and scoped physical evidence recorded for
commit `d7f1afe`.
Simulation and synthesis-smoke evidence are available through the repository
release gates, but those gates do not replace board-specific constraints,
vendor timing reports, bitstream generation, or physical validation.

The current Basys3 evidence does not establish random-seed or exhaustive
placement robustness, complete ISA compliance, exhaustive physical coverage,
benchmark performance, power signoff, or on-board bitstream readback.
Bitstream generation by itself does not equal board validation.
