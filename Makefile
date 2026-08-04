# SPDX-License-Identifier: GPL-2.0-only
KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all modules: prepare
	$(MAKE) -C $(KDIR) M=$(PWD) modules

prepare:
	python3 scripts/apply-hid-fnlock.py
	python3 scripts/apply-userspace-fixes.py

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -rf dist

load-hid:
	sudo modprobe hid_asus_ec

load-ec:
	sudo modprobe asus_zenbook_a14_ec

unload-ec:
	sudo modprobe -r asus_zenbook_a14_ec

reload-ec: unload-ec load-ec

install-deb:
	./install.sh

deb:
	./scripts/build-deb.sh

dmesg:
	dmesg --ctime | grep -E 'asus_zenbook_a14_ec|hid_asus_zenbook_a14_ec|asus::kbd_backlight|Fn lock' | tail -n 80

.PHONY: all modules prepare clean load-hid load-ec unload-ec reload-ec install-deb deb dmesg
