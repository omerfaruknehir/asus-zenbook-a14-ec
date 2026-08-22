#!/usr/bin/env python3
"""Compatibility wrapper for the safe 0B05:4543 correlation diagnostic.

The previous version wrote guessed keyboard, Fn-lock, and initialization
commands using a report length that did not match the live UX3407RA descriptor.
Unknown writes are intentionally disabled. Use status or correlate.
"""

from pathlib import Path
import os
import sys

TARGET = Path(__file__).with_name("a14-4543-correlation-probe.py")


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in {"status", "correlate"}:
        print(
            "Unsafe 0B05:4543 writes are disabled.\n"
            f"usage: sudo {sys.argv[0]} status | correlate [delay]",
            file=sys.stderr,
        )
        return 2
    os.execv(sys.executable, [sys.executable, str(TARGET), *sys.argv[1:]])
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
