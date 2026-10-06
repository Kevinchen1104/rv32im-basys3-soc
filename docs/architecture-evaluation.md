# Architecture evaluation

This study asks which changes improve useful work on the CPU, and which costs
remain after replacing the iterative multiplier. It compares the same compiled
images across CPU configurations, then compares software with two independently
selectable MATVEC interfaces. These measurements established the compute
baseline for the now-working [interactive signal application](signal-console.md).

## Findings and decisions

The full study contains **380 checked executions**: 200 with internal RAM and
180 with the synchronous BRAM data backend. Paired CPU runs share the same
compiled image. [All measurements](benchmarks/architecture/measurements.csv)
and [source/tool metadata](benchmarks/architecture/run-metadata.json) retain the
complete matrix, including results that do not improve.

The complete matrix was refreshed at `5c1c4c0`, including the corrected MATVEC
driver's row-count validation. Paired runs use the same compiled image. The
[standalone MATVEC baseline](matvec-benchmark.md) uses its own measurement
interval; do not substitute its counts into these comparisons.

### Improve the CPU baseline before judging offload

With synchronous BRAM and `-O2`, FIR falls from **26,922 to 12,402 cycles
(2.17x)** with the fast multiplier. Both runs retire 6,105 instructions. Their
RV32M raw stall counts fall from 16,940 to 2,420. CRC-32 and insertion sort have
no RV32M stalls and do not improve: the multiplier is useful, not a universal
solution. Unit latency is 33 versus 3 cycles; execute-stage ownership adds
pipeline overhead, so this is not an 11x whole-program speedup.

### Offload depends on work size and reuse

All values below are cycles with the synchronous BRAM backend and include the drivers.

| MATVEC workload | Iterative CPU | Fast CPU | Fast + Scratchpad | Fast + DMA |
| --- | ---: | ---: | ---: | ---: |
| Stream, 1 row x 1 job | 263 | 143 | 183 | 143 |
| Stream, 4 rows x 1 job | 822 | 342 | 243 | 167 |
| Stream, 16 rows x 8 jobs | 23,670 | 8,310 | 3,664 | 2,136 |
| Reuse, 16 rows x 8 jobs | 23,667 | 8,307 | 2,097 | 2,131 |

The large streaming case retains a **3.89x cycle advantage over the fast CPU**.
Reporting only 11.08x against the iterative CPU would mix improvements to
general multiplication with the benefit of offload. For one streaming row and
one job, the fast CPU and DMA tie at 143 cycles; offload provides no cycle
benefit there. With a reused 16-row matrix, Scratchpad slightly beats DMA
because it amortizes the initial upload. The internal-RAM model instead gives
DMA the advantage in that case (1,583 versus 1,984 cycles); backing-memory
latency therefore changes the interface decision.

Both accelerators spend 256 multiply/reduce cycles on 16 rows x 8 jobs.
Scratchpad is busy for 512 cycles and DMA for 1,152 cycles with synchronous
BRAM. DMA's remaining 896 busy cycles are internal transfer/control work.
Its whole driver interval is 2,136 cycles: arithmetic latency alone does not
explain application cost. CPU and accelerator activity can overlap, so the
busy counter must not be added to CPU time as an independent component.

The drivers poll MMIO without competing RAM accesses while DMA owns memory.
Consequently a zero DMA-ownership stall count in these runs is **not evidence
of concurrent CPU memory progress**. Arbitration or double buffering should
be justified by an application that actually needs this overlap.

### Memory organization and instruction footprint

The three traversal tests issue 1,024 volatile loads and retire 7,175
instructions each at `-O2`. Fast-CPU cycles are 7,226 for resident data, 8,234
for sequential traversal and 11,297 for conflict traversal. Conflict accesses
eight words at a 16-word stride: only 32 bytes are repeatedly read, but the
addresses map to one direct-mapped D-cache index. Capacity alone is an
insufficient description of this workload.

CRC-32 illustrates an instruction-side issue. `-O2` takes 16,313 cycles with
2,056 I-cache misses; `-Os` takes 11,927 cycles with 391 misses despite retiring
more instructions (8,175 versus 7,578) and recording more branch misses
(641 versus 2). The measured regions span 340 and 92 instruction bytes,
respectively. This supports investigating instruction footprint alongside the
64-byte I-cache. Compiler flags also change layout and scheduling, so this is
not a single-variable cache-size experiment.

Prediction remains valuable: disabling it increases `-O2` sort from 15,025 to
19,962 cycles. The subsequent [I-cache](icache-study.md) and
[D-cache](dcache-study.md) experiments compare synchronous request/response
designs while holding prediction fixed, rather than enlarging every cache by
default.

### Resource and timing evidence

