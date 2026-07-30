# Program: perf_mmio_read
# Purpose: Reads CPU performance counters through the 0x600 MMIO window.
# Exercises: cycle/retired/cache/stall/MATVEC counter MMIO reads and ignored store behavior.
# Observable result: Public debug_status pass/fail signature and DMemory counter snapshots are checked by the program
#   testbench.
# Used by: tb_program_perf_mmio_read

# Read CPU performance counters through the 0x600 MMIO window.
# This is an observability/bring-up smoke, not a benchmark or speedup claim.

    li   t0, 0x600        # performance-counter MMIO base

    lw   t1, 0(t0)        # cycle_count
    beq  t1, zero, fail
    sw   t1, 0(zero)

    lw   t2, 4(t0)        # retired_count
    beq  t2, zero, fail
    sw   t2, 4(zero)

    lw   t3, 8(t0)        # branch_miss_count
    sw   t3, 8(zero)

    lw   t4, 12(t0)       # icache_miss_count
    sw   t4, 12(zero)

    lw   t5, 16(t0)       # dcache_miss_count
    sw   t5, 16(zero)

    lw   t6, 20(t0)       # stall_cycle_count
    sw   t6, 20(zero)

    lw   a0, 24(t0)       # matvec_start_count before any MATVEC start
    bne  a0, zero, fail

    lw   a1, 28(t0)       # matvec_done_count before any MATVEC start
    bne  a1, zero, fail

    lw   a2, 32(t0)       # matvec_busy_cycle_count before any MATVEC start
    bne  a2, zero, fail

    li   a3, 0x55aa55aa
    sw   a3, 24(t0)       # store to read-only counter MMIO must be ignored

    lw   a0, 24(t0)
    bne  a0, zero, fail
    lw   a1, 28(t0)
    bne  a1, zero, fail
    lw   a2, 32(t0)
    bne  a2, zero, fail

    li   t3, 256
    li   t4, 0xacce6000
    sw   t4, 0(t3)
    lw   s2, 336(zero)    # evict/write back DMemory word 4
    lw   s1, 320(zero)    # evict/write back DMemory words 0..3 and status
    j    done

fail:
    li   t3, 256
    li   t4, 0xbad06000
    sw   t4, 0(t3)
    lw   s2, 336(zero)
    lw   s1, 320(zero)

done:
    beq  zero, zero, done
