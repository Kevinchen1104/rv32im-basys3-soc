import binascii
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from signal_console import (Client, encode_frame, decode_frame, config_payload,
                            sample_payload, parse_response, request_frame, send_frame, boot, CHUNK_BYTES)


class FakePort:
    def __init__(self, data):
        self.data = bytearray(data)
        self.writes = bytearray()
        self.chunks = []

    def read(self, count):
        answer = bytes(self.data[:count])
        del self.data[:count]
        return answer

    def write(self, data):
        self.writes.extend(data)
        self.chunks.append(bytes(data))
        return len(data)


class SignalConsoleTests(unittest.TestCase):
    def test_incomplete_boot_write_is_not_success(self):
        data = struct.pack("<6I", 0x52564254, 1, 0, 1, 0x13, 0x13)
        packet = Mock()
        packet.read_bytes.return_value = data
        port = Mock()
        port.write.return_value = len(data) - 1
        with self.assertRaisesRegex(OSError, "incomplete boot"):
            boot(port, packet)
        port.read.assert_not_called()

    def test_crc_and_all_byte_values(self):
        self.assertEqual(binascii.crc_hqx(b"123456789", 0xffff), 0x29b1)
        data = bytes(range(256))
        self.assertEqual(decode_frame(encode_frame(data)), data)

    def test_bad_framing_and_checksum(self):
        valid = encode_frame(b"hello")
        for bad in (b"", valid[1:], valid[:-1], b"\x7e\x7d\x7e", b"\x7e\x7e\x00\x7e",
                    valid[:2] + bytes([valid[2] ^ 1]) + valid[3:]):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                decode_frame(bad)

    def test_argument_boundaries(self):
        self.assertEqual(len(sample_payload([-32768, 32767] * 16)), 64)
        self.assertEqual(len(config_payload([-128, 127], 15, -(1 << 31))), 8)
        for data in ([], [0] * 33, [-32769], [32768]):
            with self.assertRaises(ValueError):
                sample_payload(data)
        for coefficients, scale, threshold in (([], 0, 0), ([0] * 9, 0, 0), ([128], 0, 0),
                                                ([1], 16, 0), ([1], 0, 1 << 31)):
            with self.assertRaises(ValueError):
                config_payload(coefficients, scale, threshold)

    def test_client_ack_sequence_and_response(self):
        request = request_frame(0, "D", sample_payload([-8, 12]))
        payload = bytes([2]) + struct.pack("<IIIii", 100, 1, 1, -2, 1)
        response = encode_frame(bytes([0, ord("D"), 0, len(payload)]) + payload)
        port = FakePort(b"\x06" * (1 + (len(request) - 2) // CHUNK_BYTES + 1) + response)
        result = Client(port).exchange("D", sample_payload([-8, 12]))
        self.assertEqual(bytes(port.writes), request)
        self.assertEqual(result["outputs"], [-2, 1])
        self.assertEqual(result["compute_cycles"], 100)
        with self.assertRaises(ValueError):
            parse_response(response, 1, "D")

    def test_burst_boundaries_and_escape_bytes(self):
        for length in (1, 31, 32, 33, 63, 64, 128):
            wire = encode_frame(bytes([0x7d, 0x7e]) * length)
            count = 1 + (len(wire) - 2) // CHUNK_BYTES + 1
            port = FakePort(b"\x06" * count)
            send_frame(port, wire)
            self.assertEqual(bytes(port.writes), wire)
            self.assertEqual(len(port.chunks), count)
            self.assertEqual(port.chunks[0], b"\x7e")
            self.assertTrue(all(len(chunk) <= CHUNK_BYTES for chunk in port.chunks))
            self.assertFalse(port.data)

    def test_missing_burst_ack_does_not_send_remainder(self):
        wire = encode_frame(bytes(range(100)))
        port = FakePort(b"\x06?")
        with self.assertRaises(ValueError):
            send_frame(port, wire)
        self.assertEqual(port.writes, wire[:33])

    def test_reject_short_write_and_multiple_frames(self):
        class ShortPort(FakePort):
            def write(self, data):
                return 0
        with self.assertRaises(OSError):
            send_frame(ShortPort(b""), b"\x7e")
        for wire in (b"", b"x", b"\x7ex", b"\x7e\x7e\x7e"):
            with self.assertRaises(ValueError):
                send_frame(FakePort(b""), wire)

    def test_missing_ack_aborts_without_retry(self):
        port = FakePort(b"?")
        with self.assertRaises(ValueError):
            Client(port).exchange("S")
        self.assertEqual(port.writes, b"\x7e")
        with self.assertRaises(TimeoutError):
            Client(FakePort(b"")).exchange("S")

    def test_rejected_command_and_short_payload(self):
        for body in (bytes([1, ord("S"), 2, 0]), bytes([1, ord("S"), 0, 0]),
                     bytes([1, ord("D"), 0, 1, 1])):
            with self.assertRaises(ValueError):
                parse_response(encode_frame(body), 1, chr(body[1]))


if __name__ == "__main__":
    unittest.main()
