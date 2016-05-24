# Variables to override
#
# CC            C compiler
# CROSSCOMPILE	crosscompiler prefix, if any
# CFLAGS        compiler flags for compiling all C files
# LDFLAGS       linker flags for linking all binaries
# ERL_LDFLAGS   additional linker flags for projects referencing Erlang libraries
# MIX           path to mix
# SUDO_ASKPASS  path to ssh-askpass when modifying ownership of udhcpc_wrapper
# SUDO          path to SUDO. If you don't want the privileged parts to run, set to "true"

LDFLAGS +=
CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter
CFLAGS += -std=c99
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

.PHONY: all clean

all: priv/udhcpc_wrapper

%.o: %.c
	$(CC) -c $(CFLAGS) -o $@ $<

priv/udhcpc_wrapper: src/udhcpc_wrapper.o
	@mkdir -p priv
	$(CC) $^ $(ERL_LDFLAGS) $(LDFLAGS) -o $@
	# setuid root udhcpc_wrapper so that it can call udhcpc
	SUDO_ASKPASS=$(SUDO_ASKPASS) $(SUDO) -- sh -c 'chown root:root $@; chmod +s $@'

clean:
	$(MIX) clean
	rm -f priv/udhcpc_wrapper src/*.o
