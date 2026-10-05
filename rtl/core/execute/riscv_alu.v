`timescale 1ns / 1ps

// Module: riscv_alu
// Role: Shared combinational execute-result datapath for the RV32IM-style core.
// Interface: Forwarded operands, decode fields, immediates, PC, CSR/RV32M
//   results, the shared arithmetic result, and the selected execute result.
// Key behavior: Shares add/sub and shift datapaths across register/immediate operations.

module riscv_alu (
    input [6:0] opcode,
    input [2:0] funct3,
    input [6:0] funct7,
    input [31:0] lhs,
    input [31:0] rhs,
    input [31:0] imm_i,
    input [31:0] imm_s,
    input [31:0] imm_u,
    input [31:0] pc,
    input [31:0] rv32m_result,
    input [31:0] csr_result,
    output [31:0] arithmetic_result,
    output arithmetic_result_selected,
    output [31:0] result
);

    localparam ALURop = 7'b0110011;
    localparam ALUIop = 7'b0010011;
    localparam LOADop = 7'b0000011;
    localparam STOREop = 7'b0100011;
    localparam LUIop = 7'b0110111;
    localparam AUIPCop = 7'b0010111;
    localparam SYSTEMop = 7'b1110011;

    wire arithmetic_subtract =
        (opcode == ALURop) &&
        (funct7 == 7'b0100000) &&
        (funct3 == 3'b000);
    wire [31:0] arithmetic_lhs = (opcode == AUIPCop) ? pc : lhs;
    wire [31:0] arithmetic_rhs =
        (opcode == STOREop) ? imm_s :
        (opcode == AUIPCop) ? imm_u :
        (opcode == ALURop) ? rhs :
        imm_i;
    wire [31:0] arithmetic_rhs_adjusted =
        arithmetic_rhs ^ {32{arithmetic_subtract}};
    assign arithmetic_result =
        arithmetic_lhs + arithmetic_rhs_adjusted + arithmetic_subtract;

    wire is_arithmetic_result_instruction =
        ((opcode == ALURop) &&
         (funct3 == 3'b000) &&
         ((funct7 == 7'b0000000) || (funct7 == 7'b0100000))) ||
        ((opcode == ALUIop) && (funct3 == 3'b000)) ||
        (opcode == AUIPCop) ||
        ((opcode == LOADop) &&
         ((funct3 == 3'b000) ||
          (funct3 == 3'b001) ||
          (funct3 == 3'b010) ||
          (funct3 == 3'b100) ||
          (funct3 == 3'b101))) ||
        ((opcode == STOREop) &&
         ((funct3 == 3'b000) ||
          (funct3 == 3'b001) ||
          (funct3 == 3'b010)));
    assign arithmetic_result_selected = is_arithmetic_result_instruction;
    reg [31:0] non_arithmetic_result;

    // Reverse the bit order around a right shifter to implement left shifts.
    // Register and immediate shifts differ only in the source of shift_amount.
    wire shift_left = (funct3 == 3'b001);
    wire [4:0] shift_amount = (opcode == ALURop) ? rhs[4:0] : imm_i[4:0];
    wire shift_fill = !shift_left && funct7[5] && lhs[31];
    wire [31:0] shift_input;
    wire signed [32:0] shift_extended = {shift_fill, shift_input};
    wire [32:0] shifted_right = shift_extended >>> shift_amount;
    wire [31:0] shift_result;

    genvar bit_index;
    generate
        for (bit_index = 0; bit_index < 32; bit_index = bit_index + 1) begin : shift_bits
            assign shift_input[bit_index] = shift_left ? lhs[31-bit_index] : lhs[bit_index];
            assign shift_result[bit_index] = shift_left ? shifted_right[31-bit_index] : shifted_right[bit_index];
        end
    endgenerate

    always @(*) begin
        non_arithmetic_result = 32'h0;

        case (opcode)
            ALURop: begin
                if (funct7 == 7'b0000001) begin
                    non_arithmetic_result = rv32m_result;
                end else case ({funct7, funct3})
                    {7'b0000000, 3'b111}: non_arithmetic_result = lhs & rhs; // AND
                    {7'b0000000, 3'b110}: non_arithmetic_result = lhs | rhs; // OR
                    {7'b0000000, 3'b010}: non_arithmetic_result = ($signed(lhs) < $signed(rhs)) ? 32'd1 : 32'd0; // SLT
                    {7'b0000000, 3'b011}: non_arithmetic_result = (lhs < rhs) ? 32'd1 : 32'd0; // SLTU
                    {7'b0000000, 3'b100}: non_arithmetic_result = lhs ^ rhs; // XOR
                    {7'b0000000, 3'b001}: non_arithmetic_result = shift_result; // SLL
                    {7'b0000000, 3'b101}: non_arithmetic_result = shift_result; // SRL
                    {7'b0100000, 3'b101}: non_arithmetic_result = shift_result; // SRA
                    default: non_arithmetic_result = 32'h0;
                endcase
            end

            ALUIop: begin
                casez ({funct7, funct3})
                    {7'b???????, 3'b010}: non_arithmetic_result = ($signed(lhs) < $signed(imm_i)) ? 32'd1 : 32'd0; // SLTI
                    {7'b???????, 3'b011}: non_arithmetic_result = (lhs < imm_i) ? 32'd1 : 32'd0; // SLTIU
                    {7'b???????, 3'b100}: non_arithmetic_result = lhs ^ imm_i; // XORI
                    {7'b0000000, 3'b001}: non_arithmetic_result = shift_result; // SLLI
                    {7'b0000000, 3'b101}: non_arithmetic_result = shift_result; // SRLI
                    {7'b0100000, 3'b101}: non_arithmetic_result = shift_result; // SRAI
                    {7'b???????, 3'b110}: non_arithmetic_result = lhs | imm_i; // ORI
                    {7'b???????, 3'b111}: non_arithmetic_result = lhs & imm_i; // ANDI
                    default: non_arithmetic_result = 32'h0;
                endcase
            end

            LUIop: non_arithmetic_result = imm_u;
            SYSTEMop: non_arithmetic_result = csr_result;
            default: non_arithmetic_result = 32'h0;
        endcase
    end

    assign result =
        arithmetic_result_selected ? arithmetic_result : non_arithmetic_result;

endmodule
