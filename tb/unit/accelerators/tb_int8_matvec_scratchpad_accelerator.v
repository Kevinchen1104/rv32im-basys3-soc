`timescale 1ns / 1ps

// Testbench: tb_int8_matvec_scratchpad_accelerator
// Purpose: Checks the pipelined MATVEC Scratchpad accelerator and its stable MMIO contract.
// Checks: Coherent indexed row/result readback, four-stage row execution, exact 1/4/16-row latency,
//   signed int8 edge cases, ordered single commits, busy-time start/write rejection,
//   clear/interrupt behavior including final-COMMIT collisions, reset in every stage, and back-to-back jobs.
// Pass condition: All stage, result, status, interrupt, counter, and reset checks complete without $fatal.

module tb_int8_matvec_scratchpad_accelerator;
    initial begin
        #1000000;
        $fatal(1, "scratchpad test watchdog expired");
    end

    reg clock;
    reg reset;
    reg ctrl_write;
    reg config_write;
    reg vector_write;
    reg row_index_write;
    reg row_data_write;
    reg result_index_write;
    reg clear_done;
    reg [31:0] write_data;
    reg [3:0] write_byte_enable;

    wire [31:0] status_read_data;
    wire [31:0] config_read_data;
    wire [31:0] vector_read_data;
    wire [31:0] row_index_read_data;
    wire [31:0] row_data_read_data;
    wire [31:0] result_index_read_data;
    wire [31:0] result_data_read_data;
    wire [31:0] perf_read_data;
    wire irq_pending;

    localparam integer PORT_CTRL = 0;
    localparam integer PORT_CONFIG = 1;
    localparam integer PORT_VECTOR = 2;
    localparam integer PORT_ROW_INDEX = 3;
    localparam integer PORT_ROW_DATA = 4;
    localparam integer PORT_RESULT_INDEX = 5;

    localparam [2:0] STATE_IDLE = 3'd0;
    localparam [2:0] STATE_LOAD_ROW = 3'd1;
    localparam [2:0] STATE_MULTIPLY = 3'd2;
    localparam [2:0] STATE_REDUCE = 3'd3;
    localparam [2:0] STATE_COMMIT = 3'd4;

    localparam [31:0] VECTOR_A = 32'hfc03_fe01;
    localparam [31:0] BAD_WRITE = 32'hdead_beef;

    reg [31:0] rows [0:15];
    reg [31:0] expected [0:15];
    reg [31:0] prior_results [0:15];
    integer commit_count [0:15];
    integer commit_order [0:31];
    integer busy_cycles_observed;
    integer commit_total;
    integer expected_busy_write_count;
    integer expected_completed_ops;
    integer i;
    integer monitor_i;

    reg monitor_job;
    reg commit_happened;
    reg [15:0] commit_mask_snapshot;
    reg [31:0] prior_selected_result_readback;

    int8_matvec_scratchpad_accelerator dut (
        .clock(clock),
        .reset(reset),
        .ctrl_write(ctrl_write),
        .config_write(config_write),
        .vector_write(vector_write),
        .row_index_write(row_index_write),
        .row_data_write(row_data_write),
        .result_index_write(result_index_write),
        .clear_done(clear_done),
        .write_data(write_data),
        .write_byte_enable(write_byte_enable),
        .status_read_data(status_read_data),
        .config_read_data(config_read_data),
        .vector_read_data(vector_read_data),
        .row_index_read_data(row_index_read_data),
        .row_data_read_data(row_data_read_data),
        .result_index_read_data(result_index_read_data),
        .result_data_read_data(result_data_read_data),
        .perf_read_data(perf_read_data),
        .irq_pending(irq_pending)
    );

    initial begin
        clock = 1'b0;
        forever #5 clock = ~clock;
    end

    function signed [31:0] reference_product_sum;
        input [31:0] row_data;
        input [31:0] vec_data;
        reg signed [7:0] a0;
        reg signed [7:0] a1;
        reg signed [7:0] a2;
        reg signed [7:0] a3;
        reg signed [7:0] x0;
        reg signed [7:0] x1;
        reg signed [7:0] x2;
        reg signed [7:0] x3;
        reg signed [15:0] p0;
        reg signed [15:0] p1;
        reg signed [15:0] p2;
        reg signed [15:0] p3;
        begin
            a0 = row_data[7:0];
            a1 = row_data[15:8];
            a2 = row_data[23:16];
            a3 = row_data[31:24];
            x0 = vec_data[7:0];
            x1 = vec_data[15:8];
            x2 = vec_data[23:16];
            x3 = vec_data[31:24];
            p0 = a0 * x0;
            p1 = a1 * x1;
            p2 = a2 * x2;
            p3 = a3 * x3;
            reference_product_sum =
                {{16{p0[15]}}, p0} +
                {{16{p1[15]}}, p1} +
                {{16{p2[15]}}, p2} +
                {{16{p3[15]}}, p3};
        end
    endfunction

    task fail;
        input [8*160-1:0] message;
        begin
            $display("FAIL: %0s", message);
            $fatal;
        end
    endtask

    task check_equal;
        input [8*100-1:0] label;
        input [31:0] actual;
        input [31:0] expected_value;
        begin
            if (actual !== expected_value) begin
                $display("FAIL: %0s expected %h got %h", label, expected_value, actual);
                $fatal;
            end
        end
    endtask

    task check_state;
        input [8*80-1:0] label;
        input [2:0] expected_state;
        begin
            if (dut.compute_state !== expected_state) begin
                $display("FAIL: %0s expected state %0d got %0d", label, expected_state, dut.compute_state);
                $fatal;
            end
        end
    endtask

    task clear_write_strobes;
        begin
            ctrl_write = 1'b0;
            config_write = 1'b0;
            vector_write = 1'b0;
            row_index_write = 1'b0;
            row_data_write = 1'b0;
            result_index_write = 1'b0;
        end
    endtask

    task reset_dut;
        begin
            write_byte_enable = 4'b1111;
            monitor_job = 1'b0;
            clear_write_strobes();
            clear_done = 1'b0;
            write_data = 32'h0;
            reset = 1'b1;
            repeat (3) @(posedge clock);
            #1;
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
            write_data = data;
            clear_write_strobes();
            case (port_id)
                PORT_CTRL: ctrl_write = 1'b1;
                PORT_CONFIG: config_write = 1'b1;
                PORT_VECTOR: vector_write = 1'b1;
                PORT_ROW_INDEX: row_index_write = 1'b1;
                PORT_ROW_DATA: row_data_write = 1'b1;
                PORT_RESULT_INDEX: result_index_write = 1'b1;
                default: fail("unknown write port");
            endcase
            @(posedge clock);
            #1;
            clear_write_strobes();
            write_data = 32'h0;
        end
    endtask

    task pulse_clear_done;
        begin
            @(negedge clock);
            clear_done = 1'b1;
            @(posedge clock);
            #1;
            clear_done = 1'b0;
        end
    endtask

    task write_row;
        input [3:0] index;
        input [31:0] data;
        begin
            write_reg(PORT_ROW_INDEX, {28'h0, index});
            write_reg(PORT_ROW_DATA, data);
        end
    endtask

    task select_result;
        input [3:0] index;
        begin
            write_reg(PORT_RESULT_INDEX, {28'h0, index});
        end
    endtask

    task prepare_job;
        input integer row_count;
        begin
            write_reg(PORT_CONFIG, row_count - 1);
            write_reg(PORT_VECTOR, VECTOR_A);
            for (i = 0; i < row_count; i = i + 1) begin
                write_row(i[3:0], rows[i]);
            end
            write_reg(PORT_ROW_INDEX, 32'h0);
            write_reg(PORT_RESULT_INDEX, 32'h0);
        end
    endtask

    task clear_job_monitor;
        begin
            @(negedge clock);
            monitor_job = 1'b0;
            busy_cycles_observed = 0;
            commit_total = 0;
            commit_happened = 1'b0;
            commit_mask_snapshot = 16'h0;
            for (i = 0; i < 16; i = i + 1) begin
                commit_count[i] = 0;
                prior_results[i] = dut.result_scratchpad[i];
            end
            prior_selected_result_readback = dut.selected_result_data_readback;
            for (i = 0; i < 32; i = i + 1) begin
                commit_order[i] = -1;
            end
            monitor_job = 1'b1;
        end
    endtask

    task stop_job_monitor;
        begin
            @(negedge clock);
            monitor_job = 1'b0;
        end
    endtask

    task start_operation;
        begin
            write_reg(PORT_CTRL, 32'h0000_0001);
            if (status_read_data[0] !== 1'b1) fail("busy did not assert after accepted start");
            if (status_read_data[7:4] !== 4'h0) fail("active_row did not start at zero");
            check_state("accepted start", STATE_LOAD_ROW);
        end
    endtask

    task wait_until_done_total;
        input integer expected_busy_cycles;
        input integer max_wait_cycles;
        integer waited;
        begin
            waited = 0;
            while (status_read_data[1] !== 1'b1 && waited < max_wait_cycles) begin
                @(posedge clock);
                #1;
                waited = waited + 1;
            end
            if (status_read_data[1] !== 1'b1) fail("timed out waiting for done");
            if (status_read_data[0] !== 1'b0) fail("busy remained high after done");
            if (busy_cycles_observed !== expected_busy_cycles) begin
                $display("FAIL: expected %0d busy cycles got %0d", expected_busy_cycles, busy_cycles_observed);
                $fatal;
            end
        end
    endtask

    task check_commit_sequence;
        input integer row_count;
        begin
            if (commit_total !== row_count) begin
                $display("FAIL: expected %0d commits got %0d", row_count, commit_total);
                $fatal;
            end
            for (i = 0; i < row_count; i = i + 1) begin
                if (commit_count[i] !== 1 || commit_order[i] !== i) begin
                    $display("FAIL: row %0d commit_count=%0d order=%0d", i, commit_count[i], commit_order[i]);
                    $fatal;
                end
            end
        end
    endtask

    task check_results;
        input integer row_count;
        begin
            for (i = 0; i < row_count; i = i + 1) begin
                select_result(i[3:0]);
                check_equal("result row", result_data_read_data, expected[i]);
            end
        end
    endtask

    task check_full_reset_state;
        begin
            check_equal("reset status", status_read_data, 32'h0);
            check_equal("reset config", config_read_data, 32'h0);
            check_equal("reset vector", vector_read_data, 32'h0);
            check_equal("reset row index", row_index_read_data, 32'h0);
            check_equal("reset row data", row_data_read_data, 32'h0);
            check_equal("reset result index", result_index_read_data, 32'h0);
            check_equal("reset result data", result_data_read_data, 32'h0);
            check_equal("reset perf", perf_read_data, 32'h0);
            check_state("reset", STATE_IDLE);
            if (irq_pending !== 1'b0 || dut.row_word !== 32'h0 ||
                dut.selected_row_data_readback !== 32'h0 ||
                dut.selected_result_data_readback !== 32'h0 ||
                dut.compute_row_index !== 4'h0 || dut.commit_mask !== 16'h0 ||
                dut.product0 !== 16'sh0 || dut.product1 !== 16'sh0 ||
                dut.product2 !== 16'sh0 || dut.product3 !== 16'sh0 ||
                dut.result_word !== 32'sh0) begin
                fail("reset did not clear compute pipeline state");
            end
            for (i = 0; i < 16; i = i + 1) begin
                if (dut.row_scratchpad[i] !== 32'h0 || dut.result_scratchpad[i] !== 32'h0) begin
                    fail("reset did not clear scratchpad state");
                end
            end
        end
    endtask

    task reset_during_state;
        input [2:0] target_state;
        begin
            reset_dut();
            prepare_job(1);
            start_operation();
            while (dut.compute_state !== target_state) begin
                @(posedge clock);
                #1;
            end
            @(negedge clock);
            reset = 1'b1;
            @(posedge clock);
            #1;
            check_full_reset_state();
            @(negedge clock);
            reset = 1'b0;
            @(posedge clock);
            #1;
        end
    endtask

    task exercise_busy_write_port;
        input integer port_id;
        begin
            write_reg(PORT_CTRL, 32'h0000_0002);
            prepare_job(1);
            if (port_id == PORT_RESULT_INDEX) begin
                select_result(4'd7);
            end
            clear_job_monitor();
            start_operation();

            write_reg(port_id, BAD_WRITE);
            check_state("busy write after LOAD_ROW", STATE_MULTIPLY);
            write_reg(port_id, BAD_WRITE);
            check_state("busy write after MULTIPLY", STATE_REDUCE);
            write_reg(port_id, BAD_WRITE);
            check_state("busy write after REDUCE", STATE_COMMIT);
            write_reg(port_id, BAD_WRITE);
            check_state("busy write after COMMIT", STATE_IDLE);

            expected_busy_write_count = expected_busy_write_count + 4;
            expected_completed_ops = expected_completed_ops + 1;
            check_equal("busy write counter", {24'h0, perf_read_data[23:16]}, expected_busy_write_count);
            check_equal("busy-write completed_ops", {24'h0, perf_read_data[7:0]}, expected_completed_ops);
            check_equal("busy config preserved", config_read_data, 32'h0);
            check_equal("busy vector preserved", vector_read_data, VECTOR_A);
            check_equal("busy row index preserved", row_index_read_data, 32'h0);
            check_equal("busy row data preserved", row_data_read_data, rows[0]);
            if (port_id == PORT_RESULT_INDEX) begin
                check_equal("busy result index preserved", result_index_read_data, 32'h7);
                check_equal("busy result readback preserved", result_data_read_data,
                    dut.result_scratchpad[7]);
            end else begin
                check_equal("busy result index preserved", result_index_read_data, 32'h0);
                check_equal("busy-write result", result_data_read_data, expected[0]);
            end
            if (busy_cycles_observed !== 4) fail("busy-write job latency was not four cycles");
            check_commit_sequence(1);
            stop_job_monitor();
        end
    endtask

    // Capture dynamic commit events and verify that one-hot index metadata
    // remains aligned with the row that is being written.
    always @(posedge clock) begin
        if (reset) begin
            commit_happened <= 1'b0;
            commit_mask_snapshot <= 16'h0;
        end else begin
            commit_happened <= dut.busy && (dut.compute_state == STATE_COMMIT);
            commit_mask_snapshot <= dut.commit_mask;

            if (monitor_job && dut.busy) begin
                busy_cycles_observed <= busy_cycles_observed + 1;
            end
            if (monitor_job && dut.busy && (dut.compute_state == STATE_COMMIT)) begin
                if (dut.commit_mask !== (16'h0001 << dut.compute_row_index)) begin
                    fail("commit mask and compute_row_index lost alignment");
                end
                commit_count[dut.compute_row_index] <= commit_count[dut.compute_row_index] + 1;
                commit_order[commit_total] <= dut.compute_row_index;
                commit_total <= commit_total + 1;
            end
        end
    end

    // Result scratchpad storage may change only after a registered COMMIT
    // event, never during LOAD_ROW, MULTIPLY, or REDUCE.
    always @(negedge clock) begin
        if (!reset) begin
            if (row_data_read_data !== dut.selected_row_data_readback ||
                dut.selected_row_data_readback !== dut.row_scratchpad[dut.selected_row_index]) begin
                fail("selected row readback lost scratchpad coherence");
            end
            if (result_data_read_data !== dut.selected_result_data_readback ||
                dut.selected_result_data_readback !== dut.result_scratchpad[dut.selected_result_index]) begin
                fail("selected result readback lost scratchpad coherence");
            end
        end
        if (monitor_job) begin
            if (commit_happened &&
                (dut.selected_result_data_readback !== prior_selected_result_readback) &&
                !commit_mask_snapshot[dut.selected_result_index]) begin
                fail("non-selected result commit changed selected readback");
            end
            prior_selected_result_readback = dut.selected_result_data_readback;
            for (monitor_i = 0; monitor_i < 16; monitor_i = monitor_i + 1) begin
                if ((dut.result_scratchpad[monitor_i] !== prior_results[monitor_i]) &&
                    (!commit_happened || !commit_mask_snapshot[monitor_i])) begin
                    $display("FAIL: result row %0d changed outside COMMIT", monitor_i);
                    $fatal;
                end
                prior_results[monitor_i] = dut.result_scratchpad[monitor_i];
            end
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_int8_matvec_scratchpad_accelerator.vcd");
        $dumpvars(0, tb_int8_matvec_scratchpad_accelerator);

        monitor_job = 1'b0;
        commit_happened = 1'b0;
        commit_mask_snapshot = 16'h0;
        prior_selected_result_readback = 32'h0;
        expected_busy_write_count = 0;
        expected_completed_ops = 0;

        rows[0] = 32'h0403_0201;
        rows[1] = 32'h0201_00ff;
        rows[2] = 32'h0001_807f;
        rows[3] = 32'hf807_fa05;
        rows[4] = 32'h0101_0101;
        rows[5] = 32'hffff_ffff;
        rows[6] = 32'h7f80_8001;
        rows[7] = 32'h80ff_7f00;
        rows[8] = 32'h0807_0605;
        rows[9] = 32'hfefd_fcfb;
        rows[10] = 32'h1020_3040;
        rows[11] = 32'hef10_f001;
        rows[12] = 32'h7f7f_7f7f;
        rows[13] = 32'h8080_8080;
        rows[14] = 32'h0000_0000;
        rows[15] = 32'h817f_01ff;

        for (i = 0; i < 16; i = i + 1) begin
            expected[i] = reference_product_sum(rows[i], VECTOR_A);
        end

        // Reset must cancel and clear every active compute stage.
        reset_during_state(STATE_LOAD_ROW);
        reset_during_state(STATE_MULTIPLY);
        reset_during_state(STATE_REDUCE);
        reset_during_state(STATE_COMMIT);

        reset_dut();
        check_full_reset_state();

        // Every indexed row must be visible immediately after the selecting
        // write, while a data write must update both storage and readback.
        for (i = 0; i < 16; i = i + 1) begin
            write_reg(PORT_ROW_INDEX, i[3:0]);
            check_equal("new row index initial readback", row_data_read_data, 32'h0);
            write_reg(PORT_ROW_DATA, rows[i]);
            check_equal("selected row write readback", row_data_read_data, rows[i]);
        end
        for (i = 15; i >= 0; i = i - 1) begin
            write_reg(PORT_ROW_INDEX, i[3:0]);
            check_equal("indexed row readback", row_data_read_data, rows[i]);
        end
        write_reg(PORT_ROW_INDEX, 32'h3);
        check_equal("back-to-back row index first", row_data_read_data, rows[3]);
        write_reg(PORT_ROW_INDEX, 32'hc);
        check_equal("back-to-back row index second", row_data_read_data, rows[12]);

        // Result storage is reset to zero, and all sixteen selections must
        // update the readback without an extra MMIO-visible cycle.
        for (i = 0; i < 16; i = i + 1) begin
            write_reg(PORT_RESULT_INDEX, i[3:0]);
            check_equal("reset result indexed readback", result_data_read_data, 32'h0);
        end
        write_reg(PORT_RESULT_INDEX, 32'h9);
        check_equal("back-to-back result index first", result_data_read_data, 32'h0);
        write_reg(PORT_RESULT_INDEX, 32'h2);
        check_equal("back-to-back result index second", result_data_read_data, 32'h0);

        // One row: inspect every pipeline boundary and exact four-cycle latency.
        prepare_job(1);
        clear_job_monitor();
        start_operation();
        check_equal("LOAD_ROW result unchanged", dut.result_scratchpad[0], 32'h0);

        @(posedge clock);
        #1;
        check_state("after LOAD_ROW", STATE_MULTIPLY);
        check_equal("captured row", dut.row_word, rows[0]);
        check_equal("captured row index", {28'h0, dut.compute_row_index}, 32'h0);
        check_equal("captured commit mask", {16'h0, dut.commit_mask}, 32'h0000_0001);
        check_equal("MULTIPLY result unchanged", dut.result_scratchpad[0], 32'h0);

        @(posedge clock);
        #1;
        check_state("after MULTIPLY", STATE_REDUCE);
        check_equal("REDUCE result unchanged", dut.result_scratchpad[0], 32'h0);

        @(posedge clock);
        #1;
        check_state("after REDUCE", STATE_COMMIT);
        check_equal("registered result_word", dut.result_word, expected[0]);
        check_equal("COMMIT not yet written", dut.result_scratchpad[0], 32'h0);
        if (status_read_data[1] !== 1'b0 || irq_pending !== 1'b0) begin
            fail("done/irq asserted before final COMMIT");
        end

        @(posedge clock);
        #1;
        check_state("after final COMMIT", STATE_IDLE);
        if (status_read_data[0] !== 1'b0 || status_read_data[1] !== 1'b1) begin
            fail("final COMMIT did not transition busy to sticky done");
        end
        check_equal("one-row result", dut.result_scratchpad[0], expected[0]);
        if (busy_cycles_observed !== 4) fail("one-row latency was not four busy cycles");
        check_commit_sequence(1);
        expected_completed_ops = 1;
        check_equal("one-row completed_ops", {24'h0, perf_read_data[7:0]}, expected_completed_ops);
        stop_job_monitor();

        // Four rows: back-to-back start while done is sticky, clear_done while
        // busy, start rejection in every stage, and live interrupt enable state.
        prepare_job(4);
        clear_job_monitor();
        start_operation();
        if (status_read_data[1] !== 1'b1) fail("accepted back-to-back job unexpectedly cleared sticky done");
        pulse_clear_done();
        check_state("clear_done during LOAD_ROW", STATE_MULTIPLY);
        if (status_read_data[0] !== 1'b1 || status_read_data[1] !== 1'b0) begin
            fail("clear_done disturbed busy or failed to clear done");
        end

        write_reg(PORT_CTRL, 32'h1);
        check_state("start during MULTIPLY", STATE_REDUCE);
        write_reg(PORT_CTRL, 32'h1);
        check_state("start during REDUCE", STATE_COMMIT);
        write_reg(PORT_CTRL, 32'h1);
        check_state("start during COMMIT", STATE_LOAD_ROW);
        write_reg(PORT_CTRL, 32'h1);
        check_state("start during LOAD_ROW", STATE_MULTIPLY);
        check_equal("ignored starts exact", {24'h0, perf_read_data[15:8]}, 32'd4);

        write_reg(PORT_CTRL, 32'h4);
        check_state("interrupt set during MULTIPLY", STATE_REDUCE);
        if (status_read_data[9] !== 1'b1) fail("interrupt enable did not set while busy");
        write_reg(PORT_CTRL, 32'h8);
        check_state("interrupt clear during REDUCE", STATE_COMMIT);
        if (status_read_data[9] !== 1'b0) fail("interrupt enable did not clear while busy");
        write_reg(PORT_CTRL, 32'h4);
        check_state("interrupt set during COMMIT", STATE_LOAD_ROW);

        wait_until_done_total(16, 32);
        check_commit_sequence(4);
        check_results(4);
        if (irq_pending !== 1'b1 || status_read_data[8] !== 1'b1) begin
            fail("enabled final COMMIT did not raise irq_pending");
        end
        expected_completed_ops = 2;
        check_equal("four-row completed_ops", {24'h0, perf_read_data[7:0]}, expected_completed_ops);
        stop_job_monitor();

        // Clear a stale IRQ while a new job remains busy, then clear sticky done
        // without disturbing the compute pipeline. Completion may reassert IRQ.
        prepare_job(1);
        clear_job_monitor();
        start_operation();
        write_reg(PORT_CTRL, 32'h10);
        check_state("clear_irq during LOAD_ROW", STATE_MULTIPLY);
        if (irq_pending !== 1'b0 || status_read_data[1] !== 1'b1) begin
            fail("clear_irq during busy changed done or failed to clear IRQ");
        end
        pulse_clear_done();
        check_state("clear_done during MULTIPLY", STATE_REDUCE);
        wait_until_done_total(4, 8);
        if (irq_pending !== 1'b1) fail("enabled back-to-back completion did not reassert IRQ");
        expected_completed_ops = 3;
        check_equal("clear-during-busy completed_ops", {24'h0, perf_read_data[7:0]}, expected_completed_ops);
        check_commit_sequence(1);
        stop_job_monitor();

        write_reg(PORT_CTRL, 32'h10);
        write_reg(PORT_CTRL, 32'h8);

        // Every ignored operand/index write is exercised once in each of the
        // four busy stages, with exact counter accounting.
        exercise_busy_write_port(PORT_CONFIG);
        exercise_busy_write_port(PORT_VECTOR);
        exercise_busy_write_port(PORT_ROW_INDEX);
        exercise_busy_write_port(PORT_ROW_DATA);
        exercise_busy_write_port(PORT_RESULT_INDEX);
        if (expected_busy_write_count !== 20) fail("busy-write test accounting error");
        if (status_read_data[3] !== 1'b1) fail("busy-write sticky flag did not set");

        // Sixteen rows include 0x80/0x7f edge operands and must commit in
        // ascending order with exactly 64 busy cycles and no disabled IRQ.
        write_reg(PORT_CTRL, 32'h2);
        prepare_job(16);
        clear_job_monitor();
        start_operation();
        wait_until_done_total(64, 80);
        check_commit_sequence(16);
        check_results(16);
        if (irq_pending !== 1'b0 || status_read_data[9] !== 1'b0) begin
            fail("disabled sixteen-row completion raised IRQ");
        end
        expected_completed_ops = 9;
        check_equal("sixteen-row completed_ops", {24'h0, perf_read_data[7:0]}, expected_completed_ops);
        check_equal("ignored starts retained", {24'h0, perf_read_data[15:8]}, 32'd4);
        check_equal("ignored writes retained", {24'h0, perf_read_data[23:16]}, 32'd20);
        stop_job_monitor();

        pulse_clear_done();
        if (status_read_data[1] !== 1'b0 || status_read_data[2] !== 1'b0 ||
            status_read_data[3] !== 1'b0 || irq_pending !== 1'b0) begin
            fail("clear_done did not clear sticky status/IRQ flags");
        end
        select_result(4'd15);
        check_equal("clear_done retained result", result_data_read_data, expected[15]);
        check_equal("clear_done retained perf", perf_read_data, 32'h0014_0409);

        // Completion wins over clear_done/clear_irq on the final COMMIT edge.
        // IRQ generation samples the pre-edge enable, while the enable clear
        // itself remains visible after that edge.
        write_reg(PORT_CTRL, 32'h4);
        prepare_job(1);
        clear_job_monitor();
        start_operation();
        repeat (3) begin
            @(posedge clock);
            #1;
        end
        check_state("before final clear collision", STATE_COMMIT);
        @(negedge clock);
        write_data = 32'h0000_001a;
        clear_write_strobes();
        ctrl_write = 1'b1;
        @(posedge clock);
        #1;
        clear_write_strobes();
        write_data = 32'h0;
        if (status_read_data[1] !== 1'b1 || irq_pending !== 1'b1 ||
            status_read_data[9] !== 1'b0) begin
            fail("final COMMIT clear collision priority mismatch");
        end
        if (busy_cycles_observed !== 4) fail("clear-collision job latency mismatch");
        check_commit_sequence(1);
        expected_completed_ops = 10;
        check_equal("clear-collision completed_ops", {24'h0, perf_read_data[7:0]}, expected_completed_ops);
        stop_job_monitor();

        // Enabling interrupts on the final edge affects the next completion,
        // not the operation that sampled interrupt_enable low.
        write_reg(PORT_CTRL, 32'h18);
        prepare_job(1);
        clear_job_monitor();
        start_operation();
        repeat (3) begin
            @(posedge clock);
            #1;
        end
        check_state("before final enable collision", STATE_COMMIT);
        write_reg(PORT_CTRL, 32'h4);
        if (status_read_data[1] !== 1'b1 || irq_pending !== 1'b0 ||
            status_read_data[9] !== 1'b1) begin
            fail("final COMMIT enable collision snapshot mismatch");
        end
        if (busy_cycles_observed !== 4) fail("enable-collision job latency mismatch");
        check_commit_sequence(1);
        expected_completed_ops = 11;
        check_equal("enable-collision completed_ops", {24'h0, perf_read_data[7:0]}, expected_completed_ops);
        stop_job_monitor();
        write_reg(PORT_CTRL, 32'h18);
        pulse_clear_done();

        // Final immediate back-to-back job confirms retained operands/results
        // do not prevent another accepted four-cycle operation.
        prepare_job(1);
        clear_job_monitor();
        start_operation();
        wait_until_done_total(4, 8);
        check_commit_sequence(1);
        check_results(1);
        expected_completed_ops = 12;
        check_equal("back-to-back completed_ops", {24'h0, perf_read_data[7:0]}, expected_completed_ops);
        stop_job_monitor();

        reset_dut();
        write_reg(PORT_VECTOR, 32'h1234_5678);
        write_byte_enable = 4'b0100;
        write_reg(PORT_VECTOR, 32'h00aa_0000);
        check_equal("vector byte lane preserves other bytes", vector_read_data, 32'h12aa_5678);
        write_byte_enable = 4'b1111;
        write_row(4'd3, 32'h1234_5678);
        write_byte_enable = 4'b1100;
        write_reg(PORT_ROW_DATA, 32'hbeef_0000);
        check_equal("row halfword merge", row_data_read_data, 32'hbeef_5678);
        write_byte_enable = 4'b0010;
        write_reg(PORT_ROW_INDEX, 32'h0000_0900);
        check_equal("upper index byte preserves index", row_index_read_data, 32'd3);
        check_equal("upper index byte preserves readback", row_data_read_data, 32'hbeef_5678);
        write_reg(PORT_CTRL, 32'h0000_0100);
        check_equal("upper control byte cannot start job", status_read_data, 32'h0);
        write_byte_enable = 4'b1111;

        $display("PASS: MATVEC Scratchpad pipeline latency rows1=4 rows4=16 rows16=64 busy cycles");
        $display("PASS: tb_int8_matvec_scratchpad_accelerator passed");
        $finish;
    end
endmodule
