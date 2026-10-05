`timescale 1ns / 1ps

// Testbench: tb_exception_decode_unit
// Purpose: Checks a focused CPU core unit or core-level smoke path.
// Checks: Standalone exception/legal-instruction decode unit classifies legal instructions, implemented CSR accesses
//   including mie/mip/mtval, ecall/ebreak/mret, and misaligned instruction/data accesses.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_exception_decode_unit;

    localparam [6:0] ALUR   = 7'b0110011;
    localparam [6:0] ALUI   = 7'b0010011;
    localparam [6:0] LOAD   = 7'b0000011;
    localparam [6:0] STORE  = 7'b0100011;
    localparam [6:0] BRANCH = 7'b1100011;
    localparam [6:0] JAL    = 7'b1101111;
    localparam [6:0] JALR   = 7'b1100111;
    localparam [6:0] LUI    = 7'b0110111;
    localparam [6:0] SYSTEM = 7'b1110011;

    reg valid;
    reg [31:0] instruction;
    reg [6:0] opcode;
    reg [2:0] funct3;
    reg [6:0] funct7;
    reg [11:0] csr_addr;
    reg mem_read;
    reg mem_write;
    reg [1:0] load_address_low;
    reg [1:0] store_address_low;
    reg control_transfer_taken;
    reg [1:0] control_target_address_low;

    wire is_ecall;
    wire is_ebreak;
    wire is_mret;
    wire is_csr_access;
    wire is_valid_csr;
    wire is_misaligned_load;
    wire is_misaligned_store;
    wire is_misaligned_access;
    wire is_misaligned_instruction;
    wire is_legal_instruction;
    wire classified_exception;
    wire [31:0] classified_cause;

    exception_decode_unit dut (
        .valid(valid),
        .instruction(instruction),
        .opcode(opcode),
        .funct3(funct3),
        .funct7(funct7),
        .csr_addr(csr_addr),
        .mem_read(mem_read),
        .mem_write(mem_write),
        .load_address_low(load_address_low),
        .store_address_low(store_address_low),
        .control_transfer_taken(control_transfer_taken),
        .control_target_address_low(control_target_address_low),
        .is_ecall(is_ecall),
        .is_ebreak(is_ebreak),
        .is_mret(is_mret),
        .is_csr_access(is_csr_access),
        .is_valid_csr(is_valid_csr),
        .is_misaligned_load(is_misaligned_load),
        .is_misaligned_store(is_misaligned_store),
        .is_misaligned_access(is_misaligned_access),
        .is_misaligned_instruction(is_misaligned_instruction),
        .is_legal_instruction(is_legal_instruction)
    );

    // The core owns acceptance and cause mapping; these local expressions let
    // the classifier unit test state the expected architectural category.
    assign classified_exception =
        valid &&
        (
            !is_legal_instruction ||
            is_misaligned_instruction ||
            is_ecall ||
            is_ebreak ||
            is_misaligned_access
        );
    assign classified_cause =
        !is_legal_instruction ? 32'd2 :
        is_misaligned_instruction ? 32'd0 :
        is_ecall ? 32'd11 :
        is_ebreak ? 32'd3 :
        is_misaligned_load ? 32'd4 :
        is_misaligned_store ? 32'd6 :
        32'd0;

    task defaults;
    begin
        valid = 1'b1;
        instruction = 32'h0000_0013;
        opcode = ALUI;
        funct3 = 3'b000;
        funct7 = 7'b0000000;
        csr_addr = 12'h300;
        mem_read = 1'b0;
        mem_write = 1'b0;
        load_address_low = 2'b00;
        store_address_low = 2'b00;
        control_transfer_taken = 1'b0;
        control_target_address_low = 2'b00;
    end
    endtask

    task check_bool;
        input [255:0] name;
        input actual;
        input expected;
    begin
        if (actual !== expected) begin
            $display("FAIL: %0s expected %0d got %0d", name, expected, actual);
            $fatal;
        end
    end
    endtask

    task check_word;
        input [255:0] name;
        input [31:0] actual;
        input [31:0] expected;
    begin
        if (actual !== expected) begin
            $display("FAIL: %0s expected %h got %h", name, expected, actual);
            $fatal;
        end
    end
    endtask

    task check_no_exception;
        input [255:0] name;
    begin
        #1;
        check_bool({name, " legal"}, is_legal_instruction, 1'b1);
        check_bool({name, " exception"}, classified_exception, 1'b0);
        check_word({name, " cause"}, classified_cause, 32'd0);
    end
    endtask

    task check_exception;
        input [255:0] name;
        input [31:0] cause;
    begin
        #1;
        check_bool({name, " exception"}, classified_exception, 1'b1);
        check_word({name, " cause"}, classified_cause, cause);
    end
    endtask

    task set_load_address_parts;
        input [31:0] base;
        input [31:0] offset;
    begin
        load_address_low = base[1:0] + offset[1:0];
    end
    endtask

    task set_store_address_parts;
        input [31:0] base;
        input [31:0] offset;
    begin
        store_address_low = base[1:0] + offset[1:0];
    end
    endtask

    integer i;
    reg [2:0] legal_load_funct3 [0:4];
    reg [2:0] legal_store_funct3 [0:2];
    reg [2:0] legal_branch_funct3 [0:5];

    initial begin
        legal_load_funct3[0] = 3'b000;
        legal_load_funct3[1] = 3'b001;
        legal_load_funct3[2] = 3'b010;
        legal_load_funct3[3] = 3'b100;
        legal_load_funct3[4] = 3'b101;
        legal_store_funct3[0] = 3'b000;
        legal_store_funct3[1] = 3'b001;
        legal_store_funct3[2] = 3'b010;
        legal_branch_funct3[0] = 3'b000;
        legal_branch_funct3[1] = 3'b001;
        legal_branch_funct3[2] = 3'b100;
        legal_branch_funct3[3] = 3'b101;
        legal_branch_funct3[4] = 3'b110;
        legal_branch_funct3[5] = 3'b111;

        defaults();
        valid = 1'b0;
        opcode = 7'b0000000;
        instruction = 32'hffff_ffff;
        #1;
        check_bool("valid zero legal", is_legal_instruction, 1'b1);
        check_bool("valid zero no exception", classified_exception, 1'b0);
        check_word("valid zero cause", classified_cause, 32'd0);

        defaults();
        opcode = ALUR;
        funct3 = 3'b000;
        funct7 = 7'b0000000;
        check_no_exception("legal ADD");

        defaults();
        opcode = ALUR;
        funct3 = 3'b000;
        funct7 = 7'b0100000;
        check_no_exception("legal SUB");

        defaults();
        opcode = ALUR;
        funct3 = 3'b100;
        funct7 = 7'b0000001;
        check_no_exception("legal RV32M funct7");

        defaults();
        opcode = ALUI;
        funct3 = 3'b000;
        funct7 = 7'b1111111;
        check_no_exception("legal ADDI");

        defaults();
        opcode = ALUI;
        funct3 = 3'b001;
        funct7 = 7'b0000000;
        check_no_exception("legal SLLI");

        defaults();
        opcode = ALUI;
        funct3 = 3'b001;
        funct7 = 7'b0000001;
        check_exception("illegal SLLI funct7", 32'd2);

        for (i = 0; i < 5; i = i + 1) begin
            defaults();
            opcode = LOAD;
            funct3 = legal_load_funct3[i];
            mem_read = 1'b1;
            load_address_low = 2'b00;
            check_no_exception("legal load funct3");
        end

        defaults();
        opcode = LOAD;
        funct3 = 3'b011;
        check_exception("illegal load funct3", 32'd2);

        for (i = 0; i < 3; i = i + 1) begin
            defaults();
            opcode = STORE;
            funct3 = legal_store_funct3[i];
            mem_write = 1'b1;
            store_address_low = 2'b00;
            check_no_exception("legal store funct3");
        end

        defaults();
        opcode = STORE;
        funct3 = 3'b011;
        check_exception("illegal store funct3", 32'd2);

        for (i = 0; i < 6; i = i + 1) begin
            defaults();
            opcode = BRANCH;
            funct3 = legal_branch_funct3[i];
            check_no_exception("legal branch funct3");
        end

        defaults();
        opcode = BRANCH;
        funct3 = 3'b010;
        check_exception("illegal branch funct3", 32'd2);

        defaults();
        opcode = JAL;
        check_no_exception("legal JAL");

        defaults();
        opcode = JALR;
        funct3 = 3'b000;
        check_no_exception("legal JALR funct3");

        defaults();
        opcode = JALR;
        funct3 = 3'b111;
        check_exception("illegal JALR funct3", 32'd2);

        defaults();
        opcode = JAL;
        control_transfer_taken = 1'b1;
        control_target_address_low = 2'b10;
        check_exception("misaligned JAL target", 32'd0);
        check_bool("misaligned JAL flag", is_misaligned_instruction, 1'b1);

        defaults();
        opcode = JALR;
        funct3 = 3'b000;
        control_transfer_taken = 1'b1;
        control_target_address_low = 2'b10;
        check_exception("misaligned JALR target", 32'd0);

        defaults();
        opcode = BRANCH;
        funct3 = 3'b000;
        control_transfer_taken = 1'b1;
        control_target_address_low = 2'b10;
        check_exception("misaligned taken branch target", 32'd0);

        defaults();
        opcode = BRANCH;
        funct3 = 3'b000;
        control_transfer_taken = 1'b0;
        control_target_address_low = 2'b10;
        check_no_exception("untaken branch ignores target alignment");

        defaults();
        opcode = JALR;
        funct3 = 3'b111;
        control_transfer_taken = 1'b1;
        control_target_address_low = 2'b10;
        check_exception("illegal JALR beats target misalignment", 32'd2);
        check_bool("illegal JALR no misaligned flag", is_misaligned_instruction, 1'b0);

        defaults();
        opcode = LUI;
        check_no_exception("legal LUI");

        defaults();
        opcode = SYSTEM;
        instruction = 32'h3000_1073;
        funct3 = 3'b001;
        csr_addr = 12'h300;
        #1;
        check_bool("valid CSR access", is_csr_access, 1'b1);
        check_bool("valid CSR address", is_valid_csr, 1'b1);
        check_no_exception("valid CSR legal");

        defaults();
        opcode = SYSTEM;
        instruction = 32'h3040_1073;
        funct3 = 3'b001;
        csr_addr = 12'h304;
        #1;
        check_bool("valid MIE CSR address", is_valid_csr, 1'b1);
        check_no_exception("valid MIE CSR legal");

        defaults();
        opcode = SYSTEM;
        instruction = 32'h3440_1073;
        funct3 = 3'b001;
        csr_addr = 12'h344;
        #1;
        check_bool("valid MIP CSR address", is_valid_csr, 1'b1);
        check_no_exception("valid MIP CSR legal");

        defaults();
        opcode = SYSTEM;
        instruction = 32'h3430_1073;
        funct3 = 3'b001;
        csr_addr = 12'h343;
        #1;
        check_bool("valid MTVAL CSR address", is_valid_csr, 1'b1);
        check_no_exception("valid MTVAL CSR legal");

        defaults();
        opcode = SYSTEM;
        instruction = 32'h7c00_1073;
        funct3 = 3'b001;
        csr_addr = 12'h7c0;
        #1;
        check_bool("invalid CSR access", is_csr_access, 1'b1);
        check_bool("invalid CSR address", is_valid_csr, 1'b0);
        check_exception("invalid CSR cause", 32'd2);

        defaults();
        opcode = SYSTEM;
        instruction = 32'h0000_0073;
        check_exception("ecall cause", 32'd11);
        check_bool("ecall flag", is_ecall, 1'b1);

        defaults();
        opcode = SYSTEM;
        instruction = 32'h0010_0073;
        check_exception("ebreak cause", 32'd3);
        check_bool("ebreak flag", is_ebreak, 1'b1);

        defaults();
        opcode = SYSTEM;
        instruction = 32'h3020_0073;
        check_no_exception("mret legal");
        check_bool("mret flag", is_mret, 1'b1);

        defaults();
        opcode = LOAD;
        funct3 = 3'b001;
        mem_read = 1'b1;
        load_address_low = 2'b01;
        check_exception("misaligned LH", 32'd4);
        check_bool("misaligned LH flag", is_misaligned_load, 1'b1);

        defaults();
        opcode = LOAD;
        funct3 = 3'b010;
        mem_read = 1'b1;
        load_address_low = 2'b10;
        check_exception("misaligned LW", 32'd4);

        defaults();
        opcode = STORE;
        funct3 = 3'b001;
        mem_write = 1'b1;
        store_address_low = 2'b01;
        check_exception("misaligned SH", 32'd6);
        check_bool("misaligned SH flag", is_misaligned_store, 1'b1);

        defaults();
        opcode = STORE;
        funct3 = 3'b010;
        mem_write = 1'b1;
        store_address_low = 2'b10;
        check_exception("misaligned SW", 32'd6);

        defaults();
        opcode = LOAD;
        funct3 = 3'b000;
        mem_read = 1'b1;
        load_address_low = 2'b11;
        check_no_exception("byte load never misaligned");

        defaults();
        opcode = STORE;
        funct3 = 3'b000;
        mem_write = 1'b1;
        store_address_low = 2'b11;
        check_no_exception("byte store never misaligned");

        defaults();
        opcode = LOAD;
        funct3 = 3'b011;
        mem_read = 1'b1;
        load_address_low = 2'b01;
        check_exception("illegal beats misaligned", 32'd2);

        defaults();
        opcode = LOAD;
        funct3 = 3'b010;
        mem_read = 1'b1;
        set_load_address_parts(32'h0000_0fff, 32'd1);
        check_no_exception("LW low-bit carry aligns address");

        defaults();
        opcode = LOAD;
        funct3 = 3'b010;
        mem_read = 1'b1;
        set_load_address_parts(32'h8000_0fff, 32'd2);
        check_exception("LW low-bit carry leaves offset one", 32'd4);

        defaults();
        opcode = STORE;
        funct3 = 3'b001;
        mem_write = 1'b1;
        set_store_address_parts(32'h0000_1fff, 32'd1);
        check_no_exception("SH low-bit carry aligns address");

        defaults();
        opcode = STORE;
        funct3 = 3'b001;
        mem_write = 1'b1;
        set_store_address_parts(32'hffff_1fff, 32'd2);
        check_exception("SH low-bit carry leaves odd address", 32'd6);

        defaults();
        opcode = LOAD;
        funct3 = 3'b001;
        mem_read = 1'b1;
        set_load_address_parts(32'h0000_1000, 32'd1);
        check_exception("LH low address pattern", 32'd4);

        defaults();
        opcode = LOAD;
        funct3 = 3'b001;
        mem_read = 1'b1;
        set_load_address_parts(32'hffff_f000, 32'd1);
        check_exception("LH same low bits different high bits", 32'd4);

        $display("PASS: tb_exception_decode_unit passed");
        $finish;
    end

endmodule
