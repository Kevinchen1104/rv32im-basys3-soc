# Verification

The verification strategy combines directed simulation, generated reference
programs, bounded formal smoke, lint, generic synthesis, and FPGA tool reports.
Each layer has a narrower claim than full functional or physical proof.

## Directed simulation

`scripts/run.ps1` is the executable test manifest. It covers CPU units,
pipeline side-effect isolation, CSR/trap behavior, caches and adapters, exact
MMIO decode, Scratchpad, DMA-lite, firmware programs, UART boot, showcase
flows, and FPGA wrapper guards. `docs/test_catalog.json` records each test's
contract, evidence level, hierarchy usage, and boundary.

DMA-lite descriptor tests cover alignment, capacity, 32-bit address wraparound,
and matrix/output overlap. Rejected descriptors must issue no DMEM transaction.

External-memory tests require out-of-range or partial-line requests to return
zero, acknowledge deterministically, ignore writes, and avoid low-address
aliasing. Packet-loader tests cover bad headers, checksum
failure with IMEM scrubbing, reset during an incomplete payload, shorter clean
retry, zero-length image rejection, one-word-capacity elaboration/boot, and
unused-tail clearing before CPU release. Wrapper guards cover boot memories too
small to expose the public debug-status word, invalid UART divisors or heartbeat
indices, and initialization counts larger than their storage.

Control-transfer exception tests cover legal `JALR` encoding, cause-0
instruction-address-misaligned traps for taken branch/JAL/JALR, untaken
branch fallthrough, precise `mepc`/`mtval`, link suppression, and
predictor/RAS side-effect isolation. They also check the registered N/N+1/N+2
trap handoff, newly pending versus already deferred interrupt boundaries,
D-cache stall/release behavior, pending-state reset, and CSR metadata-pending
drain.

Execute-acceptance tests also create real multi-cycle D-cache load misses while
a younger CSR or illegal instruction is held in ID/EX. They check that no CSR
write or synchronous trap side effect occurs during backpressure, that release
accepts the held instruction exactly once, and that CSR pre-write readback plus
`mstatus`/`mepc`/`mcause`/`mtval` remain precise.

RV32M squash tests place a younger MUL or DIV behind an older out-of-range
load/store. They check that trap acceptance prevents the M operation from
starting, leaves no in-flight or ready result, and cannot feed stale arithmetic
to a different M instruction executed after the handler advances `mepc` and
returns with `mret`.

The MMIO tests explicitly check that every byte alias in `0x0400..0x05ff`
remains ordinary memory. Accelerator integration tests check accepted starts,
done rises, busy cycles, interrupt behavior, polling behavior, DMA arbitration,
and exact signed results. Assertions are not weakened to accommodate failures.

## Reference and formal scope

Random/reference scripts generate deterministic CPU fixtures from explicit
seeds. They are CPU architectural cross-checks, not official RISC-V
certification.

`formal/matvec_scratchpad_formal.sby` performs a bounded check of Scratchpad
reset recurrence, accepted starts, busy-write isolation, rejected repeated
starts, and one-row progress/completion. Other harnesses cover selected ALU,
forwarding, branch predictor, timer, trap metadata, and x0 invariants. These are
focused bounded properties; they do not constitute a complete accelerator or
CPU formal proof.

## Static and physical checks

Verilator lint checks compile-time consistency. Yosys synthesis smoke checks
selected tops and modules without FPGA timing. Vivado implementation is the
only basis for Basys3 timing claims, and timing is accepted only when post-route
`WNS >= 0` and `TNS = 0`. Canonical promotion also requires generated
post-synthesis and post-route DRC reports, no DRC errors or critical warnings,
and no warnings or advisories unless a rule is explicitly reviewed and added
to the release allowlist. The parser reconciles the sum of parsed rule counts
with `Checks found`; incomplete or changed report formats fail closed.
`REQP-1839` BRAM asynchronous-control warnings are always rejected. A
generated bitstream is not physical validation.
The GitHub Check workflow runs the portable `scripts/check.ps1` gate only; its
badge does not imply that lint, synthesis, formal, Vivado, physical, or final
release gates ran for the same commit.

Regression, portable check, lint, Yosys, formal, and catalog summaries are
source-bound: they record one normalized verification-input fingerprint and
must identify the canonical Vivado source commit. Documentation coverage,
link, and claim gates are repository-bound: they record a separate public
documentation/package fingerprint and the evidence-generation HEAD. These
documentation gates run after the new FPGA and final package contents exist,
so a later physical-evidence commit does not invalidate source-bound results.

The direct-100-MHz source revision at commit `d7f1afe` has a canonical
bitstream whose matching post-route report records WNS `+0.318 ns` and TNS
`0`, and passed the scoped 2026-07-30 physical suite. XSDB
programming/configured state and exact UART transcripts are machine-recorded;
LED/reset observations are operator-reported. This scope does not establish official
compliance, exhaustive physical coverage, random-seed robustness, or on-board
bitstream readback, and it does not transfer to later RTL revisions.

The current Basys3 flow can sweep five documented implementation-directive
profiles, requires all five to meet timing and constraint checks, and reports
the worst routed slack separately from an optional `+0.200 ns` margin target.
Each profile must also have a release-approved DRC report. This is
multi-strategy placement/routing evidence, not a random-seed or exhaustive
physical-design proof. Current source receives no timing or physical claim
from a later revision until its own sweep, canonical bitstream, and scoped
board validation complete. The current five profiles all met timing, with worst
WNS `+0.079 ns`; the optional `+0.200 ns` margin target was not met.
The runtime-wrapper integration test separately checks that board reset is
sampled by an `ASYNC_REG`-marked two-flop synchronizer and resets protocol
state without erasing external BRAM.

Current machine-readable run outputs are generated under `wave/` and copied
into `release/` by the release flow. See [Evidence packages](evidence/README.md).
