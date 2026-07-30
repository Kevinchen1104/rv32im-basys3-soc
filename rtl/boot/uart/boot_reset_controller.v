`timescale 1ns / 1ps

// Module: boot_reset_controller
// Role: Reset gate that keeps the CPU held until boot loading is complete.
// Interface: External reset, loader done signal, and generated CPU reset output.
// Key behavior: Combines external reset with boot completion so the CPU starts only after the selected loader releases it.

module boot_reset_controller #(
    parameter BOOT_FROM_LOADER = 0
) (
    input external_reset,
    input loader_done,
    output cpu_reset,
    output boot_waiting
);

    // Boot-from-loader mode keeps reset asserted after external reset drops
    // until the selected loader reports a complete image.
    assign boot_waiting = BOOT_FROM_LOADER && !loader_done;
    assign cpu_reset = external_reset || boot_waiting;

endmodule
