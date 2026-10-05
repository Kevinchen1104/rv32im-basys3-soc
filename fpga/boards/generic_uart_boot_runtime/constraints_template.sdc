# Generic UART boot runtime SDC template.
# Fill clock period and IO constraints from the selected board manual/tool flow.
# This file intentionally contains no real board pin assignments.

# Clock
# Replace <CLOCK_PERIOD_NS> with the board clock period.
# create_clock -name sys_clk -period <CLOCK_PERIOD_NS> [get_ports clock]

# Reset
# For an asynchronous external reset, constrain only the path into the first
# reset synchronizer stage. Do not blanket-cut paths to all reset consumers;
# synchronized reset release still needs timing analysis in its clock domain.

# UART
# Add input/output delays only after selecting a real UART bridge and board IO.
# set_input_delay  <UART_INPUT_DELAY_NS>  -clock sys_clk [get_ports uart_rx]
# set_output_delay <UART_OUTPUT_DELAY_NS> -clock sys_clk [get_ports uart_tx]

# LEDs/GPIO
# Add IO timing constraints only for pins that leave the FPGA package.

# Timing status
# No timing closure claim is made by this template.
