`timescale 1ns / 1ps

// Testbench: tb_assert_exmem_invalid_side_effect_isolation
// Purpose: Proves EX/MEM validity, not payload contents, authorizes memory-stage effects.
// Checks: Nonzero invalid load/store/ALU payload cannot request D-cache/external memory, write normal memory,
//   debug status, GPIO, UART, timer, MATVEC, or DMA descriptors, retire, trace, or write a register. Directed
//   exception, interrupt, redirect, and RV32M bubbles clear validity while stale payload/write metadata remain
//   side-effect isolated.
// Pass condition: Every invalid-payload and bubble check completes without an architectural side effect.
// Does not prove: Directed hierarchical assertion evidence only; not a complete pipeline formal proof, timing
//   closure result, cache-protocol proof, or physical-board validation.

module tb_assert_exmem_invalid_side_effect_isolation;
    reg clock = 1'b0;
    reg reset = 1'b0;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;
    wire [31:0] dmem_addr;
    wire dmem_read;
    wire dmem_write;
    wire [127:0] dmem_wdata;
    wire [15:0] dmem_byte_enable;
    wire trace_valid;
    wire trace_reg_write;
    wire [31:0] gpio_outputs;
    wire [7:0] uart_tx_data;
    wire uart_tx_valid;

    RISCVCPU dut (
        .clock(clock),
        .reset(reset),
        .imem_addr(),
        .imem_read(),
        .imem_rdata(128'h0),
        .imem_ready(1'b0),
        .dmem_addr(dmem_addr),
        .dmem_read(dmem_read),
        .dmem_write(dmem_write),
        .dmem_wdata(dmem_wdata),
        .dmem_byte_enable(dmem_byte_enable),
        .dmem_rdata(128'h0),
        .dmem_ready(1'b0),
        .debug_status(debug_status),
        .debug_pc(debug_pc),
        .trace_valid(trace_valid),
        .trace_pc(),
        .trace_instruction(),
        .trace_rd(),
        .trace_reg_write(trace_reg_write),
        .trace_writeback_value(),
        .perf_cycle_count(),
        .perf_retired_count(),
        .perf_branch_miss_count(),
        .perf_icache_miss_count(),
        .perf_dcache_miss_count(),
        .perf_stall_cycle_count(),
        .gpio_inputs(32'h0),
        .gpio_outputs(gpio_outputs),
        .uart_tx_data(uart_tx_data),
        .uart_tx_valid(uart_tx_valid),
        .uart_tx_ready(1'b1),
        .uart_rx_data(8'h00),
        .uart_rx_valid(1'b0),
        .uart_rx_overrun(1'b0),
        .uart_rx_ready()
    );

    always #5 clock = ~clock;

    task reset_core;
        begin
            reset = 1'b1;
            repeat (2) @(posedge clock);
            #1;
            reset = 1'b0;
            @(negedge clock);
        end
    endtask

    task exercise_invalid_payload;
        input [255:0] label;
        input [31:0] instruction;
        input [31:0] address;
        input [31:0] store_value;
        reg [31:0] dmem_before;
        reg [31:0] debug_before;
        reg [31:0] gpio_before;
        reg [7:0] uart_data_before;
        reg [63:0] mtimecmp_before;
        reg [31:0] matvec_config_before;
        reg [31:0] matvec_status_before;
        reg [31:0] dma_vec_addr_before;
        begin
            reset_core();
            dut.DMemory[0] = 32'h1122_3344;
            dmem_before = dut.DMemory[0];
            debug_before = dut.DebugStatus;
            gpio_before = dut.GPIOOutput;
            uart_data_before = dut.UARTTxData;
            mtimecmp_before = dut.gen_machine_timer.timer.mtimecmp;
            matvec_config_before = dut.matvec_config_read_data;
            matvec_status_before = dut.matvec_status_read_data;
            dma_vec_addr_before = dut.matvec_dma_vec_addr_read_data;

            force dut.EXMEMValid = 1'b0;
            force dut.EXMEMIR = instruction;
            force dut.EXMEMPC = 32'hdead_1000;
            force dut.EXMEMPCPlus4 = 32'hdead_1004;
            force dut.EXMEMALUOut = address;
            force dut.EXMEMB = store_value;
            force dut.EXMEMForwardRegWrite = 1'b1;
            force dut.EXMEMWritebackRegWrite = 1'b1;
            force dut.EXMEMForwardRd = 5'd9;
            force dut.EXMEMForwardUsePCPlus4 = 1'b1;

            #1;
            if (dut.EXMEMValid !== 1'b0 ||
                dut.gen_dcache.dcache.request_valid !== 1'b0 ||
                dut.EXMEMMmioAccess !== 1'b0 ||
                dmem_read !== 1'b0 || dmem_write !== 1'b0) begin
                $display("FAIL: %0s invalid payload requested memory/MMIO valid=%0b req=%0b mmio=%0b dmem=%0b/%0b",
                         label, dut.EXMEMValid, dut.gen_dcache.dcache.request_valid,
                         dut.EXMEMMmioAccess, dmem_read, dmem_write);
                $fatal;
            end

            @(posedge clock);
            #1;
            if (dut.DMemory[0] !== dmem_before ||
                dut.DebugStatus !== debug_before ||
                dut.GPIOOutput !== gpio_before ||
                dut.UARTTxData !== uart_data_before ||
                dut.UARTTxValid !== 1'b0 ||
                dut.UARTRxReady !== 1'b0 ||
                dut.gen_machine_timer.timer.mtimecmp !== mtimecmp_before ||
                dut.matvec_config_read_data !== matvec_config_before ||
                dut.matvec_status_read_data !== matvec_status_before ||
                dut.matvec_dma_vec_addr_read_data !== dma_vec_addr_before) begin
                $display("FAIL: %0s invalid payload changed an architectural/MMIO state", label);
                $fatal;
            end
            if (dut.MEMWBValid !== 1'b0 ||
                dut.MEMWBForwardRegWrite !== 1'b0 ||
                dut.MEMWBRegWrite !== 1'b0 ||
                dut.TraceValid !== 1'b0 ||
                trace_valid !== 1'b0 || trace_reg_write !== 1'b0) begin
                $display("FAIL: %0s invalid payload retired or enabled writeback", label);
                $fatal;
            end
            if ((instruction[6:0] == 7'b0110011) &&
                (dut.MEMWBValue !== address)) begin
                $display("FAIL: %0s did not exercise a nonzero stale ALU MEM/WB value", label);
                $fatal;
            end
            if ((instruction[6:0] == 7'b1101111) &&
                (dut.MEMWBValue !== 32'hdead_1004)) begin
                $display("FAIL: %0s did not exercise a nonzero stale jump MEM/WB value", label);
                $fatal;
            end

            release dut.EXMEMValid;
            release dut.EXMEMIR;
            release dut.EXMEMPC;
            release dut.EXMEMPCPlus4;
            release dut.EXMEMALUOut;
            release dut.EXMEMB;
            release dut.EXMEMForwardRegWrite;
            release dut.EXMEMWritebackRegWrite;
            release dut.EXMEMForwardRd;
            release dut.EXMEMForwardUsePCPlus4;
        end
    endtask

    task check_runtime_bubble;
        input [255:0] label;
        input [1:0] bubble_kind;
        begin
            reset_core();
            dut.EXMEMIR = 32'h0020_82b3;
            dut.EXMEMPC = 32'hcafe_1000;
            dut.EXMEMPCPlus4 = 32'hcafe_1004;
            dut.EXMEMALUOut = 32'hcafe_2000;
            dut.EXMEMB = 32'hcafe_3000;
            dut.EXMEMValid = 1'b1;
            dut.EXMEMForwardRegWrite = 1'b1;
            dut.EXMEMWritebackRegWrite = 1'b1;
            dut.EXMEMForwardRd = 5'd7;
            dut.EXMEMForwardUsePCPlus4 = 1'b1;

            force dut.ex_advance = 1'b1;
            force dut.ex_hold = 1'b0;
            case (bubble_kind)
                2'd0: force dut.exception_taken = 1'b1;
                2'd1: force dut.interrupt_taken = 1'b1;
                2'd2: force dut.control_redirect_apply = 1'b1;
                default: force dut.rv32m_execute_stall = 1'b1;
            endcase

            @(posedge clock);
            #1;
            if (dut.EXMEMValid !== 1'b0) begin
                $display("FAIL: %0s did not clear EX/MEM validity", label);
                $fatal;
            end
            if (dut.EXMEMForwardRegWrite !== 1'b1 ||
                dut.EXMEMWritebackRegWrite !== 1'b1 ||
                dut.EXMEMForwardRd !== 5'd7 ||
                dut.EXMEMForwardUsePCPlus4 !== 1'b1) begin
                $display("FAIL: %0s unexpectedly cleared stale EX/MEM write metadata", label);
                $fatal;
            end
            if (dut.EXMEMForwardProducerValid !== 1'b0 ||
                dut.EXMEMRegWrite !== 1'b0 ||
                dut.gen_dcache.dcache.request_valid !== 1'b0 ||
                dut.EXMEMMmioAccess !== 1'b0) begin
                $display("FAIL: %0s stale EX/MEM metadata authorized a side effect", label);
                $fatal;
            end
            release dut.ex_advance;
            release dut.ex_hold;
            case (bubble_kind)
                2'd0: release dut.exception_taken;
                2'd1: release dut.interrupt_taken;
                2'd2: release dut.control_redirect_apply;
                default: release dut.rv32m_execute_stall;
            endcase
        end
    endtask

    initial begin
        $dumpfile("wave/tb_assert_exmem_invalid_side_effect_isolation.vcd");
        $dumpvars(0, tb_assert_exmem_invalid_side_effect_isolation);

        reset_core();
        if (dut.EXMEMValid !== 1'b0 ||
            dut.EXMEMForwardRegWrite !== 1'b0 ||
            dut.EXMEMWritebackRegWrite !== 1'b0 ||
            dut.EXMEMForwardRd !== 5'd0 ||
            dut.EXMEMForwardUsePCPlus4 !== 1'b0) begin
            $display("FAIL: reset did not clear EX/MEM validity/write metadata");
            $fatal;
        end

        exercise_invalid_payload("normal store", 32'h0020_2023, 32'h0000_0000, 32'ha5a5_0001);
        exercise_invalid_payload("normal load", 32'h0000_2083, 32'h0000_0000, 32'ha5a5_0002);
        exercise_invalid_payload("ALU writeback", 32'h0020_82b3, 32'h5a5a_1000, 32'ha5a5_0009);
        exercise_invalid_payload("jump writeback", 32'h0000_00ef, 32'h5a5a_2000, 32'ha5a5_000a);
        exercise_invalid_payload("debug status store", 32'h0020_2023, 32'h0000_0100, 32'ha5a5_0003);
        exercise_invalid_payload("GPIO store", 32'h0020_2023, 32'h0000_0200, 32'ha5a5_0004);
        exercise_invalid_payload("UART store", 32'h0020_2023, 32'h0000_0300, 32'ha5a5_0005);
        exercise_invalid_payload("MATVEC Scratchpad store", 32'h0020_2023, 32'h0000_0708, 32'ha5a5_0006);
        exercise_invalid_payload("timer compare store", 32'h0020_2023, 32'h0000_0808, 32'ha5a5_0007);
        exercise_invalid_payload("DMA descriptor store", 32'h0020_2023, 32'h0000_0900, 32'ha5a5_0008);

        check_runtime_bubble("exception bubble", 2'd0);
        check_runtime_bubble("interrupt bubble", 2'd1);
        check_runtime_bubble("control/mret redirect bubble", 2'd2);
        check_runtime_bubble("RV32M wait bubble", 2'd3);

        // A D-cache stall holds an already valid transaction and its payload.
        reset_core();
        dut.EXMEMIR = 32'h0000_2083;
        dut.EXMEMPC = 32'h1234_0000;
        dut.EXMEMALUOut = 32'h0000_0040;
        dut.EXMEMValid = 1'b1;
        force dut.dcache_pipeline_stall = 1'b1;
        force dut.ex_hold = 1'b1;
        @(posedge clock);
        #1;
        if (dut.EXMEMValid !== 1'b1 ||
            dut.EXMEMIR !== 32'h0000_2083 ||
            dut.EXMEMPC !== 32'h1234_0000 ||
            dut.EXMEMALUOut !== 32'h0000_0040) begin
            $display("FAIL: D-cache stall did not hold valid EX/MEM transaction");
            $fatal;
        end
        release dut.dcache_pipeline_stall;
        release dut.ex_hold;

        $display("PASS: invalid stale EX/MEM payload/metadata remained side-effect isolated and bubbles were valid-authoritative");
        $display("PASS: tb_assert_exmem_invalid_side_effect_isolation passed");
        $finish;
    end
endmodule
