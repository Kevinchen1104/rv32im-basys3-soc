# Supported configuration and operating constraints

## ISA and execution

- The core implements the RV32I instruction groups and machine-mode subset
  described in [ISA and MMIO](isa_mmio.md), plus all eight RV32M operations.
  `FENCE`, user/supervisor modes, MMU, and virtual memory are not implemented.
- The 16-entry BTB has no PC tags. Aliasing can cause extra mispredictions;
  resolved control transfers correct the architectural path.
- Reset initializes general registers to their index values for deterministic
  visibility. Only `x0=0` is architectural; firmware initializes every other
  register it uses.

## Memory and accelerators

- I-cache and D-cache default to 64 bytes with 16-byte lines. I-cache supports
  power-of-two capacities from 64 to 4096 bytes with indexed lookup; its
  original parallel lookup is limited to 64 bytes. D-cache supports 64 or 128
  primary bytes and an optional 0/1/2/4/8-line victim buffer.
  External IMEM/DMEM use 128-bit request/ready transactions and require the
  matching cache. Larger I-cache configurations need their own routed timing
  evidence; functional simulation does not establish a usable clock rate.
- External DMEM capacity must be at least four words and a multiple of four.
  Unsupported combinations assert `config_error`.
- Initialization counts are bounded before `$readmemh`; wrappers with
  configuration status reject counts larger than storage.
  External DMEM `SIM_INIT_HEX` is simulation-only. The synthesized memory is
  populated by runtime writes.
- DMA-lite serializes ordinary CPU memory accesses while busy. Its local
  D-cache snoop supports the [documented software sequence](accelerators.md#software-sequence-and-cache-behavior),
  not a multi-master coherence protocol. Descriptor addresses must be
  word-aligned and in range; matrix and output ranges must be disjoint.
- Scratchpad processes 1..16 rows and DMA-lite 1..4 rows, with four signed-int8
  lanes per row. Scratchpad can interrupt; DMA-lite uses polling.
- Reset invalidates caches and control state without clearing backing IMEM or
  DMEM. Dirty cache contents are discarded rather than written back, so reset
  is not a software memory-flush operation.

## Peripherals and board inputs

- UART RX uses 8N1 sampling and a 64-byte FIFO in the runtime SoC. Software or
  host flow control must bound incoming bursts to the available capacity. Overrun
  remains set until reset. Framing-error bytes are discarded without a
  separate software-visible framing-error flag.
- UART RX requires `CLKS_PER_BIT >= 3`; TX requires `CLKS_PER_BIT >= 1`. Integrated wrappers hold invalid
  configurations in reset and report an error.
- `mtime` and `mtimecmp` have independent 32-bit halves. Use the retry and
  compare-update sequences in [ISA and MMIO](isa_mmio.md).
- UART RX and Basys3 switches use two-flop synchronizers. Several switches
  changing together are not sampled atomically. Other GPIO integrations need
  their own clock-domain-crossing treatment.
- Board constraints exclude asynchronous input paths only up to the first
  synchronizer stage. Top-level I/O delay values are interface budgets;
  external-device timing must fit those budgets.

## UART boot

- Zero-length images are rejected. An incomplete packet has no timeout;
  reset restarts reception.
- Payload words are written during reception while the CPU is held.
  Checksum failure scrubs IMEM. Successful reception fills the unused tail
  with NOPs before releasing the CPU.
- The 32-bit additive checksum checks the transfer; it does not authenticate
  the sender or firmware image.

## Measurements

[Verification](verification.md) distinguishes simulation, bounded formal,
implementation, and physical observations. Hardware results identify their
source revision and board run. The [MATVEC benchmark](matvec-benchmark.md)
measures end-to-end workload speedup in RTL simulation and on the 100-MHz
Basys3, including setup and data movement. The profiles use different memory
backends and timing boundaries, documented with their results. Power has not
been measured.
