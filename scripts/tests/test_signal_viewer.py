import csv
import importlib.util
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from signal_viewer import SignalSource, StreamSession, SignalPlot, Viewer, save_snapshot, arguments, PRESETS
from signal_console_check import Session


class FakeClient:
    """Independent FIR oracle behind the same client interface, only for tests."""
    def __init__(self):
        self.model = Session()
        self.commands = []
        self.closed = False
        self.port = self

    def close(self):
        self.closed = True

    def exchange(self, command, payload=b""):
        self.commands.append(command)
        if command == "C":
            length, scale, threshold = struct.unpack_from("<BBi", payload)
            self.model = Session()
            self.model.coefficients = list(struct.unpack_from(f"<{length}b", payload, 6))
            self.model.scale, self.model.threshold = scale, threshold
            result = self.model.status()
        elif command == "S":
            result = self.model.status()
        elif command == "D":
            values = list(struct.unpack(f"<{len(payload)//2}h", payload))
            result = self.model.data(values)
            result["compute_cycles"] = 1000
        else:
            raise ValueError(command)
        return {**result, "round_trip_ms": 10.0}


class ViewerLogicTests(unittest.TestCase):
    def test_source_repeatable_and_continuous_across_batches(self):
        for kind in ("sine", "step"):
            a, b = SignalSource(kind, 1000, 3), SignalSource(kind, 1000, 3)
            whole = a.take(512)
            chunks = sum((b.take(32) for _ in range(16)), [])
            self.assertEqual(whole, chunks)
            self.assertTrue(all(-2000 <= x <= 2000 for x in whole))

    def test_clean_source_and_bad_settings(self):
        data = SignalSource("sine", 0).take(129)
        self.assertEqual([data[n] for n in (0, 32, 64, 96, 128)], [0, 1000, 0, -1000, 0])
        self.assertEqual(SignalSource("step", 0).take(65), [-1000] * 64 + [1000])
        for kind, noise in (("bad", 0), ("sine", -1), ("step", 1001)):
            with self.assertRaises(ValueError):
                SignalSource(kind, noise)

    def test_all_presets_keep_bounded_history_and_check_counters(self):
        for preset in PRESETS:
            with self.subTest(preset=preset):
                client = FakeClient()
                session = StreamSession(client, preset, "sine", 300, 700, 1)
                for _ in range(20):
                    session.next_batch()
                session.check_status()
                self.assertEqual(session.total, 640)
                self.assertEqual(len(session.records), 512)
                self.assertEqual(session.records[0]["sample"], 128)
                self.assertEqual(session.records[-1]["sample"], 639)
                self.assertEqual(client.commands.count("S"), 3)
                if preset == "bypass":
                    self.assertTrue(all(r["input"] == r["output"] for r in session.records))

    def test_restart_resets_source_history_and_counters(self):
        client = FakeClient()
        first = StreamSession(client, "average4", "sine", 300, 700, 2)
        first.next_batch()
        expected = list(first.records)
        first.next_batch()
        second = StreamSession(client, "average4", "sine", 300, 700, 2)
        second.next_batch()
        self.assertEqual(list(second.records), expected)
        self.assertEqual(second.total, 32)

    def test_bad_response_stops_without_retry(self):
        client = FakeClient()
        session = StreamSession(client, "bypass", "step", 0, 700, 1)
        with patch.object(client, "exchange", side_effect=TimeoutError("test timeout")) as exchange:
            with self.assertRaises(TimeoutError):
                session.next_batch()
            self.assertEqual(exchange.call_count, 1)
        self.assertEqual(session.total, 0)
        self.assertFalse(session.records)
        with patch.object(client, "exchange", return_value={"outputs": []}):
            with self.assertRaises(ValueError):
                session.next_batch()
        with patch.object(client, "exchange", return_value={"uart_overrun": True}):
            with self.assertRaises(ValueError):
                session.check_status()

    def test_event_counter_mismatch_rejected(self):
        session = StreamSession(FakeClient(), "bypass", "step", 0, 700, 1)
        with patch.object(session.client, "exchange", return_value={
                "outputs": [0] * 32, "threshold_events": 1, "gpio": 1}):
            with self.assertRaises(ValueError):
                session.next_batch()
        self.assertEqual(session.total, 0)


