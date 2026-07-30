`timescale 1ns / 1ps

// Testbench: tb_int8_matvec_dma_lite
// Purpose: Checks a local accelerator block or its MMIO/performance-counter integration.
// Checks: Registered descriptor validation, transaction addresses and compute stages, rows 1..4, signed int8 edge products, ordered reads/writes,
//   stable backpressure, snoop/external equivalence, reset, descriptor range/overlap errors, unchanged counters, and polling status.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.
//   accelerator, throughput proof, or board result.

module tb_int8_matvec_dma_lite;
    reg clock;
    reg reset;
    reg vec_addr_write;
    reg matrix_addr_write;
    reg out_addr_write;
    reg rows_write;
    reg ctrl_write;
    reg [31:0] write_data;
    reg dmem_snoop_hit;
    reg [31:0] dmem_snoop_word;
    reg dmem_ready_enable;

    wire [31:0] vec_addr_read_data;
    wire [31:0] matrix_addr_read_data;
    wire [31:0] out_addr_read_data;
    wire [31:0] rows_read_data;
    wire [31:0] ctrl_read_data;
    wire [31:0] status_read_data;
    wire [31:0] error_read_data;
    wire [31:0] perf_read_data;
    wire busy;
    wire done;
    wire error;
    wire irq_pending;
    wire dmem_read;
    wire dmem_write;
    wire [31:0] dmem_addr;
    wire [31:0] dmem_word_addr;
    wire [127:0] dmem_wdata;
    wire [15:0] dmem_byte_enable;
    wire [127:0] dmem_rdata;
    wire dmem_ready;

    reg [31:0] memory [0:255];
    integer i;
    integer busy_cycle_count;
    integer accepted_read_count;
    integer accepted_write_count;
    reg [31:0] accepted_read_addr [0:4];
    reg [31:0] accepted_write_addr [0:3];
    reg saw_compute_gap;
    reg saw_registered_row_boundary;
    reg saw_edge_products;
    reg waiting_request;
    reg waiting_read;
    reg waiting_write;
    reg [31:0] waiting_addr;
    reg [31:0] waiting_word_addr;
    reg [127:0] waiting_wdata;
    reg [15:0] waiting_byte_enable;

    localparam integer PORT_VEC_ADDR = 0;
    localparam integer PORT_MATRIX_ADDR = 1;
    localparam integer PORT_OUT_ADDR = 2;
    localparam integer PORT_ROWS = 3;
    localparam integer PORT_CTRL = 4;

    localparam [2:0] STATE_READ_VECTOR = 3'd1;
    localparam [2:0] STATE_READ_ROW = 3'd2;
    localparam [2:0] STATE_MULTIPLY = 3'd3;
    localparam [2:0] STATE_REDUCE = 3'd4;
    localparam [2:0] STATE_WRITE_RESULT = 3'd5;

    localparam [31:0] VEC_ADDR = 32'h0000_0040;
    localparam [31:0] MATRIX_ADDR = 32'h0000_0050;
    localparam [31:0] OUT_ADDR = 32'h0000_0080;
    localparam [31:0] VECTOR = 32'hfc03_fe01;
    localparam [31:0] ROW0 = 32'h01ff_0201;
    localparam [31:0] ROW1 = 32'h0000_0504;
    localparam [31:0] ROW2 = 32'h0001_807f;
    localparam [31:0] ROW3 = 32'h000a_ec00;

    int8_matvec_dma_lite #(
        .DMEM_WORD_COUNT(256)
    ) dut (
        .clock(clock),
        .reset(reset),
        .vec_addr_write(vec_addr_write),
        .matrix_addr_write(matrix_addr_write),
        .out_addr_write(out_addr_write),
        .rows_write(rows_write),
        .ctrl_write(ctrl_write),
        .write_data(write_data),
        .vec_addr_read_data(vec_addr_read_data),
        .matrix_addr_read_data(matrix_addr_read_data),
        .out_addr_read_data(out_addr_read_data),
        .rows_read_data(rows_read_data),
        .ctrl_read_data(ctrl_read_data),
        .status_read_data(status_read_data),
        .error_read_data(error_read_data),
        .perf_read_data(perf_read_data),
        .busy(busy),
        .done(done),
        .error(error),
        .irq_pending(irq_pending),
        .dmem_read(dmem_read),
        .dmem_write(dmem_write),
        .dmem_addr(dmem_addr),
        .dmem_word_addr(dmem_word_addr),
        .dmem_wdata(dmem_wdata),
        .dmem_byte_enable(dmem_byte_enable),
        .dmem_rdata(dmem_rdata),
        .dmem_ready(dmem_ready),
        .dmem_snoop_hit(dmem_snoop_hit),
        .dmem_snoop_word(dmem_snoop_word)
    );

    assign dmem_ready = (dmem_read || dmem_write) && dmem_ready_enable;
    assign dmem_rdata = {
        memory[(dmem_addr >> 2) + 3],
        memory[(dmem_addr >> 2) + 2],
        memory[(dmem_addr >> 2) + 1],
        memory[(dmem_addr >> 2) + 0]
    };

    initial begin
        clock = 1'b0;
        forever #5 clock = ~clock;
    end

    always @(posedge clock) begin
        if (reset) begin
            busy_cycle_count <= 0;
            accepted_read_count <= 0;
            accepted_write_count <= 0;
            saw_compute_gap <= 1'b0;
            saw_registered_row_boundary <= 1'b0;
            saw_edge_products <= 1'b0;
            waiting_request <= 1'b0;
            waiting_read <= 1'b0;
            waiting_write <= 1'b0;
            waiting_addr <= 32'h0;
            waiting_word_addr <= 32'h0;
            waiting_wdata <= 128'h0;
            waiting_byte_enable <= 16'h0;
            for (i = 0; i < 5; i = i + 1) begin
                accepted_read_addr[i] <= 32'h0;
            end
            for (i = 0; i < 4; i = i + 1) begin
                accepted_write_addr[i] <= 32'h0;
            end
        end else begin
            if (busy) begin
                busy_cycle_count <= busy_cycle_count + 1;
            end
            if (dmem_read && dmem_ready) begin
                if (accepted_read_count < 5) begin
                    accepted_read_addr[accepted_read_count] <= dmem_word_addr;
                end
                accepted_read_count <= accepted_read_count + 1;
            end
            if (dmem_write && dmem_ready) begin
                if (accepted_write_count < 4) begin
                    accepted_write_addr[accepted_write_count] <= dmem_word_addr;
                end
                accepted_write_count <= accepted_write_count + 1;
            end

            // A one-outstanding request must keep its complete bus bundle
            // stable until the memory side accepts it.
            if (waiting_request) begin
                if (!(dmem_read || dmem_write) ||
                    (dmem_read !== waiting_read) ||
                    (dmem_write !== waiting_write) ||
                    (dmem_addr !== waiting_addr) ||
                    (dmem_word_addr !== waiting_word_addr) ||
                    (dmem_wdata !== waiting_wdata) ||
                    (dmem_byte_enable !== waiting_byte_enable)) begin
                    fail("DMEM request bundle changed under backpressure");
                end
            end
            waiting_request <= (dmem_read || dmem_write) && !dmem_ready;
            if ((dmem_read || dmem_write) && !dmem_ready) begin
                waiting_read <= dmem_read;
                waiting_write <= dmem_write;
                waiting_addr <= dmem_addr;
                waiting_word_addr <= dmem_word_addr;
                waiting_wdata <= dmem_wdata;
                waiting_byte_enable <= dmem_byte_enable;
            end

            if ((dut.state == STATE_MULTIPLY) || (dut.state == STATE_REDUCE)) begin
                saw_compute_gap <= 1'b1;
                if (dmem_read || dmem_write) begin
                    $display("FAIL: compute stage drove a DMEM request state=%0d", dut.state);
                    $fatal;
                end
            end

            if ((dut.state == STATE_MULTIPLY) &&
                (dut.active_row == 2'd0) &&
                (dut.row_word == ROW0)) begin
                if (dut.result_word !== 32'h0) begin
                    fail("READ_ROW changed result before registered compute stages");
                end
                saw_registered_row_boundary <= 1'b1;
            end

            if ((dut.state == STATE_REDUCE) &&
                (dut.active_row == 2'd2) &&
                (dut.row_word == ROW2) &&
                (dut.vector_word == VECTOR)) begin
                if ((dut.product0 !== 16'sd127) ||
                    (dut.product1 !== 16'sd256) ||
                    (dut.product2 !== 16'sd3) ||
                    (dut.product3 !== 16'sd0)) begin
                    $display("FAIL: signed product registers p0=%0d p1=%0d p2=%0d p3=%0d",
                             dut.product0, dut.product1, dut.product2, dut.product3);
                    $fatal;
                end
                if ((dut.product_sum01 !== 17'sd383) ||
                    (dut.product_sum23 !== 17'sd3) ||
                    (dut.product_sum_all !== 18'sd386)) begin
                    $display("FAIL: balanced reduction sums sum01=%0d sum23=%0d total=%0d",
                             dut.product_sum01, dut.product_sum23, dut.product_sum_all);
                    $fatal;
                end
                saw_edge_products <= 1'b1;
            end
        end

        if (dmem_write && dmem_ready) begin
            if (dmem_byte_enable[0]) memory[(dmem_addr >> 2) + 0][7:0] <= dmem_wdata[7:0];
            if (dmem_byte_enable[1]) memory[(dmem_addr >> 2) + 0][15:8] <= dmem_wdata[15:8];
            if (dmem_byte_enable[2]) memory[(dmem_addr >> 2) + 0][23:16] <= dmem_wdata[23:16];
            if (dmem_byte_enable[3]) memory[(dmem_addr >> 2) + 0][31:24] <= dmem_wdata[31:24];
            if (dmem_byte_enable[4]) memory[(dmem_addr >> 2) + 1][7:0] <= dmem_wdata[39:32];
            if (dmem_byte_enable[5]) memory[(dmem_addr >> 2) + 1][15:8] <= dmem_wdata[47:40];
            if (dmem_byte_enable[6]) memory[(dmem_addr >> 2) + 1][23:16] <= dmem_wdata[55:48];
            if (dmem_byte_enable[7]) memory[(dmem_addr >> 2) + 1][31:24] <= dmem_wdata[63:56];
            if (dmem_byte_enable[8]) memory[(dmem_addr >> 2) + 2][7:0] <= dmem_wdata[71:64];
            if (dmem_byte_enable[9]) memory[(dmem_addr >> 2) + 2][15:8] <= dmem_wdata[79:72];
            if (dmem_byte_enable[10]) memory[(dmem_addr >> 2) + 2][23:16] <= dmem_wdata[87:80];
            if (dmem_byte_enable[11]) memory[(dmem_addr >> 2) + 2][31:24] <= dmem_wdata[95:88];
            if (dmem_byte_enable[12]) memory[(dmem_addr >> 2) + 3][7:0] <= dmem_wdata[103:96];
            if (dmem_byte_enable[13]) memory[(dmem_addr >> 2) + 3][15:8] <= dmem_wdata[111:104];
            if (dmem_byte_enable[14]) memory[(dmem_addr >> 2) + 3][23:16] <= dmem_wdata[119:112];
            if (dmem_byte_enable[15]) memory[(dmem_addr >> 2) + 3][31:24] <= dmem_wdata[127:120];
        end
    end

    task fail;
        input [8*160-1:0] message;
        begin
            $display("FAIL: %0s", message);
            $finish;
        end
    endtask

    task check_equal;
        input [8*80-1:0] label;
        input [31:0] actual;
        input [31:0] expected;
        begin
            if (actual !== expected) begin
                $display("FAIL: %0s expected %h got %h", label, expected, actual);
                $finish;
            end
        end
    endtask

    task clear_writes;
        begin
            vec_addr_write = 1'b0;
            matrix_addr_write = 1'b0;
            out_addr_write = 1'b0;
            rows_write = 1'b0;
            ctrl_write = 1'b0;
            write_data = 32'h0;
        end
    endtask

    task reset_dut;
        begin
            clear_writes();
            dmem_snoop_hit = 1'b0;
            dmem_snoop_word = 32'h0;
            dmem_ready_enable = 1'b1;
            for (i = 0; i < 256; i = i + 1) begin
                memory[i] = 32'h0;
            end
            reset = 1'b1;
            repeat (3) @(posedge clock);
            reset = 1'b0;
            @(posedge clock);
            #1;
        end
    endtask

    task write_reg;
        input integer port_id;
        input [31:0] data;
        begin
            @(negedge clock);
            clear_writes();
            write_data = data;
            case (port_id)
                PORT_VEC_ADDR: vec_addr_write = 1'b1;
                PORT_MATRIX_ADDR: matrix_addr_write = 1'b1;
                PORT_OUT_ADDR: out_addr_write = 1'b1;
                PORT_ROWS: rows_write = 1'b1;
                PORT_CTRL: ctrl_write = 1'b1;
                default: fail("bad write port");
            endcase
            @(posedge clock);
            #1;
            @(negedge clock);
            clear_writes();
        end
    endtask

    task write_reg_compact;
        input integer port_id;
        input [31:0] data;
        begin
            @(negedge clock);
            clear_writes();
            write_data = data;
            case (port_id)
                PORT_VEC_ADDR: vec_addr_write = 1'b1;
                PORT_MATRIX_ADDR: matrix_addr_write = 1'b1;
                PORT_OUT_ADDR: out_addr_write = 1'b1;
                PORT_ROWS: rows_write = 1'b1;
                PORT_CTRL: ctrl_write = 1'b1;
                default: fail("bad compact write port");
            endcase
            @(posedge clock);
            #1;
            clear_writes();
        end
    endtask

    task load_case_memory;
        begin
            memory[VEC_ADDR >> 2] = VECTOR;
            memory[MATRIX_ADDR >> 2] = ROW0;
            memory[(MATRIX_ADDR >> 2) + 1] = ROW1;
            memory[(MATRIX_ADDR >> 2) + 2] = ROW2;
            memory[(MATRIX_ADDR >> 2) + 3] = ROW3;
            memory[OUT_ADDR >> 2] = 32'hdead_beef;
            memory[(OUT_ADDR >> 2) + 1] = 32'hdead_beef;
            memory[(OUT_ADDR >> 2) + 2] = 32'hdead_beef;
            memory[(OUT_ADDR >> 2) + 3] = 32'hdead_beef;
        end
    endtask

    task configure_case;
        input [31:0] rows;
        begin
            write_reg(PORT_VEC_ADDR, VEC_ADDR);
            write_reg(PORT_MATRIX_ADDR, MATRIX_ADDR);
            write_reg(PORT_OUT_ADDR, OUT_ADDR);
            write_reg(PORT_ROWS, rows);
        end
    endtask

    task start_job;
        begin
            write_reg(PORT_CTRL, 32'h0000_0001);
        end
    endtask

    task wait_done;
        input integer max_cycles;
        integer cycles;
        begin
            cycles = 0;
            while (!done && cycles < max_cycles) begin
                @(posedge clock);
                #1;
                cycles = cycles + 1;
            end
            if (!done) begin
                fail("timed out waiting for DMA done");
            end
            if (busy) begin
                fail("busy stayed high after done");
            end
        end
    endtask

    task wait_for_state;
        input [2:0] expected_state;
        input integer max_cycles;
        integer cycles;
        begin
            cycles = 0;
            while ((dut.state !== expected_state) && (cycles < max_cycles)) begin
                @(posedge clock);
                #1;
                cycles = cycles + 1;
            end
            if (dut.state !== expected_state) begin
                fail("timed out waiting for DMA state");
            end
        end
    endtask

    task clear_done;
        begin
            write_reg(PORT_CTRL, 32'h0000_0004);
        end
    endtask

    task run_rows_case;
        input [31:0] rows;
        begin
            reset_dut();
            load_case_memory();
            configure_case(rows);
            start_job();
            wait_done(32);
            if (error) begin
                fail("unexpected error on valid rows case");
            end
            check_equal("row0 result", memory[OUT_ADDR >> 2], 32'hffff_fff6);
            if (rows >= 2) check_equal("row1 result", memory[(OUT_ADDR >> 2) + 1], 32'hffff_fffa);
            if (rows >= 3) check_equal("row2 result", memory[(OUT_ADDR >> 2) + 2], 32'h0000_0182);
            if (rows >= 4) check_equal("row3 result", memory[(OUT_ADDR >> 2) + 3], 32'h0000_0046);
            check_equal("jobs started", {24'h0, perf_read_data[7:0]}, 32'h0000_0001);
            check_equal("jobs completed", {24'h0, perf_read_data[15:8]}, 32'h0000_0001);
            check_equal("dmem reads", {24'h0, perf_read_data[23:16]}, rows + 32'd1);
            check_equal("dmem writes", {24'h0, perf_read_data[31:24]}, rows);
            if (busy_cycle_count != ((rows * 4) + 2)) begin
                $display("FAIL: rows=%0d expected %0d busy cycles got %0d",
                         rows, (rows * 4) + 2, busy_cycle_count);
                $fatal;
            end
            if ((accepted_read_count != (rows + 1)) ||
                (accepted_write_count != rows)) begin
                $display("FAIL: rows=%0d accepted reads=%0d writes=%0d",
                         rows, accepted_read_count, accepted_write_count);
                $fatal;
            end
            if (accepted_read_addr[0] !== VEC_ADDR) begin
                $display("FAIL: vector read expected address %h got %h",
                         VEC_ADDR, accepted_read_addr[0]);
                $fatal;
            end
            for (i = 0; i < rows; i = i + 1) begin
                if (accepted_read_addr[i + 1] !== (MATRIX_ADDR + (i * 4))) begin
                    $display("FAIL: row read %0d expected address %h got %h",
                             i, MATRIX_ADDR + (i * 4), accepted_read_addr[i + 1]);
                    $fatal;
                end
            end
            if (!saw_compute_gap) begin
                fail("row job did not visit compute-only stages");
            end
            if (!saw_registered_row_boundary) begin
                fail("row read did not cross the registered compute boundary");
            end
            for (i = 0; i < rows; i = i + 1) begin
                if (accepted_write_addr[i] !== (OUT_ADDR + (i * 4))) begin
                    $display("FAIL: output write %0d expected address %h got %h",
                             i, OUT_ADDR + (i * 4), accepted_write_addr[i]);
                    $fatal;
                end
            end
            if ((rows >= 3) && !saw_edge_products) begin
                fail("signed INT8 edge products were not observed");
            end
            if (irq_pending) begin
                fail("polling-only DMA unexpectedly raised irq_pending");
            end
            clear_done();
            if (done || error_read_data != 32'h0) begin
                fail("clear_done did not clear sticky done/error state");
            end
        end
    endtask

    initial begin
        $dumpfile("wave/tb_int8_matvec_dma_lite.vcd");
        $dumpvars(0, tb_int8_matvec_dma_lite);

        reset = 1'b0;
        reset_dut();
        check_equal("reset status", status_read_data, 32'h0);
        check_equal("reset rows", rows_read_data, 32'h0);
        check_equal("reset perf", perf_read_data, 32'h0);

        run_rows_case(32'd1);
        run_rows_case(32'd2);
        run_rows_case(32'd3);
        run_rows_case(32'd4);

        reset_dut();
        load_case_memory();
        configure_case(32'd0);
        start_job();
        wait_done(4);
        if (!done || !error || error_read_data[0] !== 1'b1) begin
            fail("rows=0 did not report invalid rows error");
        end
        clear_done();
        write_reg(PORT_ROWS, 32'd5);
        start_job();
        wait_done(4);
        if (!done || !error || error_read_data[0] !== 1'b1) begin
            fail("rows>4 did not report invalid rows error");
        end
        clear_done();
        write_reg(PORT_ROWS, 32'd9);
        check_equal("rows retains full software value", rows_read_data, 32'd9);
        start_job();
        wait_done(4);
        if (!done || !error || error_read_data[0] !== 1'b1) begin
            fail("rows=9 was truncated instead of rejected");
        end

        reset_dut();
        load_case_memory();
        write_reg(PORT_VEC_ADDR, VEC_ADDR + 32'd1);
        write_reg(PORT_MATRIX_ADDR, MATRIX_ADDR);
        write_reg(PORT_OUT_ADDR, OUT_ADDR);
        write_reg(PORT_ROWS, 32'd4);
        start_job();
        wait_done(4);
        if (!done || !error || error_read_data[1] !== 1'b1) begin
            fail("unaligned vector address did not report error");
        end
        clear_done();
        write_reg(PORT_VEC_ADDR, VEC_ADDR);
        write_reg(PORT_MATRIX_ADDR, MATRIX_ADDR + 32'd2);
        write_reg(PORT_OUT_ADDR, OUT_ADDR + 32'd1);
        start_job();
        wait_done(4);
        if (!done || !error || error_read_data[2] !== 1'b1 || error_read_data[3] !== 1'b1) begin
            fail("unaligned matrix/output addresses did not report errors");
        end

        reset_dut();
        load_case_memory();
        configure_case(32'd4);
        write_reg(PORT_VEC_ADDR, 32'h0000_0400);
        start_job();
        wait_done(4);
        if (!done || !error || error_read_data[6] !== 1'b1) begin
            fail("out-of-range vector did not report range error");
        end
        clear_done();
        write_reg(PORT_VEC_ADDR, VEC_ADDR);
        write_reg(PORT_MATRIX_ADDR, 32'h0000_03f8);
        start_job();
        wait_done(4);
        if (!done || !error || error_read_data[7] !== 1'b1) begin
            fail("matrix row span crossing DMEM end was accepted");
        end
        clear_done();
        write_reg(PORT_MATRIX_ADDR, MATRIX_ADDR);
        write_reg(PORT_OUT_ADDR, 32'h0000_03f8);
        start_job();
        wait_done(4);
        if (!done || !error || error_read_data[8] !== 1'b1) begin
            fail("output row span crossing DMEM end was accepted");
        end
        clear_done();
        write_reg(PORT_MATRIX_ADDR, 32'hffff_fffc);
        write_reg(PORT_OUT_ADDR, OUT_ADDR);
        write_reg(PORT_ROWS, 32'd2);
        start_job();
        wait_done(4);
        if (!done || !error || error_read_data[7] !== 1'b1) begin
            fail("wrapped matrix descriptor was accepted");
        end

        reset_dut();
        load_case_memory();
        write_reg(PORT_VEC_ADDR, VEC_ADDR);
        write_reg(PORT_MATRIX_ADDR, MATRIX_ADDR);
        write_reg(PORT_OUT_ADDR, MATRIX_ADDR + 32'd4);
        write_reg(PORT_ROWS, 32'd2);
        start_job();
        wait_done(4);
        if (!done || !error || error_read_data[9] !== 1'b1) begin
            fail("output overlapping an unread matrix row was accepted");
        end
        if (busy || dmem_read || dmem_write ||
            (accepted_read_count != 0) || (accepted_write_count != 0) ||
            (perf_read_data != 32'h0)) begin
            fail("overlap rejection produced memory traffic or counter events");
        end
        clear_done();
        write_reg(PORT_OUT_ADDR, MATRIX_ADDR);
        write_reg(PORT_ROWS, 32'd1);
        start_job();
        wait_done(4);
        if (!done || !error || error_read_data[9] !== 1'b1) begin
            fail("identical matrix/output ranges were accepted");
        end

        reset_dut();
        load_case_memory();
        configure_case(32'd4);
        start_job();
        wait_for_state(STATE_MULTIPLY, 16);
        write_reg_compact(PORT_CTRL, 32'h0000_0001);
        write_reg_compact(PORT_ROWS, 32'd1);
        if (!busy || error_read_data[4] !== 1'b1 || error_read_data[5] !== 1'b1) begin
            fail("busy start/config writes did not set ignored error bits");
        end
        check_equal("busy rows write ignored", rows_read_data, 32'd4);
        wait_done(32);
        check_equal("busy row3 result", memory[(OUT_ADDR >> 2) + 3], 32'h0000_0046);

        reset_dut();
        load_case_memory();
        configure_case(32'd1);
        dmem_snoop_hit = 1'b1;
        dmem_snoop_word = 32'h0101_0101;
        start_job();
        wait_done(16);
        check_equal("snoop read overrides backing memory", memory[OUT_ADDR >> 2], 32'h0000_0004);

        reset_dut();
        load_case_memory();
        configure_case(32'd1);
        dmem_snoop_hit = 1'b1;
        dmem_snoop_word = VECTOR;
        start_job();
        wait_for_state(STATE_READ_ROW, 8);
        dmem_snoop_word = ROW0;
        wait_done(16);
        check_equal("matching snoop/external read result", memory[OUT_ADDR >> 2], 32'hffff_fff6);
        if ((accepted_read_count != 2) || (accepted_write_count != 1)) begin
            fail("snoop path changed accepted transaction counts");
        end

        reset_dut();
        load_case_memory();
        configure_case(32'd2);
        dmem_ready_enable = 1'b0;
        start_job();
        repeat (3) begin
            @(posedge clock);
            #1;
        end
        if (!busy || !dmem_read || (dut.state != STATE_READ_VECTOR) ||
            (perf_read_data[23:16] != 8'd0)) begin
            fail("vector read did not hold under backpressure");
        end

        @(negedge clock);
        dmem_ready_enable = 1'b1;
        wait_for_state(STATE_READ_ROW, 8);
        @(negedge clock);
        dmem_ready_enable = 1'b0;
        repeat (2) begin
            @(posedge clock);
            #1;
        end
        if ((dut.state != STATE_READ_ROW) || (perf_read_data[23:16] != 8'd1)) begin
            fail("row read did not hold under backpressure");
        end

        @(negedge clock);
        dmem_ready_enable = 1'b1;
        wait_for_state(STATE_WRITE_RESULT, 8);
        @(negedge clock);
        dmem_ready_enable = 1'b0;
        repeat (3) begin
            @(posedge clock);
            #1;
        end
        if ((dut.state != STATE_WRITE_RESULT) || (perf_read_data[31:24] != 8'd0)) begin
            fail("result write did not hold under backpressure");
        end

        @(negedge clock);
        dmem_ready_enable = 1'b1;
        wait_done(32);
        check_equal("backpressure row0 result", memory[OUT_ADDR >> 2], 32'hffff_fff6);
        check_equal("backpressure row1 result", memory[(OUT_ADDR >> 2) + 1], 32'hffff_fffa);
        check_equal("backpressure dmem reads", {24'h0, perf_read_data[23:16]}, 32'd3);
        check_equal("backpressure dmem writes", {24'h0, perf_read_data[31:24]}, 32'd2);
        if ((accepted_read_count != 3) || (accepted_write_count != 2)) begin
            fail("backpressure changed accepted transaction counts");
        end

        reset_dut();
        load_case_memory();
        configure_case(32'd1);
        start_job();
        wait_for_state(STATE_MULTIPLY, 16);
        @(negedge clock);
        reset = 1'b1;
        @(posedge clock);
        #1;
        reset = 1'b0;
        if (busy || done || error || (accepted_write_count != 0) ||
            (memory[OUT_ADDR >> 2] != 32'hdead_beef)) begin
            fail("reset during compute did not cancel the pending result write");
        end

        $display("PASS: tb_int8_matvec_dma_lite passed");
        $finish;
    end
endmodule
