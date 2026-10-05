`timescale 1ns / 1ps

// Checks: A MATVEC Scratchpad external-interrupt redirect suppresses the interrupted instruction plus younger wrong-path
//   data-memory and GPIO MMIO stores.
// Injects MATVEC pending state hierarchically; tb_program_matvec_scratchpad_interrupt checks real completion
// interrupts.

module tb_assert_matvec_scratchpad_interrupt_flush;

`include "tb_common.vh"

    localparam [31:0] INTERRUPTED_PC = 32'd28;
    localparam [31:0] WRONG_STORE_PC = 32'd32;
    localparam [31:0] WRONG_MMIO_PC = 32'd36;
    localparam [31:0] HANDLER_PC = 32'd40;

    reg checking_enabled = 1'b0;
    reg irq_forced = 1'b0;
    reg irq_released = 1'b0;

    always @(negedge clock) begin
        if (checking_enabled &&
            !irq_forced &&
            dut.CSRmie[11] &&
            dut.CSRmstatus[3] &&
            dut.IDEXValid &&
            (dut.IDEXPC == INTERRUPTED_PC)) begin
            force dut.gen_accelerators.accel_matvec.irq_pending_reg = 1'b1;
            irq_forced = 1'b1;
        end
    end

    always @(posedge clock) begin
        if (checking_enabled &&
            irq_forced &&
            !irq_released &&
            dut.interrupt_taken) begin
            #1;
            release dut.gen_accelerators.accel_matvec.irq_pending_reg;
            irq_released = 1'b1;
        end

        if (checking_enabled &&
            dut.MEMWBValid &&
            dut.MEMWBRegWrite &&
            (dut.MEMWBPC == INTERRUPTED_PC)) begin
            $display("FAIL: interrupted instruction at PC %h reached writeback", dut.MEMWBPC);
            $fatal;
        end

        if (checking_enabled &&
            dut.EXMEMValid &&
            dut.EXMEMMemWrite &&
            ((dut.EXMEMPC == WRONG_STORE_PC) || (dut.EXMEMPC == WRONG_MMIO_PC))) begin
            $display("FAIL: post-interrupt wrong-path side effect at PC %h reached MEM stage", dut.EXMEMPC);
            $fatal;
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_assert_matvec_scratchpad_interrupt_flush.vcd");
        $dumpvars(0, tb_assert_matvec_scratchpad_interrupt_flush);
        reset_cpu();

        dut.DMemory[0] = 32'h1234_abcd;
        dut.IMemory[0] = i_type(12'd55, 5'd0, 3'b000, 5'd2, 7'b0010011);       // x2 = side-effect data
        dut.IMemory[1] = i_type(HANDLER_PC[11:0], 5'd0, 3'b000, 5'd5, 7'b0010011);
        dut.IMemory[2] = i_type(12'h305, 5'd5, 3'b001, 5'd0, 7'b1110011);      // csrrw x0, mtvec, x5
        dut.IMemory[3] = i_type(12'h800, 5'd0, 3'b000, 5'd5, 7'b0010011);      // x5 has MEIE bit set
        dut.IMemory[4] = i_type(12'h304, 5'd5, 3'b010, 5'd0, 7'b1110011);      // csrrs x0, mie, x5
        dut.IMemory[5] = i_type(12'd8, 5'd0, 3'b000, 5'd5, 7'b0010011);        // x5 = mstatus.MIE
        dut.IMemory[6] = i_type(12'h300, 5'd5, 3'b010, 5'd0, 7'b1110011);      // csrrs x0, mstatus, x5
        dut.IMemory[7] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);       // interrupted instruction
        dut.IMemory[8] = s_type(12'd0, 5'd2, 5'd0, 3'b010, 7'b0100011);        // wrong-path sw x2, 0(x0)
        dut.IMemory[9] = s_type(12'h200, 5'd2, 5'd0, 3'b010, 7'b0100011);      // wrong-path sw x2, GPIO
        dut.IMemory[10] = i_type(12'd77, 5'd0, 3'b000, 5'd7, 7'b0010011);      // handler marker
        dut.IMemory[11] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        checking_enabled = 1'b1;
        run_cycles(220);

        if (!irq_forced || !irq_released) begin
            $display("FAIL: test did not force and release MATVEC irq pending, forced=%0d released=%0d", irq_forced, irq_released);
            $fatal;
        end
        if (dut.CSRmtvec !== HANDLER_PC) begin
            $display("FAIL: mtvec expected %h, got %h", HANDLER_PC, dut.CSRmtvec);
            $fatal;
        end
        if (dut.CSRmepc !== INTERRUPTED_PC || dut.CSRmcause !== 32'h8000_000b) begin
            $display("FAIL: interrupt state mepc=%h mcause=%h", dut.CSRmepc, dut.CSRmcause);
            $fatal;
        end
        if (dut.DMemory[0] !== 32'h1234_abcd) begin
            $display("FAIL: post-interrupt wrong-path store changed DMemory[0] to %h", dut.DMemory[0]);
            $fatal;
        end
        if (dut.GPIOOutput !== 32'h0 || gpio_outputs !== 32'h0) begin
            $display(
                "FAIL: post-interrupt wrong-path MMIO changed GPIOOutput=%h gpio_outputs=%h",
                dut.GPIOOutput,
                gpio_outputs
            );
            $fatal;
        end

        check_reg(2, 32'd55);
        check_reg(6, 32'd6);
        check_reg(7, 32'd77);
        $display("PASS: MATVEC interrupt redirect suppressed younger memory and MMIO side effects");
        $display("PASS: tb_assert_matvec_scratchpad_interrupt_flush passed");
        $finish;
    end

endmodule
