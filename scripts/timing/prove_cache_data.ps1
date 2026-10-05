# Reproduce the valid cache-data selection equivalence experiment.
param([string]$Repo = (Resolve-Path "$PSScriptRoot/../..").Path)
$ErrorActionPreference = 'Stop'
Set-Location $Repo
New-Item -ItemType Directory -Force -Path 'build', 'results/timing/refill_data_select' | Out-Null
$rtl = Get-Content rtl/memory/cache/dcache_unit.v -Raw
$assignments = foreach ($name in @('hit','refill_ready','load_word_data','load_word_valid')) {
    $match = [regex]::Match($rtl, "(?s)    assign $name\s*=.*?;")
    if (-not $match.Success) { throw "Missing source assignment: $name" }
    $match.Value
}
$header = @'
module cache_data_equivalence;
    localparam CACHE_IDLE = 2'b00, CACHE_REFILL = 2'b11;
    (* anyconst *) reg [1:0] cache_state;
    (* anyconst *) reg USE_EXTERNAL_DMEM, external_ready, selected_line_hit;
    (* anyconst *) reg request_valid, request_mmio, request_read;
    (* anyconst *) reg pending_read_valid, pending_store_valid;
    (* anyconst *) reg [31:0] hit_word_data, refill_selected_word;
    wire hit, refill_ready, load_word_valid;
    wire [31:0] load_word_data;
'@
$footer = @'
    wire [31:0] previous_payload = hit ? hit_word_data : refill_selected_word;
    always @* begin
        if (load_word_valid) assert(load_word_data == previous_payload);
    end
endmodule
'@
$output='build/cache_data_equivalence.sv'
[IO.File]::WriteAllText((Join-Path $Repo $output), ($header,($assignments -join "`n"),$footer) -join "`n")
& yosys -Q -T -q -l results/timing/refill_data_select/data-equivalence.log -p "read_verilog -formal $output; prep -top cache_data_equivalence -flatten; chformal -lower; sat -verify -prove-asserts"
if ($LASTEXITCODE -ne 0) { throw 'Cache data equivalence failed' }
Select-String -LiteralPath results/timing/refill_data_select/data-equivalence.log -SimpleMatch 'SAT proof finished'
