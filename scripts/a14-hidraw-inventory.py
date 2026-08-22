#!/usr/bin/env python3
"""Inventory every Linux hidraw endpoint and its report geometry.

This is intentionally read-only.  It helps distinguish separate physical HID
devices from top-level collections that share one report descriptor, and lists
every report ID available under every application collection.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path


def uvalue(data: bytes) -> int:
    return int.from_bytes(data, "little", signed=False)


def read_uevent(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        for line in path.read_text(errors="replace").splitlines():
            key, sep, value = line.partition("=")
            if sep:
                values[key] = value
    except OSError:
        pass
    return values


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


@dataclass(frozen=True)
class Collection:
    depth: int
    collection_type: int
    usage_page: int
    usage: int


def decode_descriptor(desc: bytes) -> tuple[list[Collection], dict[tuple[int, int, str, int], int]]:
    state = GlobalState()
    state_stack: list[GlobalState] = []
    collections: list[Collection] = []
    local_usages: list[tuple[int, int]] = []
    top_apps: list[Collection] = []
    reports: dict[tuple[int, int, str, int], int] = {}

    offset = 0
    while offset < len(desc):
        prefix = desc[offset]
        offset += 1
        if prefix == 0xFE:
            if offset + 2 > len(desc):
                break
            size = desc[offset]
            offset += 2 + size
            local_usages.clear()
            continue

        size_code = prefix & 0x03
        size = 4 if size_code == 3 else size_code
        item_type = (prefix >> 2) & 0x03
        tag = (prefix >> 4) & 0x0F
        data = desc[offset : offset + size]
        offset += size
        value = uvalue(data)

        if item_type == 1:
            if tag == 0x0:
                state.usage_page = value
            elif tag == 0x7:
                state.report_size = value
            elif tag == 0x8:
                state.report_id = value
            elif tag == 0x9:
                state.report_count = value
            elif tag == 0xA:
                state_stack.append(state.clone())
            elif tag == 0xB and state_stack:
                state = state_stack.pop()
            continue

        if item_type == 2 and tag == 0x0:
            if size == 4 and value > 0xFFFF:
                local_usages.append(((value >> 16) & 0xFFFF, value & 0xFFFF))
            else:
                local_usages.append((state.usage_page, value))
            continue

        if item_type != 0:
            continue

        if tag == 0xA:
            page, usage = local_usages[-1] if local_usages else (state.usage_page, 0)
            collection = Collection(len(collections), value, page, usage)
            collections.append(collection)
            if collection.depth == 0 and collection.collection_type == 1:
                top_apps.append(collection)
            local_usages.clear()
            continue

        if tag == 0xC:
            if collections:
                collections.pop()
            local_usages.clear()
            continue

        kind = {0x8: "input", 0x9: "output", 0xB: "feature"}.get(tag)
        if kind:
            top = collections[0] if collections else Collection(0, -1, 0, 0)
            key = (top.usage_page, top.usage, kind, state.report_id)
            reports[key] = reports.get(key, 0) + state.report_size * state.report_count
        local_usages.clear()

    return top_apps, reports


def parent_chain(device: Path) -> str:
    labels: list[str] = []
    try:
        current = device.resolve()
    except OSError:
        return "unknown"
    for parent in (current, *current.parents):
        if parent == Path("/sys"):
            break
        info = read_uevent(parent / "uevent")
        modalias = info.get("MODALIAS", "")
        if "QTEC" in modalias.upper() or "ASUH" in modalias.upper():
            labels.append(modalias)
    return ",".join(dict.fromkeys(labels)) or "none"


def main() -> int:
    nodes = sorted(Path("/sys/class/hidraw").glob("hidraw*"))
    if not nodes:
        print("No hidraw devices found.")
        return 3

    for index, cls in enumerate(nodes):
        device = cls / "device"
        info = read_uevent(device / "uevent")
        try:
            driver = (device / "driver").resolve().name
        except OSError:
            driver = "unbound"
        try:
            desc = (device / "report_descriptor").read_bytes()
        except OSError as error:
            desc = b""
            desc_error = str(error)
        else:
            desc_error = ""

        if index:
            print()
        print(f"device=/dev/{cls.name}")
        print(f"hid_id={info.get('HID_ID', 'unknown')}")
        print(f"hid_name={info.get('HID_NAME', 'unknown')}")
        print(f"driver={driver}")
        print(f"firmware_parents={parent_chain(device)}")
        if desc_error:
            print(f"report_descriptor_error={desc_error}")
            continue
        print(f"report_descriptor_bytes={len(desc)}")
        print(f"report_descriptor_sha256={hashlib.sha256(desc).hexdigest()}")

        top_apps, reports = decode_descriptor(desc)
        for app_index, app in enumerate(top_apps):
            marker = " QTEC_WINDOWS_TARGET" if (
                app.usage_page, app.usage
            ) == (0xFF31, 0x0076) else ""
            print(
                f"application[{app_index}]=page:0x{app.usage_page:04x} "
                f"usage:0x{app.usage:04x}{marker}"
            )
        for (page, usage, kind, report_id), bits in sorted(reports.items()):
            wire_bytes = (bits + 7) // 8 + (1 if report_id else 0)
            print(
                f"report=page:0x{page:04x} usage:0x{usage:04x} "
                f"kind:{kind} id:0x{report_id:02x} "
                f"payload_bits:{bits} wire_bytes:{wire_bytes}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
