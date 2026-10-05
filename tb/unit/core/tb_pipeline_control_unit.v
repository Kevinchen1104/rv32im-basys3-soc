`timescale 1ns / 1ps

// Testbench: tb_pipeline_control_unit
// Purpose: Checks a focused CPU core unit or core-level smoke path.
// Checks: Standalone pipeline control unit preserves IF/ID/EX stall, redirect, bubble, and advance priority
//   decisions.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_pipeline_control_unit;
    reg dcache_pipeline_stall;
    reg redirect_taken;
    reg icache_pipeline_stall;
    reg load_use_hazard;
    reg execute_busy_stall;

    wire if_hold;
    wire if_redirect;
    wire if_advance;
    wire id_hold;
    wire id_bubble;
    wire id_advance;
    wire ex_hold;
    wire ex_advance;

    pipeline_control_unit dut (
        .dcache_pipeline_stall(dcache_pipeline_stall),
        .redirect_taken(redirect_taken),
        .icache_pipeline_stall(icache_pipeline_stall),
        .load_use_hazard(load_use_hazard),
        .execute_busy_stall(execute_busy_stall),
        .if_hold(if_hold),
        .if_redirect(if_redirect),
        .if_advance(if_advance),
        .id_hold(id_hold),
        .id_bubble(id_bubble),
        .id_advance(id_advance),
        .ex_hold(ex_hold),
        .ex_advance(ex_advance)
    );

    task fail;
        input [8*120-1:0] msg;
        begin
            $display("FAIL: %0s", msg);
            $fatal(1);
        end
    endtask

    task drive;
        input dcache_stall_in;
        input redirect_in;
        input icache_stall_in;
        input load_use_in;
        input execute_busy_in;
        begin
            dcache_pipeline_stall = dcache_stall_in;
            redirect_taken = redirect_in;
            icache_pipeline_stall = icache_stall_in;
            load_use_hazard = load_use_in;
            execute_busy_stall = execute_busy_in;
            #1;
        end
    endtask

    task check_outputs;
        input exp_if_hold;
        input exp_if_redirect;
        input exp_if_advance;
        input exp_id_hold;
        input exp_id_bubble;
        input exp_id_advance;
        input exp_ex_hold;
        input exp_ex_advance;
        input [8*80-1:0] label;
        begin
            if (if_hold !== exp_if_hold) begin
                fail({label, " if_hold"});
            end
            if (if_redirect !== exp_if_redirect) begin
                fail({label, " if_redirect"});
            end
            if (if_advance !== exp_if_advance) begin
                fail({label, " if_advance"});
            end
            if (id_hold !== exp_id_hold) begin
                fail({label, " id_hold"});
            end
            if (id_bubble !== exp_id_bubble) begin
                fail({label, " id_bubble"});
            end
            if (id_advance !== exp_id_advance) begin
                fail({label, " id_advance"});
            end
            if (ex_hold !== exp_ex_hold) begin
                fail({label, " ex_hold"});
            end
            if (ex_advance !== exp_ex_advance) begin
                fail({label, " ex_advance"});
            end
        end
    endtask

    initial begin
        drive(1'b0, 1'b0, 1'b0, 1'b0, 1'b0);
        check_outputs(1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b1, "no hazards");

        drive(1'b1, 1'b0, 1'b0, 1'b0, 1'b0);
        check_outputs(1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, "dcache stall");

        drive(1'b0, 1'b1, 1'b0, 1'b0, 1'b0);
        check_outputs(1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, "redirect");

        drive(1'b0, 1'b0, 1'b1, 1'b0, 1'b0);
        check_outputs(1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, "icache stall");

        drive(1'b0, 1'b0, 1'b0, 1'b1, 1'b0);
        check_outputs(1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, "load use");

        drive(1'b0, 1'b0, 1'b0, 1'b0, 1'b1);
        check_outputs(1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, "execute busy");

        drive(1'b0, 1'b1, 1'b0, 1'b0, 1'b1);
        check_outputs(1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, "redirect over execute busy");

        drive(1'b1, 1'b1, 1'b0, 1'b0, 1'b0);
        check_outputs(1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, "dcache over redirect");

        drive(1'b0, 1'b1, 1'b1, 1'b0, 1'b0);
        check_outputs(1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, "redirect over icache");

        drive(1'b0, 1'b1, 1'b0, 1'b1, 1'b0);
        check_outputs(1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, "redirect over load use");

        drive(1'b0, 1'b0, 1'b1, 1'b1, 1'b0);
        check_outputs(1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, "icache plus load use");

        drive(1'b1, 1'b1, 1'b1, 1'b1, 1'b1);
        check_outputs(1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, "all asserted");

        $display("PASS: tb_pipeline_control_unit passed");
        $finish;
    end
endmodule
