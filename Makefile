# SPDX-License-Identifier: GPL-2.0-only
KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all modules: prepare
	$(MAKE) -C $(KDIR) M=$(PWD) modules

# Compose only when the source is stale or pristine. The transforms intentionally
# build on one another. POLICY_V2 distinguishes acoustic Quiet from desktop
# Power Saver; emergency notifications expose escalation; TRANSACTIONAL makes
# firmware fan ownership, native policy, CPU QoS and emergency state switch as
# one coherent unit with rollback on failure.
prepare:
	@if grep -Eq '^#define EC_FW_WAIT_MIN_US[[:space:]]+100000$$' asus_zenbook_a14_ec.c && \
	   grep -Eq '^#define EC_FW_WAIT_MAX_US[[:space:]]+110000$$' asus_zenbook_a14_ec.c && \
	   grep -q 'EC_FW_FAN_PROFILE_FULL_SPEED' asus_zenbook_a14_ec.c && \
	   grep -q 'EC_NATIVE_FAN1_RPM_LO' asus_zenbook_a14_ec.c && \
	   grep -q 'PLATFORM_PROFILE_MAX_POWER' asus_zenbook_a14_ec.c && \
	   grep -q 'A14_PROFILE_POLICY_V2' asus_zenbook_a14_ec.c && \
	   grep -q 'A14_PROFILE_EMERGENCY_NOTIFY' asus_zenbook_a14_ec.c && \
	   grep -q 'A14_PROFILE_TRANSACTIONAL' asus_zenbook_a14_ec.c && \
	   grep -q 'ASUS_EC_PROFILE_POWER_SAVER' asus_zenbook_a14_ec.c && \
	   grep -q 'asus_ec_set_pwm_both(ec, 255)' asus_zenbook_a14_ec.c; then \
		echo 'a14_ec_stack=current'; \
	else \
		python3 scripts/apply-a14-ec-hardening.py && \
		python3 scripts/apply-a14-native-fan-profile.py && \
		python3 scripts/apply-a14-native-hardening-compat.py && \
		python3 scripts/apply-a14-native-max-power.py && \
		python3 scripts/apply-a14-native-fan-telemetry.py && \
		python3 scripts/apply-a14-profile-policy-v2.py && \
		python3 scripts/apply-a14-profile-emergency-notify.py && \
		python3 scripts/apply-a14-profile-transactional.py; \
	fi
	python3 scripts/apply-a14-hid-fnlock.py

mainline-check:
	@test -n "$(KERNEL_SRC)" || { echo "Usage: make mainline-check KERNEL_SRC=/path/to/linux" >&2; exit 2; }
	./scripts/a14-mainline-check.sh "$(KERNEL_SRC)"

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	$(MAKE) -C kernel/aos clean KDIR=$(KDIR) >/dev/null 2>&1 || true
	rm -rf dist

load-hid:
	sudo modprobe hid_asus_ec

load-ec:
	sudo modprobe asus_zenbook_a14_ec

unload-ec:
	sudo modprobe -r asus_zenbook_a14_ec

reload-ec: unload-ec load-ec

install-deb: prepare
	./install.sh

deb: prepare
	./scripts/build-deb.sh

aos-probe:
	sudo ./scripts/a14-aos-kernel-probe.sh

aos-module:
	$(MAKE) -C kernel/aos KDIR=$(KDIR) W=1

aos-module-clean:
	$(MAKE) -C kernel/aos KDIR=$(KDIR) clean

aos-firmware-verify:
	@test -n "$(DIR)" || { echo "Usage: make aos-firmware-verify DIR=/path/to/extracted/files" >&2; exit 2; }
	./scripts/verify-a14-aos-firmware.sh "$(DIR)"

dmesg:
	dmesg --ctime | grep -E 'asus_zenbook_a14_ec|hid_asus_zenbook_a14_ec|asus::kbd_backlight|Fn-lock' | tail -n 80

.PHONY: all modules prepare mainline-check clean load-hid load-ec unload-ec reload-ec install-deb deb aos-probe aos-module aos-module-clean aos-firmware-verify dmesg
