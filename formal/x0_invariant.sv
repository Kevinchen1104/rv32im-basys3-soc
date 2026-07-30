`default_nettype none

module x0_invariant;
    (* gclk *) reg clock;
    reg reset = 1'b1;

    wire [31:0] imem_addr;
    wire imem_read;
    wire [31:0] dmem_addr;
    wire dmem_read;
    wire dmem_write;
    wire [127:0] dmem_wdata;
    wire [15:0] dmem_byte_enable;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;
    wire trace_valid;
    wire [31:0] trace_pc;
    wire [31:0] trace_instruction;
    wire [4:0] trace_rd;
    wire trace_reg_write;
    wire [31:0] trace_writeback_value;
    wire [31:0] perf_cycle_count;
    wire [31:0] perf_retired_count;
    wire [31:0] perf_branch_miss_count;
    wire [31:0] perf_icache_miss_count;
    wire [31:0] perf_dcache_miss_count;
    wire [31:0] perf_stall_cycle_count;
    wire [31:0] gpio_outputs;
    wire [7:0] uart_tx_data;
    wire uart_tx_valid;
    wire uart_rx_ready;

    RISCVCPU dut (
        .clock(clock),
        .reset(reset),
        .imem_addr(imem_addr),
        .imem_read(imem_read),
        .imem_rdata(128'h0),
        .imem_ready(1'b0),
        .dmem_addr(dmem_addr),
        .dmem_read(dmem_read),
        .dmem_write(dmem_write),
        .dmem_wdata(dmem_wdata),
        .dmem_byte_enable(dmem_byte_enable),
        .dmem_rdata(128'h0),
        .dmem_ready(1'b0),
        .debug_status(debug_status),
        .debug_pc(debug_pc),
        .trace_valid(trace_valid),
        .trace_pc(trace_pc),
        .trace_instruction(trace_instruction),
        .trace_rd(trace_rd),
        .trace_reg_write(trace_reg_write),
        .trace_writeback_value(trace_writeback_value),
        .perf_cycle_count(perf_cycle_count),
        .perf_retired_count(perf_retired_count),
        .perf_branch_miss_count(perf_branch_miss_count),
        .perf_icache_miss_count(perf_icache_miss_count),
        .perf_dcache_miss_count(perf_dcache_miss_count),
        .perf_stall_cycle_count(perf_stall_cycle_count),
        .gpio_inputs(32'h0),
        .gpio_outputs(gpio_outputs),
        .uart_tx_data(uart_tx_data),
        .uart_tx_valid(uart_tx_valid),
        .uart_tx_ready(1'b1),
        .uart_rx_data(8'h00),
        .uart_rx_valid(1'b0),
        .uart_rx_overrun(1'b0),
        .uart_rx_ready(uart_rx_ready)
    );

    reg past_valid = 1'b0;
    reg [3:0] active_cycles = 4'd0;
    reg retirement_seen = 1'b0;

    always @(posedge clock) begin
        past_valid <= 1'b1;
        reset <= 1'b0;

        if (reset) begin
            active_cycles <= 4'd0;
            retirement_seen <= 1'b0;
        end else begin
            if (active_cycles < 4'd10) begin
                active_cycles <= active_cycles + 4'd1;
            end
            if (trace_valid) begin
                retirement_seen <= 1'b1;
            end
        end

        if (past_valid && !reset) begin
            assert(!(trace_valid && trace_reg_write && (trace_rd == 5'd0)));
            cover(trace_valid);
            if (active_cycles == 4'd10) begin
                assert(retirement_seen || trace_valid);
            end
        end
    end
endmodule

`default_nettype wire
