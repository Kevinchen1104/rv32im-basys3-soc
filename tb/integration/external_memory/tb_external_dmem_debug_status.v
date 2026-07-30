`timescale 1ns / 1ps

// Testbench: tb_external_dmem_debug_status
// Purpose: Exercises the CPU external-memory integration boundary in simulation.
// Checks: Runs board_smoke with USE_EXTERNAL_DMEM=1, checks external DMem read/write traffic, verifies the public
//   debug_status latch reports the pass marker from a committed store to byte address 0x100, and confirms internal
//   DMemory is not the external-DMEM observation point.
// Pass condition: Observed external-memory traffic, public status, and checked memory contents match expectations.
//   board validation.
// Firmware: firmware/hex/showcase/board_smoke.hex

module tb_external_dmem_debug_status;

    reg clock = 0;
    reg reset = 0;
    wire [31:0] dmem_addr;
    wire dmem_read;
    wire dmem_write;
    wire [127:0] dmem_wdata;
    wire [15:0] dmem_byte_enable;
    wire [127:0] dmem_rdata;
    wire dmem_ready;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;

    integer dmem_read_count = 0;
    integer dmem_write_count = 0;

    RISCVCPU #(
        .MEMORY_WORD_COUNT(128),
        .INIT_PROGRAM_HEX("firmware/hex/showcase/board_smoke.hex"),
        .INIT_PROGRAM_WORD_COUNT(7),
        .USE_EXTERNAL_DMEM(1)
    ) cpu (
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

    external_dmem_bram #(
        .WORD_COUNT(128)
    ) dmem (
        .clock(clock),
        .reset(reset),
        .dmem_addr(dmem_addr),
        .dmem_read(dmem_read),
        .dmem_write(dmem_write),
        .dmem_wdata(dmem_wdata),
        .dmem_byte_enable(dmem_byte_enable),
        .dmem_rdata(dmem_rdata),
        .dmem_ready(dmem_ready),
        .read_seen(),
        .write_seen()
    );

    always #5 clock = ~clock;

    always @(posedge clock) begin
        if (dmem_read) begin
            dmem_read_count <= dmem_read_count + 1;
        end
        if (dmem_write) begin
            dmem_write_count <= dmem_write_count + 1;
            if (dmem_byte_enable !== 16'hffff) begin
                $display("FAIL: expected full-line write-back byte enable, got %h",
                         dmem_byte_enable);
                $fatal;
            end
        end
    end

    task check_reg;
        input [4:0] reg_id;
        input [31:0] expected;
        begin
            if (cpu.Regs[reg_id] !== expected) begin
                $display("FAIL: x%0d expected %h, got %h", reg_id, expected, cpu.Regs[reg_id]);
                $fatal;
            end
            $display("PASS: x%0d = %h", reg_id, cpu.Regs[reg_id]);
        end
    endtask

    initial begin
        $dumpfile("wave/tb_external_dmem_debug_status.vcd");
        $dumpvars(0, tb_external_dmem_debug_status);

        reset = 1'b1;
        repeat (2) @(posedge clock);
        #1;
        reset = 1'b0;

        repeat (360) @(posedge clock);
        #1;

        check_reg(5, 32'd256);
        check_reg(6, 32'h600d_cafe);
        check_reg(8, 32'h0);

        if (debug_status !== 32'h600d_cafe) begin
            $display("FAIL: external-DMEM debug_status expected %h, got %h",
                     32'h600d_cafe, debug_status);
            $fatal;
        end

        if (dmem.memory[64] !== 32'h600d_cafe) begin
            $display("FAIL: external DMem memory[64] expected %h, got %h",
                     32'h600d_cafe, dmem.memory[64]);
            $fatal;
        end

        if (cpu.DMemory[64] !== 32'h0) begin
            $display("FAIL: internal DMemory should remain unused with external DMEM, got %h",
                     cpu.DMemory[64]);
            $fatal;
        end

        if (debug_pc !== 32'd24) begin
            $display("FAIL: expected debug_pc = %h, got %h", 32'd24, debug_pc);
            $fatal;
        end

        if (dmem_read_count == 0 || dmem_write_count == 0) begin
            $display("FAIL: expected external DMem read/write traffic, read=%0d write=%0d",
                     dmem_read_count, dmem_write_count);
            $fatal;
        end

        $display("PASS: external-DMEM public debug_status latched committed status store");
        $display("PASS: tb_external_dmem_debug_status passed");
        $finish;
    end

endmodule