[Implementation measurements](benchmarks/architecture/implementation.csv)
compare five full SoC profiles at 100 MHz; [the metadata and retained routed
reports](benchmarks/architecture/implementation-metadata.json) identify their
sources, utilization, critical paths and DRC observations. LUT, FF, BRAM and
DSP counts remain separate. Hierarchical module area and whole-SoC deltas are
both useful: enabling DMA also retains D-cache snoop logic and changes MMIO
integration, so the DMA module's own LUT count understates its system cost.

All five profiles meet 100 MHz setup/hold constraints and pass routed DRC
with zero warnings. Each uses two BRAM tiles. The four study profiles were
rebuilt at `5c1c4c0`; the default uses the `9d46f04` build, whose 45
hardware/build inputs match the same reviewed source.

| Profile | SoC LUT | SoC FF | DSP | Setup slack (ns) | Hold slack (ns) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Iterative CPU | 6,874 | 5,447 | 0 | +0.095 | +0.058 |
| Fast CPU | 6,718 | 5,287 | 4 | +0.067 | +0.010 |
| Fast + Scratchpad | 7,755 | 6,505 | 4 | +0.399 | +0.034 |
| Fast + DMA | 8,253 | 5,809 | 4 | +0.111 | +0.045 |
| Default: iterative + both accelerators | 9,476 | 7,179 | 0 | +0.323 | +0.040 |

Adding DMA to the fast CPU costs 1,535 whole-SoC LUTs, while the DMA module
itself accounts for 674. The D-cache hierarchy grows from 1,099 to 1,450
LUTs with its snoop path retained; MMIO/control integration and implementation
optimization account for other differences. Scratchpad adds 1,037 SoC LUTs
but uses 696 more FFs than the DMA profile. Neither interface dominates
every resource and workload dimension.

The fast CPU's limiting routed path starts at `PC[29]` and ends at `PC[31]`,
rather than in the multiplier. Scratchpad's limiting path starts at
`EXMEMALUOut[7]` and ends at `ControlRedirectPending`. Faster multiplication
improves cycles per program without removing the remaining control/routing
frequency limit.

The fast profiles use **four fully pipelined DSP blocks**. Each partial product
uses input, multiplier and output registers (AREG/BREG, MREG and PREG).
Carry-save reduction combines the four signed partial products before one
final carry-propagate addition. The accepted-operation latency remains three
cycles: partial-product calculation, DSP output registration, then combination
and completion.

This pipeline organization addresses the earlier DSP input/output-register
advisories through explicit RTL registers, not warning waivers. The retained
reports describe the current mapping and each profile's routed timing.
Whole-SoC resource and slack differences include implementation optimization;
they are not isolated cell-area or power measurements. Power was not measured.

The unit test checks all four multiply variants for 64
edge-value pairs and 2,048 fixed-seed random pairs in both implementations,
along with latency, busy-request rejection and reset cancellation.

The implementation comparison is one placement/route result per profile, not
a sweep of seeds or proof of maximum achievable frequency.

### Decision for the interactive application

The [interactive signal application](signal-console.md) now uses the fast CPU
on the physical board. It starts with software signal processing; an
accelerator should be added only when the workload justifies its transfer and
resource costs. The original default configuration and its dated board
records remain separate from this application profile.

The application accepts new UART data, runs configurable C firmware, returns
FIR results and drives GPIO. Its documentation records firmware/stack/buffer
space and distinguishes UART-to-result latency from compute time. Those
physical observations are not measurements from this earlier simulation suite.

For subsequent core/SoC separation, define one outstanding request with an
explicit acceptance event, stable payload until acceptance, exactly one
response, byte enables, error reporting and reset cancellation. The present
line backend has a completion pulse rather than a full valid/ready interface;
an adapter is needed before replacing it with a generic word bus. Preserve
precise exception ordering and UART backpressure during that work. This is a
concrete follow-up contract, not a bus refactor performed by this experiment.

## Configurations

| Profile | Multiplier | MATVEC | Purpose |
| --- | --- | --- | --- |
| `iterative_cpu` | 33 cycles after acceptance | None | Baseline A |
| `fast_cpu` | 3 cycles after acceptance | None | Baseline B |
| `fast_scratchpad` | Fast | Scratchpad only | Offload alternative C1 |
| `fast_dma` | Fast | DMA-lite only | Offload alternative C2 |
| `fast_no_prediction` | Fast | None | Branch-prediction sensitivity |
| `fast_ideal_memory` | Fast | None | Asynchronous internal RAM, caches bypassed |

Division remains iterative in every configuration. The original default board
configuration remains available; selecting a study profile is explicit. The
fast implementation splits each operand into signed 17-bit limbs: the low
limb is nonnegative, while the high limb carries the instruction's signedness.
Four registered partial products are combined modulo 2^64, so signed high-word
results require no later correction. The same unit tests exercise
both implementations, including signed high products and divide edge cases.

