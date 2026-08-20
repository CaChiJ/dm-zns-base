# Standalone kernel test modules. Each one includes the source file under
# test directly, so a failing case shows up as a failing insmod.

obj-m += allocator-test.o
obj-m += memtable-test.o
obj-m += sstable-test.o
obj-m += zone-info-test.o

ccflags-y += -I$(src) -I$(src)/../../src

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

.PHONY: all clean
