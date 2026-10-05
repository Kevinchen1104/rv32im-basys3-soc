`timescale 1ns / 1ps

// Purpose: Checks MMIO D-cache bypass and precise interrupt acceptance across D-cache backpressure.
// Checks: Exhaustive mapped-register aliases, undefined page holes, one-shot MMIO effects, stall-held interrupt eligibility, and exception/mret priority.
// Pass condition: MMIO requests bypass without misses, ordinary addresses miss, and a deferred interrupt updates PC/CSRs exactly once after stall release.
// Assertion focus: Redirect requests may remain high during a stall, while PC and interrupt CSR side effects wait for the single acceptance boundary.

module tb_assert_interrupt_dcache_stall_release;

`include "tb_common.vh"

    localparam [6:0] LOAD = 7'b0000011;
    localparam [6:0] STORE = 7'b0100011;
    localparam [6:0] OP_IMM = 7'b0010011;
    localparam [6:0] BRANCH = 7'b1100011;
    localparam [31:0] MRET_INSTRUCTION = 32'h3020_0073;

    integer offset_index;
    integer interrupt_pulses;
    integer gpio_write_pulses;
    integer gpio_read_pulses;
    integer wait_cycles;
    reg monitor_interrupt;
    reg monitor_gpio;

    always @(posedge clock) begin
        if (!reset && monitor_interrupt && dut.interrupt_taken)
            interrupt_pulses = interrupt_pulses + 1;
        if (!reset && monitor_gpio && dut.EXMEMValid && dut.EXMEMGpioOutputAccess) begin
            if (dut.EXMEMMemWrite)
                gpio_write_pulses = gpio_write_pulses + 1;
            if (dut.EXMEMMemRead)
                gpio_read_pulses = gpio_read_pulses + 1;
        end
    end

    task wait_for_idex_pc;
        input [31:0] expected_pc;
        begin
            wait_cycles = 0;
            while (!(dut.IDEXValid && (dut.IDEXPC == expected_pc)) &&
                   (wait_cycles < 100)) begin
                @(negedge clock);
                wait_cycles = wait_cycles + 1;
            end
            if (!(dut.IDEXValid && (dut.IDEXPC == expected_pc))) begin
                $display("FAIL: timeout waiting for ID/EX PC %h", expected_pc);
                $fatal;
            end
        end
    endtask

    task check_cache_address;
        input [31:0] test_addr;
        input expected_mmio;
        begin
            force dut.EXMEMValid = 1'b1;
            force dut.EXMEMIR = 32'h0000_2083;  // lw x1, 0(x0)
            force dut.EXMEMALUOut = test_addr;
            #1;
            if ((dut.EXMEMAnyMmioSelect !== expected_mmio) ||
                (dut.EXMEMMmioAccess !== expected_mmio) ||
                (dut.cache_miss !== !expected_mmio)) begin
                $display("FAIL: addr %h mmio_select=%0b mmio_access=%0b cache_miss=%0b",
                         test_addr, dut.EXMEMAnyMmioSelect,
                         dut.EXMEMMmioAccess, dut.cache_miss);
                $fatal;
            end
            release dut.EXMEMALUOut;
            release dut.EXMEMIR;
            release dut.EXMEMValid;
        end
    endtask

    task check_register_aliases;
        input [31:0] register_addr;
        integer alias_index;
        begin
            for (alias_index = 0; alias_index < 4; alias_index = alias_index + 1)
                check_cache_address(register_addr + alias_index, 1'b1);
        end
    endtask

    task check_undefined_aliases;
        input [31:0] register_addr;
        integer alias_index;
        begin
            for (alias_index = 0; alias_index < 4; alias_index = alias_index + 1)
                check_cache_address(register_addr + alias_index, 1'b0);
        end
    endtask

    task check_out_of_range_address;
        input [31:0] test_addr;
        begin
            force dut.EXMEMValid = 1'b1;
            force dut.EXMEMIR = 32'h0000_2083;  // lw x1, 0(x0)
            force dut.EXMEMALUOut = test_addr;
            #1;
            if (dut.EXMEMAnyMmioSelect ||
                dut.EXMEMMmioAccess ||
                dut.cache_miss ||
                !dut.memory_access_fault_detect) begin
                $display("FAIL: OOB addr %h mmio=%0b cache_miss=%0b access_fault=%0b",
                         test_addr, dut.EXMEMMmioAccess,
                         dut.cache_miss, dut.memory_access_fault_detect);
                $fatal;
            end
            release dut.EXMEMALUOut;
            release dut.EXMEMIR;
            release dut.EXMEMValid;
        end
    endtask

    task run_mmio_bypass_sweep;
        begin
            reset = 1'b1;
            @(posedge clock);
            #1;

            for (offset_index = 0; offset_index <= 1; offset_index = offset_index + 1)
                check_register_aliases(32'h0000_0200 + (offset_index * 4));
            for (offset_index = 0; offset_index <= 2; offset_index = offset_index + 1)
                check_register_aliases(32'h0000_0300 + (offset_index * 4));
            for (offset_index = 0; offset_index <= 8; offset_index = offset_index + 1)
                check_register_aliases(32'h0000_0600 + (offset_index * 4));
            for (offset_index = 0; offset_index <= 8; offset_index = offset_index + 1)
                check_register_aliases(32'h0000_0700 + (offset_index * 4));
            for (offset_index = 0; offset_index <= 3; offset_index = offset_index + 1)
                check_register_aliases(32'h0000_0800 + (offset_index * 4));
            for (offset_index = 0; offset_index <= 7; offset_index = offset_index + 1)
                check_register_aliases(32'h0000_0900 + (offset_index * 4));

            check_undefined_aliases(32'h0000_0208);
            check_undefined_aliases(32'h0000_030c);
            for (offset_index = 0; offset_index < 64; offset_index = offset_index + 1) begin
                check_undefined_aliases(32'h0000_0400 + (offset_index * 4));
                check_undefined_aliases(32'h0000_0500 + (offset_index * 4));
            end
            check_undefined_aliases(32'h0000_0624);
            check_undefined_aliases(32'h0000_0724);
            check_undefined_aliases(32'h0000_0810);
            check_undefined_aliases(32'h0000_0920);
            check_out_of_range_address(32'h0001_0200);

            reset = 1'b0;
        end
    endtask

    task run_mmio_side_effect_once;
        begin
            reset_cpu();
            dut.IMemory[0] = i_type(12'h200, 5'd0, 3'b000, 5'd1, OP_IMM);
            dut.IMemory[1] = i_type(12'h05a, 5'd0, 3'b000, 5'd2, OP_IMM);
            dut.IMemory[2] = s_type(12'h000, 5'd2, 5'd1, 3'b010, STORE);
            dut.IMemory[3] = i_type(12'h000, 5'd1, 3'b010, 5'd3, LOAD);
            dut.IMemory[4] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            gpio_write_pulses = 0;
            gpio_read_pulses = 0;
            monitor_gpio = 1'b1;
            run_cycles(100);
            monitor_gpio = 1'b0;

            if ((gpio_write_pulses != 1) || (gpio_read_pulses != 1) ||
                (dut.GPIOOutput !== 32'h0000_005a) ||
                (dut.Regs[3] !== 32'h0000_005a)) begin
                $display("FAIL: GPIO MMIO effects write=%0d read=%0d gpio=%h x3=%h",
                         gpio_write_pulses, gpio_read_pulses,
                         dut.GPIOOutput, dut.Regs[3]);
                $fatal;
            end
        end
    endtask

    task run_interrupt_stall_release;
        reg [31:0] held_pc;
        reg [31:0] held_idex_pc;
        begin
            reset_cpu();
            dut.IMemory[16] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            dut.csr_unit_inst.mstatus = 32'h0000_1808;
            dut.csr_unit_inst.mie = 32'h0000_0800;
            dut.csr_unit_inst.mtvec = 32'd64;
            dut.csr_unit_inst.mepc = 32'h0000_0120;
            dut.csr_unit_inst.mcause = 32'h0000_0055;
            interrupt_pulses = 0;
            monitor_interrupt = 1'b1;
            force dut.matvec_irq_pending = 1'b1;

            wait_for_idex_pc(32'd0);
            force dut.cache_miss = 1'b1;
            #1;
            held_pc = dut.PC;
            held_idex_pc = dut.IDEXPC;
            if (!dut.interrupt_eligible || dut.interrupt_taken ||
                !dut.redirect_taken || dut.if_redirect ||
                (dut.CSRmepc !== 32'h0000_0120) ||
                (dut.CSRmcause !== 32'h0000_0055)) begin
                $display("FAIL: pending interrupt stall eligible=%0b taken=%0b request=%0b apply=%0b valid=%0b pending=%0b control=%0b deferred=%0b mext=%0b stall=%0b mepc=%h mcause=%h",
                         dut.interrupt_eligible, dut.interrupt_taken,
                         dut.redirect_taken, dut.if_redirect, dut.IDEXValid,
                         dut.machine_interrupt_pending,
                         dut.IDEXBranch || dut.IDEXJump,
                         dut.ControlInterruptDeferred, dut.IDEXMExtension,
                         dut.dcache_pipeline_stall, dut.CSRmepc, dut.CSRmcause);
                $fatal;
            end

            repeat (3) begin
                @(posedge clock);
                #1;
                if (!dut.interrupt_eligible || dut.interrupt_taken ||
                    !dut.redirect_taken || dut.if_redirect ||
                    (dut.PC !== held_pc) || (dut.IDEXPC !== held_idex_pc) ||
                    (dut.CSRmepc !== 32'h0000_0120) ||
                    (dut.CSRmcause !== 32'h0000_0055)) begin
                    $display("FAIL: stalled interrupt changed pipeline or CSR state");
                    $fatal;
                end
            end

            @(negedge clock);
            release dut.cache_miss;
            #1;
            if (!dut.interrupt_eligible || !dut.interrupt_taken ||
                !dut.redirect_taken || !dut.if_redirect ||
                (dut.redirect_pc !== 32'd64)) begin
                $display("FAIL: interrupt was not accepted when D-cache stall cleared");
                $fatal;
            end

            @(posedge clock);
            #1;
            if ((dut.PC !== 32'd64) ||
                (dut.CSRmepc !== 32'h0000_0120) ||
                (dut.CSRmcause !== 32'h0000_0055) ||
                (dut.csr_unit_inst.trap_metadata_pending !== 1'b1) ||
                dut.CSRmstatus[3] || (interrupt_pulses != 1)) begin
                $display("FAIL: accepted interrupt redirect/status/capture mismatch");
                $fatal;
            end
            @(posedge clock);
            #1;
            if ((dut.CSRmepc !== 32'd0) ||
                (dut.CSRmcause !== 32'h8000_000b) ||
                (dut.CSRmtval !== 32'h0) ||
                (dut.csr_unit_inst.trap_metadata_pending !== 1'b0)) begin
                $display("FAIL: accepted interrupt metadata did not commit one edge later");
                $fatal;
            end
            repeat (5) @(posedge clock);
            #1;
            if (interrupt_pulses != 1) begin
                $display("FAIL: interrupt acceptance repeated after stall release");
                $fatal;
            end

            release dut.matvec_irq_pending;
            monitor_interrupt = 1'b0;
        end
    endtask

    task run_exception_interrupt_stall_priority;
        begin
            reset_cpu();
            dut.IMemory[0] = 32'hffff_ffff;
            dut.csr_unit_inst.mstatus = 32'h0000_1808;
            dut.csr_unit_inst.mie = 32'h0000_0800;
            dut.csr_unit_inst.mtvec = 32'd64;
            force dut.matvec_irq_pending = 1'b1;
            wait_for_idex_pc(32'd0);
            force dut.cache_miss = 1'b1;
            repeat (3) begin
                #1;
                if (dut.exception_taken || !dut.interrupt_eligible ||
                    dut.interrupt_taken || !dut.redirect_taken || dut.if_redirect ||
                    dut.trap_taken || dut.csr_unit_inst.trap_metadata_pending ||
                    (dut.CSRmstatus !== 32'h0000_1808)) begin
                    $display("FAIL: stalled exception produced an architectural trap side effect");
                    $fatal;
                end
                @(posedge clock);
            end
            @(negedge clock);
            release dut.cache_miss;
            #1;
            if (!dut.exception_taken || dut.interrupt_taken || !dut.if_redirect) begin
                $display("FAIL: exception priority changed when stall cleared");
                $fatal;
            end
            @(posedge clock);
            #1;
            if (dut.csr_unit_inst.trap_metadata_pending !== 1'b1) begin
                $display("FAIL: exception did not register metadata pending");
                $fatal;
            end
            @(posedge clock);
            #1;
            release dut.matvec_irq_pending;
            if ((dut.CSRmepc !== 32'd0) || (dut.CSRmcause !== 32'd2) ||
                (dut.CSRmtval !== 32'hffff_ffff)) begin
                $display("FAIL: exception CSR state was replaced by pending interrupt");
                $fatal;
            end
        end
    endtask

    task run_mret_interrupt_stall_priority;
        begin
            reset_cpu();
            dut.IMemory[0] = MRET_INSTRUCTION;
            dut.csr_unit_inst.mstatus = 32'h0000_1888;
            dut.csr_unit_inst.mie = 32'h0000_0800;
            dut.csr_unit_inst.mepc = 32'd32;
            force dut.matvec_irq_pending = 1'b1;
            wait_for_idex_pc(32'd0);
            force dut.cache_miss = 1'b1;
            #1;
            if (!dut.mret_taken || !dut.interrupt_eligible ||
                dut.interrupt_taken || !dut.redirect_taken || dut.if_redirect ||
                dut.architectural_mret_taken) begin
                $display("FAIL: stalled mret did not defer redirect and interrupt acceptance");
                $fatal;
            end
            release dut.cache_miss;
            #1;
            if (!dut.mret_taken || dut.interrupt_taken || !dut.if_redirect ||
                !dut.architectural_mret_taken || (dut.redirect_pc !== 32'd32)) begin
                $display("FAIL: mret did not retain priority when stall cleared");
                $fatal;
            end
            @(posedge clock);
            #1;
            release dut.matvec_irq_pending;
            if (dut.PC !== 32'd32) begin
                $display("FAIL: mret redirected to %h instead of mepc", dut.PC);
                $fatal;
            end
        end
    endtask

    initial begin
        $dumpfile("results/waveforms/tb_assert_interrupt_dcache_stall_release.vcd");
        $dumpvars(0, tb_assert_interrupt_dcache_stall_release);
        monitor_interrupt = 1'b0;
        monitor_gpio = 1'b0;
        interrupt_pulses = 0;
        gpio_write_pulses = 0;
        gpio_read_pulses = 0;

        run_mmio_bypass_sweep();
        run_mmio_side_effect_once();
        run_interrupt_stall_release();
        run_exception_interrupt_stall_priority();
        run_mret_interrupt_stall_priority();

        $display("PASS: MMIO bypass and interrupt D-cache stall release remained precise");
        $display("PASS: tb_assert_interrupt_dcache_stall_release passed");
        $finish;
    end

endmodule
