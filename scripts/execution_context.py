"""Stable result contexts, process-owned locks, and simple symbol parsing."""

import hashlib
import os
import re


def selection_context(selection, complete_selection):
    normalized = tuple(tuple(sorted(set(values))) for values in selection)
    complete = tuple(tuple(sorted(set(values))) for values in complete_selection)
    if normalized == complete:
        return ""
    return "subset-" + hashlib.sha256(repr(normalized).encode()).hexdigest()[:10]


def parse_symbols(text):
    symbols = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 3 and re.fullmatch(r"[0-9a-fA-F]+", parts[0]):
            symbols[parts[2]] = int(parts[0], 16)
    return symbols


class RunLock:
    """The OS releases this lock even after an interrupted process exits."""

    def __init__(self, path):
        self.stream = path.open("a+b")
        if path.stat().st_size == 0:
            self.stream.write(b"0")
            self.stream.flush()
        self.stream.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(self.stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            self.stream.close()
            raise RuntimeError(f"This selection is already running: {path}") from error

    def close(self):
        self.stream.close()
