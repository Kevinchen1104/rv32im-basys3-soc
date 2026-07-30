# Program: board_smoke
# Purpose: Writes a stable board-smoke pass value for wrapper bring-up.
# Exercises: DMemory status store at 0x100, cache writeback visibility, and FPGA-facing status observation.
# Observable result: Status value 0x600dcafe is checked by program, boot, external-memory, and FPGA wrapper
#   testbenches.
# Used by: tb_external_dmem_debug_status, tb_program_board_smoke, and tb_uart_packet_boot_imem.
# Does not claim: Simulation bring-up smoke only; not timing closure or physical board validation.

# Board smoke program: a minimal hardware bring-up pass/fail signal.
# Writes a fixed pass value to a stable status address.

    li   t0, 256           # status address: 0x100
    li   t1, 0x600dcafe    # recognizable pass value
    sw   t1, 0(t0)

    lw   s0, 320(zero)     # conflicting block writes dirty status back
    j    done

done:
    beq  zero, zero, done
