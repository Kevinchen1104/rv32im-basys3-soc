`timescale 1ns / 1ps

// Testbench: tb_arch_test_signature
// Purpose: Compares DUT behavior against deterministic local reference or signature fixtures.
// Checks: Local arch-test-style signature comparison, tohost status detection, and optional DUT signature export
//   plumbing.
// Pass condition: DUT outputs match the generated expected fixture or signature and no mismatch or timeout occurs.
// Does not prove: Local signature harness only; not an official compliance suite, exhaustive ISA proof, timing
//   evidence, or physical board validation.

module tb_arch_test_signature;

    localparam MAX_MEMORY_WORDS = 131072;
    localparam MAX_SIGNATURE_WORDS = MAX_MEMORY_WORDS;
    localparam DEFAULT_TIMEOUT_CYCLES = 250000;
    localparam NOP = 32'h00000013;
    localparam ARCH_PASS_STATUS = 32'h600dface;
    localparam ARCH_FAIL_STATUS = 32'hbad0fade;
    localparam TOHOST_PASS_STATUS = 32'h00000001;
    localparam TOHOST_FAIL_STATUS = 32'h00000003;

    reg clock = 0;
    reg reset = 0;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;

    reg [31:0] expected_signature [0:MAX_SIGNATURE_WORDS-1];
    reg [1023:0] program_hex_path;
    reg [1023:0] expected_signature_path;
    reg [1023:0] dut_signature_path;
    reg [511:0] test_name;
    reg [2047:0] line_buffer;
    integer program_file;
    integer line_status;
    integer program_word_count = 0;
    integer signature_start_word = 0;
    integer signature_word_count = 0;
    integer tohost_word_index = -1;
    integer tohost_pass_pc = -1;
    integer tohost_fail_pc = -1;
    integer timeout_cycles = DEFAULT_TIMEOUT_CYCLES;
    integer has_expected_signature = 0;
    integer has_dut_signature_path = 0;
    integer signature_file;
    integer i;
    integer mismatch_count;
    integer cycles_elapsed;
    reg [31:0] tohost_status_value;
    reg tohost_pc_pass_seen;
    reg tohost_pc_fail_seen;

    function has_arch_test_tohost_status;
        begin
            has_arch_test_tohost_status =
                (tohost_word_index >= 0) &&
                (tohost_word_index < MAX_MEMORY_WORDS) &&
                ((dut.DMemory[tohost_word_index] === TOHOST_PASS_STATUS) ||
                 (dut.DMemory[tohost_word_index] === TOHOST_FAIL_STATUS));
        end
    endfunction

    function pc_matches_halt_loop;
        input integer base_pc;
        begin
            pc_matches_halt_loop =
                (base_pc >= 0) &&
                ((debug_pc === base_pc) ||
                 (debug_pc === (base_pc + 4)) ||
                 (debug_pc === (base_pc + 8)) ||
                 (debug_pc === (base_pc + 12)));
        end
    endfunction

    function has_arch_test_tohost_pc_status;
        begin
            has_arch_test_tohost_pc_status =
                pc_matches_halt_loop(tohost_pass_pc) ||
                pc_matches_halt_loop(tohost_fail_pc);
        end
    endfunction

    RISCVCPU #(
        .MEMORY_WORD_COUNT(MAX_MEMORY_WORDS)
    ) dut (
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
        .trace_valid(),
        .trace_pc(),
        .trace_instruction(),
        .trace_rd(),
        .trace_reg_write(),
        .trace_writeback_value()
    );

    always #5 clock = ~clock;

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

    task clear_memories;
        begin
            for (i = 0; i < MAX_MEMORY_WORDS; i = i + 1) begin
                dut.IMemory[i] = NOP;
                dut.DMemory[i] = 32'h0;
            end
        end
    endtask

    task write_dut_signature;
        begin
            if (has_dut_signature_path && signature_word_count > 0) begin
                signature_file = $fopen(dut_signature_path, "w");
                if (signature_file == 0) begin
                    $display("FAIL: could not open DUT signature output file %0s", dut_signature_path);
                    $fatal;
                end

                for (i = 0; i < signature_word_count; i = i + 1) begin
                    $fwrite(signature_file, "%08x\n", dut.DMemory[signature_start_word + i]);
                end
                $fclose(signature_file);
                $display("INFO: wrote DUT signature %0s words=%0d start_word=%0d",
                         dut_signature_path, signature_word_count, signature_start_word);
            end
        end
    endtask

    task compare_expected_signature;
        begin
            if (!has_expected_signature) begin
                $display("NO_REFERENCE: DUT ran, but no expected signature was supplied for %0s", test_name);
            end else begin
                $readmemh(expected_signature_path, expected_signature, 0, signature_word_count - 1);
                mismatch_count = 0;

                for (i = 0; i < signature_word_count; i = i + 1) begin
                    if (dut.DMemory[signature_start_word + i] !== expected_signature[i]) begin
                        $display("FAIL: signature[%0d] expected %08x got %08x",
                                 i, expected_signature[i], dut.DMemory[signature_start_word + i]);
                        mismatch_count = mismatch_count + 1;
                    end
                end

                if (mismatch_count != 0) begin
                    $fatal;
                end

                $display("PASS: arch-test signature matched %0d words for %0s",
                         signature_word_count, test_name);
            end
        end
    endtask

    initial begin
        $dumpfile("wave/tb_arch_test_signature.vcd");
        $dumpvars(0, tb_arch_test_signature);

        test_name = "arch-test";
        if (!$value$plusargs("test_name=%s", test_name)) begin
            test_name = "arch-test";
        end

        if (!$value$plusargs("program_hex=%s", program_hex_path)) begin
            $display("FAIL: missing +program_hex=<path>");
            $fatal;
        end

        has_expected_signature = $value$plusargs("expected_signature=%s", expected_signature_path);
        has_dut_signature_path = $value$plusargs("dut_signature=%s", dut_signature_path);

        if (!$value$plusargs("signature_start=%d", signature_start_word)) begin
            signature_start_word = 0;
        end
        if (!$value$plusargs("signature_words=%d", signature_word_count)) begin
            signature_word_count = 0;
        end
        if (!$value$plusargs("tohost_word=%d", tohost_word_index)) begin
            tohost_word_index = -1;
        end
        if (!$value$plusargs("tohost_pass_pc=%d", tohost_pass_pc)) begin
            tohost_pass_pc = -1;
        end
        if (!$value$plusargs("tohost_fail_pc=%d", tohost_fail_pc)) begin
            tohost_fail_pc = -1;
        end
        if (!$value$plusargs("timeout_cycles=%d", timeout_cycles)) begin
            timeout_cycles = DEFAULT_TIMEOUT_CYCLES;
        end

        count_program_words();
        if (program_word_count <= 0 || program_word_count > MAX_MEMORY_WORDS) begin
            $display("FAIL: invalid program word count %0d", program_word_count);
            $fatal;
        end

        if (signature_word_count < 0 || signature_word_count > MAX_SIGNATURE_WORDS ||
            signature_start_word < 0 ||
            signature_start_word + signature_word_count > MAX_MEMORY_WORDS) begin
            $display("FAIL: invalid signature range start=%0d words=%0d",
                     signature_start_word, signature_word_count);
            $fatal;
        end

        if (tohost_word_index >= MAX_MEMORY_WORDS) begin
            $display("FAIL: invalid tohost word index %0d", tohost_word_index);
            $fatal;
        end

        clear_memories();
        $readmemh(program_hex_path, dut.IMemory, 0, program_word_count - 1);
        $readmemh(program_hex_path, dut.DMemory, 0, program_word_count - 1);

        reset = 1'b1;
        repeat (2) @(posedge clock);
        reset = 1'b0;

        cycles_elapsed = 0;
        while (cycles_elapsed < timeout_cycles &&
               debug_status === 32'h0 &&
               !has_arch_test_tohost_status() &&
               !has_arch_test_tohost_pc_status()) begin
            @(posedge clock);
            cycles_elapsed = cycles_elapsed + 1;
        end
        #1;

        tohost_status_value = (tohost_word_index >= 0) ? dut.DMemory[tohost_word_index] : 32'h0;
        tohost_pc_pass_seen = pc_matches_halt_loop(tohost_pass_pc);
        tohost_pc_fail_seen = pc_matches_halt_loop(tohost_fail_pc);

        if (debug_status === ARCH_FAIL_STATUS ||
            tohost_status_value === TOHOST_FAIL_STATUS ||
            tohost_pc_fail_seen) begin
            $display("FAIL: arch-test program reported fail status %08x for %0s",
                     (tohost_status_value === TOHOST_FAIL_STATUS) ? tohost_status_value :
                     (tohost_pc_fail_seen ? TOHOST_FAIL_STATUS : debug_status),
                     test_name);
            $fatal;
        end

        if (debug_status !== ARCH_PASS_STATUS &&
            tohost_status_value !== TOHOST_PASS_STATUS &&
            !tohost_pc_pass_seen) begin
            $display("TIMEOUT: arch-test program did not report pass status for %0s after %0d cycles; debug_status=%08x tohost=%08x debug_pc=%08x",
                     test_name, timeout_cycles, debug_status, tohost_status_value, debug_pc);
            $fatal;
        end

        if (tohost_status_value === TOHOST_PASS_STATUS) begin
            $display("INFO: arch-test tohost pass observed for %0s at word %0d",
                     test_name, tohost_word_index);
        end
        if (tohost_pc_pass_seen) begin
            $display("INFO: arch-test tohost pass loop observed for %0s at pc %08x",
                     test_name, debug_pc);
        end

        write_dut_signature();
        compare_expected_signature();

        $display("PASS: tb_arch_test_signature completed for %0s", test_name);
        $finish;
    end

endmodule
