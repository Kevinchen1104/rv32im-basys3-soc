# MATVEC: software versus accelerators

This experiment measures the cost of producing signed-int32 RAM results from
packed signed-int8 matrix and vector operands already in RAM. It compares
GCC-compiled software, Scratchpad MATVEC, and DMA-lite on the same RTL CPU.

This page covers the iterative-CPU/internal-RAM benchmark. For the
fast-multiplier baseline, synchronous BRAM comparison and whole-SoC resource
cost, start with the [architecture evaluation](architecture-evaluation.md).

**The measured benefit comes from both parallel arithmetic and the software
interface.** DMA-lite is usually fastest because results go directly to RAM.
Scratchpad benefits strongly from reusing uploaded weights and wins the
smallest repeated-row case. The arithmetic pipeline alone does not describe
either method's application cost.

## Reproduce

Use native Python 3.10+, Icarus Verilog and RISC-V GCC, objcopy, objdump and nm.
The existing `.venv` can be reused; this benchmark uses Python's standard library.
From the repository root:

```powershell
.venv/Scripts/python.exe -B scripts/matvec_benchmark.py
```

If the compiler is outside PATH, append `--toolchain-bin C:/path/to/bin`.
`--prefix riscv32-unknown-elf-` selects a different executable prefix.
`RISCV_TOOLCHAIN_BIN` and `RISCV_PREFIX` also supply these settings.

A shorter run and the benchmark's checker tests are:

```powershell
.venv/Scripts/python.exe -B scripts/matvec_benchmark.py --rows 1 4 --jobs 1 --scenarios stream
.venv/Scripts/python.exe -B -m unittest discover -s scripts/tests -p test_matvec_benchmark.py -v
```

Read `results/matvec-benchmark/RESULTS.md`. It shows total cycles and speedups;
`measurements.csv` adds retirement, cache-miss, stall and accelerator-activity
counters. `summary.json` records source hashes, tools, every checked result,
image hashes and log/snapshot hashes. Per-case folders contain the simulator
log and cache-visible RAM snapshot. Compiler logs and disassembly are shared
per method under `results/matvec-benchmark/build/`. Rebuildable images and the
single simulator executable are under `build/matvec-benchmark/`.

Subset selections use separate directories. A rerun first changes its summary
to `running`; failure replaces it with `failed` and retains diagnostics.
`running.lock` is a small persistent lock file. The operating system releases
its lock when the process exits, including interruptions; do not delete it
while a run is active. Repeating the same selection overwrites its own outputs.

## Workloads and drivers

| Dimension | Values |
| --- | --- |
| Matrix shape | 1, 2, 4, 8 or 16 rows, always 4 columns |
| Batch size | 1, 4 or 8 vectors/jobs |
| Stream | A different RAM matrix and vector for each job |
| Reuse | One RAM matrix shared by the batch; a different vector for each job |
| Methods | Software, Scratchpad, DMA-lite |

The complete matrix is **5 x 3 x 2 x 3 = 90 executions**, checking **2,418 output
words**. Inputs follow fixed integer formulas covering positive and negative
int8 values, including -128. The Python oracle computes signed dot products
before packing the lanes. Every execution also checks that input arrays remain
unchanged, unused output slots remain zero, and the program completed normally.

All drivers use `firmware/c/matvec_benchmark.c`, compiled separately with GCC
`-O2 -march=rv32im -mabi=ilp32`. The software kernel loads each packed matrix row
once, extracts its four signed lanes, and keeps the vector lanes in registers.
Volatile RAM operands prevent constant folding; the kernel is not inlined.
The linker/startup are shared with the existing compiled-C workflow. Matrix,
vector and output arrays are 64-byte aligned and have identical addresses in
all three binaries; the runner checks this before comparing measurements.
`-fno-toplevel-reorder` keeps their declaration order. `--param=min-pagesize=0`
allows GCC's low-address analysis to match the bare-metal MMIO map below 4 KiB.

Scratchpad setup writes the row count, uploads matrix rows, writes the vector,
starts, polls, and copies each result to RAM. In Reuse, the matrix upload occurs
once inside the measured batch; in Stream, it occurs for every job. `CTRL=3`
clears the previous sticky completion flag when starting each job.

DMA-lite writes descriptors, starts and polls; it deposits outputs directly in
RAM. Matrices above four rows are split into four-row jobs, including all extra
descriptor/start/poll costs. Reuse keeps the matrix in RAM: DMA still reads it
for each job. For matrices of at most four rows, the unchanged matrix descriptor
is configured once per Reuse batch. Both accelerators use polling in this comparison.

