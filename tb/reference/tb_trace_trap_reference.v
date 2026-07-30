`timescale 1ns / 1ps

// Testbench: tb_trace_trap_reference
// Purpose: Compares DUT behavior against deterministic local reference or signature fixtures.
// Checks: Observable retired trace order and wrong-path trace suppression for a directed trap-entry and mret-return
//   program.
// Pass condition: DUT outputs match the generated expected fixture or signature and no mismatch or timeout occurs.
// Does not prove: This validates observable retire trace behavior for a directed trap/mret program; it is not a
//   complete architectural trace spec, not formal verification, and not full privileged ISA compliance.

module tb_trace_trap_reference;

    localparam TRACE_COUNT = 8;
    localparam PROGRAM_WORDS = 15;
    localparam WRONG_PATH_COUNT = 4;
    localparam NOP = 32'h00000013;

    reg clock = 0;
    reg reset = 0;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;
    wire trace_valid;
    wire [31:0] trace_pc;
    wire [31:0] trace_instruction;
    wire [4:0] trace_rd;
    wire trace_reg_write;
    wire [31:0] trace_writeback_value;

    reg [127:0] expected_trace [0:TRACE_COUNT-1];
    reg [31:0] wrong_path_pc [0:WRONG_PATH_COUNT-1];
    reg [31:0] expected_pc;
    reg [31:0] expected_instruction;
    reg [31:0] expected_meta;
    reg [31:0] expected_value;
    reg expected_reg_write;
    reg [4:0] expected_rd;
    reg completion_seen = 1'b0;
    integer trace_events = 0;
    integer init_index;
    integer wrong_index;

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
        .gpio_inputs(32'h0),
        .gpio_outputs(),
        .uart_tx_ready(1'b1),
        .uart_rx_data(8'h00),
        .uart_rx_valid(1'b0),
        .uart_rx_overrun(1'b0),
        .uart_tx_data(),
        .uart_tx_valid(),
        .uart_rx_ready(),
        .debug_status(debug_status),
        .debug_pc(debug_pc),
        .trace_valid(trace_valid),
        .trace_pc(trace_pc),
        .trace_instruction(trace_instruction),
        .trace_rd(trace_rd),
        .trace_reg_write(trace_reg_write),
        .trace_writeback_value(trace_writeback_value)
    );

    always #5 clock = ~clock;

    task check_trace_row;
        input integer index;
        begin
            {expected_pc, expected_instruction, expected_meta, expected_value} = expected_trace[index];
            expected_reg_write = expected_meta[5];
            expected_rd = expected_meta[4:0];

            if (trace_pc !== expected_pc ||
                trace_instruction !== expected_instruction ||
                trace_reg_write !== expected_reg_write ||
                (expected_reg_write && (trace_rd !== expected_rd)) ||
                (expected_reg_write && (trace_writeback_value !== expected_value))) begin
                $display("FAIL: trace_trap_reference[%0d] expected pc=%h ir=%h reg_write=%b rd=%0d value=%h, got pc=%h ir=%h reg_write=%b rd=%0d value=%h",
                         index,
                         expected_pc,
                         expected_instruction,
                         expected_reg_write,
                         expected_rd,
                         expected_value,
                         trace_pc,
                         trace_instruction,
                         trace_reg_write,
                         trace_rd,
                         trace_writeback_value);
                $fatal;
            end
        end
    endtask

    task check_wrong_path_pc;
        begin
            for (wrong_index = 0; wrong_index < WRONG_PATH_COUNT; wrong_index = wrong_index + 1) begin
                if (trace_pc === wrong_path_pc[wrong_index]) begin
                    $display("FAIL: wrong-path PC %h appeared in retired trace", trace_pc);
                    $fatal;
                end
            end
        end
    endtask

    task check_final_state;
        begin
            if (dut.Regs[30] !== 32'h0000_07ad) begin
                $display("FAIL: final marker x30 expected 000007ad, got %h", dut.Regs[30]);
                $fatal;
            end
            if (dut.Regs[8] !== 32'd8 || dut.Regs[9] !== 32'd9 ||
                dut.Regs[10] !== 32'd10 || dut.Regs[11] !== 32'd11) begin
                $display("FAIL: wrong-path registers changed x8=%h x9=%h x10=%h x11=%h",
                         dut.Regs[8], dut.Regs[9], dut.Regs[10], dut.Regs[11]);
                $fatal;
            end
        end
    endtask

    always @(posedge clock) begin
        #1;
        if (!reset && completion_seen) begin
            check_final_state();
            $display("PASS: trace trap reference matched %0d retired events", TRACE_COUNT);
            $display("PASS: wrong-path trap/mret PCs were suppressed from retired trace");
            $display("PASS: tb_trace_trap_reference passed");
            $finish;
        end

        if (!reset && trace_valid) begin
            check_wrong_path_pc();

            if (trace_events >= TRACE_COUNT) begin
                $display("FAIL: unexpected extra trace event pc=%h ir=%h reg_write=%b rd=%0d value=%h",
                         trace_pc, trace_instruction, trace_reg_write, trace_rd, trace_writeback_value);
                $fatal;
            end

            check_trace_row(trace_events);
            trace_events = trace_events + 1;

            if (trace_events == TRACE_COUNT) begin
                completion_seen = 1'b1;
            end
        end
    end

    initial begin
        $dumpfile("wave/tb_trace_trap_reference.vcd");
        $dumpvars(0, tb_trace_trap_reference);

        for (init_index = 0; init_index < 1024; init_index = init_index + 1) begin
            dut.IMemory[init_index] = NOP;
            dut.DMemory[init_index] = 32'h0;
        end

        $readmemh("fixtures/generated/reference/trace_trap_reference.hex", dut.IMemory, 0, PROGRAM_WORDS-1);
        $readmemh("fixtures/generated/reference/trace_trap_reference_expected.hex", expected_trace, 0, TRACE_COUNT-1);
        $readmemh("fixtures/generated/reference/trace_trap_reference_wrong_path.hex", wrong_path_pc, 0, WRONG_PATH_COUNT-1);

        reset = 1'b1;
        repeat (2) @(posedge clock);
        reset = 1'b0;

        repeat (260) @(posedge clock);

        $display("FAIL: expected %0d trace events, got %0d", TRACE_COUNT, trace_events);
        $fatal;
    end

endmodule
