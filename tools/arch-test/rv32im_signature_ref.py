#!/usr/bin/env python3
"""Local independent RV32IM signature reference for selected arch-test cases.

This is intentionally small and scoped to the locally selected RV32I/RV32M
arch-test sources. It is not a RISCOF, Spike, or Sail replacement and must not
be used as an official compliance result.
"""

import argparse
import json
from pathlib import Path
import sys


MASK32 = 0xFFFFFFFF
INT_MIN = 0x80000000
TOHOST_PASS = 0x00000001
TOHOST_FAIL = 0x00000003


class UnsupportedInstruction(Exception):
    pass


class ReferenceCpu:
    def __init__(self, program_hex, memory_words, tohost_word, pass_pc, fail_pc):
        self.mem = {}
        self.regs = [0] * 32
        self.csrs = {}
        self.pc = 0
        self.cycles = 0
        self.memory_words = memory_words
        self.tohost_word = tohost_word
        self.pass_pc = pass_pc
        self.fail_pc = fail_pc
        self._load_hex(program_hex)

    def _load_hex(self, program_hex):
        for word_index, raw_line in enumerate(Path(program_hex).read_text().splitlines()):
            line = raw_line.strip()
            if not line:
                continue
            word = int(line, 16) & MASK32
            base = word_index * 4
            self.write_u8(base + 0, word & 0xFF)
            self.write_u8(base + 1, (word >> 8) & 0xFF)
            self.write_u8(base + 2, (word >> 16) & 0xFF)
            self.write_u8(base + 3, (word >> 24) & 0xFF)

    def read_u8(self, addr):
        return self.mem.get(addr & MASK32, 0) & 0xFF

    def read_u16(self, addr):
        return self.read_u8(addr) | (self.read_u8(addr + 1) << 8)

    def read_u32(self, addr):
        return (
            self.read_u8(addr)
            | (self.read_u8(addr + 1) << 8)
            | (self.read_u8(addr + 2) << 16)
            | (self.read_u8(addr + 3) << 24)
        ) & MASK32

    def write_u8(self, addr, value):
        self.mem[addr & MASK32] = value & 0xFF

    def write_u16(self, addr, value):
        self.write_u8(addr, value)
        self.write_u8(addr + 1, value >> 8)

    def write_u32(self, addr, value):
        self.write_u8(addr, value)
        self.write_u8(addr + 1, value >> 8)
        self.write_u8(addr + 2, value >> 16)
        self.write_u8(addr + 3, value >> 24)

    def get_reg(self, idx):
        return 0 if idx == 0 else self.regs[idx] & MASK32

    def set_reg(self, idx, value):
        if idx != 0:
            self.regs[idx] = value & MASK32
        self.regs[0] = 0

    def pc_matches(self, base_pc):
        if base_pc < 0:
            return False
        return self.pc in {
            base_pc & MASK32,
            (base_pc + 4) & MASK32,
            (base_pc + 8) & MASK32,
            (base_pc + 12) & MASK32,
        }

    def tohost_status(self):
        if self.tohost_word < 0:
            return 0
        return self.read_u32(self.tohost_word * 4)

    def termination(self):
        status = self.tohost_status()
        if status == TOHOST_PASS:
            return "pass_tohost"
        if status == TOHOST_FAIL:
            return "fail_tohost"
        if self.pc_matches(self.pass_pc):
            return "pass_pc"
        if self.pc_matches(self.fail_pc):
            return "fail_pc"
        return None

    def step(self):
        instr = self.read_u32(self.pc)
        next_pc = (self.pc + 4) & MASK32
        opcode = instr & 0x7F
        rd = (instr >> 7) & 0x1F
        funct3 = (instr >> 12) & 0x7
        rs1 = (instr >> 15) & 0x1F
        rs2 = (instr >> 20) & 0x1F
        funct7 = (instr >> 25) & 0x7F

        if opcode == 0x37:  # LUI
            self.set_reg(rd, instr & 0xFFFFF000)
        elif opcode == 0x17:  # AUIPC
            self.set_reg(rd, self.pc + (instr & 0xFFFFF000))
        elif opcode == 0x6F:  # JAL
            self.set_reg(rd, self.pc + 4)
            next_pc = (self.pc + imm_j(instr)) & MASK32
        elif opcode == 0x67:  # JALR
            if funct3 != 0:
                self.unsupported(instr)
            target = (self.get_reg(rs1) + imm_i(instr)) & MASK32
            self.set_reg(rd, self.pc + 4)
            next_pc = target & ~1
        elif opcode == 0x63:  # branch
            a = self.get_reg(rs1)
            b = self.get_reg(rs2)
            take = self.branch_taken(funct3, a, b, instr)
            if take:
                next_pc = (self.pc + imm_b(instr)) & MASK32
        elif opcode == 0x03:  # load
            addr = (self.get_reg(rs1) + imm_i(instr)) & MASK32
            self.exec_load(funct3, rd, addr, instr)
        elif opcode == 0x23:  # store
            addr = (self.get_reg(rs1) + imm_s(instr)) & MASK32
            self.exec_store(funct3, addr, self.get_reg(rs2), instr)
        elif opcode == 0x13:  # OP-IMM
            self.exec_op_imm(funct3, funct7, rd, rs1, instr)
        elif opcode == 0x33:  # OP / M
            self.exec_op(funct3, funct7, rd, rs1, rs2, instr)
        elif opcode == 0x0F:  # FENCE/FENCE.I
            pass
        elif opcode == 0x73:  # SYSTEM / CSR subset
            next_pc = self.exec_system(funct3, rd, rs1, instr, next_pc)
        else:
            self.unsupported(instr)

        self.pc = next_pc & MASK32
        self.regs[0] = 0
        self.cycles += 1

    def branch_taken(self, funct3, a, b, instr):
        if funct3 == 0x0:
            return a == b
        if funct3 == 0x1:
            return a != b
        if funct3 == 0x4:
            return to_s32(a) < to_s32(b)
        if funct3 == 0x5:
            return to_s32(a) >= to_s32(b)
        if funct3 == 0x6:
            return a < b
        if funct3 == 0x7:
            return a >= b
        self.unsupported(instr)
        return False

    def exec_load(self, funct3, rd, addr, instr):
        if funct3 == 0x0:
            self.set_reg(rd, sext(self.read_u8(addr), 8))
        elif funct3 == 0x1:
            self.set_reg(rd, sext(self.read_u16(addr), 16))
        elif funct3 == 0x2:
            self.set_reg(rd, self.read_u32(addr))
        elif funct3 == 0x4:
            self.set_reg(rd, self.read_u8(addr))
        elif funct3 == 0x5:
            self.set_reg(rd, self.read_u16(addr))
        else:
            self.unsupported(instr)

    def exec_store(self, funct3, addr, value, instr):
        if funct3 == 0x0:
            self.write_u8(addr, value)
        elif funct3 == 0x1:
            self.write_u16(addr, value)
        elif funct3 == 0x2:
            self.write_u32(addr, value)
        else:
            self.unsupported(instr)

    def exec_op_imm(self, funct3, funct7, rd, rs1, instr):
        a = self.get_reg(rs1)
        imm = imm_i(instr)
        shamt = (instr >> 20) & 0x1F
        if funct3 == 0x0:
            self.set_reg(rd, a + imm)
        elif funct3 == 0x2:
            self.set_reg(rd, 1 if to_s32(a) < to_s32(imm) else 0)
        elif funct3 == 0x3:
            self.set_reg(rd, 1 if a < (imm & MASK32) else 0)
        elif funct3 == 0x4:
            self.set_reg(rd, a ^ imm)
        elif funct3 == 0x6:
            self.set_reg(rd, a | imm)
        elif funct3 == 0x7:
            self.set_reg(rd, a & imm)
        elif funct3 == 0x1 and funct7 == 0x00:
            self.set_reg(rd, a << shamt)
        elif funct3 == 0x5 and funct7 == 0x00:
            self.set_reg(rd, a >> shamt)
        elif funct3 == 0x5 and funct7 == 0x20:
            self.set_reg(rd, to_s32(a) >> shamt)
        else:
            self.unsupported(instr)

    def exec_op(self, funct3, funct7, rd, rs1, rs2, instr):
        a = self.get_reg(rs1)
        b = self.get_reg(rs2)
        shamt = b & 0x1F
        if funct7 == 0x00:
            if funct3 == 0x0:
                self.set_reg(rd, a + b)
            elif funct3 == 0x1:
                self.set_reg(rd, a << shamt)
            elif funct3 == 0x2:
                self.set_reg(rd, 1 if to_s32(a) < to_s32(b) else 0)
            elif funct3 == 0x3:
                self.set_reg(rd, 1 if a < b else 0)
            elif funct3 == 0x4:
                self.set_reg(rd, a ^ b)
            elif funct3 == 0x5:
                self.set_reg(rd, a >> shamt)
            elif funct3 == 0x6:
                self.set_reg(rd, a | b)
            elif funct3 == 0x7:
                self.set_reg(rd, a & b)
            else:
                self.unsupported(instr)
        elif funct7 == 0x20:
            if funct3 == 0x0:
                self.set_reg(rd, a - b)
            elif funct3 == 0x5:
                self.set_reg(rd, to_s32(a) >> shamt)
            else:
                self.unsupported(instr)
        elif funct7 == 0x01:
            self.exec_m(funct3, rd, a, b, instr)
        else:
            self.unsupported(instr)

    def exec_m(self, funct3, rd, a, b, instr):
        if funct3 == 0x0:
            self.set_reg(rd, to_s32(a) * to_s32(b))
        elif funct3 == 0x1:
            self.set_reg(rd, (to_s32(a) * to_s32(b)) >> 32)
        elif funct3 == 0x2:
            self.set_reg(rd, (to_s32(a) * b) >> 32)
        elif funct3 == 0x3:
            self.set_reg(rd, (a * b) >> 32)
        elif funct3 == 0x4:
            self.set_reg(rd, div_s32(a, b))
        elif funct3 == 0x5:
            self.set_reg(rd, div_u32(a, b))
        elif funct3 == 0x6:
            self.set_reg(rd, rem_s32(a, b))
        elif funct3 == 0x7:
            self.set_reg(rd, rem_u32(a, b))
        else:
            self.unsupported(instr)

    def exec_system(self, funct3, rd, rs1, instr, next_pc):
        if instr == 0x00000073:
            raise UnsupportedInstruction("ecall encountered")
        if instr == 0x00100073:
            raise UnsupportedInstruction("ebreak encountered")
        if instr == 0x30200073:
            return self.csrs.get(0x341, 0) & MASK32

        csr = (instr >> 20) & 0xFFF
        old = self.csrs.get(csr, 0)
        if funct3 == 0x1:  # CSRRW
            self.csrs[csr] = self.get_reg(rs1)
        elif funct3 == 0x2:  # CSRRS
            if rs1 != 0:
                self.csrs[csr] = old | self.get_reg(rs1)
        elif funct3 == 0x3:  # CSRRC
            if rs1 != 0:
                self.csrs[csr] = old & (~self.get_reg(rs1) & MASK32)
        elif funct3 == 0x5:  # CSRRWI
            self.csrs[csr] = rs1
        elif funct3 == 0x6:  # CSRRSI
            if rs1 != 0:
                self.csrs[csr] = old | rs1
        elif funct3 == 0x7:  # CSRRCI
            if rs1 != 0:
                self.csrs[csr] = old & (~rs1 & MASK32)
        else:
            self.unsupported(instr)
        self.set_reg(rd, old)
        return next_pc

    def unsupported(self, instr):
        raise UnsupportedInstruction(
            "unsupported instruction 0x%08x at pc 0x%08x" % (instr & MASK32, self.pc & MASK32)
        )


