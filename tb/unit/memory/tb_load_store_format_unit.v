`timescale 1ns / 1ps

// Testbench: tb_load_store_format_unit
// Purpose: Checks a local memory-system block with directed transactions.
// Checks: Standalone load/store formatter preserves CPU little-endian LB/LH/LW/LBU/LHU extension and SB/SH/SW merge
//   behavior.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_load_store_format_unit;

    reg [31:0] word_data;
    reg [31:0] store_data;
    reg [1:0] byte_offset;
    reg [2:0] funct3;
    wire [31:0] load_value;
    wire [31:0] store_merged_value;

    load_store_format_unit dut (
        .word_data(word_data),
        .store_data(store_data),
        .byte_offset(byte_offset),
        .funct3(funct3),
        .load_value(load_value),
        .store_merged_value(store_merged_value)
    );

    task check_load;
        input [255:0] name;
        input [31:0] expected;
    begin
        #1;
        if (load_value !== expected) begin
            $display("FAIL: %0s load expected %h got %h", name, expected, load_value);
            $fatal;
        end
    end
    endtask

    task check_store;
        input [255:0] name;
        input [31:0] expected;
    begin
        #1;
        if (store_merged_value !== expected) begin
            $display("FAIL: %0s store expected %h got %h", name, expected, store_merged_value);
            $fatal;
        end
    end
    endtask

    initial begin
        word_data = 32'h807f_3412;
        store_data = 32'haabb_ccdd;

        funct3 = 3'b000;
        byte_offset = 2'b00;
        check_load("LB offset 0 sign positive", 32'h0000_0012);

        funct3 = 3'b000;
        byte_offset = 2'b11;
        check_load("LB offset 3 sign negative", 32'hffff_ff80);

        funct3 = 3'b100;
        byte_offset = 2'b11;
        check_load("LBU offset 3 zero extend", 32'h0000_0080);

        word_data = 32'h8001_7fff;
        funct3 = 3'b001;
        byte_offset = 2'b00;
        check_load("LH low sign positive", 32'h0000_7fff);

        funct3 = 3'b001;
        byte_offset = 2'b10;
        check_load("LH high sign negative", 32'hffff_8001);

        funct3 = 3'b101;
        byte_offset = 2'b10;
        check_load("LHU high zero extend", 32'h0000_8001);

        word_data = 32'h1234_5678;
        funct3 = 3'b010;
        byte_offset = 2'b01;
        check_load("LW full word", 32'h1234_5678);

        word_data = 32'h1122_3344;
        store_data = 32'haabb_ccdd;
        funct3 = 3'b000;
        byte_offset = 2'b00;
        check_store("SB offset 0", 32'h1122_33dd);

        byte_offset = 2'b10;
        check_store("SB offset 2", 32'h11dd_3344);

        funct3 = 3'b001;
        byte_offset = 2'b00;
        check_store("SH low", 32'h1122_ccdd);

        byte_offset = 2'b10;
        check_store("SH high", 32'hccdd_3344);

        funct3 = 3'b010;
        byte_offset = 2'b01;
        check_store("SW full", 32'haabb_ccdd);

        word_data = 32'h55aa_1234;
        store_data = 32'hdeed_beef;
        funct3 = 3'b011;
        byte_offset = 2'b11;
        check_load("default load behavior", 32'h55aa_1234);
        check_store("default store behavior", 32'hdeed_beef);

        $display("PASS: tb_load_store_format_unit passed");
        $finish;
    end

endmodule
