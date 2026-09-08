# novadeck-splash — the boot / shutdown splash drawer.
#
# STATIC, aarch64, no shared libraries. Both halves of that are load-bearing and the reasons are
# in the header of src/novadeck-splash.c; the short version is that the build container's cross
# toolchain is a NEWER glibc than the image ships, so a dynamically linked binary would fail to
# load on the device — silently, which is indistinguishable from a splash that drew nothing.
#
# The host build (`make host`) produces an x86_64 binary for the offline layout tests. It is not
# shipped; it exists so tests/test-splash.sh can render every panel geometry in the device
# registry on the build host, which is the only fast feedback loop available on a board with no
# serial console.
#
#   make            aarch64 static -> build/novadeck-splash
#   make host       x86_64 (for tests) -> build/novadeck-splash.host
#   make install    DESTDIR=... PREFIX=/usr
#
# Run inside the build image (needs gcc-aarch64-linux-gnu, which carries the DRM uapi headers in
# its sysroot):
#   docker run --rm -v "$PWD":/src -w /src novadeck-build -c 'make -C apps/novadeck-splash'

CROSS   ?= aarch64-linux-gnu-
CC      := $(CROSS)gcc
HOSTCC  ?= cc
STRIP   := $(CROSS)strip

# -ffunction-sections/-Wl,--gc-sections claw back a chunk of what static glibc costs; the binary
# lands in the initramfs, where every KB is paid for on every boot.
CFLAGS  := -O2 -std=c11 -Wall -Wextra -Wno-unused-parameter \
           -ffunction-sections -fdata-sections
LDFLAGS := -static -Wl,--gc-sections

PREFIX  ?= /usr
DESTDIR ?=
BIN     := build/novadeck-splash
HOSTBIN := build/novadeck-splash.host
SRC     := src/novadeck-splash.c
DEPS    := src/novadeck-splash.c src/stb_truetype.h

.PHONY: all host clean install

all: $(BIN)

$(BIN): $(DEPS)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRC) -lm
	$(STRIP) $@
	@echo "[novadeck] splash: $@ ($$(du -h $@ | cut -f1), $$(file -b $@ | cut -d, -f1-2))"

# The host build only ever runs the ppm backend, but it compiles the DRM path too so that a
# mistake there is caught by `make host` rather than by a device that will not boot.
$(HOSTBIN): $(DEPS)
	@mkdir -p build
	$(HOSTCC) $(CFLAGS) -o $@ $(SRC) -lm

host: $(HOSTBIN)

clean:
	rm -rf build

install: $(BIN)
	install -Dm0755 $(BIN) $(DESTDIR)$(PREFIX)/lib/novadeck/novadeck-splash
