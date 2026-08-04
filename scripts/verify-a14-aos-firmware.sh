#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 DIRECTORY" >&2
    exit 2
fi
root=$1
[ -d "$root" ] || { echo "Not a directory: $root" >&2; exit 2; }

status=0
verify() {
    expected=$1
    file_name=$2
    matches=$(find "$root" -type f -name "$file_name" -print 2>/dev/null | sort)
    if [ -z "$matches" ]; then
        echo "MISSING  $file_name"
        status=1
        return
    fi
    good=0
    old_ifs=$IFS
    IFS='
'
    for path in $matches; do
        actual=$(sha256sum "$path" | awk '{print $1}')
        if [ "$actual" = "$expected" ]; then
            echo "OK       $file_name  $path"
            good=1
        else
            echo "MISMATCH $file_name  $path"
            echo "         expected=$expected"
            echo "         actual=$actual"
        fi
    done
    IFS=$old_ifs
    [ "$good" -eq 1 ] || status=1
}

verify eb55def2d4f2cdf5af37112bada641bc2888b110b22b967e32d87410f7a3f847 qsh_camera.json
verify 0321ac0c0b0aef5ce3269ffded770114b73e75966dd13680029beff7e6ff2d9e qsh_camera_ov02c10_2.json
verify aab68860361e258ad70e68b53430910c2201b239849c3ac76304a175fcecb994 ov02c10_2.pb
verify 705a226e166ab19e4dac5ba1f4e3c4525d66ce03e3ad58aac312bffd22e15672 com.qti.sensormodule.ov02c10.bin
verify 98c1065ad32be807d157836de4554a623675fc70a41d9eb069334d76b85d48d1 com.qti.tuned.ov02c10_be.bin
verify 98c1065ad32be807d157836de4554a623675fc70a41d9eb069334d76b85d48d1 com.qti.tuned.ov02c10_cg.bin
verify 723e34efd878ab5de3bbc11380aeabc7cf0ee49dfc9ae5a3c622c5fc9467d2ce com.qti.sensormodule.hm1092.bin
verify 935753caf705a06c13441ab0acf4eba4649519d08ac8d6f2db62c753f40ea23a com.qti.tuned.hm1092_be.bin
verify 935753caf705a06c13441ab0acf4eba4649519d08ac8d6f2db62c753f40ea23a com.qti.tuned.hm1092_cg.bin
verify bdeb071197c551b5acc1609403f55325537dcf2dded55a70d00b47e43c65b375 com.qti.tuned.hm1092_pw_be.bin
verify bdeb071197c551b5acc1609403f55325537dcf2dded55a70d00b47e43c65b375 com.qti.tuned.hm1092_pw_cg.bin

exit "$status"
