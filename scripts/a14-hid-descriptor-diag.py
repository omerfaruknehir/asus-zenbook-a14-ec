#!/usr/bin/env python3
"""Decode just enough of the A14 HID descriptor to verify Fn-switch geometry.

Windows ASUSOptimization selects VID 0B05, PID 0220, UsagePage FF31,
Usage 0076 and reports FeatureReportByteLength=64.  This script verifies that
Linux parsed the same physical HID descriptor/collection and shows every
Feature item using report ID 0x5a.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path

ASUS_VENDOR = 0x0B05
ASUS_PRODUCT = 0x0220
TARGET_PAGE = 0xFF31
TARGET_USAGE = 0x0076
TARGET_REPORT_ID = 0x5A


def uvalue(data: bytes) -> int:
    return int.from_bytes(data, "little", signed=False)


def read_uevent(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    try:
        for line in path.read_text(errors="replace").splitlines():
            key, sep, value = line.partition("=")
            if sep:
                out[key] = value
    except OSError:
        pass
    return out


def parse_hid_id(text: str) -> tuple[int, int] | None:
    try:
        _bus, vendor, product = text.split(":", 2)
        return int(vendor, 16), int(product, 16)
    except (ValueError, AttributeError):
        return None


@dataclass
class GlobalState:
    usage_page: int = 0
    report_size: int = 0
    report_id: int = 0
    report_count: int = 0

    def clone(self) -> "GlobalState":
        return GlobalState(
            self.usage_page, self.report_size, self.report_id, self.report_count
        )


@dataclass
class Collection:
    depth: int
    collection_type: int
    usage_page: int
    usage: int


def decode_descriptor(desc: bytes) -> None:
    g = GlobalState()
    gstack: list[GlobalState] = []
    collections: list[Collection] = []
    local_usages: list[tuple[int, int]] = []
    top_apps: list[Collection] = []
    feature_bits: dict[tuple[int, int, int], int] = {}

    offset = 0
    while offset < len(desc):
        prefix = desc[offset]
        offset += 1
        if prefix == 0xFE:  # long item
            if offset + 2 > len(desc):
                break
            size = desc[offset]
            offset += 2  # size + long tag
            offset += size
            local_usages.clear()
            continue

        size_code = prefix & 0x3
        size = 4 if size_code == 3 else size_code
        item_type = (prefix >> 2) & 0x3
        tag = (prefix >> 4) & 0xF
        data = desc[offset : offset + size]
        offset += size
        value = uvalue(data)

        # Global items
        if item_type == 1:
            if tag == 0x0:  # Usage Page
                g.usage_page = value
            elif tag == 0x7:  # Report Size
                g.report_size = value
            elif tag == 0x8:  # Report ID
                g.report_id = value
            elif tag == 0x9:  # Report Count
                g.report_count = value
            elif tag == 0xA:  # Push
                gstack.append(g.clone())
            elif tag == 0xB and gstack:  # Pop
                g = gstack.pop()
            continue

        # Local Usage
        if item_type == 2 and tag == 0x0:
            if size == 4 and value > 0xFFFF:
                local_usages.append(((value >> 16) & 0xFFFF, value & 0xFFFF))
            else:
                local_usages.append((g.usage_page, value))
            continue

        if item_type != 0:
            continue

        # Main Collection
        if tag == 0xA:
            page, usage = local_usages[-1] if local_usages else (g.usage_page, 0)
            c = Collection(len(collections), value, page, usage)
            collections.append(c)
            if c.depth == 0 and c.collection_type == 1:  # Application
                top_apps.append(c)
            local_usages.clear()
            continue

        # Main End Collection
        if tag == 0xC:
            if collections:
                collections.pop()
            local_usages.clear()
            continue

        # Main Feature
        if tag == 0xB:
            top = collections[0] if collections else Collection(0, -1, 0, 0)
            bits = g.report_size * g.report_count
            key = (top.usage_page, top.usage, g.report_id)
            feature_bits[key] = feature_bits.get(key, 0) + bits

        # Local state resets after every Main item.
        local_usages.clear()

    print("top_level_application_collections:")
    for i, c in enumerate(top_apps):
        marker = " TARGET" if (c.usage_page, c.usage) == (TARGET_PAGE, TARGET_USAGE) else ""
        print(
            f"  [{i}] usage_page=0x{c.usage_page:04x} usage=0x{c.usage:04x}"
            f" type=0x{c.collection_type:02x}{marker}"
        )

    target_apps = [
        c for c in top_apps if (c.usage_page, c.usage) == (TARGET_PAGE, TARGET_USAGE)
    ]
    print(f"WINDOWS_TARGET_COLLECTION_COUNT={len(target_apps)}")

    matches = []
    for (page, usage, report_id), bits in sorted(feature_bits.items()):
        if report_id == TARGET_REPORT_ID:
            # A report-ID byte is on the wire in addition to descriptor payload.
            total_bytes = 1 + ((bits + 7) // 8)
            matches.append((page, usage, bits, total_bytes))
            print(
                "feature_report_5a: "
                f"usage_page=0x{page:04x} usage=0x{usage:04x} "
                f"payload_bits={bits} total_wire_bytes={total_bytes}"
            )

    exact = [m for m in matches if m[0] == TARGET_PAGE and m[1] == TARGET_USAGE]
    if exact:
        for _page, _usage, _bits, total_bytes in exact:
            print(f"WINDOWS_TARGET_FEATURE_REPORT_5A_BYTES={total_bytes}")
            print(
                "WINDOWS_TARGET_FEATURE_REPORT_MATCH="
                + ("YES" if total_bytes == 64 else "LENGTH_MISMATCH")
            )
    else:
        print("WINDOWS_TARGET_FEATURE_REPORT_MATCH=NO_REPORT_5A_UNDER_TARGET_COLLECTION")


def main() -> int:
    found = False
    for cls in sorted(Path("/sys/class/hidraw").glob("hidraw*")):
        dev = cls / "device"
        info = read_uevent(dev / "uevent")
        ident = parse_hid_id(info.get("HID_ID", ""))
        if ident != (ASUS_VENDOR, ASUS_PRODUCT):
            continue
        found = True
        desc_path = dev / "report_descriptor"
        try:
            desc = desc_path.read_bytes()
        except OSError as error:
            print(f"device=/dev/{cls.name} ERROR=read report_descriptor: {error}")
            continue
        print(f"device=/dev/{cls.name}")
        print(f"hid_name={info.get('HID_NAME', 'unknown')}")
        try:
            print(f"driver={(dev / 'driver').resolve().name}")
        except OSError:
            print("driver=unbound")
        print(f"report_descriptor_bytes={len(desc)}")
        print(f"report_descriptor_sha256={hashlib.sha256(desc).hexdigest()}")
        decode_descriptor(desc)

    if not found:
        print("No ASUS 0B05:0220 hidraw device found.")
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
