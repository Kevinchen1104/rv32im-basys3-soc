# Program: led_smoke
# Purpose: Writes an alternate LED/status pattern for wrapper image-override tests.
# Exercises: Parameterized FPGA program image selection and low-byte LED/status observation.
# Observable result: Status value 0x123456a5 is checked by FPGA wrapper testbenches.
# Used by: tb_fpga_top_program_override, tb_fpga_top_smoke_pass
# Does not claim: Simulation wrapper smoke only; not timing closure or physical board validation.

# Alternate board smoke program for wrapper image-parameter testing.
# Writes a different status value so LED output proves the override worked.

    li   t0, 256           # status address: 0x100
    li   t1, 0x123456a5    # low byte becomes LED pattern 0xa5
    sw   t1, 0(t0)

    lw   s0, 320(zero)     # conflicting block writes dirty status back
    j    done

done:
    beq  zero, zero, done
