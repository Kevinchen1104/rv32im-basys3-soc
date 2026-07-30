`timescale 1ns / 1ps

// Testbench: tb_program_csr_trap
// Purpose: Runs CPU firmware to exercise the selected machine-mode CSR/trap subset.
// Checks: Assembled CSR/trap program records exception causes and PCs.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/csr_trap/csr_trap.hex

module tb_program_csr_trap;

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
        $dumpfile("wave/tb_program_csr_trap.vcd");
        $dumpvars(0, tb_program_csr_trap);

        reset_cpu();
        $readmemh("firmware/hex/csr_trap/csr_trap.hex", dut.IMemory, 0, 19);

        run_cycles(760);

        check_memory_word(0, 32'd11);
        check_memory_word(1, 32'd16);
        check_memory_word(2, 32'd3);
        check_memory_word(3, 32'd20);
        check_memory_word(4, 32'd2);
        check_memory_word(5, 32'd24);
        check_memory_word(6, 32'd4);
        check_memory_word(7, 32'd28);
        check_memory_word(8, 32'd6);
        check_memory_word(9, 32'd32);

        if (dut.CSRmtvec !== 32'd52) begin
            $display("FAIL: mtvec expected 00000034, got %h", dut.CSRmtvec);
            $fatal;
        end
        if (dut.CSRmcause !== 32'd6 || dut.CSRmepc !== 32'd32) begin
            $display("FAIL: final CSR trap state mcause=%h mepc=%h", dut.CSRmcause, dut.CSRmepc);
            $fatal;
        end

        $display("PASS: CSR trap program recorded exception causes and PCs");
        $display("PASS: tb_program_csr_trap passed");
        $finish;
    end

endmodule