## Measurement boundary

Each execution resets the SoC, loads its image, and runs the normal C startup.
The measured interval begins when `benchmark_begin` retires and ends when
`benchmark_end` retires. It includes driver setup, operand upload/reads, all
jobs, polling, and output stores. Input generation, startup/BSS clearing and
the host's correctness comparison are outside the interval. Configuration
arguments are read before the begin marker. The two marker instructions have
the same role in all binaries; no timing-read MMIO calls are inserted per job.

RAM results mean CPU-visible data memory, including dirty resident D-cache
words. The checker overlays those words onto backing RAM; it does not force a
writeback at the end. All three methods use this same completion contract.

The interval includes instruction and data-cache effects of the actual compiled
drivers. Each case starts from reset, then inherits the cache state left by
startup; subsequent jobs share cache/predictor state naturally. This is a
batch-level measurement rather than an artificially cache-flushed kernel loop.
The profile uses 16 KiB internal simulated memory, 64-byte I/D caches and branch
prediction. The retained CPU/accelerator RTL is unchanged by the benchmark.

- **Total cycles** are the performance-counter difference between marker retirements.
- **Cycles per job** are total cycles divided by batch size, including the initial setup.
- **Speedup** is software total cycles divided by accelerator total cycles for the same workload.
- **Busy cycles** count cycles while either accelerator is active. DMA busy time includes transfers and descriptor validation; Scratchpad busy time includes row load and commit.
- **Arithmetic cycles** count accelerator multiply/reduce states only: two cycles per output row. They are a subset of busy cycles, not a second component to add to total time. Software has zero accelerator activity, not zero computation time.

The checker independently requires the expected number of launches and arithmetic
cycles. Large DMA jobs therefore must complete every four-row chunk, not just
return plausible final values.

## Recorded results

The checked publication snapshot consists of
[all measurements](benchmarks/matvec/measurements.csv) and
[run/source metadata](benchmarks/matvec/run.json). It retains the full experiment
matrix without committing simulator executables, per-case binaries or raw logs.
To verify its coverage, CSV hash and current source identity without a compiler:

```powershell
.venv/Scripts/python.exe -B scripts/matvec_benchmark.py --check-snapshot
```

To regenerate that snapshot, first commit benchmark source changes, then run
the complete matrix with `--publish`. A subset or uncommitted source run cannot
replace it. Local run details remain available under `results/matvec-benchmark/`.

## Interpretation

Representative total-cycle comparisons from the complete 90-case matrix:

| Workload | Software | Scratchpad | DMA-lite | Scratchpad speedup | DMA speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| Stream, 1 row, 1 job | 260 | 174 | 139 | 1.49x | 1.87x |
| Stream, 4 rows, 1 job | 807 | 234 | 147 | 3.45x | 5.49x |
| Stream, 4 rows, 8 jobs | 6,245 | 1,729 | 686 | 3.61x | 9.10x |
| Reuse, 4 rows, 8 jobs | 6,231 | 845 | 664 | 7.37x | 9.38x |
| Reuse, 1 row, 8 jobs | 1,962 | 577 | 593 | 3.40x | 3.31x |
| Reuse, 16 rows, 8 jobs | 23,149 | 1,984 | 1,583 | 11.67x | 14.62x |

The snapshot records the tested source revision. Driver validation changes can
also change compiled instruction layout and cache behavior; cycle differences
from older snapshots are not, by themselves, hardware speedups.

Three observations explain when each interface is useful:

1. **Repeated matrix upload is expensive.** For four rows and eight jobs,
   Scratchpad drops from 1,729 cycles in Stream to 845 in Reuse. The matrix is
   uploaded once instead of eight times; software and DMA totals change little.
   This favors workloads with stable weights and changing input vectors.
2. **DMA avoids CPU result copying, but still has per-job overhead.** It is
   fastest for the four-row and larger examples even after splitting large
   matrices into four-row chunks. For one reused row and eight jobs, Scratchpad
   takes 577 cycles versus DMA's 593: the small job cannot amortize DMA's
   descriptor/start/poll cost as effectively. Batch size alone does not imply
   that DMA must win.
3. **Internal compute latency greatly understates end-to-end cost.** The
   reused 16-row, eight-job workload has only 256 accelerator multiply/reduce
   cycles. Scratchpad still takes 1,984 total cycles and DMA takes 1,583.
   Upload/readback, descriptors, polling, instruction execution and cache
   effects account for the remaining work. Future optimization should first
   examine these measured driver/data-movement costs.

