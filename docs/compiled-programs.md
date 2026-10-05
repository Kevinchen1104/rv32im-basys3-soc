# GCC-compiled C programs

This optional flow executes the same GCC-generated program in the RTL CPU and
the external [Unicorn](https://www.unicorn-engine.org/) RV32 emulator. It checks
the compiler/ABI path as well as instruction execution with caches and branch
prediction enabled.

## Run

Use native Windows Python 3.10 or later, Icarus Verilog, Git, and a GNU RISC-V
bare-metal toolchain containing GCC, objcopy, objdump, and nm. The compiler can
be named `riscv64-unknown-elf-gcc`: `-march=rv32im -mabi=ilp32` selects its 32-bit
target. The toolchain must have RV32 support.

The compiled-program flow alone supports Python 3.10. If the same environment
will also run the signal viewer or full Python test suite, use Python 3.11 or
later with Tk because the pinned Matplotlib dependency requires it. CI uses
Python 3.12.

From the repository root, create the optional environment once:

```powershell
py -3 -m venv .venv
.venv/Scripts/python.exe -m pip install -r tools/compiled-programs/requirements.txt
```

If Python was installed without the `py` launcher, use its native Windows
`python.exe` in the first command instead of `py -3`. An existing `.venv`
with these requirements can be reused.

Run the complete twelve-case matrix:

```powershell
.venv/Scripts/python.exe -B scripts/compiled_programs.py
```

If the RISC-V tools are outside PATH, append `--toolchain-bin C:/path/to/bin`.
For a different executable prefix, append `--prefix riscv32-unknown-elf-`.
`RISCV_TOOLCHAIN_BIN` and `RISCV_PREFIX` provide the same defaults.

For a shorter run or a check of the comparator itself:

```powershell
.venv/Scripts/python.exe -B scripts/compiled_programs.py --cases arithmetic --optimizations O2
.venv/Scripts/python.exe -B -m unittest discover -s scripts/tests -p test_compiled_programs.py -v
```

Read `results/compiled-programs/RESULTS.md`. It links to the current run's JSON
metadata. Per-case folders hold compiler logs, disassembly, reference/RTL
traces, data snapshots, and simulator logs. ELF, binary, hex images, and the
simulator executable are under `build/compiled-programs/`.

Subset runs use `subset-<selection hash>/` under both roots; the command prints
their exact report path. Selection order and duplicates do not create new
contexts. Repeating a selection overwrites its own generated files, while the
complete twelve-case report remains separate. A process-owned lock rejects
simultaneous runs of the same selection and releases automatically on exit.

## Programs and comparison

| Program | Main behavior |
| --- | --- |
| `arithmetic.c` | Signed/unsigned arithmetic, multiplication, division, remainder, shifts, and comparisons |
| `memory.c` | BSS initialization, byte/halfword stores, sign extension, and arrays larger than the D-cache |
| `calls.c` | Nested calls, a function-pointer call, loops, stack use, and conditional control flow |
| `matvec.c` | A software-only signed-int8 4-by-4 matrix/vector calculation |

Each program is rebuilt at `-O0`, `-O2`, and `-Os`. Volatile inputs prevent
replacement of the calculations by constant answers. Function-call helpers
also use `noinline` to retain the calling-convention exercise.

Unicorn executes every instruction and supplies the post-instruction register
values. The adapter only identifies destination-register metadata; it does
not compute instruction results. The comparator checks retired PC,
instruction bits, write enable, destination, and writeback value in order.
After the completion loop retires, it also compares all 4 KiB of data RAM.
The testbench overlays resident D-cache words onto backing memory so dirty
lines are included. Sixteen signature words are additionally checked against
algorithm-level expected answers computed separately from Unicorn.

The startup code sets a 16-byte-aligned stack pointer, clears BSS and the
signature area, calls `main`, and enters a named completion loop. Uninitialized
data RAM starts with `0xa5` bytes to exercise BSS clearing. Both models begin
at PC zero with the core's existing register-reset values (`xN = N`).
Timeouts, unsupported executed opcodes, out-of-profile data accesses, nonzero
`main` returns, missing artifacts, and comparison failures fail the run.

## Execution profile

| Region | Byte addresses |
| --- | --- |
| Boot stub | `0x0000..0x00ff` |
| C instructions | `0x1000..0x2fff` |
| Initialized data and BSS | Starts at `0x3000`, below `0x3800` |
| Result signature | `0x3800..0x383f` |
| Stack | Grows downward from `0x4000`, above the signature |

The testbench uses 16 KiB of simulated instruction/data address space and the
default enabled core features. The linker places C code/data above the SoC's
MMIO windows. These programs use aligned integer loads/stores and RV32IM
arithmetic/control flow; MMIO, CSR/trap behavior, FENCE, and FENCE.I use other
tests or remain outside this profile. The board's UART boot flow keeps its
existing memory configuration.

Reported RTL cycles include startup, BSS clearing, `main`, and return to the
completion loop. Unicorn provides functional state, not cycle timing. This
is an external-model cross-check of the listed C programs. The separate Sail
flow below checks signatures from selected upstream architectural tests.

Compiler flags follow the [GCC RISC-V options](https://gcc.gnu.org/onlinedocs/gcc/RISC-V-Options.html).
The pinned Unicorn dependency and its [Python interface](https://www.unicorn-engine.org/docs/tutorial.html)
keep the emulator separate from the repository's existing local reference models.

## Optional upstream Sail comparison

The native Windows flow above does not require Linux. For a second independent
reference, `scripts/sail_reference.py` runs the upstream Sail RISC-V model on
the same 36 selected RV32I/M test images used by `arch-test-run.ps1`. This is a
signature comparison against the official model, **not a claim of complete
ISA compliance**, a complete privileged architecture, or an ACT certification.

The tested reference is the x86-64 Linux release of Sail RISC-V **0.14.1**.
On Windows, an optional Ubuntu WSL installation can host it. Install Ubuntu
once in an administrator terminal, following any restart prompt:

```powershell
wsl --install -d Ubuntu --no-launch
```

Open its root shell with `wsl -d Ubuntu -u root`, then install the pinned
[official release](https://github.com/riscv/sail-riscv/releases/tag/0.14.1):

```bash
mkdir -p /opt/cpu-reference
cd /opt/cpu-reference
curl -fL https://github.com/riscv/sail-riscv/releases/download/0.14.1/sail-riscv-Linux-x86_64.tar.gz -o sail-riscv-0.14.1.tar.gz
echo 'de45a89748ca67a8a522b3ac0924c303b5609a16bb50d759bbd08c4d440df0eb  sail-riscv-0.14.1.tar.gz' | sha256sum --check
tar -xzf sail-riscv-0.14.1.tar.gz
exit
```

From a Windows terminal at the repository root, run the DUT tests first and
then the independent model. Keep verification sources unchanged during both:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/arch-test-setup.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/arch-test-run.ps1 -Profile rv32im-selected
.venv/Scripts/python.exe -B scripts/sail_reference.py --wsl Ubuntu --sail /opt/cpu-reference/sail-riscv-Linux-x86_64/bin/sail_riscv_sim
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/results-overview.ps1
```

The selected-test profile pins the upstream test revision. The DUT's existing
local-reference check remains a separate result; Sail does not replace or
silently relabel it. Sail loads an ELF with the original symbols and exactly
the DUT's bytes. Executable zero-word padding is converted to NOPs by the
existing DUT adapter; the Sail adapter permits that same conversion and
rejects any changed nonzero instruction or data word. Each model must reach
successful termination and produce identical, nonempty signatures.

Read `results/arch-test/sail/summary.json` for the configuration, model version
and binary hash, input identities, per-test word counts, and artifact hashes.
Logs and signatures are beside that summary. `--case rv32i-I-add-01` is a
single-case diagnostic and produces `diagnostic_passed`, never a full-matrix
pass. Diagnostic selections have separate `cases-<hash>/` subdirectories, so
they cannot overwrite the complete matrix. Repeating the same selection
replaces only that selection's records.
