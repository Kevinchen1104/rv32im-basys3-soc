`timescale 1ns / 1ps

// Testbench: tb_uart_mmio
// Purpose: Checks a local MMIO peripheral, UART, timer, GPIO, or decoder block.
// Checks: CPU-visible UART MMIO status/data behavior and handshakes.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_uart_mmio;

    reg clock = 0;
    reg reset = 1;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;
    wire [31:0] gpio_outputs;
    wire [7:0] uart_tx_data;
    wire uart_tx_valid;
    reg uart_tx_ready = 1'b0;
    wire [7:0] uart_rx_data = 8'hab;
    wire uart_rx_valid = 1'b1;
    wire uart_rx_overrun = 1'b1;
    wire uart_rx_ready;

    integer tx_seen = 0;
    integer rx_ready_seen = 0;
    reg [7:0] captured_tx_data = 8'h00;

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
        .gpio_inputs(32'h0),
        .gpio_outputs(gpio_outputs),
        .uart_tx_data(uart_tx_data),
        .uart_tx_valid(uart_tx_valid),
        .uart_tx_ready(uart_tx_ready),
        .uart_rx_data(uart_rx_data),
        .uart_rx_valid(uart_rx_valid),
        .uart_rx_overrun(uart_rx_overrun),
        .uart_rx_ready(uart_rx_ready)
    );

    always #5 clock = ~clock;

    always @(posedge clock) begin
        if (!reset && uart_tx_valid && uart_tx_ready) begin
            tx_seen <= tx_seen + 1;
            captured_tx_data <= uart_tx_data;
        end
        if (uart_rx_ready) begin
            rx_ready_seen <= rx_ready_seen + 1;
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
        #100000;
        $fatal(1, "UART MMIO test timed out");
    end

    initial begin
        $dumpfile("results/waveforms/tb_uart_mmio.vcd");
        $dumpvars(0, tb_uart_mmio);
        #1;

        for (i = 0; i < 1024; i = i + 1) begin
            dut.IMemory[i] = 32'h0000_0013;
            dut.DMemory[i] = 32'h0;
        end

        reset = 1'b1;
        @(negedge clock);
        reset = 1'b0;

        dut.IMemory[0] = i_type(12'd768, 5'd0, 3'b000, 5'd1, 7'b0010011);  // addi x1, x0, 0x300
        dut.IMemory[1] = i_type(12'd772, 5'd0, 3'b000, 5'd2, 7'b0010011);  // addi x2, x0, 0x304
        dut.IMemory[2] = i_type(12'd776, 5'd0, 3'b000, 5'd3, 7'b0010011);  // addi x3, x0, 0x308
        dut.IMemory[3] = i_type(12'h041, 5'd0, 3'b000, 5'd4, 7'b0010011);  // addi x4, x0, 'A'
        dut.IMemory[4] = s_type(12'd0, 5'd4, 5'd1, 3'b010, 7'b0100011);  // sw x4, 0(x1)
        dut.IMemory[5] = i_type(12'd0, 5'd3, 3'b010, 5'd5, 7'b0000011);  // lw x5, 0(x3)
        dut.IMemory[6] = i_type(12'd0, 5'd2, 3'b010, 5'd6, 7'b0000011);  // lw x6, 0(x2)
        dut.IMemory[7] = i_type(12'd0, 5'd2, 3'b100, 5'd7, 7'b0000011);  // lbu x7, 0(x2)
        dut.IMemory[8] = i_type(12'd0, 5'd3, 3'b010, 5'd8, 7'b0000011); // status after TX handshake
        dut.IMemory[9] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        wait (
            dut.EXMEMValid &&
            (dut.EXMEMPC == 32'd16) &&
            dut.uart_tx_pipeline_stall
        );
        repeat (4) begin
            @(posedge clock);
            #1;
            if (!dut.uart_tx_pipeline_stall ||
                (dut.EXMEMPC !== 32'd16) ||
                (tx_seen !== 0)) begin
                $display("FAIL: busy UART TX store was not held without side effects");
                $fatal;
            end
        end
        uart_tx_ready = 1'b1;

        repeat (180) @(posedge clock);
        #1;

        if (tx_seen !== 1) begin
            $display("FAIL: expected one UART TX valid pulse, got %0d", tx_seen);
            $fatal;
        end
        if (captured_tx_data !== 8'h41) begin
            $display("FAIL: UART TX expected 41, got %h", captured_tx_data);
            $fatal;
        end
        if (rx_ready_seen !== 2) begin
            $display("FAIL: expected two UART RX ready pulses, got %0d", rx_ready_seen);
            $fatal;
        end

        check_reg(5, 32'h0000_0005); // TX slot occupied by the preceding store
        check_reg(6, 32'h0000_00ab);
        check_reg(7, 32'h0000_00ab);
        check_reg(8, 32'h0000_0007); // TX slot available after ready/valid transfer

        if (dut.DMemory[192] !== 32'h0 || dut.DMemory[193] !== 32'h0 || dut.DMemory[194] !== 32'h0) begin
            $display("FAIL: UART MMIO access should not write backing DMemory");
            $fatal;
        end

        if (dut.DCacheMissCount !== 32'd0) begin
            $display("FAIL: UART MMIO access should bypass D-cache misses, got %0d", dut.DCacheMissCount);
            $fatal;
        end

        $display("PASS: tb_uart_mmio passed");
        $finish;
    end

endmodule
