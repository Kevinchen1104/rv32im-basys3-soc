"""Check the compiled-program comparator and its external-model setup."""

import importlib.util
from pathlib import Path
import struct
import sys
import tempfile
import subprocess
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import compiled_programs as flow
from execution_context import RunLock, parse_symbols, selection_context


class ExecutionContextTests(unittest.TestCase):
    def test_complete_and_reordered_selections(self):
        self.assertEqual(selection_context(([2, 1, 2], ['b', 'a']), ([1, 2], ['a', 'b'])), '')
        self.assertEqual(selection_context(([1, 1], ['b']), ([1, 2], ['a', 'b'])),
                         selection_context(([1], ['b']), ([1, 2], ['a', 'b'])))

    def test_subsets_are_separate(self):
        self.assertNotEqual(selection_context(([1],), ([1, 2],)), selection_context(([2],), ([1, 2],)))

    def test_lock_rejects_overlap_and_releases(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'running.lock'
            first = RunLock(path)
            try:
                with self.assertRaises(RuntimeError):
                    RunLock(path)
            finally:
                first.close()
            second = RunLock(path)
            second.close()

    def test_lock_released_after_process_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'running.lock'
            helper = str(Path(flow.__file__).parent)
            code = "import sys,os; sys.path.insert(0,sys.argv[1]); from pathlib import Path; from execution_context import RunLock; lock=RunLock(Path(sys.argv[2])); os._exit(0)"
            subprocess.run([sys.executable, '-c', code, helper, str(path)], check=True)
            lock = RunLock(path)
            lock.close()

    def test_symbol_parser(self):
        self.assertEqual(parse_symbols('000001a0 T main\n U missing\nnothex T x\n'), {'main': 0x1a0})


class SimulatorPathTests(unittest.TestCase):
    def test_unicode_checkout_uses_relative_filename(self):
        root = Path("workspace") / "\u4e2d\u6587 checkout"
        with patch.object(flow, "ROOT", root):
            self.assertEqual(flow.simulator_file(root / "build/image.hex"), "build/image.hex")
            self.assertEqual(flow.simulator_file(root / "results/memory.hex"), "results/memory.hex")

    def test_external_filename_is_rejected(self):
        with patch.object(flow, "ROOT", Path("project")):
            with self.assertRaises(ValueError):
                flow.simulator_file(Path("outside/image.hex"))


class ComparatorTests(unittest.TestCase):
    def test_equal_trace(self):
        trace = [(0, 0x00700093, 33, 7)]
        flow.compare_trace(trace, trace)

    def test_no_write_ignores_payload(self):
        flow.compare_trace([(0, 0x0000006F, 0, 0)], [(0, 0x0000006F, 7, 123)])

    def test_reject_changed_pc_instruction_destination_or_value(self):
        expected = [(0, 0x00700093, 33, 7)]
        for field in range(4):
            with self.subTest(field=field):
                corrupted = list(expected[0])
                corrupted[field] ^= 1
                with self.assertRaisesRegex(RuntimeError, "retirement 0"):
                    flow.compare_trace(expected, [tuple(corrupted)])

    def test_reject_changed_write_enable(self):
        with self.assertRaisesRegex(RuntimeError, "retirement 0"):
            flow.compare_trace([(0, 0x00700093, 33, 7)], [(0, 0x00700093, 1, 7)])

    def test_reject_missing_or_extra_retirements(self):
        row = (0, 0x0000006F, 0, 0)
        for expected, actual in (([row], []), ([row], [row, row])):
            with self.assertRaisesRegex(RuntimeError, "retired count"):
                flow.compare_trace(expected, actual)

    def test_memory_compare_checks_every_byte(self):
        flow.compare_memory(b"\x00\x01\xff", b"\x00\x01\xff")
        with self.assertRaisesRegex(RuntimeError, "0x3002"):
            flow.compare_memory(b"\x00\x01\xff", b"\x00\x01\xfe")
        with self.assertRaisesRegex(RuntimeError, "length"):
            flow.compare_memory(b"\x00", b"")

    def test_algorithm_answers(self):
        self.assertEqual(flow.expected_signature("arithmetic")[3:8],
                         [(-12727) & flow.MASK32, (-48) & flow.MASK32,
                          0xFFFFFFFA, 1431655764, 2])
        self.assertEqual(flow.expected_signature("matvec")[:4],
                         [(-78) & flow.MASK32, 1030, 312, (-133) & flow.MASK32])
        for case in flow.CASES:
            self.assertEqual(len(flow.expected_signature(case)), 16)


class ProcessTests(unittest.TestCase):
    def setUp(self):
        directory = flow.ROOT / "build/tests"
        directory.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="compiled-programs-", dir=directory)
        self.addCleanup(self.temporary.cleanup)
        self.log = Path(self.temporary.name) / "process.log"

    def test_failed_command_keeps_output(self):
        with self.assertRaisesRegex(RuntimeError, "exited 3"):
            flow.run([sys.executable, "-c", "print('diagnostic'); raise SystemExit(3)"], self.log)
        self.assertIn("diagnostic", self.log.read_text(encoding="utf-8"))
        self.assertIn("Exit code: 3", self.log.read_text(encoding="utf-8"))

    def test_timeout_keeps_output(self):
        with self.assertRaisesRegex(RuntimeError, "timed out"):
            flow.run([sys.executable, "-c", "import time; print('started', flush=True); time.sleep(10)"],
                     self.log, timeout=1)
        self.assertIn("started", self.log.read_text(encoding="utf-8"))
        self.assertIn("TIMEOUT", self.log.read_text(encoding="utf-8"))

    def test_missing_tool_is_recorded(self):
        with self.assertRaisesRegex(RuntimeError, "could not start"):
            flow.run([str(Path(self.temporary.name) / "missing-tool")], self.log)
        self.assertIn("START FAILED", self.log.read_text(encoding="utf-8"))

    def test_inherited_pipe_timeout_is_recorded(self):
        code = "import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time; time.sleep(8)']); print('parent',flush=True)"
        started = time.monotonic()
        with self.assertRaisesRegex(RuntimeError, 'timed out'):
            flow.run([sys.executable, '-c', code], self.log, timeout=1)
        self.assertLess(time.monotonic() - started, 5)
        self.assertIn('Result: timed_out', self.log.read_text(encoding='utf-8'))


