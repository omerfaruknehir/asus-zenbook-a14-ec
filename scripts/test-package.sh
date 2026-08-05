#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"
sh -n install.sh scripts/build-deb.sh scripts/asus-a14-control \
  scripts/asus-zenbook-a14-ec-load scripts/asus-zenbook-a14-ec-unload \
  scripts/a14-aos-kernel-probe.sh scripts/verify-a14-aos-firmware.sh
python3 -m py_compile \
  scripts/asus-zenbook-a14-ppd-bridge.py \
  desktop/resources/apply-a14-cpu-info.py \
  desktop/resources/test-patcher.py
python3 desktop/resources/test-patcher.py
version=$(cat VERSION)
grep -q "PACKAGE_VERSION=\"$version\"" dkms.conf
test -s AOS-KERNEL-BRINGUP.md
test -s docs/aos/ARCHITECTURE.md
test -s docs/aos/PROBE-20260804.md
test -s firmware/aos/manifest.sha256
test -s kernel-patches/aos/README.md
test -s desktop/README.md
test -s desktop/resources/README.md
test -s desktop/resources/apply-a14-cpu-info.py
test -s kernel/aos/qcom_ssc_hpd.c
test -s kernel/aos/qcom_ssc_hpd_protocol.c
test -s kernel/aos/qcom_ssc_hpd_transport.c
test -s kernel/aos/qcom_ssc_hpd_internal.h
test -s kernel/aos/PROTOCOL.md
grep -q 'read_only=true' scripts/a14-aos-kernel-probe.sh
grep -q 'remoteproc_restart=false' scripts/a14-aos-kernel-probe.sh
grep -q 'A14_SSC_QMI_SERVICE.*400' kernel/aos/qcom_ssc_hpd_internal.h
grep -q 'qmi_add_lookup' kernel/aos/qcom_ssc_hpd.c
grep -q 'IIO_PROXIMITY' kernel/aos/qcom_ssc_hpd.c
grep -q 'A14_RESOURCES_CPU_INFO_V1' desktop/resources/apply-a14-cpu-info.py
grep -q '/sys/devices/system/cpu/online' desktop/resources/apply-a14-cpu-info.py
grep -q 'qcom,x1e80100' desktop/resources/apply-a14-cpu-info.py
if [ -e "/lib/modules/$(uname -r)/build/Makefile" ]; then
  kdir="/lib/modules/$(uname -r)/build"
  make clean >/dev/null 2>&1 || true
  make -j2

  if [ -r "$kdir/include/linux/soc/qcom/qmi.h" ] && \
     [ -r "$kdir/include/linux/iio/iio.h" ]; then
    config=
    if [ -r "$kdir/.config" ]; then
      config="$kdir/.config"
    elif [ -r "/boot/config-$(uname -r)" ]; then
      config="/boot/config-$(uname -r)"
    fi

    if [ -n "$config" ] && \
       grep -Eq '^CONFIG_QCOM_QMI_HELPERS=[ym]$' "$config" && \
       grep -Eq '^CONFIG_IIO=[ym]$' "$config"; then
      make aos-module
    else
      # Generic CI kernels may ship the public headers without exporting the
      # Qualcomm QMI/IIO symbols. Still compile every translation unit with
      # W=1; relax only modpost's target-kernel symbol availability check.
      make -C kernel/aos KDIR="$kdir" W=1 KBUILD_MODPOST_WARN=1
    fi
    test -s kernel/aos/qcom_ssc_hpd.ko
    make aos-module-clean >/dev/null
  fi
fi
./scripts/build-deb.sh >/dev/null
test -s "dist/asus-zenbook-a14-ec-dkms_${version}_all.deb"
dpkg-deb --info "dist/asus-zenbook-a14-ec-dkms_${version}_all.deb" >/dev/null
contents=$(dpkg-deb --contents "dist/asus-zenbook-a14-ec-dkms_${version}_all.deb")
printf '%s\n' "$contents" | grep -q "usr/src/asus-zenbook-a14-ec-${version}/asus_zenbook_a14_ec.c"
printf '%s\n' "$contents" | grep -q "usr/lib/systemd/system/asus-zenbook-a14-ec.service"
printf '%s\n' "$contents" | grep -q "usr/lib/systemd/system/asus-zenbook-a14-ppd-bridge.service"
printf '%s\n' "$contents" | grep -q "usr/libexec/asus-zenbook-a14-ppd-bridge"
if printf '%s\n' "$contents" | grep -q 'kernel/aos\|qcom_ssc_hpd\|desktop/resources\|apply-a14-cpu-info'; then
  echo "Development drivers and desktop source patches must not be included in the EC package" >&2
  exit 1
fi
echo "Validation passed"
