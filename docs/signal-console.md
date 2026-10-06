# Interactive signal console

The CPU runs a configurable integer FIR filter on data supplied over UART. The
PC sends samples and displays responses; the C firmware performs the filtering,
maintains history across batches, counts threshold events, and drives the LEDs.
Changing coefficients or data requires no RTL change or FPGA rebuild.

The [Basys3 burst-transfer measurement](fpga/board_evidence/signal_console_burst_2026-10-01/README.md)
reduced a 32-sample, eight-tap command round trip from about 1,148 ms to 61.7 ms
at the same 115200 baud, approximately 18.6 times faster. The transport uses a
64-byte RX FIFO and 32-byte bursts. Two physical sessions, including reset and
firmware reload, checked 13,216 numerical outputs with no UART overrun.
CPU processing for that batch took 100.54 us; communication still dominates.

## Build and test

Use the RISC-V GCC and Icarus setup described in [Compiled C programs](compiled-programs.md).
For the viewer and complete Python test suite, create that environment with
native Windows Python 3.11 or later including Tk (CI uses 3.12). Install both
requirement files before running the tests. From the repository root:

```powershell
.venv/Scripts/python.exe -m pip install -r scripts/signal-viewer-requirements.txt -r tools/compiled-programs/requirements.txt
.venv/Scripts/python.exe -B scripts/signal_console_check.py
.venv/Scripts/python.exe -B scripts/python_tests.py --gui
```

Append `--toolchain-bin C:/path/to/bin` to `signal_console_check.py` if the
RISC-V tools are not on PATH. This checker compiles the firmware, boots it through
the simulated UART pins, and checks commands against a separate Python convolution calculation on
both multiplier profiles. Each session also checks malformed packets, board
LEDs, switch reads, and reset/reboot. Read `results/signal-console/RESULTS.md`;
source hashes and compiler identity are in the adjacent `summary.json`.
Its `--build-only` option produces firmware without running simulation.
Its `--cache-study` option additionally checks the six D-cache study profiles through
the same UART pins and reset/reboot sequence.
The Python runner requires both `scripts/signal-viewer-requirements.txt` and
`tools/compiled-programs/requirements.txt`; it checks all Python helpers, not
just this application. The CI Check workflow runs it as a separate job.

The linker enforces the board's separate 4 KiB instruction and data memories.
Static data starts at `0x0a00`, above MMIO; the downward-growing stack starts at
`0x1000`. GCC emits stack-use records alongside the ELF. All filter state is
initialized on boot, including when BRAM contents survive a reset.

## Prepare the board

Build the software-only fast-multiplier profile at 100 MHz:

```powershell
powershell -File scripts/vivado-basys3-build.ps1 -Bitstream -ArchitectureProfile fast_cpu -OutDir build/vivado/signal_console -SummaryPath results/timing/signal-console-summary.json -LogPath results/signal-console/vivado.log
```

Check that `results/timing/signal-console-summary.json` reports passing timing, DRC and bitstream
generation. In Vivado Hardware Manager, program the Basys3 with
`build/vivado/signal_console/RISCVCPU_basys3_top.bit`. This profile has no MATVEC
accelerators; the original default SoC remains available through the existing
build command. Existing canonical programming helpers select the recorded default
image. For this application, use Hardware Manager or the explicit startup command below.

Install the PC serial client dependency once:

```powershell
.venv/Scripts/python.exe -m pip install pyserial==3.5
.venv/Scripts/python.exe -m serial.tools.list_ports
```

Close other programs using the board's serial port. Press and release **BTN C**,
then replace `COM5` with the listed Basys3 port:

```powershell
.venv/Scripts/python.exe -B scripts/signal_console.py --port COM5 --boot build/signal-console/program.boot.bin
```

The client uploads the C program and waits for its `FIR2` greeting. Use the FIFO
bitstream and FIR2 firmware together; upgrading from FIR1 requires programming
the new bitstream and uploading the new firmware. Subsequent
connections can omit `--boot` if the firmware is still running. After BTN C,
upload it again. After power loss, first program this application's bitstream
again, then upload the firmware: JTAG programming here does not store the image
in the board's nonvolatile Flash. `quit` closes the PC connection and leaves the
filter running. Start with the on-board LEDs and switches; no external wiring is
required.

