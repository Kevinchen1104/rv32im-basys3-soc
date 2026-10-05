"""Readable result JSON shared by the Python verification entrypoints."""

import json
from pathlib import Path
import re

QUOTED = r'"(?:\\.|[^"\\])*"'
SCALAR = rf'(?:{QUOTED}|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null)'
ARRAY = rf'\[\s*(?:{SCALAR}(?:\s*,\s*{SCALAR})*)?\s*\]'


def format_result_json(value):
    """Expand objects; pack scalar arrays into readable rows of up to eight."""
    text = json.dumps(value, indent=2, ensure_ascii=True, allow_nan=False)

    def compact(match):
        if not match[0].startswith("["):
            return match[0]
        items = re.findall(SCALAR, match[0])
        result = "[" + ", ".join(items) + "]"
        line_start = text.rfind("\n", 0, match.start()) + 1
        if match.start() - line_start + len(result) <= 120:
            return result
        indent = re.match(r" *", text[line_start:]).group()
        rows, row = [], []
        for item in items:
            if row and (len(row) == 8 or len(indent) + 2 + len(", ".join([*row, item])) + 1 > 120):
                rows.append(", ".join(row))
                row = []
            row.append(item)
        rows.append(", ".join(row))
        return "[\n" + (",\n".join(indent + "  " + row for row in rows)) + "\n" + indent + "]"

    return re.sub(rf'{QUOTED}|{ARRAY}', compact, text) + "\n"


def write_result_json(value, path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(format_result_json(value), encoding="utf-8", newline="\n")
