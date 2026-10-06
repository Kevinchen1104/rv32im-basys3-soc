# Data-cache study evidence

Start with [the design study](../../dcache-study.md), not the JSON files.

The complete six-profile study is in [capacity/](capacity/): 300 executions,
six routed implementations, and their source-matched physical sessions.
Check its bounded publication with
`.venv/Scripts/python.exe -B scripts/publish_cache_study.py --check` from the repository root.
The [optimization/](optimization/) directory retains the successive
four-entry datapath refinements.

The files directly in this directory are the **earlier four-profile,
200-execution snapshot** described below; they are not the current six-profile
matrix. Keeping them separate preserves the before/after optimization evidence.

| File / directory | Use |
| --- | --- |
| measurements.csv | 200 cycle measurements: 136 base cases and 64 added-latency cases |
| latency-0.json, latency-4.json, latency-12.json | Source/tool identity, parameters, counters, overlap histograms, artifact hashes |
| implementation/ | Routed 100 MHz timing, resources, DRC and critical paths for the paired FPGA configurations |
| board/ | Firmware/bitstream identity, programming result, directed responses and all 200 stress batches per session |
| verification.json | Compact 31-stage gate, 168 RTL, 82 Python and four UART-simulation records |
| publication.json | Original-run and published-copy hashes; latency-accounting validation |

These are evidence snapshots, not fresh PASS results for arbitrary future
changes. Each records its own source and image identity. Published text uses
UTF-8/LF and omits the local checkout path; embedded run hashes identify
original artifacts, while publication.json identifies normalized copies.
No bitstreams, waveforms or synthesis checkpoints are added to the repository.

The baseline programming log retains an XSDB temporary-file cleanup warning.
JTAG configuration completed with exit code zero; the subsequent firmware
session independently checked all 6,608 outputs. The warning is not hidden or
treated as a functional failure.

Study commands reproduce measurements in fixed ignored results/ and build/
contexts. Repeating a context replaces its products. The published snapshot
is updated only after review.
