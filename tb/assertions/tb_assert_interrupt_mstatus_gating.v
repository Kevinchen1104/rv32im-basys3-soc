`timescale 1ns / 1ps

// Testbench: tb_assert_interrupt_mstatus_gating
// Purpose: Exercises a focused pipeline, trap, or side-effect invariant with a directed simulation scenario.
// Checks: Timer interrupt trap entry clears mstatus.MIE, saves old MIE in mstatus.MPIE, keeps a still-pending MTIP
//   from retrapping while the handler executes, and restores MIE through mret.
// Pass condition: The directed scenario reaches the expected invariant/pass point without a mismatch, timeout, or
//   $fatal.
// Does not prove: Minimal mstatus.MIE/MPIE interrupt-gating slice only; not a nested interrupt architecture,
//   privilege-stack proof, delegation model, full CLINT, or full privileged implementation.
// Assertion focus: Directed check for interrupt mstatus gating behavior or side-effect suppression.

module tb_assert_interrupt_mstatus_gating;

`include "tb_common.vh"

    localparam [31:0] HANDLER_PC = 32'd128;
    localparam [31:0] POSTPONE_PC = 32'd176;
    localparam [31:0] PASS_MARKER = 32'h0000_0707;

    integer interrupt_count = 0;
    reg handler_window_active = 1'b0;
    integer handler_mstatus_checks = 0;

    always @(posedge clock) begin
        if (dut.interrupt_taken) begin
            interrupt_count = interrupt_count + 1;
            if (handler_window_active) begin
                $display("FAIL: retrap occurred before handler cleared/postponed the timer");
                $fatal;
            end
            handler_window_active = 1'b1;
            #1;
            if (dut.CSRmstatus[3] !== 1'b0 || dut.CSRmstatus[7] !== 1'b1) begin
                $display("FAIL: trap entry expected mstatus MIE=0 MPIE=1, got %h", dut.CSRmstatus);
                $fatal;
            end
        end

        #1;
        if (handler_window_active &&
            dut.IDEXValid &&
            (dut.IDEXPC >= HANDLER_PC) &&
            (dut.IDEXPC < POSTPONE_PC)) begin
            handler_mstatus_checks = handler_mstatus_checks + 1;
            if (dut.CSRmstatus[3] !== 1'b0 || dut.CSRmstatus[7] !== 1'b1) begin
                $display("FAIL: handler executed with unexpected mstatus=%h at PC=%h",
                         dut.CSRmstatus,
                         dut.IDEXPC);
                $fatal;
            end
            if (dut.CSRmip[7] !== 1'b1) begin
                $display("FAIL: timer should still be pending during gating window, mip=%h", dut.CSRmip);
                $fatal;
            end
        end

        if (handler_window_active &&
            dut.IDEXValid &&
            (dut.IDEXPC >= POSTPONE_PC)) begin
            handler_window_active = 1'b0;
        end
    end

    initial begin
        $dumpfile("wave/tb_assert_interrupt_mstatus_gating.vcd");
        $dumpvars(0, tb_assert_interrupt_mstatus_gating);
        reset_cpu();

        dut.IMemory[0] = {20'h00001, 5'd1, 7'b0110111};                         // x1 = 0x1000
        dut.IMemory[1] = i_type(12'h800, 5'd1, 3'b000, 5'd1, 7'b0010011);       // x1 = timer base 0x800
        dut.IMemory[2] = i_type(HANDLER_PC[11:0], 5'd0, 3'b000, 5'd5, 7'b0010011);
        dut.IMemory[3] = i_type(12'h305, 5'd5, 3'b001, 5'd0, 7'b1110011);       // csrrw x0, mtvec, x5
        dut.IMemory[4] = i_type(12'hfff, 5'd0, 3'b000, 5'd2, 7'b0010011);       // x2 = -1
        dut.IMemory[5] = s_type(12'd12, 5'd2, 5'd1, 3'b010, 7'b0100011);        // mtimecmp high far future
        dut.IMemory[6] = s_type(12'd8, 5'd2, 5'd1, 3'b010, 7'b0100011);         // mtimecmp low far future
        dut.IMemory[7] = i_type(12'd0, 5'd0, 3'b000, 5'd2, 7'b0010011);         // x2 = 0
        dut.IMemory[8] = s_type(12'd4, 5'd2, 5'd1, 3'b010, 7'b0100011);         // mtime high = 0
        dut.IMemory[9] = s_type(12'd0, 5'd2, 5'd1, 3'b010, 7'b0100011);         // mtime low = 0
        dut.IMemory[10] = s_type(12'd12, 5'd2, 5'd1, 3'b010, 7'b0100011);       // mtimecmp high = 0
        dut.IMemory[11] = i_type(12'd40, 5'd0, 3'b000, 5'd2, 7'b0010011);       // mtimecmp low soon
        dut.IMemory[12] = s_type(12'd8, 5'd2, 5'd1, 3'b010, 7'b0100011);
        dut.IMemory[13] = i_type(12'd0, 5'd0, 3'b000, 5'd9, 7'b0010011);        // s1 = handler flag
        dut.IMemory[14] = i_type(12'h080, 5'd0, 3'b000, 5'd5, 7'b0010011);      // x5 = MTIE
        dut.IMemory[15] = i_type(12'h304, 5'd5, 3'b010, 5'd0, 7'b1110011);      // csrrs x0, mie, x5
        dut.IMemory[16] = i_type(12'd8, 5'd0, 3'b000, 5'd5, 7'b0010011);        // x5 = mstatus.MIE
        dut.IMemory[17] = i_type(12'h300, 5'd5, 3'b010, 5'd0, 7'b1110011);      // csrrs x0, mstatus, x5
        dut.IMemory[18] = b_type(0, 5'd0, 5'd9, 3'b000, 7'b1100011);            // wait_irq: beq s1, zero, wait_irq
        dut.IMemory[19] = i_type(12'd256, 5'd0, 3'b000, 5'd8, 7'b0010011);      // x8 = debug_status addr
        dut.IMemory[20] = i_type(PASS_MARKER[11:0], 5'd0, 3'b000, 5'd10, 7'b0010011);
        dut.IMemory[21] = s_type(12'd0, 5'd10, 5'd8, 3'b010, 7'b0100011);       // public pass signature
        dut.IMemory[22] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        dut.IMemory[32] = i_type(12'h300, 5'd0, 3'b010, 5'd10, 7'b1110011);     // csrrs x10, mstatus, x0
        dut.IMemory[33] = s_type(12'd0, 5'd10, 5'd0, 3'b010, 7'b0100011);
        dut.IMemory[34] = i_type(12'h342, 5'd0, 3'b010, 5'd11, 7'b1110011);     // csrrs x11, mcause, x0
        dut.IMemory[35] = s_type(12'd4, 5'd11, 5'd0, 3'b010, 7'b0100011);
        dut.IMemory[36] = i_type(12'h344, 5'd0, 3'b010, 5'd12, 7'b1110011);     // csrrs x12, mip, x0
        dut.IMemory[37] = s_type(12'd8, 5'd12, 5'd0, 3'b010, 7'b0100011);
        dut.IMemory[38] = i_type(12'd1, 5'd0, 3'b000, 5'd13, 7'b0010011);
        dut.IMemory[39] = s_type(12'd12, 5'd13, 5'd0, 3'b010, 7'b0100011);
        dut.IMemory[40] = i_type(12'd1, 5'd13, 3'b000, 5'd13, 7'b0010011);
        dut.IMemory[41] = s_type(12'd12, 5'd13, 5'd0, 3'b010, 7'b0100011);
        dut.IMemory[42] = i_type(12'd1, 5'd13, 3'b000, 5'd13, 7'b0010011);
        dut.IMemory[43] = s_type(12'd12, 5'd13, 5'd0, 3'b010, 7'b0100011);
        dut.IMemory[44] = i_type(12'hfff, 5'd0, 3'b000, 5'd14, 7'b0010011);     // x14 = -1
        dut.IMemory[45] = s_type(12'd12, 5'd14, 5'd1, 3'b010, 7'b0100011);      // postpone timer high
        dut.IMemory[46] = s_type(12'd8, 5'd14, 5'd1, 3'b010, 7'b0100011);       // postpone timer low
        dut.IMemory[47] = i_type(12'd1, 5'd0, 3'b000, 5'd9, 7'b0010011);        // s1 = 1
        dut.IMemory[48] = 32'h3020_0073;                                        // mret

        run_cycles(600);

        if (debug_status !== PASS_MARKER) begin
            $display("FAIL: expected pass signature %h, got %h at pc %h",
                     PASS_MARKER,
                     debug_status,
                     debug_pc);
            $fatal;
        end
        if (interrupt_count !== 1) begin
            $display("FAIL: expected exactly one timer interrupt, got %0d", interrupt_count);
            $fatal;
        end
        if (handler_mstatus_checks < 4) begin
            $display("FAIL: expected multiple handler mstatus checks, got %0d", handler_mstatus_checks);
            $fatal;
        end
        if (dut.DMemory[0][3] !== 1'b0 || dut.DMemory[0][7] !== 1'b1) begin
            $display("FAIL: stored handler mstatus expected MIE=0 MPIE=1, got %h", dut.DMemory[0]);
            $fatal;
        end
        if (dut.DMemory[1] !== 32'h8000_0007 || dut.DMemory[2][7] !== 1'b1) begin
            $display("FAIL: stored timer trap evidence mcause=%h mip=%h",
                     dut.DMemory[1],
                     dut.DMemory[2]);
            $fatal;
        end
        if (dut.DMemory[3] !== 32'd3) begin
            $display("FAIL: handler did not execute all pending-window steps, step=%h", dut.DMemory[3]);
            $fatal;
        end
        if (dut.CSRmstatus[3] !== 1'b1 || dut.CSRmstatus[7] !== 1'b1) begin
            $display("FAIL: mret should restore mstatus MIE=1 MPIE=1, got %h", dut.CSRmstatus);
            $fatal;
        end
        if (dut.CSRmip[7] !== 1'b0) begin
            $display("FAIL: handler should postpone timer before mret, mip=%h", dut.CSRmip);
            $fatal;
        end

        $display("PASS: interrupt handler ran with mstatus.MIE cleared until timer was postponed");
        $display("PASS: tb_assert_interrupt_mstatus_gating passed");
        $finish;
    end
endmodule
