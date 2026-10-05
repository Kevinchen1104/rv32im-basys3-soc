# Physical I-cache comparison

See [the I-cache study](../../../icache-study.md#physical-fir-comparison).
Both images used the same FIR2 packet and the same 42 directed commands,
6,400 stress samples and six example outputs. Raw response records retain
actual CPU counts and transport latencies separately.

The median 32-sample, eight-tap processing count is 10,054 cycles with the
original 64 B cache and 9,372 with the banked 1 KiB cache. Both sessions
passed all 6,608 output checks. JTAG reconfiguration and firmware reload
started each session; no manual button or visual LED observation is claimed.

Original/published hashes are in the adjacent
[memory-study publication record](../../dcache/publication.json). These
records precede the D-cache candidate and retain their historical sources.
