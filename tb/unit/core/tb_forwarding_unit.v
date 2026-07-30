`timescale 1ns / 1ps

// Testbench: tb_forwarding_unit
// Purpose: Checks a focused CPU core unit or core-level smoke path.
// Checks: Standalone forwarding unit selects EX operand and store-data bypass values with EX/MEM priority over MEM/WB;
//   producer-valid ownership rejects invalid/x0 producers and nonzero producers do not match x0 consumers.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.
//   retirement.

module tb_forwarding_unit;

    reg [31:0] idex_a;
    reg [31:0] idex_b;
    reg [4:0] idex_rs1;
    reg [4:0] idex_rs2;
    reg exmem_producer_valid;
    reg [4:0] exmem_rd;
    reg [31:0] exmem_forward_value;
    reg memwb_producer_valid;
    reg [4:0] memwb_rd;
    reg [31:0] memwb_value;
    reg [31:0] exmem_b;
    reg [4:0] exmem_rs2;

    wire [31:0] forward_a;
    wire [1:0] forward_a_address_low;
    wire [31:0] forward_b;
    wire [31:0] store_data;

    forwarding_unit dut (
        .idex_a(idex_a),
        .idex_b(idex_b),
        .idex_rs1(idex_rs1),
        .idex_rs2(idex_rs2),
        .exmem_producer_valid(exmem_producer_valid),
        .exmem_rd(exmem_rd),
        .exmem_forward_value(exmem_forward_value),
        .memwb_producer_valid(memwb_producer_valid),
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
        idex_a = 32'h0000_00a1;
        idex_b = 32'h0000_00b2;
        idex_rs1 = 5'd1;
        idex_rs2 = 5'd2;
        exmem_producer_valid = 1'b0;
        exmem_rd = 5'd0;
        exmem_forward_value = 32'heeee_0000;
        memwb_producer_valid = 1'b0;
        memwb_rd = 5'd0;
        memwb_value = 32'hdddd_0000;
        exmem_b = 32'h0000_00c3;
        exmem_rs2 = 5'd3;
    end
    endtask

    task check_outputs;
        input [255:0] name;
        input [31:0] expected_a;
        input [31:0] expected_b;
        input [31:0] expected_store;
    begin
        #1;
        if (forward_a !== expected_a) begin
            $display("FAIL: %0s forward_a expected %h got %h", name, expected_a, forward_a);
            $fatal;
        end
        if (forward_a_address_low !== expected_a[1:0] ||
            forward_a_address_low !== forward_a[1:0]) begin
            $display("FAIL: %0s address-low expected %h got %h full-low %h",
                name, expected_a[1:0], forward_a_address_low, forward_a[1:0]);
            $fatal;
        end
        if (forward_b !== expected_b) begin
            $display("FAIL: %0s forward_b expected %h got %h", name, expected_b, forward_b);
            $fatal;
        end
        if (store_data !== expected_store) begin
            $display("FAIL: %0s store_data expected %h got %h", name, expected_store, store_data);
            $fatal;
        end
    end
    endtask

    initial begin
        set_defaults();
        check_outputs("no forwarding", 32'h0000_00a1, 32'h0000_00b2, 32'h0000_00c3);

        set_defaults();
        exmem_producer_valid = 1'b1;
        exmem_rd = 5'd1;
        exmem_forward_value = 32'h1111_1111;
        check_outputs("EXMEM forwards rs1", 32'h1111_1111, 32'h0000_00b2, 32'h0000_00c3);

        set_defaults();
        exmem_producer_valid = 1'b1;
        exmem_rd = 5'd1;
        exmem_forward_value = 32'h0000_0104;
        check_outputs("EXMEM PC+4 forwards rs1", 32'h0000_0104, 32'h0000_00b2, 32'h0000_00c3);

        set_defaults();
        exmem_producer_valid = 1'b1;
        exmem_rd = 5'd2;
        exmem_forward_value = 32'h2222_2222;
        check_outputs("EXMEM forwards rs2", 32'h0000_00a1, 32'h2222_2222, 32'h0000_00c3);

        set_defaults();
        memwb_producer_valid = 1'b1;
        memwb_rd = 5'd1;
        memwb_value = 32'h3333_3333;
        check_outputs("MEMWB forwards rs1", 32'h3333_3333, 32'h0000_00b2, 32'h0000_00c3);

        set_defaults();
        memwb_producer_valid = 1'b1;
        memwb_rd = 5'd2;
        memwb_value = 32'h4444_4444;
        check_outputs("MEMWB forwards rs2", 32'h0000_00a1, 32'h4444_4444, 32'h0000_00c3);

        set_defaults();
        exmem_producer_valid = 1'b1;
        exmem_rd = 5'd1;
        exmem_forward_value = 32'h5555_5555;
        memwb_producer_valid = 1'b1;
        memwb_rd = 5'd1;
        memwb_value = 32'h6666_6666;
        check_outputs("EXMEM priority over MEMWB", 32'h5555_5555, 32'h0000_00b2, 32'h0000_00c3);

        set_defaults();
        idex_rs1 = 5'd0;
        idex_rs2 = 5'd0;
        // Core ownership makes an x0 destination an invalid producer.
        exmem_producer_valid = 1'b0;
        exmem_rd = 5'd0;
        exmem_forward_value = 32'h7777_7777;
        memwb_producer_valid = 1'b0;
        memwb_rd = 5'd0;
        memwb_value = 32'h8888_8888;
        exmem_rs2 = 5'd0;
        check_outputs("rd zero does not forward", 32'h0000_00a1, 32'h0000_00b2, 32'h0000_00c3);

        set_defaults();
        exmem_rd = 5'd1;
        exmem_forward_value = 32'h7777_7777;
        memwb_rd = 5'd2;
        memwb_value = 32'h8888_8888;
        check_outputs("invalid producers do not forward", 32'h0000_00a1, 32'h0000_00b2, 32'h0000_00c3);

        set_defaults();
        idex_rs1 = 5'd0;
        idex_rs2 = 5'd0;
        exmem_producer_valid = 1'b1;
        exmem_rd = 5'd1;
        exmem_forward_value = 32'h7777_7777;
        check_outputs("x0 consumer does not match nonzero producer", 32'h0000_00a1, 32'h0000_00b2, 32'h0000_00c3);

        set_defaults();
        memwb_producer_valid = 1'b1;
        memwb_rd = 5'd3;
        memwb_value = 32'h9999_9999;
        exmem_rs2 = 5'd3;
        check_outputs("store_data forwards from MEMWB", 32'h0000_00a1, 32'h0000_00b2, 32'h9999_9999);

        set_defaults();
        memwb_producer_valid = 1'b1;
        memwb_rd = 5'd4;
        memwb_value = 32'haaaa_aaaa;
        exmem_rs2 = 5'd3;
        check_outputs("store_data default", 32'h0000_00a1, 32'h0000_00b2, 32'h0000_00c3);

        $display("PASS: tb_forwarding_unit passed");
        $finish;
    end

endmodule
