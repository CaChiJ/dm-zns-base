ZNS_ENGINE ?= lsm
ZNS_GC_POLICY ?= simple

ifeq ($(filter $(ZNS_GC_POLICY),none simple),)
$(error ZNS_GC_POLICY must be none or simple)
endif

obj-m += dm-zns-base.o
dm-zns-base-y := dm-zns-base-main.o zns-allocator.o zns-zone.o lsm-memtable.o lsm-sstable.o lsm-super.o engines/zns-engine-$(ZNS_ENGINE).o
ifeq ($(ZNS_ENGINE),lsm)
dm-zns-base-y += gc-policy/zns-gc-$(ZNS_GC_POLICY).o
endif
ccflags-y += -I$(src)

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	@if [ -f .zns-gc-policy ] && [ "$$(cat .zns-gc-policy)" != "$(ZNS_GC_POLICY)" ]; then $(MAKE) -C $(KDIR) M=$(PWD) clean; fi
	@printf '%s\n' '$(ZNS_GC_POLICY)' > .zns-gc-policy
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
