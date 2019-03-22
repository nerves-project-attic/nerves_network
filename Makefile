# Makefile for building port binaries
#
# Makefile targets:
#
# all/install   build and install the NIF
# clean         clean build products and intermediates
#
# Variables to override:
#
# MIX_COMPILE_PATH path to the build's ebin directory
#
# CC            C compiler
# CROSSCOMPILE	crosscompiler prefix, if any
# CFLAGS	compiler flags for compiling all C files
# LDFLAGS	linker flags for linking all binaries
# ERL_LDFLAGS	additional linker flags for projects referencing Erlang libraries
# SUDO_ASKPASS  path to ssh-askpass when modifying ownership of udhcpc_wrapper
# SUDO          path to SUDO. If you don't want the privileged parts to run, set to "true"

ifeq ($(MIX_COMPILE_PATH),)
	$(error MIX_COMPILE_PATH should be set by elixir_make!)
endif

PREFIX = $(MIX_COMPILE_PATH)/../priv
BUILD  = $(MIX_COMPILE_PATH)/../obj

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
	DEFAULT_TARGETS = $(PREFIX)
    endif
endif

DEFAULT_TARGETS ?= $(PREFIX) $(PREFIX)/udhcpc_wrapper $(PREFIX)/dhclient_wrapper $(PREFIX)/dhclientv4_wrapper

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

calling_from_make:
	mix compile

all: install

install: $(BUILD) $(DEFAULT_TARGETS)

$(BUILD)/%.o: src/%.c
	$(CC) -c $(CFLAGS) -o $@ $<

$(PREFIX)/udhcpc_wrapper: $(BUILD)/udhcpc_wrapper.o
	$(CC) $^ $(ERL_LDFLAGS) $(LDFLAGS) -o $@
	# setuid root udhcpc_wrapper so that it can call udhcpc
	SUDO_ASKPASS=$(SUDO_ASKPASS) $(SUDO) -- sh -c 'chown root:root $@; chmod +s $@'

$(PREFIX)/dhclient_wrapper: $(BUILD)/dhclient_wrapper.o
	$(CC) $^ $(ERL_LDFLAGS) $(LDFLAGS) -o $@
	# setuid root udhcpc_wrapper so that it can call udhcpc
	SUDO_ASKPASS=$(SUDO_ASKPASS) $(SUDO) -- sh -c 'chown root:root $@; chmod +s $@'

$(PREFIX)/dhclientv4_wrapper: $(BUILD)/dhclientv4_wrapper.o
	$(CC) $^ $(ERL_LDFLAGS) $(LDFLAGS) -o $@
	# setuid root udhcpc_wrapper so that it can call udhcpc
	SUDO_ASKPASS=$(SUDO_ASKPASS) $(SUDO) -- sh -c 'chown root:root $@; chmod +s $@'

clean:
	rm -f priv/udhcpc_wrapper priv/dhclient_wrapper src/*.o

$(PREFIX):
	mkdir -p $@

$(BUILD):
	mkdir -p $@

clean:
	$(RM) -f $(PREFIX)/udhcpc_wrapper $(PREFIX)/dhclient_wrapper $(PREFIX)/dhclientv4_wrapper $(BUILD)/*.o

.PHONY: all clean calling_from_make install