@unittest.skipUnless(importlib.util.find_spec("unicorn"), "install the optional Unicorn dependency")
class ReferenceTests(unittest.TestCase):
    @staticmethod
    def image(words):
        image = bytearray(flow.MEMORY_BYTES)
        for index, word in enumerate(words):
            struct.pack_into("<I", image, 4 * index, word)
        return bytes(image)

    def test_reset_pc_and_post_instruction_register_value(self):
        # addi x1,x0,7; addi a0,x0,0; j .
        trace, memory = flow.run_reference(self.image([0x00700093, 0x00000513, 0x0000006F]), 8, 0x1000)
        self.assertEqual(trace, [(0, 0x00700093, 33, 7),
                                 (4, 0x00000513, 42, 0), (8, 0x0000006F, 0, 0)])
        self.assertEqual(len(memory), 4096)

    def test_reference_rejects_mmio_access(self):
        with self.assertRaisesRegex(RuntimeError, "outside aligned RAM"):
            flow.run_reference(self.image([0x00002083]), 4, 0x1000)

    def test_reference_rejects_unsupported_instruction(self):
        with self.assertRaisesRegex(RuntimeError, "outside compiled-program profile"):
            flow.run_reference(self.image([0x00000073]), 4, 0x1000)

    def test_reference_rejects_nonterminating_program(self):
        with self.assertRaisesRegex(RuntimeError, "instruction limit"):
            flow.run_reference(self.image([0x0000006F]), 4, 0x1000, max_instructions=5)

    def test_reference_rejects_nonzero_main_status(self):
        with self.assertRaisesRegex(RuntimeError, "nonzero status"):
            flow.run_reference(self.image([0x00100513, 0x0000006F]), 4, 0x1000)


if __name__ == "__main__":
    unittest.main()
