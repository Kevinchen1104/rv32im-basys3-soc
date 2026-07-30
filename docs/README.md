# Documentation index

These pages are the maintained public description of the design. RTL,
firmware, tests, and generated reports remain authoritative when a statement
depends on implementation details or a specific run.

| Document | Reader purpose |
| --- | --- |
| [Architecture](architecture.md) | Understand the CPU/SoC structure and data flow |
| [ISA and MMIO](isa_mmio.md) | Implement or review software-visible behavior |
| [Accelerators](accelerators.md) | Understand Scratchpad and DMA-lite contracts |
| [Verification](verification.md) | See test layers, formal scope, and claim rules |
| [Basys3](fpga_basys3.md) | Rebuild FPGA targets and interpret timing/physical status |
| [Reproduce](reproduce.md) | Run the portable and optional tool flows |
| [Limitations](limitations.md) | Read explicit technical boundaries and non-claims |
| [Evidence packages](evidence/README.md) | Locate generated review artifacts |
| [Current Basys3 board evidence](./fpga/board_evidence/basys3_full_direct_100mhz_2026-07-30/README.md) | Inspect the source-matched `d7f1afe` Vivado, XSDB, UART, and board-observation record |

The machine-readable regression inventory is
[`test_catalog.json`](test_catalog.json).
