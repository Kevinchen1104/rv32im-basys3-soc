# Script: fpga/vivado/basys3_program.tcl
# Purpose: Programs one explicitly selected Basys3-compatible xc7a35t device.
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
    puts $fh "  \"hardware_opened\": [dict get $result hardware_opened],"
    puts $fh "  \"hw_server_connected\": [dict get $result hw_server_connected],"
    puts $fh "  \"target_opened\": [dict get $result target_opened],"
    puts $fh "  \"device_found\": [dict get $result device_found],"
    puts $fh "  \"device_name\": [json_string [dict get $result device_name]],"
    puts $fh "  \"device_part\": [json_string [dict get $result device_part]],"
    puts $fh "  \"device_programmed\": [dict get $result device_programmed],"
    puts $fh "  \"retry_count\": 0,"
    puts $fh "  \"cleanup_error\": [json_string [dict get $result cleanup_error]],"
    puts $fh "  \"error\": [json_string [dict get $result error]]"
    puts $fh "}"
    close $fh
}

array set program_options {
    -bitstream ""
    -device_selector "*xc7a35t*"
    -result_path ""
}

set hardware_opened false
set hw_server_connected false
set target_opened false
set device_found false
set device_programmed false
set device_name ""
set device_part ""
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

    open_hw_manager
    set hardware_opened true

    connect_hw_server
    set hw_server_connected true

    open_hw_target
    set target_opened true

    set matching_devices {}
    foreach candidate [get_hw_devices -quiet] {
        set candidate_name "$candidate"
        set candidate_part [get_property PART $candidate]
        if {[string match -nocase $program_options(-device_selector) $candidate_name] ||
            [string match -nocase $program_options(-device_selector) $candidate_part]} {
            lappend matching_devices $candidate
        }
    }

    set match_count [llength $matching_devices]
    if {$match_count == 0} {
        error "No hardware device matched selector '$program_options(-device_selector)'."
    }
    if {$match_count != 1} {
        error "Device selector '$program_options(-device_selector)' matched $match_count devices; refusing ambiguous programming."
    }

    set selected_device [lindex $matching_devices 0]
    set device_found true
    set device_name "$selected_device"
    set device_part [get_property PART $selected_device]

    refresh_hw_device -update_hw_probes false $selected_device
    set_property PROGRAM.FILE $program_options(-bitstream) $selected_device
    program_hw_devices $selected_device
    set device_programmed true
    refresh_hw_device -update_hw_probes false $selected_device
} operation_error operation_options]

if {$target_opened} {
    if {[catch {close_hw_target} close_error] && $cleanup_error eq ""} {
        set cleanup_error $close_error
    }
}
if {$hw_server_connected} {
    if {[catch {disconnect_hw_server} disconnect_error] && $cleanup_error eq ""} {
        set cleanup_error $disconnect_error
    }
}
if {$hardware_opened} {
    if {[catch {close_hw_manager} manager_error] && $cleanup_error eq ""} {
        set cleanup_error $manager_error
    }
}

set final_status "pass"
set final_error ""
if {$operation_code != 0} {
    set final_status "fail"
    set final_error $operation_error
} elseif {!$device_programmed} {
    set final_status "fail"
    set final_error "Vivado returned without confirming program_hw_devices completion."
}
if {$cleanup_error ne "" && $final_status eq "pass"} {
    set final_status "fail"
    set final_error "Programming completed but hardware cleanup failed: $cleanup_error"
}

set program_result [dict create \
    generated_at_utc [clock format [clock seconds] -gmt true -format "%Y-%m-%dT%H:%M:%SZ"] \
    status $final_status \
    hardware_opened $hardware_opened \
    hw_server_connected $hw_server_connected \
    target_opened $target_opened \
    device_found $device_found \
    device_name $device_name \
    device_part $device_part \
    device_programmed $device_programmed \
    cleanup_error $cleanup_error \
    error $final_error]

write_program_result $program_options(-result_path) $program_result

if {$final_status ne "pass"} {
    puts stderr "ERROR: $final_error"
    exit 1
}

puts "PROGRAM_RESULT: device=$device_name part=$device_part programmed=true retry_count=0"
exit 0