## Startup and recovery

Use one entry point, `scripts/signal_start.py`, after the build steps above.
Install `scripts/signal-viewer-requirements.txt` once; native Python with Tk is
needed for the window. `--batches N` instead makes a finite headless capture.

```powershell
.venv/Scripts/python.exe -B scripts/signal_start.py --list-ports
.venv/Scripts/python.exe -B scripts/signal_start.py --port COM3 --check
```

`--check` checks dependencies and whether the selected port exists, but does
not open UART or change the board. Add `--upload` or `--program` to preflight
their local prerequisites without performing those actions. Omitting `--port`
is allowed only when exactly one FT2232 UART is found; with multiple candidates,
select the board explicitly. Close other serial clients first.

| Board state | Startup command after `python -B scripts/signal_start.py` |
| --- | --- |
| FIR2 still running | `--port COM3` |
| BTN C was pressed | `--port COM3 --upload` |
| Power was lost or a different FPGA image is loaded | `--port COM3 --program --xsdb C:/path/to/Vivado/bin/xsdb.bat` |
| Query status without opening the viewer | `--port COM3 --probe` |

`--program` deliberately replaces the volatile FPGA image and uploads the C
firmware. It checks the `fast_cpu` build's source identity, timing/DRC status,
and both bitstream/firmware file hashes before proceeding. Rebuild once if an
older implementation summary has no bitstream hash. XSDB must find exactly one matching
FPGA; the actual programmed file hash and tool result are saved in
`results/signal-console/start-programming.json`. It does not program Flash.
Vivado Hardware Manager remains an alternative: select the application bitstream,
then run startup with `--upload`.

For a separately built fast-CPU cache experiment, append
`--build-summary results/timing/<candidate>.json` to an explicit `--program`
command. The same source, timing, DRC and bitstream-hash checks apply to that
summary, and the programming record identifies the selected build. This does
not change the default application image or program nonvolatile Flash.

To reproduce an identified physical cache experiment, first run
`signal_console_check.py --cache-study`, then use:

```powershell
.venv/Scripts/python.exe -B scripts/signal_console_check.py --port COM3 --program --build-summary results/timing/dcache-capacity-dm128.json --xsdb C:/AMDDesignTools/2026.1/Vivado/bin/xsdb.bat --session capacity-dm128
```

The build summary must match current inputs and pass timing/DRC. The selected
geometry must already have passed the UART simulation. Each explicit
`--program` reloads volatile FPGA configuration, providing a reset before
firmware upload. Programming identity and checked responses are recorded
together under `results/signal-console/board-burst/`. Use a different session
label for the reset/reload comparison, or add `--viewer` for numerical viewer
validation. Neither option programs Flash.

The ordinary command only connects; the viewer then applies its chosen filter
and waits for Start. `--probe` queries status without clearing FIR history.
Neither a UART timeout nor a failed JTAG operation triggers automatic retries,
uploads or reprogramming. A busy port means another program must be closed.
An upload timeout means checking reset, port and application image; a successful
FIR2 response confirms protocol compatibility, not a readback of the FPGA image.

## Five-minute walkthrough

Complete the build, board programming and firmware upload before presenting.
Use the `fast_cpu` FIR application, not the default MATVEC image; this demo
needs only the Basys3 and USB cable. Close every other client using its UART.
From the repository root, replace `COM3` with the listed port:

```powershell
.venv/Scripts/python.exe -B scripts/signal_start.py --list-ports
.venv/Scripts/python.exe -B scripts/signal_start.py --port COM3 --check
.venv/Scripts/python.exe -B scripts/signal_start.py --port COM3 --probe
```

