`default_nettype none

module registered_branch_miss_event_formal;
    (* gclk *) reg clock;
    reg reset = 1'b1;
    (* anyseq *) reg branch_mispredict_event;

    wire [31:0] cycle_count;
    wire [31:0] retired_count;
    wire [31:0] branch_miss_count;
    wire [31:0] icache_miss_count;
    wire [31:0] dcache_miss_count;
    wire [31:0] stall_cycle_count;
    wire [31:0] matvec_start_count;
    wire [31:0] matvec_done_count;
    wire [31:0] matvec_busy_cycle_count;

    reg past_valid = 1'b0;
    reg [31:0] reference_count = 32'd0;

    performance_counter_unit dut (
        .clock(clock),
        .reset(reset),
        .retire_event(1'b0),
        .branch_mispredict_event(branch_mispredict_event),
        .icache_miss_event(1'b0),
        .dcache_miss_event(1'b0),
        .stall_event(1'b0),
        .matvec_start_accepted_event(1'b0),
        .matvec_done_rise_event(1'b0),
        .matvec_busy(1'b0),
        .cycle_count(cycle_count),
        .retired_count(retired_count),
        .branch_miss_count(branch_miss_count),
        .icache_miss_count(icache_miss_count),
        .dcache_miss_count(dcache_miss_count),
        .stall_cycle_count(stall_cycle_count),
        .matvec_start_count(matvec_start_count),
        .matvec_done_count(matvec_done_count),
        .matvec_busy_cycle_count(matvec_busy_cycle_count)
    );

    always @(posedge clock) begin
        past_valid <= 1'b1;
        if (!past_valid) begin
            reset <= 1'b1;
        end else begin
            reset <= 1'b0;
        end

        if (reset) begin
            reference_count <= 32'd0;
        end else begin
            if (branch_mispredict_event) begin
                reference_count <= reference_count + 32'd1;
            end
        end
    end

    always @(*) begin
        if (past_valid) begin
            assert(branch_miss_count == reference_count);
        end
    end
endmodule

`default_nettype wire
