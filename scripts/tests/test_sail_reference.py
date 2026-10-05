from pathlib import Path
import struct
import sys
import unittest
import tempfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sail_reference import compare_signatures, matching_elf, parse_config
import sail_reference


class SailReferenceTests(unittest.TestCase):
    def elf(self, payload, flags=5):
        data = bytearray(128) + payload
        data[:7] = b"\x7fELF\x01\x01\x01"
        struct.pack_into("<I", data, 28, 52)
        struct.pack_into("<HH", data, 42, 32, 1)
        struct.pack_into("<8I", data, 52, 1, 128, 0, 0, len(payload), len(payload), flags, 4)
        return bytes(data)

    def test_padding_normalization_preserves_symbols_and_nonzero_words(self):
        source = self.elf(b"\x93\x00\x10\x00" + bytes(4)) + b"symbols"
        image = b"\x93\x00\x10\x00\x13\x00\x00\x00"
        result, count = matching_elf(source, image)
        self.assertEqual(result[:128], source[:128])
        self.assertEqual(result[128:136], image)
        self.assertEqual(result[136:], b"symbols")
        self.assertEqual(count, 1)

    def test_reject_nonpadding_code_or_data_changes(self):
        for source, image in ((self.elf(bytes(4)), b"\x93\x00\x10\x00"),
                              (self.elf(bytes(4), flags=6), b"\x13\x00\x00\x00"),
                              (self.elf(bytes(4)), bytes(2))):
            with self.subTest(source=source[-4:], image=image), self.assertRaises(ValueError):
                matching_elf(source, image)

    def test_signature_check_rejects_empty_missing_corrupt_and_mismatch(self):
        compare_signatures(["00000013"], ["00000013"], 1)
        for expected, actual, words in (([], [], 0), (["00000013"], [], 1),
                                        (["00000013"], ["00000014"], 1), (["unknown"], ["unknown"], 1)):
            with self.subTest(actual=actual), self.assertRaises(RuntimeError):
                compare_signatures(expected, actual, words)

    def test_model_json_comments_do_not_modify_strings(self):
        value = parse_config('{"url": "https://example.test/", // comment\n "text": ",}", "list": [1,2,],}')
        self.assertEqual(value, {"url": "https://example.test/", "text": ",}", "list": [1, 2]})

    def test_diagnostic_failure_preserves_complete_summary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "results/arch-test/sail"
            output.mkdir(parents=True)
            summary = output / "summary.json"
            summary.write_text('{"status":"passed","marker":"complete"}')
            before = summary.read_bytes()
            with patch.object(sail_reference, "ROOT", root), \
                    patch.object(sail_reference, "run", side_effect=RuntimeError("missing model")):
                with self.assertRaisesRegex(RuntimeError, "missing model"):
                    sail_reference.main(["--case", "../single-case"])
            self.assertEqual(summary.read_bytes(), before)
            diagnostics = list(output.glob("subset-*/summary.json"))
            self.assertEqual(len(diagnostics), 1)
            self.assertIn('"status": "failed"', diagnostics[0].read_text())


if __name__ == "__main__":
    unittest.main()
