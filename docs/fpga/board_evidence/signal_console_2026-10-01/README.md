# Basys3 interactive FIR board test

On 1 October 2026, the fast CPU profile ran the configurable FIR application on
Basys3 at 100 MHz. Both physical UART sessions passed, including firmware upload,
filter configuration, history across batches, malformed requests and recovery.
The operator confirmed the LED pattern, changed SW0, and pressed BTN C between
sessions. The second session uploaded firmware again without reprogramming the FPGA.

## Results

| Session | Test commands | Checked outputs | Expected rejections | Interactive client commands | Client outputs | Switches |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Initial | 42 | 202 | 13 | 6 | 6 | `0x0000` |
| After physical reset | 42 | 202 | 13 | 6 | 6 | `0x0001` |

Together these sessions checked 96 command responses and 416 numerical outputs.
The first status after each boot matched the default configuration with zero
counters; each subsequent status reported no UART overrun. Rejected requests
preserved the configuration and history. The public PC client also recovered
the session and produced `[0, 1, 3, 6]`, then `[10, 14]` across two input batches.

LD15 through LD8 displayed `10101011`, confirmed by Kevin before reset. The
post-reset switch read independently confirmed SW0 changing from off to on.
Each captured request and response includes its wire bytes, decoded result and
comparison outcome in [initial.json](initial.json) and [after-reset.json](after-reset.json).

## Computation and communication

For the same 32-sample, eight-tap case, both board sessions measured 10,980 CPU
cycles, or 109.80 microseconds at 100 MHz. PC command round trips were 1,147.932
and 1,148.721 milliseconds. The round trip includes UART transfer, per-byte ACK
pacing and host scheduling; compute cycles cover the firmware's processing loop.
These measurements show that communication dominates this interactive setup.
Improving sustained input rate should therefore start with the transfer path.

## Build and programming identity

[identity.json](identity.json) preserves the application and implementation
summaries, compiler identity, source hashes and bitstream SHA-256. All hardware
and application inputs matched their recorded hashes before this run. The
implementation met 100 MHz timing: WNS +0.100 ns and WHS +0.036 ns.

XSDB programmed the one detected xc7a35t target and confirmed the configured
state; see [programming.json](programming.json) and [programming.txt](programming.txt).
The log also records a Windows permission warning while deleting an XSDB
temporary file. Programming completed and both subsequent UART sessions passed.
The bitstream digest identifies the host file sent to the board; configuration
confirmation and application responses provide the hardware checks.

The original build summary retains its dirty-tree and verification-input-change
fields. Its hardware input hashes match this run; later firmware/client edits
during that build did not change the hardware input set. The default MATVEC
profile and its earlier physical records remain separate.

## Repeat the session

Follow [the application guide](../../../signal-console.md) to build and program
the fast CPU image. From the repository root, after programming or pressing BTN C:

```powershell
.venv/Scripts/python.exe -B docs/fpga/board_evidence/signal_console_2026-10-01/check_session.py --port COM3 --session initial
```

Replace COM3 with the board's port. Keep switches unchanged during a session.
Confirm the LED pattern, flip SW0, then press and release BTN C. If the initial
switch value was zero, repeat with:

```powershell
.venv/Scripts/python.exe -B docs/fpga/board_evidence/signal_console_2026-10-01/check_session.py --port COM3 --session after-reset --expected-switches 1
```

The checker reuses the simulation test plan up to its reset marker, compares
results against the independent FIR calculation, and exercises the public client.
Fresh captures go to `results/signal-console/board/`; this dated record is unchanged.
The saved files are listed with hashes in [artifacts.json](artifacts.json).
