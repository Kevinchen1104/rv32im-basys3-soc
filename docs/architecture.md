# Architecture

The repository [README](../README.md) contains the single system-level block
diagram. This document supplies the behavioral details behind that overview.

## Processor

`RISCVCPU` is an in-order, five-stage RV32IM-style core with fetch, decode,
execute, memory, and writeback state. The implementation includes forwarding,
load-use interlocking, multicycle RV32M execution, branch prediction, a return
address stack, and registered control-redirect handling.

The iterative RV32M unit starts only when the execute-stage operation remains
architecturally accepted. An older memory-stage trap or an accepted redirect
squashes the younger M operation before start, clears core ownership of any
discarded operation, and prevents a later completion from becoming a ready
architectural result. A subsequent M instruction waits for the iterative unit
to become idle and computes its own result.

Machine-mode CSR logic implements the repository's documented trap subset,
including exceptions, timer interrupts, external interrupts, and `mret`.
Redirect priority and side-effect suppression are checked by dedicated tests;
the design is not presented as a complete privileged-architecture
implementation.

Control transfers use 4-byte instruction alignment. A legal taken branch,
`JAL`, or `JALR` with a misaligned target traps before link-register,
predictor, RAS, or wrong-path side effects can commit. Nonzero `JALR funct3`
encodings are illegal instructions. For the rare alignment fault, capture edge
N records the source PC, target, and taken/fallthrough outcome. That registered
state forms `InstructionMisalignPending`; edge N+1 accepts the synchronous
trap, redirects to `mtvec`, and captures CSR metadata into the trap shadow
bank; edge N+2 commits architectural
`mepc`/`mcause`/`mtval`. A newly pending interrupt cannot enter while the
control transfer is unresolved, so the alignment fault is captured first. If
`ControlInterruptDeferred` was already set by an earlier resolved control
instruction, that interrupt belongs to the preceding precise boundary: it is
accepted before the current ID/EX instruction executes, and `mepc` records that
instruction for replay after `mret`. Ordinary aligned control transfers retain
their existing latency.

`exception_decode_unit` owns instruction legality and exception
classification. `RISCVCPU` owns cause mapping and acceptance priority so those
timing-factored control cones remain separate; it also owns the registered
instruction-misalignment handoff, interrupt deferral, redirect timing, and CSR
side-effect sequencing.

Execute-stage architectural effects use a shared acceptance boundary. When an
older data-memory operation applies D-cache backpressure, ID/EX validity and
payload remain held, but synchronous exception entry and CSR writes remain
inactive. After the memory transaction completes, the held instruction is
accepted once: a CSR operation captures its pre-write readback value, or an
exception enters the trap pipeline once. A pending instruction-alignment fault
is likewise retained until that boundary.

When EX advances a bubble, EX/MEM payload bits are don't-care and may capture
new values. `EXMEMValid` is the sole bubble authority; write metadata and
payload are interpreted only while it is set. A real D-cache hold still
preserves the live transaction.
IF/ID uses the same validity contract: redirect cycles may capture don't-care
fetch payload, while `IFIDValid=0` prevents that payload from entering execute.

## Key implementation parameters

| Block | Configuration |
| --- | --- |
| I-cache | 64 bytes, 16-byte lines, 2 sets, 2-way set associative |
| D-cache | 64 bytes, 16-byte lines, 4 direct-mapped lines |
| Branch predictor | 16-entry BHT and 16-entry BTB |
| Return address stack | 8 entries |
| RV32M unit | Registered launch followed by 32 iterative multiply/divide steps |
| MATVEC Scratchpad | One signed-int8 vector, 1 to 16 rows |
| MATVEC DMA-lite | DMEM-backed vector/matrix/result descriptors, 1 to 4 rows |

## Memory system

The default core has separate instruction and data caches with 128-bit refill
lines. Internal simulation memories and the external DMEM BRAM share the same
CPU-facing request/ready contract. Loads and stores use one
byte/halfword/word formatting unit, including MMIO subword aliases.

