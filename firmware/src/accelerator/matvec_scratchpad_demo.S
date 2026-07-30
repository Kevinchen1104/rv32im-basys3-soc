# Program: matvec_scratchpad_demo
# Purpose: Drives the MATVEC Scratchpad accelerator from CPU load/store MMIO.
# Exercises: MATVEC Scratchpad row storage, vector/config/result registers, done clearing, perf counters, and polling.
# Observable result: Public debug_status pass/fail signature and exact signed int32 results are checked by the program
#   testbench.
# Used by: tb_program_matvec_scratchpad
#   speedup claim.

# Drive the MATVEC Scratchpad accelerator from CPU load/store MMIO.
# x = [1, -2, 3, -4]
# rows produce y = [-10, -6, 386, 70].

    li   t0, 0x700        # MATVEC Scratchpad MMIO base

    li   t1, 3            # CONFIG row_count_minus1 = 3, so 4 rows
    sw   t1, 8(t0)

    li   t1, 0xfc03fe01   # VECTOR = {x3, x2, x1, x0}
    sw   t1, 12(t0)

    li   t2, 0
    sw   t2, 16(t0)       # ROW_INDEX = 0
    li   t1, 0x04030201   # ROW0 = {4, 3, 2, 1}
    sw   t1, 20(t0)

    li   t2, 1
    sw   t2, 16(t0)       # ROW_INDEX = 1
    li   t1, 0x020100ff   # ROW1 = {2, 1, 0, -1}
    sw   t1, 20(t0)

    li   t2, 2
    sw   t2, 16(t0)       # ROW_INDEX = 2
    li   t1, 0x0001807f   # ROW2 = {0, 1, -128, 127}
    sw   t1, 20(t0)

    li   t2, 3
    sw   t2, 16(t0)       # ROW_INDEX = 3
    li   t1, 0xf807fa05   # ROW3 = {-8, 7, -6, 5}
    sw   t1, 20(t0)

    li   t1, 1
    sw   t1, 0(t0)        # CTRL start

poll:
    lw   t2, 4(t0)        # STATUS
    andi t2, t2, 2
    beq  t2, zero, poll

    li   t2, 0
    sw   t2, 24(t0)       # RESULT_INDEX = 0
    lw   a0, 28(t0)       # RESULT_DATA
    sw   a0, 0(zero)
    li   s0, 0xfffffff6
    bne  a0, s0, fail

    li   t2, 1
    sw   t2, 24(t0)       # RESULT_INDEX = 1
    lw   a1, 28(t0)
    sw   a1, 4(zero)
    li   s0, 0xfffffffa
    bne  a1, s0, fail

    li   t2, 2
    sw   t2, 24(t0)       # RESULT_INDEX = 2
    lw   a2, 28(t0)
    sw   a2, 8(zero)
    li   s0, 0x00000182
    bne  a2, s0, fail

    li   t2, 3
    sw   t2, 24(t0)       # RESULT_INDEX = 3
    lw   a3, 28(t0)
    sw   a3, 12(zero)
    li   s0, 0x00000046
    bne  a3, s0, fail

    lw   a4, 32(t0)       # PERF
    sw   a4, 16(zero)
    andi s1, a4, 255
    li   s0, 1
    bne  s1, s0, fail

    li   t3, 256
    li   t4, 0xacce2004
    sw   t4, 0(t3)

    lw   s2, 336(zero)    # evict/write back DMemory word 4
    lw   s1, 320(zero)    # evict/write back DMemory words 0..3 and status
    j    done

fail:
    li   t3, 256
    li   t4, 0xbad02004
    sw   t4, 0(t3)
    lw   s2, 336(zero)
    lw   s1, 320(zero)

done:
    beq  zero, zero, done
