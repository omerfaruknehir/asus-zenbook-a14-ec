#!/usr/bin/env bash
set -euo pipefail

URL='https://patchew.org/linux/20260801-hm1092-driver-v6-0-5979f223748a%40gmail.com/mbox'
SHA256='34724a360d07c5142b3cb58cdab34eeb095bf4439bb8867f37f02e2579c20c1c'
OUT="${1:-hm1092-v6.mbox}"
TMP="${OUT}.tmp.$$"
trap 'rm -f "$TMP"' EXIT

curl -fL --retry 4 --retry-delay 2 "$URL" -o "$TMP"
printf '%s  %s\n' "$SHA256" "$TMP" | sha256sum -c -
mv "$TMP" "$OUT"
trap - EXIT
printf 'Wrote %s\n' "$OUT"
