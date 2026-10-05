`timescale 1ns/1ps

// Checks: Standalone CSR unit supports the local machine-mode CSR subset, including mtvec/mepc alignment, mtval
//   storage, mstatus/mie/mip WARL masking for implemented bits, hardware MTIP/MEIP readback, immediate trap-entry
//   mstatus updates, one-cycle registered trap-metadata commit, back-to-back capture/commit, and mret side effects.
// CPU-level tests exercise interrupt gating, redirect timing, and flush interactions.

module tb_csr_unit;
    reg clock;
    reg reset;
    reg [11:0] csr_addr;
    reg [2:0] csr_funct3;
    reg csr_write_enable;
    reg [31:0] csr_rs1_value;
    reg csr_rs1_nonzero;
    reg trap_taken;
    reg mret_taken;
    reg [31:0] trap_pc;
    reg [31:0] trap_cause;
    reg [31:0] trap_tval;
    reg mip_timer_pending;
    reg mip_external_pending;

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

    initial begin
        clock = 1'b0;
        forever #5 clock = ~clock;
    end

    task fail;
        input [255:0] message;
        begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    task check32;
        input [255:0] label;
        input [31:0] actual;
        input [31:0] expected;
        begin
            if (actual !== expected) begin
                $display("FAIL: %0s expected=%08x actual=%08x", label, expected, actual);
                $fatal(1);
            end
        end
    endtask

    task read_check;
        input [11:0] addr;
        input [31:0] expected;
        input [255:0] label;
        begin
            csr_addr = addr;
            #1;
            check32(label, csr_read_data, expected);
        end
    endtask

    task csr_write;
        input [11:0] addr;
        input [2:0] funct3;
        input [31:0] value;
        input nonzero;
        begin
            csr_addr = addr;
            csr_funct3 = funct3;
            csr_rs1_value = value;
            csr_rs1_nonzero = nonzero;
            csr_write_enable = 1'b1;
            @(posedge clock);
            #1;
            csr_write_enable = 1'b0;
        end
    endtask

    task take_trap;
        input [31:0] pc;
        input [31:0] cause;
        input [31:0] tval;
        begin
            trap_pc = pc;
            trap_cause = cause;
            trap_tval = tval;
            trap_taken = 1'b1;
            @(posedge clock);
            #1;
            trap_taken = 1'b0;
        end
    endtask

    task take_mret;
        begin
            mret_taken = 1'b1;
            @(posedge clock);
            #1;
            mret_taken = 1'b0;
        end
    endtask

    initial begin
        reset = 1'b1;
        csr_addr = 12'h000;
        csr_funct3 = 3'b000;
        csr_write_enable = 1'b0;
        csr_rs1_value = 32'h0;
        csr_rs1_nonzero = 1'b0;
        trap_taken = 1'b0;
        mret_taken = 1'b0;
        trap_pc = 32'h0;
        trap_cause = 32'h0;
        trap_tval = 32'h0;
        mip_timer_pending = 1'b0;
        mip_external_pending = 1'b0;

        repeat (2) @(posedge clock);
        #1;
        reset = 1'b0;
        #1;

        check32("reset mstatus_out", mstatus_out, 32'h0);
        check32("reset mie_out", mie_out, 32'h0);
        check32("reset mtvec_out", mtvec_out, 32'h0);
        check32("reset mepc_out", mepc_out, 32'h0);
        check32("reset mcause_out", mcause_out, 32'h0);
        check32("reset mtval_out", mtval_out, 32'h0);
        check32("reset mip_out", mip_out, 32'h0);
        read_check(12'h300, 32'h0, "reset mstatus read");
        read_check(12'h304, 32'h0, "reset mie read");
        read_check(12'h305, 32'h0, "reset mtvec read");
        read_check(12'h341, 32'h0, "reset mepc read");
        read_check(12'h342, 32'h0, "reset mcause read");
        read_check(12'h343, 32'h0, "reset mtval read");
        read_check(12'h344, 32'h0, "reset mip read");

        csr_write(12'h300, 3'b001, 32'h0000_00f0, 1'b1);
        check32("csrrw mstatus WARL out", mstatus_out, 32'h0000_1880);
        read_check(12'h300, 32'h0000_1880, "csrrw mstatus WARL read");

        csr_write(12'h300, 3'b010, 32'h0000_000f, 1'b1);
        check32("csrrs mstatus nonzero WARL", mstatus_out, 32'h0000_1888);

        csr_write(12'h300, 3'b010, 32'hffff_0000, 1'b0);
        check32("csrrs mstatus zero rs1", mstatus_out, 32'h0000_1888);

        csr_write(12'h304, 3'b001, 32'h0000_0800, 1'b1);
        check32("csrrw mie out", mie_out, 32'h0000_0800);
        read_check(12'h304, 32'h0000_0800, "csrrw mie read");
        csr_write(12'h304, 3'b010, 32'h0000_0010, 1'b1);
        check32("csrrs mie ignores unsupported bit", mie_out, 32'h0000_0800);
        csr_write(12'h304, 3'b011, 32'h0000_0010, 1'b1);
        check32("csrrc mie unsupported bit leaves value", mie_out, 32'h0000_0800);
        csr_write(12'h304, 3'b010, 32'h0000_0080, 1'b1);
        check32("csrrs mie MTIE", mie_out, 32'h0000_0880);

        csr_write(12'h305, 3'b001, 32'h0000_10ff, 1'b1);
        read_check(12'h305, 32'h0000_10fc, "csrrw mtvec direct aligned read");
        csr_write(12'h305, 3'b011, 32'h0000_00f0, 1'b1);
        check32("csrrc mtvec out remains aligned", mtvec_out, 32'h0000_100c);
        read_check(12'h305, 32'h0000_100c, "csrrc mtvec aligned read");

        csr_write(12'h341, 3'b001, 32'h0000_1237, 1'b1);
        check32("csrrw mepc out", mepc_out, 32'h0000_1234);
        read_check(12'h341, 32'h0000_1234, "csrrw mepc read");

        csr_write(12'h342, 3'b001, 32'h0000_000b, 1'b1);
        check32("csrrw mcause out", mcause_out, 32'h0000_000b);
        read_check(12'h342, 32'h0000_000b, "csrrw mcause read");

        csr_write(12'h343, 3'b001, 32'h1234_5678, 1'b1);
        check32("csrrw mtval out", mtval_out, 32'h1234_5678);
        read_check(12'h343, 32'h1234_5678, "csrrw mtval read");

        csr_write(12'h344, 3'b001, 32'h0000_0005, 1'b1);
        check32("csrrw mip ignores unsupported bits", mip_out, 32'h0000_0000);
        read_check(12'h344, 32'h0000_0000, "csrrw mip read");
        mip_external_pending = 1'b1;
        #1;
        check32("mip external pending out", mip_out, 32'h0000_0800);
        read_check(12'h344, 32'h0000_0800, "mip external pending read");
        csr_write(12'h344, 3'b011, 32'h0000_0001, 1'b1);
        check32("csrrc unsupported mip bit with external pending", mip_out, 32'h0000_0800);
        mip_external_pending = 1'b0;
        #1;
        check32("mip external pending low", mip_out, 32'h0000_0000);
        read_check(12'h344, 32'h0000_0000, "mip read after external low");
        mip_timer_pending = 1'b1;
        #1;
        check32("mip timer pending out", mip_out, 32'h0000_0080);
        read_check(12'h344, 32'h0000_0080, "mip timer pending read");
        mip_external_pending = 1'b1;
        #1;
        check32("mip timer and external pending out", mip_out, 32'h0000_0880);
        read_check(12'h344, 32'h0000_0880, "mip timer and external pending read");
        mip_timer_pending = 1'b0;
        mip_external_pending = 1'b0;
        #1;
        check32("mip timer and external pending low", mip_out, 32'h0000_0000);

        read_check(12'h999, 32'h0, "unknown csr read");

        take_trap(32'h0000_0080, 32'h0000_0011, 32'hfeed_0001);
        check32("trap with MIE=1 saves MPIE and clears MIE", mstatus_out, 32'h0000_1880);
        if (dut.trap_metadata_pending !== 1'b1) fail("trap edge did not register metadata pending");
        check32("trap edge preserves old mepc", mepc_out, 32'h0000_1234);
        check32("trap edge preserves old mcause", mcause_out, 32'h0000_000b);
        check32("trap edge preserves old mtval", mtval_out, 32'h1234_5678);
        @(posedge clock);
        #1;
        if (dut.trap_metadata_pending !== 1'b0) fail("metadata pending did not clear after commit");
        check32("pending commit writes mepc", mepc_out, 32'h0000_0080);
        check32("pending commit writes mcause", mcause_out, 32'h0000_0011);
        check32("pending commit writes mtval", mtval_out, 32'hfeed_0001);
        read_check(12'h341, 32'h0000_0080, "trap mepc read");
        read_check(12'h342, 32'h0000_0011, "trap mcause read");
        read_check(12'h343, 32'hfeed_0001, "trap mtval read");

        take_mret();
        check32("mret with MPIE=1 restores MIE and leaves MPIE set", mstatus_out, 32'h0000_1888);
        check32("mret preserves mepc", mepc_out, 32'h0000_0080);
        check32("mret preserves mcause", mcause_out, 32'h0000_0011);
        check32("mret preserves mtval", mtval_out, 32'hfeed_0001);
        check32("mret preserves mie", mie_out, 32'h0000_0880);
        check32("mret preserves mtvec", mtvec_out, 32'h0000_100c);
        check32("mret preserves mip", mip_out, 32'h0000_0000);

        csr_write(12'h300, 3'b001, 32'h0000_0000, 1'b1);
        take_trap(32'h0000_0093, 32'h0000_000b, 32'hfeed_0002);
        check32("trap with MIE=0 clears MIE and MPIE", mstatus_out, 32'h0000_1800);
        check32("second trap edge preserves mepc", mepc_out, 32'h0000_0080);
        check32("second trap edge preserves mcause", mcause_out, 32'h0000_0011);
        check32("second trap edge preserves mtval", mtval_out, 32'hfeed_0001);
        @(posedge clock);
        #1;
        check32("trap MIE=0 commits aligned mepc", mepc_out, 32'h0000_0090);
        check32("trap MIE=0 commits mcause", mcause_out, 32'h0000_000b);
        check32("trap MIE=0 commits mtval", mtval_out, 32'hfeed_0002);

        take_mret();
        check32("mret with MPIE=0 leaves MIE clear and sets MPIE", mstatus_out, 32'h0000_1880);

        take_mret();
        check32("mret with MPIE=1 restores MIE=1", mstatus_out, 32'h0000_1888);

        csr_write(12'h300, 3'b001, 32'h0000_0008, 1'b1);
        csr_addr = 12'h341;
        csr_funct3 = 3'b001;
        csr_rs1_value = 32'hdead_beef;
        csr_rs1_nonzero = 1'b1;
        csr_write_enable = 1'b1;
        trap_pc = 32'h0000_0044;
        trap_cause = 32'h0000_0022;
        trap_tval = 32'hfeed_0003;
        trap_taken = 1'b1;
        @(posedge clock);
        #1;
        csr_write_enable = 1'b0;
        trap_taken = 1'b0;
        check32("trap edge suppresses direct mepc write", mepc_out, 32'h0000_0090);
        check32("trap edge defers mcause", mcause_out, 32'h0000_000b);
        check32("trap edge defers mtval", mtval_out, 32'hfeed_0002);
        check32("trap priority over csr write updates mstatus", mstatus_out, 32'h0000_1880);
        check32("trap preserves mie", mie_out, 32'h0000_0880);
        check32("trap preserves mtvec", mtvec_out, 32'h0000_100c);
        check32("trap preserves mip", mip_out, 32'h0000_0000);
        @(posedge clock);
        #1;
        check32("trap priority mepc commit", mepc_out, 32'h0000_0044);
        check32("trap priority mcause commit", mcause_out, 32'h0000_0022);
        check32("trap priority mtval commit", mtval_out, 32'hfeed_0003);

        csr_write(12'h300, 3'b001, 32'h0000_0008, 1'b1);
        trap_pc = 32'h0000_0048;
        trap_cause = 32'h0000_0033;
        trap_tval = 32'hfeed_0004;
        trap_taken = 1'b1;
        mret_taken = 1'b1;
        @(posedge clock);
        #1;
        trap_taken = 1'b0;
        mret_taken = 1'b0;
        check32("trap priority over mret defers mepc", mepc_out, 32'h0000_0044);
        check32("trap priority over mret defers mcause", mcause_out, 32'h0000_0022);
        check32("trap priority over mret defers mtval", mtval_out, 32'hfeed_0003);
        check32("trap priority over mret updates mstatus", mstatus_out, 32'h0000_1880);

        @(posedge clock);
        #1;
        check32("trap priority over mret commits mepc", mepc_out, 32'h0000_0048);
        check32("trap priority over mret commits mcause", mcause_out, 32'h0000_0033);
        check32("trap priority over mret commits mtval", mtval_out, 32'hfeed_0004);

        // A pending trap commit wins over a simultaneous direct write to the
        // same architectural metadata register.
        take_trap(32'h0000_0053, 32'h0000_0044, 32'hfeed_0005);
        csr_addr = 12'h341;
        csr_funct3 = 3'b001;
        csr_rs1_value = 32'hdead_beef;
        csr_rs1_nonzero = 1'b1;
        csr_write_enable = 1'b1;
        @(posedge clock);
        #1;
        csr_write_enable = 1'b0;
        check32("pending commit beats direct mepc write", mepc_out, 32'h0000_0050);
        check32("pending commit retains mcause", mcause_out, 32'h0000_0044);
        check32("pending commit retains mtval", mtval_out, 32'hfeed_0005);

        // Back-to-back traps form a one-entry-per-cycle pipeline: edge two
        // commits trap A while capturing trap B, and edge three commits B.
        trap_pc = 32'h0000_0067;
        trap_cause = 32'h0000_0055;
        trap_tval = 32'hfeed_0006;
        trap_taken = 1'b1;
        @(posedge clock);
        #1;
        check32("back-to-back first capture preserves mepc", mepc_out, 32'h0000_0050);
        trap_pc = 32'h0000_007b;
        trap_cause = 32'h8000_000b;
        trap_tval = 32'h0;
        @(posedge clock);
        #1;
        check32("back-to-back edge commits first mepc", mepc_out, 32'h0000_0064);
        check32("back-to-back edge commits first mcause", mcause_out, 32'h0000_0055);
        check32("back-to-back edge commits first mtval", mtval_out, 32'hfeed_0006);
        if (dut.trap_metadata_pending !== 1'b1) fail("back-to-back capture lost pending event");
        trap_taken = 1'b0;
        @(posedge clock);
        #1;
        check32("back-to-back final commit mepc", mepc_out, 32'h0000_0078);
        check32("back-to-back final commit mcause", mcause_out, 32'h8000_000b);
        check32("back-to-back final commit mtval", mtval_out, 32'h0);
        if (dut.trap_metadata_pending !== 1'b0) fail("back-to-back pipeline did not drain");

        // Reset cancels a captured-but-not-yet-committed metadata event.
        take_trap(32'h0000_008c, 32'h0000_0066, 32'hfeed_0007);
        if (dut.trap_metadata_pending !== 1'b1) fail("reset test did not create pending event");
        reset = 1'b1;
        @(posedge clock);
        #1;
        reset = 1'b0;
        check32("reset cancels pending mepc", mepc_out, 32'h0);
        check32("reset cancels pending mcause", mcause_out, 32'h0);
        check32("reset cancels pending mtval", mtval_out, 32'h0);
        if (dut.trap_metadata_pending !== 1'b0) fail("reset did not clear metadata pending");

        $display("PASS: tb_csr_unit passed");
        $finish;
    end
endmodule
