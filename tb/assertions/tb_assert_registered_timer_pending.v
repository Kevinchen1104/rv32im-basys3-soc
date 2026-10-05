`timescale 1ns / 1ps

// Purpose: Checks the machine timer's registered comparison boundary cycle by cycle.
// Checks: MTIP equals the preceding mtime>=mtimecmp sample across threshold crossing, compare writes,
//   consecutive writes, deassertion, and reset; the pending state is sampled rather than sticky.
// Pass condition: Every post-edge interrupt value matches the comparison sampled immediately before that edge.

module tb_assert_registered_timer_pending;
    reg clock = 1'b0;
    reg reset = 1'b0;
    reg mtime_low_write = 1'b0;
    reg mtime_high_write = 1'b0;
    reg mtimecmp_low_write = 1'b0;
    reg mtimecmp_high_write = 1'b0;
    reg [31:0] write_data = 32'h0;

    wire [31:0] mtime_low_read_data;
    wire [31:0] mtime_high_read_data;
    wire [31:0] mtimecmp_low_read_data;
    wire [31:0] mtimecmp_high_read_data;
    wire timer_irq;

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

    always #5 clock = ~clock;

    task step_and_check;
        input [255:0] label;
        reg expected_irq;
        begin
            expected_irq = (dut.mtime >= dut.mtimecmp);
            @(posedge clock);
            #1;
            if (timer_irq !== expected_irq) begin
                $display("FAIL: %0s expected registered irq=%0b actual=%0b mtime=%h mtimecmp=%h",
                         label, expected_irq, timer_irq, dut.mtime, dut.mtimecmp);
                $fatal;
            end
        end
    endtask

    task write_word_and_check;
        input [255:0] label;
        input [1:0] select_reg;
        input [31:0] value;
        begin
            @(negedge clock);
            write_data = value;
            mtime_low_write = (select_reg == 2'd0);
            mtime_high_write = (select_reg == 2'd1);
            mtimecmp_low_write = (select_reg == 2'd2);
            mtimecmp_high_write = (select_reg == 2'd3);
            step_and_check(label);
            mtime_low_write = 1'b0;
            mtime_high_write = 1'b0;
            mtimecmp_low_write = 1'b0;
            mtimecmp_high_write = 1'b0;
            write_data = 32'h0;
        end
    endtask

    initial begin
        $dumpfile("results/waveforms/tb_assert_registered_timer_pending.vcd");
        $dumpvars(0, tb_assert_registered_timer_pending);

        reset = 1'b1;
        repeat (2) @(posedge clock);
        #1;
        if (timer_irq !== 1'b0) begin
            $display("FAIL: reset did not clear registered timer pending");
            $fatal;
        end
        reset = 1'b0;

        write_word_and_check("compare high write samples prior state", 2'd3, 32'h0);
        write_word_and_check("compare low write samples prior state", 2'd2, 32'd8);
        write_word_and_check("mtime high write samples prior state", 2'd1, 32'h0);
        write_word_and_check("mtime low write samples prior state", 2'd0, 32'd7);
        step_and_check("threshold arrival retains prior comparison");
        step_and_check("threshold comparison asserts on following edge");

        write_word_and_check("postpone compare retains asserted sample", 2'd2, 32'd20);
        step_and_check("postponed compare deasserts on following edge");

        // Consecutive writes deliberately make the comparison true and then
        // false. Each result appears in order on the next registered sample.
        write_word_and_check("lower compare samples prior false state", 2'd2, 32'd2);
        write_word_and_check("raise compare observes lowered threshold", 2'd2, 32'd30);
        step_and_check("raised compare clears after one sample");

        reset = 1'b1;
        @(posedge clock);
        #1;
        if (timer_irq !== 1'b0 || dut.timer_irq_pending !== 1'b0) begin
            $display("FAIL: reset did not cancel registered timer pending");
            $fatal;
        end

        $display("PASS: registered timer pending matched the preceding comparison across writes and reset");
        $display("PASS: tb_assert_registered_timer_pending passed");
        $finish;
    end
endmodule
