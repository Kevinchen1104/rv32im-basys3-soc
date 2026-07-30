`timescale 1ns / 1ps

// Testbench: tb_gpio_mmio
// Purpose: Checks a local MMIO peripheral, UART, timer, GPIO, or decoder block.
// Checks: GPIO MMIO input/output windows and D-cache bypass behavior.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_gpio_mmio;

    reg clock = 0;
    reg reset = 0;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;
    wire [31:0] gpio_outputs;
    reg [31:0] gpio_inputs = 32'h1234_abcd;

    RISCVCPU dut (
        .clock(clock),
        .reset(reset),
        .imem_addr(),
        .imem_read(),
        .imem_rdata(128'h0),
        .imem_ready(1'b0),
        .dmem_addr(),
        .dmem_read(),
        .dmem_write(),
        .dmem_wdata(),
        .dmem_byte_enable(),
        .dmem_rdata(128'h0),
        .dmem_ready(1'b0),
        .debug_status(debug_status),
        .debug_pc(debug_pc),
        .gpio_inputs(gpio_inputs),
        .gpio_outputs(gpio_outputs),
        .uart_tx_data(),
        .uart_tx_valid(),
        .uart_tx_ready(1'b1),
        .uart_rx_data(8'h00),
        .uart_rx_valid(1'b0),
        .uart_rx_overrun(1'b0),
        .uart_rx_ready()
    );

    always #5 clock = ~clock;

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

    function [31:0] s_type;
        input [11:0] imm;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] funct3;
        input [6:0] opcode;
        begin
            s_type = {imm[11:5], rs2, rs1, funct3, imm[4:0], opcode};
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
        $dumpfile("wave/tb_gpio_mmio.vcd");
        $dumpvars(0, tb_gpio_mmio);

        for (i = 0; i < 1024; i = i + 1) begin
            dut.IMemory[i] = 32'h0000_0013;
            dut.DMemory[i] = 32'h0;
        end

        reset = 1'b1;
        @(posedge clock);
        #1;
        reset = 1'b0;

        dut.IMemory[0] = i_type(12'd512, 5'd0, 3'b000, 5'd1, 7'b0010011);  // addi x1, x0, 0x200
        dut.IMemory[1] = i_type(12'd516, 5'd0, 3'b000, 5'd2, 7'b0010011);  // addi x2, x0, 0x204
        dut.IMemory[2] = i_type(12'h05a, 5'd0, 3'b000, 5'd3, 7'b0010011);  // addi x3, x0, 0x05a
        dut.IMemory[3] = s_type(12'd0, 5'd3, 5'd1, 3'b010, 7'b0100011);  // sw x3, 0(x1)
        dut.IMemory[4] = i_type(12'd0, 5'd1, 3'b010, 5'd4, 7'b0000011);  // lw x4, 0(x1)
        dut.IMemory[5] = i_type(12'h012, 5'd0, 3'b000, 5'd5, 7'b0010011);  // addi x5, x0, 0x012
        dut.IMemory[6] = s_type(12'd1, 5'd5, 5'd1, 3'b000, 7'b0100011);  // sb x5, 1(x1)
        dut.IMemory[7] = i_type(12'd0, 5'd1, 3'b010, 5'd6, 7'b0000011);  // lw x6, 0(x1)
        dut.IMemory[8] = i_type(12'd0, 5'd2, 3'b010, 5'd7, 7'b0000011);  // lw x7, 0(x2)
        dut.IMemory[9] = i_type(12'd2, 5'd2, 3'b101, 5'd8, 7'b0000011);  // lhu x8, 2(x2)
        dut.IMemory[10] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        repeat (180) @(posedge clock);
        #1;

        if (gpio_outputs !== 32'h0000_125a) begin
            $display("FAIL: gpio_outputs expected 0000125a, got %h", gpio_outputs);
            $fatal;
        end

        check_reg(4, 32'h0000_005a);
        check_reg(6, 32'h0000_125a);
        check_reg(7, 32'h1234_abcd);
        check_reg(8, 32'h0000_1234);

        if (dut.DMemory[128] !== 32'h0 || dut.DMemory[129] !== 32'h0) begin
            $display("FAIL: GPIO MMIO access should not write backing DMemory");
            $fatal;
        end

        if (dut.DCacheMissCount !== 32'd0) begin
            $display("FAIL: GPIO MMIO access should bypass D-cache misses, got %0d", dut.DCacheMissCount);
            $fatal;
        end

        $display("PASS: tb_gpio_mmio passed");
        $finish;
    end

endmodule
