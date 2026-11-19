# Verification

The portable workflow checks instruction behavior, pipeline control, memory
and MMIO transactions, accelerator results, and the scripts that generate
those results. Optional tool flows add lint, bounded formal checks, synthesis,
and FPGA implementation.

## Run and inspect

Run `scripts/check.ps1 -Mode Quick` during editing and `-Mode Full` for the
complete portable gate. Full includes all 173 simulations and eight FPGA top
elaborations. See [Reproduce](reproduce.md) for commands and prerequisites.

| Output | Use |
| --- | --- |
| `results/RESULTS.md` | Project result index with source-freshness labels and timing experiments |
| `results/full-RESULTS.md` | Full workflow stages, status, and failure-log links |
| `results/regression.csv` | One row per simulation |
| `results/regression-summary.json` | Commands, timestamps, exit codes, and artifact paths |
| `results/runs/` | Input-isolated simulation logs, summaries, and waveforms |
| `results/logs/` | Workflow and optional-tool output |
| `results/python-tests/` | All Python unit tests, explicit skip counts, source hashes and log |
| `results/signal-console/viewer-validation.json` | Repeatable physical viewer comparisons against an independent FIR calculation |
| `docs/test_catalog.json` | Each test's contract, expected observation, and coverage metadata |

The executable manifest is in `scripts/run.ps1`. Catalog validation checks that
its test names and files agree with the documented inventory.

The runner records log hashes and preserves separate contexts for Full, Quick,
single tests, and simulator arguments. Optional tool summaries are initialized
before execution, so a failed rerun replaces the previous success. Refresh the
project index with `scripts/results-overview.ps1` after optional tool runs.

