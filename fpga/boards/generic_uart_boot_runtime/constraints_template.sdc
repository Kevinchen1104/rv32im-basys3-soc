# Generic UART boot runtime SDC template.
# Fill clock period and IO constraints from the selected board manual/tool flow.
# This file intentionally contains no real board pin assignments.

# Clock
# Replace <CLOCK_PERIOD_NS> with the board clock period.
# create_clock -name sys_clk -period <CLOCK_PERIOD_NS> [get_ports clock]

# Reset
# Review whether reset is asynchronous to the clock in the selected top/project.
# set_false_path -from [get_ports reset]

# UART
# Add input/output delays only after selecting a real UART bridge and board IO.
# set_input_delay  <UART_INPUT_DELAY_NS>  -clock sys_clk [get_ports uart_rx]
# set_output_delay <UART_OUTPUT_DELAY_NS> -clock sys_clk [get_ports uart_tx]

# LEDs/GPIO
# Add IO timing constraints only for pins that leave the FPGA package.

# Timing status
# No timing closure claim is made by this template.
