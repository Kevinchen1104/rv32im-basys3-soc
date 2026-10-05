# Documentation index

Start with the Signal console to use the CPU on a board, Architecture evaluation
for measured design trade-offs, or Reproduce to run the checks without hardware.

| Document | Reader purpose |
| --- | --- |
| [Interactive signal console](signal-console.md) | Start the live viewer, load firmware, handle reset/power loss and run physical checks |
| [Architecture](architecture.md) | Understand the CPU/SoC structure and data flow |
| [ISA and MMIO](isa_mmio.md) | Implement or review software-visible behavior |
| [Accelerators](accelerators.md) | Understand Scratchpad and DMA-lite contracts |
| [MATVEC benchmark](matvec-benchmark.md) | Compare RAM-to-RAM software and accelerator costs |
| [Architecture evaluation](architecture-evaluation.md) | Compare multiplier, memory, offload and routed SoC trade-offs across 380 executions |
| [I-cache study](icache-study.md) | Compare lookup organization, capacity, timing and physical FIR measurements |
| [D-cache study](dcache-study.md) | Compare primary capacity, victim storage, traffic and FPGA implementation cost |
| [Verification](verification.md) | See test groups, tools, and result locations |
| [Basys3](fpga_basys3.md) | Rebuild FPGA targets and interpret timing/physical status |
| [Timing and resource baseline](timing_baseline.md) | Locate the routed critical path and prioritize FPGA optimizations |
| [Timing optimization history](timing_history.md) | Review earlier candidates, proofs, and rejected experiments |
| [Reproduce](reproduce.md) | Run the portable and optional tool flows |
| [Compiled C and official references](compiled-programs.md) | Build GCC programs, compare with Unicorn, and optionally cross-check selected upstream tests with Sail |
| [Artifact lifecycle](artifact-lifecycle.md) | Understand generated directories, cleanup, and retained evidence |
| [Operating constraints](limitations.md) | Check supported configurations and software assumptions |
| [Documentation review](documentation-review.md) | Review diagrams, explanations, and evidence-backed wording |
| [Evidence packages](evidence/README.md) | Locate generated review artifacts |
| [Current automatic board acceptance](./fpga/board_evidence/automatic_acceptance_5c1c4c0/README.md) | Inspect source-matched default/application images, JTAG/UART/MATVEC/FIR checks and reload repeats |
| [Earlier operator-confirmed board evidence](./fpga/board_evidence/basys3_full_direct_100mhz_2026-09-30/README.md) | Inspect the dated LED/BTN C observations and their original bitstream identity |
| [Interactive FIR burst-transfer evidence](./fpga/board_evidence/signal_console_burst_2026-10-01/README.md) | Compare measured latency before/after bounded bursts, resource cost, 400 stress batches, and reset/reload |
| [Interactive FIR per-byte baseline](./fpga/board_evidence/signal_console_2026-10-01/README.md) | Inspect the original per-byte ACK measurements used for comparison |
| [Physical signal viewer capture](./fpga/board_evidence/automatic_acceptance_5c1c4c0/viewer/) | Inspect the plotted UART data, settings and ten-session numerical validation |

The machine-readable regression inventory is
[`test_catalog.json`](test_catalog.json).
