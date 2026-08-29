CC ?= cc
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -Wall -Wextra -Werror

.PHONY: all clean

all: versioned-io byte-io

versioned-io: versioned-io.c
	$(CC) $(CFLAGS) -o $@ $<

byte-io: byte-io.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	$(RM) versioned-io byte-io
