`timescale 1ns / 1ps

// Checks: Compares the CPU public retired trace stream against a local RV32IM software reference fixture for selected
//   ALU/immediate, x0, control-flow, memory, and RV32M rows.

module tb_trace_lockstep_reference;

    localparam MAX_TRACE_COUNT = 4096;
    localparam TIMEOUT_CYCLES = 2500;

    reg clock = 0;
    reg reset = 1;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;
    wire trace_valid;
    wire [31:0] trace_pc;
    wire [31:0] trace_instruction;
    wire [4:0] trace_rd;
    wire trace_reg_write;
    wire [31:0] trace_writeback_value;

    reg [127:0] expected_trace [0:MAX_TRACE_COUNT-1];
    reg [31:0] expected_pc;
    reg [31:0] expected_instruction;
    reg [31:0] expected_meta;
    reg [31:0] expected_value;
    reg expected_reg_write;
    reg [4:0] expected_rd;
    reg [1023:0] program_hex_path;
    reg [1023:0] expected_trace_path;
    reg [2047:0] line_buffer;
    integer program_file;
    integer expected_file;
    integer line_status;
    integer program_word_count = 0;
    integer expected_trace_count = 0;
    integer plusarg_trace_count = 0;
    integer trace_events = 0;

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
                $display("FAIL: trace_lockstep_reference[%0d] expected pc=%h ir=%h reg_write=%b rd=%0d value=%h, got pc=%h ir=%h reg_write=%b rd=%0d value=%h",
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

    task count_expected_trace_rows;
        begin
            expected_trace_count = 0;
            expected_file = $fopen(expected_trace_path, "r");
            if (expected_file == 0) begin
                $display("FAIL: could not open expected trace file %0s", expected_trace_path);
                $fatal;
            end

            while (!$feof(expected_file)) begin
                line_buffer = 0;
                line_status = $fgets(line_buffer, expected_file);
                if (line_status > 0 && line_buffer != 0) begin
                    expected_trace_count = expected_trace_count + 1;
                end
            end
            $fclose(expected_file);
        end
    endtask

    task count_program_words;
        begin
            program_word_count = 0;
            program_file = $fopen(program_hex_path, "r");
            if (program_file == 0) begin
                $display("FAIL: could not open program hex file %0s", program_hex_path);
                $fatal;
            end

            while (!$feof(program_file)) begin
                line_buffer = 0;
                line_status = $fgets(line_buffer, program_file);
                if (line_status > 0 && line_buffer != 0) begin
                    program_word_count = program_word_count + 1;
                end
            end
            $fclose(program_file);
        end
    endtask

    // Compare only retired trace events; bubbles, stalls, and non-retiring cycles are outside the fixture stream.
    always @(posedge clock) begin
        #1;
        if (!reset && trace_valid) begin
            if (trace_events >= expected_trace_count) begin
                $display("FAIL: unexpected extra trace event pc=%h ir=%h reg_write=%b rd=%0d value=%h",
                         trace_pc, trace_instruction, trace_reg_write, trace_rd, trace_writeback_value);
                $fatal;
            end

            check_trace_row(trace_events);
            trace_events = trace_events + 1;

            if (trace_events == expected_trace_count) begin
                $display("PASS: trace lockstep reference matched %0d retired events", expected_trace_count);
                $display("PASS: tb_trace_lockstep_reference passed");
                $finish;
            end
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_trace_lockstep_reference.vcd");
        $dumpvars(0, tb_trace_lockstep_reference);
        #1; // Initialize test memory after the DUT initial block.

        program_hex_path = "fixtures/generated/reference/trace_lockstep_reference.hex";
        expected_trace_path = "fixtures/generated/reference/trace_lockstep_expected.hex";
        if (!$value$plusargs("program_hex=%s", program_hex_path)) begin
            program_hex_path = "fixtures/generated/reference/trace_lockstep_reference.hex";
        end
        if (!$value$plusargs("expected_trace=%s", expected_trace_path)) begin
            expected_trace_path = "fixtures/generated/reference/trace_lockstep_expected.hex";
        end

        count_program_words();
        count_expected_trace_rows();
        if ($value$plusargs("trace_count=%d", plusarg_trace_count)) begin
            if (plusarg_trace_count != expected_trace_count)
                $fatal(1, "trace_count does not match the complete reference trace");
        end
        if (expected_trace_count <= 0 || expected_trace_count > MAX_TRACE_COUNT) begin
            $display("FAIL: invalid expected trace count %0d", expected_trace_count);
            $fatal;
        end

        if (program_word_count <= 0 || program_word_count > 1024) begin
            $display("FAIL: invalid program word count %0d", program_word_count);
            $fatal;
        end

        $readmemh(program_hex_path, dut.IMemory, 0, program_word_count - 1);
        $readmemh(expected_trace_path, expected_trace, 0, expected_trace_count - 1);

        reset = 1'b1;
        repeat (2) @(negedge clock);
        reset = 1'b0;

        repeat (TIMEOUT_CYCLES) @(posedge clock);

        $display("FAIL: expected %0d trace events, got %0d", expected_trace_count, trace_events);
        $fatal;
    end

endmodule
