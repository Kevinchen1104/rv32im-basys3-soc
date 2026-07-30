`timescale 1ns / 1ps

// Testbench: tb_fpga_top_config_error
// Purpose: Exercises an FPGA-facing simulation wrapper or UART boot path.
// Checks: Invalid memory/init/UART/heartbeat profiles, one-word bounds, and external-memory/cache combinations.
// Pass condition: Wrapper outputs, UART transcript, GPIO/status signals, or boot markers match expected values before
//   timeout.
// Does not prove: Parameter validation only.
// Boundary: Simulation wrapper evidence only; not timing closure or physical board validation.

module tb_fpga_top_config_error;

    reg clock = 0;
    reg reset = 0;

    wire small_memory_config_error;
    wire small_memory_done;
    wire small_memory_smoke_pass;
    wire small_memory_smoke_fail;
    wire [7:0] small_memory_leds;
    wire [31:0] small_memory_debug_status;
    wire [31:0] small_memory_debug_pc;

    wire long_program_config_error;
    wire long_program_done;
    wire long_program_smoke_pass;
    wire long_program_smoke_fail;
    wire [7:0] long_program_leds;
    wire [31:0] long_program_debug_status;
    wire [31:0] long_program_debug_pc;
    wire external_imem_without_icache_error;
    wire external_dmem_without_dcache_error;
    wire partial_line_external_dmem_error;
    wire external_dmem_bram_depth_error;
    wire external_dmem_init_count_error;
    wire core_init_count_error;
    wire invalid_uart_boot_error;
    wire invalid_bram_soc_boot_error;
    wire invalid_runtime_soc_boot_error;
    wire invalid_heartbeat_error;
    wire invalid_uart_divisor_error;
    wire one_word_core_config_error;

    RISCVCPU_fpga_top #(
        .MEMORY_WORD_COUNT(64)
    ) small_memory_dut (
        .clock(clock),
        .reset(reset),
        .gpio_inputs(32'h0),
        .gpio_outputs(),
        .uart_tx_ready(1'b1),
        .uart_rx_data(8'h00),
        .uart_rx_valid(1'b0),
        .uart_tx_data(),
        .uart_tx_valid(),
        .uart_rx_ready(),
        .leds(small_memory_leds),
        .done(small_memory_done),
        .smoke_pass(small_memory_smoke_pass),
        .smoke_fail(small_memory_smoke_fail),
        .heartbeat(),
        .config_error(small_memory_config_error),
        .debug_flags(),
        .debug_status(small_memory_debug_status),
        .debug_pc(small_memory_debug_pc)
    );

    RISCVCPU_fpga_top #(
        .MEMORY_WORD_COUNT(128),
        .PROGRAM_WORD_COUNT(129)
    ) long_program_dut (
        .clock(clock),
        .reset(reset),
        .gpio_inputs(32'h0),
        .gpio_outputs(),
        .uart_tx_ready(1'b1),
        .uart_rx_data(8'h00),
        .uart_rx_valid(1'b0),
        .uart_tx_data(),
        .uart_tx_valid(),
        .uart_rx_ready(),
        .leds(long_program_leds),
        .done(long_program_done),
        .smoke_pass(long_program_smoke_pass),
        .smoke_fail(long_program_smoke_fail),
        .heartbeat(),
        .config_error(long_program_config_error),
        .debug_flags(),
        .debug_status(long_program_debug_status),
        .debug_pc(long_program_debug_pc)
    );

    RISCVCPU #(
        .USE_EXTERNAL_IMEM(1),
        .ENABLE_ICACHE(0)
    ) external_imem_without_icache_dut (
        .clock(clock),
        .reset(reset),
        .imem_rdata(128'h0),
        .imem_ready(1'b0),
        .dmem_rdata(128'h0),
        .dmem_ready(1'b0),
        .gpio_inputs(32'h0),
        .uart_tx_ready(1'b1),
        .uart_rx_data(8'h0),
        .uart_rx_valid(1'b0),
        .uart_rx_overrun(1'b0),
        .config_error(external_imem_without_icache_error)
    );

    RISCVCPU #(
        .USE_EXTERNAL_DMEM(1),
        .ENABLE_DCACHE(0)
    ) external_dmem_without_dcache_dut (
        .clock(clock),
        .reset(reset),
        .imem_rdata(128'h0),
        .imem_ready(1'b0),
        .dmem_rdata(128'h0),
        .dmem_ready(1'b0),
        .gpio_inputs(32'h0),
        .uart_tx_ready(1'b1),
        .uart_rx_data(8'h0),
        .uart_rx_valid(1'b0),
        .uart_rx_overrun(1'b0),
        .config_error(external_dmem_without_dcache_error)
    );

    RISCVCPU #(
        .MEMORY_WORD_COUNT(6),
        .USE_EXTERNAL_DMEM(1)
    ) partial_line_external_dmem_dut (
        .clock(clock),
        .reset(reset),
        .imem_rdata(128'h0),
        .imem_ready(1'b0),
        .dmem_rdata(128'h0),
        .dmem_ready(1'b0),
        .gpio_inputs(32'h0),
        .uart_tx_ready(1'b1),
        .uart_rx_data(8'h0),
        .uart_rx_valid(1'b0),
        .uart_rx_overrun(1'b0),
        .config_error(partial_line_external_dmem_error)
    );

    RISCVCPU #(
        .MEMORY_WORD_COUNT(4),
        .INIT_PROGRAM_HEX("fixtures/memory/bram_init.hex"),
        .INIT_PROGRAM_WORD_COUNT(8)
    ) invalid_init_count_core_dut (
        .clock(clock),
        .reset(reset),
        .imem_rdata(128'h0),
        .imem_ready(1'b0),
        .dmem_rdata(128'h0),
        .dmem_ready(1'b0),
        .gpio_inputs(32'h0),
        .uart_tx_ready(1'b1),
        .uart_rx_data(8'h0),
        .uart_rx_valid(1'b0),
        .uart_rx_overrun(1'b0),
        .config_error(core_init_count_error)
    );

    external_dmem_bram #(
        .WORD_COUNT(6)
    ) external_dmem_bram_depth_dut (
        .clock(clock),
        .reset(reset),
        .dmem_addr(32'h0),
        .dmem_read(1'b0),
        .dmem_write(1'b0),
        .dmem_wdata(128'h0),
        .dmem_byte_enable(16'h0),
        .dmem_rdata(),
        .dmem_ready(),
        .config_error(external_dmem_bram_depth_error),
        .read_seen(),
        .write_seen()
    );

    external_dmem_bram #(
        .WORD_COUNT(4),
        .SIM_INIT_HEX("fixtures/memory/bram_init.hex"),
        .SIM_INIT_WORD_COUNT(8)
    ) external_dmem_bram_init_count_dut (
        .clock(clock),
        .reset(reset),
        .dmem_addr(32'h0),
        .dmem_read(1'b0),
        .dmem_write(1'b0),
        .dmem_wdata(128'h0),
        .dmem_byte_enable(16'h0),
        .dmem_rdata(),
        .dmem_ready(),
        .config_error(external_dmem_init_count_error),
        .read_seen(),
        .write_seen()
    );

    RISCVCPU_uart_boot_fpga_top #(
        .MEMORY_WORD_COUNT(64),
        .UART_RX_CLKS_PER_BIT(8),
        .UART_TX_CLKS_PER_BIT(8)
    ) invalid_uart_boot_dut (
        .clock(clock),
        .reset(reset),
        .uart_rx(1'b1),
        .gpio_inputs(32'h0),
        .boot_error(invalid_uart_boot_error)
    );

    RISCVCPU_uart_boot_bram_soc_top #(
        .MEMORY_WORD_COUNT(64),
        .UART_RX_CLKS_PER_BIT(8),
        .UART_TX_CLKS_PER_BIT(8)
    ) invalid_bram_soc_dut (
        .clock(clock),
        .reset(reset),
        .uart_rx(1'b1),
        .gpio_inputs(32'h0),
        .boot_error(invalid_bram_soc_boot_error)
    );

    RISCVCPU_uart_boot_runtime_soc_top #(
        .MEMORY_WORD_COUNT(64),
        .UART_RX_CLKS_PER_BIT(8),
        .UART_TX_CLKS_PER_BIT(8)
    ) invalid_runtime_soc_dut (
        .clock(clock),
        .reset(reset),
        .uart_rx(1'b1),
        .gpio_inputs(32'h0),
        .boot_error(invalid_runtime_soc_boot_error)
    );

    RISCVCPU_fpga_top #(
        .MEMORY_WORD_COUNT(128),
        .HEARTBEAT_COUNTER_BIT(32)
    ) invalid_heartbeat_dut (
        .clock(clock),
        .reset(reset),
        .gpio_inputs(32'h0),
        .uart_tx_ready(1'b1),
        .uart_rx_data(8'h00),
        .uart_rx_valid(1'b0),
        .config_error(invalid_heartbeat_error)
    );

    RISCVCPU_uart_boot_runtime_soc_top #(
        .MEMORY_WORD_COUNT(128),
        .UART_RX_CLKS_PER_BIT(0),
        .UART_TX_CLKS_PER_BIT(8)
    ) invalid_uart_divisor_dut (
        .clock(clock),
        .reset(reset),
        .uart_rx(1'b1),
        .gpio_inputs(32'h0),
        .boot_error(invalid_uart_divisor_error)
    );

    RISCVCPU #(
        .MEMORY_WORD_COUNT(1),
        .ENABLE_ICACHE(0),
        .ENABLE_DCACHE(0)
    ) one_word_core_dut (
        .clock(clock),
        .reset(reset),
        .imem_rdata(128'h0),
        .imem_ready(1'b0),
        .dmem_rdata(128'h0),
        .dmem_ready(1'b0),
        .gpio_inputs(32'h0),
        .uart_tx_ready(1'b1),
        .uart_rx_data(8'h0),
        .uart_rx_valid(1'b0),
        .uart_rx_overrun(1'b0),
        .config_error(one_word_core_config_error)
    );

    always #5 clock = ~clock;

    initial begin
        $dumpfile("wave/tb_fpga_top_config_error.vcd");
        $dumpvars(0, tb_fpga_top_config_error);

        reset = 1'b1;
        repeat (2) @(posedge clock);
        reset = 1'b0;

        repeat (20) @(posedge clock);
        #1;

        if (small_memory_config_error !== 1'b1) begin
            $display("FAIL: wrapper should reject MEMORY_WORD_COUNT below debug status word");
            $fatal;
        end

        if (small_memory_debug_status !== 32'h0 || small_memory_debug_pc !== 32'h0) begin
            $display("FAIL: invalid small-memory config should drive safe debug outputs");
            $fatal;
        end

        if (small_memory_done !== 1'b0 ||
            small_memory_smoke_pass !== 1'b0 ||
            small_memory_smoke_fail !== 1'b0 ||
            small_memory_leds !== 8'h00) begin
            $display("FAIL: invalid small-memory config should not report smoke completion");
            $fatal;
        end

        if (long_program_config_error !== 1'b1) begin
            $display("FAIL: wrapper should reject PROGRAM_WORD_COUNT above memory depth");
            $fatal;
        end

        if (long_program_debug_status !== 32'h0 || long_program_debug_pc !== 32'h0) begin
            $display("FAIL: invalid long-program config should drive safe debug outputs");
            $fatal;
        end

        if (long_program_done !== 1'b0 ||
            long_program_smoke_pass !== 1'b0 ||
            long_program_smoke_fail !== 1'b0 ||
            long_program_leds !== 8'h00) begin
            $display("FAIL: invalid long-program config should not report smoke completion");
            $fatal;
        end

        if (!external_imem_without_icache_error ||
            !external_dmem_without_dcache_error ||
            !partial_line_external_dmem_error ||
            !external_dmem_bram_depth_error ||
            !core_init_count_error ||
            !external_dmem_init_count_error) begin
            $display(
                "FAIL: core/memory parameter errors imem=%b dmem=%b partial_core=%b partial_bram=%b core_init=%b dmem_init=%b",
                external_imem_without_icache_error,
                external_dmem_without_dcache_error,
                partial_line_external_dmem_error,
                external_dmem_bram_depth_error,
                core_init_count_error,
                external_dmem_init_count_error
            );
            $fatal;
        end

        if (!invalid_uart_boot_error ||
            !invalid_bram_soc_boot_error ||
            !invalid_runtime_soc_boot_error ||
            !invalid_uart_boot_dut.wrapper_config_error ||
            !invalid_uart_boot_dut.soc_cpu_reset ||
            !invalid_bram_soc_dut.integration_config_error ||
            !invalid_bram_soc_dut.soc_cpu_reset ||
            !invalid_runtime_soc_dut.integration_config_error ||
            !invalid_runtime_soc_dut.soc_cpu_reset) begin
            $display(
                "FAIL: UART boot tops should reject <=64 words simple=%b bram=%b runtime=%b",
                invalid_uart_boot_error,
                invalid_bram_soc_boot_error,
                invalid_runtime_soc_boot_error
            );
            $fatal;
        end

        if (!invalid_heartbeat_error ||
            !invalid_uart_divisor_error ||
            !invalid_heartbeat_dut.config_error ||
            invalid_heartbeat_dut.heartbeat !== 1'b0 ||
            !invalid_uart_divisor_dut.wrapper_config_error ||
            !invalid_uart_divisor_dut.soc_cpu_reset) begin
            $display(
                "FAIL: wrappers should reject heartbeat/UART divisors heartbeat=%b uart=%b",
                invalid_heartbeat_error,
                invalid_uart_divisor_error
            );
            $fatal;
        end

        if (one_word_core_config_error !== 1'b0) begin
            $display("FAIL: MEMORY_WORD_COUNT=1 should remain a supported core configuration");
            $fatal;
        end
        force one_word_core_dut.IDEXPC = 32'h0000_0000;
        force one_word_core_dut.EXMEMALUOut = 32'h0000_0000;
        #1;
        if (!one_word_core_dut.instruction_address_in_range ||
            !one_word_core_dut.exmem_data_address_in_range) begin
            $display("FAIL: one-word core rejected byte address zero");
            $fatal;
        end
        force one_word_core_dut.IDEXPC = 32'h0000_0004;
        force one_word_core_dut.EXMEMALUOut = 32'h0000_0004;
        #1;
        if (one_word_core_dut.instruction_address_in_range ||
            one_word_core_dut.exmem_data_address_in_range) begin
            $display("FAIL: one-word core accepted byte address four");
            $fatal;
        end
        release one_word_core_dut.IDEXPC;
        release one_word_core_dut.EXMEMALUOut;

        $display("PASS: FPGA/core/memory blocks reported invalid parameter combinations");
        $display("PASS: tb_fpga_top_config_error passed");
        $finish;
    end

endmodule
