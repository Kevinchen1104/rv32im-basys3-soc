# Script: fpga/xsdb/basys3_program.tcl
# Purpose: Programs one explicitly selected Basys3-compatible xc7a35t target through AMD XSDB.
# Scope: Physical JTAG action invoked only by the non-DryRun PowerShell wrapper.

proc json_escape {value} {
    return [string map [list \\ \\\\ \" \\\" \n \\n \r \\r \t \\t] $value]
}

proc json_string {value} {
    return "\"[json_escape $value]\""
}

proc write_program_result {path result} {
    if {$path eq ""} {
        return
    }

    set fh [open $path w]
    puts $fh "{"
    puts $fh "  \"generated_at_utc\": [json_string [dict get $result generated_at_utc]],"
    puts $fh "  \"status\": [json_string [dict get $result status]],"
    puts $fh "  \"hardware_connected\": [dict get $result hardware_connected],"
    puts $fh "  \"inventory_count\": [dict get $result inventory_count],"
    puts $fh "  \"target_count\": [dict get $result target_count],"
    puts $fh "  \"selected_target\": [json_string [dict get $result selected_target]],"
    puts $fh "  \"device_programmed\": [dict get $result device_programmed],"
    puts $fh "  \"configuration_verified\": [dict get $result configuration_verified],"
    puts $fh "  \"configuration_state\": [json_string [dict get $result configuration_state]],"
    puts $fh "  \"retry_count\": 0,"
    puts $fh "  \"cleanup_error\": [json_string [dict get $result cleanup_error]],"
    puts $fh "  \"error\": [json_string [dict get $result error]]"
    puts $fh "}"
    close $fh
}

proc target_matches_selector {target selector} {
    dict for {property value} $target {
        if {[string match -nocase $selector "$value"]} {
            return true
        }
    }
    return false
}

proc target_description {target} {
    set fields {}
    foreach property {target_id name jtag_device_name jtag_device_id} {
        if {[dict exists $target $property]} {
            lappend fields "$property=[dict get $target $property]"
        }
    }
    return [join $fields " "]
}

array set program_options {
    -bitstream ""
    -device_selector "*xc7a35t*"
    -result_path ""
}

set hardware_connected false
set connection_open false
set connection_channel ""
set inventory_count 0
set target_count 0
set selected_target ""
set device_programmed false
set configuration_verified false
set configuration_state ""
set cleanup_error ""

set operation_code [catch {
    if {[expr {[llength $argv] % 2}] != 0} {
        error "Expected key/value Tcl arguments."
    }
    foreach {key value} $argv {
        if {![info exists program_options($key)]} {
            error "Unknown argument: $key"
        }
        set program_options($key) $value
    }

    if {$program_options(-bitstream) eq ""} {
        error "Missing -bitstream argument."
    }
    if {![file isfile $program_options(-bitstream)]} {
        error "Bitstream not found: $program_options(-bitstream)"
    }
    if {$program_options(-result_path) eq ""} {
        error "Missing -result_path argument."
    }
    if {$program_options(-device_selector) eq ""} {
        error "Device selector must not be empty."
    }

    set connection_channel [connect]
    set hardware_connected true
    set connection_open true

    set target_inventory [targets -target-properties]
    set inventory_count [llength $target_inventory]
    set matching_targets {}
    foreach candidate $target_inventory {
        if {[target_matches_selector $candidate $program_options(-device_selector)]} {
            lappend matching_targets $candidate
        }
    }

    set target_count [llength $matching_targets]
    if {$target_count == 0} {
        error "No XSDB target matched selector '$program_options(-device_selector)'."
    }
    if {$target_count != 1} {
        error "XSDB selector '$program_options(-device_selector)' matched $target_count targets; refusing ambiguous programming."
    }

    set selected [lindex $matching_targets 0]
    if {![dict exists $selected target_id]} {
        error "Matched XSDB target does not expose target_id."
    }
    set selected_target [target_description $selected]
    targets [dict get $selected target_id]

    fpga -file $program_options(-bitstream)
    set device_programmed true

    set configuration_state [string trim [fpga -state]]
    if {$configuration_state ne "FPGA is configured"} {
        error "XSDB did not confirm configured state: $configuration_state"
    }
    set configuration_verified true
} operation_error operation_options]

if {$connection_open} {
    if {[catch {disconnect $connection_channel} disconnect_error]} {
        set cleanup_error $disconnect_error
    }
    set connection_open false
}

set final_status "pass"
set final_error ""
if {$operation_code != 0} {
    set final_status "fail"
    set final_error $operation_error
} elseif {!$device_programmed || !$configuration_verified} {
    set final_status "fail"
    set final_error "XSDB returned without complete one-shot programming and configuration confirmation."
}
if {$cleanup_error ne "" && $final_status eq "pass"} {
    set final_status "fail"
    set final_error "Programming completed but XSDB disconnect failed: $cleanup_error"
}

set program_result [dict create \
    generated_at_utc [clock format [clock seconds] -gmt true -format "%Y-%m-%dT%H:%M:%SZ"] \
    status $final_status \
    hardware_connected $hardware_connected \
    inventory_count $inventory_count \
    target_count $target_count \
    selected_target $selected_target \
    device_programmed $device_programmed \
    configuration_verified $configuration_verified \
    configuration_state $configuration_state \
    cleanup_error $cleanup_error \
    error $final_error]

write_program_result $program_options(-result_path) $program_result

if {$final_status ne "pass"} {
    puts stderr "ERROR: $final_error"
    exit 1
}

puts "PROGRAM_RESULT: target={$selected_target} programmed=true configured=true retry_count=0"
exit 0
