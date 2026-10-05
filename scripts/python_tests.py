"""Run the project's Python unit tests and save a source-identified summary."""
import argparse
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timezone
import hashlib
import importlib
import os
from pathlib import Path
import platform
import subprocess
import unittest

from execution_context import RunLock
from result_json import write_result_json

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "results/python-tests"


class CountingResult(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.passed = 0

    def addSuccess(self, test):
        super().addSuccess(test)
        self.passed += 1


def inputs():
    paths = sorted(path for path in (ROOT / "scripts").rglob("*")
                   if path.suffix in (".py", ".ps1"))
    paths += [ROOT / "scripts/signal-viewer-requirements.txt",
              ROOT / "tools/compiled-programs/requirements.txt",
              ROOT / "tools/arch-test/rv32im_signature_ref.py"]
    return {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gui", action="store_true", help="also exercise Tk controls; requires a desktop session")
    args = parser.parse_args()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    (ROOT / "build").mkdir(exist_ok=True)
    lock = RunLock(ROOT / "build/python-tests.lock")
    report = {"status": "running", "started_at_utc": datetime.now(timezone.utc).isoformat(),
              "python": platform.python_version(), "gui_requested": args.gui}
    path = OUTPUT / "summary.json"
    write_result_json(report, path)
    try:
        report["inputs"] = inputs()
        report["source_commit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        report["dependencies"] = {}
        for name in ("serial", "matplotlib", "unicorn"):
            module = importlib.import_module(name)
            report["dependencies"][name] = module.__version__
        os.environ["CPU_VIEWER_GUI_TESTS"] = "1" if args.gui else "0"
        suite = unittest.defaultTestLoader.discover(str(ROOT / "scripts/tests"))
        with (OUTPUT / "tests.log").open("w", encoding="utf-8") as log:
            with redirect_stdout(log), redirect_stderr(log):
                result = unittest.TextTestRunner(stream=log, verbosity=2, resultclass=CountingResult).run(suite)
        report.update(tests_run=result.testsRun, failures=len(result.failures), errors=len(result.errors),
                      skipped=[{"test": test.id(), "reason": reason} for test, reason in result.skipped])
        report["tests_passed"] = result.passed
        if not result.wasSuccessful() or not result.testsRun:
            raise RuntimeError("Python tests failed; see results/python-tests/tests.log")
        if any(args.gui or not test.id().startswith("test_signal_viewer.ViewerGuiTests.")
               for test, _ in result.skipped):
            raise RuntimeError("unexpected skipped tests; install the documented dependencies")
        if report["inputs"] != inputs():
            raise RuntimeError("Python sources changed during the run")
        report["files"] = {"tests.log": hashlib.sha256((OUTPUT / "tests.log").read_bytes()).hexdigest()}
        report["status"] = "passed"
    except Exception as error:
        report.update(status="failed", error=str(error))
        raise
    finally:
        report["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
        write_result_json(report, path)
        lock.close()
    print(f"PASS: {report['tests_passed']}/{report['tests_run']} Python tests; "
          f"{len(report['skipped'])} explicitly skipped. See {path}")


if __name__ == "__main__":
    main()