Both accelerators beat software in all 30 measured workload conditions. No
break-even crossing against software occurs within this matrix; the smallest
tested case is already faster. This does not locate a break-even threshold
outside the tested sizes, or include receiving/unpacking inputs from UART.

The software baseline uses the core's iterative RV32M unit: each multiply
performs 32 shift/add iterations. The accelerator instead evaluates four
signed-int8 products in parallel. End-to-end gains therefore depend on this
specific arithmetic implementation as well as the amount of MMIO/data movement.
When comparing another CPU or memory backend, rerun the same workload contract
and timing boundary. The separate board measurements below use that same
RAM-to-RAM workload contract; power has not been measured.

## Physical board measurements

`firmware/c/board_matvec.c` runs the same 90 workload combinations on the
100-MHz Basys3 target: five row counts, three batch sizes, Stream/Reuse, and
software/Scratchpad/DMA-lite. It uses the board's separate 4-KiB instruction
and data memories. Data begins at `0x0a00`, above MMIO; the linker reserves
at least 384 bytes for the stack. Operands and BSS are initialized at runtime.

Two volatile reads of the hardware cycle counter at `0x0600` bracket each
RAM-to-RAM operation. The interval includes method dispatch, driver setup,
transfers, polling and output stores, with counter-read overhead left in the
measurement. Operand generation, result checking and UART printing are outside
the interval. Microseconds equal cycles divided by 100 at this board clock.

All methods use the same binary and RAM locations. Each case regenerates its
inputs and poisons the output buffer before measurement. Caches and prediction
remain enabled; cases run in a fixed order without a cache flush. A repeat
restarts the entire firmware after board reset. The host checks all 2,418
reported output words against independent signed Python dot products and
rejects missing/duplicated cases, bad output, or incomplete UART captures.

This board profile uses external BRAM-backed data memory and firmware-read
counters. The earlier RTL benchmark uses internal simulated memory and
retire-marker timing. Compare the three methods within each profile, not
their absolute cycle counts across the two profiles.

### Measured results

The [dated board run](./fpga/board_evidence/automatic_acceptance_5c1c4c0/README.md)
passed all 90 cases twice, with 2,418 numerical outputs checked in each run.
The repeat after JTAG reconfiguration and firmware reload produced identical
cycle counts for every case. At 100 MHz, one cycle is 0.01 microseconds; the
values below include all jobs in the batch. The earlier
[2026-09-30 run](./fpga/board_evidence/basys3_full_direct_100mhz_2026-09-30/README.md)
separately records an operator-pressed BTN C repeat.

| Workload | Software cycles | Scratchpad cycles | DMA-lite cycles | Scratchpad speedup | DMA-lite speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| Stream, 4 rows, 1 job | 917 | 311 | 235 | 2.95x | 3.90x |
| Stream, 16 rows, 8 jobs | 22,043 | 3,111 | 2,130 | 7.09x | 10.35x |
| Reuse, 16 rows, 8 jobs | 22,064 | 2,241 | 2,200 | 9.85x | 10.03x |

Across the 30 workload conditions, Scratchpad is 1.59-9.85x faster than
software and DMA-lite is 1.87-10.35x faster. Larger batches amortize setup,
while Scratchpad benefits from retaining a reused matrix: its 16-row,
eight-job cost drops from 3,111 to 2,241 cycles. DMA-lite reloads operands
for each job and does not gain the same reuse advantage. These results
confirm the accelerators' benefit with the actual board memory and driver
overhead included. The [complete cycle CSV](./fpga/board_evidence/automatic_acceptance_5c1c4c0/default/Matvec/measurements.csv)
provides the remaining workload sizes and methods.

### Reproducing the measurements

Prepare and verify the firmware without accessing hardware:

```powershell
.venv/Scripts/python.exe -B scripts/board_matvec.py --build --simulate --toolchain-bin C:/path/to/bin
```

After programming the source-matched 100-MHz bitstream, capture it using:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/basys3-board-demo.ps1 `
  -Target FullDirect100 -Demo Matvec -Port COM3 `
  -TranscriptPath results/board/Matvec/uart.txt `
  -SummaryPath results/board/Matvec/summary.json
```

Use the actual board COM port. Reset or reconfigure before sending a new
packet. `comparison.json` and `measurements.csv` are written beside the UART
transcript only after all numerical checks pass.