`--check` only checks local prerequisites. `--probe` must receive a FIR2 status
response with `uart_overrun: false`. If it fails, use the
[startup state table](#startup-and-recovery) before the presentation; a reset
needs firmware upload, while power loss also needs FPGA programming.
Then open the viewer, which applies its initial filter and waits for Start:

```powershell
.venv/Scripts/python.exe -B scripts/signal_start.py --port COM3
```

| Time | Action | Point to explain |
| --- | --- | --- |
| 0:00-0:40 | Introduce the board and data path. | The host supplies samples; GCC-compiled C on the five-stage CPU reads UART, filters data, updates GPIO and returns outputs. Python plots those returned values. |
| 0:40-1:30 | Choose `bypass`, `sine`, noise `300`, threshold `700`; **Apply & restart**, then **Start**. Pause and repeat with `average4`. | Bypass returns the input unchanged. Four-tap averaging smooths the noisy input. Settings change without a hardware rebuild. |
| 1:30-2:10 | Pause, choose `average8`, then **Apply & restart** and **Start**. | More averaging also introduces more delay. Applying settings restarts the fixed-seed input and filter history, so the initial input sequence is repeatable. |
| 2:10-2:50 | Pause, choose `difference`, input `step`, noise `0`; **Apply & restart**, then **Start**. | A different C filter configuration produces signed pulses at transitions and zero between them after startup. This is programmable behavior, not a fixed output waveform. |
| 2:50-3:20 | **Pause**, read the footer, and **Save snapshot**. | CPU cycles and host UART round-trip milliseconds measure different intervals. Saving records the latest received samples, chart and settings under the same output stem. |
| 3:20-5:00 | Open [Three architecture decisions](../README.md#three-architecture-decisions). | Use the measured comparisons to explain the I-cache capacity knee, traffic-versus-cycle trade-off, and offload break-even. |

A compact introduction is:

> This is a five-stage FPGA CPU running a C signal-processing application.
> The PC supplies input, but the CPU computes the returned output and maintains
> state across requests. I used controlled experiments to investigate when
> larger caches or an accelerator improve useful work, including cases where
> they do not. The project combines a working application with measurements
> that guide system-design decisions.

For the last part, the three conclusions are: "256 B captures the CRC loop's
main instruction-cache benefit"; "89% fewer FIR data transfers gives about
12% fewer cycles, and sequential access gets slower"; and "DMA helps the larger
MATVEC job, but ties the fast CPU on the smallest job." The linked studies
contain the fixed inputs, counters, costs and counterexamples behind each
statement. They are separate experiments, not changes applied during this demo.

The FIR runs in software, using the CPU's DSP-assisted multiply instructions;
this application image contains no dedicated FIR or MATVEC accelerator. The
stream is host-paced, not ADC sampling. At 100 MHz, `compute_cycles / 100` is
processing time in microseconds for the firmware's measured interval, not the
end-to-end response time. A saved viewer capture is a demonstration record;
the [independent physical output checks](fpga/board_evidence/automatic_acceptance_5c1c4c0/README.md)
are the separate correctness evidence.

If the board is unavailable, show the
[recorded input/output capture](fpga/board_evidence/automatic_acceptance_5c1c4c0/viewer/viewer-checked.png)
and its [received samples](fpga/board_evidence/automatic_acceptance_5c1c4c0/viewer/viewer-checked.csv),
and identify it as a recorded session. For an exact arithmetic example or a
question about cross-batch state, use the console sequence below after closing
the viewer.

## Try it

At the `cpu>` prompt, enter one command per line:

```text
config 2 5 1 1 1 1
data 0 4 8 12
data 16 20
status
led 0xaa
clear
config 0 10 1 -1
data 10 14 30 25
quit
```

The first configuration is a four-sample moving average: coefficients
`[1, 1, 1, 1]`, division by `2^2`, and event threshold `5`. The first batch returns
`[0, 1, 3, 6]`; the second returns `[10, 14]`, using history from the first batch.
The final configuration computes adjacent differences and returns `[10, 4, 16, -5]`.

| Command | Effect |
| --- | --- |
| `config SCALE THRESHOLD COEFF...` | Set 1–8 signed-int8 coefficients and a scale of 0–15; clear history and counters |
| `data SAMPLE...` | Process 1–32 signed-int16 samples and return signed-int32 outputs, compute cycles, event count and GPIO |
| `status` | Read coefficients, scale, threshold, counters, switches and UART-overrun status |
| `clear` | Clear sample history, counters and event LED; retain configuration and manual LEDs |
| `led VALUE` | Set GPIO bits 7–1; bit 0 belongs to threshold detection |
| `quit` | Close the client |

`y[n] = trunc_toward_zero(sum(c[k] * x[n-k]) / 2^SCALE)`; samples before the
start of the stream are zero. Coefficient 0 multiplies the newest sample. With
eight taps, `abs(sum) <= 8 * 128 * 32768 = 33,554,432`, so the accumulator fits
signed 32 bits. Counters wrap modulo `2^32`. Configuration changes restart the
stream. A CLI reconnect or status query retains history; the viewer applies its
selected configuration when it connects and therefore starts a new stream.

An event is an output **greater than or equal to** the signed threshold. LD8
lights when at least one output in the most recent batch meets that threshold,
and clears on a batch with no events. LD15–LD9 show the seven manual GPIO bits.
`status.switches` is the synchronized SW15–SW0 value. LD0–LD7 retain the board
wrapper's diagnostic functions and are not the application's event display.

## Live signal viewer

The optional desktop viewer sends a continuous, repeatable signal over the same
UART client and plots the CPU's returned outputs. It does not compute a local
replacement for the FIR output. Install its plotting dependencies once:

```powershell
.venv/Scripts/python.exe -m pip install -r scripts/signal-viewer-requirements.txt
```

With FIR2 already running and other serial clients closed:

```powershell
.venv/Scripts/python.exe -B scripts/signal_start.py --port COM5
```

After BTN C, append `--upload`. No new
bitstream or firmware build is needed if the FIFO/FIR2 application is already
installed. The viewer configures the filter when it connects, clearing existing
history and counters. It initially waits for **Start**.

If `--upload` still times out after BTN C, check the selected port and reload the
application bitstream from **Prepare the board** before uploading the firmware.
An FPGA can be configured with a different program; BTN C resets that program
but does not replace its bitstream.

- **Start / Pause / Resume:** stream 32-sample batches; pause finishes an in-flight
  batch and retains filter history. Resume continues the same input sequence.
- **Filter:** `bypass` sends input through unchanged; `average4` and `average8`
  smooth noise; `difference` computes the current minus previous sample.
- **Input / Noise / Threshold:** choose a sine or alternating step, integer noise
  amplitude from 0 to 1000, and a signed-32-bit output threshold. Pause, change
  settings, then select **Apply & restart** and **Start**. Apply resets the input
  sequence, filter history, counters and displayed samples together.
- **Save snapshot:** while paused, save the latest 512 received samples as CSV,
  the same chart as PNG, and settings/source hashes as JSON. The default stem is
  `results/signal-console/viewer`; subsequent saves replace these three files.
  Use `--output path/to/name` to choose another stem. No automatic recording or
  unbounded sample history grows in the background.

Both generated signals have amplitude 1000 counts; the sine period is 128
samples and the step changes sign every 64 samples. Uniform integer noise is
added using seed 1 by default (`--seed` changes it). The horizontal axis is the
sample index, not a hardware sampling clock. The host requests roughly one batch
per 125 ms, but serial transfer and GUI scheduling can make the interval longer.
This is a host-paced demonstration, not a fixed-rate sensor acquisition system.

Grey dashed input and blue solid output use the same integer-amplitude axis.
The threshold is dotted; an out-of-range threshold is labeled in the subtitle
instead of stretching the scale until the signal becomes flat. FIR delay is
shown as returned, without shifting either trace to hide it. The footer shows
CPU cycles per batch separately from host-measured UART round-trip milliseconds.
Switches and UART-overrun status are polled every eight batches.

To capture a finite session without opening a window:

```powershell
.venv/Scripts/python.exe -B scripts/signal_viewer.py --port COM5 --batches 16 --preset average8
```

This captures 512 samples and writes the same snapshot files. A longer session
still saves only its latest 512 samples; JSON records both the total and the saved
range. `captured` describes an application capture, not an independent correctness
test. Transport errors stop streaming without replaying a possibly processed
command. Close the viewer, check the board, then reconnect; reset and upload again
if the UART-overrun flag is set.

Viewer tests use a separate FIR oracle and mock serial client. Run the complete
Python suite, including local Tk controls:

```powershell
.venv/Scripts/python.exe -B scripts/python_tests.py --gui
```

For a repeatable physical viewer check, first run the firmware simulation above,
close the viewer, then press BTN C and run:

```powershell
.venv/Scripts/python.exe -B scripts/signal_console_check.py --port COM3 --viewer
powershell -ExecutionPolicy Bypass -File scripts/results-overview.ps1
```

This uploads the checked firmware, compares 8,704 outputs with the independent
FIR calculation, covers four presets on both input patterns, and includes a
4,096-sample sustained session. It writes `viewer-validation.json` and a
512-sample `viewer-checked.csv/.png/.json` under `results/signal-console/`.
Each run replaces the same files. The common overview separates the correctness
result from ordinary `captured` snapshots, verifies linked-file hashes and marks
changed source inputs stale. Historical captures remain historical; they are not
relabelled as current tests. Python must include Tk for the desktop window;
`--batches` uses a non-interactive renderer.

## Transport and recovery

UART uses 115200 baud, 8 data bits, no parity and one stop bit. The PC first sends
the opening `0x7e` delimiter and waits for `0x06`. It then sends up to 32 wire
bytes at once, waiting for one ACK per burst. The firmware ACKs every delimiter
and every 32 bytes since the previous ACK; a closing delimiter at the end of a
full burst produces one ACK, not two. After that ACK, the PC reads the complete
response before starting another command. Escaped bytes count as transmitted
wire bytes, so even the maximum-escaping case stays within the burst limit.

An ACK means the firmware has consumed the preceding burst, freeing FIFO space.
The next burst therefore fits in the 64-byte FIFO even if the CPU briefly stalls.
This bounds incoming data without relying on the PC to sleep for precise byte
intervals. The boot loader retains its existing packet protocol.

Frames start and end with `0x7e`. Within a frame, `0x7e` and `0x7d` are encoded as
`0x7d` followed by the byte XOR `0x20`. Request bytes are sequence, ASCII command,
payload length, payload, then a little-endian CRC-16 with polynomial `0x1021` and
initial value `0xffff`. Response bytes insert a status byte between command and
length; the CRC covers every unescaped byte before the CRC. The status payload
reports protocol version 2. Status 0 means
success, 1 malformed frame/CRC, 2 invalid arguments, and 3 unknown command.

Rejected packets leave filter state unchanged. A delimiter terminates a partial
packet, allowing the following complete packet to run. On reconnect the client
flushes a partial frame and queries status. It does not automatically replay an
interrupted data command: the CPU may already have processed it. Use `clear`
and resend the intended stream when delivery is uncertain. A sticky UART-overrun
flag requires board reset and firmware upload.

After programming or pressing BTN C, the existing checker can also run a
physical session (close the interactive client first):

```powershell
.venv/Scripts/python.exe -B scripts/signal_console_check.py --port COM5 --session initial
```

Run the simulation first so the checker can verify firmware/source identity.
The physical session replays the directed cases, checks 200 consecutive batches
of 32 samples against the Python calculation, and leaves the interactive LED
example running. Results go to `results/signal-console/board-burst/`. After a
physical reset, repeat with `--session after-reset`; `--expected-switches 1` can
also verify an operator-set switch value. Old dated board records refer to their
recorded source revision, while this command tests the current sources.

`compute_cycles` covers sample decoding, history updates, multiply/add/divide,
and event counting, excluding UART reception, CRC parsing and response sending.
`round_trip_ms` covers a complete PC command and response, including ACK pacing
and host scheduling. At 100 MHz, compute time in microseconds is cycles divided
by 100. Simulation accelerates the UART baud to keep tests short; use the PC
measurement for actual communication latency.

## Files

The implementation is [signal_console.c](../firmware/c/signal_console.c). The
[PC client](../scripts/signal_console.py) handles transport and presentation;
[the build and checker](../scripts/signal_console_check.py) supplies independent
expected values to the [UART testbench](../tb/reference/tb_signal_console.v).
Generated firmware stays in `build/signal-console/`, simulation evidence in
`results/signal-console/`, and FPGA implementation in
`build/vivado/signal_console/`. The implementation summary goes in `results/timing/`
so the main `results/RESULTS.md` index includes it. Repeating a run replaces the
same files.
