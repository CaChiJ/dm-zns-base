obj-m += allocator-test.o
obj-m += memtable-test.o
obj-m += zone-info-test.o
obj-m += sstable-test.o
ccflags-y += -I$(src)/../src

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
