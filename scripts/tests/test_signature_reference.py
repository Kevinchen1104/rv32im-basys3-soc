"""Test the local signature model's input and RAM boundaries."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


PATH = Path(__file__).resolve().parents[2] / 'tools/arch-test/rv32im_signature_ref.py'
SPEC = importlib.util.spec_from_file_location('signature_reference', PATH)
reference = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reference)


class SignatureReferenceTests(unittest.TestCase):
    def test_invalid_program_cannot_leave_previous_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            program = root / 'program.hex'
            signature = root / 'signature.txt'
            result = root / 'result.json'
            signature.write_text('00000000\n')
            result.write_text('{"status": "pass"}')
            program.write_text('100000000\n')
            code = reference.main(['--program-hex', str(program), '--signature-start-word', '0',
                                   '--signature-words', '1', '--output-signature', str(signature),
                                   '--output-json', str(result)])
            self.assertEqual(code, 3)
            self.assertEqual(json.loads(result.read_text())['status'], 'fail')
            self.assertFalse(signature.exists())

    def test_ram_limits_and_unsigned_words(self):
        with tempfile.TemporaryDirectory() as directory:
            program = Path(directory) / 'program.hex'
            program.write_text('ffffffff\n')
            cpu = reference.ReferenceCpu(program, 2, -1, -1, -1)
            self.assertEqual(cpu.read_u32(0), 0xffffffff)
            cpu.write_u32(4, 0x80000001)
            self.assertEqual(cpu.read_u32(4), 0x80000001)
            for address in (-1, 8, 0x100000000):
                with self.subTest(address=address):
                    with self.assertRaises(reference.UnsupportedInstruction):
                        cpu.read_u8(address)
                    with self.assertRaises(reference.UnsupportedInstruction):
                        cpu.write_u8(address, 1)


if __name__ == '__main__':
    unittest.main()
