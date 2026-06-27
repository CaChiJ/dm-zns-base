ZNS_ENGINE ?= append4k

obj-m += dm-zns-base.o
dm-zns-base-y := dm-zns-base-main.o engines/zns-engine-$(ZNS_ENGINE).o
ccflags-y += -I$(src)

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
