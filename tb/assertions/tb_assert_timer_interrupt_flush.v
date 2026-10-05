`timescale 1ns / 1ps

// Checks: A forced machine-timer interrupt redirect suppresses the interrupted instruction plus younger wrong-path
//   data-memory, GPIO, timer, and UART MMIO stores, publishes a public pass signature, and separately checks
//   simultaneous MEIP/MTIP priority selects MEIP.
// Injects timer pending state hierarchically; tb_program_machine_timer_interrupt checks real timer compare
// interrupts.

module tb_assert_timer_interrupt_flush;

`include "tb_common.vh"

    localparam [31:0] INTERRUPTED_PC = 32'd40;
    localparam [31:0] WRONG_STORE_PC = 32'd44;
    localparam [31:0] WRONG_GPIO_PC = 32'd48;
    localparam [31:0] WRONG_TIMER_PC = 32'd52;
    localparam [31:0] WRONG_UART_PC = 32'd56;
    localparam [31:0] HANDLER_PC = 32'd60;
    localparam [31:0] PRIORITY_INTERRUPTED_PC = 32'd32;
    localparam [31:0] PRIORITY_HANDLER_PC = 32'd36;
    localparam [31:0] PASS_MARKER = 32'h0000_0707;

    reg checking_enabled = 1'b0;
    reg irq_forced = 1'b0;
    reg irq_released = 1'b0;
    reg priority_checking_enabled = 1'b0;
    reg priority_forced = 1'b0;
    reg priority_released = 1'b0;
    integer uart_tx_seen = 0;

    always @(posedge clock) begin
        if (uart_tx_valid) begin
            uart_tx_seen <= uart_tx_seen + 1;
        end
    end

    always @(negedge clock) begin
        if (checking_enabled &&
            !irq_forced &&
            dut.CSRmie[7] &&
            dut.CSRmstatus[3] &&
            dut.IDEXValid &&
            (dut.IDEXPC == INTERRUPTED_PC)) begin
            force dut.timer_irq_pending = 1'b1;
            irq_forced = 1'b1;
        end

        if (priority_checking_enabled &&
            !priority_forced &&
            dut.CSRmie[11] &&
            dut.CSRmie[7] &&
            dut.CSRmstatus[3] &&
            dut.IDEXValid &&
            (dut.IDEXPC == PRIORITY_INTERRUPTED_PC)) begin
            force dut.matvec_irq_pending = 1'b1;
            force dut.timer_irq_pending = 1'b1;
            priority_forced = 1'b1;
        end
    end

    always @(posedge clock) begin
        if (checking_enabled &&
            irq_forced &&
            !irq_released &&
            dut.interrupt_taken) begin
            #1;
            release dut.timer_irq_pending;
            irq_released = 1'b1;
        end

        if (priority_checking_enabled &&
            priority_forced &&
            !priority_released &&
            dut.interrupt_taken) begin
            #1;
            release dut.matvec_irq_pending;
            release dut.timer_irq_pending;
            priority_released = 1'b1;
        end

        if (checking_enabled &&
            dut.MEMWBValid &&
            dut.MEMWBRegWrite &&
            (dut.MEMWBPC == INTERRUPTED_PC)) begin
            $display("FAIL: interrupted timer instruction at PC %h reached writeback", dut.MEMWBPC);
            $fatal;
        end

        if (checking_enabled &&
            dut.EXMEMValid &&
            dut.EXMEMMemWrite &&
            ((dut.EXMEMPC == WRONG_STORE_PC) ||
             (dut.EXMEMPC == WRONG_GPIO_PC) ||
             (dut.EXMEMPC == WRONG_TIMER_PC) ||
             (dut.EXMEMPC == WRONG_UART_PC))) begin
            $display("FAIL: post-timer-interrupt wrong-path side effect at PC %h reached MEM stage", dut.EXMEMPC);
            $fatal;
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_assert_timer_interrupt_flush.vcd");
        $dumpvars(0, tb_assert_timer_interrupt_flush);
        reset_cpu();

        dut.DMemory[0] = 32'h1234_abcd;
        dut.IMemory[0] = i_type(12'd55, 5'd0, 3'b000, 5'd2, 7'b0010011);       // x2 = side-effect data
        dut.IMemory[1] = {20'h00001, 5'd1, 7'b0110111};                        // x1 = 0x1000
        dut.IMemory[2] = i_type(12'h800, 5'd1, 3'b000, 5'd1, 7'b0010011);      // x1 = timer base 0x800
        dut.IMemory[3] = i_type(12'h300, 5'd0, 3'b000, 5'd3, 7'b0010011);      // x3 = UART TXDATA
        dut.IMemory[4] = i_type(HANDLER_PC[11:0], 5'd0, 3'b000, 5'd5, 7'b0010011);
        dut.IMemory[5] = i_type(12'h305, 5'd5, 3'b001, 5'd0, 7'b1110011);      // csrrw x0, mtvec, x5
        dut.IMemory[6] = i_type(12'h080, 5'd0, 3'b000, 5'd5, 7'b0010011);      // x5 = MTIE
        dut.IMemory[7] = i_type(12'h304, 5'd5, 3'b010, 5'd0, 7'b1110011);      // csrrs x0, mie, x5
        dut.IMemory[8] = i_type(12'd8, 5'd0, 3'b000, 5'd5, 7'b0010011);        // x5 = mstatus.MIE
        dut.IMemory[9] = i_type(12'h300, 5'd5, 3'b010, 5'd0, 7'b1110011);      // csrrs x0, mstatus, x5
        dut.IMemory[10] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);      // interrupted instruction
        dut.IMemory[11] = s_type(12'd0, 5'd2, 5'd0, 3'b010, 7'b0100011);       // wrong-path sw x2, 0(x0)
        dut.IMemory[12] = s_type(12'h200, 5'd2, 5'd0, 3'b010, 7'b0100011);     // wrong-path sw x2, GPIO
        dut.IMemory[13] = s_type(12'd8, 5'd2, 5'd1, 3'b010, 7'b0100011);       // wrong-path sw x2, mtimecmp low
        dut.IMemory[14] = s_type(12'd0, 5'd2, 5'd3, 3'b010, 7'b0100011);       // wrong-path sw x2, UART TX
        dut.IMemory[15] = i_type(12'd77, 5'd0, 3'b000, 5'd7, 7'b0010011);      // handler marker
        dut.IMemory[16] = i_type(12'd256, 5'd0, 3'b000, 5'd8, 7'b0010011);     // x8 = debug_status
        dut.IMemory[17] = i_type(PASS_MARKER[11:0], 5'd0, 3'b000, 5'd9, 7'b0010011);
        dut.IMemory[18] = s_type(12'd0, 5'd9, 5'd8, 3'b010, 7'b0100011);       // public pass signature
        dut.IMemory[19] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        checking_enabled = 1'b1;
        run_cycles(320);

        if (!irq_forced || !irq_released) begin
            $display("FAIL: test did not force and release timer irq, forced=%0d released=%0d", irq_forced, irq_released);
            $fatal;
        end
        if (debug_status !== PASS_MARKER) begin
            $display("FAIL: handler did not publish pass signature, debug_status=%h", debug_status);
            $fatal;
        end
        if (dut.CSRmtvec !== HANDLER_PC) begin
            $display("FAIL: mtvec expected %h, got %h", HANDLER_PC, dut.CSRmtvec);
            $fatal;
        end
        if (dut.CSRmepc !== INTERRUPTED_PC || dut.CSRmcause !== 32'h8000_0007) begin
            $display("FAIL: timer interrupt state mepc=%h mcause=%h", dut.CSRmepc, dut.CSRmcause);
            $fatal;
        end
        if (dut.DMemory[0] !== 32'h1234_abcd) begin
            $display("FAIL: post-interrupt wrong-path store changed DMemory[0] to %h", dut.DMemory[0]);
            $fatal;
        end
        if (dut.GPIOOutput !== 32'h0 || gpio_outputs !== 32'h0) begin
            $display(
                "FAIL: post-interrupt wrong-path GPIO changed GPIOOutput=%h gpio_outputs=%h",
                dut.GPIOOutput,
                gpio_outputs
            );
            $fatal;
        end
        if (dut.gen_machine_timer.timer.mtimecmp_low_read_data !== 32'hffff_ffff ||
            dut.gen_machine_timer.timer.mtimecmp_high_read_data !== 32'hffff_ffff) begin
            $display("FAIL: wrong-path timer write changed mtimecmp high=%h low=%h",
                     dut.gen_machine_timer.timer.mtimecmp_high_read_data,
                     dut.gen_machine_timer.timer.mtimecmp_low_read_data);
            $fatal;
        end
        if (uart_tx_seen !== 0) begin
            $display("FAIL: wrong-path UART TX observed %0d valid pulses", uart_tx_seen);
            $fatal;
        end

        check_reg(2, 32'd55);
        check_reg(6, 32'd6);
        check_reg(7, 32'd77);
        $display("PASS: timer interrupt redirect suppressed younger memory and MMIO side effects");

        checking_enabled = 1'b0;
        irq_forced = 1'b0;
        irq_released = 1'b0;
        priority_forced = 1'b0;
        priority_released = 1'b0;
        uart_tx_seen = 0;

        reset_cpu();

        dut.IMemory[0] = i_type(PRIORITY_HANDLER_PC[11:0], 5'd0, 3'b000, 5'd5, 7'b0010011);
        dut.IMemory[1] = i_type(12'h305, 5'd5, 3'b001, 5'd0, 7'b1110011);      // csrrw x0, mtvec, x5
        dut.IMemory[2] = i_type(12'h080, 5'd0, 3'b000, 5'd5, 7'b0010011);      // x5 = MTIE
        dut.IMemory[3] = i_type(12'h304, 5'd5, 3'b010, 5'd0, 7'b1110011);      // csrrs x0, mie, x5
        dut.IMemory[4] = i_type(12'h800, 5'd0, 3'b000, 5'd5, 7'b0010011);      // x5 has MEIE bit set
        dut.IMemory[5] = i_type(12'h304, 5'd5, 3'b010, 5'd0, 7'b1110011);      // csrrs x0, mie, x5
        dut.IMemory[6] = i_type(12'd8, 5'd0, 3'b000, 5'd5, 7'b0010011);        // x5 = mstatus.MIE
        dut.IMemory[7] = i_type(12'h300, 5'd5, 3'b010, 5'd0, 7'b1110011);      // csrrs x0, mstatus, x5
        dut.IMemory[8] = i_type(12'd99, 5'd0, 3'b000, 5'd6, 7'b0010011);       // interrupted instruction
        dut.IMemory[9] = i_type(12'd11, 5'd0, 3'b000, 5'd7, 7'b0010011);       // priority handler marker
        dut.IMemory[10] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        priority_checking_enabled = 1'b1;
        run_cycles(220);
        priority_checking_enabled = 1'b0;

        if (!priority_forced || !priority_released) begin
            $display("FAIL: priority phase did not force/release pending sources, forced=%0d released=%0d",
                     priority_forced,
                     priority_released);
            $fatal;
        end
        if (dut.CSRmepc !== PRIORITY_INTERRUPTED_PC || dut.CSRmcause !== 32'h8000_000b) begin
            $display("FAIL: MEIP-over-MTIP priority expected mepc=%h mcause=8000000b, got mepc=%h mcause=%h",
                     PRIORITY_INTERRUPTED_PC,
                     dut.CSRmepc,
                     dut.CSRmcause);
            $fatal;
        end

        check_reg(6, 32'd6);
        check_reg(7, 32'd11);
        $display("PASS: simultaneous MEIP/MTIP pending sources selected MEIP priority");
        $display("PASS: tb_assert_timer_interrupt_flush passed");
        $finish;
    end
endmodule
