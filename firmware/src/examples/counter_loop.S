# Program: counter_loop
# Purpose: Runs a bounded loop that produces visible performance-counter activity.
# Exercises: Branch loop behavior, loads/stores, and performance counter observation.
# Observable result: Final sum and counter INFO values are checked by the program testbench.
# Used by: tb_program_counter_loop

# Small benchmark-style loop for performance-counter reporting.
# Sums 1 through 16, stores the result to the debug status word, and forces
# a dirty D-cache write-back.

    li   t0, 0             # running sum
    li   t1, 16            # loop count
    li   t2, 1             # current addend

loop:
    add  t0, t0, t2
    addi t2, t2, 1
    addi t1, t1, -1
    bne  t1, zero, loop

    li   t3, 256           # status address: 0x100
    sw   t0, 0(t3)
    lw   s0, 320(zero)     # conflicting block writes dirty status back

done:
    beq  zero, zero, done
