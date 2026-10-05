"""Interactive UART client for the CPU's integer FIR firmware."""
import argparse
import binascii
from pathlib import Path
import struct
import time
from result_json import format_result_json

DELIMITER = 0x7e
ESCAPE = 0x7d
ACK = b"\x06"
MAX_SAMPLES = 32
CHUNK_BYTES = 32


def encode_frame(body):
    data = body + struct.pack("<H", binascii.crc_hqx(body, 0xffff))
    wire = bytearray([DELIMITER])
    for byte in data:
        if byte in (DELIMITER, ESCAPE):
            wire.extend((ESCAPE, byte ^ 0x20))
        else:
            wire.append(byte)
    wire.append(DELIMITER)
    return bytes(wire)


def decode_frame(wire):
    if len(wire) < 4 or wire[0] != DELIMITER or wire[-1] != DELIMITER:
        raise ValueError("missing frame delimiters")
    data = bytearray()
    escaped = False
    for byte in wire[1:-1]:
        if byte == DELIMITER:
            raise ValueError("unexpected frame delimiter")
        if escaped:
            data.append(byte ^ 0x20)
            escaped = False
        elif byte == ESCAPE:
            escaped = True
        else:
            data.append(byte)
    if escaped or len(data) < 2:
        raise ValueError("truncated frame")
    body = bytes(data[:-2])
    if binascii.crc_hqx(body, 0xffff) != int.from_bytes(data[-2:], "little"):
        raise ValueError("frame CRC mismatch")
    return body


def request_frame(sequence, command, payload=b""):
    if len(payload) > 128:
        raise ValueError("request payload exceeds 128 bytes")
    return encode_frame(bytes((sequence, ord(command), len(payload))) + payload)


def config_payload(coefficients, scale, threshold):
    if not 1 <= len(coefficients) <= 8 or any(not -128 <= c <= 127 for c in coefficients):
        raise ValueError("use 1..8 coefficients, each -128..127")
    if not 0 <= scale <= 15 or not -(1 << 31) <= threshold < (1 << 31):
        raise ValueError("scale must be 0..15; threshold must fit signed 32 bits")
    return struct.pack("<BBi", len(coefficients), scale, threshold) + struct.pack(
        f"<{len(coefficients)}b", *coefficients)


def sample_payload(samples):
    if not 1 <= len(samples) <= MAX_SAMPLES or any(not -32768 <= x <= 32767 for x in samples):
        raise ValueError("send 1..32 integer samples, each -32768..32767")
    return struct.pack(f"<{len(samples)}h", *samples)


def parse_response(wire, sequence, command):
    body = decode_frame(wire)
    if len(body) < 4 or body[:2] != bytes((sequence, ord(command))) or len(body) != body[3] + 4:
        raise ValueError("response identity or length mismatch")
    if body[2]:
        errors = {1: "invalid frame or CRC", 2: "invalid arguments", 3: "unknown command"}
        raise ValueError(f"device rejected command: {errors.get(body[2], body[2])}")
    payload = body[4:]
    if command == "D":
        if len(payload) < 13 or len(payload) != 13 + payload[0] * 4:
            raise ValueError("invalid data response")
        count = payload[0]
        cycles, events, gpio = struct.unpack_from("<III", payload, 1)
        return {"outputs": list(struct.unpack_from(f"<{count}i", payload, 13)),
                "compute_cycles": cycles, "threshold_events": events, "gpio": gpio}
    if len(payload) < 31 or payload[0] != 2 or not 1 <= payload[1] <= 8 or len(payload) != 31 + payload[1]:
        raise ValueError("unsupported or malformed status response")
    threshold, samples, events, gpio, switches, uart_status, batch_limit = struct.unpack_from("<i6I", payload, 3)
    return {"coefficients": list(struct.unpack_from(f"<{payload[1]}b", payload, 31)),
            "scale": payload[2], "threshold": threshold, "samples_processed": samples,
            "threshold_events": events, "gpio": gpio, "switches": switches,
            "uart_overrun": bool(uart_status & 4), "batch_limit": batch_limit}


def read_byte(port):
    value = port.read(1)
    if len(value) != 1:
        raise TimeoutError("UART timeout; check the port, board program, and reset state")
    return value


