<#
Script: scripts\run.ps1
Purpose: Compiles and runs named Icarus Verilog regression tests from the test manifest.
Common usage:
  powershell -ExecutionPolicy Bypass -File scripts\run.ps1 -Test <name>
Outputs:
  Simulation executables, VCD waveforms, and optional regression summary JSON under wave\.
Scope:
  Directed simulation evidence only; not timing closure, physical board validation, official RISC-V compliance, or benchmark proof.
Audience:
  Public entrypoint.
#>
param(
    [ValidateNotNullOrEmpty()]
    [string]$Test = "all",
    [switch]$OpenWave,
    [switch]$SkipAssemble,
    [string]$SummaryJson = "",
    [string]$PlusArgs = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. "$PSScriptRoot\verification-source-identity.ps1"

if (-not $SkipAssemble) {
    & (Join-Path $PSScriptRoot "assemble.ps1")
}

New-Item -ItemType Directory -Force -Path "wave" | Out-Null

$testSources = [ordered]@{
    main = "tb/unit/core/tb_main.v"
    alu = "tb/unit/core/tb_alu.v"
    memory = "tb/unit/core/tb_memory.v"
    assert_x0 = "tb/assertions/tb_assert_x0.v"
    assert_flush = "tb/assertions/tb_assert_flush.v"
    assert_reset = "tb/assertions/tb_assert_reset.v"
    csr_unit = "tb/unit/core/tb_csr_unit.v"
    exception_decode_unit = "tb/unit/core/tb_exception_decode_unit.v"
    performance_counter_unit = "tb/unit/core/tb_performance_counter_unit.v"
    rv32m_multicycle_unit = "tb/unit/core/tb_rv32m_multicycle_unit.v"
    forwarding_unit = "tb/unit/core/tb_forwarding_unit.v"
    assert_forwarded_alignment_equivalence = "tb/assertions/tb_assert_forwarded_alignment_equivalence.v"
    branch_jump_unit = "tb/unit/core/tb_branch_jump_unit.v"
    load_store_format_unit = "tb/unit/memory/tb_load_store_format_unit.v"
    pipeline_control_unit = "tb/unit/core/tb_pipeline_control_unit.v"
    ras_unit = "tb/unit/core/tb_ras_unit.v"
    icache_unit = "tb/unit/memory/tb_icache_unit.v"
    dcache_unit = "tb/unit/memory/tb_dcache_unit.v"
    assert_trap = "tb/assertions/tb_assert_trap.v"
    assert_trap_side_effect_flush = "tb/assertions/tb_assert_trap_side_effect_flush.v"
    assert_exception_branch_priority = "tb/assertions/tb_assert_exception_branch_priority.v"
    assert_illegal_csr = "tb/assertions/tb_assert_illegal_csr.v"
    assert_mret_redirect = "tb/assertions/tb_assert_mret_redirect.v"
    assert_mret_side_effect_flush = "tb/assertions/tb_assert_mret_side_effect_flush.v"
    assert_interrupt_mstatus_gating = "tb/assertions/tb_assert_interrupt_mstatus_gating.v"
    assert_precise_exception_commit = "tb/assertions/tb_assert_precise_exception_commit.v"
    assert_control_transfer_legality_alignment = "tb/assertions/tb_assert_control_transfer_legality_alignment.v"
    assert_interrupt_priority_mstatus = "tb/assertions/tb_assert_interrupt_priority_mstatus.v"
    assert_trap_redirect_factoring = "tb/assertions/tb_assert_trap_redirect_factoring.v"
    assert_interrupt_dcache_stall_release = "tb/assertions/tb_assert_interrupt_dcache_stall_release.v"
    assert_execute_acceptance_dcache_stall = "tb/assertions/tb_assert_execute_acceptance_dcache_stall.v"
    assert_registered_trap_metadata_commit = "tb/assertions/tb_assert_registered_trap_metadata_commit.v"
    assert_rv32m_multicycle_pipeline = "tb/assertions/tb_assert_rv32m_multicycle_pipeline.v"
    assert_rv32m_trap_squash = "tb/assertions/tb_assert_rv32m_trap_squash.v"
    assert_registered_control_redirect = "tb/assertions/tb_assert_registered_control_redirect.v"
    assert_registered_branch_miss_event = "tb/assertions/tb_assert_registered_branch_miss_event.v"
    assert_registered_timer_pending = "tb/assertions/tb_assert_registered_timer_pending.v"
    assert_exmem_invalid_side_effect_isolation = "tb/assertions/tb_assert_exmem_invalid_side_effect_isolation.v"
    assert_idex_invalid_side_effect_isolation = "tb/assertions/tb_assert_idex_invalid_side_effect_isolation.v"
    assert_jump_flush = "tb/assertions/tb_assert_jump_flush.v"
    assert_jump_side_effect_flush = "tb/assertions/tb_assert_jump_side_effect_flush.v"
    assert_jalr_flush = "tb/assertions/tb_assert_jalr_flush.v"
    assert_jalr_side_effect_flush = "tb/assertions/tb_assert_jalr_side_effect_flush.v"
    assert_store_flush = "tb/assertions/tb_assert_store_flush.v"
    assert_mmio_flush = "tb/assertions/tb_assert_mmio_flush.v"
    assert_branch_mispredict_dcache_stall = "tb/assertions/tb_assert_branch_mispredict_dcache_stall.v"
    assert_matvec_scratchpad_flush = "tb/assertions/tb_assert_matvec_scratchpad_flush.v"
    assert_matvec_scratchpad_interrupt_flush = "tb/assertions/tb_assert_matvec_scratchpad_interrupt_flush.v"
    assert_matvec_dma_arbitration = "tb/assertions/tb_assert_matvec_dma_arbitration.v"
    assert_matvec_dma_descriptor_overlap = "tb/assertions/tb_assert_matvec_dma_descriptor_overlap.v"
    assert_timer_interrupt_flush = "tb/assertions/tb_assert_timer_interrupt_flush.v"
    external_imem = "tb/integration/external_memory/tb_external_imem.v"
    external_dmem_bram_sync = "tb/unit/memory/tb_external_dmem_bram_sync.v"
    external_dmem = "tb/integration/external_memory/tb_external_dmem.v"
    external_dmem_debug_status = "tb/integration/external_memory/tb_external_dmem_debug_status.v"
    external_dmem_matvec_dma = "tb/integration/external_memory/tb_external_dmem_matvec_dma.v"
    gpio_mmio = "tb/unit/peripherals/tb_gpio_mmio.v"
    mmio_decode = "tb/unit/peripherals/tb_mmio_decode.v"
    mmio_read_mux = "tb/unit/soc/tb_mmio_read_mux.v"
    int8_matvec_scratchpad_accelerator = "tb/unit/accelerators/tb_int8_matvec_scratchpad_accelerator.v"
    int8_matvec_dma_lite = "tb/unit/accelerators/tb_int8_matvec_dma_lite.v"
    machine_timer = "tb/unit/peripherals/tb_machine_timer.v"
    timer_mmio = "tb/unit/peripherals/tb_timer_mmio.v"
    matvec_perf_counters = "tb/unit/accelerators/tb_matvec_perf_counters.v"
    uart_mmio = "tb/unit/peripherals/tb_uart_mmio.v"
    uart_tx = "tb/unit/peripherals/tb_uart_tx.v"
    uart_rx = "tb/unit/peripherals/tb_uart_rx.v"
    uart_rx_mmio_buffer = "tb/unit/peripherals/tb_uart_rx_mmio_buffer.v"
    boot_reset_controller = "tb/unit/boot/tb_boot_reset_controller.v"
    uart_packet_boot_imem = "tb/integration/boot/tb_uart_packet_boot_imem.v"
    uart_packet_boot_reject = "tb/integration/boot/tb_uart_packet_boot_reject.v"
    branch = "tb/unit/core/tb_branch.v"
    branch_prediction = "tb/unit/core/tb_branch_prediction.v"
    branch_predictor_update_pipeline = "tb/unit/core/tb_branch_predictor_update_pipeline.v"
    jal_btb_prediction = "tb/unit/core/tb_jal_btb_prediction.v"
    branch_predictor_warm_recovery = "tb/unit/core/tb_branch_predictor_warm_recovery.v"
    branch_predictor_recovery = "tb/unit/core/tb_branch_predictor_recovery.v"
    jump_ras = "tb/unit/core/tb_jump_ras.v"
    ras_flush = "tb/unit/core/tb_ras_flush.v"
    ras_immediate_return = "tb/unit/core/tb_ras_immediate_return.v"
    load_use_decode = "tb/unit/core/tb_load_use_decode.v"
    cache = "tb/unit/core/tb_cache.v"
    trace = "tb/reference/tb_trace.v"
    trace_reference = "tb/reference/tb_trace_reference.v"
    trace_trap_reference = "tb/reference/tb_trace_trap_reference.v"
    trace_lockstep_reference = "tb/reference/tb_trace_lockstep_reference.v"
    pipeline_invariants = "tb/assertions/tb_pipeline_invariants.v"
    perf_counters = "tb/unit/core/tb_perf_counters.v"
    random_reference = "tb/reference/tb_random_reference.v"
    random_memory_reference = "tb/reference/tb_random_memory_reference.v"
    random_control_reference = "tb/reference/tb_random_control_reference.v"
    random_hazard_reference = "tb/reference/tb_random_hazard_reference.v"
    random_call_reference = "tb/reference/tb_random_call_reference.v"
    program = "tb/program/examples/tb_program.v"
    program_call = "tb/program/examples/tb_program_call.v"
    program_nested = "tb/program/examples/tb_program_nested.v"
    program_stack = "tb/program/examples/tb_program_stack.v"
    program_memory = "tb/program/isa/tb_program_memory.v"
    program_upper = "tb/program/isa/tb_program_upper.v"
    program_alu = "tb/program/isa/tb_program_alu.v"
    program_muldiv = "tb/program/isa/tb_program_muldiv.v"
    program_csr_trap = "tb/program/csr_trap/tb_program_csr_trap.v"
    program_mret_trap = "tb/program/csr_trap/tb_program_mret_trap.v"
    program_mstatus_trap_return = "tb/program/csr_trap/tb_program_mstatus_trap_return.v"
    program_privileged_csr_edges = "tb/program/csr_trap/tb_program_privileged_csr_edges.v"
    program_exception_mcause_mtval = "tb/program/csr_trap/tb_program_exception_mcause_mtval.v"
    program_misaligned_exception = "tb/program/csr_trap/tb_program_misaligned_exception.v"
    program_abi = "tb/program/examples/tb_program_abi.v"
    program_li = "tb/program/examples/tb_program_li.v"
    program_address = "tb/program/examples/tb_program_address.v"
    program_pointer = "tb/program/examples/tb_program_pointer.v"
    program_array = "tb/program/examples/tb_program_array.v"
    program_byte_array = "tb/program/examples/tb_program_byte_array.v"
    program_halfword_array = "tb/program/examples/tb_program_halfword_array.v"
    program_sum_function = "tb/program/examples/tb_program_sum_function.v"
    program_nested_sum = "tb/program/examples/tb_program_nested_sum.v"
    program_byte_directive = "tb/program/examples/tb_program_byte_directive.v"
    program_half_directive = "tb/program/examples/tb_program_half_directive.v"
    program_string = "tb/program/examples/tb_program_string.v"
    program_strlen = "tb/program/examples/tb_program_strlen.v"
    program_strcmp = "tb/program/examples/tb_program_strcmp.v"
    program_string_escape = "tb/program/examples/tb_program_string_escape.v"
    program_count_char = "tb/program/examples/tb_program_count_char.v"
    program_counter_loop = "tb/program/examples/tb_program_counter_loop.v"
    program_perf_mmio_read = "tb/program/soc_io/tb_program_perf_mmio_read.v"
    program_uart_gpio_demo = "tb/program/soc_io/tb_program_uart_gpio_demo.v"
    program_showcase_demo = "tb/program/showcase/tb_program_showcase_demo.v"
    program_interactive_showcase_demo = "tb/program/showcase/tb_program_interactive_showcase_demo.v"
    program_hardware_validation_suite = "tb/program/showcase/tb_program_hardware_validation_suite.v"
    program_matvec_scratchpad = "tb/program/accelerator/tb_program_matvec_scratchpad.v"
    program_matvec_scratchpad_interrupt = "tb/program/accelerator/tb_program_matvec_scratchpad_interrupt.v"
    program_matvec_scratchpad_no_interrupt = "tb/program/accelerator/tb_program_matvec_scratchpad_no_interrupt.v"
    program_matvec_dma_demo = "tb/program/accelerator/tb_program_matvec_dma_demo.v"
    program_machine_timer_interrupt = "tb/program/csr_trap/tb_program_machine_timer_interrupt.v"
    program_machine_timer_no_interrupt = "tb/program/csr_trap/tb_program_machine_timer_no_interrupt.v"
    program_compliance_basic = "tb/program/isa/tb_program_compliance_basic.v"
    program_rv32i_alu_compliance = "tb/program/isa/tb_program_rv32i_alu_compliance.v"
    program_rv32i_control_compliance = "tb/program/isa/tb_program_rv32i_control_compliance.v"
    program_rv32i_memory_compliance = "tb/program/isa/tb_program_rv32i_memory_compliance.v"
    program_rv32m_compliance = "tb/program/isa/tb_program_rv32m_compliance.v"
    program_board_smoke = "tb/program/showcase/tb_program_board_smoke.v"
    fpga_top_board_smoke = "tb/integration/fpga/tb_fpga_top_board_smoke.v"
    basys3_board_smoke_top = "tb/integration/fpga/tb_basys3_board_smoke_top.v"
    basys3_full_lowfreq_top = "tb/integration/fpga/tb_basys3_full_lowfreq_top.v"
    fpga_top_program_override = "tb/integration/fpga/tb_fpga_top_program_override.v"
    fpga_top_reset_sync = "tb/integration/fpga/tb_fpga_top_reset_sync.v"
    fpga_top_reset_active_low = "tb/integration/fpga/tb_fpga_top_reset_active_low.v"
    fpga_top_leds_active_low = "tb/integration/fpga/tb_fpga_top_leds_active_low.v"
    fpga_top_done = "tb/integration/fpga/tb_fpga_top_done.v"
    fpga_top_smoke_pass = "tb/integration/fpga/tb_fpga_top_smoke_pass.v"
    fpga_top_smoke_fail = "tb/integration/fpga/tb_fpga_top_smoke_fail.v"
    fpga_top_debug_flags = "tb/integration/fpga/tb_fpga_top_debug_flags.v"
    fpga_top_leds_debug_flags = "tb/integration/fpga/tb_fpga_top_leds_debug_flags.v"
    fpga_top_memory_size = "tb/integration/fpga/tb_fpga_top_memory_size.v"
    fpga_top_heartbeat = "tb/integration/fpga/tb_fpga_top_heartbeat.v"
    fpga_top_config_error = "tb/integration/fpga/tb_fpga_top_config_error.v"
    fpga_top_uart_tx = "tb/integration/fpga/tb_fpga_top_uart_tx.v"
    fpga_uart_boot_top = "tb/integration/fpga/tb_fpga_uart_boot_top.v"
    fpga_uart_boot_showcase = "tb/integration/fpga/tb_fpga_uart_boot_showcase.v"
    fpga_uart_boot_bram_soc_showcase = "tb/integration/fpga/tb_fpga_uart_boot_bram_soc_showcase.v"
    fpga_uart_boot_runtime_rx_showcase = "tb/integration/fpga/tb_fpga_uart_boot_runtime_rx_showcase.v"
    fpga_uart_boot_hardware_validation_suite = "tb/integration/fpga/tb_fpga_uart_boot_hardware_validation_suite.v"
    fpga_debug_led_top = "tb/integration/fpga/tb_fpga_debug_led_top.v"
}

function Get-WaveformPath {
    param([string]$Name)

    if ($Name -eq "main") {
        return "wave/dump.vcd"
    }

    return "wave/tb_$Name.vcd"
}

function Write-SummaryJson {
    if ($SummaryJson -eq "") {
        return
    }

    $summaryPath = if ([System.IO.Path]::IsPathRooted($SummaryJson)) {
        $SummaryJson
    } else {
        Join-Path $repoRoot $SummaryJson
    }

    $summaryDirectory = Split-Path -Parent $summaryPath
    if ($summaryDirectory -ne "") {
        New-Item -ItemType Directory -Force -Path $summaryDirectory | Out-Null
    }

    $summary = [ordered]@{
        requested_test = $Test
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        total = $results.Count
        passed = @($results | Where-Object { $_.status -eq "passed" }).Count
        failed = @($results | Where-Object { $_.status -ne "passed" }).Count
        tests = $results
    }
    Add-VerificationIdentityFields -Summary $summary | Out-Null

    $summary | ConvertTo-Json -Depth 4 | Set-Content -Path $summaryPath -Encoding Ascii
    Write-Host "Regression summary written to $summaryPath"
}

if ($Test -ne "all" -and -not $testSources.Contains($Test)) {
    throw "Unknown test '$Test'. Choose 'all' or a name from the run.ps1 test manifest."
}

if ($Test -eq "all") {
    $tests = @($testSources.Keys)
} else {
    $tests = @($Test)
}

$results = @()

foreach ($name in $tests) {
    Write-Host "========================================"
    Write-Host "Running test: $name"

    $simulation = "wave/$name.vvp"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    iverilog -g2012 -Wall -I tb/common -o $simulation -f rtl/rtl_sources.f $testSources[$name]

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Compile failed: $name"
        $stopwatch.Stop()
        $results += [pscustomobject]@{
            name = $name
            source = $testSources[$name]
            waveform = Get-WaveformPath $name
            status = "compile_failed"
            duration_ms = $stopwatch.ElapsedMilliseconds
        }
        Write-SummaryJson
        exit $LASTEXITCODE
    }

    $vvpArgs = @($simulation)
    if (-not [string]::IsNullOrWhiteSpace($PlusArgs)) {
        $vvpArgs += @($PlusArgs -split '\s+')
    }
    vvp @vvpArgs

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Simulation failed: $name"
        $stopwatch.Stop()
        $results += [pscustomobject]@{
            name = $name
            source = $testSources[$name]
            waveform = Get-WaveformPath $name
            status = "simulation_failed"
            duration_ms = $stopwatch.ElapsedMilliseconds
        }
        Write-SummaryJson
        exit $LASTEXITCODE
    }

    $stopwatch.Stop()
    $results += [pscustomobject]@{
        name = $name
        source = $testSources[$name]
        waveform = Get-WaveformPath $name
        status = "passed"
        duration_ms = $stopwatch.ElapsedMilliseconds
    }
}

Write-Host "========================================"
Write-Host "PASS: requested CPU regression tests passed"
Write-SummaryJson

if ($OpenWave -and ($Test -eq "all")) {
    Write-Host "Use -Test <name> -OpenWave to open one test waveform."
} elseif ($OpenWave -and (Get-Command gtkwave -ErrorAction SilentlyContinue)) {
    gtkwave (Get-WaveformPath $Test) wave/pipeline.gtkw
} elseif ($OpenWave) {
    Write-Host "GTKWave is not installed or not in PATH. Open $(Get-WaveformPath $Test) manually after installing GTKWave."
} elseif ($Test -ne "all") {
    Write-Host "Waveform written to $(Get-WaveformPath $Test). Re-run with -OpenWave to launch GTKWave."
}
