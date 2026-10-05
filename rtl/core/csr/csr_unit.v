`timescale 1ns/1ps

// Module: csr_unit
// Role: Selected machine-mode CSR file for traps, interrupts, and mret side effects.
// Interface: CSR address/function/write inputs, trap/mret events, pending interrupt inputs, and CSR readback outputs.
// Key behavior: Implements mstatus/mie/mtvec/mepc/mcause/mtval/mip readback, WARL masking, immediate trap-entry status updates, registered trap-metadata commit, and mret restoration for the supported subset.
// Non-goals: This is not a complete privileged-mode implementation.

module csr_unit (
    input clock,
    input reset,

    input [11:0] csr_addr,
    input [2:0] csr_funct3,
    input csr_write_enable,
    input [31:0] csr_rs1_value,
    input csr_rs1_nonzero,

    input trap_taken,
    input mret_taken,
    input [31:0] trap_pc,
    input [31:0] trap_cause,
    input [31:0] trap_tval,
    input mip_timer_pending,
    input mip_external_pending,

    output reg [31:0] csr_read_data,
    output [31:0] mstatus_out,
    output [31:0] mie_out,
    output [31:0] mtvec_out,
    output [31:0] mepc_out,
    output [31:0] mcause_out,
    output [31:0] mtval_out,
    output [31:0] mip_out,
    output trap_metadata_pending_out
);
    localparam CSR_MSTATUS = 12'h300;
    localparam CSR_MIE     = 12'h304;
    localparam CSR_MTVEC   = 12'h305;
    localparam CSR_MEPC    = 12'h341;
    localparam CSR_MCAUSE  = 12'h342;
    localparam CSR_MTVAL   = 12'h343;
    localparam CSR_MIP     = 12'h344;

    localparam [1:0] METADATA_MEPC   = 2'd0;
    localparam [1:0] METADATA_MCAUSE = 2'd1;
    localparam [1:0] METADATA_MTVAL  = 2'd2;

    localparam [31:0] MSTATUS_MIE  = 32'h0000_0008;
    localparam [31:0] MSTATUS_MPIE = 32'h0000_0080;
    localparam [31:0] MSTATUS_MPP  = 32'h0000_1800;
    localparam [31:0] MIE_MTIP     = 32'h0000_0080;
    localparam [31:0] MIE_MEIP     = 32'h0000_0800;
    localparam [31:0] INTERRUPT_MASK = MIE_MTIP | MIE_MEIP;

    reg [31:0] mstatus;
    reg [31:0] mie;
    reg [31:0] mtvec;
    reg [31:0] mepc;
    reg [31:0] mcause;
    reg [31:0] mtval;
    reg [31:0] mip;

    // Trap metadata is sampled every cycle so trap_taken never becomes the
    // clock-enable for this wide payload bank.  The one-bit pending event
    // records which sample belongs to an accepted trap.  This forms a
    // one-entry-per-cycle capture/commit pipeline: a pending sample commits
    // while a new trap sample can be captured on the same edge.
    reg [31:0] trap_pc_shadow;
    reg [31:0] trap_cause_shadow;
    reg [31:0] trap_tval_shadow;
    reg trap_metadata_pending;

    // Direct writes to trap metadata use the same registered-commit boundary.
    // The bypass below preserves normal CSR write/read visibility without
    // letting a same-cycle trap suppress the write through the 96-bit bank CE.
    // A registered trap-pending event suppresses capture of a direct request
    // that overlaps an older trap commit.
    reg [31:0] direct_metadata_write_shadow;
    reg [1:0] direct_metadata_write_select;
    reg direct_metadata_write_pending;

    // mtvec uses the same capture/commit pattern so trap acceptance controls
    // only a one-bit event rather than the clock enables of the 32-bit bank.
    // The visible bypass preserves same-cycle CSR readback and trap targeting.
    reg [31:0] direct_mtvec_write_shadow;
    reg direct_mtvec_write_pending;

    wire [31:0] mip_effective =
        mip |
        (mip_timer_pending ? 32'h0000_0080 : 32'h0) |
        (mip_external_pending ? 32'h0000_0800 : 32'h0);

    wire write_mstatus = csr_write_enable && (csr_addr == CSR_MSTATUS);
    wire write_mie     = csr_write_enable && (csr_addr == CSR_MIE);
    wire write_mtvec   = csr_write_enable && (csr_addr == CSR_MTVEC);
    wire write_mip     = csr_write_enable && (csr_addr == CSR_MIP);
    wire addr_is_mepc   = (csr_addr == CSR_MEPC);
    wire addr_is_mcause = (csr_addr == CSR_MCAUSE);
    wire addr_is_mtval  = (csr_addr == CSR_MTVAL);

    function [31:0] csr_write_result;
        input [31:0] current_value;
        input [2:0] funct3;
        input [31:0] rs1_value;
        input rs1_nonzero;
        begin
            case (funct3)
                3'b001: csr_write_result = rs1_value;
                3'b010: csr_write_result = rs1_nonzero ? (current_value | rs1_value) : current_value;
                3'b011: csr_write_result = rs1_nonzero ? (current_value & ~rs1_value) : current_value;
                default: csr_write_result = current_value;
            endcase
        end
    endfunction

    // Keep writable CSR bits to the supported machine-mode subset and force
    // MPP readback to machine mode for the trap-return model.
    function [31:0] warl_mstatus;
        input [31:0] raw_value;
        begin
            warl_mstatus = (raw_value & (MSTATUS_MIE | MSTATUS_MPIE)) | MSTATUS_MPP;
        end
    endfunction

    function [31:0] align_ialign32;
        input [31:0] raw_value;
        begin
            align_ialign32 = {raw_value[31:2], 2'b00};
        end
    endfunction

    wire direct_metadata_write_request =
        csr_write_enable &&
        (addr_is_mepc || addr_is_mcause || addr_is_mtval);
    wire [1:0] direct_metadata_write_request_select =
        addr_is_mepc ? METADATA_MEPC :
        addr_is_mcause ? METADATA_MCAUSE :
        METADATA_MTVAL;
    wire direct_metadata_bypass_valid =
        direct_metadata_write_pending && !trap_metadata_pending;
    wire [31:0] mtvec_visible =
        direct_mtvec_write_pending ? direct_mtvec_write_shadow : mtvec;
    wire [31:0] mepc_visible =
        (direct_metadata_bypass_valid &&
         (direct_metadata_write_select == METADATA_MEPC)) ?
            direct_metadata_write_shadow : mepc;
    wire [31:0] mcause_visible =
        (direct_metadata_bypass_valid &&
         (direct_metadata_write_select == METADATA_MCAUSE)) ?
            direct_metadata_write_shadow : mcause;
    wire [31:0] mtval_visible =
        (direct_metadata_bypass_valid &&
         (direct_metadata_write_select == METADATA_MTVAL)) ?
            direct_metadata_write_shadow : mtval;
    wire [31:0] direct_metadata_write_value =
        addr_is_mepc ?
            align_ialign32(csr_write_result(mepc_visible, csr_funct3, csr_rs1_value, csr_rs1_nonzero)) :
        addr_is_mcause ?
            csr_write_result(mcause_visible, csr_funct3, csr_rs1_value, csr_rs1_nonzero) :
            csr_write_result(mtval_visible, csr_funct3, csr_rs1_value, csr_rs1_nonzero);

    assign mstatus_out = mstatus;
    assign mie_out = mie;
    assign mtvec_out = mtvec_visible;
    assign mepc_out = mepc_visible;
    assign mcause_out = mcause_visible;
    assign mtval_out = mtval_visible;
    assign mip_out = mip_effective;
    assign trap_metadata_pending_out = trap_metadata_pending;

    always @(*) begin
        case (csr_addr)
            CSR_MSTATUS: csr_read_data = mstatus;
            CSR_MIE:     csr_read_data = mie;
            CSR_MTVEC:   csr_read_data = mtvec_visible;
            CSR_MEPC:    csr_read_data = mepc_visible;
            CSR_MCAUSE:  csr_read_data = mcause_visible;
            CSR_MTVAL:   csr_read_data = mtval_visible;
            CSR_MIP:     csr_read_data = mip_effective;
            default:     csr_read_data = 32'h0;
        endcase
    end

    // Keep one sequential process so direct CSR write data/address logic can be
    // shared, but give each register its own event chain. In particular, mret
    // is deliberately absent from every register-enable cone except mstatus.
    // Simultaneous mret and direct CSR write outside trap is an illegal input
    // combination; the integrated core proves they are mutually exclusive.
    // Trap retains global observable priority for standalone overlap tests.
    // Architectural trap metadata commits one edge after trap acceptance;
    // pending commit has priority over direct writes to the same registers.
    always @(posedge clock) begin
        if (reset) begin
            mstatus <= 32'h0;
            mie <= 32'h0;
            mtvec <= 32'h0;
            mepc <= 32'h0;
            mcause <= 32'h0;
            mtval <= 32'h0;
            mip <= 32'h0;
            trap_pc_shadow <= 32'h0;
            trap_cause_shadow <= 32'h0;
            trap_tval_shadow <= 32'h0;
            trap_metadata_pending <= 1'b0;
            direct_metadata_write_shadow <= 32'h0;
            direct_metadata_write_select <= METADATA_MEPC;
            direct_metadata_write_pending <= 1'b0;
            direct_mtvec_write_shadow <= 32'h0;
            direct_mtvec_write_pending <= 1'b0;
        end else begin
            // Unconditional sampling keeps trap acceptance out of all 96
            // shadow-payload enables. The registered event selects the sample
            // for architectural commit on the following edge.
            trap_pc_shadow <= align_ialign32(trap_pc);
            trap_cause_shadow <= trap_cause;
            trap_tval_shadow <= trap_tval;
            trap_metadata_pending <= trap_taken;

            // Data and selector capture never depend on trap acceptance.  The
            // registered old trap event suppresses an illegal direct request
            // overlapping its architectural commit; a new same-edge trap is
            // resolved by the registered commit priority on the next edge.
            direct_metadata_write_shadow <= direct_metadata_write_value;
            direct_metadata_write_select <= direct_metadata_write_request_select;
            direct_metadata_write_pending <=
                direct_metadata_write_request && !trap_metadata_pending;
            direct_mtvec_write_shadow <= align_ialign32(
                csr_write_result(
                    mtvec_visible,
                    csr_funct3,
                    csr_rs1_value,
                    csr_rs1_nonzero
                )
            );
            direct_mtvec_write_pending <= write_mtvec && !trap_taken;

            if (trap_taken) begin
                // Trap redirect is handled by the core on this same edge.
                // Status entry also remains immediate: snapshot MIE into MPIE
                // and disable nested entry before handler execution begins.
                mstatus[7] <= mstatus[3];
                mstatus[3] <= 1'b0;
                mstatus[12:11] <= 2'b11;
            end else if (mret_taken) begin
                // mret restores MIE from MPIE and leaves the core in the
                // supported machine-mode subset.
                mstatus[3] <= mstatus[7];
                mstatus[7] <= 1'b1;
                mstatus[12:11] <= 2'b11;
            end else if (write_mstatus) begin
                mstatus <= warl_mstatus(csr_write_result(mstatus, csr_funct3, csr_rs1_value, csr_rs1_nonzero));
            end

            // Trap acceptance suppresses every same-edge direct CSR write.
            // Pending commit is independent so an older trap can commit while
            // a back-to-back trap captures the next shadow sample.
            if (!trap_taken) begin
                if (write_mie) begin
                    mie <= csr_write_result(mie, csr_funct3, csr_rs1_value, csr_rs1_nonzero) & INTERRUPT_MASK;
                end
                if (write_mip) begin
                    mip <= csr_write_result(mip, csr_funct3, csr_rs1_value, csr_rs1_nonzero) & INTERRUPT_MASK;
                end
            end
            if (direct_mtvec_write_pending) begin
                mtvec <= direct_mtvec_write_shadow;
            end

            if (trap_metadata_pending) begin
                mepc <= trap_pc_shadow;
                mcause <= trap_cause_shadow;
                mtval <= trap_tval_shadow;
            end else if (direct_metadata_write_pending) begin
                case (direct_metadata_write_select)
                    METADATA_MEPC: begin
                        mepc <= direct_metadata_write_shadow;
                    end
                    METADATA_MCAUSE: begin
                        mcause <= direct_metadata_write_shadow;
                    end
                    METADATA_MTVAL: begin
                        mtval <= direct_metadata_write_shadow;
                    end
                    default: begin
                    end
                endcase
            end
        end
    end

endmodule
