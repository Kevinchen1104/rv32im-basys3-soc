# Program: pointer_store
# Purpose: Loads a label-derived pointer and stores through it.
# Exercises: la-style pointer materialization, load/store, and DMemory observation.
# Observable result: Final pointer result and DMemory value are checked by the program testbench.
# Used by: tb_program_pointer

# Use a label address as a D-memory pointer in this Harvard-style test system.

    la   t0, data_slot     # data_slot is byte address 32
    li   t1, 0x12345678
    sw   t1, 0(t0)
    lw   a0, 0(t0)
    lw   s0, 96(zero)     # conflicting cache block forces data_slot write-back

done:
    beq  zero, zero, done

data_slot:                # symbolic DMemory address; initialized by testbench
