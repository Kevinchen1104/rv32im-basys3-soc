# Non-project Vivado build for the Basys3-targeted CPU wrapper.

set PART "xc7a35tcpg236-1"
set TOP "RISCVCPU_basys3_top"
set OUT_DIR "build/vivado/basys3"
set REPO_ROOT ""
set RUN_SYNTH_ONLY 1
set RUN_IMPL 0
set GENERATE_BITSTREAM 0
set OPT_DIRECTIVE "ExploreWithRemap"
set PLACE_DIRECTIVE "Explore"
set PHYS_OPT_DIRECTIVE "Explore"
set ROUTE_DIRECTIVE "NoTimingRelaxation"
set TIMING_PERIOD_NS 10.0
set ARCHITECTURE_PROFILE "default"
set ICACHE_BYTES 64
set DCACHE_VICTIM_LINES 0
set DCACHE_BYTES 64
set ICACHE_PARALLEL_LOOKUP 1

if {[llength $argv] % 2 != 0} {
    error "Expected key/value Tcl arguments"
}
for {set i 0} {$i < [llength $argv]} {incr i} {
    set arg [lindex $argv $i]
    switch -- $arg {
        "-out_dir" {
            incr i
            set OUT_DIR [lindex $argv $i]
        }
        "-repo_root" {
            incr i
            set REPO_ROOT [lindex $argv $i]
        }
        "-top" {
            incr i
            set TOP [lindex $argv $i]
        }
        "-run_synth_only" {
            incr i
            set RUN_SYNTH_ONLY [lindex $argv $i]
        }
        "-run_impl" {
            incr i
            set RUN_IMPL [lindex $argv $i]
        }
        "-generate_bitstream" {
            incr i
            set GENERATE_BITSTREAM [lindex $argv $i]
        }
        "-opt_directive" {
            incr i
            set OPT_DIRECTIVE [lindex $argv $i]
        }
        "-place_directive" {
            incr i
            set PLACE_DIRECTIVE [lindex $argv $i]
        }
        "-phys_opt_directive" {
            incr i
            set PHYS_OPT_DIRECTIVE [lindex $argv $i]
        }
        "-route_directive" {
            incr i
            set ROUTE_DIRECTIVE [lindex $argv $i]
        }
        "-timing_period_ns" {
            incr i
            set TIMING_PERIOD_NS [lindex $argv $i]
        }
        "-architecture_profile" {
            incr i
            set ARCHITECTURE_PROFILE [lindex $argv $i]
        }
        "-icache_bytes" {
            incr i
            set ICACHE_BYTES [lindex $argv $i]
        }
        "-icache_parallel_lookup" {
            incr i
            set ICACHE_PARALLEL_LOOKUP [lindex $argv $i]
        }
        "-dcache_victim_lines" {
            incr i
            set DCACHE_VICTIM_LINES [lindex $argv $i]
        }
        "-dcache_bytes" {
            incr i
            set DCACHE_BYTES [lindex $argv $i]
        }
        default {
            error "Unknown argument: $arg"
        }
    }
}

if {![string is double -strict $TIMING_PERIOD_NS] ||
    !($TIMING_PERIOD_NS >= 1.0 && $TIMING_PERIOD_NS <= 100.0)} {
    error "timing_period_ns must be between 1 and 100 ns"
}
if {$TIMING_PERIOD_NS != 10.0 &&
    ($GENERATE_BITSTREAM || $TOP ne "RISCVCPU_basys3_top")} {
    error "Non-board clock periods are restricted to direct-clock timing experiments"
}

if {$GENERATE_BITSTREAM} {
    set RUN_IMPL 1
    set RUN_SYNTH_ONLY 0
}
if {$RUN_IMPL} {
    set RUN_SYNTH_ONLY 0
}

proc as_posix_path {path} {
    return [string map {"\\" "/"} $path]
}

proc safe_get_property {property object default_value} {
    if {[catch {get_property $property $object} value]} {
        return $default_value
    }
    if {$value eq ""} {
        return $default_value
    }
    return $value
}

