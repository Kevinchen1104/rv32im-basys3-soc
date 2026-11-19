# Program: access_fault_misaligned_control
# Purpose: Checks that an instruction-access fault on a control transfer raises exactly one trap.
# Exercises: a JAL with a misaligned target fetched beyond MEMORY_WORD_COUNT from external IMEM.
# Observable result: Public debug_status pass/fail signature is checked by the program testbench.
# Used by: tb_program_access_fault_misaligned_control

    li   t0, 0
    sw   t0, 64(zero)     # trap count
    la   t0, handler
    csrrw x0, mtvec, t0
    li   t0, 0x88
    csrrw x0, mstatus, t0 # MIE=1, MPIE=1
    li   t0, 0x400        # first byte beyond MEMORY_WORD_COUNT=256
    jalr x0, 0(t0)        # the testbench returns "jal x0, +6" there

recover:
    lw   t1, 64(zero)
    li   t2, 1
    bne  t1, t2, fail     # exactly one trap
    lw   t1, 68(zero)
    bne  t1, t2, fail     # mcause = instruction access fault
    lw   t1, 72(zero)
    li   t2, 0x400
    bne  t1, t2, fail     # mepc
    lw   t1, 76(zero)
    bne  t1, t2, fail     # mtval
    lw   t1, 80(zero)
    li   t2, 0x1880
    bne  t1, t2, fail     # entry state: MPP=M, MPIE=1, MIE=0

    li   t3, 256
    li   t4, 0xc5e3000a
    sw   t4, 0(t3)
    j    done

handler:
    lw   t1, 64(zero)
    addi t1, t1, 1
    sw   t1, 64(zero)
    li   t2, 1
    bne  t1, t2, handler_return
    csrrs t2, mcause, zero
    sw   t2, 68(zero)
    csrrs t2, mepc, zero
    sw   t2, 72(zero)
    csrrs t2, mtval, zero
    sw   t2, 76(zero)
    csrrs t2, mstatus, zero
    sw   t2, 80(zero)
handler_return:
    la   t2, recover
    csrrw x0, mepc, t2
    mret

fail:
    li   t3, 256
    li   t4, 0xbad5000a
    sw   t4, 0(t3)

done:
    beq  zero, zero, done
