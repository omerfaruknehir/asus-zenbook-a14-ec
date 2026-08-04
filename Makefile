# SPDX-License-Identifier: GPL-2.0-only
KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

.PHONY: all modules prepare clean load unload reload dmesg install uninstall deb

all: modules

prepare:
	python3 scripts/apply-safety-fixes.py

modules: prepare
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

load: modules
	sudo modprobe platform_profile || true
	sudo insmod ./asus_zenbook_a14_ec.ko
	sudo insmod ./hid_asus_ec.ko || true

unload:
	-sudo rmmod asus_zenbook_a14_ec
	-sudo rmmod hid_asus_ec

reload: unload load

dmesg:
	dmesg --ctime | grep -E 'asus_zenbook_a14_ec|hid_asus_ec|asus.ec' | tail -n 80

install:
	./scripts/install.sh

uninstall:
	./scripts/uninstall.sh

deb:
	./scripts/build-deb.sh
