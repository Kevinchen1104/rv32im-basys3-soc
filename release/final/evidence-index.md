# Evidence Index

- evidence/check-summary.json: portable regression orchestration
- evidence/regression-summary.json: per-test simulation results
- evidence/regression-evidence-summary.json: regression evidence checks
- evidence/test-catalog-summary.json: current catalog counts
- evidence/documentation-coverage-summary.json: source-header coverage
- evidence/docs-link-audit-summary.json: documentation link audit
- evidence/claim-audit-summary.json: bounded-claim audit
- evidence/verilator-lint-summary.json: lint result
- evidence/synth-smoke-summary.json: synthesis smoke result
- evidence/formal-smoke-summary.json: bounded CPU properties
- evidence/formal-matvec-smoke-summary.json: bounded MATVEC Scratchpad properties
- evidence/vivado-basys3-build-summary.json: source-matched Vivado result when current
- evidence/vivado-basys3-robustness-summary.json: five-profile implementation-directive sweep
- evidence/physical/summary.json: scoped Basys3 direct-100-MHz physical evidence
- evidence/physical/xsdb-programming-summary.json: sanitized machine-captured JTAG programming record
- evidence/physical/*-transcript.txt: exact machine-captured UART transcripts
- [Basys3 FPGA evidence](../fpga/basys3/status.json)
- [Generic FPGA package status](../fpga/generic_uart_boot_runtime/status.json)

Bitstream size and SHA-256 are recorded in status metadata, but the ignored binary
is intentionally excluded. Physical programming identity was not read back from the FPGA.
