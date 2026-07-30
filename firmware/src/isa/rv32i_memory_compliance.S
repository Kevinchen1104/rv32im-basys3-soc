# Program: rv32i_memory_compliance
# Purpose: Runs selected local RV32I memory compliance-style checks.
# Exercises: lb/lbu/lh/lhu/lw/sb/sh/sw, little-endian byte lanes, sign/zero extension, and overlapping subword stores.
# Observable result: Public debug_status pass/fail signature is checked by the program testbench.
# Used by: tb_program_rv32i_memory_compliance
# Does not claim: Not an official compliance suite, memory-system proof, or cache-coherence claim.

# Selected local RV32I memory compliance-style test.
# This is not an official compliance suite.

    li   t0, 0x11223344
    sw   t0, 0(zero)
    lw   t1, 0(zero)
    bne  t1, t0, fail

    lbu  t1, 0(zero)
    li   t2, 0x44
    bne  t1, t2, fail
    lbu  t1, 1(zero)
    li   t2, 0x33
    bne  t1, t2, fail
    lbu  t1, 2(zero)
    li   t2, 0x22
    bne  t1, t2, fail
    lbu  t1, 3(zero)
    li   t2, 0x11
    bne  t1, t2, fail
    lb   t1, 3(zero)
    li   t2, 0x11
    bne  t1, t2, fail
    lh   t1, 0(zero)
    li   t2, 0x3344
    bne  t1, t2, fail
    lhu  t1, 2(zero)
    li   t2, 0x1122
    bne  t1, t2, fail

    li   t0, 0x80ff7f01
    sw   t0, 4(zero)
    lb   t1, 6(zero)
    li   t2, -1
    bne  t1, t2, fail
    lbu  t1, 6(zero)
    li   t2, 0xff
    bne  t1, t2, fail
    lb   t1, 7(zero)
    li   t2, 0xffffff80
    bne  t1, t2, fail
    lbu  t1, 7(zero)
    li   t2, 0x80
    bne  t1, t2, fail
    lh   t1, 6(zero)
    li   t2, 0xffff80ff
    bne  t1, t2, fail
    lhu  t1, 6(zero)
    li   t2, 0x80ff
    bne  t1, t2, fail

    li   t0, 0xaaaaaaaa
    sw   t0, 8(zero)
    li   t0, 0x55
    sb   t0, 9(zero)
    lw   t1, 8(zero)
    li   t2, 0xaaaa55aa
    bne  t1, t2, fail

    li   t0, 0x1234
    sh   t0, 10(zero)
    lw   t1, 8(zero)
    li   t2, 0x123455aa
    bne  t1, t2, fail

    li   t0, 0x8001
    sh   t0, 8(zero)
    lw   t1, 8(zero)
    li   t2, 0x12348001
    bne  t1, t2, fail
    lh   t1, 8(zero)
    li   t2, 0xffff8001
    bne  t1, t2, fail
    lhu  t1, 8(zero)
    li   t2, 0x8001
    bne  t1, t2, fail

    li   t0, 0xff
    sb   t0, 11(zero)
    lw   t1, 8(zero)
    li   t2, 0xff348001
    bne  t1, t2, fail
    lb   t1, 11(zero)
    li   t2, -1
    bne  t1, t2, fail
    lbu  t1, 11(zero)
    li   t2, 0xff
    bne  t1, t2, fail

pass:
    li   t5, 256
    li   t6, 0xc0a10003
    sw   t6, 0(t5)
    lw   s0, 320(zero)
    j    done

fail:
    li   t5, 256
    li   t6, 0xbad10003
    sw   t6, 0(t5)
    lw   s0, 320(zero)

done:
    beq  zero, zero, done
