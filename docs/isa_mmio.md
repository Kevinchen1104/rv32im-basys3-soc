# ISA and MMIO

## ISA scope

The processor implements the repository-tested RV32I arithmetic, control-flow,
load/store, upper-immediate, and environment subset, plus all eight RV32M
operations. Machine-mode CSR, exception, timer-interrupt, external-interrupt,
and `mret` behavior follows the implemented subset. See
[Supported configuration](limitations.md) for instruction and system limits.

`JALR` accepts only `funct3=000`. With no compressed-instruction extension,
taken branch, `JAL`, and `JALR` targets must be 4-byte aligned; violations
raise instruction-address-misaligned cause 0 on the control-transfer
instruction and record the target in `mtval`. An untaken branch does not raise
this exception.

Instruction fetches and ordinary data accesses are bounded by
`MEMORY_WORD_COUNT`. An out-of-range fetch raises instruction access fault
cause 1; out-of-range loads and stores raise causes 5 and 7. `mtval` records
the rejected byte address. Implemented MMIO registers remain legal and are
classified by the authoritative MMIO decoder rather than the memory bound.

## Address map

All addresses are byte addresses. Implemented registers accept the four low
byte-address aliases; load/store formatting selects the addressed lane.

| Address | Register | Notes |
| --- | --- | --- |
| `0x0200` | GPIO output | Read/write |
| `0x0204` | GPIO input | Read-only input value |
| `0x0300` | UART TX data | Write; the pipeline waits while TX is busy |
| `0x0304` | UART RX data | Read |
| `0x0308` | UART status | bit 0 RX valid, bit 1 TX ready, bit 2 sticky RX overrun |
| `0x0600` | cycle count | Global performance counter |
| `0x0604` | retired count | Global performance counter |
| `0x0608` | branch miss count | Global performance counter |
| `0x060c` | I-cache miss count | Global performance counter |
| `0x0610` | D-cache miss count | Global performance counter |
| `0x0614` | stall cycle count | Global performance counter |
| `0x0618` | MATVEC start count | Scratchpad accepted starts |
| `0x061c` | MATVEC done count | Scratchpad done rising edges |
| `0x0620` | MATVEC busy cycles | Cycles Scratchpad reports busy |
| `0x0700..0x0720` | MATVEC Scratchpad | See [Accelerators](accelerators.md) |
| `0x0800` | `mtime` low | Machine timer |
| `0x0804` | `mtime` high | Machine timer |
| `0x0808` | `mtimecmp` low | Machine timer compare |
| `0x080c` | `mtimecmp` high | Machine timer compare |
| `0x0900..0x091c` | MATVEC DMA-lite | See [Accelerators](accelerators.md) |

`0x0400..0x05ff` is not MMIO. Accesses use the ordinary data-memory path and
may be cached like other data-memory addresses.

Write-only registers, such as UART TX data and MATVEC control, read as zero.

The public debug signature word at byte address `0x0100` is an ordinary memory
location with top-level observation support. It is used by firmware tests and
is intentionally not part of the peripheral decoder.

UART TX stores are retained until `TX ready` is high; software polling remains
useful for avoiding a pipeline stall. Reading RX data consumes the oldest byte
in the runtime SoC's 64-byte FIFO. RX-valid indicates at least one queued byte.
RX overrun is sticky until reset and indicates a new byte was dropped because
the FIFO was full without a simultaneous CPU read. Register addresses and status
bit assignments are unchanged.

The 64-bit timer registers are exposed as independent 32-bit halves and are
not atomic. For a coherent `mtime` read, software should read high, low, then
high again and retry if the high halves differ. To update `mtimecmp` without a
transient interrupt, write `0xffff_ffff` to the high half, write the desired
low half, then write the desired high half.