def sext(value, bits):
    mask = (1 << bits) - 1
    value &= mask
    sign_bit = 1 << (bits - 1)
    return (value ^ sign_bit) - sign_bit


def to_s32(value):
    return sext(value, 32)


def imm_i(instr):
    return sext((instr >> 20) & 0xFFF, 12)


def imm_s(instr):
    return sext(((instr >> 25) << 5) | ((instr >> 7) & 0x1F), 12)


def imm_b(instr):
    raw = (
        ((instr >> 31) & 0x1) << 12
        | ((instr >> 7) & 0x1) << 11
        | ((instr >> 25) & 0x3F) << 5
        | ((instr >> 8) & 0xF) << 1
    )
    return sext(raw, 13)


def imm_j(instr):
    raw = (
        ((instr >> 31) & 0x1) << 20
        | ((instr >> 12) & 0xFF) << 12
        | ((instr >> 20) & 0x1) << 11
        | ((instr >> 21) & 0x3FF) << 1
    )
    return sext(raw, 21)


def div_s32(a, b):
    a_s = to_s32(a)
    b_s = to_s32(b)
    if b_s == 0:
        return MASK32
    if a == INT_MIN and b == MASK32:
        return INT_MIN
    q = abs(a_s) // abs(b_s)
    if (a_s < 0) != (b_s < 0):
        q = -q
    return q


