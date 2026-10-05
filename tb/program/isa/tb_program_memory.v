`timescale 1ns / 1ps

// Checks: Assembled word/subword memory operations and unsigned branches.
// Firmware: firmware/hex/examples/memory_unsigned.hex

module tb_program_memory;

`include "tb_common.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_memory.vcd");
        $dumpvars(0, tb_program_memory);
        reset_cpu();

        $readmemh("firmware/hex/examples/memory_unsigned.hex", dut.IMemory, 0, 13);
        dut.DMemory[0] = 32'h80ff_7f01;
        dut.DMemory[21] = 32'h1357_9bdf;  // address 84 evicts the dirty line at address 20

        run_cycles(300);

        check_reg(1, 32'hffff_ffff);
        check_reg(2, 32'h0000_00ff);
        check_reg(3, 32'hffff_80ff);
        check_reg(4, 32'h0000_80ff);
        check_reg(5, 32'h80ff_00ff);
        check_reg(6, 32'd6);
        check_reg(7, 32'd7);
        check_reg(9, 32'h1357_9bdf);
        check_reg(10, 32'd1);

        if (dut.DMemory[5] !== 32'h80ff_00ff) begin
            $display("FAIL: subword output expected DMemory[5] = %h, got %h",
                     32'h80ff_00ff, dut.DMemory[5]);
            $fatal;
        end

        $display("PASS: loaded memory program wrote subwords and followed unsigned branches");
        $display("PASS: tb_program_memory passed");
        $finish;
    end

endmodule
