`timescale 1ns / 1ps

// Module: basys3_lowfreq_clock_gen
// Role: Generates the low-frequency clock used by the full-feature Basys3 SoC target.
// Interface: Accepts the 100 MHz board clock and active-high reset; outputs a 6.25 MHz clock and lock status.
// Key behavior: Vivado uses an MMCME2_BASE with buffered feedback/output; portable tools use a deterministic divide-by-16 model.
// Non-goals: The portable fallback is for simulation and generic synthesis smoke, not the Basys3 bitstream clock network.

module basys3_lowfreq_clock_gen (
    input clk,
    input reset,
    output soc_clk,
    output locked
);

`ifdef XILINX_VIVADO

    wire mmcm_feedback;
    wire mmcm_feedback_buffered;
    wire mmcm_soc_clk;

    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(8.0),
        .CLKFBOUT_PHASE(0.0),
        .CLKIN1_PERIOD(10.0),
        .CLKOUT0_DIVIDE_F(128.0),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT0_PHASE(0.0),
        .DIVCLK_DIVIDE(1),
        .STARTUP_WAIT("FALSE")
    ) mmcm (
        .CLKFBOUT(mmcm_feedback),
        .CLKOUT0(mmcm_soc_clk),
        .LOCKED(locked),
        .CLKFBIN(mmcm_feedback_buffered),
        .CLKIN1(clk),
        .PWRDWN(1'b0),
        .RST(reset)
    );

    BUFG feedback_buffer (
        .I(mmcm_feedback),
        .O(mmcm_feedback_buffered)
    );

    BUFG soc_clock_buffer (
        .I(mmcm_soc_clk),
        .O(soc_clk)
    );

`else

    localparam [4:0] LOCK_DELAY_CYCLES = 5'd16;

    reg [2:0] divide_count = 3'd0;
    reg soc_clk_reg = 1'b0;
    reg [4:0] lock_count = 5'd0;
    reg locked_reg = 1'b0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            divide_count <= 3'd0;
            soc_clk_reg <= 1'b0;
            lock_count <= 5'd0;
            locked_reg <= 1'b0;
        end else begin
            if (divide_count == 3'd7) begin
                divide_count <= 3'd0;
                soc_clk_reg <= ~soc_clk_reg;
            end else begin
                divide_count <= divide_count + 3'd1;
            end

            if (!locked_reg) begin
                if (lock_count == LOCK_DELAY_CYCLES - 1'b1) begin
                    locked_reg <= 1'b1;
                end else begin
                    lock_count <= lock_count + 5'd1;
                end
            end
        end
    end

    assign soc_clk = soc_clk_reg;
    assign locked = locked_reg;

`endif

endmodule