The external IMEM and DMEM ports are cache-line request/ready protocols, so an
external instruction-memory configuration requires the I-cache and an external
data-memory configuration requires the D-cache. Unsupported cache-disabled
external combinations assert the core's `config_error` output instead of
silently appearing valid. External DMEM capacity must be at least one complete
4-word line and a multiple of four words; the external BRAM block exposes the
same configuration error. The external DMEM block acknowledges out-of-range
line requests with zero data and ignores out-of-range writes.
Its `SIM_INIT_HEX` parameter initializes simulation only; synthesized Basys3
DMEM is populated through accepted runtime writes, including UART-loaded
firmware activity.

The central MMIO decoder accepts only implemented word offsets. An access
bypasses the D-cache only when the exact decoder select is active. Unmapped
addresses, including every address in pages `0x0400` and `0x0500`, follow the
ordinary memory path.

Instruction and ordinary data addresses are checked against the configured
word capacity before architectural acceptance. Out-of-range instruction,
load, and store accesses raise causes 1, 5, and 7 with the byte address in
`mtval`. Internal memories and external BRAM wrappers also return NOP/zero and
ignore out-of-range writes defensively, so disabled-trap profiles do not turn
truncated high address bits into low-memory aliases.
An out-of-range data access suppresses the D-cache request and therefore cannot
produce a cache miss. Precise fault acceptance checks only already-active
cache, DMA-ownership, or UART holds instead of feeding the combinational miss
result back into the trap path.

Packet boot writes payload words while receiving them, but it does not release
the CPU until checksum validation and image cleanup complete. A checksum
failure scrubs the instruction memory before reporting `boot_error`; a
successful packet replaces its declared payload and clears every unused tail
word to NOP. Reset can abort an incomplete packet, and the next successful
packet restores a clean image before release. The loader rejects zero-length
images. Its checksum is a 32-bit additive transfer check, not a CRC,
cryptographic integrity mechanism, authentication scheme, or secure-boot
primitive.

## SoC integration

The active peripheral groups are GPIO, UART, performance counters, MATVEC
Scratchpad, machine timer, and MATVEC DMA-lite. `mmio_decode` owns write/bypass
selection and `mmio_read_mux` owns readback selection.

UART TX backpressure participates in the memory-stage pipeline hold, so a busy
transmitter delays a store instead of dropping it. The physical RX pin passes
through a two-flop synchronizer before 8N1 sampling. Runtime RX uses a one-byte
buffer; its sticky overrun flag is visible in UART status bit 2.
Basys3 switch inputs pass through independent two-flop synchronizers before
entering the GPIO path; simultaneous multi-switch changes are not an atomic
sample.
The runtime SoC board reset likewise uses an `ASYNC_REG`-marked two-flop
synchronizer with synchronous assertion and release. Power-up values hold the
SoC in reset until two sampled clock edges have propagated.

MATVEC Scratchpad completion drives the existing machine external-interrupt
pending input. DMA-lite exposes no interrupt source and must be polled.

While DMA-lite owns DMEM, CPU non-MMIO data-memory operations stall. DMA reads
can use the D-cache snoop word when the requested word is resident, but the
engine is not generally coherent with arbitrary CPU cache traffic. Software
must obey the ownership rules in [Accelerators](accelerators.md). Descriptor
validation rejects matrix/output overlap so a completed result cannot overwrite
a matrix row that the engine has not read yet.

`mtime` and `mtimecmp` expose separate 32-bit halves. The hardware intentionally
does not invent an implicit latch/commit transaction around ordinary MMIO
loads and stores; software uses the retry/write sequences documented in
[ISA and MMIO](isa_mmio.md).

## Configurable slices

Top-level parameters can disable RV32M, accelerators, timer, caches, branch
prediction, performance counters, control redirects, or CSR/trap logic for
targeted tests and alternate bring-up profiles. Defaults preserve the
default-feature SoC configuration. Cache-disable parameters are supported with
the internal memories; they do not convert the external cache-line ports into
single-word bypass interfaces.
