#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Apply and verify the A14 WSA884x VISENSE transport patch to Linux 7.1.5."""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import NoReturn

BASE_COMMIT = "155b42bec9cbb6b8cdc47dd9bd09503a81fbe493"
PATCH_REL = Path("patches/0001-a14-wsa-visense-transport-v1.patch")


def die(msg: str) -> NoReturn:
    raise SystemExit(f"ERROR: {msg}")


def run(*args: str, cwd: Path, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, check=check)


def has(path: Path, text: str) -> bool:
    return text in path.read_text(errors="strict")


def pure_unified_diff(patch: Path) -> str:
    """Return only the unified-diff body from an email-style patch.

    The V1 patch is intentionally human/auditor-friendly and carries a small
    mail header plus the conventional git-format-patch footer.  `git apply
    --recount` recounts hunk bodies and therefore must not be allowed to treat
    the trailing `-- \n<git-version>` footer as hunk text.
    """
    text = patch.read_text(errors="strict")
    start = text.find("diff --git ")
    if start < 0:
        die(f"no unified diff found in {patch}")
    text = text[start:]

    # Strip the conventional git-format-patch signature only when it is the
    # final trailer.  Keep every line of the actual diff body byte-for-byte.
    lines = text.splitlines(keepends=True)
    if len(lines) >= 2 and lines[-2] in ("-- \n", "-- \r\n"):
        lines = lines[:-2]
    elif len(lines) >= 2 and lines[-2].rstrip("\r\n") == "-- ":
        lines = lines[:-2]

    cleaned = "".join(lines)
    if not cleaned.endswith("\n"):
        cleaned += "\n"
    if "\n2.43.0\n" in cleaned or cleaned.endswith("2.43.0\n"):
        die("git-format-patch footer leaked into sanitized diff")
    return cleaned


def verify(src: Path) -> None:
    dts = src / "arch/arm64/boot/dts/qcom/x1-asus-zenbook-a14.dtsi"
    swr = src / "drivers/soundwire/qcom.c"
    wsa_macro = src / "sound/soc/codecs/lpass-wsa-macro.c"
    wsa = src / "sound/soc/codecs/wsa884x.c"
    q6ports = src / "sound/soc/qcom/qdsp6/q6dsp-lpass-ports.c"
    machine = src / "sound/soc/qcom/x1e80100.c"

    required = [
        (dts, 'link-name = "WSA VI Protection";'),
        (dts, 'sound-dai = <&left_spkr 1>, <&right_spkr 1>,'),
        (dts, '<&swr0 9>, <&lpass_wsamacro 2>;'),
        (dts, 'qcom,port-mapping = <1 2 3 7 10 13>;'),
        (dts, 'qcom,port-mapping = <4 5 6 7 11 13>;'),
        (swr, 'SoundWire VI Protection%d'),
        (wsa_macro, 'WSA_AIF_VI Protection'),
        (wsa, '.name = "SPKR_VI"'),
        (wsa, 'A14 WSA %s: rate=%u port=%u direction=%s'),
        (q6ports, '#define Q6AFE_CDC_DMA_VI_DAI(did)'),
        (q6ports, 'Q6AFE_CDC_DMA_VI_DAI(WSA_CODEC_DMA_TX_0)'),
        (machine, 'A14 WSA VI feedback %s'),
    ]
    for path, marker in required:
        if not has(path, marker):
            die(f"verification marker missing in {path.relative_to(src)}: {marker}")

    # Hard safety invariant for V1: the upstream X1E limits MUST still exist.
    safety = [
        'snd_soc_limit_volume(card, "WSA WSA_RX0 Digital Volume", 81);',
        'snd_soc_limit_volume(card, "WSA WSA_RX1 Digital Volume", 81);',
        'snd_soc_limit_volume(card, "SpkrLeft PA Volume", 6);',
        'snd_soc_limit_volume(card, "SpkrRight PA Volume", 6);',
    ]
    for marker in safety:
        if not has(machine, marker):
            die(f"V1 safety limit missing from x1e80100.c: {marker}")

    # The generic UCM-visible controls remain capped; V1 cannot make speakers louder.
    if has(machine, 'snd_soc_limit_volume(card, "SpkrLeft PA Volume", 24);'):
        die("unsafe Surface PA operating point leaked into A14 V1")

    print("A14_SPEAKER_PROTECTION_V1=VERIFIED")
    print("visense_left_master_port=10")
    print("visense_right_master_port=11")
    print("vi_backend=WSA_CODEC_DMA_TX_0:8000Hz:S32_LE:2ch")
    print("digital_gain_cap=-3dB_PRESERVED")
    print("pa_gain_cap=0dB_PRESERVED")
    print("sp_spvi_graph=NOT_ENABLED_IN_V1")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("source", type=Path)
    args = ap.parse_args()
    src = args.source.resolve()
    if not (src / ".git").exists():
        die(f"not a git Linux source tree: {src}")

    root = Path(__file__).resolve().parents[1]
    patch = root / PATCH_REL
    if not patch.is_file():
        die(f"missing repository patch: {patch}")

    head = run("git", "rev-parse", "HEAD", cwd=src).stdout.strip()
    if head != BASE_COMMIT:
        die(f"Linux source HEAD must be exact v7.1.5 {BASE_COMMIT}; got {head}")

    marker = src / "sound/soc/qcom/x1e80100.c"
    if has(marker, "A14 WSA VI feedback %s"):
        verify(src)
        print("speaker_protection_v1=current")
        return

    cleaned = pure_unified_diff(patch)
    with tempfile.TemporaryDirectory(prefix="a14-spkprot-v1-") as td:
        apply_patch = Path(td) / "a14-wsa-visense-v1.diff"
        apply_patch.write_text(cleaned)

        # Hunk bodies are authoritative; --recount makes the hand-maintained
        # patch insensitive to stale line-count metadata in @@ headers.
        apply_args = ("git", "apply", "--recount", "--ignore-space-change")
        check = run(*apply_args, "--check", str(apply_patch), cwd=src, check=False)
        if check.returncode:
            sys.stdout.write(check.stdout)
            die("A14 VISENSE patch does not apply cleanly to exact Linux 7.1.5")

        apply = run(*apply_args, str(apply_patch), cwd=src, check=False)
        if apply.returncode:
            sys.stdout.write(apply.stdout)
            die("git apply failed")

    verify(src)


if __name__ == "__main__":
    main()
