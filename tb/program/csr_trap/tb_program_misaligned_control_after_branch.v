`timescale 1ns / 1ps

// Testbench: tb_program_misaligned_control_after_branch
// Purpose: Runs CPU firmware to check IALIGN traps when control transfers resolve on consecutive cycles.
// Checks: An isolated JALR and the same JALR entering execute right after a not-taken branch both trap with
//   mcause=0, mepc at the JALR and mtval at the misaligned target, without writing the link register or
//   executing the target; a monitor confirms the branch and JALR occupied ID/EX on consecutive cycles.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/csr_trap/misaligned_control_after_branch.hex

module tb_program_misaligned_control_after_branch;

    localparam [31:0] PASS_MARKER = 32'hc5e3_0009;
    localparam [31:0] FAIL_MARKER = 32'hbad5_0009;
    localparam [31:0] WRONG_PATH_MARKER = 32'hbad5_a009;
    localparam integer TIMEOUT_CYCLES = 5000;

    localparam PROGRAM_HEX = "firmware/hex/csr_trap/misaligned_control_after_branch.hex";
    localparam integer PROGRAM_WORD_COUNT = 69;
    `include "tb/common/tb_firmware.vh"

    // The interesting case needs the branch and the JALR in ID/EX on
    // consecutive cycles. Detect it so a layout change cannot silently turn
    // this into an isolated-JALR test.
    reg previous_was_branch = 1'b0;
    reg [31:0] previous_branch_pc = 32'h0;
    reg back_to_back_seen = 1'b0;

    always @(negedge clock) begin
        if (reset) begin
            previous_was_branch <= 1'b0;
        end else if (!dut.dcache_pipeline_stall) begin
            if (previous_was_branch && dut.IDEXValid &&
                (dut.IDEXIR[6:0] == 7'h67) && (dut.IDEXPC == previous_branch_pc + 32'd4))
                back_to_back_seen <= 1'b1;
            previous_was_branch <= dut.IDEXValid && dut.IDEXBranch;
            previous_branch_pc <= dut.IDEXPC;
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_program_misaligned_control_after_branch.vcd");
        $dumpvars(0, tb_program_misaligned_control_after_branch);

        reset = 1'b1;
        @(posedge clock);
        #1;
        reset = 1'b0;
        begin : wait_for_result
            integer cycles;
            cycles = 0;
            while (cycles < TIMEOUT_CYCLES &&
                   debug_status !== PASS_MARKER &&
                   debug_status !== FAIL_MARKER &&
                   debug_status !== WRONG_PATH_MARKER) begin
                @(posedge clock);
                #1;
                cycles = cycles + 1;
            end
            if (debug_status === WRONG_PATH_MARKER)
                $fatal(1, "FAIL: a misaligned JALR target executed instead of trapping (pc=%h)", debug_pc);
            if (debug_status === FAIL_MARKER)
                $fatal(1, "FAIL: firmware check failed at pc=%h mcause=%h mepc=%h mtval=%h count=%h",
                       debug_pc, dut.CSRmcause, dut.CSRmepc, dut.CSRmtval, dut.DMemory[0]);
            if (debug_status !== PASS_MARKER)
                $fatal(1, "FAIL: timed out after %0d cycles; status=%h pc=%h", cycles, debug_status, debug_pc);
        end

        if (!back_to_back_seen) begin
            $display("FAIL: the branch and JALR never reached ID/EX on consecutive cycles");
            $fatal;
        end
        if (dut.DMemory[0] !== 32'd2 || dut.CSRmcause !== 32'd0) begin
            $display("FAIL: final trap evidence count=%h mcause=%h", dut.DMemory[0], dut.CSRmcause);
            $fatal;
        end

        $display("PASS: tb_program_misaligned_control_after_branch passed");
        $finish;
    end

endmodule
