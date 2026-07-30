`default_nettype none

module machine_timer_pending_formal;
    (* gclk *) reg clock;
    reg reset = 1'b1;
    (* anyseq *) reg mtime_low_write;
    (* anyseq *) reg mtime_high_write;
    (* anyseq *) reg mtimecmp_low_write;
    (* anyseq *) reg mtimecmp_high_write;
    (* anyseq *) reg [31:0] write_data;

    wire [31:0] mtime_low_read_data;
    wire [31:0] mtime_high_read_data;
    wire [31:0] mtimecmp_low_read_data;
    wire [31:0] mtimecmp_high_read_data;
    wire timer_irq;
    reg past_valid = 1'b0;

    machine_timer dut (
        .clock(clock),
        .reset(reset),
        .mtime_low_write(mtime_low_write),
        .mtime_high_write(mtime_high_write),
        .mtimecmp_low_write(mtimecmp_low_write),
        .mtimecmp_high_write(mtimecmp_high_write),
        .write_data(write_data),
        .mtime_low_read_data(mtime_low_read_data),
        .mtime_high_read_data(mtime_high_read_data),
        .mtimecmp_low_read_data(mtimecmp_low_read_data),
        .mtimecmp_high_read_data(mtimecmp_high_read_data),
        .timer_irq(timer_irq)
    );

    always @(posedge clock) begin
        past_valid <= 1'b1;
        if (!past_valid) begin
            reset <= 1'b1;
        end else begin
            reset <= 1'b0;
        end
    end
endmodule

`default_nettype wire
