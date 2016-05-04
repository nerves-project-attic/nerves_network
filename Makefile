# Variables to override
#
# CC            C compiler
# CROSSCOMPILE	crosscompiler prefix, if any
# CFLAGS        compiler flags for compiling all C files
# LDFLAGS       linker flags for linking all binaries
# ERL_LDFLAGS   additional linker flags for projects referencing Erlang libraries
# MIX           path to mix
# SUDO_ASKPASS  path to ssh-askpass when modifying ownership of net_basic
# SUDO          path to SUDO. If you don't want the privileged parts to run, set to "true"

LDFLAGS += -lmnl
CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter
CC ?= $(CROSSCOMPILE)gcc
MIX ?= mix

# If not cross-compiling, then run sudo by default
ifeq ($(origin CROSSCOMPILE), undefined)
SUDO_ASKPASS ?= /usr/bin/ssh-askpass
SUDO ?= sudo
else
# If cross-compiling, then permissions need to be set some build system-dependent way
SUDO ?= true
endif

all: compile

compile:
	$(MIX) compile

test:
	$(MIX) test

%.o: %.c
	$(CC) -c $(CFLAGS) -o $@ $<

priv/udhcpc_wrapper: src/udhcpc_wrapper.o
	mkdir -p priv
	$(CC) $^ $(ERL_LDFLAGS) $(LDFLAGS) -o $@
	# setuid root net_basic so that it can configure network interfaces
	SUDO_ASKPASS=$(SUDO_ASKPASS) $(SUDO) -- sh -c 'chown root:root $@; chmod +s $@'

clean:
	$(MIX) clean
	rm -f priv/udhcpc_wrapper src/*.o

.PHONY: all compile test clean