proc write_clock_summary {path} {
    set fh [open $path w]
    puts $fh "name period_ns frequency_mhz generated source_pin"
    foreach clock_object [lsort [get_clocks]] {
        set name [get_property NAME $clock_object]
        set period [safe_get_property PERIOD $clock_object "unknown"]
        set frequency "unknown"
        if {$period ne "unknown" && $period > 0.0} {
            set frequency [format "%.6f" [expr {1000.0 / $period}]]
        }
        set generated [safe_get_property IS_GENERATED $clock_object "unknown"]
        set source_pin [safe_get_property SOURCE_PINS $clock_object "none"]
        puts $fh "$name $period $frequency $generated $source_pin"
    }
    close $fh
}

set SCRIPT_DIR [file dirname [as_posix_path [info script]]]
if {$REPO_ROOT eq ""} {
    set REPO_ROOT [file join $SCRIPT_DIR ".." ".."]
}
set REPO_ROOT [as_posix_path $REPO_ROOT]
set OUT_DIR [as_posix_path $OUT_DIR]
if {[file pathtype $OUT_DIR] eq "relative"} {
    set OUT_DIR [as_posix_path [file join $REPO_ROOT $OUT_DIR]]
}
set REPORT_DIR [file join $OUT_DIR "reports"]
file mkdir $OUT_DIR
file mkdir $REPORT_DIR

set_param general.maxThreads 1

set manifest [as_posix_path [file join $REPO_ROOT "fpga" "fpga_sources.f"]]
set xdc_file [as_posix_path [file join $REPO_ROOT "fpga" "boards" "basys3" "basys3.xdc"]]

puts "Basys3 Vivado build"
puts "  part: $PART"
puts "  top: $TOP"
puts "  out_dir: $OUT_DIR"
puts "  run_synth_only: $RUN_SYNTH_ONLY"
puts "  run_impl: $RUN_IMPL"
puts "  generate_bitstream: $GENERATE_BITSTREAM"
puts "  opt_directive: $OPT_DIRECTIVE"
puts "  place_directive: $PLACE_DIRECTIVE"
puts "  phys_opt_directive: $PHYS_OPT_DIRECTIVE"
puts "  route_directive: $ROUTE_DIRECTIVE"
puts "  timing_period_ns: $TIMING_PERIOD_NS"

set fh [open $manifest r]
while {[gets $fh line] >= 0} {
    set source [string trim $line]
    if {$source eq ""} {
        continue
    }
    if {[string match "#*" $source]} {
        continue
    }

    set source_path [as_posix_path [file join $REPO_ROOT $source]]
    read_verilog -sv $source_path
}
close $fh

read_xdc $xdc_file

if {$TIMING_PERIOD_NS != 10.0} {
    # A later XDC replaces the same named clock for this run only. The board
    # constraints and physical 100-MHz oscillator remain unchanged.
    set override_xdc [file join $OUT_DIR "timing_override.xdc"]
    set fh [open $override_xdc w]
    puts $fh [format {create_clock -name sys_clk_pin -period %.6f -waveform {0 %.6f} [get_ports clk]} \
        $TIMING_PERIOD_NS [expr {$TIMING_PERIOD_NS / 2.0}]]
    close $fh
    read_xdc $override_xdc
}

