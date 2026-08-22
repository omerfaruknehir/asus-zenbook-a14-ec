#!/usr/bin/env python3
"""Reproducible static analysis for the UX3407RA BIOS 312 EC image.

This tool never modifies firmware.  It validates the exact 256 KiB EC image,
disassembles the recovered RISC-V handlers, and emits a machine-readable map
that can be compared with the C++ behavioral reconstruction.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys

try:
    from capstone import CS_ARCH_RISCV, CS_MODE_RISCVC, CS_MODE_RISCV32, Cs
except ImportError as exc:  # pragma: no cover - depends on the analyst host
    raise SystemExit(
        "capstone is required; install it in a venv with: pip install capstone"
    ) from exc


EXPECTED_SIZE = 262_144
EXPECTED_SHA256 = "353eb0d125d76a14f15faa72f2153d57e25efd8d212f42b18a9f11c16e3fc39d"
EXPECTED_IDENTITY = b"ITE51300-EC-V0.00"

FEATURE_LEDGER = (
    {
        "report": "5a 05 20 31 00 08",
        "status": "parser and response proven",
        "behavior": "ASUS feature capability/configuration exchange",
    },
    {
        "report": "5a ba c5 c4 <0..3>",
        "status": "handler semantics proven",
        "behavior": "four-level keyboard-light target",
    },
    {
        "report": "5a d0 4e <0|1>",
        "status": "handler and service semantics proven",
        "behavior": "queue Fn-row selection",
    },
    {
        "report": "5a d0 7c <0|1>",
        "status": "dispatch proven; downstream device meaning unknown",
        "behavior": "set channel 0x3a to 1 or 0",
    },
    {
        "report": "5a d0 85 ff 00",
        "status": "dispatch and response construction proven",
        "behavior": "status/query exchange; field meanings unknown",
    },
    {
        "report": "5a d0 85 ff 80",
        "status": "handler semantics proven; public meaning unknown",
        "behavior": "set bit 7 of EC byte 0x00803024",
    },
    {
        "report": "5a d0 8f 01",
        "status": "handler proven; hardware-disproven as Fn-switch prerequisite",
        "behavior": "start/reset auxiliary timed state; public purpose unknown",
    },
    {
        "report": "5a f4 6b ...",
        "status": "dispatch proven; payload semantics unknown",
        "behavior": "refresh/copy 12-byte EC data block",
    },
)

# File offsets are also execution addresses in the first EC code image.
REGIONS = {
    "reset_and_preserved_asus_blocks": (0x0100, 0x0226),
    "hid_feature_dispatch": (0xEB10, 0xEE5A),
    "fn_switch_state_query": (0xF81E, 0xF82C),
    "fn_switch_request_action_keys": (0xF82C, 0xF83E),
    "fn_switch_request_fkeys": (0xF83E, 0xF850),
    "fn_switch_service": (0xF850, 0xF896),
    "keyboard_backlight_quantizer": (0xFFDC, 0x1000E),
    "d0_7c_channel_3a": (0x10226, 0x1023A),
    "d0_8f_auxiliary_state": (0x102F8, 0x10346),
    "d0_85_flag_00803024": (0xD350, 0xD36A),
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def disassemble(data: bytes, start: int, end: int) -> list[dict[str, object]]:
    md = Cs(CS_ARCH_RISCV, CS_MODE_RISCV32 | CS_MODE_RISCVC)
    result: list[dict[str, object]] = []
    for insn in md.disasm(data[start:end], start):
        result.append(
            {
                "address": insn.address,
                "bytes": insn.bytes.hex(),
                "mnemonic": insn.mnemonic,
                "operands": insn.op_str,
            }
        )
    return result


def instruction_text(instructions: list[dict[str, object]]) -> str:
    return "\n".join(
        f"{item['address']:08x}: {item['mnemonic']} {item['operands']}"
        for item in instructions
    )


def require_semantics(regions: dict[str, list[dict[str, object]]]) -> None:
    checks = {
        "hid_feature_dispatch": (
            "addi a4, zero, 0x5a",
            "addi a3, zero, 0xd0",
            "addi a3, zero, 0x4e",
            "addi a3, zero, 0x8f",
            "addi a4, zero, 0xc5",
            "addi a4, zero, 0xc4",
        ),
        "fn_switch_request_action_keys": (
            "lbu a5, 0x49(a4)",
            "ori a5, a5, 4",
            "sb a5, 0x49(a4)",
        ),
        "fn_switch_request_fkeys": (
            "lbu a5, 0x49(a4)",
            "ori a5, a5, 8",
            "sb a5, 0x49(a4)",
        ),
        "fn_switch_service": (
            "lbu a5, 0x49(s0)",
            "andi a4, a5, 4",
            "andi a4, a5, 8",
            "ori a5, a5, 2",
        ),
        "keyboard_backlight_quantizer": (
            "c.li a4, 2",
            "c.li a4, 3",
            "c.li a4, 1",
            "sb zero, 0x4a(a5)",
        ),
        "d0_7c_channel_3a": (
            "c.li a1, 0",
            "c.li a1, 1",
            "addi a0, zero, 0x3a",
        ),
        "d0_8f_auxiliary_state": (
            "lbu a5, 0x2a0(a4)",
            "ori a5, a5, -0x80",
            "andi a5, a5, -0x41",
            "sb a0, 0x2a1(a5)",
        ),
        "d0_85_flag_00803024": (
            "lbu a5, 0x24(a4)",
            "ori a5, a5, -0x80",
            "sb a5, 0x24(a4)",
        ),
    }
    missing: list[str] = []
    for region, tokens in checks.items():
        text = instruction_text(regions[region])
        for token in tokens:
            if token not in text:
                missing.append(f"{region}: {token}")
    if missing:
        raise SystemExit("semantic validation failed:\n  " + "\n  ".join(missing))


def build_manifest(path: Path, data: bytes) -> dict[str, object]:
    regions = {
        name: disassemble(data, start, end)
        for name, (start, end) in REGIONS.items()
    }
    require_semantics(regions)
    return {
        "source": str(path),
        "size": len(data),
        "sha256": sha256(data),
        "identity": EXPECTED_IDENTITY.decode(),
        "architecture": "RISC-V RV32IMC (recovered from reset code)",
        "address_model": "first code image uses file offset as execution address",
        "facts": {
            "fn_switch_report": [0x5A, 0xD0, 0x4E, "state"],
            "fn_switch_state_0": "queue action/media keys as primary",
            "fn_switch_state_1": "queue ordinary F1-F12 as primary",
            "fn_switch_queue_address": "0x00803049",
            "fn_switch_busy_gate_address": "0x00800410",
            "fn_switch_ready_gate": "bit 7 of 0x0080041a",
            "d0_8f_report": [0x5A, 0xD0, 0x8F, 0x01],
            "d0_8f_auxiliary_state_address": "0x008012a0",
            "backlight_report": [0x5A, 0xBA, 0xC5, 0xC4, "level"],
            "backlight_levels": [0, 1, 2, 3],
        },
        "feature_ledger": FEATURE_LEDGER,
        "regions": regions,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("ec_image", type=Path)
    parser.add_argument("--json", type=Path, help="write the recovered map as JSON")
    parser.add_argument(
        "--allow-unknown-image",
        action="store_true",
        help="disassemble an image with a different hash (semantic checks still apply)",
    )
    args = parser.parse_args()

    data = args.ec_image.read_bytes()
    digest = sha256(data)
    if len(data) != EXPECTED_SIZE:
        raise SystemExit(f"unexpected EC size: {len(data)} (expected {EXPECTED_SIZE})")
    if EXPECTED_IDENTITY not in data[:0x100]:
        raise SystemExit("ITE51300 EC identity is absent from the image header")
    if digest != EXPECTED_SHA256 and not args.allow_unknown_image:
        raise SystemExit(
            f"unexpected EC SHA-256: {digest}\nexpected BIOS 312 EC: {EXPECTED_SHA256}"
        )

    manifest = build_manifest(args.ec_image, data)
    print(f"source={args.ec_image}")
    print(f"size={len(data)}")
    print(f"sha256={digest}")
    print("architecture=RISC-V RV32IMC")
    print("fn_switch_dispatch=5a d0 4e state")
    print("fn_switch_queue=0x00803049 bits 2/3; current state=bit 1")
    print("fn_switch_gates=0x00800410 == 0; 0x0080041a bit 7 == 1")
    print("d0_8f_dispatch=5a d0 8f 01; Fn-switch prerequisite=hardware-disproven")
    print("backlight_dispatch=5a ba c5 c4 level; accepted levels=0..3")
    print(f"feature_ledger_entries={len(FEATURE_LEDGER)}")

    if args.json:
        args.json.write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"json={args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
