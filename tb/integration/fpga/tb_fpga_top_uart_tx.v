`timescale 1ns / 1ps

// Testbench: tb_fpga_top_uart_tx
// Purpose: Exercises an FPGA-facing simulation wrapper or UART boot path.
// Checks: FPGA top internal UART TX serializes MMIO data.
// Pass condition: Wrapper outputs, UART transcript, GPIO/status signals, or boot markers match expected values before
//   timeout.
// Does not prove: Wrapper-level UART TX simulation only; no board serial proof.
// Boundary: Simulation wrapper evidence only; not timing closure or physical board validation.

module tb_fpga_top_uart_tx;

    reg clock = 0;
    reg reset = 0;
    wire [7:0] leds;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;
    wire uart_tx;

    RISCVCPU_fpga_top #(
        .PROGRAM_HEX(""),
        .PROGRAM_WORD_COUNT(0),
        .UART_TX_CLKS_PER_BIT(4),
        .DONE_PC(32'd16)
    ) dut (
        .clock(clock),
        .reset(reset),
        .gpio_inputs(32'h0),
        .gpio_outputs(),
        .uart_tx_ready(1'b1),
        .uart_rx_data(8'h00),
        .uart_rx_valid(1'b0),
        .uart_tx_data(),
        .uart_tx_valid(),
        .uart_tx(uart_tx),
        .uart_rx_ready(),
        .leds(leds),
        .debug_status(debug_status),
        .debug_pc(debug_pc)
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

    task check_uart_bit;
        input expected;
        input integer count;
        integer i;
        begin
            for (i = 0; i < count; i = i + 1) begin
                #1;
                if (uart_tx !== expected) begin
                    $display("FAIL: uart_tx expected %b, got %b", expected, uart_tx);
                    $fatal;
                end
                @(posedge clock);
            end
        end
    endtask

    initial begin
        $dumpfile("wave/tb_fpga_top_uart_tx.vcd");
        $dumpvars(0, tb_fpga_top_uart_tx);

        dut.valid_config.cpu.IMemory[0] = i_type(12'd768, 5'd0, 3'b000, 5'd1, 7'b0010011);  // addi x1, x0, 0x300
        dut.valid_config.cpu.IMemory[1] = i_type(12'h041, 5'd0, 3'b000, 5'd2, 7'b0010011);  // addi x2, x0, 'A'
        dut.valid_config.cpu.IMemory[2] = s_type(12'd0, 5'd2, 5'd1, 3'b010, 7'b0100011);  // sw x2, 0(x1)
        dut.valid_config.cpu.IMemory[3] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        reset = 1'b1;
        repeat (2) @(posedge clock);
        #1;
        reset = 1'b0;

        wait (uart_tx === 1'b0);
        @(posedge clock);

        check_uart_bit(1'b0, 3);  // remaining start-bit cycles
        check_uart_bit(1'b1, 4);  // bit 0
        check_uart_bit(1'b0, 4);  // bit 1
        check_uart_bit(1'b0, 4);  // bit 2
        check_uart_bit(1'b0, 4);  // bit 3
        check_uart_bit(1'b0, 4);  // bit 4
        check_uart_bit(1'b0, 4);  // bit 5
        check_uart_bit(1'b1, 4);  // bit 6
        check_uart_bit(1'b0, 4);  // bit 7
        check_uart_bit(1'b1, 4);  // stop bit

        $display("PASS: fpga top internal UART TX serialized MMIO data");
        $display("PASS: tb_fpga_top_uart_tx passed");
        $finish;
    end

endmodule
