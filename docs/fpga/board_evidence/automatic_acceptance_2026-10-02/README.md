# Automatic board acceptance, 2026-10-02

Both the default full SoC and default FIR application were rebuilt at 100 MHz
and explicitly loaded into the same Basys3 through volatile JTAG. No Flash
write was performed. This record does not claim a manual LED observation or
BTN C press; the repeat runs use JTAG reconfiguration and firmware reload.

| Check | Result |
| --- | --- |
| Default Showcase / Interactive / HardwareValidation | UART, RV32M, timer interrupt, Scratchpad and DMA checks passed |
| Default MATVEC | 90 cases / 2,418 outputs passed, repeated after JTAG reload |
| Default FIR | 42 commands / 6,608 numerical outputs passed |
| Equal-data-capacity candidates | 128 B direct and 64 B + four victims each passed another 6,608-output reload session |
| Physical viewer | 10 sessions / 8,704 outputs passed, including cross-batch history and threshold counters |
| Startup | Non-mutating preflight and status probe passed |

The [complete six-profile comparison](../../../dcache-study.md) is separate
from this acceptance run. Initial candidate sessions and their routed reports
are under [capacity/](../../../benchmarks/dcache/capacity/).

The original operator-confirmed LED/button record is retained in the dated
[2026-09-30 directory](../basys3_full_direct_100mhz_2026-09-30/README.md).
It describes that earlier image, not a visual observation of this run.

## Inspect and reproduce

- `default-build.json` and `application-build.json` identify the images.
- `default/` contains programming records, UART transcripts and MATVEC CSVs.
- `fir/` contains directed/stress responses and the programming hash chain.
- `viewer/` contains the physical trace, figure, settings and ten-session check.
- `acceptance.json` records the ordered execution steps.
- `publication.json` keeps original hashes; `artifacts.json` hashes normalized
  published copies with checkout/user paths removed. Embedded run hashes still
  refer to original files.

XSDB logs retain its temporary-file cleanup messages. Configuration completed
with exit code zero and the following numerical/communication checks passed;
those messages are not routed DRC warnings or failed UART checks.

Reproduce using the [board guide](../../../fpga_basys3.md) and
[application guide](../../../signal-console.md#build-and-test), then publish
only after checking the recorded build, packet and programming identities.
The normal `scripts/check.ps1 -Mode Full` workflow does not access hardware.