set profile_generics {}
switch -- $ARCHITECTURE_PROFILE {
    "default" {}
    iterative_cpu { set profile_generics {FAST_MULTIPLY=0 ENABLE_MATVEC_SCRATCHPAD=0 ENABLE_MATVEC_DMA=0} }
    fast_cpu { set profile_generics {FAST_MULTIPLY=1 ENABLE_MATVEC_SCRATCHPAD=0 ENABLE_MATVEC_DMA=0} }
    fast_scratchpad { set profile_generics {FAST_MULTIPLY=1 ENABLE_MATVEC_SCRATCHPAD=1 ENABLE_MATVEC_DMA=0} }
    fast_dma { set profile_generics {FAST_MULTIPLY=1 ENABLE_MATVEC_SCRATCHPAD=0 ENABLE_MATVEC_DMA=1} }
    default { error "Unknown architecture profile: $ARCHITECTURE_PROFILE" }
}
if {$ARCHITECTURE_PROFILE ne "default" && $TOP ne "RISCVCPU_basys3_top"} {
    error "Architecture profiles require RISCVCPU_basys3_top"
}
if {$ICACHE_BYTES ni {64 128 256 512 1024 2048 4096} ||
    $ICACHE_PARALLEL_LOOKUP ni {0 1} ||
    ($ICACHE_PARALLEL_LOOKUP == 1 && $ICACHE_BYTES != 64)} {
    error "Unsupported I-cache geometry"
}
if {$ICACHE_BYTES != 64 || $ICACHE_PARALLEL_LOOKUP != 1} {
    if {$TOP ne "RISCVCPU_basys3_top"} { error "I-cache experiments require RISCVCPU_basys3_top" }
    lappend profile_generics ICACHE_BYTES=$ICACHE_BYTES ICACHE_PARALLEL_LOOKUP=$ICACHE_PARALLEL_LOOKUP
}
set synth_arguments [list -top $TOP -part $PART -verilog_define XILINX_VIVADO -flatten_hierarchy none -directive PerformanceOptimized -fsm_extraction off]
if {$DCACHE_VICTIM_LINES ni {0 1 2 4 8}} { error "Unsupported victim-cache size" }
if {$DCACHE_BYTES ni {64 128}} { error "Unsupported D-cache primary size" }
if {$DCACHE_BYTES != 64} {
    if {$TOP ne "RISCVCPU_basys3_top"} { error "D-cache geometry requires RISCVCPU_basys3_top" }
    lappend profile_generics DCACHE_BYTES=$DCACHE_BYTES
}
if {$DCACHE_VICTIM_LINES != 0} {
    if {$TOP ne "RISCVCPU_basys3_top"} { error "Victim-cache experiments require RISCVCPU_basys3_top" }
    lappend profile_generics DCACHE_VICTIM_LINES=$DCACHE_VICTIM_LINES
}
if {[llength $profile_generics]} { lappend synth_arguments -generic $profile_generics }
synth_design {*}$synth_arguments
write_checkpoint -force [file join $OUT_DIR "post_synth.dcp"]
report_utilization -file [file join $REPORT_DIR "post_synth_utilization.rpt"]
report_timing_summary -file [file join $REPORT_DIR "post_synth_timing_summary.rpt"]
report_timing -delay_type max -max_paths 10 -sort_by group -file [file join $REPORT_DIR "post_synth_critical_paths.rpt"]
report_drc -file [file join $REPORT_DIR "post_synth_drc.rpt"]
write_clock_summary [file join $REPORT_DIR "post_synth_clocks.rpt"]

if {$RUN_IMPL} {
    # The direct 100 MHz full SoC is route dominated. Use timing-oriented
    # implementation directives so the canonical flow does not depend on a
    # lucky default placement for its small setup margin.
    opt_design -directive $OPT_DIRECTIVE
    place_design -directive $PLACE_DIRECTIVE
    phys_opt_design -directive $PHYS_OPT_DIRECTIVE
    route_design -directive $ROUTE_DIRECTIVE

    write_checkpoint -force [file join $OUT_DIR "post_route.dcp"]
    report_utilization -file [file join $REPORT_DIR "post_route_utilization.rpt"]
    report_utilization -hierarchical -hierarchical_depth 5 -file [file join $REPORT_DIR "post_route_hierarchy.rpt"]
    report_timing_summary -file [file join $REPORT_DIR "post_route_timing_summary.rpt"]
    report_timing -delay_type max -max_paths 10 -sort_by group -file [file join $REPORT_DIR "post_route_critical_paths.rpt"]
    report_timing -delay_type max -max_paths 50 -nworst 1 -sort_by slack -file [file join $REPORT_DIR "post_route_top50_paths.rpt"]
    report_drc -file [file join $REPORT_DIR "post_route_drc.rpt"]
    report_exceptions -file [file join $REPORT_DIR "post_route_timing_exceptions.rpt"]
    report_clock_interaction -file [file join $REPORT_DIR "post_route_clock_interaction.rpt"]
    write_clock_summary [file join $REPORT_DIR "post_route_clocks.rpt"]
}

if {$GENERATE_BITSTREAM} {
    if {!$RUN_IMPL} {
        error "GENERATE_BITSTREAM requires RUN_IMPL"
    }
    write_bitstream -force [file join $OUT_DIR "$TOP.bit"]
}

puts "Basys3 Vivado build complete"
exit 0
