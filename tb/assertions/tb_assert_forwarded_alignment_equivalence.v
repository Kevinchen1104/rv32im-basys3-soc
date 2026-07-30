`timescale 1ns / 1ps

// Testbench: tb_assert_forwarded_alignment_equivalence
// Purpose: Proves by directed simulation that the dedicated alignment-low mux matches full rs1 forwarding.
// Checks: No bypass, EX/MEM and MEM/WB bypass, priority, x0 exclusion, PC+4, all low-bit values,
//   and equal low bits with intentionally different upper 30 bits.
// Pass condition: Every directed forwarding combination preserves priority and low-bit equivalence.
// Does not prove: Directed simulation only; a separate symbolic smoke covers all standalone input combinations.

module tb_assert_forwarded_alignment_equivalence;
    reg [31:0] idex_a;
    reg [31:0] idex_b;
    reg [4:0] idex_rs1;
    reg [4:0] idex_rs2;
    reg exmem_reg_write;
    reg [4:0] exmem_rd;
    reg [31:0] exmem_forward_value;
    reg memwb_reg_write;
    reg [4:0] memwb_rd;
    reg [31:0] memwb_value;
    reg [31:0] exmem_b;
    reg [4:0] exmem_rs2;

    wire [31:0] forward_a;
    wire [1:0] forward_a_address_low;
    wire [31:0] forward_b;
    wire [31:0] store_data;
    integer low_bits;

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

    task set_defaults;
        begin
            idex_a = 32'haaaa_aaa0;
            idex_b = 32'hbbbb_bbb1;
            idex_rs1 = 5'd5;
            idex_rs2 = 5'd6;
            exmem_reg_write = 1'b0;
            exmem_rd = 5'd0;
            exmem_forward_value = 32'h5555_5552;
            memwb_reg_write = 1'b0;
            memwb_rd = 5'd0;
            memwb_value = 32'hcccc_ccc3;
            exmem_b = 32'hdddd_ddd0;
            exmem_rs2 = 5'd7;
        end
    endtask

    task check_expected;
        input [8*64-1:0] label;
        input [31:0] expected;
        begin
            #1;
            if (forward_a !== expected ||
                forward_a_address_low !== expected[1:0] ||
                forward_a_address_low !== forward_a[1:0]) begin
                $display("FAIL: %0s full=%h low=%h expected=%h",
                    label, forward_a, forward_a_address_low, expected);
                $fatal;
            end
        end
    endtask

    initial begin
        for (low_bits = 0; low_bits < 4; low_bits = low_bits + 1) begin
            set_defaults();
            idex_a = {30'h2aaaaaaa, low_bits[1:0]};
            check_expected("no forwarding", idex_a);

            set_defaults();
            exmem_reg_write = 1'b1;
            exmem_rd = idex_rs1;
            exmem_forward_value = {30'h15555555, low_bits[1:0]};
            check_expected("EXMEM rs1 forwarding", exmem_forward_value);

            set_defaults();
            memwb_reg_write = 1'b1;
            memwb_rd = idex_rs1;
            memwb_value = {30'h33333333, low_bits[1:0]};
            check_expected("MEMWB rs1 forwarding", memwb_value);

            set_defaults();
            exmem_reg_write = 1'b1;
            exmem_rd = idex_rs1;
            exmem_forward_value = {30'h11111111, low_bits[1:0]};
            memwb_reg_write = 1'b1;
            memwb_rd = idex_rs1;
            memwb_value = {30'h22222222, ~low_bits[1:0]};
            check_expected("EXMEM priority over MEMWB", exmem_forward_value);
        end

        set_defaults();
        exmem_reg_write = 1'b1;
        exmem_rd = 5'd0;
        idex_rs1 = 5'd0;
        memwb_reg_write = 1'b1;
        memwb_rd = 5'd0;
        check_expected("x0 destinations never forward", idex_a);

        set_defaults();
        exmem_reg_write = 1'b1;
        exmem_rd = idex_rs1;
        exmem_forward_value = 32'h0000_0104;
        check_expected("PC plus four forwarding", 32'h0000_0104);

        set_defaults();
        exmem_reg_write = 1'b1;
        exmem_rd = idex_rs1;
        exmem_forward_value = 32'h5555_5552;
        memwb_reg_write = 1'b1;
        memwb_rd = idex_rs1;
        memwb_value = 32'hcccc_ccc2;
        check_expected("different upper bits same low bits", 32'h5555_5552);

        $display("PASS: dedicated forwarded alignment-low path matches full forwarding");
        $display("PASS: tb_assert_forwarded_alignment_equivalence passed");
        $finish;
    end
endmodule
