`timescale 1ns / 1ps

// Testbench: tb_boot_reset_controller
// Purpose: Checks boot/reset control behavior with directed stimulus.
// Checks: CPU reset gating for direct boot and loader-controlled boot release.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_boot_reset_controller;

    reg external_reset = 1'b0;
    reg loader_done = 1'b0;
    wire cpu_reset_loader_boot;
    wire boot_waiting_loader_boot;
    wire cpu_reset_direct_boot;
    wire boot_waiting_direct_boot;

    boot_reset_controller #(
        .BOOT_FROM_LOADER(1)
    ) loader_boot (
        .external_reset(external_reset),
        .loader_done(loader_done),
        .cpu_reset(cpu_reset_loader_boot),
        .boot_waiting(boot_waiting_loader_boot)
    );

    boot_reset_controller #(
        .BOOT_FROM_LOADER(0)
    ) direct_boot (
        .external_reset(external_reset),
        .loader_done(loader_done),
        .cpu_reset(cpu_reset_direct_boot),
        .boot_waiting(boot_waiting_direct_boot)
    );

    task check_state;
        input expected_loader_cpu_reset;
        input expected_loader_waiting;
        input expected_direct_cpu_reset;
        input expected_direct_waiting;
        begin
            #1;
            if (cpu_reset_loader_boot !== expected_loader_cpu_reset ||
                boot_waiting_loader_boot !== expected_loader_waiting ||
                cpu_reset_direct_boot !== expected_direct_cpu_reset ||
                boot_waiting_direct_boot !== expected_direct_waiting) begin
                $display("FAIL: ext_reset=%b loader_done=%b got loader(cpu_reset=%b waiting=%b) direct(cpu_reset=%b waiting=%b)",
                         external_reset,
                         loader_done,
                         cpu_reset_loader_boot,
                         boot_waiting_loader_boot,
                         cpu_reset_direct_boot,
                         boot_waiting_direct_boot);
                $fatal;
            end
            $display("PASS: ext_reset=%b loader_done=%b", external_reset, loader_done);
        end
    endtask

    initial begin
        $dumpfile("results/waveforms/tb_boot_reset_controller.vcd");
        $dumpvars(0, tb_boot_reset_controller);

        external_reset = 1'b1;
        loader_done = 1'b0;
        check_state(1'b1, 1'b1, 1'b1, 1'b0);

        external_reset = 1'b0;
        loader_done = 1'b0;
        check_state(1'b1, 1'b1, 1'b0, 1'b0);

        external_reset = 1'b0;
        loader_done = 1'b1;
        check_state(1'b0, 1'b0, 1'b0, 1'b0);

        external_reset = 1'b1;
        loader_done = 1'b1;
        check_state(1'b1, 1'b0, 1'b1, 1'b0);

        $display("PASS: tb_boot_reset_controller passed");
        $finish;
    end

endmodule
