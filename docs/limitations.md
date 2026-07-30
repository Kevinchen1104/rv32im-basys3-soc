# Limitations and non-claims

- The core is an RV32IM-style educational/engineering implementation, not a
  certified implementation of every unprivileged or privileged RISC-V rule.
- `FENCE` is not implemented. The unprivileged ISA claim remains limited to
  the instruction and exception behavior exercised by the repository tests.
- Machine-mode CSR/trap behavior is limited to the implemented subset. There is
  no user/supervisor mode, MMU, virtual memory, Linux, or RTOS platform claim.
- Caches are small and the MATVEC DMA-lite path is not generally cache coherent.
  Software must respect DMA ownership and address/alignment rules; matrix and
  output descriptor ranges must be disjoint and are checked before a job starts.
- UART RX has a two-flop input synchronizer and a one-byte software-visible
  buffer, not a deep FIFO or error-correcting serial link. RX overrun is sticky
  until reset. The 64-bit timer halves require documented software sequences
  for coherent reads and interrupt-safe compare updates.
- MATVEC Scratchpad and DMA-lite demonstrate signed-int8 compute integration.
  They are not production accelerators and carry no throughput, speedup,
  power, or deployment-quality claim.
- Bounded formal harnesses prove selected recurrences and invariants only. They
  are not complete CPU or accelerator proofs.
- Generic Yosys synthesis is not FPGA timing closure. Basys3 timing is claimed
  only from a matching Vivado post-route report with `WNS >= 0` and `TNS = 0`.
- Commit `d7f1afe` has source-matched timing, a five-profile implementation
  sweep, a canonical bitstream, and scoped physical evidence dated 2026-07-30.
  Those claims do not transfer to later source revisions.
- UART RX and Basys3 switch inputs use two-flop synchronizers. Independent
  switch synchronization does not make a multi-switch transition atomic, and
  generic GPIO users remain responsible for board-specific CDC. Asynchronous
  input paths are excluded only up to their first synchronizer stage. Declared
  top-level input/output delay budgets are complete in the current Vivado
  report, but they remain board-level budgets rather than measurement of every
  possible external device. The five-profile implementation sweep is
  multi-strategy evidence, not random-seed coverage or exhaustive placement
  robustness; its worst WNS was `+0.079 ns`, below the optional `+0.200 ns`
  target. No power analysis or production DFT/signoff claim is made.
- UART framing errors are discarded by the receiver and are not exposed as a
  sticky software-visible status bit. RX overrun is software-visible.
- The 16-entry BTB is indexed without PC tags. Aliasing may increase
  mispredictions but is recovered architecturally.
- Reset initializes general registers to their index values for deterministic
  simulation visibility. Only `x0=0` is architectural; firmware must initialize
  every other register it uses.
- Reset invalidates caches and control state but does not erase UART-loaded
  instruction memory or backing data memory. Dirty cache contents are not
  written back by reset, and an incomplete boot packet has no timeout. Reset
  restarts packet reception; checksum failure scrubs IMEM, and any later
  successful packet clears the unused image tail before CPU release.
- UART boot rejects zero-length images. Its 32-bit additive checksum is
  non-cryptographic and does not provide CRC-strength error detection,
  authentication, anti-rollback protection, or secure boot.
- UART serial blocks require `CLKS_PER_BIT >= 1`; integrated wrappers hold
  invalid configurations in reset and report an error.
- External IMEM/DMEM are 128-bit cache-line protocols and require the matching
  I-cache/D-cache. External DMEM capacity is restricted to a positive multiple
  of four words; invalid parameter combinations assert `config_error` and must
  not be used as runnable profiles. Initialization counts larger than their
  backing memories are rejected where configuration status exists and are
  always clamped before `$readmemh`. External DMEM `SIM_INIT_HEX` is a
  simulation-only convenience; synthesized memory contents must be established
  by runtime writes.
- The physical suite is not official RISC-V compliance, every-instruction
  physical coverage, Linux/RTOS qualification, production/cache-coherent DMA
  validation, benchmark speedup evidence, or power/performance signoff.
