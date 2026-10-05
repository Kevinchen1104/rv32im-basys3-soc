import sys
from pathlib import Path
import unittest
import tempfile
import json
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from board_matvec import parse_transcript, ROWS, JOBS, SCENARIOS, workload
import board_matvec as flow


def transcript():
    lines = ['B 00000001']
    for reuse in range(2):
        for rows in ROWS:
            for jobs in JOBS:
                expected = workload(rows, jobs, SCENARIOS[reuse])[2]
                for method in range(3):
                    fields = [reuse, rows, jobs, method, 123, *expected]
                    lines.append('M ' + ' '.join(f'{v:08x}' for v in fields))
    return '\n'.join([*lines, 'E 0000005a']) + '\n'


class BoardMatvecTests(unittest.TestCase):
    def test_compile_failure_invalidates_previous_comparison(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "simulation"
            output.mkdir()
            (output / "comparison.json").write_text('{"status":"passed"}')
            (output / "uart.txt").write_text("old transcript")
            with patch.object(flow, "RESULTS", root), patch.object(flow, "find_tool", return_value="tool"), \
                    patch.object(flow, "run", side_effect=RuntimeError("compile failed")):
                with self.assertRaisesRegex(RuntimeError, "compile failed"):
                    flow.simulate()
            result = json.loads((output / "comparison.json").read_text())
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["error"], "compile failed")
            self.assertFalse((output / "uart.txt").exists())

    def test_complete(self):
        rows = parse_transcript(transcript())
        self.assertEqual(len(rows), 90)
        self.assertEqual(sum(r['outputs_checked'] for r in rows), 2418)

    def test_missing_case(self):
        lines = transcript().splitlines()
        del lines[1]
        with self.assertRaises(ValueError):
            parse_transcript('\n'.join(lines))

    def test_duplicate(self):
        lines = transcript().splitlines()
        lines[2] = lines[1]
        with self.assertRaises(ValueError):
            parse_transcript('\n'.join(lines))

    def test_wrong_result(self):
        lines = transcript().splitlines()
        fields = lines[1].split()
        fields[-1] = 'ffffffff'
        lines[1] = ' '.join(fields)
        with self.assertRaises(ValueError):
            parse_transcript('\n'.join(lines))

    def test_zero_cycles(self):
        with self.assertRaises(ValueError):
            parse_transcript(transcript().replace('0000007b', '00000000'))

    def test_missing_completion(self):
        with self.assertRaises(ValueError):
            parse_transcript(transcript().replace('E 0000005a', ''))


if __name__ == '__main__':
    unittest.main()
