# Basys3 Bring-Up Checklist

Use this checklist before making any board-run claim.

- Confirm the board is a Digilent Basys3 with part `xc7a35tcpg236-1`.
- Review `basys3.xdc` against the current Digilent Basys3 master XDC.
- Run `scripts\vivado-detect.ps1` and record the Vivado version.
- Run `scripts\vivado-basys3-build.ps1 -SynthOnly`.
- Build the low-frequency full-feature profile with `-Top RISCVCPU_basys3_full_lowfreq_top -OutDir build\vivado\basys3_full_lowfreq` when that target is under review.
- Run Vivado implementation before making any timing statement.
- Claim timing closure only if the implementation timing summary passes.
- Generate a bitstream only after constraints and timing reports are reviewed.
- Program the board and record reset, UART TX/RX, switch, LED, and GPIO observations.
- Record each physical claim with its evidence level, exact target, bitstream
  identity, transcript bytes/hash, operator observations, and non-claims.

For `RISCVCPU_basys3_full_lowfreq_top`, confirm the clock report contains the
100 MHz `sys_clk_pin` and MMCM-generated 6.25 MHz `mmcm_soc_clk`, with zero
`no_clock` and `unconstrained_internal_endpoints` checks. Its timing and
physical status are independent of both the reduced board-smoke target and the
direct-100-MHz default-feature SoC target.

Bitstream generation does not equal board validation. The current
direct-100-MHz source revision at commit `d7f1afe` has a source-matched,
timing-closed bitstream, a five-profile implementation sweep, and a scoped
2026-07-30 physical pass. Later source revisions do not inherit that status.
The
direct-100-MHz, low-frequency, and reduced board-smoke targets retain
independent physical status.
