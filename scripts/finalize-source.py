#!/usr/bin/env python3
"""Apply final compile-safety fixes to the prepared build copy."""

from __future__ import annotations

import argparse
from pathlib import Path


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match in {path}, found {count}")
    path.write_text(text.replace(old, new, 1))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=Path("build-src"))
    args = parser.parse_args()
    source = args.source.resolve()

    replace_once(
        source / "asus_zenbook_a14_ec.c",
        "\tu8 temp, mode;\n",
        "\tu8 temp = 0, mode = EC_FAN_MODE_AUTO;\n",
        "initialize probe telemetry",
    )
    replace_once(
        source / "hid_asus_ec.c",
        "#include <linux/module.h>\n",
        "#include <linux/module.h>\n#include <linux/mutex.h>\n",
        "include HID mutex support",
    )
    print(f"Finalized hardened module sources in {source}")


if __name__ == "__main__":
    main()
