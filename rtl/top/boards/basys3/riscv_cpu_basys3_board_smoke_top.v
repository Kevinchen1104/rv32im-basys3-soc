`timescale 1ns / 1ps

// Module: RISCVCPU_basys3_board_smoke_top
// Role: Small Basys3 board-smoke target for lightweight CPU execution evidence.
// Interface: Basys3 clock/reset button, switches, LEDs, and idle USB-UART pins for shared constraints.
// Key behavior: Runs a minimal RV32I CPU smoke profile from internal memory and exposes pass/fail/done/status on LEDs.
// Non-goals: This does not replace the full Basys3 SoC top, does not exercise control-flow/trap features, and is not physical-board validation by itself.

module RISCVCPU_basys3_board_smoke_top #(
    parameter MEMORY_WORD_COUNT = 128,
    parameter PROGRAM_HEX = "firmware/hex/showcase/board_smoke.hex",
    parameter PROGRAM_WORD_COUNT = 7,
    parameter HEARTBEAT_COUNTER_BIT = 23,
    parameter [31:0] DONE_PC = 32'd24,
    parameter [31:0] EXPECTED_STATUS = 32'h600d_cafe
) (
    input clk,
    input btnC,
    input RsRx,
    output RsTx,
    input [15:0] sw,
    output [15:0] led
);

    localparam [7:0] DONE_CAPTURE_DELAY_CYCLES = 8'd16;
    localparam HEARTBEAT_CONFIG_VALID =
        (HEARTBEAT_COUNTER_BIT >= 0) && (HEARTBEAT_COUNTER_BIT <= 31);
    localparam SAFE_HEARTBEAT_COUNTER_BIT =
        HEARTBEAT_CONFIG_VALID ? HEARTBEAT_COUNTER_BIT : 0;
    localparam WRAPPER_CONFIG_VALID =
        (MEMORY_WORD_COUNT >= 1) &&
        (PROGRAM_WORD_COUNT >= 1) &&
        (PROGRAM_WORD_COUNT <= MEMORY_WORD_COUNT) &&
        HEARTBEAT_CONFIG_VALID;

    (* ASYNC_REG = "TRUE" *) reg cpu_reset_meta = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg cpu_reset_sync = 1'b1;
    reg [31:0] heartbeat_counter = 32'd0;
    (* ASYNC_REG = "TRUE" *) reg [15:0] sw_meta = 16'h0000;
    (* ASYNC_REG = "TRUE" *) reg [15:0] sw_sync = 16'h0000;

    wire [31:0] debug_status;
    wire [31:0] debug_pc;
    wire [31:0] gpio_outputs;
    wire done_hit;
    wire heartbeat;
    wire cpu_config_error;
    wire core_reset = cpu_reset_sync || !WRAPPER_CONFIG_VALID || cpu_config_error;

    reg done_pc_seen = 1'b0;
    reg [7:0] done_capture_delay = 8'd0;
    reg done_latched = 1'b0;
    reg pass_latched = 1'b0;
    reg fail_latched = 1'b0;
    reg [31:0] latched_debug_status = 32'd0;
    reg [31:0] latched_gpio_outputs = 32'd0;

    always @(posedge clk or posedge btnC) begin
        if (btnC) begin
            cpu_reset_meta <= 1'b1;
            cpu_reset_sync <= 1'b1;
        end else begin
            cpu_reset_meta <= 1'b0;
            cpu_reset_sync <= cpu_reset_meta;
        end
    end

    always @(posedge clk or posedge btnC) begin
        if (btnC) begin
            sw_meta <= 16'h0000;
            sw_sync <= 16'h0000;
        end else begin
            sw_meta <= sw;
            sw_sync <= sw_meta;
        end
    end

    always @(posedge clk or posedge btnC) begin
        if (btnC) begin
            heartbeat_counter <= 32'd0;
        end else if (cpu_reset_sync) begin
            heartbeat_counter <= 32'd0;
        end else begin
            heartbeat_counter <= heartbeat_counter + 32'd1;
        end
    end

    always @(posedge clk or posedge btnC) begin
        if (btnC) begin
            done_pc_seen <= 1'b0;
            done_capture_delay <= 8'd0;
            done_latched <= 1'b0;
            pass_latched <= 1'b0;
            fail_latched <= 1'b0;
            latched_debug_status <= 32'd0;
            latched_gpio_outputs <= 32'd0;
        end else if (cpu_reset_sync) begin
            done_pc_seen <= 1'b0;
            done_capture_delay <= 8'd0;
            done_latched <= 1'b0;
            pass_latched <= 1'b0;
            fail_latched <= 1'b0;
            latched_debug_status <= 32'd0;
            latched_gpio_outputs <= 32'd0;
        end else if (!done_latched) begin
            if (!done_pc_seen && done_hit) begin
                done_pc_seen <= 1'b1;
                done_capture_delay <= DONE_CAPTURE_DELAY_CYCLES;
            end else if (done_pc_seen) begin
                if (done_capture_delay != 8'd0) begin
                    done_capture_delay <= done_capture_delay - 8'd1;
                end else begin
                    done_latched <= 1'b1;
                    pass_latched <= (debug_status == EXPECTED_STATUS);
                    fail_latched <= (debug_status != EXPECTED_STATUS);
                    latched_debug_status <= debug_status;
                    latched_gpio_outputs <= gpio_outputs;
                end
            end
        end
    end

    RISCVCPU #(
        .MEMORY_WORD_COUNT(MEMORY_WORD_COUNT),
        .INIT_PROGRAM_HEX(PROGRAM_HEX),
        .INIT_PROGRAM_WORD_COUNT(PROGRAM_WORD_COUNT),
        .ENABLE_RV32M(0),
        .ENABLE_ACCELERATORS(0),
        .ENABLE_MACHINE_TIMER(0),
        .ENABLE_ICACHE(0),
        .ENABLE_DCACHE(0),
        .ENABLE_BRANCH_PREDICTOR(0),
        .ENABLE_PERF_COUNTERS(0),
        .ENABLE_CONTROL_REDIRECTS(0),
        .ENABLE_CSR_TRAPS(0)
    ) cpu (
        .clock(clk),
        .reset(core_reset),
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
        .trace_valid(),
        .trace_pc(),
        .trace_instruction(),
        .trace_rd(),
        .trace_reg_write(),
        .trace_writeback_value(),
        .perf_cycle_count(),
        .perf_retired_count(),
        .perf_branch_miss_count(),
        .perf_icache_miss_count(),
        .perf_dcache_miss_count(),
        .perf_stall_cycle_count(),
        .perf_matvec_start_count(),
        .perf_matvec_done_count(),
        .perf_matvec_busy_cycle_count(),
        .gpio_inputs({16'h0000, sw_sync}),
        .gpio_outputs(gpio_outputs),
        .uart_tx_data(),
        .uart_tx_valid(),
        .uart_tx_ready(1'b1),
        .uart_rx_data(8'h00),
        .uart_rx_valid(1'b0),
        .uart_rx_overrun(1'b0),
        .uart_rx_ready(),
        .config_error(cpu_config_error)
    );

    assign done_hit = !core_reset && (debug_pc == DONE_PC);
    assign heartbeat = HEARTBEAT_CONFIG_VALID ?
        heartbeat_counter[SAFE_HEARTBEAT_COUNTER_BIT] : 1'b0;

    assign led[0] = pass_latched;
    assign led[1] = !WRAPPER_CONFIG_VALID || cpu_config_error || fail_latched;
    assign led[2] = done_latched;
    assign led[3] = heartbeat;
    assign led[7:4] = done_latched ? DONE_PC[5:2] : debug_pc[5:2];
    assign led[15:8] = done_latched ? (latched_debug_status[7:0] | latched_gpio_outputs[7:0]) :
                                      (debug_status[7:0] | gpio_outputs[7:0]);
    assign RsTx = RsRx | 1'b1;

endmodule