def div_u32(a, b):
    if b == 0:
        return MASK32
    return a // b


def rem_s32(a, b):
    a_s = to_s32(a)
    b_s = to_s32(b)
    if b_s == 0:
        return a
    if a == INT_MIN and b == MASK32:
        return 0
    q = to_s32(div_s32(a, b))
    return a_s - (q * b_s)


def rem_u32(a, b):
    if b == 0:
        return a
    return a % b


def write_signature(cpu, output_path, start_word, word_count):
    lines = []
    for offset in range(word_count):
        word = cpu.read_u32((start_word + offset) * 4)
        lines.append("%08x" % word)
    Path(output_path).write_text("\n".join(lines) + ("\n" if lines else ""), encoding="ascii")


def write_json(path, data):
    Path(path).write_text(json.dumps(data, indent=2) + "\n", encoding="ascii")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--program-hex", required=True)
    parser.add_argument("--signature-start-word", type=int, required=True)
    parser.add_argument("--signature-words", type=int, required=True)
    parser.add_argument("--tohost-word", type=int, default=-1)
    parser.add_argument("--tohost-pass-pc", type=lambda x: int(x, 0), default=-1)
    parser.add_argument("--tohost-fail-pc", type=lambda x: int(x, 0), default=-1)
    parser.add_argument("--memory-words", type=int, default=131072)
    parser.add_argument("--max-cycles", type=int, default=250000)
    parser.add_argument("--output-signature", required=True)
    parser.add_argument("--output-json", required=True)
    args = parser.parse_args()

    cpu = ReferenceCpu(
        args.program_hex,
        args.memory_words,
        args.tohost_word,
        args.tohost_pass_pc,
        args.tohost_fail_pc,
    )

    status = "timeout"
    reason = "local reference timed out"
    termination = None

    try:
        while cpu.cycles < args.max_cycles:
            termination = cpu.termination()
            if termination is not None:
                if termination.startswith("pass"):
                    status = "pass"
                    reason = "local reference reached arch-test pass termination"
                else:
                    status = "fail"
                    reason = "local reference reached arch-test fail termination"
                break
            cpu.step()
        else:
            termination = cpu.termination()
            if termination is not None and termination.startswith("pass"):
                status = "pass"
                reason = "local reference reached arch-test pass termination"
    except UnsupportedInstruction as exc:
        status = "unsupported"
        reason = str(exc)

    if status == "pass":
        write_signature(cpu, args.output_signature, args.signature_start_word, args.signature_words)

    result = {
        "status": status,
        "reason": reason,
        "reference_kind": "local",
        "program_hex": args.program_hex,
        "signature_path": args.output_signature if status == "pass" else None,
        "signature_start_word": args.signature_start_word,
        "signature_words": args.signature_words,
        "tohost_word": args.tohost_word,
        "tohost_status": cpu.tohost_status(),
        "tohost_pass_pc": args.tohost_pass_pc,
        "tohost_fail_pc": args.tohost_fail_pc,
        "termination": termination,
        "cycles": cpu.cycles,
        "pc": cpu.pc,
        "claim_boundary": "local independent RV32IM signature reference only; not an official compliance result",
    }
    write_json(args.output_json, result)

    if status == "pass":
        return 0
    if status == "unsupported":
        return 2
    if status == "fail":
        return 3
    return 4


if __name__ == "__main__":
    sys.exit(main())
