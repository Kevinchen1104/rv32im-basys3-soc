`timescale 1ns / 1ps

// Testbench: tb_external_dmem
// Purpose: Exercises the CPU external-memory integration boundary in simulation.
// Checks: Data load/store traffic and one-count-per-transaction D-cache misses through the external data memory interface.
// Pass condition: Observed external-memory traffic, public status, and checked memory contents match expectations.

module tb_external_dmem;

    reg clock = 0;
    reg reset = 1;
    wire [31:0] dmem_addr;
    wire dmem_read;
    wire dmem_write;
    wire [127:0] dmem_wdata;
    wire [15:0] dmem_byte_enable;
    reg [127:0] dmem_rdata = 128'h0;
    wire dmem_ready = dmem_read || dmem_write;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;
    wire [31:0] perf_dcache_miss_count;

    reg [127:0] line0 = {32'h3333_3333, 32'h2222_2222, 32'h1111_1111, 32'h0000_0007};
    reg [127:0] line4 = {32'h7777_7777, 32'h6666_6666, 32'h5555_5555, 32'h0000_0055};
    integer dmem_read_count = 0;
    integer dmem_write_count = 0;

    RISCVCPU #(
        .USE_EXTERNAL_DMEM(1)
    ) dut (
        .clock(clock),
        .reset(reset),
        .imem_addr(),
        .imem_read(),
        .imem_rdata(128'h0),
        .imem_ready(1'b0),
        .dmem_addr(dmem_addr),
        .dmem_read(dmem_read),
        .dmem_write(dmem_write),
        .dmem_wdata(dmem_wdata),
        .dmem_byte_enable(dmem_byte_enable),
        .dmem_rdata(dmem_rdata),
        .dmem_ready(dmem_ready),
        .debug_status(debug_status),
        .debug_pc(debug_pc),
        .perf_dcache_miss_count(perf_dcache_miss_count),
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
        case (dmem_addr)
            32'h0000_0000: dmem_rdata = line0;
            32'h0000_0040: dmem_rdata = line4;
            default: dmem_rdata = 128'h0;
        endcase
    end

    always @(posedge clock) begin
        if (dmem_read) begin
            dmem_read_count <= dmem_read_count + 1;
        end

        if (dmem_write) begin
            dmem_write_count <= dmem_write_count + 1;
            if (dmem_addr == 32'h0000_0000) begin
                line0 <= dmem_wdata;
            end
            if (dmem_byte_enable !== 16'hffff) begin
                $display("FAIL: D-cache line write-back expected full byte enable, got %h",
                         dmem_byte_enable);
                $fatal;
            end
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
        $dumpfile("results/waveforms/tb_external_dmem.vcd");
        $dumpvars(0, tb_external_dmem);
        #1; // Initialize test memory after the DUT initial block.

        for (i = 0; i < 1024; i = i + 1) begin
            dut.IMemory[i] = 32'h0000_0013;
            dut.DMemory[i] = 32'h0;
        end

        dut.IMemory[0] = i_type(12'd0, 5'd0, 3'b010, 5'd1, 7'b0000011);    // lw x1, 0(x0)
        dut.IMemory[1] = i_type(12'd5, 5'd1, 3'b000, 5'd2, 7'b0010011);    // addi x2, x1, 5
        dut.IMemory[2] = s_type(12'd0, 5'd2, 5'd0, 3'b010, 7'b0100011);    // sw x2, 0(x0)
        dut.IMemory[3] = i_type(12'd64, 5'd0, 3'b000, 5'd3, 7'b0010011);   // addi x3, x0, 64
        dut.IMemory[4] = i_type(12'd0, 5'd3, 3'b010, 5'd4, 7'b0000011);    // lw x4, 0(x3)
        dut.IMemory[5] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        reset = 1'b1;
        repeat (2) @(posedge clock);
        #1;
        reset = 1'b0;

        repeat (220) @(posedge clock);
        #1;

        check_reg(1, 32'd7);
        check_reg(2, 32'd12);
        check_reg(4, 32'h55);

        if (line0[31:0] !== 32'd12) begin
            $display("FAIL: external DMemory line0 expected write-back word0 = 12, got %h",
                     line0[31:0]);
            $fatal;
        end

        if (dut.DMemory[0] !== 32'h0) begin
            $display("FAIL: internal DMemory should remain unused in external DMEM test");
            $fatal;
        end

        if (dmem_read_count < 2 || dmem_write_count == 0) begin
            $display("FAIL: external DMEM expected reads and a dirty write-back, reads=%0d writes=%0d",
                     dmem_read_count, dmem_write_count);
            $fatal;
        end

        if (perf_dcache_miss_count !== 32'd2) begin
            $display("FAIL: expected exactly two accepted D-cache misses, got %0d",
                     perf_dcache_miss_count);
            $fatal;
        end

        $display("PASS: tb_external_dmem passed");
        $finish;
    end

endmodule
