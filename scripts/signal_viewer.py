"""Live input/output plots for the FIR program running on the FPGA CPU."""
import argparse
from collections import deque
from concurrent.futures import ThreadPoolExecutor
import csv
from datetime import datetime, timezone
import hashlib
import math
from pathlib import Path
import random
import sys
import time

from result_json import write_result_json
from signal_console import Client, boot, config_payload, sample_payload

PRESETS = {"bypass": ([1], 0), "average4": ([1] * 4, 2),
           "average8": ([1] * 8, 3), "difference": ([1, -1], 0)}
WINDOW = 512
BATCH = 32
INTERVAL = 0.125
DEFAULT_OUTPUT = Path(__file__).resolve().parents[1] / "results/signal-console/viewer"


class SignalSource:
    """Generate reproducible integer input; never calculate the plotted output."""
    def __init__(self, kind="sine", noise=300, seed=1):
        if kind not in ("sine", "step") or not 0 <= noise <= 1000:
            raise ValueError("source must be sine/step and noise must be 0..1000")
        self.kind, self.noise = kind, noise
        self.random = random.Random(seed)
        self.index = 0

    def take(self, count=BATCH):
        values = []
        for _ in range(count):
            n = self.index
            clean = (1000 * math.sin(2 * math.pi * n / 128) if self.kind == "sine"
                     else (1000 if (n // 64) % 2 else -1000))
            values.append(round(clean) + self.random.randint(-self.noise, self.noise))
            self.index += 1
        return values


class StreamSession:
    def __init__(self, client, preset, source, noise, threshold, seed):
        if preset not in PRESETS:
            raise ValueError("unknown filter preset")
        coefficients, scale = PRESETS[preset]
        payload = config_payload(coefficients, scale, threshold)
        self.source = SignalSource(source, noise, seed)
        self.settings = dict(preset=preset, coefficients=coefficients, scale=scale,
                             source=source, noise=noise, threshold=threshold, seed=seed)
        self.client = client
        self.device = client.exchange("C", payload)
        if (self.device["coefficients"] != coefficients or self.device["scale"] != scale or
                self.device["threshold"] != threshold or self.device["uart_overrun"] or
                self.device["samples_processed"] != 0 or self.device["threshold_events"] != 0):
            raise ValueError("device configuration or UART status mismatch")
        self.records = deque(maxlen=WINDOW)
        self.total = 0
        self.events = 0
        self.batches = 0
        self.last = None

    def next_batch(self):
        values = self.source.take()
        result = self.client.exchange("D", sample_payload(values))
        if len(result["outputs"]) != len(values):
            raise ValueError("device returned a different sample count")
        events = sum(value >= self.settings["threshold"] for value in result["outputs"])
        if result["threshold_events"] != events or (result["gpio"] & 1) != bool(events):
            raise ValueError("device event count or event LED mismatch")
        for offset, (value, output) in enumerate(zip(values, result["outputs"])):
            self.records.append({"sample": self.total + offset, "input": value, "output": output})
        self.total += len(values)
        self.events += result["threshold_events"]
        self.batches += 1
        self.last = result
        # Read actual counters and overrun status approximately once per second.
        if self.batches % 8 == 0:
            self.check_status()
        return result

    def check_status(self):
        self.device = self.client.exchange("S")
        if (self.device["uart_overrun"] or
                self.device["samples_processed"] != self.total % (1 << 32) or
                self.device["threshold_events"] != self.events % (1 << 32)):
            raise ValueError("device counters changed or UART overrun; stop and reconnect")


class SignalPlot:
    """One shared renderer for the live window and saved PNG."""
    def __init__(self):
        from matplotlib import rcParams
        from matplotlib.figure import Figure
        rcParams["font.family"] = "Segoe UI" if sys.platform == "win32" else "DejaVu Sans"
        self.figure = Figure(figsize=(10, 5.2), dpi=100, facecolor="white")
        self.figure.subplots_adjust(left=0.09, right=0.97, bottom=0.15, top=0.76)
        self.title = self.figure.text(0.09, 0.94, "CPU FIR input and output", fontsize=17, color="#252a31")
        self.subtitle = self.figure.text(0.09, 0.875, "Waiting for FPGA data", fontsize=10, color="#525a65")
        self.axes = self.figure.add_subplot(111)
        self.input_line, = self.axes.plot([], [], "--", color="#8b929c", lw=1.1, label="Input sent by PC")
        self.output_line, = self.axes.plot([], [], "-", color="#2166ac", lw=1.7, label="Output from FPGA CPU")
        self.threshold_line = self.axes.axhline(0, color="#a67717", lw=1, ls=":", label="Event threshold")
        self.axes.legend(loc="lower left", bbox_to_anchor=(0, 1.01), ncol=3, frameon=False, fontsize=9)
        self.axes.set_xlabel("Sample index n (not wall-clock time)")
        self.axes.set_ylabel("Integer amplitude (counts)")
        self.axes.spines[["top", "right"]].set_visible(False)
        self.axes.grid(axis="y", color="#e4e7eb", lw=0.7)
        self.axes.set_xlim(0, WINDOW - 1)
        self.axes.set_ylim(-1500, 1500)

    def update(self, session):
        rows = list(session.records)
        self.input_line.set_data([r["sample"] for r in rows], [r["input"] for r in rows])
        self.output_line.set_data([r["sample"] for r in rows], [r["output"] for r in rows])
        last = rows[-1]["sample"] if rows else WINDOW - 1
        self.axes.set_xlim(max(0, last - WINDOW + 1), max(WINDOW - 1, last))
        settings = session.settings
        gain = sum(abs(c) for c in settings["coefficients"]) / (2 ** settings["scale"])
        limit = (1000 + settings["noise"]) * max(1, gain) * 1.12
        self.axes.set_ylim(-limit, limit)
        threshold = settings["threshold"]
        self.threshold_line.set_ydata([threshold, threshold])
        self.threshold_line.set_visible(abs(threshold) <= limit)
        suffix = " (outside plot)" if abs(threshold) > limit else ""
        self.subtitle.set_text(f"{settings['preset']}  |  {settings['source']} + noise +/-{settings['noise']}  |  "
                               f"threshold {threshold}{suffix}\n"
                               "Physical UART, 115200 baud; 32 samples/batch; latest 512 samples")


def save_snapshot(session, plot, output, port_name):
    if not session.records:
        raise ValueError("collect at least one batch before saving")
    output.parent.mkdir(parents=True, exist_ok=True)
    csv_path, png_path, json_path = [Path(str(output) + ext) for ext in (".csv", ".png", ".json")]
    json_path.unlink(missing_ok=True)
    with csv_path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=("sample", "input", "output"))
        writer.writeheader()
        writer.writerows(session.records)
    plot.update(session)
    plot.figure.savefig(png_path, dpi=150)
    write_result_json({
        "status": "captured", "captured_at_utc": datetime.now(timezone.utc).isoformat(),
        "port": port_name, "baud": 115200, "settings": session.settings,
        "total_samples": session.total, "saved_samples": len(session.records),
        "first_sample": session.records[0]["sample"], "last_sample": session.records[-1]["sample"],
        "last_batch": session.last, "last_status": session.device,
        "inputs": {"scripts/" + name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
                   for name in ("signal_viewer.py", "signal_console.py", "result_json.py")},
        "files": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (csv_path, png_path)},
    }, json_path)
    return csv_path


def connect(port_name, packet):
    import serial
    port = serial.Serial(port_name, 115200, timeout=3, write_timeout=3)
    stage = 'firmware upload' if packet else 'FIR2 status query'
    try:
        if packet:
            boot(port, packet)
        stage = 'FIR2 status query'
        client = Client(port)
        client.synchronize()
        return client
    except Exception as error:
        port.close()
        hint = ('Press BTN C before --upload; after power loss load the FIR application bitstream first.'
                if stage == 'firmware upload' else
                'After BTN C use --upload; after power loss use the explicit --program startup path.')
        raise RuntimeError(f"{stage} failed: {error}. {hint}") from error


class Viewer:
    def __init__(self, root, args):
        import tkinter as tk
        from tkinter import ttk
        from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg
        self.root, self.args = root, args
        self.client = self.session = None
        self.running = self.closing = self.failed = False
        self.next_time = 0
        self.pool = ThreadPoolExecutor(max_workers=1)
        self.future = self.pool.submit(connect, args.port, args.boot)
        self.action = "connect"
        root.title("CPU signal viewer")
        root.geometry("1080x740")
        root.minsize(880, 660)
        root.protocol("WM_DELETE_WINDOW", self.close)
        outer = ttk.Frame(root, padding=14)
        outer.pack(fill="both", expand=True)
        outer.columnconfigure(0, weight=1)
        outer.rowconfigure(4, weight=1)
        ttk.Label(outer, text="FPGA signal console", font=("Segoe UI", 17, "bold")).grid(row=0, column=0, sticky="w")
        ttk.Label(outer, text=f"{args.port}  |  PC generates input; your CPU computes every output").grid(
            row=1, column=0, sticky="w", pady=(3, 12))
        controls = ttk.Frame(outer)
        controls.grid(row=2, column=0, sticky="ew")
        self.preset = tk.StringVar(value=args.preset)
        self.source = tk.StringVar(value=args.source)
        self.noise = tk.StringVar(value=str(args.noise))
        self.threshold = tk.StringVar(value=str(args.threshold))
        for column, (label, variable, choices, width) in enumerate([
                ("Filter", self.preset, list(PRESETS), 15),
                ("Input", self.source, ["sine", "step"], 9),
                ("Noise +/-", self.noise, None, 9),
                ("Threshold", self.threshold, None, 12)]):
            ttk.Label(controls, text=label).grid(row=0, column=column, sticky="w")
            widget = (ttk.Combobox(controls, textvariable=variable, values=choices, state="readonly", width=width)
                      if choices else ttk.Entry(controls, textvariable=variable, width=width))
            widget.grid(row=1, column=column, padx=(0, 12), pady=(3, 8))
        self.apply_button = ttk.Button(controls, text="Apply & restart", command=self.apply, state="disabled")
        self.apply_button.grid(row=1, column=4, padx=5)
        self.play_button = ttk.Button(controls, text="Start", command=self.toggle, state="disabled")
        self.play_button.grid(row=1, column=5, padx=5)
        self.save_button = ttk.Button(controls, text="Save snapshot", command=self.save, state="disabled")
        self.save_button.grid(row=1, column=6, padx=5)
        self.message = tk.StringVar(value="Connecting to FIR2 firmware...")
        message_label = ttk.Label(outer, textvariable=self.message, wraplength=980)
        message_label.grid(row=3, column=0, sticky="ew", pady=(0, 5))
        self.plot = SignalPlot()
        self.canvas = FigureCanvasTkAgg(self.plot.figure, master=outer)
        self.canvas.get_tk_widget().grid(row=4, column=0, sticky="nsew")
        self.metrics = tk.StringVar(value="No samples received")
        ttk.Label(outer, textvariable=self.metrics, font=("Consolas", 11)).grid(
            row=5, column=0, sticky="w", pady=(8, 4))
        self.help_label = ttk.Label(outer, text="Pause retains history. Apply restarts the signal and clears filter history/counters. "
                                   "Changes take effect only after Apply.", wraplength=980)
        self.help_label.grid(row=6, column=0, sticky="ew")
        for label in (message_label, self.help_label):
            label.bind("<Configure>", lambda event: event.widget.configure(wraplength=max(1, event.width)))
        self.timer = root.after(40, self.poll)

    def apply(self):
        if self.future or self.failed or self.closing:
            return
        try:
            preset, source = self.preset.get(), self.source.get()
            noise, threshold = int(self.noise.get()), int(self.threshold.get())
            SignalSource(source, noise, self.args.seed)
            config_payload(PRESETS[preset][0], PRESETS[preset][1], threshold)
        except (ValueError, KeyError) as error:
            self.message.set(str(error))
            return
        self.running = False
        self.play_button.configure(text="Start", state="disabled")
        self.apply_button.configure(state="disabled")
        self.save_button.configure(state="disabled")
        self.action = "configure"
        self.future = self.pool.submit(StreamSession, self.client, preset, source, noise, threshold, self.args.seed)
        self.message.set("Applying configuration...")

    def toggle(self):
        if not self.session or self.failed or self.closing:
            return
        self.running = not self.running
        self.play_button.configure(text="Pause" if self.running else "Resume")
        self.message.set("Streaming from FPGA" if self.running else "Paused after the current batch; history retained")

    def save(self):
        if self.future or not self.session:
            return
        try:
            path = save_snapshot(self.session, self.plot, self.args.output, self.args.port)
            self.message.set(f"Saved {len(self.session.records)} samples: {path}")
        except (OSError, ValueError) as error:
            self.message.set(f"Save failed: {error}")

    def close(self):
        self.closing, self.running = True, False
        self.message.set("Closing serial connection after the current response...")

    def poll(self):
        if self.future and self.future.done():
            future, self.future = self.future, None
            try:
                result = future.result()
                if self.action == "connect":
                    self.client = result
                    if not self.closing:
                        self.apply()
                elif self.action == "configure":
                    self.session = result
                    self.plot.update(self.session)
                    self.canvas.draw_idle()
                    self.metrics.set("No samples received")
                    self.message.set("Ready. Press Start to send a continuous signal.")
                elif self.action == "data":
                    s = self.session
                    self.plot.update(s)
                    self.canvas.draw_idle()
                    self.metrics.set(f"Samples {s.total:,}   Events {s.events:,}   "
                                     f"CPU {result['compute_cycles']:,} cycles/batch   "
                                     f"UART round trip {result['round_trip_ms']:.1f} ms\n"
                                     f"GPIO 0x{result['gpio']:02X}   Switches 0x{s.device['switches']:04X}   "
                                     f"RX overrun: {'YES' if s.device['uart_overrun'] else 'no'}")
            except Exception as error:
                self.failed, self.running = True, False
                self.message.set(f"Stopped: {error}. Close, check the board, and reconnect. No command was retried.")
                self.play_button.configure(text="Stopped")
        if self.closing and self.future is None:
            if self.client:
                self.client.port.close()
            self.pool.shutdown(wait=False)
            self.root.destroy()
            return
        idle = self.future is None and self.client and not self.failed and not self.closing
        paused = idle and not self.running
        playable = self.session and not self.failed and not self.closing and (idle or self.action == "data")
        self.apply_button.configure(state="normal" if paused else "disabled")
        self.play_button.configure(state="normal" if playable else "disabled")
        self.save_button.configure(state="normal" if paused and self.session and self.session.records else "disabled")
        if idle and self.running and time.monotonic() >= self.next_time:
            self.next_time = time.monotonic() + INTERVAL
            self.action = "data"
            self.future = self.pool.submit(self.session.next_batch)
        self.timer = self.root.after(40, self.poll)


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--boot", type=Path, help="upload FIR2 firmware after board reset")
    parser.add_argument("--preset", choices=PRESETS, default="average4")
    parser.add_argument("--source", choices=("sine", "step"), default="sine")
    parser.add_argument("--noise", type=int, default=300)
    parser.add_argument("--threshold", type=int, default=700)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--batches", type=int, default=0, help="capture N batches without a window; zero opens the viewer")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="snapshot filename stem; existing files are replaced")
    args = parser.parse_args(argv)
    try:
        SignalSource(args.source, args.noise, args.seed)
        config_payload(PRESETS[args.preset][0], PRESETS[args.preset][1], args.threshold)
        if args.batches < 0:
            raise ValueError("batches must be nonnegative")
    except ValueError as error:
        parser.error(str(error))
    return args


def main(argv=None):
    args = arguments(argv)
    try:
        if args.batches:
            from matplotlib.backends.backend_agg import FigureCanvasAgg
            client = connect(args.port, args.boot)
            try:
                session = StreamSession(client, args.preset, args.source, args.noise, args.threshold, args.seed)
                for _ in range(args.batches):
                    start = time.monotonic()
                    session.next_batch()
                    time.sleep(max(0, INTERVAL - (time.monotonic() - start)))
                session.check_status()
                plot = SignalPlot()
                FigureCanvasAgg(plot.figure)
                path = save_snapshot(session, plot, args.output, args.port)
                print(f"Captured {session.total} FPGA outputs; saved latest {len(session.records)} to {path}")
            finally:
                client.port.close()
        else:
            import tkinter as tk
            root = tk.Tk()
            Viewer(root, args)
            root.mainloop()
    except ImportError as error:
        raise SystemExit(f"Missing {error.name}; install scripts/signal-viewer-requirements.txt")
    except (OSError, TimeoutError, ValueError, RuntimeError, KeyboardInterrupt) as error:
        raise SystemExit(str(error))


if __name__ == "__main__":
    main()
