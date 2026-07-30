# Program: abi_call
# Purpose: Calls an ABI-style leaf function and checks return-value/register convention behavior.
# Exercises: Function call, return-address, stack-pointer, and register-result bring-up.
# Observable result: Final registers are checked by the program testbench.
# Used by: tb_program_abi

# Use ABI register names and single-instruction pseudos for a small function call.

    li   sp, 48           # stack pointer
    li   a0, 7            # first argument and return value
    call add_five

    mv   t1, a0           # copy the return value through an addi pseudo
    sw   a0, 0(zero)      # store returned value = 12
    lw   t0, 64(zero)     # force dirty write-back
    j    done
    nop

add_five:
    addi sp, sp, -4
    sw   ra, 0(sp)
    addi a0, a0, 5
    lw   ra, 0(sp)
    addi sp, sp, 4
    ret

done:
    beq  zero, zero, done