## Workloads and measurement intervals

The suite compiles arithmetic, subword memory, nested/indirect calls and small
MATVEC examples, plus FIR, CRC-32, insertion sort and three equal-load-count
memory traversals. Each is compiled at `-O2` and `-Os`. CPU profiles execute
identical image bytes; every retired instruction and the complete 4 KiB data
snapshot are compared with Unicorn. Separate Python algorithms check the
result signatures, including `zlib.crc32` for CRC.

New workloads use retired begin/end markers around the algorithm, after input
initialization. Existing examples measure from retirement of the first `main`
instruction through retirement of `program_done`. These intervals exclude the
startup BSS clearing loop. They are appropriate for **within-workload** profile
comparisons, not an absolute ranking of unrelated algorithms.

The MATVEC sweep covers two input-reuse patterns, five row counts, three job
counts and four profiles: 120 cases. It includes driver setup, polling and
RAM-to-RAM transfers. The signed Python dot-product oracle checks every output
and confirms that inputs were not modified. Software A/B share an image;
accelerator drivers necessarily use different instruction sequences.

## Stall accounting

The profiling testbench samples the six stall conditions at the same rising
edge as the hardware counters. A 64-entry histogram records every combination
of active conditions, including zero. Counters reconcile against both the
independently counted interval clocks and the retirement trace.

- Raw cause counts may overlap and must not be added.
- Exclusive counts attribute each stalled cycle in this order: UART, DMA
  memory ownership, D-cache, RV32M, I-cache, load-use. This is an attribution
  convention, not proof of the cycles saved by removing that cause.
- `sum(exclusive causes) = stall counter`.
- `retired + stalls + no-retire/no-stall - retired-with-stall = cycles`.
- Accelerator busy cycles and multiply/reduce cycles are sampled separately.
  Their difference is accelerator-side transfer/control time, not total
  software driver overhead.

## Memory and time interpretation

The main simulation uses 16 KiB IMEM and 16 KiB DMEM with the core's internal
RAM model and its 64-byte caches. This permits larger C workloads than the
4 KiB-per-memory board configuration. Cold reset occurs before each case, but
startup and input initialization can warm cache lines before the interval.

A second matrix uses `external_dmem_bram`, the same synchronous data-memory
backend as the board, scaled to 16 KiB. Instruction fetch keeps the internal
combinational line source. This separates cache/backing-memory latency from
the multiplier and offload changes; it is an RTL model, not a new board run.

`fast_ideal_memory` is a sensitivity reference, **not a synthesized synchronous
BRAM replacement**. Its asynchronous read and absent cache penalties describe
the opportunity exposed by the current memory system. Implementing a real
cache bypass requires a registered request/response adapter and a new timing
measurement. A lower cycle count in this profile cannot establish a superior
FPGA implementation.

FPGA comparisons use the actual Basys3 top with 4 KiB memories, the same
100-MHz constraint and the same synthesis/place/route directives. Resource
counts are for the complete SoC. LUT, FF, BRAM and DSP are reported separately.
Simulation speedup uses cycles; converting to time at 100 MHz is conditional
on a configuration meeting that target. This study does not replace the
existing physical-board evidence with simulated observations.

The subsequent [I-cache design study](icache-study.md) tests the instruction
footprint hypothesis with fixed binaries, parameterized capacity and banked
storage. Its external-IMEM handshake model differs from this study's internal
IMEM, so compare cache sizes within that matrix rather than subtracting cycle
counts between studies.

## Reproduce

With the Python environment and RISC-V GCC described in
[the compiled C setup](compiled-programs.md), run:

```powershell
.venv/Scripts/python.exe -B scripts/architecture_benchmark.py
.venv/Scripts/python.exe -B scripts/architecture_benchmark.py --external-dmem
```

`--smoke` writes an isolated small matrix. Complete results overwrite the
stable `results/architecture/complete` directory; build products are retained
under `build/architecture/complete`. A running/failed status replaces old
success before work starts. The summary records tool versions, source hashes,
image hashes, overlap histograms and hashes of the retained evidence.
The external-memory matrix uses the separate `complete-external` context.

For a routed hardware profile:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/vivado-basys3-build.ps1 -Implementation -ArchitectureProfile fast_cpu -OutDir build/vivado/architecture_fast_cpu -SummaryPath results/architecture/fast_cpu-implementation.json -LogPath results/architecture/fast_cpu-vivado.log
```

Use `iterative_cpu`, `fast_scratchpad` or `fast_dma` with matching output paths
for the other comparisons. `-Implementation` does not program the board.
