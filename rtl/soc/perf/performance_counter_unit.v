`timescale 1ns / 1ps

// Module: performance_counter_unit
// Role: Event counter block for CPU bring-up and observability.
// Interface: Clock/reset, one-cycle event inputs, MATVEC busy level, and 32-bit counter outputs.
// Key behavior: Counts cycles, retired instructions, misses, stalls, and MATVEC events without changing their meaning.

module performance_counter_unit (
    input clock,
    input reset,

    input retire_event,
    input branch_mispredict_event,
    input icache_miss_event,
    input dcache_miss_event,
    input stall_event,

    input matvec_start_accepted_event,
    input matvec_done_rise_event,
    input matvec_busy,

    output reg [31:0] cycle_count,
    output reg [31:0] retired_count,
    output reg [31:0] branch_miss_count,
    output reg [31:0] icache_miss_count,
    output reg [31:0] dcache_miss_count,
    output reg [31:0] stall_cycle_count,

    output reg [31:0] matvec_start_count,
    output reg [31:0] matvec_done_count,
    output reg [31:0] matvec_busy_cycle_count
);

    // The core supplies an already-registered, one-cycle branch-miss event.
    // Keep a mirror for assertion visibility; the counter consumes the input
    // directly so its externally visible timing remains one cycle after the
    // accepted branch resolution.
    reg branch_mispredict_event_capture;

    always @(posedge clock) begin
        if (reset) begin
            branch_mispredict_event_capture <= 1'b0;
            cycle_count <= 32'd0;
            retired_count <= 32'd0;
            branch_miss_count <= 32'd0;
            icache_miss_count <= 32'd0;
            dcache_miss_count <= 32'd0;
            stall_cycle_count <= 32'd0;
            matvec_start_count <= 32'd0;
            matvec_done_count <= 32'd0;
            matvec_busy_cycle_count <= 32'd0;
        end else begin
            branch_mispredict_event_capture <= branch_mispredict_event;
            cycle_count <= cycle_count + 32'd1;

            if (retire_event) begin
                retired_count <= retired_count + 32'd1;
            end
            if (branch_mispredict_event) begin
                branch_miss_count <= branch_miss_count + 32'd1;
            end
            if (icache_miss_event) begin
                icache_miss_count <= icache_miss_count + 32'd1;
            end
            if (dcache_miss_event) begin
                dcache_miss_count <= dcache_miss_count + 32'd1;
            end
            if (stall_event) begin
                stall_cycle_count <= stall_cycle_count + 32'd1;
            end
            if (matvec_start_accepted_event) begin
                matvec_start_count <= matvec_start_count + 32'd1;
            end
            if (matvec_done_rise_event) begin
                matvec_done_count <= matvec_done_count + 32'd1;
            end
            if (matvec_busy) begin
                matvec_busy_cycle_count <= matvec_busy_cycle_count + 32'd1;
            end
        end
    end

`ifdef FORMAL
    reg formal_past_valid = 1'b0;
    always @(posedge clock) begin
        formal_past_valid <= 1'b1;
        if (formal_past_valid) begin
            if ($past(reset)) begin
                assert(branch_mispredict_event_capture == 1'b0);
            end else begin
                assert(branch_mispredict_event_capture == $past(branch_mispredict_event));
            end
        end
    end
`endif

endmodule
