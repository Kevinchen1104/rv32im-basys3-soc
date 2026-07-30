`timescale 1ns / 1ps

// Module: pipeline_control_unit
// Role: Central hold/advance/flush policy for the CPU pipeline.
// Interface: D-cache, execute-busy, I-cache, redirect, and load-use inputs plus per-stage control outputs.
// Key behavior: Holds all stages for data-memory stalls and otherwise lets redirects bubble decode ahead of multicycle execute waits, fetch stalls, and decode hazards.

module pipeline_control_unit (
    input dcache_pipeline_stall,
    input redirect_taken,
    input icache_pipeline_stall,
    input load_use_hazard,
    input execute_busy_stall,

    output if_hold,
    output if_redirect,
    output if_advance,

    output id_hold,
    output id_bubble,
    output id_advance,

    output ex_hold,
    output ex_advance
);

    // D-cache stalls freeze all younger stages first; redirects are applied
    // only when data-memory side effects are no longer being held in place.
    assign if_hold =
        dcache_pipeline_stall ||
        (!redirect_taken && (execute_busy_stall || icache_pipeline_stall || load_use_hazard));
    assign if_redirect = !dcache_pipeline_stall && redirect_taken;
    assign if_advance =
        !dcache_pipeline_stall &&
        !redirect_taken &&
        !execute_busy_stall &&
        !icache_pipeline_stall &&
        !load_use_hazard;

    assign id_hold =
        dcache_pipeline_stall ||
        (!redirect_taken && execute_busy_stall);
    assign id_bubble =
        !dcache_pipeline_stall &&
        (
            redirect_taken ||
            (!execute_busy_stall && (icache_pipeline_stall || load_use_hazard))
        );
    assign id_advance =
        !dcache_pipeline_stall &&
        !execute_busy_stall &&
        !icache_pipeline_stall &&
        !redirect_taken &&
        !load_use_hazard;

    assign ex_hold = dcache_pipeline_stall;
    assign ex_advance = !dcache_pipeline_stall;

endmodule
