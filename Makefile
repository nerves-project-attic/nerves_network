# Variables to override
#
# CC            C compiler. MUST be set if crosscompiling
# CROSSCOMPILE	crosscompiler prefix, if any
# CFLAGS        compiler flags for compiling all C files
# LDFLAGS       linker flags for linking all binaries
# ERL_LDFLAGS   additional linker flags for projects referencing Erlang libraries
# SUDO_ASKPASS  path to ssh-askpass when modifying ownership of udhcpc_wrapper
# SUDO          path to SUDO. If you don't want the privileged parts to run, set to "true"

# Check that we're on a supported build platform
ifeq ($(CROSSCOMPILE),)
    # Not crosscompiling, so check that we're on Linux.
    ifneq ($(shell uname -s),Linux)
        $(warning nerves_network only works on Linux, but crosscompilation)
        $(warning is supported by defining $$CROSSCOMPILE and $$ERL_LDFLAGS.)
        $(warning See Makefile for details. If using Nerves,)
        $(warning this should be done automatically.)
        $(warning .)
        $(warning Skipping C compilation unless targets explicitly passed to make.)
	DEFAULT_TARGETS = priv
    endif
endif
DEFAULT_TARGETS ?= priv priv/udhcpc_wrapper
DEFAULT_TARGETS += priv/dhclient_wrapper

LDFLAGS +=
CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter
CFLAGS += -std=c99

# If not cross-compiling, then run sudo by default
ifeq ($(origin CROSSCOMPILE), undefined)
SUDO_ASKPASS ?= /usr/bin/ssh-askpass
SUDO ?= sudo
else
# If cross-compiling, then permissions need to be set some build system-dependent way
SUDO ?= true
endif

.PHONY: all clean

all: $(DEFAULT_TARGETS)

%.o: %.c
	$(CC) -c $(CFLAGS) -o $@ $<

priv:
	mkdir -p priv

priv/udhcpc_wrapper: src/udhcpc_wrapper.o
	$(CC) $^ $(ERL_LDFLAGS) $(LDFLAGS) -o $@
	# setuid root udhcpc_wrapper so that it can call udhcpc
	SUDO_ASKPASS=$(SUDO_ASKPASS) $(SUDO) -- sh -c 'chown root:root $@; chmod +s $@'

priv/dhclient_wrapper: src/dhclient_wrapper.o
	$(CC) $^ $(ERL_LDFLAGS) $(LDFLAGS) -o $@
	# setuid root udhcpc_wrapper so that it can call udhcpc
	SUDO_ASKPASS=$(SUDO_ASKPASS) $(SUDO) -- sh -c 'chown root:root $@; chmod +s $@'

clean:
	rm -f priv/udhcpc_wrapper src/*.o
