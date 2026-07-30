`default_nettype none

module forwarding_alignment_equivalence;
    (* anyseq *) reg [31:0] idex_a;
    (* anyseq *) reg [31:0] idex_b;
    (* anyseq *) reg [4:0] idex_rs1;
    (* anyseq *) reg [4:0] idex_rs2;
    (* anyseq *) reg exmem_reg_write;
    (* anyseq *) reg [4:0] exmem_rd;
    (* anyseq *) reg [31:0] exmem_forward_value;
    (* anyseq *) reg memwb_reg_write;
    (* anyseq *) reg [4:0] memwb_rd;
    (* anyseq *) reg [31:0] memwb_value;
    (* anyseq *) reg [31:0] exmem_b;
    (* anyseq *) reg [4:0] exmem_rs2;

    wire [31:0] forward_a;
    wire [1:0] forward_a_address_low;
    wire [31:0] forward_b;
    wire [31:0] store_data;

    wire exmem_match =
        exmem_reg_write && (exmem_rd != 5'd0) && (exmem_rd == idex_rs1);
    wire memwb_match =
        memwb_reg_write && (memwb_rd != 5'd0) && (memwb_rd == idex_rs1);
    wire exmem_rs2_match =
        exmem_reg_write && (exmem_rd != 5'd0) && (exmem_rd == idex_rs2);
    wire memwb_rs2_match =
        memwb_reg_write && (memwb_rd != 5'd0) && (memwb_rd == idex_rs2);
    wire memwb_store_match =
        memwb_reg_write && (memwb_rd != 5'd0) && (memwb_rd == exmem_rs2);

    forwarding_unit dut (
        .idex_a(idex_a),
        .idex_b(idex_b),
        .idex_rs1(idex_rs1),
        .idex_rs2(idex_rs2),
        .exmem_producer_valid(exmem_reg_write && (exmem_rd != 5'd0)),
        .exmem_rd(exmem_rd),
        .exmem_forward_value(exmem_forward_value),
        .memwb_producer_valid(memwb_reg_write && (memwb_rd != 5'd0)),
        .memwb_rd(memwb_rd),
        .memwb_value(memwb_value),
        .exmem_b(exmem_b),
        .exmem_rs2(exmem_rs2),
        .forward_a(forward_a),
        .forward_a_address_low(forward_a_address_low),
        .forward_b(forward_b),
        .store_data(store_data)
    );

    always @(*) begin
        assert(forward_a_address_low == forward_a[1:0]);
        if (exmem_match) begin
            assert(forward_a == exmem_forward_value);
            assert(forward_a_address_low == exmem_forward_value[1:0]);
        end else if (memwb_match) begin
            assert(forward_a == memwb_value);
            assert(forward_a_address_low == memwb_value[1:0]);
        end else begin
            assert(forward_a == idex_a);
            assert(forward_a_address_low == idex_a[1:0]);
        end

        if (exmem_rs2_match) begin
            assert(forward_b == exmem_forward_value);
        end else if (memwb_rs2_match) begin
            assert(forward_b == memwb_value);
        end else begin
            assert(forward_b == idex_b);
        end

        if (memwb_store_match) begin
            assert(store_data == memwb_value);
        end else begin
            assert(store_data == exmem_b);
        end
    end
endmodule

`default_nettype wire
