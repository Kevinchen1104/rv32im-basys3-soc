# Generic UART Boot Runtime Pinout Checklist

Use this before turning the template into a real board project.

## Board Identity

- Board name:
- FPGA part/package/speed grade:
- Board manual / schematic link:
- Toolchain and version:
- Intended top module: `RISCVCPU_uart_boot_runtime_soc_top`

## Required Pins

| Signal | Board pin | IO standard | Reviewed |
| --- | --- | --- | --- |
| `clock` | `<fill>` | `<fill>` | `[ ]` |
| `reset` | `<fill>` | `<fill>` | `[ ]` |
| `uart_rx` | `<fill>` | `<fill>` | `[ ]` |
| `uart_tx` | `<fill>` | `<fill>` | `[ ]` |
| `leds[0]` | `<fill>` | `<fill>` | `[ ]` |
| `leds[1]` | `<fill>` | `<fill>` | `[ ]` |
| `leds[2]` | `<fill>` | `<fill>` | `[ ]` |
| `leds[3]` | `<fill>` | `<fill>` | `[ ]` |

## Optional Pins

- `gpio_inputs[*]`
- `gpio_outputs[*]`
- `debug_flags[*]`
- `debug_status[*]`
- `debug_pc[*]`
- `external_dmem_read_seen`
- `external_dmem_write_seen`
- `runtime_uart_rx_valid`
- `runtime_uart_rx_overrun`

## Timing Readiness

- `[ ]` Clock frequency is known and `expected_clock_hz` is filled in
  `board.json`.
- `[ ]` XDC/SDC clock period matches the board clock.
- `[ ]` UART baud divisor is selected for the board clock.
- `[ ]` Reset polarity is checked against the board button/switch.
- `[ ]` LED polarity is checked.
- `[ ]` Vendor timing report is generated.
- `[ ]` Timing report has no unconstrained primary clock.
- `[ ]` Timing closure status is recorded without overclaiming.

## Physical Validation

- `[ ]` Bitstream generated for the selected board.
- `[ ]` Board programmed successfully.
- `[ ]` Heartbeat observed.
- `[ ]` Packet UART boot attempted.
- `[ ]` UART TX transcript captured.
- `[ ]` GPIO/LED final state observed.
- `[ ]` Evidence recorded under `docs/fpga/board_evidence/`.

Until this checklist is filled with a real board, the profile remains a
constraints template only until a board is selected.
Physical FPGA validation has not run; no timing closure claim.
