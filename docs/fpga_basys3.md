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
  -SummaryPath results/vivado-basys3-build-summary.json `
  -LogPath results/vivado-basys3-build.log `
  -Bitstream

powershell -ExecutionPolicy Bypass -File scripts/vivado-basys3-robustness.ps1
```

The wrapper records synthesis, implementation, timing, utilization, and
bitstream status. `timing_closure_status=met` requires nonnegative post-route
setup slack and zero total negative setup slack. Hold values are also recorded.

Implementation also writes `post_route_hierarchy.rpt` with per-module resource
usage and `post_route_top50_paths.rpt` with the 50 worst setup paths to distinct
endpoints. Use these alongside the timing summary when comparing RTL revisions.
The [timing and resource baseline](timing_baseline.md) records the measured
starting point for optimization.

The current default implementation at `fd52074` meets 100 MHz: WNS
`+0.021 ns`, WHS `+0.034 ns`, zero TNS/THS, 9,359 LUTs, 7,176 FFs, two BRAM
tiles and no DSP blocks. Its source identities and routed reports are in the
[implementation package](../release/implementation/basys3/README.md). No
bitstream or board run has been recorded for this revision.

The latest board-validated default build, `9d46f04`, completed implementation
and bitstream generation on 2026-10-02: WNS `+0.323 ns`, WHS `+0.040 ns`, zero
TNS/THS, 9,476 LUTs, 7,179 FFs, two BRAM tiles and no DSP blocks.

The earlier 2026-09-30 build at `849270b` completed implementation and bitstream
generation in Vivado 2026.1 with post-route WNS `+0.399 ns`, TNS `0 ns`,
WHS `+0.018 ns`, and THS `0 ns`. It used 9,654 LUTs, 7,166 FFs,
2 BRAM tiles, and no DSP blocks. Its bitstream SHA-256 is
`b7619a54318e0cc3dab0145b6d0e16f106b6eb3d18f58ed81ac998bad7449b15`.

The earlier robustness run at `d7f1afe` used five
documented implementation-directive profiles sequentially, requires complete
internal and board-I/O constraint coverage, and requires every profile to meet
setup and hold timing with a release-approved DRC report. The summary also
records an optional `+0.200 ns` minimum-margin target without redefining timing
closure when that target is missed. All five profiles met timing, with WNS
from `+0.079 ns` to `+0.318 ns`; the optional margin target was not met.

Offline physical-flow preflight commands:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/xsdb-basys3-program.ps1 -DryRun
powershell -ExecutionPolicy Bypass -File scripts/basys3-board-demo.ps1 `
  -Target FullDirect100 -Demo Showcase -Port <COMx> -DryRun
```

The same host command accepts `Interactive`, `HardwareValidation`, and `Matvec`.
Build the MATVEC firmware using its [measurement guide](matvec-benchmark.md#physical-board-measurements) first. `-DryRun`
validates canonical metadata and packet fixtures offline. Remove `-DryRun`
only when ready to program the board or send the selected UART packet.

## Physical validation record

The [current-input automatic acceptance](./fpga/board_evidence/automatic_acceptance_5c1c4c0/README.md)
uses the `9d46f04` default SoC and `5c1c4c0` FIR application; their hardware/build
inputs match the reviewed source. It checks
JTAG configuration, Showcase/Interactive/HardwareValidation UART behavior,
90 MATVEC cases twice, FIR numerical outputs and the live viewer. The repeat
uses JTAG reconfiguration and firmware reload, not an operator-pressed BTN C.
No new visual LED observation is claimed.

The source-matched `849270b` bitstream passed the physical suite on
2026-09-30. It covers XSDB JTAG configuration, Showcase UART TX,
Interactive UART RX, RV32M/timer-interrupt/DMA checks, and 90 MATVEC
measurements. MATVEC was repeated after an operator-pressed BTN C reset:
all 2,418 output values passed in each run, and all 90 cycle counts matched.

XSDB programming/configured state and UART transcripts are machine-captured;
LED/reset observations are operator-reported. The durable summary, transcript
hashes, and test list are in [Basys3 direct-100-MHz board
evidence](./fpga/board_evidence/basys3_full_direct_100mhz_2026-09-30/README.md).
The record identifies the tested synthesis-input fingerprint and source
revision. New RTL revisions need their own implementation and board results.
No script in the normal regression opens a serial port or programs the board.

A new session uses separate output directories for each programming operation
and UART capture. After Showcase, Interactive, HardwareValidation, Matvec and
a MatvecReset repeat pass, `scripts/basys3-board-report.ps1` publishes the
captures, cycle CSVs, build identity and operator observations to a new dated
directory. It does not overwrite an earlier session. Select the validated
summary through `recorded_physical_evidence` in the board profile.
