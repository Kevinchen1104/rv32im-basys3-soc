`default_nettype none

module matvec_scratchpad_formal;
    (* gclk *) reg clock;
    reg reset = 1'b1;

    (* anyseq *) reg ctrl_write;
    (* anyseq *) reg config_write;
    (* anyseq *) reg vector_write;
    (* anyseq *) reg row_index_write;
    (* anyseq *) reg row_data_write;
    (* anyseq *) reg result_index_write;
    (* anyseq *) reg clear_done;
    (* anyseq *) reg [31:0] write_data;
    (* anyseq *) reg [3:0] write_byte_enable;

    wire [31:0] status_read_data;
    wire [31:0] config_read_data;
    wire [31:0] vector_read_data;
    wire [31:0] row_index_read_data;
    wire [31:0] row_data_read_data;
    wire [31:0] result_index_read_data;
    wire [31:0] result_data_read_data;
    wire [31:0] perf_read_data;
    wire irq_pending;

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

    wire busy = status_read_data[0];
    wire done = status_read_data[1];
    wire start_request = ctrl_write && write_byte_enable[0] && write_data[0];
    wire accepted_start = start_request && !busy;
    wire accepted_one_row = accepted_start && (config_read_data[3:0] == 4'h0);
    wire operand_write_request =
        config_write || vector_write || row_index_write ||
        row_data_write || result_index_write;

    reg past_valid = 1'b0;
    reg [2:0] one_row_age = 3'd0;
    integer lane;

    always @(posedge clock) begin
        past_valid <= 1'b1;
        if (!past_valid)
            reset <= 1'b1;
        else
            reset <= 1'b0;

        if (reset) begin
            one_row_age <= 3'd0;
        end else if (accepted_one_row) begin
            one_row_age <= 3'd1;
        end else if ((one_row_age != 3'd0) && (one_row_age != 3'd5)) begin
            one_row_age <= one_row_age + 3'd1;
        end else begin
            one_row_age <= 3'd0;
        end

        // Reset re-establishes every externally visible control/readback field.
        if (past_valid && $past(reset)) begin
            assert(status_read_data == 32'h0);
            assert(config_read_data == 32'h0);
            assert(vector_read_data == 32'h0);
            assert(row_index_read_data == 32'h0);
            assert(row_data_read_data == 32'h0);
            assert(result_index_read_data == 32'h0);
            assert(result_data_read_data == 32'h0);
            assert(perf_read_data == 32'h0);
            assert(!irq_pending);
        end

        if (past_valid && !$past(reset)) begin
            if ($past(!busy)) begin
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    if ($past(vector_write && write_byte_enable[lane]))
                        assert(vector_read_data[lane*8 +: 8] == $past(write_data[lane*8 +: 8]));
                    else
                        assert(vector_read_data[lane*8 +: 8] == $past(vector_read_data[lane*8 +: 8]));
                end
                if ($past(row_index_write && write_byte_enable[0]))
                    assert(row_index_read_data[3:0] == $past(write_data[3:0]));
                else
                    assert(row_index_read_data == $past(row_index_read_data));
            end
            // Any idle start is accepted on the following edge.
            if ($past(accepted_start)) begin
                assert(busy);
            end

            // Busy-time operand/index writes are isolated from staged state.
            if ($past(busy && operand_write_request)) begin
                assert(status_read_data[3]);
                assert(config_read_data == $past(config_read_data));
                assert(vector_read_data == $past(vector_read_data));
                assert(row_index_read_data == $past(row_index_read_data));
                assert(row_data_read_data == $past(row_data_read_data));
                assert(result_index_read_data == $past(result_index_read_data));
            end

            // A repeated start while busy is rejected and reported.
            if ($past(busy && start_request)) begin
                assert(status_read_data[2]);
            end
        end

        // A one-row accepted operation has four visible busy cycles, then
        // completes with done set. This proves a bounded progress recurrence
        // without claiming complete functional formal verification.
        if ((one_row_age >= 3'd1) && (one_row_age <= 3'd4))
            assert(busy);
        if (one_row_age == 3'd5) begin
            assert(!busy);
            assert(done);
            assert(perf_read_data[7:0] != 8'h0);
        end

        cover(past_valid && busy);
        cover(past_valid && done);
    end
endmodule

`default_nettype wire
