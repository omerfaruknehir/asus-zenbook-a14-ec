# SPDX-License-Identifier: GPL-2.0-only
KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all modules: prepare
	$(MAKE) -C $(KDIR) M=$(PWD) modules

prepare:
	python3 scripts/prepare-a14-ec.py
	@test ! -f scripts/apply-a14-lifecycle-hardening.py || python3 scripts/apply-a14-lifecycle-hardening.py
	@test ! -f scripts/apply-a14-hid-reset-resume.py || python3 scripts/apply-a14-hid-reset-resume.py
	@test ! -f scripts/apply-a14-bios312-coldboot.py || python3 scripts/apply-a14-bios312-coldboot.py
	@test ! -f scripts/apply-a14-fnlock-state.py || python3 scripts/apply-a14-fnlock-state.py
	@test ! -f scripts/clean-a14-generated-hid.py || python3 scripts/clean-a14-generated-hid.py

mainline-check:
	@test -n "$(KERNEL_SRC)" || { echo "Usage: make mainline-check KERNEL_SRC=/path/to/linux" >&2; exit 2; }
	sh ./scripts/a14-mainline-check.sh "$(KERNEL_SRC)"

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
	sh ./install.sh

deb: prepare
	sh ./scripts/build-deb.sh

gnome-native-install:
	sh ./scripts/a14-gnome-native-install.sh

gnome-validate:
	sh ./scripts/a14-gnome-profile-validation.sh

quiet-fanless-validate:
	sudo sh ./scripts/a14-quiet-fanless-validation.sh

quiet-emergency-validate:
	sudo sh ./scripts/a14-quiet-emergency-validation.sh

unify-normal-dtb:
	sh ./scripts/a14-unify-normal-dtb.sh

aos-probe:
	sudo sh ./scripts/a14-aos-kernel-probe.sh

aos-module:
	$(MAKE) -C kernel/aos KDIR=$(KDIR) W=1

aos-module-clean:
	$(MAKE) -C kernel/aos KDIR=$(KDIR) clean

aos-firmware-verify:
	@test -n "$(DIR)" || { echo "Usage: make aos-firmware-verify DIR=/path/to/extracted/files" >&2; exit 2; }
	sh ./scripts/verify-a14-aos-firmware.sh "$(DIR)"

dmesg:
	dmesg --ctime | grep -E 'asus_zenbook_a14_ec|hid_asus_zenbook_a14_ec|asus::kbd_backlight|Fn-lock' | tail -n 80

.PHONY: all modules prepare mainline-check clean load-hid load-ec unload-ec reload-ec install-deb deb gnome-native-install gnome-validate quiet-fanless-validate quiet-emergency-validate unify-normal-dtb aos-probe aos-module aos-module-clean aos-firmware-verify dmesg
