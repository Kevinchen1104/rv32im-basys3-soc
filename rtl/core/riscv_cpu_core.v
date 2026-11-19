`timescale 1ns / 1ps

// Five-stage RV32IM-style CPU with optional caches, machine-mode traps, and MMIO.
// Pipeline payload and validity are stored separately. Control recovery uses
// registered metadata; memory backpressure holds the live transaction.

module RISCVCPU #(
    parameter MEMORY_WORD_COUNT = 1024,
    parameter INIT_PROGRAM_HEX = "",
    parameter INIT_PROGRAM_WORD_COUNT = MEMORY_WORD_COUNT,
    parameter USE_EXTERNAL_IMEM = 0,
    parameter USE_EXTERNAL_DMEM = 0,
    parameter ENABLE_RV32M = 1,
    parameter FAST_MULTIPLY = 0,
    parameter ENABLE_ACCELERATORS = 1,
    parameter ENABLE_MATVEC_SCRATCHPAD = 1,
    parameter ENABLE_MATVEC_DMA = 1,
    parameter ENABLE_MACHINE_TIMER = 1,
    parameter ENABLE_ICACHE = 1,
    parameter ICACHE_BYTES = 64,
    parameter ICACHE_PARALLEL_LOOKUP = 1,
    parameter ENABLE_DCACHE = 1,
    parameter DCACHE_BYTES = 64,
    parameter DCACHE_VICTIM_LINES = 0,
    parameter ENABLE_BRANCH_PREDICTOR = 1,
    parameter ENABLE_PERF_COUNTERS = 1,
    parameter ENABLE_CONTROL_REDIRECTS = 1,
    parameter ENABLE_CSR_TRAPS = 1
) (
    input clock,
    input reset,
    output [31:0] imem_addr,
    output imem_read,
    input [127:0] imem_rdata,
    input imem_ready,
    output [31:0] dmem_addr,
    output dmem_read,
    output dmem_write,
    output [127:0] dmem_wdata,
    output [15:0] dmem_byte_enable,
    input [127:0] dmem_rdata,
    input dmem_ready,
    output config_error,
    output [31:0] debug_status,
    output [31:0] debug_pc,
    output trace_valid,
    output [31:0] trace_pc,
    output [31:0] trace_instruction,
    output [4:0] trace_rd,
    output trace_reg_write,
    output [31:0] trace_writeback_value,
    output [31:0] perf_cycle_count,
    output [31:0] perf_retired_count,
    output [31:0] perf_branch_miss_count,
    output [31:0] perf_icache_miss_count,
    output [31:0] perf_dcache_miss_count,
    output [31:0] perf_stall_cycle_count,
    output [31:0] perf_matvec_start_count,
    output [31:0] perf_matvec_done_count,
    output [31:0] perf_matvec_busy_cycle_count,
    input [31:0] gpio_inputs,
    output [31:0] gpio_outputs,
    output [7:0] uart_tx_data,
    output uart_tx_valid,
    input uart_tx_ready,
    input [7:0] uart_rx_data,
    input uart_rx_valid,
    input uart_rx_overrun,
    output uart_rx_ready
);
    localparam MEMORY_CONFIG_VALID = (MEMORY_WORD_COUNT >= 1);
    localparam INIT_PROGRAM_CONFIG_VALID =
        (INIT_PROGRAM_HEX == "") ||
        ((INIT_PROGRAM_WORD_COUNT >= 0) &&
         (INIT_PROGRAM_WORD_COUNT <= MEMORY_WORD_COUNT));
    localparam EXTERNAL_MEMORY_CONFIG_VALID =
        (!USE_EXTERNAL_IMEM || ENABLE_ICACHE) &&
        (!USE_EXTERNAL_DMEM || ENABLE_DCACHE) &&
        (!USE_EXTERNAL_DMEM ||
         ((MEMORY_WORD_COUNT >= 4) && ((MEMORY_WORD_COUNT % 4) == 0)));
    localparam CORE_CONFIG_VALID =
        MEMORY_CONFIG_VALID &&
        INIT_PROGRAM_CONFIG_VALID &&
        EXTERNAL_MEMORY_CONFIG_VALID &&
        (DCACHE_BYTES == 64 || DCACHE_BYTES == 128) &&
        (DCACHE_VICTIM_LINES == 0 || DCACHE_VICTIM_LINES == 1 || DCACHE_VICTIM_LINES == 2 ||
         DCACHE_VICTIM_LINES == 4 || DCACHE_VICTIM_LINES == 8) &&
        (!ENABLE_ICACHE || ((ICACHE_BYTES >= 64) && (ICACHE_BYTES <= 4096) &&
         ((ICACHE_BYTES & (ICACHE_BYTES - 1)) == 0) &&
         ((ICACHE_PARALLEL_LOOKUP == 0) ||
          ((ICACHE_PARALLEL_LOOKUP == 1) && (ICACHE_BYTES == 64)))));

    // Invalid memory depth, initialization range, or external cache-line
    // integration asserts config_error. Integrators must hold or reject such
    // profiles rather than treating them as runnable configurations.
    assign config_error = !CORE_CONFIG_VALID;

    // ================================
    // Instruction classes and local decode constants
    // ================================
    // funct3/funct7 select the operation within each opcode class.
    localparam [6:0] OP_REG    = 7'b0110011;
    localparam [6:0] OP_IMM    = 7'b0010011;
    localparam [6:0] OP_LOAD   = 7'b0000011;
    localparam [6:0] OP_STORE  = 7'b0100011;
    localparam [6:0] OP_BRANCH = 7'b1100011;
    localparam [6:0] OP_JAL    = 7'b1101111;
    localparam [6:0] OP_JALR   = 7'b1100111;
    localparam [6:0] OP_LUI    = 7'b0110111;
    localparam [6:0] OP_AUIPC  = 7'b0010111;
    localparam [6:0] OP_SYSTEM = 7'b1110011;
    localparam [31:0] NOP = 32'h00000013;  // addi x0, x0, 0

    // Cache states used here or observed by the reset test.
    localparam CACHE_IDLE = 2'b00;
    localparam CACHE_REFILL = 2'b11;
    localparam IC_IDLE = 1'b0;

    // Debug status mirrors a normal-memory store. Peripheral address decoding
    // is owned by mmio_decode.
    localparam [31:0] DEBUG_STATUS_ADDR = 32'h0000_0100;

    // ================================
    // Architectural state and memories
    // ================================
    localparam SAFE_MEMORY_WORD_COUNT =
        (MEMORY_WORD_COUNT < 1) ? 1 : MEMORY_WORD_COUNT;
    localparam INTERNAL_IMEM_WORD_COUNT =
        USE_EXTERNAL_IMEM ? 1 : SAFE_MEMORY_WORD_COUNT;
    localparam EXTERNAL_DMEM_OBSERVATION_WORD_COUNT =
        (SAFE_MEMORY_WORD_COUNT < 128) ? SAFE_MEMORY_WORD_COUNT : 128;
    localparam INTERNAL_DMEM_WORD_COUNT =
        USE_EXTERNAL_DMEM ?
        EXTERNAL_DMEM_OBSERVATION_WORD_COUNT :
        SAFE_MEMORY_WORD_COUNT;
    localparam EFFECTIVE_INIT_PROGRAM_WORD_COUNT =
        (INIT_PROGRAM_WORD_COUNT < MEMORY_WORD_COUNT) ?
        INIT_PROGRAM_WORD_COUNT :
        MEMORY_WORD_COUNT;

    // Keep the architectural hold as an explicit data mux. 7-series CE setup
    // is tighter than D setup, and the late D-cache miss signal is a necessary
    // PC hold input rather than a reason to create a wide clock-enable cone.
    (* EXTRACT_ENABLE = "NO" *) reg [31:0] PC;
    reg [31:0] Regs   [  0:31];

    reg [31:0] IMemory[0:INTERNAL_IMEM_WORD_COUNT-1];
    reg [31:0] DMemory[0:INTERNAL_DMEM_WORD_COUNT-1];

    reg [31:0] DebugStatus;

    assign debug_status = DebugStatus;
    assign debug_pc = PC;
    assign trace_valid = TraceValid;
    assign trace_pc = MEMWBPC;
    assign trace_instruction = MEMWBIR;
    assign trace_rd = MEMWBForwardRd;
    assign trace_reg_write = MEMWBRegWrite;
    assign trace_writeback_value = MEMWBValue;
    assign perf_cycle_count = CycleCount;
    assign perf_retired_count = RetiredCount;
    assign perf_branch_miss_count = BranchMissCount;
    assign perf_icache_miss_count = ICacheMissCount;
    assign perf_dcache_miss_count = DCacheMissCount;
    assign perf_stall_cycle_count = StallCycleCount;
    assign perf_matvec_start_count = MatvecStartCount;
    assign perf_matvec_done_count = MatvecDoneCount;
    assign perf_matvec_busy_cycle_count = MatvecBusyCycleCount;
    assign gpio_outputs = GPIOOutput;
    assign uart_tx_data = UARTTxData;
    assign uart_tx_valid = UARTTxValid;
    assign uart_rx_ready = UARTRxReady;
    assign imem_addr = icache_refill_addr;
    assign imem_read = icache_external_read;

    // MATVEC DMA-lite temporarily owns the external data-memory port while
    // its job FSM is active; the CPU-side D-cache path is stalled upstream.
    assign dmem_addr = matvec_dma_dmem_request ? matvec_dma_dmem_addr : dcache_external_addr;
    assign dmem_read = matvec_dma_dmem_request ? matvec_dma_dmem_read : dcache_external_read;
    assign dmem_write = matvec_dma_dmem_request ? matvec_dma_dmem_write : dcache_external_write;
    assign dmem_wdata = matvec_dma_dmem_request ? matvec_dma_dmem_wdata : dcache_external_wdata;
    assign dmem_byte_enable = matvec_dma_dmem_request ? matvec_dma_dmem_byte_enable : dcache_external_byte_enable;

    // ================================
    // Pipeline registers
    // ================================
    // IF/ID: fetched instruction and prediction.
    reg [31:0] IFIDIR;
    reg [31:0] IFIDPC;
    reg IFIDValid;
    reg IFIDPredTaken;
    reg [31:0] IFIDPredPC;

    // ID/EX: decoded operands and prediction to resolve in execute.
    reg [31:0] IDEXIR;
    reg [31:0] IDEXPC;
    reg [31:0] IDEXA, IDEXB;
    reg IDEXValid;
    reg IDEXPredTaken;
    reg [31:0] IDEXPredPC;

    // EX/MEM: result, store operand, and destination/writeback metadata.
    reg [31:0] EXMEMIR;
    reg [31:0] EXMEMPC;
    reg [31:0] EXMEMB, EXMEMALUOut;
    reg [31:0] EXMEMPCPlus4;
    reg EXMEMValid;
    reg EXMEMForwardRegWrite;
    reg EXMEMWritebackRegWrite;
    reg [4:0] EXMEMForwardRd;
    reg EXMEMForwardUsePCPlus4;

    // MEM/WB: completed result and public retirement trace.
    reg [31:0] MEMWBIR;
    reg [31:0] MEMWBPC;
    reg [31:0] MEMWBValue;
    reg MEMWBValid;
    reg MEMWBForwardRegWrite;
    reg [4:0] MEMWBForwardRd;
    reg TraceValid;

    // Registered control recovery and delayed instruction-alignment checks.
    reg ControlRedirectPending;
    reg ControlRedirectPendingPrev;
    reg ControlResolutionWasBranch;
    reg [31:0] ControlRedirectTargetPC;
    reg [31:0] ControlRedirectFallthroughPC;
    reg ControlRedirectUseFallthrough;
    wire [31:0] ControlRedirectPC;
    reg ControlInterruptDeferred;
    reg ControlAlignmentCheckPending;
    wire InstructionMisalignPending;
    reg InstructionMisalignCancel;
    reg InstructionMisalignUseFallthrough;
    reg [31:0] InstructionMisalignPC;
    reg [31:0] InstructionMisalignTarget;

    // Ownership of the iterative multiply/divide unit.
    reg RV32MInFlight;
    reg RV32MResultReady;

    // Performance counters, CSR state, and peripheral readback.
    wire [31:0] CycleCount;
    wire [31:0] RetiredCount;
    wire [31:0] BranchMissCount;
    wire [31:0] ICacheMissCount;
    wire [31:0] DCacheMissCount;
    wire [31:0] StallCycleCount;
    wire [31:0] MatvecStartCount;
    wire [31:0] MatvecDoneCount;
    wire [31:0] MatvecBusyCycleCount;
    reg MatvecDonePrev;
    reg MachineExternalInterruptActive;
    reg MachineTimerInterruptActive;
    wire [31:0] CSRmstatus;
    wire [31:0] CSRmie;
    wire [31:0] CSRmtvec;
    wire [31:0] CSRmepc;
    wire [31:0] CSRmcause;
    wire [31:0] CSRmtval;
    wire [31:0] CSRmip;
    wire CSRTrapMetadataPending;
    wire [31:0] csr_read_data;
    reg [31:0] GPIOOutput;
    reg [7:0] UARTTxData;
    reg UARTTxValid;
    wire UARTRxReady;

    wire [31:0] matvec_status_read_data;
    wire [31:0] matvec_config_read_data;
    wire [31:0] matvec_vector_read_data;
    wire [31:0] matvec_row_index_read_data;
    wire [31:0] matvec_row_data_read_data;
    wire [31:0] matvec_result_index_read_data;
    wire [31:0] matvec_result_data_read_data;
    wire [31:0] matvec_perf_read_data;
    wire matvec_irq_pending;
    wire [31:0] matvec_dma_vec_addr_read_data;
    wire [31:0] matvec_dma_matrix_addr_read_data;
    wire [31:0] matvec_dma_out_addr_read_data;
    wire [31:0] matvec_dma_rows_read_data;
    wire [31:0] matvec_dma_ctrl_read_data;
    wire [31:0] matvec_dma_status_read_data;
    wire [31:0] matvec_dma_error_read_data;
    wire [31:0] matvec_dma_perf_read_data;
    wire matvec_dma_busy;
    wire matvec_dma_done;
    wire matvec_dma_error;
    wire matvec_dma_irq_pending;
    wire [31:0] timer_mtime_low_read_data;
    wire [31:0] timer_mtime_high_read_data;
    wire [31:0] timer_mtimecmp_low_read_data;
    wire [31:0] timer_mtimecmp_high_read_data;
    wire timer_irq_pending;
    wire matvec_start_accepted;
    wire matvec_busy;
    wire matvec_done;
    wire dcache_pipeline_stall;
    wire icache_pipeline_stall;

    // ================================
    // Cache debug visibility
    // ================================
    wire [1:0] cache_stall;
    wire [1:0] cache_state;
    wire [(DCACHE_BYTES == 128 ? 8 : 4)-1:0] DCacheDirty;

    // Current fetch output from the instruction cache, or NOP on a miss.
    wire [31:0] IFInstruction;
    wire [1:0] icache_state;
    wire [1:0] icache_stall;
    wire icache_external_read;
    wire lru_set0;
    wire lru_set1;

    wire [2:0] RASTop;
    wire [3:0] RASCount;

    // ================================
    // Instruction field aliases
    // ================================
    wire [6:0] IFIDop = IFIDIR[6:0];
    wire [2:0] IFIDfunct3 = IFIDIR[14:12];
    wire [4:0] IFIDrs1 = IFIDIR[19:15];
    wire [4:0] IFIDrs2 = IFIDIR[24:20];

    wire [6:0] IDEXop = IDEXIR[6:0];
    wire [4:0] IDEXrd = IDEXIR[11:7];
    wire [2:0] IDEXfunct3 = IDEXIR[14:12];
    wire [4:0] IDEXrs1 = IDEXIR[19:15];
    wire [4:0] IDEXrs2 = IDEXIR[24:20];
    wire [6:0] IDEXfunct7 = IDEXIR[31:25];
    wire [11:0] IDEXcsr = IDEXIR[31:20];

    wire [6:0] EXMEMop = EXMEMIR[6:0];
    wire [2:0] EXMEMfunct3 = EXMEMIR[14:12];
    wire [4:0] EXMEMrs2 = EXMEMIR[24:20];
    // Preserve the existing debug/testbench alias without decoding MEMWBIR
    // back into the execute forwarding path.
    wire [4:0] MEMWBrd = MEMWBForwardRd;

    wire [31:0] imm_i;
    wire [31:0] imm_s;
    wire [31:0] imm_b;
    wire [31:0] imm_u;
    wire [31:0] imm_j;

    assign imm_i = {{20{IDEXIR[31]}}, IDEXIR[31:20]};
    assign imm_s = {{20{IDEXIR[31]}}, IDEXIR[31:25], IDEXIR[11:7]};
    assign imm_b = {
        {19{IDEXIR[31]}}, IDEXIR[31], IDEXIR[7], IDEXIR[30:25], IDEXIR[11:8], 1'b0
    };
    assign imm_u = {IDEXIR[31:12], 12'b0};
    assign imm_j = {
        {11{IDEXIR[31]}}, IDEXIR[31], IDEXIR[19:12], IDEXIR[20], IDEXIR[30:21], 1'b0
    };

    // ================================
    // Pipeline control decode
    // ================================
    wire IDEXMemRead   = (IDEXop == OP_LOAD);
    wire IDEXMemWrite  = (IDEXop == OP_STORE);
    wire IDEXBranch    = (IDEXop == OP_BRANCH);
    wire IDEXJump      = (IDEXop == OP_JAL) || (IDEXop == OP_JALR);
    wire IDEXSystem    = (IDEXop == OP_SYSTEM);
    wire IDEXALUResult =
        (IDEXop == OP_REG) ||
        (IDEXop == OP_IMM) ||
        (IDEXop == OP_LUI) ||
        (IDEXop == OP_AUIPC) ||
        IDEXSystem;
    wire IDEXWritesRegister =
        IDEXValid &&
        (IDEXrd != 0) &&
        (IDEXALUResult || IDEXMemRead || IDEXJump);

    wire EXMEMMemRead   = (EXMEMop == OP_LOAD);
    wire EXMEMMemWrite  = (EXMEMop == OP_STORE);
    wire EXMEMMemAccess = EXMEMMemRead || EXMEMMemWrite;
    wire EXMEMJump      = (EXMEMop == OP_JAL) || (EXMEMop == OP_JALR);
    wire EXMEMALUResult =
        (EXMEMop == OP_REG) ||
        (EXMEMop == OP_IMM) ||
        (EXMEMop == OP_LUI) ||
        (EXMEMop == OP_AUIPC) ||
        (EXMEMop == OP_SYSTEM);
    // Opcode decode alone can remain asserted in a bubble. Qualify memory
    // operations with stage validity before selecting side effects.
    wire EXMEMLoadValid = EXMEMValid && EXMEMMemRead;
    wire EXMEMStoreValid = EXMEMValid && EXMEMMemWrite;

    // IDEXWritesRegister excludes x0 before rd/write intent enter EX/MEM.
    // EX/MEM bubbles retain stale write metadata, so they still need Valid.
    // MEM/WB captures write intent already qualified by memwb_input_valid;
    // rechecking Valid or rd here would lengthen every WB forwarding path.
    wire EXMEMForwardProducerValid =
        EXMEMValid && EXMEMForwardRegWrite;
    wire MEMWBForwardProducerValid = MEMWBForwardRegWrite;
    wire EXMEMRegWrite = EXMEMForwardProducerValid;
    wire MEMWBRegWrite = MEMWBForwardProducerValid;

    // ================================
    // Forwarding paths
    // ================================
    wire [31:0] Ain;
    wire [1:0] AinAddressLow;
    wire [31:0] Bin;

    // JAL/JALR write PC+4, while ALU-like instructions write EXMEMALUOut.
    // Keeping this as one value keeps EX-stage forwarding priority compact.
    wire [31:0] EXMEMForwardValue;
    assign EXMEMForwardValue = EXMEMForwardUsePCPlus4 ? EXMEMPCPlus4 : EXMEMALUOut;

    // Store data reaches MEM one stage later than ALU operands, so it needs a
    // dedicated MEM/WB bypass instead of sharing the EX operand mux directly.
    wire [31:0] StoreData;

    forwarding_unit execute_forwarding (
        .idex_a(IDEXA),
        .idex_b(IDEXB),
        .idex_rs1(IDEXrs1),
        .idex_rs2(IDEXrs2),
        .exmem_producer_valid(EXMEMForwardProducerValid),
        .exmem_rd(EXMEMForwardRd),
        .exmem_forward_value(EXMEMForwardValue),
        .memwb_producer_valid(MEMWBForwardProducerValid),
        .memwb_rd(MEMWBForwardRd),
        .memwb_value(MEMWBValue),
        .exmem_b(EXMEMB),
        .exmem_rs2(EXMEMrs2),
        .forward_a(Ain),
        .forward_a_address_low(AinAddressLow),
        .forward_b(Bin),
        .store_data(StoreData)
    );

    // ================================
    // Execute datapath and iterative multiply/divide
    // ================================
    wire [31:0] execute_result;
    wire [31:0] execute_arithmetic_result;
    wire [31:0] rv32m_result;

    riscv_alu execute_alu (
        .opcode(IDEXop),
        .funct3(IDEXfunct3),
        .funct7(IDEXfunct7),
        .lhs(Ain),
        .rhs(Bin),
        .imm_i(imm_i),
        .imm_s(imm_s),
        .imm_u(imm_u),
        .pc(IDEXPC),
        .rv32m_result(rv32m_result),
        .csr_result(csr_read_data),
        .arithmetic_result(execute_arithmetic_result),
        .arithmetic_result_selected(),
        .result(execute_result)
    );

    wire IDEXMExtension =
        ENABLE_RV32M &&
        IDEXValid &&
        (IDEXop == OP_REG) &&
        (IDEXfunct7 == 7'b0000001);
    wire rv32m_squash;
    wire rv32m_start =
        IDEXMExtension &&
        !ControlRedirectPending &&
        !rv32m_squash &&
        !RV32MInFlight &&
        !RV32MResultReady &&
        !rv32m_busy;
    wire rv32m_busy;
    wire rv32m_unit_done;
    wire rv32m_execute_stall =
        IDEXMExtension &&
        !ControlRedirectPending &&
        !RV32MResultReady;
    wire rv32m_release =
        IDEXMExtension &&
        RV32MResultReady &&
        !ControlRedirectPending &&
        !dcache_pipeline_stall;

    generate
        if (ENABLE_RV32M) begin : gen_rv32m_multicycle
            rv32m_multicycle_unit #(.FAST_MULTIPLY(FAST_MULTIPLY)) rv32m_execute_unit (
                .clock(clock),
                .reset(reset),
                .start(rv32m_start),
                .funct3(IDEXfunct3),
                .lhs(Ain),
                .rhs(Bin),
                .busy(rv32m_busy),
                .done(rv32m_unit_done),
                .result(rv32m_result)
            );
        end else begin : gen_no_rv32m_multicycle
            assign rv32m_busy = 1'b0;
            assign rv32m_unit_done = 1'b0;
            assign rv32m_result = 32'h0;
        end
    endgenerate

    // ================================
    // Branch and jump control
    // ================================
    wire is_branch;
    wire is_jal;
    wire is_jalr;
    wire is_jump;
    wire branch_taken;
    wire branch_mispredict;
    wire jump_mispredict;
    wire branch_mispredict_raw;
    wire jump_mispredict_raw;

    wire [31:0] branch_target;
    wire        bp_predict_taken;
    wire [31:0] bp_predicted_pc;
    wire [31:0] jal_target;
    wire [31:0] jalr_target;
    wire [31:0] jump_target;
    wire [31:0] control_target_address;
    wire control_transfer_taken;
    wire exception_taken;
    wire interrupt_taken;
    wire redirect_taken;
    wire instruction_misaligned_detect;
    wire control_resolution_accept;
    wire control_resolution_blocked;
    wire control_mispredict_accept;
    wire control_redirect_apply;

    branch_jump_unit execute_branch_jump (
        .opcode(IDEXop),
        .funct3(IDEXfunct3),
        .pc(IDEXPC),
        .operand_a(Ain),
        .operand_b(Bin),
        .imm_b(imm_b),
        .imm_j(imm_j),
        .imm_i(imm_i),
        .pred_taken(IDEXPredTaken),
        .pred_pc(IDEXPredPC),
        .is_branch(is_branch),
        .is_jal(is_jal),
        .is_jalr(is_jalr),
        .is_jump(is_jump),
        .branch_taken(branch_taken),
        .branch_mispredict(branch_mispredict_raw),
        .jump_mispredict(jump_mispredict_raw),
        .branch_target(branch_target),
        .correct_branch_pc(),
        .jal_target(jal_target),
        .jalr_target(jalr_target),
        .jump_target(jump_target)
    );
    assign control_transfer_taken = (is_branch && branch_taken) || is_jump;
    assign control_target_address = is_branch ? branch_target : jump_target;

    generate
        if (ENABLE_BRANCH_PREDICTOR) begin : gen_branch_predictor
            branch_predictor branch_predictor_inst (
                .clock(clock),
                .reset(reset),
                .fetch_pc(PC),
                .fetch_instruction(IFInstruction),
                .predict_taken(bp_predict_taken),
                .predicted_pc(bp_predicted_pc),
                .update_valid(
                    control_resolution_accept &&
                    (IDEXBranch || is_jal)
                ),
                .update_suppress(InstructionMisalignPending),
                .update_is_conditional(IDEXBranch),
                .update_pc(IDEXPC),
                .update_taken(IDEXBranch ? branch_taken : 1'b1),
                .update_target(IDEXBranch ? branch_target : jal_target)
            );
        end else begin : gen_no_branch_predictor
            assign bp_predict_taken = 1'b0;
            assign bp_predicted_pc = PC + 32'd4;
        end
    endgenerate

    // ================================
    // Exception classification, trap acceptance, and CSR updates
    // ================================
    wire is_ecall;
    wire is_ebreak;
    wire is_mret;
    wire is_csr_access;
    wire is_valid_csr;
    wire is_misaligned_load;
    wire is_misaligned_store;
    wire is_misaligned_access;
    wire is_misaligned_instruction;
    wire is_legal_instruction;
    wire [31:0] exception_cause;
    wire mret_taken;
    wire machine_external_interrupt_pending;
    wire machine_timer_interrupt_pending;
    wire machine_interrupt_pending;
    wire [31:0] machine_interrupt_cause;
    wire trap_taken;
    wire [31:0] trap_cause;
    wire [31:0] exception_tval;
    wire [31:0] trap_tval;
    wire architectural_mret_taken;
    wire execute_instruction_accept;
    wire immediate_exception_pending;
    wire exception_pending;
    wire immediate_exception_taken;
    wire instruction_misaligned_taken;
    wire instruction_misaligned_capture;
    wire control_alignment_capture;
    wire instruction_access_fault;
    wire load_access_fault;
    wire store_access_fault;
    wire memory_access_fault_detect;
    wire memory_access_fault_taken;
    wire memory_access_fault_stall;
    wire instruction_address_in_range;
    wire exmem_data_address_in_range;
    wire [1:0] load_address_low;
    wire [1:0] store_address_low;
    localparam integer MEMORY_WORD_ADDR_WIDTH =
        (MEMORY_WORD_COUNT <= 1) ? 1 : $clog2(MEMORY_WORD_COUNT);

    // Keep alignment control off the full execute-result selector. The full
    // effective address still comes from the shared 32-bit execute adder.
    assign load_address_low = AinAddressLow + imm_i[1:0];
    assign store_address_low = AinAddressLow + imm_s[1:0];

    exception_decode_unit #(
        .ENABLE_RV32M(ENABLE_RV32M)
    ) exception_decode_inst (
        .valid(IDEXValid),
        .instruction(IDEXIR),
        .opcode(IDEXop),
        .funct3(IDEXfunct3),
        .funct7(IDEXfunct7),
        .csr_addr(IDEXcsr),
        .mem_read(IDEXMemRead),
        .mem_write(IDEXMemWrite),
        .load_address_low(load_address_low),
        .store_address_low(store_address_low),
        .control_transfer_taken(control_transfer_taken),
        .control_target_address_low(control_target_address[1:0]),
        .is_ecall(is_ecall),
        .is_ebreak(is_ebreak),
        .is_mret(is_mret),
        .is_csr_access(is_csr_access),
        .is_valid_csr(is_valid_csr),
        .is_misaligned_load(is_misaligned_load),
        .is_misaligned_store(is_misaligned_store),
        .is_misaligned_access(is_misaligned_access),
        .is_misaligned_instruction(is_misaligned_instruction),
        .is_legal_instruction(is_legal_instruction)
    );

    generate
        // Power-of-two memories use a reduction check rather than a wide
        // magnitude comparator on the execute/trap path.
        if ((MEMORY_WORD_COUNT > 1) &&
            ((MEMORY_WORD_COUNT & (MEMORY_WORD_COUNT - 1)) == 0)) begin : gen_power_of_two_access_bounds
            assign instruction_address_in_range =
                !(|IDEXPC[31:MEMORY_WORD_ADDR_WIDTH+2]);
            assign exmem_data_address_in_range =
                !(|EXMEMALUOut[31:MEMORY_WORD_ADDR_WIDTH+2]);
        end else begin : gen_general_access_bounds
            assign instruction_address_in_range =
                (IDEXPC[31:2] < MEMORY_WORD_COUNT);
            assign exmem_data_address_in_range =
                (EXMEMALUOut[31:2] < MEMORY_WORD_COUNT);
        end
    endgenerate

    wire csr_write_enable;
    wire interrupt_eligible;

    // Trap entry is accepted only at a stable execute-stage boundary. Explicit
    // exceptions beat interrupts; mret and branch/jump redirects are kept out
    // of the interrupt path so their architectural side effects stay precise.
    assign execute_instruction_accept =
        IDEXValid &&
        !ControlRedirectPending &&
        !dcache_pipeline_stall &&
        !rv32m_execute_stall &&
        !memory_access_fault_detect;
    assign instruction_misaligned_detect =
        ENABLE_CSR_TRAPS &&
        !ControlRedirectPending &&
        is_misaligned_instruction;
    // Register a shallow "alignment check due" event at the control-resolution
    // edge. Registered target/outcome state then determines the actual IALIGN
    // fault without placing the full branch comparator on this event's D path.
    // An older control transfer that is taking its own IALIGN trap squashes
    // this instruction, and an instruction-access fault traps it here, so
    // neither case may arm a second check.
    assign control_alignment_capture =
        ENABLE_CSR_TRAPS &&
        !ControlRedirectPending &&
        !InstructionMisalignPending &&
        !instruction_access_fault &&
        IDEXValid &&
        (IDEXBranch || IDEXJump) &&
        is_legal_instruction &&
        !rv32m_execute_stall &&
        !interrupt_taken;
    assign InstructionMisalignPending =
        ControlAlignmentCheckPending &&
        !InstructionMisalignUseFallthrough &&
        (InstructionMisalignTarget[1:0] != 2'b00);
    assign instruction_misaligned_capture =
        instruction_misaligned_detect &&
        !InstructionMisalignPending &&
        !dcache_pipeline_stall &&
        !rv32m_execute_stall &&
        !interrupt_taken;
    assign instruction_access_fault =
        IDEXValid &&
        !instruction_address_in_range;
    assign load_access_fault =
        memory_access_fault_taken &&
        EXMEMMemRead;
    assign store_access_fault =
        memory_access_fault_taken &&
        EXMEMMemWrite;
    assign memory_access_fault_detect =
        ENABLE_CSR_TRAPS &&
        EXMEMValid &&
        EXMEMMemAccess &&
        !EXMEMMmioAccess &&
        !exmem_data_address_in_range;
    assign memory_access_fault_taken =
        memory_access_fault_detect &&
        !memory_access_fault_stall;
    // Select frontend recovery before memory backpressure arrives. Acceptance
    // still gates trap/CSR side effects and the pipeline's final update edge.
    assign immediate_exception_pending =
        ENABLE_CSR_TRAPS &&
        IDEXValid &&
        !ControlRedirectPending &&
        !rv32m_execute_stall &&
        !memory_access_fault_detect &&
        (
            instruction_access_fault ||
            !is_legal_instruction ||
            is_ecall ||
            is_ebreak ||
            is_misaligned_access
        );
    assign immediate_exception_taken =
        immediate_exception_pending && !dcache_pipeline_stall;
    // The branch comparator feeds only the one-bit capture event. The pending
    // register drives redirect and trap metadata on the following cycle.
    assign instruction_misaligned_taken =
        InstructionMisalignPending &&
        !InstructionMisalignCancel &&
        !dcache_pipeline_stall;
    assign exception_taken =
        memory_access_fault_taken ||
        immediate_exception_taken ||
        instruction_misaligned_taken;
    assign exception_pending =
        memory_access_fault_detect ||
        immediate_exception_pending ||
        (InstructionMisalignPending && !InstructionMisalignCancel);
    assign mret_taken =
        ENABLE_CSR_TRAPS &&
        !ControlRedirectPending &&
        !memory_access_fault_detect &&
        IDEXValid &&
        is_mret;
    assign architectural_mret_taken = mret_taken && !dcache_pipeline_stall;
    assign machine_external_interrupt_pending =
        ENABLE_CSR_TRAPS &&
        CSRmstatus[3] &&
        CSRmie[11] &&
        CSRmip[11] &&
        !MachineExternalInterruptActive;
    assign machine_timer_interrupt_pending =
        ENABLE_CSR_TRAPS &&
        CSRmstatus[3] &&
        CSRmie[7] &&
        CSRmip[7] &&
        !MachineTimerInterruptActive;
    assign machine_interrupt_pending =
        machine_external_interrupt_pending ||
        machine_timer_interrupt_pending;
    assign machine_interrupt_cause =
        machine_external_interrupt_pending ? 32'h8000_000b : 32'h8000_0007;
    trap_redirect_control_unit trap_redirect_control (
        .reset(reset),
        .instruction_valid(IDEXValid),
        .machine_interrupt_pending(machine_interrupt_pending),
        .control_redirect_pending(ControlRedirectPending),
        .control_interrupt_deferred(ControlInterruptDeferred),
        .instruction_is_control(IDEXBranch || IDEXJump),
        .instruction_is_m_extension(IDEXMExtension),
        .dcache_pipeline_stall(dcache_pipeline_stall),
        .exception_taken(exception_taken),
        .exception_pending(exception_pending),
        .mret_taken(mret_taken),
        .interrupt_eligible(interrupt_eligible),
        .interrupt_taken(interrupt_taken),
        .redirect_taken(redirect_taken)
    );
    // Only faults relevant to a valid control instruction, older memory-stage
    // traps, and registered recovery state participate in this acceptance
    // cone. Load/store and SYSTEM-only exception terms are mutually exclusive.
    assign control_resolution_blocked =
        ControlRedirectPending ||
        InstructionMisalignPending ||
        memory_access_fault_taken ||
        instruction_access_fault ||
        !is_legal_instruction ||
        interrupt_taken;
    assign control_resolution_accept =
        ENABLE_CONTROL_REDIRECTS &&
        IDEXValid &&
        (IDEXBranch || IDEXJump) &&
        !dcache_pipeline_stall &&
        !control_resolution_blocked;
    assign branch_mispredict =
        control_resolution_accept &&
        branch_mispredict_raw &&
        !instruction_misaligned_detect;
    assign jump_mispredict =
        control_resolution_accept &&
        jump_mispredict_raw &&
        !instruction_misaligned_detect;
    // The redirect candidate may be captured for a faulting control transfer,
    // but InstructionMisalignPending wins on the next cycle and clears it
    // before it can redirect the frontend.
    assign control_mispredict_accept =
        control_resolution_accept &&
        (branch_mispredict_raw || jump_mispredict_raw);
    assign control_redirect_apply =
        ControlRedirectPending && !dcache_pipeline_stall;
    // The wide recovery candidates are captured without branch-comparator
    // data. Only this registered one-bit selector depends on branch outcome.
    assign ControlRedirectPC = ControlRedirectUseFallthrough ?
                               ControlRedirectFallthroughPC :
                               ControlRedirectTargetPC;
    assign trap_taken = exception_taken || interrupt_taken;
    assign rv32m_squash = trap_taken || control_redirect_apply;
    // exception_decode_unit owns classification. This timing-factored core
    // owns acceptance priority, cause mapping, and the delayed IALIGN handoff.
    assign exception_cause =
        instruction_access_fault ? 32'd1 :
        !is_legal_instruction ? 32'd2 :
        is_ecall ? 32'd11 :
        is_ebreak ? 32'd3 :
        is_misaligned_load ? 32'd4 :
        is_misaligned_store ? 32'd6 :
        32'd0;
    assign trap_cause = interrupt_taken ? machine_interrupt_cause :
                        load_access_fault ? 32'd5 :
                        store_access_fault ? 32'd7 :
                        InstructionMisalignPending ? 32'd0 :
                        exception_cause;
    assign exception_tval =
        instruction_access_fault ? IDEXPC :
        !is_legal_instruction ? IDEXIR :
        is_misaligned_access ? execute_arithmetic_result :
        32'h0;
    assign trap_tval = interrupt_taken ? 32'h0 :
                       memory_access_fault_taken ? EXMEMALUOut :
                       InstructionMisalignPending ? InstructionMisalignTarget :
                       exception_tval;
    wire [31:0] trap_pc =
        memory_access_fault_taken ? EXMEMPC :
        InstructionMisalignPending ? InstructionMisalignPC :
        IDEXPC;

    assign csr_write_enable =
        execute_instruction_accept &&
        ENABLE_CSR_TRAPS &&
        is_csr_access &&
        is_valid_csr;

    // Accepted mret (SYSTEM funct3=000) and accepted CSR access
    // (funct3=001/010/011) must remain mutually exclusive. Keep the formal
    // contract in the integrated core so csr_unit can omit mret from unrelated
    // CSR enables.
`ifdef FORMAL
    wire formal_metadata_csr_write =
        csr_write_enable &&
        ((IDEXfunct3 == 3'b001) ||
         (((IDEXfunct3 == 3'b010) || (IDEXfunct3 == 3'b011)) &&
          (IDEXrs1 != 5'd0))) &&
        ((IDEXcsr == 12'h341) ||
         (IDEXcsr == 12'h342) ||
         (IDEXcsr == 12'h343));

    always @(posedge clock) begin
        if (!reset) begin
            assert(AinAddressLow == Ain[1:0]);
            assert(!(architectural_mret_taken && csr_write_enable));
            if (dcache_pipeline_stall) begin
                assert(!immediate_exception_taken);
                assert(!instruction_misaligned_taken);
                assert(!csr_write_enable);
            end
            // The standalone CSR unit defines pending metadata commit above a
            // simultaneous direct metadata write.  The integrated pipeline is
            // stricter: handler execution cannot reach such a write before the
            // one-cycle trap metadata pipeline drains.
            assert(!(CSRTrapMetadataPending && formal_metadata_csr_write));
        end
    end
`endif

    csr_unit csr_unit_inst (
        .clock(clock),
        .reset(reset),
        .csr_addr(IDEXcsr),
        .csr_funct3(IDEXfunct3),
        .csr_write_enable(csr_write_enable),
        .csr_rs1_value(Ain),
        .csr_rs1_nonzero(IDEXrs1 != 5'd0),
        .trap_taken(trap_taken),
        .mret_taken(architectural_mret_taken),
        .trap_pc(trap_pc),
        .trap_cause(trap_cause),
        .trap_tval(trap_tval),
        .mip_timer_pending(timer_irq_pending),
        .mip_external_pending(matvec_irq_pending),
        .csr_read_data(csr_read_data),
        .mstatus_out(CSRmstatus),
        .mie_out(CSRmie),
        .mtvec_out(CSRmtvec),
        .mepc_out(CSRmepc),
        .mcause_out(CSRmcause),
        .mtval_out(CSRmtval),
        .mip_out(CSRmip),
        .trap_metadata_pending_out(CSRTrapMetadataPending)
    );

    wire [31:0] redirect_pc;

    // Branch/jump correction enters this path only from registered recovery
    // metadata. Trap and mret redirects retain their architectural priority.
    // Exception > mret > interrupt > control recovery. A stalled candidate
    // cannot change PC: pipeline_control applies the memory-stall guard.
    assign redirect_pc = exception_pending ? CSRmtvec :
                         mret_taken ? CSRmepc :
                         interrupt_eligible ? CSRmtvec :
                         ControlRedirectPC;

    // ================================
    // Return prediction and load-use hazards
    // ================================

    wire        ras_predict_taken;
    wire        IFReturnHint;
    wire [31:0] ras_predicted_pc;
    wire        ras_update_is_call;
    wire        ras_update_is_return;
    wire        ras_update_accept;

    assign ras_update_is_call = is_jal && (IDEXrd == 5'd1);
    assign ras_update_is_return =
        is_jalr &&
        (IDEXfunct3 == 3'b000) &&
        (IDEXrd == 5'd0) &&
        (IDEXrs1 == 5'd1) &&
        (IDEXIR[31:20] == 12'd0);
    // Calls and canonical returns cannot raise memory/CSR/RV32M exceptions.
    // Keep only guards that can block their current resolution edge.
    assign ras_update_accept =
        ENABLE_CONTROL_REDIRECTS &&
        IDEXValid &&
        (ras_update_is_call || ras_update_is_return) &&
        !dcache_pipeline_stall &&
        !ControlRedirectPending &&
        (control_target_address[1:0] == 2'b00) &&
        !exception_taken &&
        !interrupt_eligible;

    generate
        if (ENABLE_BRANCH_PREDICTOR) begin : gen_return_address_stack
            ras_unit return_address_stack (
                .clock(clock),
                .reset(reset),
                .fetch_is_return(IFReturnHint),
                .ras_predict_taken(ras_predict_taken),
                .ras_predicted_pc(ras_predicted_pc),
                .update_valid(ras_update_accept),
                .update_is_call(ras_update_is_call),
                .update_is_return(ras_update_is_return),
                .update_return_pc(IDEXPC + 32'd4),
                .ras_count_debug(RASCount),
                .ras_top_debug(RASTop)
            );
        end else begin : gen_no_return_address_stack
            assign ras_predict_taken = 1'b0;
            assign ras_predicted_pc = 32'h0;
            assign RASCount = 4'h0;
            assign RASTop = 3'h0;
        end
    endgenerate

    wire        final_predict_taken;
    wire [31:0] final_predicted_pc;

    assign final_predict_taken = ras_predict_taken || bp_predict_taken;

    assign final_predicted_pc  = ras_predict_taken ? ras_predicted_pc : bp_predicted_pc;

    wire load_use_hazard;

    hazard_unit load_use_hazard_unit (
        .ifid_opcode(IFIDop),
        .ifid_funct3(IFIDfunct3),
        .ifid_rs1(IFIDrs1),
        .ifid_rs2(IFIDrs2),
        .idex_mem_read(IDEXValid && IDEXMemRead),
        .idex_rd(IDEXrd),
        .load_use_hazard(load_use_hazard)
    );

    // ================================
    // Memory-stage MMIO decode and data formatting
    // ================================
    wire [ 1:0] cache_byte_offset;
    wire        cache_hit;
    wire        EXMEMGpioOutputAccess;
    wire        EXMEMGpioInputAccess;
    wire        EXMEMUartTxDataAccess;
    wire        EXMEMUartRxDataAccess;
    wire        EXMEMUartStatusAccess;
    wire        EXMEMUartAccess;
    wire        EXMEMMatvecCtrlAccess;
    wire        EXMEMMatvecStatusAccess;
    wire        EXMEMMatvecConfigAccess;
    wire        EXMEMMatvecVectorAccess;
    wire        EXMEMMatvecRowIndexAccess;
    wire        EXMEMMatvecRowDataAccess;
    wire        EXMEMMatvecResultIndexAccess;
    wire        EXMEMMatvecResultDataAccess;
    wire        EXMEMMatvecPerfAccess;
    wire        EXMEMMatvecAccess;
    wire        EXMEMPerfCycleCountAccess;
    wire        EXMEMPerfRetiredCountAccess;
    wire        EXMEMPerfBranchMissCountAccess;
    wire        EXMEMPerfICacheMissCountAccess;
    wire        EXMEMPerfDCacheMissCountAccess;
    wire        EXMEMPerfStallCycleCountAccess;
    wire        EXMEMPerfMatvecStartCountAccess;
    wire        EXMEMPerfMatvecDoneCountAccess;
    wire        EXMEMPerfMatvecBusyCycleCountAccess;
    wire        EXMEMPerfCounterAccess;
    wire        EXMEMMatvecDmaVecAddrAccess;
    wire        EXMEMMatvecDmaMatrixAddrAccess;
    wire        EXMEMMatvecDmaOutAddrAccess;
    wire        EXMEMMatvecDmaRowsAccess;
    wire        EXMEMMatvecDmaCtrlAccess;
    wire        EXMEMMatvecDmaStatusAccess;
    wire        EXMEMMatvecDmaErrorAccess;
    wire        EXMEMMatvecDmaPerfAccess;
    wire        EXMEMMatvecDmaAccess;
    wire        EXMEMTimerMtimeLowAccess;
    wire        EXMEMTimerMtimeHighAccess;
    wire        EXMEMTimerMtimecmpLowAccess;
    wire        EXMEMTimerMtimecmpHighAccess;
    wire        EXMEMTimerAccess;
    wire        EXMEMAnyMmioSelect;
    wire        EXMEMMmioAccess;

    assign cache_byte_offset = EXMEMALUOut[1:0];
    assign EXMEMUartAccess =
        EXMEMUartTxDataAccess ||
        EXMEMUartRxDataAccess ||
        EXMEMUartStatusAccess;
    assign matvec_busy = matvec_status_read_data[0];
    assign matvec_done = matvec_status_read_data[1];
    assign matvec_start_accepted =
        ENABLE_ACCELERATORS && ENABLE_MATVEC_SCRATCHPAD &&
        EXMEMStoreValid &&
        EXMEMMatvecCtrlAccess &&
        matvec_store_byte_enable[0] &&
        matvec_store_data[0] &&
        !matvec_busy;

    // MMIO addresses are decoded at the memory stage and bypass the D-cache;
    // subword formatting is still shared with normal loads/stores below.
    // A stale payload may decode as memory/MMIO after a bubble. EXMEMValid is
    // authoritative: invalid payload must not bypass the D-cache or authorize
    // any memory-stage side effect.
    assign EXMEMMmioAccess =
        EXMEMValid && EXMEMMemAccess && EXMEMAnyMmioSelect;
    // Pop the RX queue on the same edge that captures RXDATA into MEM/WB, so
    // the next read sees the next byte and an immediate status read sees the
    // updated count. An MMIO load never raises a memory-stage hold, so this
    // edge always retires the load.
    assign UARTRxReady =
        EXMEMLoadValid && EXMEMMmioAccess && EXMEMUartRxDataAccess;

    mmio_decode exmem_mmio_decode (
        .addr(EXMEMALUOut),
        .gpio_output_sel(EXMEMGpioOutputAccess),
        .gpio_input_sel(EXMEMGpioInputAccess),
        .uart_tx_sel(EXMEMUartTxDataAccess),
        .uart_rx_sel(EXMEMUartRxDataAccess),
        .uart_status_sel(EXMEMUartStatusAccess),
        .matvec_ctrl_sel(EXMEMMatvecCtrlAccess),
        .matvec_status_sel(EXMEMMatvecStatusAccess),
        .matvec_config_sel(EXMEMMatvecConfigAccess),
        .matvec_vector_sel(EXMEMMatvecVectorAccess),
        .matvec_row_index_sel(EXMEMMatvecRowIndexAccess),
        .matvec_row_data_sel(EXMEMMatvecRowDataAccess),
        .matvec_result_index_sel(EXMEMMatvecResultIndexAccess),
        .matvec_result_data_sel(EXMEMMatvecResultDataAccess),
        .matvec_perf_sel(EXMEMMatvecPerfAccess),
        .perf_cycle_count_sel(EXMEMPerfCycleCountAccess),
        .perf_retired_count_sel(EXMEMPerfRetiredCountAccess),
        .perf_branch_miss_count_sel(EXMEMPerfBranchMissCountAccess),
        .perf_icache_miss_count_sel(EXMEMPerfICacheMissCountAccess),
        .perf_dcache_miss_count_sel(EXMEMPerfDCacheMissCountAccess),
        .perf_stall_cycle_count_sel(EXMEMPerfStallCycleCountAccess),
        .perf_matvec_start_count_sel(EXMEMPerfMatvecStartCountAccess),
        .perf_matvec_done_count_sel(EXMEMPerfMatvecDoneCountAccess),
        .perf_matvec_busy_cycle_count_sel(EXMEMPerfMatvecBusyCycleCountAccess),
        .matvec_dma_vec_addr_sel(EXMEMMatvecDmaVecAddrAccess),
        .matvec_dma_matrix_addr_sel(EXMEMMatvecDmaMatrixAddrAccess),
        .matvec_dma_out_addr_sel(EXMEMMatvecDmaOutAddrAccess),
        .matvec_dma_rows_sel(EXMEMMatvecDmaRowsAccess),
        .matvec_dma_ctrl_sel(EXMEMMatvecDmaCtrlAccess),
        .matvec_dma_status_sel(EXMEMMatvecDmaStatusAccess),
        .matvec_dma_error_sel(EXMEMMatvecDmaErrorAccess),
        .matvec_dma_perf_sel(EXMEMMatvecDmaPerfAccess),
        .timer_mtime_low_sel(EXMEMTimerMtimeLowAccess),
        .timer_mtime_high_sel(EXMEMTimerMtimeHighAccess),
        .timer_mtimecmp_low_sel(EXMEMTimerMtimecmpLowAccess),
        .timer_mtimecmp_high_sel(EXMEMTimerMtimecmpHighAccess),
        .matvec_sel(EXMEMMatvecAccess),
        .matvec_dma_sel(EXMEMMatvecDmaAccess),
        .perf_counter_sel(EXMEMPerfCounterAccess),
        .timer_sel(EXMEMTimerAccess),
        .any_mmio_sel(EXMEMAnyMmioSelect)
    );

    wire cache_miss;
    wire dcache_request_complete;

    wire cache_busy;

    wire [31:0] mmio_load_word;
    wire [31:0] mmio_load_value;
    wire [31:0] gpio_store_merged_value;
    reg [31:0] matvec_store_data;
    reg [3:0] matvec_store_byte_enable;
    wire [31:0] matvec_dma_store_old_word;
    wire [31:0] matvec_dma_store_merged_value;
    wire [31:0] timer_store_old_word;
    wire [31:0] timer_store_merged_value;
    wire [31:0] debug_status_store_merged_value;
    wire [31:0] dcache_load_word;
    wire [31:0] dcache_load_value;
    wire dcache_load_word_valid;
    wire dcache_external_wait;
    wire [31:0] dcache_external_addr;
    wire dcache_external_read;
    wire dcache_external_write;
    wire [127:0] dcache_external_wdata;
    wire [15:0] dcache_external_byte_enable;
    wire [31:0] matvec_dma_dmem_addr;
    wire [31:0] matvec_dma_dmem_word_addr;
    wire matvec_dma_dmem_read;
    wire matvec_dma_dmem_write;
    wire matvec_dma_dmem_request;
    wire [127:0] matvec_dma_dmem_wdata;
    wire [15:0] matvec_dma_dmem_byte_enable;
    wire [127:0] matvec_dma_dmem_rdata;
    wire matvec_dma_dmem_ready;
    wire [127:0] matvec_dma_internal_refill_line;
    wire [31:0] matvec_dma_internal_line_base_word;
    wire dcache_dma_snoop_hit;
    wire [31:0] dcache_dma_snoop_read_word;
    wire matvec_dma_cpu_memory_stall;
    wire [127:0] dcache_internal_refill_line;
    wire dcache_internal_writeback_valid;
    wire [31:0] dcache_internal_writeback_addr;
    wire [127:0] dcache_internal_writeback_line;
    wire [31:0] dcache_internal_line_base_word;
    wire [31:0] direct_dmem_word;
    wire [31:0] direct_dmem_store_merged_value;
    wire debug_status_store_word_access;
    wire debug_status_store_commit;

    assign debug_status_store_word_access =
        ({EXMEMALUOut[31:2], 2'b00} == DEBUG_STATUS_ADDR);
    // Mirror the store on the edge the D-cache completes it: a hit, a refill
    // or a victim-buffer swap.
    assign debug_status_store_commit =
        EXMEMStoreValid &&
        !EXMEMMmioAccess &&
        debug_status_store_word_access &&
        dcache_request_complete;

    mmio_read_mux exmem_mmio_read_mux (
        .addr(EXMEMALUOut),
        .gpio_output_read_data(GPIOOutput),
        .gpio_input_read_data(gpio_inputs),
        .uart_rx_read_data({24'h0, uart_rx_data}),
        .uart_status_read_data({29'h0, uart_rx_overrun, (uart_tx_ready && !UARTTxValid), uart_rx_valid}),
        .matvec_status_read_data(matvec_status_read_data),
        .matvec_config_read_data(matvec_config_read_data),
        .matvec_vector_read_data(matvec_vector_read_data),
        .matvec_row_index_read_data(matvec_row_index_read_data),
        .matvec_row_data_read_data(matvec_row_data_read_data),
        .matvec_result_index_read_data(matvec_result_index_read_data),
        .matvec_result_data_read_data(matvec_result_data_read_data),
        .matvec_perf_read_data(matvec_perf_read_data),
        .perf_cycle_count_read_data(CycleCount),
        .perf_retired_count_read_data(RetiredCount),
        .perf_branch_miss_count_read_data(BranchMissCount),
        .perf_icache_miss_count_read_data(ICacheMissCount),
        .perf_dcache_miss_count_read_data(DCacheMissCount),
        .perf_stall_cycle_count_read_data(StallCycleCount),
        .perf_matvec_start_count_read_data(MatvecStartCount),
        .perf_matvec_done_count_read_data(MatvecDoneCount),
        .perf_matvec_busy_cycle_count_read_data(MatvecBusyCycleCount),
        .timer_mtime_low_read_data(timer_mtime_low_read_data),
        .timer_mtime_high_read_data(timer_mtime_high_read_data),
        .timer_mtimecmp_low_read_data(timer_mtimecmp_low_read_data),
        .timer_mtimecmp_high_read_data(timer_mtimecmp_high_read_data),
        .matvec_dma_vec_addr_read_data(matvec_dma_vec_addr_read_data),
        .matvec_dma_matrix_addr_read_data(matvec_dma_matrix_addr_read_data),
        .matvec_dma_out_addr_read_data(matvec_dma_out_addr_read_data),
        .matvec_dma_rows_read_data(matvec_dma_rows_read_data),
        .matvec_dma_ctrl_read_data(matvec_dma_ctrl_read_data),
        .matvec_dma_status_read_data(matvec_dma_status_read_data),
        .matvec_dma_error_read_data(matvec_dma_error_read_data),
        .matvec_dma_perf_read_data(matvec_dma_perf_read_data),
        .read_word(mmio_load_word)
    );

    // Prepare write lanes independently of MMIO address decoding. The
    // destination registers merge only enabled bytes, avoiding the old
    // address -> readback mux -> merged data -> indexed row selection path.
    always @(*) begin
        matvec_store_data = StoreData;
        matvec_store_byte_enable = 4'b1111;
        case (EXMEMfunct3)
            3'b000: begin
                matvec_store_data = {24'h0, StoreData[7:0]} << (8 * cache_byte_offset);
                matvec_store_byte_enable = 4'b0001 << cache_byte_offset;
            end
            3'b001: begin
                matvec_store_data = {16'h0, StoreData[15:0]} << (16 * cache_byte_offset[1]);
                matvec_store_byte_enable = cache_byte_offset[1] ? 4'b1100 : 4'b0011;
            end
            default: begin end
        endcase
    end

    assign matvec_dma_store_old_word =
        EXMEMMatvecDmaVecAddrAccess ? matvec_dma_vec_addr_read_data :
        EXMEMMatvecDmaMatrixAddrAccess ? matvec_dma_matrix_addr_read_data :
        EXMEMMatvecDmaOutAddrAccess ? matvec_dma_out_addr_read_data :
        EXMEMMatvecDmaRowsAccess ? matvec_dma_rows_read_data :
        EXMEMMatvecDmaCtrlAccess ? matvec_dma_ctrl_read_data :
        StoreData;

    assign timer_store_old_word =
        EXMEMTimerMtimeLowAccess ? timer_mtime_low_read_data :
        EXMEMTimerMtimeHighAccess ? timer_mtime_high_read_data :
        EXMEMTimerMtimecmpLowAccess ? timer_mtimecmp_low_read_data :
        EXMEMTimerMtimecmpHighAccess ? timer_mtimecmp_high_read_data :
        StoreData;

    assign dcache_internal_line_base_word = {EXMEMALUOut[31:4], 4'b0000} >> 2;
    assign dcache_internal_refill_line = USE_EXTERNAL_DMEM ? 128'h0 : {
        ((dcache_internal_line_base_word + 3) < MEMORY_WORD_COUNT) ?
            DMemory[dcache_internal_line_base_word + 3] : 32'h0,
        ((dcache_internal_line_base_word + 2) < MEMORY_WORD_COUNT) ?
            DMemory[dcache_internal_line_base_word + 2] : 32'h0,
        ((dcache_internal_line_base_word + 1) < MEMORY_WORD_COUNT) ?
            DMemory[dcache_internal_line_base_word + 1] : 32'h0,
        (dcache_internal_line_base_word < MEMORY_WORD_COUNT) ?
            DMemory[dcache_internal_line_base_word] : 32'h0
    };
    assign direct_dmem_word =
        (!USE_EXTERNAL_DMEM && ((EXMEMALUOut >> 2) < INTERNAL_DMEM_WORD_COUNT)) ?
        DMemory[EXMEMALUOut >> 2] :
        32'h0;
    assign matvec_dma_dmem_request = matvec_dma_dmem_read || matvec_dma_dmem_write;
    assign matvec_dma_dmem_ready =
        USE_EXTERNAL_DMEM ? dmem_ready : matvec_dma_dmem_request;
    assign matvec_dma_internal_line_base_word = matvec_dma_dmem_addr >> 2;
    assign matvec_dma_internal_refill_line = USE_EXTERNAL_DMEM ? 128'h0 : {
        ((matvec_dma_internal_line_base_word + 3) < MEMORY_WORD_COUNT) ?
            DMemory[matvec_dma_internal_line_base_word + 3] : 32'h0,
        ((matvec_dma_internal_line_base_word + 2) < MEMORY_WORD_COUNT) ?
            DMemory[matvec_dma_internal_line_base_word + 2] : 32'h0,
        ((matvec_dma_internal_line_base_word + 1) < MEMORY_WORD_COUNT) ?
            DMemory[matvec_dma_internal_line_base_word + 1] : 32'h0,
        (matvec_dma_internal_line_base_word < MEMORY_WORD_COUNT) ?
            DMemory[matvec_dma_internal_line_base_word] : 32'h0
    };
    assign matvec_dma_dmem_rdata =
        USE_EXTERNAL_DMEM ? dmem_rdata : matvec_dma_internal_refill_line;

    load_store_format_unit mmio_load_format (
        .word_data(mmio_load_word),
        .store_data(StoreData),
        .byte_offset(cache_byte_offset),
        .funct3(EXMEMfunct3),
        .load_value(mmio_load_value),
        .store_merged_value()
    );

    load_store_format_unit gpio_store_format (
        .word_data(GPIOOutput),
        .store_data(StoreData),
        .byte_offset(cache_byte_offset),
        .funct3(EXMEMfunct3),
        .load_value(),
        .store_merged_value(gpio_store_merged_value)
    );

    load_store_format_unit matvec_dma_store_format (
        .word_data(matvec_dma_store_old_word),
        .store_data(StoreData),
        .byte_offset(cache_byte_offset),
        .funct3(EXMEMfunct3),
        .load_value(),
        .store_merged_value(matvec_dma_store_merged_value)
    );

    load_store_format_unit timer_store_format (
        .word_data(timer_store_old_word),
        .store_data(StoreData),
        .byte_offset(cache_byte_offset),
        .funct3(EXMEMfunct3),
        .load_value(),
        .store_merged_value(timer_store_merged_value)
    );

    load_store_format_unit debug_status_store_format (
        .word_data(DebugStatus),
        .store_data(StoreData),
        .byte_offset(cache_byte_offset),
        .funct3(EXMEMfunct3),
        .load_value(),
        .store_merged_value(debug_status_store_merged_value)
    );

    load_store_format_unit dcache_load_format (
        .word_data(dcache_load_word),
        .store_data(StoreData),
        .byte_offset(cache_byte_offset),
        .funct3(EXMEMfunct3),
        .load_value(dcache_load_value),
        .store_merged_value()
    );

    load_store_format_unit direct_dmem_store_format (
        .word_data(direct_dmem_word),
        .store_data(StoreData),
        .byte_offset(cache_byte_offset),
        .funct3(EXMEMfunct3),
        .load_value(),
        .store_merged_value(direct_dmem_store_merged_value)
    );

    // ================================
    // Data cache and direct-memory alternative
    // ================================
    generate
        if (ENABLE_DCACHE) begin : gen_dcache
            dcache_unit #(
                .USE_EXTERNAL_DMEM(USE_EXTERNAL_DMEM),
                .MEMORY_WORD_COUNT(MEMORY_WORD_COUNT),
                .CACHE_BYTES(DCACHE_BYTES),
                .VICTIM_LINES(DCACHE_VICTIM_LINES)
            ) dcache (
                .clock(clock),
                .reset(reset),
                .request_valid(
                    EXMEMValid &&
                    EXMEMMemAccess &&
                    !memory_access_fault_detect &&
                    !matvec_dma_cpu_memory_stall
                ),
                .request_read(EXMEMMemRead),
                .request_write(EXMEMMemWrite),
                .request_addr(EXMEMALUOut),
                .request_funct3(EXMEMfunct3),
                .request_store_data(StoreData),
                .request_mmio(EXMEMMmioAccess),
                .internal_refill_line(dcache_internal_refill_line),
                .internal_writeback_valid(dcache_internal_writeback_valid),
                .internal_writeback_addr(dcache_internal_writeback_addr),
                .internal_writeback_line(dcache_internal_writeback_line),
                .external_rdata(dmem_rdata),
                .external_ready(dmem_ready),
                .dma_snoop_addr(matvec_dma_dmem_word_addr),
                .dma_snoop_write(matvec_dma_dmem_write && matvec_dma_dmem_ready),
                .dma_snoop_write_data(matvec_dma_dmem_wdata[(matvec_dma_dmem_word_addr[3:2] * 32) +: 32]),
                .dma_snoop_hit(dcache_dma_snoop_hit),
                .dma_snoop_read_word(dcache_dma_snoop_read_word),
                .hit(cache_hit),
                .miss(cache_miss),
                .request_complete(dcache_request_complete),
                .busy(cache_busy),
                .external_wait(dcache_external_wait),
                .load_word_data(dcache_load_word),
                .load_word_valid(dcache_load_word_valid),
                .external_addr(dcache_external_addr),
                .external_read(dcache_external_read),
                .external_write(dcache_external_write),
                .external_wdata(dcache_external_wdata),
                .external_byte_enable(dcache_external_byte_enable),
                .state_debug(cache_state),
                .stall_debug(cache_stall),
                .dirty_debug(DCacheDirty)
            );
        end else begin : gen_no_dcache
            assign cache_hit =
                EXMEMValid &&
                EXMEMMemAccess &&
                !memory_access_fault_detect &&
                !matvec_dma_cpu_memory_stall &&
                !EXMEMMmioAccess;
            assign cache_miss = 1'b0;
            assign dcache_request_complete = cache_hit;
            assign cache_busy = 1'b0;
            assign dcache_external_wait = 1'b0;
            assign dcache_load_word = direct_dmem_word;
            assign dcache_load_word_valid = cache_hit && EXMEMLoadValid;
            assign dcache_external_addr = 32'h0;
            assign dcache_external_read = 1'b0;
            assign dcache_external_write = 1'b0;
            assign dcache_external_wdata = 128'h0;
            assign dcache_external_byte_enable = 16'h0;
            assign dcache_internal_writeback_valid = 1'b0;
            assign dcache_internal_writeback_addr = 32'h0;
            assign dcache_internal_writeback_line = 128'h0;
            assign dcache_dma_snoop_hit = 1'b0;
            assign dcache_dma_snoop_read_word = 32'h0;
            assign cache_state = CACHE_IDLE;
            assign cache_stall = 2'b00;
            assign DCacheDirty = 4'h0;
        end
    endgenerate

    // ================================
    // Accelerator and timer MMIO endpoints
    // ================================
    generate
        if (ENABLE_ACCELERATORS && ENABLE_MATVEC_SCRATCHPAD) begin : gen_accelerators
            int8_matvec_scratchpad_accelerator accel_matvec (
                .clock(clock),
                .reset(reset),
                .ctrl_write(EXMEMStoreValid && EXMEMMatvecCtrlAccess),
                .config_write(EXMEMStoreValid && EXMEMMatvecConfigAccess),
                .vector_write(EXMEMStoreValid && EXMEMMatvecVectorAccess),
                .row_index_write(EXMEMStoreValid && EXMEMMatvecRowIndexAccess),
                .row_data_write(EXMEMStoreValid && EXMEMMatvecRowDataAccess),
                .result_index_write(EXMEMStoreValid && EXMEMMatvecResultIndexAccess),
                .clear_done(1'b0),
                .write_data(matvec_store_data),
                .write_byte_enable(matvec_store_byte_enable),
                .status_read_data(matvec_status_read_data),
                .config_read_data(matvec_config_read_data),
                .vector_read_data(matvec_vector_read_data),
                .row_index_read_data(matvec_row_index_read_data),
                .row_data_read_data(matvec_row_data_read_data),
                .result_index_read_data(matvec_result_index_read_data),
                .result_data_read_data(matvec_result_data_read_data),
                .perf_read_data(matvec_perf_read_data),
                .irq_pending(matvec_irq_pending)
            );

        end else begin : gen_no_scratchpad
            assign matvec_status_read_data = 32'h0;
            assign matvec_config_read_data = 32'h0;
            assign matvec_vector_read_data = 32'h0;
            assign matvec_row_index_read_data = 32'h0;
            assign matvec_row_data_read_data = 32'h0;
            assign matvec_result_index_read_data = 32'h0;
            assign matvec_result_data_read_data = 32'h0;
            assign matvec_perf_read_data = 32'h0;
            assign matvec_irq_pending = 1'b0;
        end
        if (ENABLE_ACCELERATORS && ENABLE_MATVEC_DMA) begin : gen_dma_accelerator
            int8_matvec_dma_lite #(
                .DMEM_WORD_COUNT(MEMORY_WORD_COUNT)
            ) accel_matvec_dma (
                .clock(clock),
                .reset(reset),
                .vec_addr_write(EXMEMStoreValid && EXMEMMatvecDmaVecAddrAccess),
                .matrix_addr_write(EXMEMStoreValid && EXMEMMatvecDmaMatrixAddrAccess),
                .out_addr_write(EXMEMStoreValid && EXMEMMatvecDmaOutAddrAccess),
                .rows_write(EXMEMStoreValid && EXMEMMatvecDmaRowsAccess),
                .ctrl_write(EXMEMStoreValid && EXMEMMatvecDmaCtrlAccess),
                .write_data(matvec_dma_store_merged_value),
                .vec_addr_read_data(matvec_dma_vec_addr_read_data),
                .matrix_addr_read_data(matvec_dma_matrix_addr_read_data),
                .out_addr_read_data(matvec_dma_out_addr_read_data),
                .rows_read_data(matvec_dma_rows_read_data),
                .ctrl_read_data(matvec_dma_ctrl_read_data),
                .status_read_data(matvec_dma_status_read_data),
                .error_read_data(matvec_dma_error_read_data),
                .perf_read_data(matvec_dma_perf_read_data),
                .busy(matvec_dma_busy),
                .done(matvec_dma_done),
                .error(matvec_dma_error),
                .irq_pending(matvec_dma_irq_pending),
                .dmem_read(matvec_dma_dmem_read),
                .dmem_write(matvec_dma_dmem_write),
                .dmem_addr(matvec_dma_dmem_addr),
                .dmem_word_addr(matvec_dma_dmem_word_addr),
                .dmem_wdata(matvec_dma_dmem_wdata),
                .dmem_byte_enable(matvec_dma_dmem_byte_enable),
                .dmem_rdata(matvec_dma_dmem_rdata),
                .dmem_ready(matvec_dma_dmem_ready),
                .dmem_snoop_hit(dcache_dma_snoop_hit),
                .dmem_snoop_word(dcache_dma_snoop_read_word)
            );
        end else begin : gen_no_dma
            assign matvec_dma_vec_addr_read_data = 32'h0;
            assign matvec_dma_matrix_addr_read_data = 32'h0;
            assign matvec_dma_out_addr_read_data = 32'h0;
            assign matvec_dma_rows_read_data = 32'h0;
            assign matvec_dma_ctrl_read_data = 32'h0;
            assign matvec_dma_status_read_data = 32'h0;
            assign matvec_dma_error_read_data = 32'h0;
            assign matvec_dma_perf_read_data = 32'h0;
            assign matvec_dma_busy = 1'b0;
            assign matvec_dma_done = 1'b0;
            assign matvec_dma_error = 1'b0;
            assign matvec_dma_irq_pending = 1'b0;
            assign matvec_dma_dmem_read = 1'b0;
            assign matvec_dma_dmem_write = 1'b0;
            assign matvec_dma_dmem_addr = 32'h0;
            assign matvec_dma_dmem_word_addr = 32'h0;
            assign matvec_dma_dmem_wdata = 128'h0;
            assign matvec_dma_dmem_byte_enable = 16'h0;
        end
    endgenerate

    generate
        if (ENABLE_MACHINE_TIMER) begin : gen_machine_timer
            machine_timer timer (
                .clock(clock),
                .reset(reset),
                .mtime_low_write(EXMEMStoreValid && EXMEMTimerMtimeLowAccess),
                .mtime_high_write(EXMEMStoreValid && EXMEMTimerMtimeHighAccess),
                .mtimecmp_low_write(EXMEMStoreValid && EXMEMTimerMtimecmpLowAccess),
                .mtimecmp_high_write(EXMEMStoreValid && EXMEMTimerMtimecmpHighAccess),
                .write_data(timer_store_merged_value),
                .mtime_low_read_data(timer_mtime_low_read_data),
                .mtime_high_read_data(timer_mtime_high_read_data),
                .mtimecmp_low_read_data(timer_mtimecmp_low_read_data),
                .mtimecmp_high_read_data(timer_mtimecmp_high_read_data),
                .timer_irq(timer_irq_pending)
            );
        end else begin : gen_no_machine_timer
            assign timer_mtime_low_read_data = 32'h0;
            assign timer_mtime_high_read_data = 32'h0;
            assign timer_mtimecmp_low_read_data = 32'h0;
            assign timer_mtimecmp_high_read_data = 32'h0;
            assign timer_irq_pending = 1'b0;
        end
    endgenerate

    // ================================
    // Instruction cache address logic
    // ================================
    wire icache_miss;
    wire icache_busy;
    wire [31:0] icache_refill_addr;
    wire [127:0] icache_internal_line_data;
    wire [31:0] icache_internal_line_base_word;
    wire if_redirect;

    assign icache_internal_line_base_word = {icache_refill_addr[31:4], 4'b0000} >> 2;

    generate
        if (ENABLE_ICACHE) begin : gen_icache
            assign icache_internal_line_data = USE_EXTERNAL_IMEM ? 128'h0 : {
                ((icache_internal_line_base_word + 3) < MEMORY_WORD_COUNT) ?
                    IMemory[icache_internal_line_base_word + 3] : NOP,
                ((icache_internal_line_base_word + 2) < MEMORY_WORD_COUNT) ?
                    IMemory[icache_internal_line_base_word + 2] : NOP,
                ((icache_internal_line_base_word + 1) < MEMORY_WORD_COUNT) ?
                    IMemory[icache_internal_line_base_word + 1] : NOP,
                (icache_internal_line_base_word < MEMORY_WORD_COUNT) ?
                    IMemory[icache_internal_line_base_word] : NOP
            };

            icache_unit #(
                .USE_EXTERNAL_IMEM(USE_EXTERNAL_IMEM),
                .CACHE_BYTES(ICACHE_BYTES),
                .PARALLEL_LOOKUP(ICACHE_PARALLEL_LOOKUP)
            ) instruction_cache (
                .clock(clock),
                .reset(reset),
                .pc(PC),
                .internal_line_data(icache_internal_line_data),
                .external_line_data(imem_rdata),
                .external_ready(imem_ready),
                .cancel_refill(if_redirect),
                .instruction(IFInstruction),
                .return_hint(IFReturnHint),
                .miss(icache_miss),
                .busy(icache_busy),
                .external_read(icache_external_read),
                .refill_addr(icache_refill_addr),
                .state_debug(icache_state),
                .stall_debug(icache_stall),
                .lru_set0_debug(lru_set0),
                .lru_set1_debug(lru_set1)
            );
        end else begin : gen_no_icache
            assign IFReturnHint = (IFInstruction & 32'hffff_8fff) == 32'h0000_8067;
            assign icache_internal_line_data = 128'h0;
            assign IFInstruction =
                USE_EXTERNAL_IMEM ?
                imem_rdata[(PC[3:2] * 32) +: 32] :
                ((PC >> 2) < MEMORY_WORD_COUNT) ? IMemory[PC >> 2] : NOP;
            assign icache_miss = 1'b0;
            assign icache_busy = 1'b0;
            assign icache_external_read = 1'b0;
            assign icache_refill_addr = {PC[31:4], 4'b0000};
            assign icache_state = 2'b00;
            assign icache_stall = 2'b00;
            assign lru_set0 = 1'b0;
            assign lru_set1 = 1'b0;
        end
    endgenerate

    // ================================
    // Pipeline holds, advancement, and retirement events
    // ================================
    wire if_hold;
    wire if_advance;
    wire id_hold;
    wire id_bubble;
    wire id_advance;
    wire id_payload_hold;
    wire ex_hold;
    wire ex_advance;
    wire if_accept_instruction;
    wire memwb_update;
    wire memwb_input_valid;
    wire trace_event;
    wire retire_event;
    wire branch_mispredict_event;
    wire icache_miss_event;
    wire dcache_miss_event;
    wire stall_event;
    wire matvec_start_accepted_event;
    wire matvec_done_rise_event;

    // While DMA owns DMEM, hold CPU non-MMIO memory operations until the
    // transfer completes or yields the port.
    assign matvec_dma_cpu_memory_stall =
        matvec_dma_busy &&
        EXMEMValid &&
        EXMEMMemAccess &&
        !EXMEMMmioAccess;
    wire uart_tx_pipeline_stall =
        EXMEMStoreValid &&
        EXMEMUartTxDataAccess &&
        (!uart_tx_ready || UARTTxValid);
    // An out-of-range access suppresses dcache request_valid, so it cannot
    // create a cache_miss. Keep only holds that can already be active when
    // deciding whether the precise access fault may be accepted.
    assign memory_access_fault_stall =
        cache_busy ||
        matvec_dma_cpu_memory_stall ||
        uart_tx_pipeline_stall;
    assign dcache_pipeline_stall =
        cache_busy ||
        cache_miss ||
        matvec_dma_cpu_memory_stall ||
        uart_tx_pipeline_stall;
    assign icache_pipeline_stall = icache_miss || icache_busy;
    assign memwb_update =
        !dcache_pipeline_stall || dcache_request_complete;
    assign trace_event = memwb_update && !cache_miss;
    // Qualify the MEM/WB input separately from the edge that captures it.
    // Trace reporting additionally waits for the cache-miss event to clear.
    assign memwb_input_valid =
        EXMEMValid &&
        !memory_access_fault_taken &&
        !InstructionMisalignPending;
    assign retire_event = trace_event && memwb_input_valid;
    // Derive the branch-only counter event from registered recovery state.
    // PendingPrev turns a recovery held by backpressure into one pulse, while
    // the captured instruction class excludes JAL/JALR. Misaligned transfers
    // use the trap path and therefore must not count as branch misses.
    assign branch_mispredict_event =
        ControlRedirectPending &&
        !ControlRedirectPendingPrev &&
        ControlResolutionWasBranch &&
        !InstructionMisalignPending;
    assign icache_miss_event = icache_miss;
    assign dcache_miss_event = cache_miss;
    assign stall_event =
        dcache_pipeline_stall ||
        rv32m_execute_stall ||
        icache_pipeline_stall ||
        load_use_hazard;
    assign matvec_start_accepted_event = matvec_start_accepted;
    assign matvec_done_rise_event = matvec_done && !MatvecDonePrev;
    assign if_accept_instruction = if_advance;
    // Payload storage follows only real transaction holds. Redirect and
    // bubble policy owns IDEXValid below, so stale/nonzero payload cannot
    // authorize work and does not need a redirect-derived clear or CE.
    assign id_payload_hold = dcache_pipeline_stall || rv32m_execute_stall;

    pipeline_control_unit pipeline_control (
        .dcache_pipeline_stall(dcache_pipeline_stall),
        .redirect_taken(redirect_taken),
        .icache_pipeline_stall(icache_pipeline_stall),
        .load_use_hazard(load_use_hazard),
        .execute_busy_stall(rv32m_execute_stall),
        .if_hold(if_hold),
        .if_redirect(if_redirect),
        .if_advance(if_advance),
        .id_hold(id_hold),
        .id_bubble(id_bubble),
        .id_advance(id_advance),
        .ex_hold(ex_hold),
        .ex_advance(ex_advance)
    );
    wire [31:0] pc_next_value =
        if_redirect ? redirect_pc :
        if_advance ? final_predicted_pc :
        PC;

    generate
        if (ENABLE_PERF_COUNTERS) begin : gen_performance_counters
            performance_counter_unit performance_counter_inst (
                .clock(clock),
                .reset(reset),
                .retire_event(retire_event),
                .branch_mispredict_event(branch_mispredict_event),
                .icache_miss_event(icache_miss_event),
                .dcache_miss_event(dcache_miss_event),
                .stall_event(stall_event),
                .matvec_start_accepted_event(matvec_start_accepted_event),
                .matvec_done_rise_event(matvec_done_rise_event),
                .matvec_busy(matvec_busy),
                .cycle_count(CycleCount),
                .retired_count(RetiredCount),
                .branch_miss_count(BranchMissCount),
                .icache_miss_count(ICacheMissCount),
                .dcache_miss_count(DCacheMissCount),
                .stall_cycle_count(StallCycleCount),
                .matvec_start_count(MatvecStartCount),
                .matvec_done_count(MatvecDoneCount),
                .matvec_busy_cycle_count(MatvecBusyCycleCount)
            );
        end else begin : gen_no_performance_counters
            assign CycleCount = 32'h0;
            assign RetiredCount = 32'h0;
            assign BranchMissCount = 32'h0;
            assign ICacheMissCount = 32'h0;
            assign DCacheMissCount = 32'h0;
            assign StallCycleCount = 32'h0;
            assign MatvecStartCount = 32'h0;
            assign MatvecDoneCount = 32'h0;
            assign MatvecBusyCycleCount = 32'h0;
        end
    endgenerate

    // ================================
    // Initialization
    // ================================
    integer i;
    integer writeback_word;
    integer dma_byte;


    initial begin
        PC = 0;
        IFIDIR = NOP;
        IDEXIR = NOP;
        EXMEMIR = NOP;
        MEMWBIR = NOP;
        IFIDPC = 0;
        IDEXPC = 0;
        EXMEMPC = 0;
        MEMWBPC = 0;
        EXMEMForwardRegWrite = 1'b0;
        EXMEMWritebackRegWrite = 1'b0;
        EXMEMForwardRd = 5'd0;
        EXMEMForwardUsePCPlus4 = 1'b0;
        MEMWBForwardRegWrite = 1'b0;
        MEMWBForwardRd = 5'd0;
        ControlRedirectPending = 1'b0;
        ControlRedirectPendingPrev = 1'b0;
        ControlResolutionWasBranch = 1'b0;
        ControlRedirectTargetPC = 32'h0;
        ControlRedirectFallthroughPC = 32'h0;
        ControlRedirectUseFallthrough = 1'b0;
        ControlInterruptDeferred = 1'b0;
        IFIDValid = 1'b0;
        IDEXValid = 1'b0;
        EXMEMValid = 1'b0;
        MEMWBValid = 1'b0;
        TraceValid = 1'b0;
        MachineExternalInterruptActive = 1'b0;
        MachineTimerInterruptActive = 1'b0;

        IFIDPredTaken = 1'b0;
        IDEXPredTaken = 1'b0;
        IFIDPredPC = 32'h0;
        IDEXPredPC = 32'h0;

        GPIOOutput = 32'd0;
        UARTTxData = 8'h00;
        UARTTxValid = 1'b0;
        DebugStatus = 32'h0;

        for (i = 0; i < 32; i = i + 1) begin
            Regs[i] = i;
        end

        for (i = 0; i < INTERNAL_IMEM_WORD_COUNT; i = i + 1) begin
            IMemory[i] = NOP;
        end

        for (i = 0; i < INTERNAL_DMEM_WORD_COUNT; i = i + 1) begin
            DMemory[i] = 32'h0;
        end

        if (!USE_EXTERNAL_IMEM &&
            (INIT_PROGRAM_HEX != "") &&
            (EFFECTIVE_INIT_PROGRAM_WORD_COUNT > 0)) begin
            $readmemh(
                INIT_PROGRAM_HEX,
                IMemory,
                0,
                EFFECTIVE_INIT_PROGRAM_WORD_COUNT - 1
            );
        end
    end

    // ================================
    // Sequential state updates
    // ================================
    // This sequential block is the commit point for pipeline registers,
    // visible MMIO side effects, debug status, and retired-trace reporting.
    always @(posedge clock) begin
        if (reset) begin
            PC <= 0;
            IFIDIR <= NOP;
            IDEXIR <= NOP;
            EXMEMIR <= NOP;
            MEMWBIR <= NOP;
            IFIDValid <= 1'b0;
            IDEXValid <= 1'b0;
            EXMEMValid <= 1'b0;
            MEMWBValid <= 1'b0;
            TraceValid <= 1'b0;
            MachineExternalInterruptActive <= 1'b0;
            MachineTimerInterruptActive <= 1'b0;
            IFIDPC <= 0;
            IDEXPC <= 0;
            EXMEMPC <= 0;
            MEMWBPC <= 0;
            IDEXA <= 0;
            IDEXB <= 0;
            EXMEMB <= 0;
            EXMEMALUOut <= 0;
            EXMEMPCPlus4 <= 0;
            MEMWBValue <= 0;
            EXMEMForwardRegWrite <= 1'b0;
            EXMEMWritebackRegWrite <= 1'b0;
            EXMEMForwardRd <= 5'd0;
            EXMEMForwardUsePCPlus4 <= 1'b0;
            MEMWBForwardRegWrite <= 1'b0;
            MEMWBForwardRd <= 5'd0;
            ControlRedirectPending <= 1'b0;
            ControlRedirectPendingPrev <= 1'b0;
            ControlResolutionWasBranch <= 1'b0;
            ControlRedirectTargetPC <= 32'h0;
            ControlRedirectFallthroughPC <= 32'h0;
            ControlRedirectUseFallthrough <= 1'b0;
            ControlInterruptDeferred <= 1'b0;
            ControlAlignmentCheckPending <= 1'b0;
            InstructionMisalignCancel <= 1'b0;
            InstructionMisalignUseFallthrough <= 1'b0;
            InstructionMisalignPC <= 32'h0;
            InstructionMisalignTarget <= 32'h0;
            RV32MInFlight <= 1'b0;
            RV32MResultReady <= 1'b0;

            IFIDPredTaken <= 1'b0;
            IDEXPredTaken <= 1'b0;
            IFIDPredPC <= 32'h0;
            IDEXPredPC <= 32'h0;

            MatvecDonePrev <= 1'b0;
            GPIOOutput <= 32'd0;
            UARTTxData <= 8'h00;
            UARTTxValid <= 1'b0;
            DebugStatus <= 32'h0;

            for (i = 0; i < 32; i = i + 1) begin
                Regs[i] <= i;
            end

        end else begin

            // Hold the queued byte until the UART accepts it. A following store
            // stalls while this slot is occupied, including the acceptance edge.
            if (UARTTxValid && uart_tx_ready) UARTTxValid <= 1'b0;

            TraceValid <= 1'b0;
            MatvecDonePrev <= matvec_done;

            // Capture the next recovery candidates whenever the current registered
            // event bank is free. ControlRedirectPending alone holds accepted
            // payload through backpressure, so cache/trap logic does not drive the
            // wide payload clock enables.
            ControlRedirectPendingPrev <= ControlRedirectPending;
            ControlResolutionWasBranch <= IDEXBranch;
            if (!ControlRedirectPending) begin
                ControlRedirectTargetPC <= IDEXJump ? jump_target : branch_target;
                ControlRedirectFallthroughPC <= IDEXPC + 32'd4;
                ControlRedirectUseFallthrough <= IDEXBranch && !branch_taken;
            end

            if (InstructionMisalignPending) begin
                ControlRedirectPending <= 1'b0;
            end else if (control_redirect_apply) begin
                ControlRedirectPending <= 1'b0;
            end else if (control_mispredict_accept) begin
                ControlRedirectPending <= 1'b1;
            end

            // Capture the execute-stage payload on every advancing edge, even
            // while a check is pending, so a control transfer that follows
            // another one on the next cycle checks its own target. A D-cache
            // hold keeps the payload of the check that is still waiting.
            if (!ControlAlignmentCheckPending || !dcache_pipeline_stall) begin
                InstructionMisalignPC <= IDEXPC;
                InstructionMisalignTarget <= control_target_address;
                InstructionMisalignUseFallthrough <= IDEXBranch && !branch_taken;
            end
            // An older EX/MEM access fault can coincide with a younger misaligned
            // control transfer. Register that cancellation so the memory-fault
            // comparator does not feed the pending-event D cone.
            InstructionMisalignCancel <= memory_access_fault_taken;
            if (!dcache_pipeline_stall) begin
                // The alignment check is a one-cycle event. A D-cache hold retains
                // it; every advancing cycle replaces it with shallow control
                // acceptance for the current instruction.
                ControlAlignmentCheckPending <= control_alignment_capture;
            end

            // A pending interrupt does not preempt unresolved control flow. Once
            // that instruction resolves, this flop permits interrupt entry at the
            // next correct-path instruction boundary, including a self-loop branch.
            if (interrupt_taken || exception_taken || !machine_interrupt_pending) begin
                ControlInterruptDeferred <= 1'b0;
            end else if (control_resolution_accept && machine_interrupt_pending) begin
                ControlInterruptDeferred <= 1'b1;
            end

            // Trap/redirect acceptance owns squash priority. The iterative unit
            // may finish discarded work in the background, but only a completion
            // still owned by RV32MInFlight can become an architectural result.
            if (rv32m_squash) begin
                RV32MInFlight <= 1'b0;
                RV32MResultReady <= 1'b0;
            end else begin
                if (rv32m_start) begin
                    RV32MInFlight <= 1'b1;
                end
                if (rv32m_unit_done && RV32MInFlight) begin
                    RV32MInFlight <= 1'b0;
                    RV32MResultReady <= 1'b1;
                end
                if (rv32m_release) begin
                    RV32MResultReady <= 1'b0;
                end
            end

            // Track the active interrupt class until mret so a still-pending
            // source does not immediately retrigger the same handler.
            if (interrupt_taken) begin
                if (machine_external_interrupt_pending) begin
                    MachineExternalInterruptActive <= 1'b1;
                end else begin
                    MachineTimerInterruptActive <= 1'b1;
                end
            end else if (architectural_mret_taken) begin
                MachineExternalInterruptActive <= 1'b0;
                MachineTimerInterruptActive <= 1'b0;
            end

            // Internal-memory mode writes dirty D-cache evictions back into the
            // local DMemory array; external-memory mode emits the same line on
            // the top-level data-memory bus instead.
            if (dcache_internal_writeback_valid) begin
                for (writeback_word = 0; writeback_word < 4; writeback_word = writeback_word + 1) begin
                    if (((dcache_internal_writeback_addr >> 2) + writeback_word) < INTERNAL_DMEM_WORD_COUNT)
                        DMemory[(dcache_internal_writeback_addr >> 2) + writeback_word] <=
                            dcache_internal_writeback_line[writeback_word * 32 +: 32];
                end
            end

            if (!ENABLE_DCACHE &&
                !USE_EXTERNAL_DMEM &&
                cache_hit &&
                EXMEMStoreValid &&
                ((EXMEMALUOut >> 2) < INTERNAL_DMEM_WORD_COUNT)) begin
                DMemory[EXMEMALUOut >> 2] <= direct_dmem_store_merged_value;
            end

            // DMA writes update the backing DMemory bytes directly in internal
            // memory mode; the D-cache snoop path handles any resident cached word.
            if (!USE_EXTERNAL_DMEM &&
                matvec_dma_dmem_write &&
                matvec_dma_dmem_ready) begin
                for (dma_byte = 0; dma_byte < 16; dma_byte = dma_byte + 1) begin
                    if (matvec_dma_dmem_byte_enable[dma_byte] &&
                        (((matvec_dma_dmem_addr >> 2) + dma_byte / 4) < INTERNAL_DMEM_WORD_COUNT))
                        DMemory[(matvec_dma_dmem_addr >> 2) + dma_byte / 4][(dma_byte % 4) * 8 +: 8] <=
                            matvec_dma_dmem_wdata[dma_byte * 8 +: 8];
                end
            end

            if (debug_status_store_commit) begin
                DebugStatus <= debug_status_store_merged_value;
            end

            // ----------------
            // IF stage
            // ----------------
            PC <= pc_next_value;
            if (!if_hold) begin
                // Payload capture is independent of redirect/trap decisions.
                // IFIDValid alone marks a redirect-cycle capture as a bubble.
                IFIDIR <= IFInstruction;
                IFIDPC <= PC;
                IFIDPredTaken <= final_predict_taken;
                IFIDPredPC    <= final_predicted_pc;

                if (if_redirect) begin
                    IFIDValid <= 1'b0;
                end else if (if_advance) begin
                    IFIDValid <= 1'b1;
                end
            end

            // ----------------
            // ID stage
            // ----------------
            if (id_payload_hold) begin
                // A held operand still accepts a completing WB bypass. Other
                // operands and prediction payload retain their registered values.
                if (MEMWBRegWrite && (MEMWBForwardRd == IDEXrs1)) begin
                    IDEXA <= MEMWBValue;
                end
                if (MEMWBRegWrite && (MEMWBForwardRd == IDEXrs2)) begin
                    IDEXB <= MEMWBValue;
                end
            end else begin
                if (MEMWBRegWrite && (MEMWBForwardRd == IFIDrs1)) begin
                    IDEXA <= MEMWBValue;
                end else begin
                    IDEXA <= Regs[IFIDrs1];
                end

                if (MEMWBRegWrite && (MEMWBForwardRd == IFIDrs2)) begin
                    IDEXB <= MEMWBValue;
                end else begin
                    IDEXB <= Regs[IFIDrs2];
                end

                IDEXIR <= IFIDIR;
                IDEXPC <= IFIDPC;
                IDEXPredTaken <= IFIDPredTaken;
                IDEXPredPC    <= IFIDPredPC;
            end

            // Validity alone distinguishes an injected bubble from the captured
            // payload. A real hold preserves the live transaction; every bubble
            // kills it without clearing or clock-enabling the payload registers.
            if (id_bubble) begin
                IDEXValid <= 1'b0;
            end else if (id_advance) begin
                IDEXValid <= IFIDValid;
            end else if (id_hold) begin
                IDEXValid <= IDEXValid;
            end

            // ----------------
            // EX stage
            // ----------------
            if (ex_hold) begin
                EXMEMIR      <= EXMEMIR;
                EXMEMPC      <= EXMEMPC;
                EXMEMValid   <= EXMEMValid;
                EXMEMB       <= EXMEMB;
                EXMEMALUOut  <= EXMEMALUOut;
                EXMEMPCPlus4 <= EXMEMPCPlus4;
                EXMEMForwardRegWrite <= EXMEMForwardRegWrite;
                EXMEMWritebackRegWrite <= EXMEMWritebackRegWrite;
                EXMEMForwardRd <= EXMEMForwardRd;
                EXMEMForwardUsePCPlus4 <= EXMEMForwardUsePCPlus4;

            end else if (ex_advance) begin
                // Invalid bubbles may carry arbitrary payload. Capture payload on
                // every advancing cycle so exception/redirect decisions control
                // only validity and write metadata, not wide-register enables.
                EXMEMIR      <= IDEXIR;
                EXMEMPC      <= IDEXPC;
                EXMEMB       <= Bin;
                EXMEMALUOut  <= execute_result;
                EXMEMPCPlus4 <= IDEXPC + 4;

                if (rv32m_execute_stall) begin
                    // Older EX/MEM work drains while the M instruction remains in
                    // ID/EX. EXMEMValid is the sole bubble authority; payload and
                    // write metadata remain don't-care while invalid.
                    EXMEMValid <= 1'b0;
                end else if (exception_taken ||
                             interrupt_taken ||
                             control_redirect_apply) begin
                    // Trap-taking instructions update CSR state through csr_unit;
                    // registered control recovery likewise bubbles the younger
                    // wrong-path ID/EX instruction before side effects can commit.
                    // EXMEMValid alone authorizes interpretation of the captured
                    // payload and write metadata, so they need no runtime clear.
                    EXMEMValid <= 1'b0;
                end

                if (!rv32m_execute_stall &&
                    !exception_taken &&
                    !interrupt_taken &&
                    !control_redirect_apply) begin
                    EXMEMValid   <= IDEXValid;
                    EXMEMForwardRegWrite <= IDEXWritesRegister && !IDEXMemRead;
                    EXMEMWritebackRegWrite <= IDEXWritesRegister;
                    EXMEMForwardRd <= IDEXrd;
                    EXMEMForwardUsePCPlus4 <= IDEXJump;
                end
            end

            // ----------------
            // MEM stage
            // ----------------
            if (EXMEMALUResult) begin
                MEMWBValue <= EXMEMALUOut;
            end else if (EXMEMMmioAccess) begin

                if (EXMEMLoadValid) begin
                    MEMWBValue <= mmio_load_value;
                end else if (EXMEMValid && EXMEMGpioOutputAccess) begin
                    GPIOOutput <= gpio_store_merged_value;
                end else if (EXMEMStoreValid && EXMEMUartTxDataAccess && uart_tx_ready && !UARTTxValid) begin
                    UARTTxData <= StoreData[7:0];
                    UARTTxValid <= 1'b1;
                end

            end else if (EXMEMMemAccess) begin

                if (dcache_load_word_valid) begin
                    MEMWBValue <= dcache_load_value;
                end

            end else if (EXMEMJump) begin
                MEMWBValue <= EXMEMPCPlus4;
            end

            if (memwb_update) begin
                // The trace port reports retired memory-stage events after stalls
                // and cache misses have resolved, keeping wrong-path rows out of
                // the public retired trace stream.
                MEMWBIR <= EXMEMIR;
                MEMWBPC <= EXMEMPC;
                MEMWBValid <= memwb_input_valid;
                MEMWBForwardRegWrite <= EXMEMWritebackRegWrite && memwb_input_valid;
                MEMWBForwardRd <= EXMEMForwardRd;
                TraceValid <= retire_event;
            end

            // ----------------
            // WB stage
            // ----------------
            if (MEMWBRegWrite) begin
                Regs[MEMWBForwardRd] <= MEMWBValue;
            end

            Regs[0] <= 0;
        end
    end
endmodule
