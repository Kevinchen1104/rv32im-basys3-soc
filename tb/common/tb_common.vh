    reg clock = 0;
    reg reset = 1;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;
    wire [31:0] gpio_outputs;
    wire [31:0] gpio_inputs = 32'h0;
    wire [7:0] uart_tx_data;
    wire uart_tx_valid;
    wire uart_tx_ready = 1'b1;
    wire [7:0] uart_rx_data = 8'h00;
    wire uart_rx_valid = 1'b0;
    wire uart_rx_overrun = 1'b0;
    wire uart_rx_ready;
    wire [31:0] imem_addr;
    wire imem_read;
    wire [31:0] dmem_addr;
    wire dmem_read;
    wire dmem_write;
    wire [127:0] dmem_wdata;
    wire [15:0] dmem_byte_enable;

`ifndef CORE_FAST_MULTIPLY
`define CORE_FAST_MULTIPLY 0
`endif
`ifndef CORE_DCACHE_VICTIM_LINES
`define CORE_DCACHE_VICTIM_LINES 0
`endif
    RISCVCPU #(.FAST_MULTIPLY(`CORE_FAST_MULTIPLY), .DCACHE_VICTIM_LINES(`CORE_DCACHE_VICTIM_LINES)) dut (
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
        .gpio_inputs(gpio_inputs),
        .gpio_outputs(gpio_outputs),
        .uart_tx_data(uart_tx_data),
        .uart_tx_valid(uart_tx_valid),
        .uart_tx_ready(uart_tx_ready),
        .uart_rx_data(uart_rx_data),
        .uart_rx_valid(uart_rx_valid),
        .uart_rx_overrun(uart_rx_overrun),
        .uart_rx_ready(uart_rx_ready)
    );

    always #5 clock = ~clock;

    localparam NOP = 32'h00000013;

    function automatic string reference_path;
        input string filename;
        string directory;
        begin
            if (!$value$plusargs("fixture_dir=%s", directory))
                directory = "fixtures/generated/reference";
            reference_path = $sformatf("%0s/%0s", directory, filename);
        end
    endfunction

    function automatic integer reference_word_count;
        input integer default_count;
        integer count;
        begin
            if (!$value$plusargs("program_words=%d", count))
                count = default_count;
            if (count < 1 || count > 1024)
                $fatal(1, "Reference program does not fit instruction memory");
            reference_word_count = count;
        end
    endfunction

    function [31:0] r_type;
        input [6:0] funct7;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] funct3;
        input [4:0] rd;
        input [6:0] opcode;
        begin
            r_type = {funct7, rs2, rs1, funct3, rd, opcode};
        end
    endfunction

    function [31:0] i_type;
        input [11:0] imm;
        input [4:0] rs1;
        input [2:0] funct3;
        input [4:0] rd;
        input [6:0] opcode;
        begin
            i_type = {imm, rs1, funct3, rd, opcode};
        end
    endfunction

    function [31:0] s_type;
        input [11:0] imm;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] funct3;
        input [6:0] opcode;
        begin
            s_type = {imm[11:5], rs2, rs1, funct3, imm[4:0], opcode};
        end
    endfunction

    function [31:0] b_type;
        input integer imm;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] funct3;
        input [6:0] opcode;
        reg [12:0] bimm;
        begin
            bimm = imm[12:0];
            b_type = {bimm[12], bimm[10:5], rs2, rs1, funct3, bimm[4:1], bimm[11], opcode};
        end
    endfunction

    function [31:0] j_type;
        input integer imm;
        input [4:0] rd;
        input [6:0] opcode;
        reg [20:0] jimm;
        begin
            jimm = imm[20:0];
            j_type = {jimm[20], jimm[10:1], jimm[11], jimm[19:12], rd, opcode};
        end
    endfunction

    task reset_cpu;
        integer i;
        begin
            // Let DUT initialization finish before writing its memory arrays.
            #1;
            for (i = 0; i < 1024; i = i + 1) begin
                dut.IMemory[i] = NOP;
                dut.DMemory[i] = 32'h0;
            end

            reset = 1'b1;
            @(posedge clock);
            @(negedge clock);
            reset = 1'b0;
        end
    endtask

    task run_cycles;
        input integer count;
        begin
            repeat (count) @(posedge clock);
            #1;
        end
    endtask

    task check_reg;
        input [4:0] reg_id;
        input [31:0] expected;
        begin
            if (dut.Regs[reg_id] !== expected) begin
                $display("FAIL: x%0d expected %h, got %h", reg_id, expected, dut.Regs[reg_id]);
                $fatal;
            end
            $display("PASS: x%0d = %h", reg_id, dut.Regs[reg_id]);
        end
    endtask
