`timescale 1ns / 1ps

// Checks: RV32M multiply, divide, and remainder instruction behavior including directed edge cases.
// Firmware: firmware/hex/examples/muldiv_ops.hex

module tb_program_muldiv;

`include "tb_common.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_muldiv.vcd");
        $dumpvars(0, tb_program_muldiv);

        reset_cpu();
        $readmemh("firmware/hex/examples/muldiv_ops.hex", dut.IMemory, 0, 21);

        run_cycles(900);

        check_reg(3, 32'hffff_ffeb);
        check_reg(4, 32'hffff_ffff);
        check_reg(5, 32'hffff_ffff);
        check_reg(6, 32'h0000_0006);
        check_reg(7, 32'hffff_fffe);
        check_reg(8, 32'h0000_0000);
        check_reg(9, 32'h0000_0001);
        check_reg(10, 32'h0000_0007);
        check_reg(13, 32'h8000_0000);
        check_reg(14, 32'h0000_0000);
        check_reg(16, 32'hffff_ffff);
        check_reg(17, 32'hffff_ffff);
        check_reg(18, 32'h0000_0007);
        check_reg(19, 32'h0000_0007);
        check_reg(20, 32'hffff_ffeb);

        $display("PASS: loaded RV32M program executed multiply/divide operations");
        $display("PASS: tb_program_muldiv passed");
        $finish;
    end

endmodule
