# Program: matvec_dma_demo
# Purpose: Drives the DMEM-backed MATVEC DMA-lite accelerator from CPU software.
# Exercises: DMA-lite descriptor MMIO, DMemory vector/matrix/output ownership, polling status, counters, and signed
#   int8 results.
# Observable result: Public debug_status pass/fail signature and four DMemory output words are checked by
#   program/integration testbenches.
# Used by: tb_external_dmem_matvec_dma, tb_program_matvec_dma_demo

# Drive the DMEM-backed MATVEC DMA-lite accelerator from CPU software.
# x = [1, -2, 3, -4]
# rows produce y = [-10, -6, 386, 70].

    li   s0, 0x900        # MATVEC DMA-lite MMIO base
    li   s1, 0x180        # vector word in DMemory
    li   s2, 0x190        # matrix rows in DMemory
    li   s3, 0x1a0        # output words in DMemory
    li   s4, 256          # public debug_status byte address

    li   t0, 0xfc03fe01   # VECTOR = {x3, x2, x1, x0} = {-4, 3, -2, 1}
    sw   t0, 0(s1)

    li   t0, 0x01ff0201   # ROW0 -> -10
    sw   t0, 0(s2)
    li   t0, 0x00000504   # ROW1 -> -6
    sw   t0, 4(s2)
    li   t0, 0x0001807f   # ROW2 -> 386
    sw   t0, 8(s2)
    li   t0, 0x000aec00   # ROW3 -> 70
    sw   t0, 12(s2)

    sw   s1, 0(s0)        # MATVEC_DMA_VEC_ADDR
    sw   s2, 4(s0)        # MATVEC_DMA_MATRIX_ADDR
    sw   s3, 8(s0)        # MATVEC_DMA_OUT_ADDR
    li   t0, 4
    sw   t0, 12(s0)       # MATVEC_DMA_ROWS

    li   t0, 1
    sw   t0, 16(s0)       # CTRL.start

poll:
    lw   t1, 20(s0)       # STATUS
    andi t2, t1, 4        # error
    bne  t2, zero, fail
    andi t2, t1, 2        # done
    beq  t2, zero, poll

    lw   a0, 0(s3)
    li   t3, 0xfffffff6
    bne  a0, t3, fail

    lw   a1, 4(s3)
    li   t3, 0xfffffffa
    bne  a1, t3, fail

    lw   a2, 8(s3)
    li   t3, 0x00000182
    bne  a2, t3, fail

    lw   a3, 12(s3)
    li   t3, 0x00000046
    bne  a3, t3, fail

    lw   a4, 28(s0)       # PERF = writes, reads, jobs_completed, jobs_started
    li   t3, 0x04050101
    bne  a4, t3, fail

    li   t0, 4
    sw   t0, 16(s0)       # CTRL.clear_done
    lw   t1, 20(s0)
    andi t2, t1, 6        # done/error should both be clear
    bne  t2, zero, fail

pass:
    li   t4, 0xd1a02016
    sw   t4, 0(s4)
    j    done

fail:
    li   t4, 0xbad02016
    sw   t4, 0(s4)

done:
    beq  zero, zero, done
