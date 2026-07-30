# Basys3 full-direct 100 MHz physical evidence

This suite records the scoped 2026-07-29 physical validation of
`RISCVCPU_basys3_top` on a Digilent Basys3. The synthesis-input fingerprint,
host-side bitstream identity, post-route timing, XSDB programming record,
exact UART captures, and operator-observed board status are tied together in
[summary.json](summary.json).

The validated canonical identity is source commit `a32df5f`, source
fingerprint `76a94d31...84063`, and bitstream SHA-256
`85f782b9...a92fd`. Its matching Vivado 2026.1 post-route report records WNS
`+0.030 ns`, TNS `0`, WHS `+0.027 ns`, and THS `0`.

## Evidence layers

- [XSDB programming](xsdb-programming-summary.json) machine-recorded one
  matching `xc7a35t` target, successful programming, configured state, zero
  automatic retries, and clean disconnect.
- XSDB used a host-verified canonical `.bit` file. It did not read back or
  hash the configured FPGA image, so on-board identity readback is not claimed.
- UART evidence was captured by one COM4/115200 session per case with zero
  host retries. The checked-in transcript files are exact LF-only byte streams
  with a final LF.
- LED, heartbeat, reset-button, and return-to-boot-wait observations are
  operator-reported and are recorded per case in `summary.json`.

| Case | Packet bytes / SHA-256 | Transcript bytes / SHA-256 |
| --- | --- | --- |
| Showcase | 1,096 / `088a27132a09c5cb7ac1625fac85868a9ecca2bb1c8f60a9ba82863c69eaaa8a` | 64 / `983a592b146062541104b69e82c2abe463b498d70c659545141f05fa8d73ef9a` |
| Interactive | 1,300 / `13767ac723f26b39bbede004277b7774ff557495367322947b54126dd382cfb3` | 74 / `3640188d8d3f56b1a613d7cb900d04798814d4654f50f48d738a66f11ef33736` |
| HardwareValidation | 2,052 / `eb3b6b2defad3093337f7dd466ec5ca8f767098d54107c94b965aa2bf39dce92` | 82 / `e79c0a5cf34d98c178a4f4fe0a6f0cd65472daf786f0d523c2e97338725e6282` |

The exact captures are [Showcase](showcase-transcript.txt),
[Interactive](interactive-transcript.txt), and
[HardwareValidation](hardware-validation-transcript.txt).

## Scoped result

The suite demonstrates XSDB JTAG configuration; packet boot; UART TX; one
runtime UART RX command byte `0x4d` without CR/LF; MATVEC Scratchpad
self-checks and counter reads; selected RV32M arithmetic; machine timer
interrupt, trap, and `mret`; MATVEC DMA-lite external-DMEM use; and the
recorded GPIO/status/heartbeat/reset/reboot behavior.

It is not official RISC-V compliance, every-instruction physical coverage,
multi-seed timing robustness, external synchronous-I/O signoff, Linux/RTOS
validation, production or cache-coherent DMA, benchmark speedup, power or
performance signoff, photographic/video/ILA evidence, or on-board bitstream
readback/hash verification.