@unittest.skipUnless(importlib.util.find_spec("matplotlib"), "install viewer plotting dependencies")
class ViewerPlotTests(unittest.TestCase):
    def test_export_matches_returned_data_and_overwrites(self):
        from matplotlib.backends.backend_agg import FigureCanvasAgg
        session = StreamSession(FakeClient(), "average4", "sine", 300, 700, 1)
        for _ in range(18):
            session.next_batch()
        plot = SignalPlot()
        FigureCanvasAgg(plot.figure)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "viewer"
            save_snapshot(session, plot, output, "fake-test-port")
            with output.with_suffix(".csv").open(encoding="utf-8", newline="") as stream:
                rows = list(csv.DictReader(stream))
            self.assertEqual(len(rows), 512)
            self.assertEqual(int(rows[0]["sample"]), 64)
            self.assertEqual([int(r["output"]) for r in rows], [r["output"] for r in session.records])
            metadata = json.loads(output.with_suffix(".json").read_text())
            self.assertEqual(metadata["status"], "captured")
            self.assertEqual(metadata["total_samples"], 576)
            self.assertEqual(list(plot.output_line.get_ydata()), [r["output"] for r in session.records])
            save_snapshot(session, plot, output, "fake-test-port")
            self.assertEqual(len(list(Path(directory).iterdir())), 3)
            with patch.object(plot.figure, "savefig", side_effect=OSError("disk unavailable")):
                with self.assertRaises(OSError):
                    save_snapshot(session, plot, output, "fake-test-port")
            self.assertFalse(output.with_suffix(".json").exists())

    def test_extreme_threshold_does_not_flatten_signal(self):
        session = StreamSession(FakeClient(), "bypass", "step", 0, 2000000000, 1)
        session.next_batch()
        plot = SignalPlot()
        plot.update(session)
        self.assertFalse(plot.threshold_line.get_visible())
        self.assertLess(plot.axes.get_ylim()[1], 3000)


@unittest.skipUnless(os.environ.get("CPU_VIEWER_GUI_TESTS") == "1", "set CPU_VIEWER_GUI_TESTS=1 for local Tk checks")
class ViewerGuiTests(unittest.TestCase):
    def wait_until(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while not predicate() and time.monotonic() < deadline:
            self.root.update()
            time.sleep(0.01)
        self.assertTrue(predicate())

    def test_start_pause_apply_and_close(self):
        import tkinter as tk
        self.root = tk.Tk()
        self.root.withdraw()
        client = FakeClient()
        try:
            with patch("signal_viewer.connect", return_value=client):
                viewer = Viewer(self.root, arguments(["--port", "fake-test-port"]))
                self.wait_until(lambda: viewer.session is not None and viewer.future is None)
                viewer.play_button.invoke()
                self.wait_until(lambda: viewer.session.total >= 64)
                viewer.play_button.invoke()
                self.wait_until(lambda: viewer.future is None)
                total = viewer.session.total
                self.root.geometry("880x660")
                self.root.deiconify()
                self.root.update()
                help_bottom = viewer.help_label.winfo_rooty() + viewer.help_label.winfo_height()
                self.assertLessEqual(help_bottom, self.root.winfo_rooty() + self.root.winfo_height())
                self.assertGreater(viewer.canvas.get_tk_widget().winfo_height(), 200)
                for _ in range(20):
                    self.root.update()
                    time.sleep(0.02)
                self.assertEqual(viewer.session.total, total)
                viewer.preset.set("difference")
                viewer.apply_button.invoke()
                self.wait_until(lambda: viewer.future is None and viewer.session.settings["preset"] == "difference")
                self.assertEqual(viewer.session.total, 0)
                viewer.close()
                self.wait_until(lambda: client.closed)
        finally:
            try:
                self.root.destroy()
            except tk.TclError:
                pass


if __name__ == "__main__":
    unittest.main()
