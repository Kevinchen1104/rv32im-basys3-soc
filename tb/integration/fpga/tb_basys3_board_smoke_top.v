`timescale 1ns / 1ps

// Testbench: tb_basys3_board_smoke_top
// Purpose: Exercises the separate Basys3 board-smoke target.
// Checks: Switch synchronization plus straight-line firmware pass/done/status latching onto public LED pins.
// Pass condition: LED pass and done bits assert, fail stays low, done-PC LEDs show 0x6, and status LEDs show the signature low byte.
// Does not prove: Wrapper simulation only; no Vivado timing closure, bitstream signoff, or physical board validation.
// Firmware: firmware/hex/showcase/board_smoke.hex
// Boundary: Simulation wrapper evidence only; not timing closure or physical board validation.

module tb_basys3_board_smoke_top;

    reg clk = 1'b0;
    reg btnC = 1'b0;
    reg RsRx = 1'b1;
    reg [15:0] sw = 16'h0000;
    wire RsTx;
    wire [15:0] led;

    RISCVCPU_basys3_board_smoke_top dut (
        .clk(clk),
        .btnC(btnC),
        .RsRx(RsRx),
        .RsTx(RsTx),
        .sw(sw),
        .led(led)
    );

    always #5 clk = ~clk;

    initial begin
        $dumpfile("wave/tb_basys3_board_smoke_top.vcd");
        $dumpvars(0, tb_basys3_board_smoke_top);

        btnC = 1'b1;
        repeat (3) @(posedge clk);
        #1;
        btnC = 1'b0;

        sw = 16'ha55a;
        #1;
        if (dut.sw_sync !== 16'h0000) begin
            $display("FAIL: asynchronous switch input bypassed the synchronizer");
            $fatal;
        end
        @(posedge clk);
        #1;
        if (dut.sw_sync !== 16'h0000) begin
            $display("FAIL: switch synchronizer changed before the second stage");
            $fatal;
        end
        @(posedge clk);
        #1;
        if (dut.sw_sync !== 16'ha55a) begin
            $display("FAIL: switch synchronizer did not capture the stable input");
            $fatal;
        end
        sw = 16'h0000;
        repeat (2) @(posedge clk);

        repeat (6000) @(posedge clk);
        #1;

        if (RsTx !== 1'b1) begin
            $display("FAIL: board-smoke UART TX pin should idle high, got %b", RsTx);
            $fatal;
        end

        if (led[0] !== 1'b1 || led[1] !== 1'b0 || led[2] !== 1'b1) begin
            $display("FAIL: expected pass=1 fail=0 done=1, got led[2:0]=%b", led[2:0]);
            $fatal;
        end

        if (led[7:4] !== 4'h6) begin
            $display("FAIL: expected done-PC LED nibble 6, got %h", led[7:4]);
            $fatal;
        end

        if (led[15:8] !== 8'hfe) begin
            $display("FAIL: expected status low-byte LEDs fe, got %h", led[15:8]);
            $fatal;
        end

        $display("PASS: Basys3 board-smoke top exposed pass/done/status on LEDs");
        $display("PASS: tb_basys3_board_smoke_top passed");
        $finish;
    end

endmodule
