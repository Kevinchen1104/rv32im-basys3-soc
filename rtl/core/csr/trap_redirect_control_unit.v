`timescale 1ns / 1ps

// Module: trap_redirect_control_unit
// Role: Factor interrupt eligibility, accepted interrupt entry, and frontend redirect control.
// Interface: Execute-stage validity/control metadata, trap/mret decisions, and redirect outputs.
// Key behavior: Keeps exception and mret priority out of the interrupt eligibility cone while preserving accepted-interrupt semantics.

module trap_redirect_control_unit (
    input reset,
    input instruction_valid,
    input machine_interrupt_pending,
    input control_redirect_pending,
    input control_interrupt_deferred,
    input instruction_is_control,
    input instruction_is_m_extension,
    input dcache_pipeline_stall,
    input exception_taken,
    input exception_pending,
    input mret_taken,

    output interrupt_eligible,
    output interrupt_taken,
    output redirect_taken
);

    // Eligibility is independent of memory backpressure. The accept signal
    // below is the sole boundary that applies the D-cache stall guard.
    assign interrupt_eligible =
        !reset &&
        instruction_valid &&
        machine_interrupt_pending &&
        !control_redirect_pending &&
        (!instruction_is_control || control_interrupt_deferred) &&
        !instruction_is_m_extension;

    assign interrupt_taken =
        interrupt_eligible &&
        !dcache_pipeline_stall &&
        !exception_taken &&
        !mret_taken;

    // This is a redirect request, not proof that the PC changes this cycle.
    // pipeline_control_unit applies it only after D-cache backpressure clears.
    assign redirect_taken =
        exception_pending ||
        mret_taken ||
        interrupt_eligible ||
        control_redirect_pending;

endmodule
