#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec sh "$repo/scripts/test-package-native-whisper.sh"
