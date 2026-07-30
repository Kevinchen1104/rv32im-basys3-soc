# Bounded Formal Smoke Checks

The `formal/` directory contains eight deliberately narrow bounded model
checking harnesses. Each `.sby` file defines the bound and source list for its
matching SystemVerilog harness.

| Harness | BMC depth | Checked property scope |
| --- | ---: | --- |
| `x0_invariant` | 12 | Under the integrated CPU's default NOP-filled instruction-memory harness, requires retirement within the bounded window and checks that the retire trace never reports an architectural write to `x0` after reset. |
| `forwarding_alignment_equivalence` | 1 | The dedicated two-bit alignment forwarding path matches the low bits of full operand forwarding, including EX/MEM priority and store-data forwarding. |
| `alu_result_classification` | 1 | Arithmetic and non-arithmetic instruction classes select results consistent with the reference ALU expressions. |
| `registered_branch_miss_event` | 8 | The registered branch-miss event is captured for one cycle and accumulated exactly by the performance counter. |
| `branch_predictor_payload_capture` | 6 | Predictor update payload and validity registers follow their inputs across reset and pending updates; invalid updates leave BHT/BTB state stable. |
| `machine_timer_pending` | 6 | Reset values and the registered timer-interrupt pending relation follow the previous `mtime` and `mtimecmp` state. |
| `trap_metadata_commit` | 7 | Trap metadata pending/commit recurrence, reset behavior, direct-write priority, and back-to-back capture behavior remain consistent. |
| `matvec_scratchpad_formal` | 12 | MATVEC Scratchpad reset, accepted start, busy-time operand isolation, one-row progress, completion, and visible control/readback behavior. |

Run the seven CPU, pipeline, predictor, timer, and CSR checks with:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/formal-smoke.ps1
```

Run the accelerator check separately with:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/formal-matvec-smoke.ps1
```

The scripts use SymbiYosys when available and may use the repository's local
fallback runner where platform policy prevents launching `sby` directly.

These are bounded smoke proofs, not complete CPU, cache, privileged-architecture,
or accelerator formal verification. They do not establish unbounded liveness,
full ISA compliance, exhaustive pipeline correctness, or complete arithmetic
correctness for every accelerator configuration.
