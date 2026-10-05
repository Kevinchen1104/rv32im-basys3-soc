# Basys3 FIR burst transport measurement

Replacing per-byte ACKs with bounded 32-byte bursts reduced the measured
32-sample command round trip from about 1,148 ms to 61.7 ms, approximately
18.6 times faster. The application still runs on the CPU at 100 MHz; UART
baud remains 115200. A 64-byte receive FIFO supports the new transfer protocol.

## Before and after

The same PC, board, baud rate, coefficients and sample bytes were used for
directed case 14: 32 signed samples, eight taps. Request wire bytes and numerical
outputs match the [per-byte baseline](../signal_console_2026-10-01/README.md).
The firmware/client pair changed from FIR1 to FIR2.

| Measurement | Per-byte ACK | 32-byte bursts |
| --- | ---: | ---: |
| Initial session round trip | 1,147.932 ms | 61.587 ms |
| After-reset round trip | 1,148.721 ms | 61.807 ms |
| CPU processing, both sessions | 10,980 cycles / 109.80 us | 10,054 cycles / 100.54 us |
| LUT | 6,694 | 6,733 |
| Flip-flops | 5,269 | 5,287 |
| BRAM / DSP | 2 / 4 | 2 / 4 |

The gain is primarily in communication, not an 18.6-times faster FIR algorithm.
The compiled firmware also has a small processing-cycle difference; both values
are reported separately. The new code occupies 1,888 of 4,096 instruction bytes,
32 bytes more than FIR1, with unchanged 380-byte BSS and 1,156-byte stack space.

Each session additionally ran 200 consecutive, varied 32-sample batches with
eight taps. Their median round trips were 63.763 and 63.836 ms; observed ranges
were 56.030–77.004 and 60.600–78.970 ms. These are host-observed latency
measurements, including USB scheduling and ACKs, not real-time deadlines.
The UART response and host overhead still dominate the roughly 0.1-ms CPU work.

[comparison.json](comparison.json) records the calculations. The transfer
change saves host/device handshakes while preserving bounded input: the PC
waits for an ACK before every next burst, and the firmware acknowledges consumed
bytes. See the [protocol and commands](../../../signal-console.md).

## Physical checks

| Session | Directed commands / outputs | Expected rejections | Stress batches / outputs | Example outputs | Switches |
| --- | ---: | ---: | ---: | ---: | --- |
| Initial | 42 / 202 | 13 | 200 / 6,400 | 6 | `0x0001` |
| After BTN C | 42 / 202 | 13 | 200 / 6,400 | 6 | `0x0000` |

Both sessions passed: 13,216 numerical outputs and 26 expected rejections in
total. The stress inputs include signed extremes, random values and frequent
frame-escape bytes. All outputs and threshold counts matched a separate Python
calculation; counters matched the submitted sample count, with no UART overrun.
The public client produced `[0, 1, 3, 6]`, then `[10, 14]`, retaining history.

Kevin confirmed LD15–LD8 as `10101011`, switched SW0 off, and pressed BTN C.
The second session re-uploaded firmware without another JTAG programming step.
The first status after each upload confirmed default configuration and cleared
counters; the switch read changed from one to zero. Raw directed wire captures,
stress inputs/outputs, counters and timings are in [initial.json](initial.json)
and [after-reset.json](after-reset.json).

## Build identity and timing

Source revision: `331b5c4`. [identity.json](identity.json) preserves source hashes,
GCC/Vivado identities, application simulation and implementation summaries,
and the bitstream digest. Hardware and application inputs matched these hashes
before programming and after both sessions. The build began before the source
commit, so its original dirty-tree metadata is retained; its input files match
the committed revision.

The fast CPU profile met 100 MHz setup and hold: WNS +0.149 ns, WHS +0.017 ns,
zero total negative slack. Routed DRC reported no violations. Raw reports:
[timing](post_route_timing_summary.rpt), [utilization](post_route_utilization.rpt),
and [DRC](post_route_drc.rpt).

XSDB selected the one detected xc7a35t target, programmed once and confirmed
configured state; see [programming.json](programming.json) and
[programming.txt](programming.txt). [artifacts.json](artifacts.json) contains
file hashes and the operator's reset confirmation.

## Repeat

Build and program the FIR2 image using the [application guide](../../../signal-console.md).
After programming or pressing BTN C, with other serial clients closed:

```powershell
.venv/Scripts/python.exe -B scripts/signal_console_check.py --port COM3 --session initial
```

Confirm LEDs, change SW0, press BTN C, then run `--session after-reset`.
Use `--expected-switches 0` or `1` to match the selected setting. Fresh results
replace `results/signal-console/board-burst/`; this dated record stays unchanged.
