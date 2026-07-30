`default_nettype none

module alu_result_classification;
    (* anyseq *) reg [6:0] opcode;
    (* anyseq *) reg [2:0] funct3;
    (* anyseq *) reg [6:0] funct7;
    (* anyseq *) reg [31:0] lhs;
    (* anyseq *) reg [31:0] rhs;
    (* anyseq *) reg [31:0] imm_i;
    (* anyseq *) reg [31:0] imm_s;
    (* anyseq *) reg [31:0] imm_u;
    (* anyseq *) reg [31:0] pc;
    (* anyseq *) reg [31:0] rv32m_result;
    (* anyseq *) reg [31:0] csr_result;

    wire [31:0] arithmetic_result;
    wire arithmetic_result_selected;
    wire [31:0] result;

    localparam ALURop = 7'b0110011;
    localparam ALUIop = 7'b0010011;
    localparam LOADop = 7'b0000011;
    localparam STOREop = 7'b0100011;
    localparam LUIop = 7'b0110111;
    localparam AUIPCop = 7'b0010111;
    localparam SYSTEMop = 7'b1110011;

    wire reference_subtract =
        (opcode == ALURop) &&
        (funct7 == 7'b0100000) &&
        (funct3 == 3'b000);
    wire [31:0] reference_lhs = (opcode == AUIPCop) ? pc : lhs;
    wire [31:0] reference_rhs =
        (opcode == STOREop) ? imm_s :
        (opcode == AUIPCop) ? imm_u :
        (opcode == ALURop) ? rhs :
        imm_i;
    wire [31:0] reference_arithmetic =
        reference_lhs +
        (reference_rhs ^ {32{reference_subtract}}) +
        reference_subtract;

    wire reference_arithmetic_class =
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

    reg [31:0] reference_non_arithmetic;
    always @(*) begin
        reference_non_arithmetic = 32'h0;
        case (opcode)
            ALURop: begin
                if (funct7 == 7'b0000001) begin
                    reference_non_arithmetic = rv32m_result;
                end else case ({funct7, funct3})
                    {7'b0000000, 3'b111}: reference_non_arithmetic = lhs & rhs;
                    {7'b0000000, 3'b110}: reference_non_arithmetic = lhs | rhs;
                    {7'b0000000, 3'b010}: reference_non_arithmetic =
                        ($signed(lhs) < $signed(rhs)) ? 32'd1 : 32'd0;
                    {7'b0000000, 3'b011}: reference_non_arithmetic =
                        (lhs < rhs) ? 32'd1 : 32'd0;
                    {7'b0000000, 3'b100}: reference_non_arithmetic = lhs ^ rhs;
                    {7'b0000000, 3'b001}: reference_non_arithmetic = lhs << rhs[4:0];
                    {7'b0000000, 3'b101}: reference_non_arithmetic = lhs >> rhs[4:0];
                    {7'b0100000, 3'b101}: reference_non_arithmetic =
                        $signed(lhs) >>> rhs[4:0];
                    default: reference_non_arithmetic = 32'h0;
                endcase
            end
            ALUIop: begin
                casez ({funct7, funct3})
                    {7'b???????, 3'b010}: reference_non_arithmetic =
                        ($signed(lhs) < $signed(imm_i)) ? 32'd1 : 32'd0;
                    {7'b???????, 3'b011}: reference_non_arithmetic =
                        (lhs < imm_i) ? 32'd1 : 32'd0;
                    {7'b???????, 3'b100}: reference_non_arithmetic = lhs ^ imm_i;
                    {7'b0000000, 3'b001}: reference_non_arithmetic = lhs << imm_i[4:0];
                    {7'b0000000, 3'b101}: reference_non_arithmetic = lhs >> imm_i[4:0];
                    {7'b0100000, 3'b101}: reference_non_arithmetic =
                        $signed(lhs) >>> imm_i[4:0];
                    {7'b???????, 3'b110}: reference_non_arithmetic = lhs | imm_i;
                    {7'b???????, 3'b111}: reference_non_arithmetic = lhs & imm_i;
                    default: reference_non_arithmetic = 32'h0;
                endcase
            end
            LUIop: reference_non_arithmetic = imm_u;
            SYSTEMop: reference_non_arithmetic = csr_result;
            default: reference_non_arithmetic = 32'h0;
        endcase
    end

    wire [31:0] reference_result =
        reference_arithmetic_class ? reference_arithmetic : reference_non_arithmetic;

    riscv_alu dut (
        .opcode(opcode),
        .funct3(funct3),
        .funct7(funct7),
        .lhs(lhs),
        .rhs(rhs),
        .imm_i(imm_i),
        .imm_s(imm_s),
        .imm_u(imm_u),
        .pc(pc),
        .rv32m_result(rv32m_result),
        .csr_result(csr_result),
        .arithmetic_result(arithmetic_result),
        .arithmetic_result_selected(arithmetic_result_selected),
        .result(result)
    );

    always @(*) begin
        assert(arithmetic_result == reference_arithmetic);
        assert(arithmetic_result_selected == reference_arithmetic_class);
        assert(result == reference_result);
        if (reference_arithmetic_class) begin
            assert(result == arithmetic_result);
        end else begin
            assert(result == reference_non_arithmetic);
        end
    end
endmodule

`default_nettype wire
