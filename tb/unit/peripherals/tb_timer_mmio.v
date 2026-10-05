`timescale 1ns / 1ps

// Testbench: tb_timer_mmio
// Purpose: Checks a local MMIO peripheral, UART, timer, GPIO, or decoder block.
// Checks: CPU load/store traffic selects the 0x800 machine-timer MMIO window, reads and writes mtime/mtimecmp halves,
//   bypasses D-cache, exposes the registered timer pending bit through mip.MTIP, and leaves unrelated GPIO/UART
//   MMIO behavior intact.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_timer_mmio;
    reg clock = 0;
    reg reset = 1;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;
    wire [31:0] gpio_outputs;
    wire [7:0] uart_tx_data;
    wire uart_tx_valid;
    wire uart_tx_ready = 1'b1;
    wire [7:0] uart_rx_data = 8'h00;
    wire uart_rx_valid = 1'b0;
    wire uart_rx_ready;

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
        .uart_rx_overrun(1'b0),
        .uart_rx_ready(uart_rx_ready)
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

    function [31:0] u_type;
        input [19:0] imm;
        input [4:0] rd;
        input [6:0] opcode;
        begin
            u_type = {imm, rd, opcode};
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
        end
    endtask

    integer i;

    initial begin
        $dumpfile("results/waveforms/tb_timer_mmio.vcd");
        $dumpvars(0, tb_timer_mmio);
        #1; // Initialize test memory after the DUT initial block.

        for (i = 0; i < 1024; i = i + 1) begin
            dut.IMemory[i] = 32'h0000_0013;
            dut.DMemory[i] = 32'h0;
        end

        reset = 1'b1;
        @(posedge clock);
        #1;
        reset = 1'b0;

        dut.IMemory[0] = u_type(20'h00001, 5'd1, 7'b0110111);              // lui x1, 0x1
        dut.IMemory[1] = i_type(12'h800, 5'd1, 3'b000, 5'd1, 7'b0010011);  // addi x1, x1, -2048 -> 0x800
        dut.IMemory[2] = i_type(12'd0, 5'd0, 3'b000, 5'd2, 7'b0010011);    // x2 = 0
        dut.IMemory[3] = s_type(12'd12, 5'd2, 5'd1, 3'b010, 7'b0100011);   // sw x2, mtimecmp high
        dut.IMemory[4] = i_type(12'd96, 5'd0, 3'b000, 5'd3, 7'b0010011);   // x3 = 96
        dut.IMemory[5] = s_type(12'd8, 5'd3, 5'd1, 3'b010, 7'b0100011);    // sw x3, mtimecmp low
        dut.IMemory[6] = i_type(12'd8, 5'd1, 3'b010, 5'd4, 7'b0000011);    // lw x4, mtimecmp low
        dut.IMemory[7] = s_type(12'd4, 5'd2, 5'd1, 3'b010, 7'b0100011);    // sw x2, mtime high
        dut.IMemory[8] = i_type(12'd32, 5'd0, 3'b000, 5'd6, 7'b0010011);   // x6 = 32
        dut.IMemory[9] = s_type(12'd0, 5'd6, 5'd1, 3'b010, 7'b0100011);    // sw x6, mtime low
        dut.IMemory[10] = i_type(12'd0, 5'd1, 3'b010, 5'd7, 7'b0000011);   // lw x7, mtime low
        dut.IMemory[11] = i_type(12'h200, 5'd0, 3'b000, 5'd8, 7'b0010011); // x8 = GPIO output
        dut.IMemory[12] = i_type(12'ha5, 5'd0, 3'b000, 5'd9, 7'b0010011);  // x9 = 0xa5
        dut.IMemory[13] = s_type(12'd0, 5'd9, 5'd8, 3'b010, 7'b0100011);   // sw x9, GPIO
        dut.IMemory[14] = i_type(12'd8, 5'd1, 3'b010, 5'd10, 7'b0000011);  // lw x10, mtimecmp low
        dut.IMemory[15] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        repeat (260) @(posedge clock);
        #1;

        check_reg(1, 32'h0000_0800);
        check_reg(4, 32'd96);
        check_reg(10, 32'd96);

        if (^dut.Regs[7] === 1'bx || dut.Regs[7] < 32'd32) begin
            $display("FAIL: mtime read should be at least written value, got %h", dut.Regs[7]);
            $fatal;
        end
        if (dut.gen_machine_timer.timer.mtimecmp_low_read_data !== 32'd96 ||
            dut.gen_machine_timer.timer.mtimecmp_high_read_data !== 32'd0) begin
            $display("FAIL: timer mtimecmp readback low=%h high=%h",
                     dut.gen_machine_timer.timer.mtimecmp_low_read_data,
                     dut.gen_machine_timer.timer.mtimecmp_high_read_data);
            $fatal;
        end
        if (dut.DMemory[512] !== 32'h0 ||
            dut.DMemory[513] !== 32'h0 ||
            dut.DMemory[514] !== 32'h0 ||
            dut.DMemory[515] !== 32'h0) begin
            $display("FAIL: timer MMIO access should not write backing DMemory");
            $fatal;
        end
        if (dut.DCacheMissCount !== 32'd0) begin
            $display("FAIL: timer/GPIO MMIO should bypass D-cache misses, got %0d", dut.DCacheMissCount);
            $fatal;
        end
        if (gpio_outputs !== 32'h0000_00a5 || dut.GPIOOutput !== 32'h0000_00a5) begin
            $display("FAIL: unrelated GPIO MMIO expected a5, gpio_outputs=%h GPIOOutput=%h",
                     gpio_outputs,
                     dut.GPIOOutput);
            $fatal;
        end
        if (uart_tx_valid !== 1'b0 || uart_tx_data !== 8'h00) begin
            $display("FAIL: timer/GPIO MMIO unexpectedly drove UART valid=%0b data=%h",
                     uart_tx_valid,
                     uart_tx_data);
            $fatal;
        end

        // Pin the local timer near a threshold after the software MMIO slice
        // has completed. The first edge reaches the threshold but retains the
        // prior low sample; the second edge publishes pending through CSR mip.
        @(negedge clock);
        dut.gen_machine_timer.timer.mtime = 64'd50;
        dut.gen_machine_timer.timer.mtimecmp = 64'd51;
        dut.gen_machine_timer.timer.timer_irq_pending = 1'b0;
        @(posedge clock);
        #1;
        if (dut.timer_irq_pending !== 1'b0 || dut.CSRmip[7] !== 1'b0) begin
            $display("FAIL: threshold edge exposed MTIP before registered sample irq=%0b mip=%h",
                     dut.timer_irq_pending, dut.CSRmip);
            $fatal;
        end
        @(posedge clock);
        #1;
        if (dut.timer_irq_pending !== 1'b1 || dut.CSRmip[7] !== 1'b1) begin
            $display("FAIL: registered timer pending did not reach mip.MTIP irq=%0b mip=%h",
                     dut.timer_irq_pending, dut.CSRmip);
            $fatal;
        end
        @(negedge clock);
        dut.gen_machine_timer.timer.mtimecmp = 64'd100;
        @(posedge clock);
        #1;
        if (dut.timer_irq_pending !== 1'b0 || dut.CSRmip[7] !== 1'b0) begin
            $display("FAIL: postponed comparison did not clear registered mip.MTIP irq=%0b mip=%h",
                     dut.timer_irq_pending, dut.CSRmip);
            $fatal;
        end

        $display("PASS: timer MMIO and registered mip.MTIP integration checked");
        $display("PASS: tb_timer_mmio passed");
        $finish;
    end
endmodule
