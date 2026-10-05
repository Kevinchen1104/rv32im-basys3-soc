`timescale 1ns / 1ps

// Purpose: Checks that ID/EX validity, not stale payload contents, authorizes execute-stage work.
// Checks: Nonzero invalid ALU, memory, control, CSR/trap, RV32M, and MMIO-like payload cannot
//   raise an exception/redirect, update predictor/RAS/CSR state, start RV32M, create a load-use
//   interlock, enter EX/MEM as valid, retire, trace, write a register, or commit memory/MMIO.
//   Directed bubbles clear only validity, real D-cache/RV32M holds preserve the transaction,
//   MEM/WB repair remains active during hold, reset clears ID/EX state, and a valid instruction retires.
// Pass condition: Every invalid-payload, bubble, hold, reset, and valid-control check passes.

module tb_assert_idex_invalid_side_effect_isolation;
    localparam NOP = 32'h0000_0013;
    localparam IFID_PAYLOAD = 32'h0062_83b3; // add x7, x5, x6

    reg clock = 1'b0;
    reg reset = 1'b0;
    wire [31:0] dmem_addr;
    wire dmem_read;
    wire dmem_write;
    wire trace_valid;
    wire trace_reg_write;
    wire [31:0] gpio_outputs;
    wire [7:0] uart_tx_data;
    wire uart_tx_valid;
    wire [31:0] perf_retired_count;
    wire [31:0] perf_branch_miss_count;

    RISCVCPU #(
        .ENABLE_ICACHE(0),
        .ENABLE_DCACHE(0)
    ) dut (
        .clock(clock),
        .reset(reset),
        .imem_addr(),
        .imem_read(),
        .imem_rdata(128'h0),
        .imem_ready(1'b0),
        .dmem_addr(dmem_addr),
        .dmem_read(dmem_read),
        .dmem_write(dmem_write),
        .dmem_wdata(),
        .dmem_byte_enable(),
        .dmem_rdata(128'h0),
        .dmem_ready(1'b0),
        .debug_status(),
        .debug_pc(),
        .trace_valid(trace_valid),
        .trace_pc(),
        .trace_instruction(),
        .trace_rd(),
        .trace_reg_write(trace_reg_write),
        .trace_writeback_value(),
        .perf_cycle_count(),
        .perf_retired_count(perf_retired_count),
        .perf_branch_miss_count(perf_branch_miss_count),
        .perf_icache_miss_count(),
        .perf_dcache_miss_count(),
        .perf_stall_cycle_count(),
        .perf_matvec_start_count(),
        .perf_matvec_done_count(),
        .perf_matvec_busy_cycle_count(),
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
        input [31:0] operand_a;
        input [31:0] operand_b;
        reg [31:0] dmem_before;
        reg [31:0] debug_before;
        reg [31:0] gpio_before;
        reg [7:0] uart_before;
        reg [31:0] reg_before;
        reg [31:0] mstatus_before;
        reg [31:0] mie_before;
        reg [31:0] mepc_before;
        reg [31:0] mcause_before;
        reg [31:0] mtval_before;
        reg [3:0] ras_before;
        reg [31:0] matvec_config_before;
        reg [31:0] dma_vec_before;
        reg [31:0] retired_before;
        reg [31:0] branch_miss_before;
        begin
            reset_core();
            dut.DMemory[0] = 32'h1122_3344;
            dmem_before = dut.DMemory[0];
            debug_before = dut.DebugStatus;
            gpio_before = dut.GPIOOutput;
            uart_before = dut.UARTTxData;
            reg_before = dut.Regs[5];
            mstatus_before = dut.CSRmstatus;
            mie_before = dut.CSRmie;
            mepc_before = dut.CSRmepc;
            mcause_before = dut.CSRmcause;
            mtval_before = dut.CSRmtval;
            ras_before = dut.RASCount;
            matvec_config_before = dut.matvec_config_read_data;
            dma_vec_before = dut.matvec_dma_vec_addr_read_data;
            retired_before = perf_retired_count;
            branch_miss_before = perf_branch_miss_count;

            force dut.IFIDValid = 1'b1;
            force dut.IFIDIR = 32'h0002_83b3; // add x7, x5, x0: dependent on stale rd=x5
            force dut.IFIDPC = 32'h1234_0100;
            force dut.IDEXValid = 1'b0;
            force dut.IDEXIR = instruction;
            force dut.IDEXPC = 32'hdead_1000;
            force dut.IDEXA = operand_a;
            force dut.IDEXB = operand_b;
            force dut.IDEXPredTaken = 1'b1;
            force dut.IDEXPredPC = 32'hdead_2000;

            #1;
            if (dut.IDEXValid !== 1'b0 ||
                dut.immediate_exception_taken !== 1'b0 ||
                dut.instruction_misaligned_detect !== 1'b0 ||
                dut.exception_taken !== 1'b0 ||
                dut.mret_taken !== 1'b0 ||
                dut.csr_write_enable !== 1'b0 ||
                dut.control_resolution_accept !== 1'b0 ||
                dut.ras_update_accept !== 1'b0 ||
                dut.rv32m_start !== 1'b0 ||
                dut.rv32m_execute_stall !== 1'b0 ||
                dut.load_use_hazard !== 1'b0) begin
                $display("FAIL: %0s invalid ID/EX payload authorized execute work", label);
                $fatal;
            end

            @(posedge clock);
            #1;
            if (dut.EXMEMValid !== 1'b0 ||
                dut.EXMEMForwardRegWrite !== 1'b0 ||
                dut.EXMEMWritebackRegWrite !== 1'b0 ||
                dut.trap_taken !== 1'b0 ||
                dut.control_mispredict_accept !== 1'b0 ||
                dmem_read !== 1'b0 || dmem_write !== 1'b0) begin
                $display("FAIL: %0s invalid ID/EX payload reached an accepted downstream event", label);
                $fatal;
            end

            @(posedge clock);
            #1;
            if (dut.DMemory[0] !== dmem_before ||
                dut.DebugStatus !== debug_before ||
                dut.GPIOOutput !== gpio_before ||
                dut.UARTTxData !== uart_before ||
                dut.UARTTxValid !== 1'b0 ||
                dut.Regs[5] !== reg_before ||
                dut.CSRmstatus !== mstatus_before ||
                dut.CSRmie !== mie_before ||
                dut.CSRmepc !== mepc_before ||
                dut.CSRmcause !== mcause_before ||
                dut.CSRmtval !== mtval_before ||
                dut.RASCount !== ras_before ||
                dut.matvec_config_read_data !== matvec_config_before ||
                dut.matvec_dma_vec_addr_read_data !== dma_vec_before ||
                perf_retired_count !== retired_before ||
                perf_branch_miss_count !== branch_miss_before) begin
                $display("FAIL: %0s invalid ID/EX payload changed architectural state", label);
                $fatal;
            end
            if (dut.MEMWBValid !== 1'b0 ||
                dut.MEMWBRegWrite !== 1'b0 ||
                dut.TraceValid !== 1'b0 ||
                trace_valid !== 1'b0 || trace_reg_write !== 1'b0) begin
                $display("FAIL: %0s invalid ID/EX payload retired, traced, or wrote back", label);
                $fatal;
            end

            release dut.IFIDValid;
            release dut.IFIDIR;
            release dut.IFIDPC;
            release dut.IDEXValid;
            release dut.IDEXIR;
            release dut.IDEXPC;
            release dut.IDEXA;
            release dut.IDEXB;
            release dut.IDEXPredTaken;
            release dut.IDEXPredPC;
            @(negedge clock);
        end
    endtask

    task prepare_bubble_payload;
        begin
            dut.IFIDIR = IFID_PAYLOAD;
            dut.IFIDPC = 32'h1234_5000;
            dut.IFIDValid = 1'b1;
            dut.IFIDPredTaken = 1'b1;
            dut.IFIDPredPC = 32'h1234_6000;
            dut.IDEXIR = 32'h0020_82b3;
            dut.IDEXPC = 32'hcafe_1000;
            dut.IDEXA = 32'hcafe_2000;
            dut.IDEXB = 32'hcafe_3000;
            dut.IDEXPredTaken = 1'b0;
            dut.IDEXPredPC = 32'hcafe_4000;
            dut.IDEXValid = 1'b1;
        end
    endtask

    task check_captured_bubble_payload;
        input [255:0] label;
        begin
            if (dut.IDEXValid !== 1'b0 ||
                dut.IDEXIR !== IFID_PAYLOAD ||
                dut.IDEXPC !== 32'h1234_5000 ||
                dut.IDEXA !== 32'd5 ||
                dut.IDEXB !== 32'd6 ||
                dut.IDEXPredTaken !== 1'b1 ||
                dut.IDEXPredPC !== 32'h1234_6000) begin
                $display("FAIL: %0s did not clear only ID/EX validity while capturing nonzero payload", label);
                $fatal;
            end
        end
    endtask

    task exercise_redirect_bubble;
        input [255:0] label;
        input [1:0] kind;
        begin
            reset_core();
            prepare_bubble_payload();
            case (kind)
                2'd0: begin
                    force dut.exception_pending = 1'b1;
                    force dut.exception_taken = 1'b1;
                end
                2'd1: begin
                    force dut.interrupt_eligible = 1'b1;
                    force dut.interrupt_taken = 1'b1;
                    force dut.redirect_taken = 1'b1;
                end
                2'd2: force dut.mret_taken = 1'b1;
                default: force dut.ControlRedirectPending = 1'b1;
            endcase
            #1;
            if (dut.redirect_taken !== 1'b1 || dut.id_bubble !== 1'b1 || dut.id_hold !== 1'b0) begin
                $display("FAIL: %0s did not request the expected ID/EX bubble", label);
                $fatal;
            end
            @(posedge clock);
            #1;
            check_captured_bubble_payload(label);
            case (kind)
                2'd0: begin
                    release dut.exception_pending;
                    release dut.exception_taken;
                end
                2'd1: begin
                    release dut.interrupt_eligible;
                    release dut.interrupt_taken;
                    release dut.redirect_taken;
                end
                2'd2: release dut.mret_taken;
                default: release dut.ControlRedirectPending;
            endcase
            @(negedge clock);
        end
    endtask

    task exercise_icache_bubble;
        begin
            reset_core();
            prepare_bubble_payload();
            force dut.icache_pipeline_stall = 1'b1;
            #1;
            if (dut.id_bubble !== 1'b1 || dut.id_hold !== 1'b0) begin
                $display("FAIL: I-cache stall did not bubble ID/EX");
                $fatal;
            end
            @(posedge clock);
            #1;
            check_captured_bubble_payload("I-cache stall bubble");
            release dut.icache_pipeline_stall;
            @(negedge clock);
        end
    endtask

    task exercise_load_use_bubble;
        begin
            reset_core();
            prepare_bubble_payload();
            dut.IDEXIR = 32'h0000_2283; // lw x5, 0(x0)
            dut.IDEXValid = 1'b1;
            #1;
            if (dut.load_use_hazard !== 1'b1 || dut.id_bubble !== 1'b1) begin
                $display("FAIL: valid load-use dependency did not request a bubble");
                $fatal;
            end
            @(posedge clock);
            #1;
            check_captured_bubble_payload("load-use bubble");
            if (dut.load_use_hazard !== 1'b0) begin
                $display("FAIL: invalid captured payload repeated a load-use bubble");
                $fatal;
            end
            @(negedge clock);
        end
    endtask

    task exercise_dcache_hold;
        begin
            reset_core();
            prepare_bubble_payload();
            force dut.dcache_pipeline_stall = 1'b1;
            #1;
            if (dut.id_hold !== 1'b1 || dut.id_payload_hold !== 1'b1) begin
                $display("FAIL: D-cache stall did not request a full ID/EX hold");
                $fatal;
            end
            @(posedge clock);
            #1;
            if (dut.IDEXValid !== 1'b1 ||
                dut.IDEXIR !== 32'h0020_82b3 ||
                dut.IDEXPC !== 32'hcafe_1000 ||
                dut.IDEXA !== 32'hcafe_2000 ||
                dut.IDEXB !== 32'hcafe_3000 ||
                dut.IDEXPredTaken !== 1'b0 ||
                dut.IDEXPredPC !== 32'hcafe_4000) begin
                $display("FAIL: D-cache stall did not preserve the valid ID/EX transaction");
                $fatal;
            end
            release dut.dcache_pipeline_stall;
            @(negedge clock);
        end
    endtask

    task exercise_rv32m_hold_and_repair;
        begin
            reset_core();
            prepare_bubble_payload();
            dut.IDEXIR = 32'h0220_82b3; // mul x5, x1, x2
            dut.IDEXA = 32'h1111_1111;
            dut.IDEXB = 32'h2222_2222;
            force dut.rv32m_execute_stall = 1'b1;
            force dut.MEMWBValid = 1'b1;
            force dut.MEMWBForwardRegWrite = 1'b1;
            force dut.MEMWBForwardRd = 5'd1;
            force dut.MEMWBValue = 32'ha5a5_5a5a;
            #1;
            if (dut.id_hold !== 1'b1 || dut.id_payload_hold !== 1'b1) begin
                $display("FAIL: RV32M wait did not hold ID/EX");
                $fatal;
            end
            @(posedge clock);
            #1;
            if (dut.IDEXValid !== 1'b1 ||
                dut.IDEXIR !== 32'h0220_82b3 ||
                dut.IDEXPC !== 32'hcafe_1000 ||
                dut.IDEXA !== 32'ha5a5_5a5a ||
                dut.IDEXB !== 32'h2222_2222 ||
                dut.EXMEMValid !== 1'b0) begin
                $display("FAIL: RV32M hold lost payload/validity or MEM/WB repair behavior");
                $fatal;
            end
            release dut.rv32m_execute_stall;
            release dut.MEMWBValid;
            release dut.MEMWBForwardRegWrite;
            release dut.MEMWBForwardRd;
            release dut.MEMWBValue;
            @(negedge clock);
        end
    endtask

    task exercise_valid_instruction;
        begin
            reset_core();
            dut.IFIDValid = 1'b0;
            dut.IDEXIR = 32'h0070_0293; // addi x5, x0, 7
            dut.IDEXPC = 32'h0000_0100;
            dut.IDEXA = 32'h0;
            dut.IDEXB = 32'h0;
            dut.IDEXValid = 1'b1;
            @(posedge clock);
            #1;
            if (dut.EXMEMValid !== 1'b1 ||
                dut.EXMEMALUOut !== 32'd7 ||
                dut.EXMEMWritebackRegWrite !== 1'b1 ||
                dut.EXMEMForwardRd !== 5'd5) begin
                $display("FAIL: a real valid ID/EX instruction did not execute");
                $fatal;
            end
            repeat (2) @(posedge clock);
            #1;
            if (dut.Regs[5] !== 32'd7) begin
                $display("FAIL: a real valid ID/EX instruction did not retire/write back");
                $fatal;
            end
        end
    endtask

    initial begin
        $dumpfile("results/waveforms/tb_assert_idex_invalid_side_effect_isolation.vcd");
        $dumpvars(0, tb_assert_idex_invalid_side_effect_isolation);

        reset_core();
        if (dut.IDEXValid !== 1'b0 ||
            dut.IDEXIR !== NOP ||
            dut.IDEXPC !== 32'h0 ||
            dut.IDEXA !== 32'h0 ||
            dut.IDEXB !== 32'h0 ||
            dut.IDEXPredTaken !== 1'b0 ||
            dut.IDEXPredPC !== 32'h0) begin
            $display("FAIL: reset did not initialize ID/EX valid and payload state");
            $fatal;
        end

        exercise_invalid_payload("ALU writeback", 32'h0020_82b3, 32'h1111_0001, 32'h2222_0001);
        exercise_invalid_payload("normal load", 32'h0000_2283, 32'h0000_0000, 32'h2222_0002);
        exercise_invalid_payload("normal store", 32'h0020_2023, 32'h0000_0000, 32'ha5a5_0003);
        exercise_invalid_payload("misaligned store", 32'h0020_2023, 32'h0000_0001, 32'ha5a5_0004);
        exercise_invalid_payload("branch", 32'h0010_8463, 32'h3333_0001, 32'h3333_0001);
        exercise_invalid_payload("JAL", 32'h0080_02ef, 32'h4444_0001, 32'h4444_0002);
        exercise_invalid_payload("JALR", 32'h0000_82e7, 32'h5555_0001, 32'h5555_0002);
        exercise_invalid_payload("CSR", 32'h3000_92f3, 32'h6666_0001, 32'h6666_0002);
        exercise_invalid_payload("ecall", 32'h0000_0073, 32'h7777_0001, 32'h7777_0002);
        exercise_invalid_payload("ebreak", 32'h0010_0073, 32'h8888_0001, 32'h8888_0002);
        exercise_invalid_payload("mret", 32'h3020_0073, 32'h9999_0001, 32'h9999_0002);
        exercise_invalid_payload("RV32M", 32'h0220_82b3, 32'haaaa_0001, 32'haaaa_0002);
        exercise_invalid_payload("accelerator/MMIO-like store", 32'h0020_2023, 32'h0000_0900, 32'hbbbb_0001);

        exercise_redirect_bubble("trap bubble", 2'd0);
        exercise_redirect_bubble("interrupt bubble", 2'd1);
        exercise_redirect_bubble("mret bubble", 2'd2);
        exercise_redirect_bubble("registered-control bubble", 2'd3);
        exercise_icache_bubble();
        exercise_load_use_bubble();
        exercise_dcache_hold();
        exercise_rv32m_hold_and_repair();
        exercise_valid_instruction();

        $display("PASS: invalid stale ID/EX payload remained side-effect isolated and bubbles were valid-authoritative");
        $display("PASS: tb_assert_idex_invalid_side_effect_isolation passed");
        $finish;
    end
endmodule
