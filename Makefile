# SPDX-License-Identifier: GPL-2.0-only
KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all modules:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

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

aos-probe:
	sudo ./scripts/a14-aos-kernel-probe.sh

aos-firmware-verify:
	@test -n "$(DIR)" || { echo "Usage: make aos-firmware-verify DIR=/path/to/extracted/files" >&2; exit 2; }
	./scripts/verify-a14-aos-firmware.sh "$(DIR)"

dmesg:
	dmesg --ctime | grep -E 'asus_zenbook_a14_ec|hid_asus_zenbook_a14_ec|asus::kbd_backlight' | tail -n 80

.PHONY: all modules clean load-hid load-ec unload-ec reload-ec install-deb deb aos-probe aos-firmware-verify dmesg
