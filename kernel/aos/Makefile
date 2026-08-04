# SPDX-License-Identifier: GPL-2.0-only
KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

obj-m += qcom_ssc_hpd.o
qcom_ssc_hpd-y := qcom_ssc_hpd_main.o qcom_ssc_hpd_protocol.o qcom_ssc_hpd_transport.o

all modules: qcom_ssc_hpd_main.c
	$(MAKE) -C $(KDIR) M=$(PWD) modules

# Keep the user-visible module name while avoiding a source/object collision.
qcom_ssc_hpd_main.c: qcom_ssc_hpd.c
	cp $< $@

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f qcom_ssc_hpd_main.c

.PHONY: all modules clean