def send_frame(port, wire):
    """Send a delimiter, then bounded bursts; stop immediately on missing credit."""
    if not wire or wire[0] != DELIMITER or (len(wire) > 1 and
            (wire[-1] != DELIMITER or DELIMITER in wire[1:-1])):
        raise ValueError("send one delimited frame at a time")
    chunks = [wire[:1]] + [wire[i:i + CHUNK_BYTES] for i in range(1, len(wire), CHUNK_BYTES)]
    for chunk in chunks:
        if port.write(chunk) != len(chunk):
            raise OSError("incomplete UART write; reset and reload before retrying")
        if read_byte(port) != ACK:
            raise ValueError("missing burst ACK; reconnect before sending more commands")


def receive_frame(port):
    wire = bytearray(read_byte(port))
    if wire[0] != DELIMITER:
        raise ValueError("missing response start; use the FIR2 firmware and FIFO bitstream")
    while len(wire) <= 324:
        wire.extend(read_byte(port))
        if wire[-1] == DELIMITER:
            return bytes(wire)
    raise ValueError("response exceeds maximum frame size")


class Client:
    def __init__(self, port):
        self.port = port
        self.sequence = 0

    def exchange(self, command, payload=b""):
        start = time.perf_counter()
        sequence = self.sequence
        self.sequence = (sequence + 1) & 255
        send_frame(self.port, request_frame(sequence, command, payload))
        result = parse_response(receive_frame(self.port), sequence, command)
        result["round_trip_ms"] = round((time.perf_counter() - start) * 1000, 3)
        return result

    def synchronize(self):
        # Finish any abandoned frame, then discard its error response. No command
        # is retried automatically: D changes the filter's history.
        self.port.reset_input_buffer()
        send_frame(self.port, bytes([DELIMITER]))
        previous_timeout = self.port.timeout
        self.port.timeout = 0.25
        try:
            while self.port.read(256):
                pass
        finally:
            self.port.timeout = previous_timeout
        return self.exchange("S")


def boot(port, packet_path):
    data = packet_path.read_bytes()
    if len(data) < 24:
        raise ValueError("boot packet is too short")
    magic, version, start, words, checksum = struct.unpack_from("<5I", data)
    if magic != 0x52564254 or version != 1 or start != 0 or not 1 <= words <= 1024 or len(data) != 20 + 4 * words:
        raise ValueError("invalid boot packet header")
    if sum(struct.unpack_from(f"<{words}I", data, 20)) & 0xffffffff != checksum:
        raise ValueError("boot packet checksum mismatch")
    port.reset_input_buffer()
    if port.write(data) != len(data):
        raise OSError("incomplete boot packet write; reset the board before retrying")
    port.flush()
    greeting = b"".join(read_byte(port) for _ in range(5))
    if greeting != b"FIR2\n":
        raise ValueError(f"unexpected firmware greeting: {greeting!r}")


def shell(client):
    print("Commands: status | config SCALE THRESHOLD COEFF... | data SAMPLE... | clear | led VALUE | quit")
    while True:
        try:
            words = input("cpu> ").split()
        except EOFError:
            return
        if not words:
            continue
        command, *arguments = words
        if command == "quit":
            return
        try:
            values = [int(value, 0) for value in arguments]
            if command == "status" and not values:
                operation, payload = "S", b""
            elif command == "clear" and not values:
                operation, payload = "R", b""
            elif command == "config" and len(values) >= 3:
                operation, payload = "C", config_payload(values[2:], values[0], values[1])
            elif command == "data":
                operation, payload = "D", sample_payload(values)
            elif command == "led" and len(values) == 1 and 0 <= values[0] <= 255:
                operation, payload = "L", bytes(values)
            else:
                raise ValueError("unknown command or wrong arguments")
        except ValueError as error:
            print(error)
            continue
        # Transport/protocol failures end the session. Never replay a possibly
        # completed data command: that would advance the FIR history twice.
        result = client.exchange(operation, payload)
        print(format_result_json(result), end="")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True, help="e.g. COM5 or /dev/ttyUSB1")
    parser.add_argument("--boot", type=Path, help="send firmware after pressing the board reset button")
    args = parser.parse_args()
    try:
        import serial
    except ImportError:
        parser.error("install pyserial: python -m pip install pyserial")
    try:
        with serial.Serial(args.port, 115200, timeout=3, write_timeout=3) as port:
            client = Client(port)
            if args.boot:
                boot(port, args.boot)
            print(format_result_json(client.synchronize()), end="")
            shell(client)
    except (OSError, TimeoutError, ValueError, KeyboardInterrupt) as error:
        raise SystemExit(str(error))


if __name__ == "__main__":
    main()
