from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import signal_start
import signal_console_check
from signal_console_check import check_viewer_case
from test_signal_viewer import FakeClient


class StartupTests(unittest.TestCase):
    def setUp(self):
        self.port = SimpleNamespace(device="COM3", vid=0x0403, pid=0x6010,
                                    description="test", hwid="test")

    def test_port_selection_does_not_guess_among_boards(self):
        self.assertEqual(signal_start.select_port(None, [self.port]), "COM3")
        self.assertEqual(signal_start.select_port("com3", [self.port]), "COM3")
        other = SimpleNamespace(device="COM4", vid=0x0403, pid=0x6010)
        for requested, ports in ((None, []), (None, [self.port, other]), ("COM5", [self.port])):
            with self.assertRaises(ValueError):
                signal_start.select_port(requested, ports)

    def test_preflight_never_opens_uart_or_programs(self):
        with patch("serial.tools.list_ports.comports", return_value=[self.port]), \
                patch("serial.Serial") as serial, patch("signal_start.program_image") as program:
            signal_start.main(["--check"])
            serial.assert_not_called()
            program.assert_not_called()

    def test_probe_failure_does_not_upload_or_program(self):
        with patch("serial.tools.list_ports.comports", return_value=[self.port]), \
                patch("signal_viewer.connect", side_effect=TimeoutError("test")) as connect, \
                patch("signal_start.program_image") as program:
            with self.assertRaises(TimeoutError):
                signal_start.main(["--probe"])
            connect.assert_called_once_with("COM3", None)
            program.assert_not_called()

    def test_explicit_program_precedes_upload_and_probe(self):
        client = FakeClient()
        with patch("serial.tools.list_ports.comports", return_value=[self.port]), \
                patch("signal_start.firmware_ready"), \
                patch("signal_start.application_image", return_value=Path("test.bit")), \
                patch("signal_start.shutil.which", return_value="xsdb"), \
                patch("signal_start.program_image") as program, \
                patch("signal_viewer.connect", return_value=client) as connect:
            signal_start.main(["--program", "--probe"])
            program.assert_called_once_with(Path("test.bit"), "xsdb")
            connect.assert_called_once_with("COM3", signal_start.PACKET)
            self.assertTrue(client.closed)

    def test_failed_program_never_uploads(self):
        with patch("serial.tools.list_ports.comports", return_value=[self.port]), \
                patch("signal_start.firmware_ready"), \
                patch("signal_start.application_image", return_value=Path("test.bit")), \
                patch("signal_start.shutil.which", return_value="xsdb"), \
                patch("signal_start.program_image", side_effect=RuntimeError("JTAG failed")), \
                patch("signal_viewer.connect") as connect:
            with self.assertRaises(RuntimeError):
                signal_start.main(["--program", "--probe"])
            connect.assert_not_called()

    def test_alternative_build_uses_its_own_identity(self):
        client = FakeClient()
        summary = Path("results/timing/icache-banked1024.json").resolve()
        with patch("serial.tools.list_ports.comports", return_value=[self.port]), \
                patch("signal_start.firmware_ready"), \
                patch("signal_start.application_image", return_value=Path("candidate.bit")) as image, \
                patch("signal_start.shutil.which", return_value="xsdb"), \
                patch("signal_start.program_image") as program, \
                patch("signal_viewer.connect", return_value=client):
            signal_start.main(["--program", "--probe", "--build-summary", str(summary)])
            image.assert_called_once_with(summary)
            program.assert_called_once_with(Path("candidate.bit"), "xsdb", timing_path=summary)

    def test_physical_viewer_checker_rejects_wrong_sample(self):
        client = FakeClient()
        result = check_viewer_case(client, "difference", "step", 20)
        self.assertEqual(result["samples_checked"], 640)
        self.assertEqual(result["status"], "passed")
        original = client.exchange

        def corrupt(command, payload=b""):
            result = original(command, payload)
            if command == "D":
                result["outputs"][0] += 1
            return result

        with patch.object(client, "exchange", side_effect=corrupt):
            with self.assertRaisesRegex(RuntimeError, "viewer output mismatch"):
                check_viewer_case(client, "average4", "sine", 1)

    def test_physical_cache_selection_checks_simulation_before_programming(self):
        geometry = {"ICACHE_BYTES": 1024, "ICACHE_PARALLEL_LOOKUP": 0, "DCACHE_BYTES": 128, "DCACHE_VICTIM_LINES": 0}
        timing = {key.lower(): value for key, value in geometry.items()}
        for simulated in (False, True):
            saved = {"status": "passed", "sessions": [{"profile": "fast_cpu", "cache": geometry}] if simulated else []}
            with self.subTest(simulated=simulated), \
                    patch("signal_console_check.RunLock"), \
                    patch("signal_console_check.json.loads", side_effect=[timing, saved]), \
                    patch("pathlib.Path.read_text", return_value="fixture"), \
                    patch("signal_console_check.sha256", return_value="hash"), \
                    patch("signal_start.firmware_ready"), \
                    patch("signal_start.application_image", return_value=Path("fixture.bit")), \
                    patch("signal_start.program_image") as program, \
                    patch("signal_console_check.physical_session") as physical:
                args = ["--port", "COM3", "--program", "--session", "capacity-dm128"]
                if simulated:
                    signal_console_check.main(args)
                    program.assert_called_once()
                    self.assertEqual(physical.call_args.args[3], geometry)
                    self.assertEqual(physical.call_args.args[4]["cache"], geometry)
                else:
                    with self.assertRaisesRegex(RuntimeError, "simulation"):
                        signal_console_check.main(args)
                    program.assert_not_called()
                    physical.assert_not_called()


if __name__ == "__main__":
    unittest.main()
