# SPDX-License-Identifier: GPL-2.0-only
KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all modules: prepare
	$(MAKE) -C $(KDIR) M=$(PWD) modules

# DKMS/module builds only transform kernel source. Userspace/package fixes are
# applied by scripts/build-deb.sh before packaging.
prepare:
	python3 scripts/apply-hid-fnlock.py
	python3 -c 'from pathlib import Path; p=Path("hid_asus_ec.c"); s=p.read_text(); old="ret = asus_wmi_get_devstate_dsts(ASUS_WMI_DEVID_FNLOCK, &state);"; new="ret = asus_wmi_evaluate_method(ASUS_WMI_METHODID_DSTS,\\n\\t\\t\\t\\t       ASUS_WMI_DEVID_FNLOCK, 0, &state);"; p.write_text(s.replace(old, new))'

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
