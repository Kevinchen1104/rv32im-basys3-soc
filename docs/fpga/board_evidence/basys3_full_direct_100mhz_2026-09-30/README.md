# Basys3 100-MHz board run

Date: 2026-09-30. Hardware source: `849270b0fcb563baa1155e2bccb9da145121bf17`.

JTAG configuration and all five UART captures passed. MATVEC was repeated after an operator-pressed reset.

| Check | Result |
| --- | --- |
| Showcase | UART TX, Scratchpad and counter self-checks passed |
| Interactive | UART RX command M and response passed |
| Hardware validation | RV32M, timer interrupt and DMA-lite passed |
| MATVEC | 90 cases and 2,418 numerical outputs checked per run |
| Reset repeat | Complete MATVEC firmware reloaded and rerun after BTN C |

Operator observation: Kevin confirmed LD0 and LD2 on, LD1 off, LD3 blinking, and LD15:8=0x5a, then pressed and released BTN C before the MatvecReset capture.

[First-run measurements](captures/Matvec/measurements.csv) | [Reset-repeat measurements](captures/MatvecReset/measurements.csv)

See [measurement method](../../../matvec-benchmark.md#physical-board-measurements) for the board profile and timing interval.

Capture copies normalize line endings and replace the absolute checkout path with a dot. Artifact hashes cover the published copies.
