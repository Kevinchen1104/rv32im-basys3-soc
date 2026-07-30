`timescale 1ns / 1ps

// Testbench: tb_program_mret_trap
// Purpose: Runs CPU firmware to exercise the selected machine-mode CSR/trap subset.
// Checks: Assembled trap program records causes and resumes through mret/mepc.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/csr_trap/mret_trap.hex

module tb_program_mret_trap;

`include "tb_common.vh"

    task check_memory_word;
        input integer word_index;
        input [31:0] expected;
        begin
            if (dut.DMemory[word_index] !== expected) begin
                $display("FAIL: DMemory[%0d] expected %h, got %h",
                         word_index, expected, dut.DMemory[word_index]);
                $fatal;
            end
            $display("PASS: DMemory[%0d] = %h", word_index, dut.DMemory[word_index]);
        end
    endtask

    initial begin
        $dumpfile("wave/tb_program_mret_trap.vcd");
        $dumpvars(0, tb_program_mret_trap);

        reset_cpu();
        $readmemh("firmware/hex/csr_trap/mret_trap.hex", dut.IMemory, 0, 17);

        run_cycles(700);

        check_memory_word(0, 32'd11);
        check_memory_word(1, 32'd16);
        check_memory_word(2, 32'd3);
        check_memory_word(3, 32'd20);
        check_memory_word(4, 32'd2);
        check_memory_word(5, 32'd24);

        if (dut.CSRmtvec !== 32'd40) begin
            $display("FAIL: mtvec expected 00000028, got %h", dut.CSRmtvec);
            $fatal;
        end
        if (dut.CSRmcause !== 32'd2 || dut.CSRmepc !== 32'd28) begin
            $display("FAIL: final mret trap state mcause=%h mepc=%h", dut.CSRmcause, dut.CSRmepc);
            $fatal;
        end

        check_reg(5, 32'd40);
        check_reg(6, 32'd2);
        check_reg(7, 32'd28);
        check_reg(10, 32'd24);

        $display("PASS: mret trap program recorded causes and returned through mepc");
        $display("PASS: tb_program_mret_trap passed");
        $finish;
    end

endmodule
