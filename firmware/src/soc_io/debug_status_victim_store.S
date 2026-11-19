# Program: debug_status_victim_store
# Purpose: Checks that the public debug_status mirror sees a store completed by a D-cache victim-buffer hit.
# Exercises: a store to 0x100 after its line was evicted from the primary cache into the victim buffer.
# Observable result: Public debug_status pass signature is checked by the program testbench.
# Used by: tb_program_debug_status_victim_store

    li   t0, 256          # debug_status word 0x100
    li   t1, 0x12345678
    sw   t1, 0(t0)        # 0x100's line becomes resident and dirty
    li   t2, 320          # 0x140 maps to the same 64-byte direct-mapped index
    lw   t3, 0(t2)        # miss moves 0x100's line into the victim buffer
    li   t4, 0xc5e37c40
    sw   t4, 0(t0)        # completes as a victim-buffer hit

done:
    beq  zero, zero, done
