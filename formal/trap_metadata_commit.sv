`default_nettype none

module trap_metadata_commit_formal;
    (* gclk *) reg clock;
    reg reset = 1'b1;

    (* anyseq *) reg [11:0] csr_addr;
    (* anyseq *) reg [2:0] csr_funct3;
    (* anyseq *) reg csr_write_enable;
    (* anyseq *) reg [31:0] csr_rs1_value;
    (* anyseq *) reg csr_rs1_nonzero;
    (* anyseq *) reg trap_taken;
    (* anyseq *) reg mret_taken;
    (* anyseq *) reg [31:0] trap_pc;
    (* anyseq *) reg [31:0] trap_cause;
    (* anyseq *) reg [31:0] trap_tval;
    (* anyseq *) reg mip_timer_pending;
    (* anyseq *) reg mip_external_pending;

    wire [31:0] csr_read_data;
    wire [31:0] mstatus_out;
    wire [31:0] mie_out;
    wire [31:0] mtvec_out;
    wire [31:0] mepc_out;
    wire [31:0] mcause_out;
    wire [31:0] mtval_out;
    wire [31:0] mip_out;
    wire trap_metadata_pending_out;

    csr_unit dut (
        .clock(clock),
        .reset(reset),
        .csr_addr(csr_addr),
        .csr_funct3(csr_funct3),
        .csr_write_enable(csr_write_enable),
        .csr_rs1_value(csr_rs1_value),
        .csr_rs1_nonzero(csr_rs1_nonzero),
        .trap_taken(trap_taken),
        .mret_taken(mret_taken),
        .trap_pc(trap_pc),
        .trap_cause(trap_cause),
        .trap_tval(trap_tval),
        .mip_timer_pending(mip_timer_pending),
        .mip_external_pending(mip_external_pending),
        .csr_read_data(csr_read_data),
        .mstatus_out(mstatus_out),
        .mie_out(mie_out),
        .mtvec_out(mtvec_out),
        .mepc_out(mepc_out),
        .mcause_out(mcause_out),
        .mtval_out(mtval_out),
        .mip_out(mip_out),
        .trap_metadata_pending_out(trap_metadata_pending_out)
    );

    reg [1:0] past_valid = 2'b00;
    always @(posedge clock) begin
        past_valid <= {past_valid[0], 1'b1};
        reset <= 1'b0;

        if (past_valid[0]) begin
            if ($past(reset)) begin
                assert(!trap_metadata_pending_out);
                assert(mepc_out == 32'h0);
                assert(mcause_out == 32'h0);
                assert(mtval_out == 32'h0);
            end else begin
                assert(trap_metadata_pending_out == $past(trap_taken));

                // Trap status entry is visible immediately after the accepted
                // edge, independent of the registered metadata commit.
                if ($past(trap_taken)) begin
                    assert(!mstatus_out[3]);
                    assert(mstatus_out[7] == $past(mstatus_out[3]));
                    assert(mstatus_out[12:11] == 2'b11);
                end

                // With no older pending commit, trap capture suppresses any
                // simultaneous direct write to architectural metadata.
                if ($past(trap_taken) && !$past(trap_metadata_pending_out)) begin
                    assert(mepc_out == $past(mepc_out));
                    assert(mcause_out == $past(mcause_out));
                    assert(mtval_out == $past(mtval_out));
                end
            end
        end

        if (past_valid[1] &&
            !$past(reset) && !$past(reset, 2) &&
            $past(trap_metadata_pending_out)) begin
            // The older sample commits even if a new trap is captured on the
            // same edge, proving one-event-per-cycle back-to-back throughput.
            assert(mepc_out == ($past(trap_pc, 2) & 32'hffff_fffc));
            assert(mcause_out == $past(trap_cause, 2));
            assert(mtval_out == $past(trap_tval, 2));
        end
    end
endmodule

`default_nettype wire
