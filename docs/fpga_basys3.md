# Basys3 FPGA flow

The Basys3 profile targets `xc7a35tcpg236-1` with a 100-MHz board clock.

| Top | Purpose |
| --- | --- |
| `RISCVCPU_basys3_top` | Canonical default-feature SoC at direct 100 MHz |
| `RISCVCPU_basys3_full_lowfreq_top` | Default-feature SoC using a 6.25-MHz generated clock |
| `RISCVCPU_basys3_board_smoke_top` | Reduced straight-line board smoke profile; control redirects and CSR traps are disabled |

The profile, XDC, and Vivado batch Tcl are under `fpga/boards/basys3/` and
`fpga/vivado/`. Build commands:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/vivado-detect.ps1
powershell -ExecutionPolicy Bypass -File scripts/vivado-basys3-build.ps1 `
  -Top RISCVCPU_basys3_top `
  -OutDir build/vivado/basys3_full_100mhz_canonical `
  -SummaryPath wave/vivado-basys3-build-summary.json `
  -LogPath wave/vivado-basys3-build.log `
  -Bitstream

powershell -ExecutionPolicy Bypass -File scripts/vivado-basys3-robustness.ps1
```

The wrapper records synthesis, implementation, timing, utilization, and
bitstream status. `timing_closure_status=met` requires nonnegative post-route
setup slack and zero total negative setup slack. Hold values are also recorded.

The current canonical build at `d7f1afe` completed implementation and
bitstream generation in Vivado 2026.1 with post-route WNS `+0.318 ns`, TNS
`0 ns`, WHS `+0.027 ns`, and THS `0 ns`. It used 12,578 LUTs, 7,148 FFs,
2 BRAM tiles, and no DSP blocks. Its bitstream SHA-256 is
`d0243a04f7e79565ffa7ef8615e35088847311484fdea0c6ea271eb811564a70`.
The robustness script ran five
documented implementation-directive profiles sequentially, requires complete
internal and board-I/O constraint coverage, and requires every profile to meet
setup and hold timing with a release-approved DRC report. The summary also
records an optional `+0.200 ns` minimum-margin target without redefining timing
closure when that target is missed. All five profiles met timing, with WNS
from `+0.079 ns` to `+0.318 ns`; the optional margin target was not met.
This is not a random-seed or exhaustive implementation study.

Offline physical-flow preflight commands:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/xsdb-basys3-program.ps1 -DryRun
powershell -ExecutionPolicy Bypass -File scripts/basys3-board-demo.ps1 `
  -Target FullDirect100 -Demo Showcase -Port <COMx> -DryRun
```

The same host command accepts `Interactive` and `HardwareValidation`. `-DryRun`
validates canonical metadata and packet fixtures but does not start XSDB, open a
hardware session, enumerate or open the serial port, send data, or claim a
physical transcript pass.

## Physical boundary

The current `d7f1afe` bitstream passed scoped physical validation dated
2026-07-30. It covers XSDB JTAG configuration, three bounded packet-boot/UART
cases, recorded accelerator and interrupt checks, and operator-observed
LED/reset behavior.

Evidence levels are intentionally separate: XSDB programming/configured state
and UART transcripts are machine-captured, while LED/reset observations are
operator-reported. There was no FPGA readback or hashing of the configured
bitstream. The durable summary, transcript hashes, exact scope, and non-claims
are in [Basys3 direct-100-MHz board
evidence](./fpga/board_evidence/basys3_full_direct_100mhz_2026-07-30/README.md).
The scope is source-matched to the recorded synthesis-input fingerprint and
does not transfer to later RTL revisions.
No script in the normal regression opens a serial port or programs the board.
