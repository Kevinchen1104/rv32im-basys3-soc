`timescale 1ns / 1ps

// Testbench: tb_machine_timer
// Purpose: Checks a local MMIO peripheral, UART, timer, GPIO, or decoder block.
// Checks: Standalone machine timer peripheral resets mtime/mtimecmp, increments mtime, supports deterministic
//   low/high register writes, registers MTIP-style comparison results with one-cycle observation latency, and
//   handles compare postponement, low-half carry, and 64-bit rollover.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.
//   nested interrupt, delegation, or board-timing proof.

module tb_machine_timer;
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

    task check32;
        input [255:0] label;
        input [31:0] actual;
        input [31:0] expected;
        begin
            if (actual !== expected) begin
                $display("FAIL: %0s expected=%08x actual=%08x", label, expected, actual);
                $fatal;
            end
        end
    endtask

    task check_irq;
        input [255:0] label;
        input expected;
        begin
            if (timer_irq !== expected) begin
                $display("FAIL: %0s expected irq=%0b actual=%0b", label, expected, timer_irq);
                $fatal;
            end
        end
    endtask

    task write_timer_word;
        input [1:0] select_reg;
        input [31:0] value;
        begin
            write_data = value;
            mtime_low_write = (select_reg == 2'd0);
            mtime_high_write = (select_reg == 2'd1);
            mtimecmp_low_write = (select_reg == 2'd2);
            mtimecmp_high_write = (select_reg == 2'd3);
            @(posedge clock);
            #1;
            mtime_low_write = 1'b0;
            mtime_high_write = 1'b0;
            mtimecmp_low_write = 1'b0;
            mtimecmp_high_write = 1'b0;
            write_data = 32'h0;
        end
    endtask

    initial begin
        $dumpfile("wave/tb_machine_timer.vcd");
        $dumpvars(0, tb_machine_timer);

        reset = 1'b1;
        repeat (2) @(posedge clock);
        #1;
        reset = 1'b0;
        #1;

        check32("reset mtime low", mtime_low_read_data, 32'h0000_0000);
        check32("reset mtime high", mtime_high_read_data, 32'h0000_0000);
        check32("reset mtimecmp low", mtimecmp_low_read_data, 32'hffff_ffff);
        check32("reset mtimecmp high", mtimecmp_high_read_data, 32'hffff_ffff);
        check_irq("reset irq", 1'b0);

        repeat (5) @(posedge clock);
        #1;
        check32("mtime increments low", mtime_low_read_data, 32'h0000_0005);
        check32("mtime increments high", mtime_high_read_data, 32'h0000_0000);
        check_irq("future reset compare", 1'b0);

        write_timer_word(2'd0, 32'h0000_0020);
        check32("mtime low write", mtime_low_read_data, 32'h0000_0020);
        check32("mtime high after low write", mtime_high_read_data, 32'h0000_0000);

        write_timer_word(2'd3, 32'h0000_0000);
        write_timer_word(2'd2, 32'h0000_0040);
        check32("mtimecmp low future", mtimecmp_low_read_data, 32'h0000_0040);
        check32("mtimecmp high future", mtimecmp_high_read_data, 32'h0000_0000);
        check_irq("future compare irq low", 1'b0);

        write_timer_word(2'd1, 32'h0000_0000);
        write_timer_word(2'd0, 32'h0000_003f);
        check_irq("one cycle before compare", 1'b0);
        @(posedge clock);
        #1;
        check32("mtime reached compare", mtime_low_read_data, 32'h0000_0040);
        check_irq("threshold edge keeps prior sampled irq", 1'b0);
        @(posedge clock);
        #1;
        check32("mtime advances after threshold", mtime_low_read_data, 32'h0000_0041);
        check_irq("threshold comparison appears one cycle later", 1'b1);

        write_timer_word(2'd3, 32'hffff_ffff);
        check_irq("compare high write retains prior sampled irq", 1'b1);
        write_timer_word(2'd2, 32'hffff_ffff);
        check32("mtimecmp low far future", mtimecmp_low_read_data, 32'hffff_ffff);
        check32("mtimecmp high far future", mtimecmp_high_read_data, 32'hffff_ffff);
        check_irq("far future compare clears irq", 1'b0);

        // Exercise the low-half increment carry without changing MMIO write
        // priority: the selected half wins over the normal increment.
        write_timer_word(2'd1, 32'h0000_0001);
        write_timer_word(2'd0, 32'hffff_fffe);
        @(posedge clock);
        @(posedge clock);
        #1;
        check32("mtime low-half carry low", mtime_low_read_data, 32'h0000_0000);
        check32("mtime low-half carry high", mtime_high_read_data, 32'h0000_0002);

        // At full rollover the sampled comparison remains visible for one
        // cycle even though the post-edge mtime value has wrapped to zero.
        write_timer_word(2'd1, 32'hffff_ffff);
        write_timer_word(2'd0, 32'hffff_ffff);
        check_irq("max value not sampled until next edge", 1'b0);
        @(posedge clock);
        #1;
        check32("64-bit rollover low", mtime_low_read_data, 32'h0000_0000);
        check32("64-bit rollover high", mtime_high_read_data, 32'h0000_0000);
        check_irq("pre-rollover comparison captured", 1'b1);
        @(posedge clock);
        #1;
        check_irq("post-rollover comparison clears", 1'b0);

        // Lowering and then postponing mtimecmp each take one sampling cycle
        // to affect the registered pending output.
        write_timer_word(2'd1, 32'h0000_0000);
        write_timer_word(2'd0, 32'h0000_0100);
        write_timer_word(2'd3, 32'h0000_0000);
        write_timer_word(2'd2, 32'h0000_0200);
        @(posedge clock);
        #1;
        check_irq("future comparison stabilized low", 1'b0);
        write_timer_word(2'd2, 32'h0000_0080);
        check_irq("lowered compare retains prior low sample", 1'b0);
        @(posedge clock);
        #1;
        check_irq("lowered compare asserts one cycle later", 1'b1);
        write_timer_word(2'd2, 32'h0000_0400);
        check_irq("postponed compare retains prior high sample", 1'b1);
        @(posedge clock);
        #1;
        check_irq("postponed compare clears one cycle later", 1'b0);

        reset = 1'b1;
        @(posedge clock);
        #1;
        check_irq("reset clears registered pending", 1'b0);

        $display("PASS: registered machine timer pending latency, writes, carry, rollover, and reset checked");
        $display("PASS: tb_machine_timer passed");
        $finish;
    end
endmodule
