# Architecture study data

Read [the analysis and reproduction method](../../architecture-evaluation.md)
before comparing rows.

- `measurements.csv`: 380 executions, including memory backend, workload,
  profile, optimization, cycles, retirement, raw/exclusive stall causes and
  image hashes.
- `run-metadata.json`: source hashes, tool versions, profiles, original
  evidence hashes and overlap histograms. `nonzero_masks` stores nonzero bins
  of each 64-entry histogram; omitted masks have count zero.
- `implementation.csv`: five routed SoC configurations, with resource counts,
  timing and DRC-release status kept separate.
- `implementation-metadata.json`: hardware/report-input identities and hashes
  for the retained reports under `implementation/<profile>/`.

Simulation source-text hashes normalize CRLF to LF. Hardware-input and report
hashes use raw file bytes. The complete run directories remain under ignored
`results/architecture/`; rerunning a named matrix overwrites its own stable
context. These committed files are reviewed measurement snapshots, identified
by source inputs rather than assumed current merely because they are present.
Retained report copies use LF endings and replace the local checkout/host name;
their metadata records both original and derivative hashes. The directory's
Git attributes preserve the recorded snapshot bytes across platforms.
