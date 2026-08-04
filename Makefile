# SPDX-License-Identifier: GPL-2.0-only

KDIR ?= /lib/modules/$(shell uname -r)/build
ROOT := $(abspath .)
BUILD_DIR := $(ROOT)/build-src
DIST_DIR := $(ROOT)/dist

all: prepare
	$(MAKE) -C $(KDIR) M=$(BUILD_DIR) modules

prepare:
	python3 scripts/prepare-source.py --source $(ROOT) --output $(BUILD_DIR)
	python3 scripts/finalize-source.py --source $(BUILD_DIR)

clean:
	@if [ -d "$(KDIR)" ] && [ -d "$(BUILD_DIR)" ]; then \
		$(MAKE) -C $(KDIR) M=$(BUILD_DIR) clean; \
	fi
	rm -rf $(BUILD_DIR)

check: prepare
	python3 -m py_compile scripts/prepare-source.py scripts/finalize-source.py
	bash -n scripts/build-deb.sh scripts/install.sh tools/a14-ecctl

load: all
	sudo insmod $(BUILD_DIR)/hid_asus_ec.ko || true
	sudo insmod $(BUILD_DIR)/asus_zenbook_a14_ec.ko probe_delay_ms=1500

unload:
	-sudo rmmod asus_zenbook_a14_ec
	-sudo rmmod hid_asus_ec

reload: unload load

dmesg:
	dmesg --ctime | grep -E 'asus_zenbook_a14_ec|hid-asus-ec|asus.ec' | tail -n 80

deb:
	bash scripts/build-deb.sh

install-deb: deb
	sudo apt install ./dist/asus-zenbook-a14-ec-dkms_*.deb

.PHONY: all prepare clean check load unload reload dmesg deb install-deb
