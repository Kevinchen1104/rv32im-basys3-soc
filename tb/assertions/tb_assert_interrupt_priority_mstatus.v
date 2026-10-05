`timescale 1ns / 1ps

// Checks: Pending MTIP/MEIP do not trap while mstatus.MIE=0, and simultaneous enabled MEIP/MTIP selects machine
//   external interrupt priority with mcause=0x8000000b and mtval=0.

module tb_assert_interrupt_priority_mstatus;

`include "tb_common.vh"

    localparam [31:0] PRIORITY_INTERRUPTED_PC = 32'd32;
    localparam [31:0] PRIORITY_HANDLER_PC = 32'd40;

    reg no_mie_phase = 1'b0;
    reg priority_phase = 1'b0;
    reg priority_forced = 1'b0;
    reg priority_released = 1'b0;

    always @(negedge clock) begin
        if (priority_phase &&
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
        if (no_mie_phase && dut.interrupt_taken) begin
            $display("FAIL: interrupt was taken while mstatus.MIE=0");
            $fatal;
        end

        if (priority_phase && priority_forced && !priority_released && dut.interrupt_taken) begin
            #1;
            release dut.matvec_irq_pending;
            release dut.timer_irq_pending;
            priority_released = 1'b1;
        end
    end

    task run_no_mie_phase;
        begin
            reset_cpu();
            dut.IMemory[0] = i_type(12'd40, 5'd0, 3'b000, 5'd1, 7'b0010011);
            dut.IMemory[1] = i_type(12'h305, 5'd1, 3'b001, 5'd0, 7'b1110011);
            dut.IMemory[2] = i_type(12'h080, 5'd0, 3'b000, 5'd5, 7'b0010011);
            dut.IMemory[3] = i_type(12'h304, 5'd5, 3'b010, 5'd0, 7'b1110011);
            dut.IMemory[4] = i_type(12'h800, 5'd0, 3'b000, 5'd5, 7'b0010011);
            dut.IMemory[5] = i_type(12'h304, 5'd5, 3'b010, 5'd0, 7'b1110011);
            dut.IMemory[6] = i_type(12'd1, 5'd0, 3'b000, 5'd6, 7'b0010011);
            dut.IMemory[7] = i_type(12'd1, 5'd6, 3'b000, 5'd6, 7'b0010011);
            dut.IMemory[8] = i_type(12'd1, 5'd6, 3'b000, 5'd6, 7'b0010011);
            dut.IMemory[9] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);
            dut.IMemory[10] = i_type(12'd77, 5'd0, 3'b000, 5'd7, 7'b0010011);
            dut.IMemory[11] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

            force dut.matvec_irq_pending = 1'b1;
            force dut.timer_irq_pending = 1'b1;
            no_mie_phase = 1'b1;
            run_cycles(180);
            no_mie_phase = 1'b0;
            release dut.matvec_irq_pending;
            release dut.timer_irq_pending;

            if (dut.CSRmstatus[3] !== 1'b0 || dut.CSRmcause !== 32'h0) begin
                $display("FAIL: MIE=0 phase changed mstatus/mcause unexpectedly, mstatus=%h mcause=%h",
                         dut.CSRmstatus,
                         dut.CSRmcause);
                $fatal;
            end
            check_reg(6, 32'd3);
            check_reg(7, 32'd7);
        end
    endtask

    task run_priority_phase;
        begin
            reset_cpu();
            dut.IMemory[0] = i_type(PRIORITY_HANDLER_PC[11:0], 5'd0, 3'b000, 5'd1, 7'b0010011);
            dut.IMemory[1] = i_type(12'h305, 5'd1, 3'b001, 5'd0, 7'b1110011);
            dut.IMemory[2] = i_type(12'h080, 5'd0, 3'b000, 5'd5, 7'b0010011);
            dut.IMemory[3] = i_type(12'h304, 5'd5, 3'b010, 5'd0, 7'b1110011);
            dut.IMemory[4] = i_type(12'h800, 5'd0, 3'b000, 5'd5, 7'b0010011);
            dut.IMemory[5] = i_type(12'h304, 5'd5, 3'b010, 5'd0, 7'b1110011);
            dut.IMemory[6] = i_type(12'd8, 5'd0, 3'b000, 5'd5, 7'b0010011);
            dut.IMemory[7] = i_type(12'h300, 5'd5, 3'b010, 5'd0, 7'b1110011);
            dut.IMemory[8] = i_type(12'd99, 5'd0, 3'b000, 5'd6, 7'b0010011);
            dut.IMemory[9] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);
            dut.IMemory[10] = i_type(12'd11, 5'd0, 3'b000, 5'd7, 7'b0010011);
            dut.IMemory[11] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

            priority_forced = 1'b0;
            priority_released = 1'b0;
            priority_phase = 1'b1;
            run_cycles(240);
            priority_phase = 1'b0;

            if (!priority_forced || !priority_released) begin
                $display("FAIL: priority phase did not force/release both pending sources");
                $fatal;
            end
            if (dut.CSRmepc !== PRIORITY_INTERRUPTED_PC ||
                dut.CSRmcause !== 32'h8000_000b ||
                dut.CSRmtval !== 32'h0) begin
                $display("FAIL: priority evidence mepc=%h mcause=%h mtval=%h",
                         dut.CSRmepc,
                         dut.CSRmcause,
                         dut.CSRmtval);
                $fatal;
            end
            if (dut.CSRmstatus[3] !== 1'b0 || dut.CSRmstatus[7] !== 1'b1) begin
                $display("FAIL: interrupt trap entry mstatus expected MIE=0 MPIE=1, got %h",
                         dut.CSRmstatus);
                $fatal;
            end
            check_reg(6, 32'd6);
            check_reg(7, 32'd11);
        end
    endtask

    initial begin
        $dumpfile("results/waveforms/tb_assert_interrupt_priority_mstatus.vcd");
        $dumpvars(0, tb_assert_interrupt_priority_mstatus);

        run_no_mie_phase();
        run_priority_phase();

        $display("PASS: tb_assert_interrupt_priority_mstatus passed");
        $finish;
    end

endmodule
