`timescale 1ns / 1ps

// Module: rv32m_multicycle_unit
// Role: Selectable pipelined/iterative multiply and iterative divide for RV32M.
// Interface: Accepts one funct3-selected operation and two operands, then reports busy, a completion pulse, and the result.
// Key behavior: Fast products finish three cycles after acceptance; iterative operations take 33 cycles and preserve architectural divide edge cases.

module rv32m_multicycle_unit #(
    parameter FAST_MULTIPLY = 0
) (
    input clock,
    input reset,
    input start,
    input [2:0] funct3,
    input [31:0] lhs,
    input [31:0] rhs,
    output reg busy,
    output reg done,
    output reg [31:0] result
);

    reg operation_is_divide;
    reg return_high_product;
    reg return_remainder;
    reg result_negative;
    reg remainder_negative;
    reg divide_by_zero;
    reg [31:0] original_lhs;
    reg [5:0] iteration;
    reg launch_pending;
    reg [2:0] launch_funct3;
    reg [31:0] launch_lhs;
    reg [31:0] launch_rhs;

    reg [63:0] multiply_accumulator;
    reg [63:0] multiply_multiplicand;
    reg [31:0] multiply_multiplier;

    // Signed 17-bit limbs represent either signed or unsigned 32-bit inputs.
    // Input, multiplier and output registers map to A/BREG, MREG and PREG.
    reg signed [16:0] multiply_lhs_low, multiply_lhs_high;
    reg signed [16:0] multiply_rhs_low, multiply_rhs_high;
    (* use_dsp = "yes" *) reg [31:0] product_ll, product_hh;
    (* use_dsp = "yes" *) reg signed [32:0] product_lh, product_hl;
    reg [31:0] product_ll_pipe, product_hh_pipe;
    reg signed [32:0] product_lh_pipe, product_hl_pipe;
    wire [63:0] product_term_ll = {32'b0, product_ll_pipe};
    wire [63:0] product_term_lh = {{15{product_lh_pipe[32]}}, product_lh_pipe, 16'b0};
    wire [63:0] product_term_hl = {{15{product_hl_pipe[32]}}, product_hl_pipe, 16'b0};
    wire [63:0] product_term_hh = {product_hh_pipe, 32'b0};
    // Carry-save reduction combines four terms with one final carry chain.
    wire [63:0] product_sum1 = product_term_ll ^ product_term_lh ^ product_term_hl;
    wire [63:0] product_carry1 = ((product_term_ll & product_term_lh) |
        (product_term_ll & product_term_hl) | (product_term_lh & product_term_hl)) << 1;
    wire [63:0] product_sum2 = product_sum1 ^ product_carry1 ^ product_term_hh;
    wire [63:0] product_carry2 = ((product_sum1 & product_carry1) |
        (product_sum1 & product_term_hh) | (product_carry1 & product_term_hh)) << 1;
    (* use_dsp = "no" *) wire [63:0] fast_product = product_sum2 + product_carry2;
    wire fast_multiply_active = FAST_MULTIPLY && !operation_is_divide;
    wire operation_complete = fast_multiply_active ? (iteration == 6'd1) :
                                                   (iteration == 6'd31);

    reg [31:0] divide_divisor;
    reg [31:0] divide_quotient;
    reg [32:0] divide_remainder;

    wire multiply_lhs_signed =
        (launch_funct3 == 3'b001) || (launch_funct3 == 3'b010);
    wire multiply_rhs_signed = (launch_funct3 == 3'b001);
    wire divide_signed =
        (launch_funct3 == 3'b100) || (launch_funct3 == 3'b110);
    wire [31:0] lhs_magnitude =
        ((multiply_lhs_signed || divide_signed) && launch_lhs[31]) ?
        (~launch_lhs + 32'd1) :
        launch_lhs;
    wire [31:0] rhs_magnitude =
        ((multiply_rhs_signed || divide_signed) && launch_rhs[31]) ?
        (~launch_rhs + 32'd1) :
        launch_rhs;

    wire [63:0] multiply_accumulator_next =
        multiply_accumulator +
        (multiply_multiplier[0] ? multiply_multiplicand : 64'h0);
    wire [63:0] multiply_signed_result =
        result_negative ? (~multiply_accumulator_next + 64'd1) : multiply_accumulator_next;

    wire [32:0] divide_remainder_shifted =
        {divide_remainder[31:0], divide_quotient[31]};
    wire divide_subtract = divide_remainder_shifted >= {1'b0, divide_divisor};
    wire [32:0] divide_remainder_next =
        divide_subtract ?
        (divide_remainder_shifted - {1'b0, divide_divisor}) :
        divide_remainder_shifted;
    wire [31:0] divide_quotient_next =
        {divide_quotient[30:0], divide_subtract};
    wire [31:0] signed_quotient =
        result_negative ? (~divide_quotient_next + 32'd1) : divide_quotient_next;
    wire [31:0] signed_remainder =
        remainder_negative ? (~divide_remainder_next[31:0] + 32'd1) :
        divide_remainder_next[31:0];

    // Only these one-bit control registers depend on start. Keeping that
    // dependency out of the iterative datapath avoids a wide start/reset cone.
    always @(posedge clock) begin
        if (reset) begin
            busy <= 1'b0;
            done <= 1'b0;
            launch_pending <= 1'b0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                busy <= 1'b1;
                launch_pending <= 1'b1;
            end else if (launch_pending) begin
                launch_pending <= 1'b0;
            end else if (busy && operation_complete) begin
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end

    // The payload is sampled while idle. launch_pending, not start, gives the
    // captured values architectural ownership on the following cycle.
    always @(posedge clock) begin
        if (reset) begin
            launch_funct3 <= 3'b000;
            launch_lhs <= 32'h0;
            launch_rhs <= 32'h0;
            multiply_lhs_low <= 17'b0;
            multiply_lhs_high <= 17'b0;
            multiply_rhs_low <= 17'b0;
            multiply_rhs_high <= 17'b0;
        end else if (!busy) begin
            launch_funct3 <= funct3;
            launch_lhs <= lhs;
            launch_rhs <= rhs;
            multiply_lhs_low <= {1'b0, lhs[15:0]};
            multiply_lhs_high <= {((funct3 == 3'b001 || funct3 == 3'b010) && lhs[31]), lhs[31:16]};
            multiply_rhs_low <= {1'b0, rhs[15:0]};
            multiply_rhs_high <= {((funct3 == 3'b001) && rhs[31]), rhs[31:16]};
        end
    end

    always @(posedge clock) begin
        if (reset) begin
            result <= 32'h0;
            operation_is_divide <= 1'b0;
            return_high_product <= 1'b0;
            return_remainder <= 1'b0;
            result_negative <= 1'b0;
            remainder_negative <= 1'b0;
            divide_by_zero <= 1'b0;
            original_lhs <= 32'h0;
            iteration <= 6'd0;
            multiply_accumulator <= 64'h0;
            multiply_multiplicand <= 64'h0;
            multiply_multiplier <= 32'h0;
            product_ll <= 32'h0;
            product_lh <= 33'h0;
            product_hl <= 33'h0;
            product_hh <= 32'h0;
            product_ll_pipe <= 32'h0;
            product_lh_pipe <= 33'h0;
            product_hl_pipe <= 33'h0;
            product_hh_pipe <= 32'h0;
            divide_divisor <= 32'h0;
            divide_quotient <= 32'h0;
            divide_remainder <= 33'h0;
        end else if (launch_pending) begin
            iteration <= 6'd0;
            operation_is_divide <= launch_funct3[2];
            return_high_product <= (launch_funct3 != 3'b000);
            return_remainder <= launch_funct3[1];
            divide_by_zero <= (launch_rhs == 32'h0);
            original_lhs <= launch_lhs;

            if (launch_funct3[2]) begin
                result_negative <=
                    divide_signed && (launch_lhs[31] ^ launch_rhs[31]);
                remainder_negative <= divide_signed && launch_lhs[31];
                divide_divisor <= rhs_magnitude;
                divide_quotient <= lhs_magnitude;
                divide_remainder <= 33'h0;
            end else if (FAST_MULTIPLY) begin
                product_ll <= multiply_lhs_low * multiply_rhs_low;
                product_lh <= multiply_lhs_low * multiply_rhs_high;
                product_hl <= multiply_lhs_high * multiply_rhs_low;
                product_hh <= multiply_lhs_high * multiply_rhs_high;
            end else begin
                result_negative <=
                    (multiply_lhs_signed && launch_lhs[31]) ^
                    (multiply_rhs_signed && launch_rhs[31]);
                remainder_negative <= 1'b0;
                multiply_accumulator <= 64'h0;
                multiply_multiplicand <= {32'h0, lhs_magnitude};
                multiply_multiplier <= rhs_magnitude;
            end
        end else if (busy) begin
            if (operation_is_divide) begin
                if (iteration == 6'd31) begin
                    if (divide_by_zero) begin
                        result <= return_remainder ? original_lhs : 32'hffff_ffff;
                    end else begin
                        result <= return_remainder ? signed_remainder : signed_quotient;
                    end
                end else begin
                    divide_remainder <= divide_remainder_next;
                    divide_quotient <= divide_quotient_next;
                    iteration <= iteration + 6'd1;
                end
            end else if (FAST_MULTIPLY) begin
                if (iteration == 6'd0) begin
                    product_ll_pipe <= product_ll;
                    product_lh_pipe <= product_lh;
                    product_hl_pipe <= product_hl;
                    product_hh_pipe <= product_hh;
                    iteration <= 6'd1;
                end else begin
                    result <= return_high_product ?
                        fast_product[63:32] : fast_product[31:0];
                end
            end else begin
                if (iteration == 6'd31) begin
                    result <= return_high_product ?
                        multiply_signed_result[63:32] :
                        multiply_signed_result[31:0];
                end else begin
                    multiply_accumulator <= multiply_accumulator_next;
                    multiply_multiplicand <= multiply_multiplicand << 1;
                    multiply_multiplier <= multiply_multiplier >> 1;
                    iteration <= iteration + 6'd1;
                end
            end
        end
    end

endmodule
