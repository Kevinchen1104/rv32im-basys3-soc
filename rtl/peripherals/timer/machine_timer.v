`timescale 1ns / 1ps

// Module: machine_timer
// Role: Machine timer MMIO block for the selected machine-mode interrupt subset.
// Interface: Clock/reset, MMIO read/write selects, write data, mtime/mtimecmp read data, and timer interrupt output.
// Key behavior: Increments mtime, updates mtimecmp through MMIO stores, and registers the sampled mtime/mtimecmp comparison.

module machine_timer (
    input clock,
    input reset,

    input mtime_low_write,
    input mtime_high_write,
    input mtimecmp_low_write,
    input mtimecmp_high_write,
    input [31:0] write_data,

    output [31:0] mtime_low_read_data,
    output [31:0] mtime_high_read_data,
    output [31:0] mtimecmp_low_read_data,
    output [31:0] mtimecmp_high_read_data,
    output timer_irq
);
    reg [63:0] mtime;
    reg [63:0] mtimecmp;
    reg timer_irq_pending;

    assign mtime_low_read_data = mtime[31:0];
    assign mtime_high_read_data = mtime[63:32];
    assign mtimecmp_low_read_data = mtimecmp[31:0];
    assign mtimecmp_high_read_data = mtimecmp[63:32];
    assign timer_irq = timer_irq_pending;

    always @(posedge clock) begin
        if (reset) begin
            mtime <= 64'h0000_0000_0000_0000;
            mtimecmp <= 64'hffff_ffff_ffff_ffff;
            timer_irq_pending <= 1'b0;
        end else begin
            // Sample the current timer state before this edge's increment or
            // MMIO writes. The output is not sticky: moving mtimecmp back into
            // the future deasserts it after the same one-cycle observation
            // latency used for assertion.
            timer_irq_pending <= (mtime >= mtimecmp);
            mtime <= mtime + 64'd1;

            if (mtime_low_write) begin
                mtime[31:0] <= write_data;
            end
            if (mtime_high_write) begin
                mtime[63:32] <= write_data;
            end
            if (mtimecmp_low_write) begin
                mtimecmp[31:0] <= write_data;
            end
            if (mtimecmp_high_write) begin
                mtimecmp[63:32] <= write_data;
            end
        end
    end

`ifdef FORMAL
    reg formal_past_valid = 1'b0;
    always @(posedge clock) begin
        formal_past_valid <= 1'b1;
        if (formal_past_valid) begin
            if ($past(reset)) begin
                assert(mtime == 64'h0000_0000_0000_0000);
                assert(mtimecmp == 64'hffff_ffff_ffff_ffff);
                assert(timer_irq_pending == 1'b0);
            end else begin
                assert(timer_irq_pending == ($past(mtime) >= $past(mtimecmp)));
            end
        end
    end
`endif
endmodule
