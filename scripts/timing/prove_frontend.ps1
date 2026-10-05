# Reproduce the redirect-control equivalence experiment.
param([string]$Repo = (Resolve-Path "$PSScriptRoot/../..").Path)
$ErrorActionPreference = 'Stop'
Set-Location $Repo
New-Item -ItemType Directory -Force -Path 'build', 'results/timing/redirect_request' | Out-Null
$core = Get-Content rtl/core/riscv_cpu_core.v -Raw
$names = @(
    'execute_instruction_accept', 'memory_access_fault_stall',
    'dcache_pipeline_stall', 'memory_access_fault_taken',
    'immediate_exception_pending', 'immediate_exception_taken',
    'instruction_misaligned_taken', 'exception_taken', 'exception_pending',
    'mret_taken', 'architectural_mret_taken', 'redirect_pc'
)
$assignments = foreach ($name in $names) {
    $match = [regex]::Match($core, "(?s)    assign $name\s*=.*?;")
    if (-not $match.Success) { throw "Missing source assignment: $name" }
    $match.Value
}
$pc = [regex]::Match($core, '(?s)    wire \[31:0\] pc_next_value\s*=.*?;')
if (-not $pc.Success) { throw 'Missing PC selection expression' }
$header = @'
module frontend_equivalence;
    (* anyconst *) reg ENABLE_CSR_TRAPS, IDEXValid, ControlRedirectPending;
    (* anyconst *) reg cache_busy, cache_miss, matvec_dma_cpu_memory_stall, uart_tx_pipeline_stall;
    (* anyconst *) reg rv32m_execute_stall, memory_access_fault_detect;
    (* anyconst *) reg instruction_access_fault, is_legal_instruction, is_ecall, is_ebreak, is_misaligned_access;
    (* anyconst *) reg InstructionMisalignPending, InstructionMisalignCancel, is_mret;
    (* anyconst *) reg reset, machine_interrupt_pending, ControlInterruptDeferred, IDEXBranch, IDEXJump, IDEXMExtension;
    (* anyconst *) reg icache_pipeline_stall, load_use_hazard;
    (* anyconst *) reg [31:0] CSRmtvec, CSRmepc, ControlRedirectPC, final_predicted_pc, PC;
    wire execute_instruction_accept, memory_access_fault_stall, dcache_pipeline_stall;
    wire memory_access_fault_taken, immediate_exception_pending, immediate_exception_taken;
    wire instruction_misaligned_taken, exception_taken, exception_pending, mret_taken, architectural_mret_taken;
    wire [31:0] redirect_pc;
    wire interrupt_eligible, interrupt_taken, redirect_taken;
    wire if_hold, if_redirect, if_advance, id_hold, id_bubble, id_advance, ex_hold, ex_advance;
    trap_redirect_control_unit redirects (
        .reset(reset), .instruction_valid(IDEXValid),
        .machine_interrupt_pending(machine_interrupt_pending),
        .control_redirect_pending(ControlRedirectPending),
        .control_interrupt_deferred(ControlInterruptDeferred),
        .instruction_is_control(IDEXBranch || IDEXJump),
        .instruction_is_m_extension(IDEXMExtension),
        .dcache_pipeline_stall(dcache_pipeline_stall),
        .exception_taken(exception_taken), .exception_pending(exception_pending), .mret_taken(mret_taken),
        .interrupt_eligible(interrupt_eligible), .interrupt_taken(interrupt_taken), .redirect_taken(redirect_taken)
    );
    pipeline_control_unit pipeline (
        .dcache_pipeline_stall(dcache_pipeline_stall), .redirect_taken(redirect_taken),
        .icache_pipeline_stall(icache_pipeline_stall), .load_use_hazard(load_use_hazard),
        .execute_busy_stall(rv32m_execute_stall),
        .if_hold(if_hold), .if_redirect(if_redirect), .if_advance(if_advance),
        .id_hold(id_hold), .id_bubble(id_bubble), .id_advance(id_advance),
        .ex_hold(ex_hold), .ex_advance(ex_advance)
    );
'@
$reference = @'
    wire old_exception =
        (memory_access_fault_detect && !memory_access_fault_stall) ||
        (ENABLE_CSR_TRAPS && IDEXValid && !ControlRedirectPending && !dcache_pipeline_stall &&
         !rv32m_execute_stall && !memory_access_fault_detect &&
         (instruction_access_fault || !is_legal_instruction || is_ecall || is_ebreak || is_misaligned_access)) ||
        (InstructionMisalignPending && !InstructionMisalignCancel && !dcache_pipeline_stall);
    wire old_mret = ENABLE_CSR_TRAPS && !ControlRedirectPending && !memory_access_fault_detect && IDEXValid && is_mret;
    wire old_eligible = !reset && IDEXValid && machine_interrupt_pending && !ControlRedirectPending &&
                        (!(IDEXBranch || IDEXJump) || ControlInterruptDeferred) && !IDEXMExtension;
    wire old_interrupt = old_eligible && !dcache_pipeline_stall && !old_exception && !old_mret;
    wire old_redirect = old_exception || old_mret || old_eligible || ControlRedirectPending;
    wire [31:0] old_target = old_exception ? CSRmtvec : old_interrupt ? CSRmtvec : old_mret ? CSRmepc : ControlRedirectPC;
    wire old_hold, old_if_redirect, old_advance, old_id_hold, old_id_bubble, old_id_advance, old_ex_hold, old_ex_advance;
    pipeline_control_unit reference_pipeline (
        .dcache_pipeline_stall(dcache_pipeline_stall), .redirect_taken(old_redirect),
        .icache_pipeline_stall(icache_pipeline_stall), .load_use_hazard(load_use_hazard),
        .execute_busy_stall(rv32m_execute_stall),
        .if_hold(old_hold), .if_redirect(old_if_redirect), .if_advance(old_advance),
        .id_hold(old_id_hold), .id_bubble(old_id_bubble), .id_advance(old_id_advance),
        .ex_hold(old_ex_hold), .ex_advance(old_ex_advance)
    );
    wire [31:0] old_pc = old_if_redirect ? old_target : old_advance ? final_predicted_pc : PC;
    always @* begin
        assert(exception_taken == old_exception);
        assert(architectural_mret_taken == (old_mret && !dcache_pipeline_stall));
        assert(interrupt_taken == old_interrupt);
        assert(pc_next_value == old_pc);
        assert({if_hold, if_redirect, if_advance, id_hold, id_bubble, id_advance, ex_hold, ex_advance} ==
               {old_hold, old_if_redirect, old_advance, old_id_hold, old_id_bubble, old_id_advance, old_ex_hold, old_ex_advance});
    end
endmodule
'@
$output = 'build/frontend_equivalence.sv'
[IO.File]::WriteAllText((Join-Path $Repo $output), ($header, ($assignments -join "`n"), $pc.Value, $reference) -join "`n")
& yosys -Q -T -q -l results/timing/redirect_request/frontend-equivalence.log -p "read_verilog -formal rtl/core/csr/trap_redirect_control_unit.v rtl/core/pipeline/pipeline_control_unit.v $output; prep -top frontend_equivalence -flatten; chformal -lower; sat -verify -prove-asserts"
if ($LASTEXITCODE -ne 0) { throw 'Frontend equivalence proof failed' }
Select-String -LiteralPath results/timing/redirect_request/frontend-equivalence.log -SimpleMatch 'SAT proof finished'
