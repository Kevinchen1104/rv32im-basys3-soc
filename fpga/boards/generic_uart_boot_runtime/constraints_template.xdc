## Generic UART boot runtime XDC template.
## Fill every PACKAGE_PIN/IOSTANDARD from the selected board manual before use.
## This file intentionally contains no real board pin assignments.

## Clock
## Replace <CLOCK_PORT_PIN>, <CLOCK_IOSTANDARD>, and <CLOCK_PERIOD_NS>.
# set_property PACKAGE_PIN <CLOCK_PORT_PIN> [get_ports {clock}]
# set_property IOSTANDARD <CLOCK_IOSTANDARD> [get_ports {clock}]
# create_clock -name sys_clk -period <CLOCK_PERIOD_NS> [get_ports {clock}]

## Reset
## Replace <RESET_PORT_PIN> and polarity handling to match the board.
# set_property PACKAGE_PIN <RESET_PORT_PIN> [get_ports {reset}]
# set_property IOSTANDARD <RESET_IOSTANDARD> [get_ports {reset}]

## UART
## Replace pins with the board USB-UART or PMOD/UART bridge pins.
# set_property PACKAGE_PIN <UART_RX_PIN> [get_ports {uart_rx}]
# set_property IOSTANDARD <UART_IOSTANDARD> [get_ports {uart_rx}]
# set_property PACKAGE_PIN <UART_TX_PIN> [get_ports {uart_tx}]
# set_property IOSTANDARD <UART_IOSTANDARD> [get_ports {uart_tx}]

## LEDs
## Expand or reduce these entries to match the selected board LED count.
# set_property PACKAGE_PIN <LED0_PIN> [get_ports {leds[0]}]
# set_property PACKAGE_PIN <LED1_PIN> [get_ports {leds[1]}]
# set_property PACKAGE_PIN <LED2_PIN> [get_ports {leds[2]}]
# set_property PACKAGE_PIN <LED3_PIN> [get_ports {leds[3]}]
# set_property PACKAGE_PIN <LED4_PIN> [get_ports {leds[4]}]
# set_property PACKAGE_PIN <LED5_PIN> [get_ports {leds[5]}]
# set_property PACKAGE_PIN <LED6_PIN> [get_ports {leds[6]}]
# set_property PACKAGE_PIN <LED7_PIN> [get_ports {leds[7]}]
# set_property IOSTANDARD <LED_IOSTANDARD> [get_ports {leds[*]}]

## GPIO inputs/outputs
## Map only the GPIO pins you actually route on the board.
# set_property PACKAGE_PIN <GPIO_IN0_PIN> [get_ports {gpio_inputs[0]}]
# set_property IOSTANDARD <GPIO_IOSTANDARD> [get_ports {gpio_inputs[0]}]
# set_property PACKAGE_PIN <GPIO_OUT0_PIN> [get_ports {gpio_outputs[0]}]
# set_property IOSTANDARD <GPIO_IOSTANDARD> [get_ports {gpio_outputs[0]}]

## Optional debug ports
## Route these only if board pins, LEDs, or an ILA/debug core are available.
# set_property PACKAGE_PIN <DONE_PIN> [get_ports {done}]
# set_property PACKAGE_PIN <BOOT_WAITING_PIN> [get_ports {boot_waiting}]
# set_property PACKAGE_PIN <LOADER_DONE_PIN> [get_ports {loader_done}]
# set_property PACKAGE_PIN <BOOT_ERROR_PIN> [get_ports {boot_error}]
# set_property PACKAGE_PIN <HEARTBEAT_PIN> [get_ports {heartbeat}]

## Timing exceptions
## Add board/tool-specific false paths or generated clocks only after review.
