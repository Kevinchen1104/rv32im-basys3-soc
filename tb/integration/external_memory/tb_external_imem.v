`timescale 1ns / 1ps

// Testbench: tb_external_imem
// Purpose: Exercises the CPU external-memory integration boundary in simulation.
// Checks: Instruction fetch through the external instruction memory interface.
// Pass condition: Observed external-memory traffic, public status, and checked memory contents match expectations.

module tb_external_imem;

    reg clock = 0;
    reg reset = 0;
    wire [31:0] imem_addr;
    wire imem_read;
    reg [127:0] imem_rdata = 128'h0;
    wire imem_ready = imem_read;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;

    integer imem_read_count = 0;

    RISCVCPU #(
        .USE_EXTERNAL_IMEM(1)
    ) dut (
        .clock(clock),
        .reset(reset),
        .imem_addr(imem_addr),
        .imem_read(imem_read),
        .imem_rdata(imem_rdata),
        .imem_ready(imem_ready),
        .dmem_addr(),
        .dmem_read(),
        .dmem_write(),
        .dmem_wdata(),
        .dmem_byte_enable(),
        .dmem_rdata(128'h0),
        .dmem_ready(1'b0),
        .debug_status(debug_status),
        .debug_pc(debug_pc),
        .gpio_inputs(32'h0),
        .gpio_outputs(),
        .uart_tx_data(),
        .uart_tx_valid(),
        .uart_tx_ready(1'b1),
        .uart_rx_data(8'h00),
        .uart_rx_valid(1'b0),
        .uart_rx_overrun(1'b0),
        .uart_rx_ready()
    );

    always #5 clock = ~clock;

    always @(*) begin
        case (imem_addr)
            32'h0000_0000: imem_rdata = {
                b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011),       // beq x0, x0, 0
                i_type(12'h042, 5'd0, 3'b000, 5'd3, 7'b0010011),  // addi x3, x0, 0x42
                i_type(12'd7, 5'd1, 3'b000, 5'd2, 7'b0010011),    // addi x2, x1, 7
                i_type(12'd5, 5'd0, 3'b000, 5'd1, 7'b0010011)     // addi x1, x0, 5
            };
            default: imem_rdata = {4{32'h0000_0013}};
        endcase
    end

    always @(posedge clock) begin
        if (imem_read) begin
            imem_read_count <= imem_read_count + 1;
        end
    end

    function [31:0] i_type;
        input [11:0] imm;
        input [4:0] rs1;
        input [2:0] funct3;
        input [4:0] rd;
        input [6:0] opcode;
        begin
            i_type = {imm, rs1, funct3, rd, opcode};
        end
    endfunction

    function [31:0] b_type;
        input integer imm;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] funct3;
        input [6:0] opcode;
        reg [12:0] bimm;
        begin
            bimm = imm[12:0];
            b_type = {bimm[12], bimm[10:5], rs2, rs1, funct3, bimm[4:1], bimm[11], opcode};
        end
    endfunction

    task check_reg;
        input [4:0] reg_id;
        input [31:0] expected;
        begin
            if (dut.Regs[reg_id] !== expected) begin
                $display("FAIL: x%0d expected %h, got %h", reg_id, expected, dut.Regs[reg_id]);
                $fatal;
            end
            $display("PASS: x%0d = %h", reg_id, dut.Regs[reg_id]);
        end
    endtask

    integer i;

    initial begin
        $dumpfile("wave/tb_external_imem.vcd");
        $dumpvars(0, tb_external_imem);

        for (i = 0; i < 1024; i = i + 1) begin
            dut.IMemory[i] = 32'h0000_0013;
            dut.DMemory[i] = 32'h0;
        end

        reset = 1'b1;
        repeat (2) @(posedge clock);
        #1;
        reset = 1'b0;

        repeat (120) @(posedge clock);
        #1;

        check_reg(1, 32'd5);
        check_reg(2, 32'd12);
        check_reg(3, 32'h42);

        if (imem_read_count == 0) begin
            $display("FAIL: external IMEM interface was never read");
            $fatal;
        end

        if (dut.IMemory[0] !== 32'h0000_0013) begin
            $display("FAIL: test expected internal IMemory to remain unused NOP data");
            $fatal;
        end

        $display("PASS: tb_external_imem passed");
        $finish;
    end

endmodule