The Check CI has two independent jobs: the portable RTL gate and
`python_tests.py --gui` for clients, plotting, comparators and helper tools.
Python prerequisites and local commands are in [Reproduce](reproduce.md#python-tools-and-the-fir-application).
The manually dispatched Extended Verification workflow also builds twelve
GCC/Unicorn comparisons and simulates both FIR multiplier profiles. Physical
UART runs require a local board and are not claimed by CI. Viewer snapshots
marked `captured` are separate from numerical tests marked `passed`; the index
checks capture hashes independently of source freshness.

## Directed simulation

The test groups isolate different failure mechanisms:

| Area | Stimulus and expected behavior |
| --- | --- |
| Instruction execution | Arithmetic, loads/stores, branches, CSR operations, and all eight RV32M operations produce their expected results |
| Pipeline acceptance | Hold a younger CSR or illegal instruction behind a real D-cache miss; no early side effect, and exactly one acceptance after release |
| Trap/control transfer | Misaligned taken branch/JAL/JALR targets record cause 0 and the correct PC/target; wrong-path link, predictor, and RAS updates are suppressed |
| RV32M squash | An older memory fault cancels a younger MUL/DIV; a subsequent M instruction receives its own result |
| Memory and MMIO | Exact register decoding, subword aliases, request/ready delays, access faults, and ordinary-memory behavior throughout `0x0400..0x05ff` |
| Accelerators | Signed results, busy/start rules, completion/IRQ behavior, descriptor errors, ownership, and counters |
| UART boot / wrappers | Malformed packets, checksum failure, reset/retry, short images, and invalid wrapper parameters |

The control-transfer tests check the registered N/N+1/N+2 alignment-trap
handoff, newly pending versus previously deferred interrupts, D-cache
stall/release, pending-state reset, and CSR metadata drain. CSR acceptance
tests compare the pre-write readback and `mstatus`, `mepc`, `mcause`, and
`mtval` after the held operation completes.

DMA descriptor tests cover alignment, capacity, 32-bit address wraparound,
and matrix/output overlap. A rejected descriptor must issue no DMEM request.
Integration tests check the D-cache snoop path, CPU memory stalls, polling,
and Scratchpad interrupt delivery.

External-memory adapter tests check deterministic acknowledgement, zero data
for rejected reads, ignored writes, and absence of low-address aliasing.
Packet-loader tests cover bad headers, checksum-failure scrubbing, reset during
a partial payload, shorter retry, zero-length rejection, one-word boot memory,
and NOP tail clearing before CPU release. Wrapper tests also cover UART
divisors, heartbeat indices, debug-status capacity, and initialization bounds.
The banked-IMEM test checks every word and line lane at ten capacities from
1 to 1,025 words, including partial lines and high-address reads.

## Reference programs and formal properties

The optional [GCC-compiled C checks](compiled-programs.md) add an external
Unicorn reference for four C programs at three optimization levels. Each run
compares the retired PC/instruction/register-write stream, cache-visible data
RAM, and algorithm-level result words. These twelve executions are reported
separately from the 173 portable simulations. Comparator self-tests deliberately
corrupt trace fields and memory bytes and exercise timeout/error handling.

Generated-reference tests use fixed seeds and repository reference models to
compare architectural state or retirement traces. Additional seed checks
exercise register, memory, control-flow, hazard, and call/return cases while
keeping failures reproducible. Extra seeds write to `build/reference/`, leaving
checked-in fixtures untouched even after a failed simulation. Selected upstream
architectural tests use retired PCs for pass/fail-loop detection and read
cache-visible signature words. Harness self-tests include a fetched-but-not-retired
pass PC, a dirty signature line, and a rejected empty signature.

The optional [Sail comparison](compiled-programs.md#optional-upstream-sail-comparison)
executes all 36 selected upstream tests in the official Sail RISC-V 0.14.1
model and compares their signatures against the RTL. The model binary, ISA
configuration, ELF, DUT image, and signatures are hash-identified. This adds
an independent reference for the selected RV32I/M instructions; it does not
establish full ISA or privileged-architecture compliance.

Eight bounded formal harnesses check selected ALU, forwarding, predictor,
timer, trap metadata, x0, and Scratchpad properties. The Scratchpad harness
checks reset recurrence, accepted starts, busy-write isolation, rejected
repeated starts, byte-enable preservation, selected-row readback coherence,
and one-row progress/completion. Harness assumptions and
depths are listed in [formal/README.md](../formal/README.md).

## Tools and hardware measurements

| Layer | What is checked | Main evidence |
| --- | --- | --- |
| Icarus | Directed and reference simulations | Per-test logs, VCDs, regression summary |
| Verilator | Nine top-level modules and all ten supported D-cache size/victim combinations | Lint summary and per-configuration logs |
| Yosys | Elaboration and generic synthesis | Selected-top synthesis reports |
| SymbiYosys | Bounded properties | Harness results; counterexamples for falsified properties |
| Vivado | Basys3 implementation, routed timing, and constraints | Timing, utilization, and DRC reports |
| Physical Basys3 | Program loading and observed behavior | XSDB/UART transcripts and LED/reset observations |

Solver runtime can vary. For an incomplete timed-out formal run, append
`-TimeoutSeconds 1800` to `scripts/formal-smoke.ps1` to allow 30 minutes per
harness without changing its proof depth; `-Group Matvec` selects the accelerator.

Timing acceptance requires matching post-route `WNS >= 0` and `TNS = 0`.
The release flow also checks hold timing and constraints. DRC parsing
reconciles individual rule counts with `Checks found`; errors, critical
warnings, unreviewed warnings/advisories, and `REQP-1839` fail the gate.

The earlier routed build at `8c7d5a6` met 100 MHz with WNS `+0.184 ns`,
WHS `+0.046 ns`, zero TNS/THS, complete constraint coverage, and passing DRC.
The earlier direct-100-MHz board build at `849270b` achieved WNS `+0.399 ns`, WHS
`+0.018 ns`, and zero TNS/THS. The
[2026-09-30 board record](./fpga/board_evidence/basys3_full_direct_100mhz_2026-09-30/README.md)
contains machine-recorded XSDB/UART captures, two 90-case MATVEC measurements
with 2,418 checked outputs per run, and operator-reported LED/reset observations.
Both MATVEC runs have identical cycle counts. Earlier build and multi-strategy
results remain in the dated historical records.

Each new Vivado run records hashes of its build inputs and raw reports. Inputs
are checked again after the tool finishes, and report hashes are checked before
export or reuse. Recorded board observations retain their original RTL revision.

## Result identity and documentation review

Simulation and tool summaries carry a verification-input fingerprint.
Release packaging checks that source-bound evidence matches the committed
inputs; documentation reports carry a separate documentation/package
fingerprint. Generated packages and current working results are described in
[Evidence packages](evidence/README.md).

Document links remain a machine-checked integrity requirement. Comment
coverage and claim-language scans are advisory: they identify places for a
reader to review, but do not decide functional success from English wording.
Use the [review checklist](documentation-review.md) when editing public docs.
