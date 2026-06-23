# novadeck master build orchestrator.
#
# Drives the whole Phase-1 pipeline — toolchain image, kernel, firmware, base
# rootfs, read-only root, boot artifact, SD card / RAUC bundle — as one incremental
# dependency graph so each stage rebuilds only when its inputs change. The individual
# stage scripts under kernel/ firmware/ images/ boot/ stay the source of truth; this
# file only wires them together and pins WHERE each one runs (host vs container).
#
# Quick start:
#   make sdcard SOC=sm8650   # full bring-up image -> out/<soc>/images/sdcard.img
#   make help                # list every target
#
# Conventions:
#   * SOC selects the target and is MANDATORY: `make kernel SOC=sm8650`.
#   * Container stages run in the novadeck-build image with the repo bind-mounted at
#     /src; host stages either need the network or drive docker themselves (base
#     customization registers qemu binfmt, so it cannot run nested in the container).
#   * Stamp files live under the already-gitignored out/ work/ firmware/ trees.
#
# Memory: builds cross-compile INSIDE docker, never on the host. Don't reorder the
# kernel patches. work/base/<soc> is root-owned (clean-base uses docker to remove it).

# SOC is mandatory — every per-SoC artifact path and stage script needs it, so there is no
# safe default. An empty/unset SOC is a caller error. Exempt are the goals that are NOT
# per-SoC: `help` (and a bare `make`, which defaults to help) so the target list is always
# reachable, plus the ARCH-scoped overlay goals `overlay`/`clean-overlay` (one aarch64 build
# under work/repo/<arch>/ serves every SoC — see OVERLAY_ARCH below, never $(SOC)).
SOC        ?=
SOC_EXEMPT := help overlay clean-overlay
ifneq ($(filter-out $(SOC_EXEMPT),$(MAKECMDGOALS)),)
ifeq ($(strip $(SOC)),)
$(error SOC is required — pass SOC=<soc>, e.g. `make kernel SOC=sm8650`)
endif
endif

BUILD_IMG ?= novadeck-build

# Optional knobs forwarded to the underlying scripts:
#   BASE_CONFIG  repo-relative path to a full verbatim kernel .config (e.g. a ROCKNIX
#                config) — skips the defconfig+fragment merge in kernel/build.sh.
#   VENDOR       path to a dump of YOUR device's vendor/modem partitions, for the
#                proprietary firmware extract (none ship in-repo).
#   VERSION      RAUC bundle version (defaults to the date inside genbundle.sh).
#   ESP          mounted EFI System Partition, for `make deploy`.
#   NOVADECK_TEST=1 + NOVADECK_WIFI_SSID/PSK + NOVADECK_SSH_PUBKEY  inject test-only
#                Wi-Fi/SSH creds into the rootfs (never part of a release build).
BASE_CONFIG ?=
VENDOR      ?=
VERSION     ?=

OUT := out/$(SOC)

# --- where each stage runs ----------------------------------------------------
# Container: repo bind-mounted at /src. INBUILD is the plain run; DOCKER lets a
# recipe insert `-e VAR` flags (which must precede the image name) before the image.
DOCKER   := docker run --rm -v $(CURDIR):/src -w /src
INBUILD := $(DOCKER) $(BUILD_IMG)
# Test-only credential env, forwarded into the rootfs assembler (no-op unless TEST=1).
TEST_ENV := -e NOVADECK_TEST -e NOVADECK_WIFI_SSID -e NOVADECK_WIFI_PSK -e NOVADECK_SSH_PUBKEY

# --- artifacts (real file targets drive incremental rebuilds) -----------------
BUILD_STAMP := out/.build-image.stamp
FW_LINUX     := firmware/linux-fw/$(SOC)/.fetched.stamp
FW_EXTRACT   := firmware/extracted/$(SOC)/sha256sums.txt
# The base tree is exported root-owned with the source image's FROZEN mtimes (e.g. sshd dates
# to the image build, not to this run), so it can't be the make target — a content change
# wouldn't bump any in-tree mtime and downstream stages would skip. A stamp outside that tree,
# touched after a successful customize, carries the real recency instead. It also lets a prebuilt-pin
# bump propagate: the pins are listed as prerequisites so editing one re-runs customize-base.
PREBUILT_PINS := $(wildcard packages/*/prebuilt.pin)
# From-source overlay packages (packages/*/source.pin + patches) — rebuilt holo packages with
# novadeck patches, landed in the local pacman repo work/repo/<soc>/ that customize-base.sh
# prepends ahead of the holo repos. The repo db is the make target; the pins+patches are
# prerequisites so a pin or patch change rebuilds the overlay (and then the base).
OVERLAY_PINS    := $(wildcard packages/*/source.pin)
OVERLAY_PATCHES := $(wildcard packages/*/patches/*.patch)
# Checked-in local PKGBUILDs (pkgbuild_local in a source.pin, e.g. packages/mesa/PKGBUILD) are
# build inputs too — track them so editing a recipe (deps, meson options) rebuilds the overlay.
OVERLAY_PKGBUILDS := $(wildcard packages/*/PKGBUILD)
# Overlay packages are ARCH-scoped, not SoC-scoped (a rebuilt aarch64 gamescope serves every
# aarch64 device), so the repo is shared at work/repo/<arch>/ across all SoCs.
OVERLAY_ARCH    ?= aarch64
OVERLAY_DB      := work/repo/$(OVERLAY_ARCH)/novadeck.db.tar.zst
BASE_STAMP   := work/base/$(SOC).stamp
KERNEL       := $(OUT)/Image.gz
ROOTFS       := $(OUT)/images/rootfs.img
BOOTIMG      := $(OUT)/boot/$(SOC)-boot.img
SDCARD       := $(OUT)/images/sdcard.img

# Repo sources the rootfs assembler reads directly (itself + the trees it copies in: the
# gamescope-session overlay and per-SoC InputPlumber config). find recurses, so files added
# under those trees are tracked automatically — no per-file Makefile edits as the image grows.
ASSEMBLE_SRC := $(shell find images/assemble-rootfs.sh session devices/$(SOC)/inputplumber -type f 2>/dev/null)

# Kernel inputs: any change re-triggers the (full, from-scratch) kernel build.
KERNEL_SRC := kernel/SOURCE.pin kernel/$(SOC)/$(SOC).config \
              $(wildcard kernel/$(SOC)/patches/*.patch) \
              $(wildcard kernel/$(SOC)/dts/qcom/*)

.DEFAULT_GOAL := help

# ==============================================================================
# Phony orchestration targets
# ==============================================================================
.PHONY: help all image toolchain kernel fw-linux fw-extract base overlay rootfs manifest \
        boot sdcard bundle deploy clean clean-base clean-overlay distclean

help: ## Show this help
	@echo "novadeck build — SOC=$(SOC)"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'
	@echo
	@echo "Knobs: SOC BASE_CONFIG VENDOR VERSION ESP NOVADECK_TEST(+creds)"

all: sdcard ## Alias for `sdcard` (the full bring-up image)

image: $(ROOTFS) ## Read-only Btrfs root only (out/<soc>/images/rootfs.img)

toolchain: $(BUILD_STAMP) ## Build the novadeck-build cross-compile docker image
kernel:    $(KERNEL)       ## Build Image.gz + dtbs + modules (in build container)
fw-linux:  $(FW_LINUX)     ## Fetch open linux-firmware blobs (host, network)
fw-extract: $(FW_EXTRACT)  ## Stage device firmware from VENDOR=<vendor-partition-tree>
overlay:   $(OVERLAY_DB)   ## Rebuild from-source overlay pkgs (patched gamescope) -> work/repo/<arch>/
base:      $(BASE_STAMP)   ## Fetch + customize the pinned aarch64 base rootfs (host)
rootfs:    $(ROOTFS)       ## Assemble the read-only root (kernel+fw+base, in container)
boot:      $(BOOTIMG)      ## Package the all-boards boot artifact (in container)
sdcard:    $(SDCARD)       ## Build the flashable SD-card image (in container)

# ==============================================================================
# Toolchain image
# ==============================================================================
$(BUILD_STAMP): build/Dockerfile
	docker build -t $(BUILD_IMG) -f build/Dockerfile build
	@mkdir -p $(@D) && touch $@

# ==============================================================================
# Firmware (host)
# ==============================================================================
# Open blobs (Adreno GPU, WCN7850 Wi-Fi/BT, Iris VPU) — pinned + verified, host network.
$(FW_LINUX): firmware/LINUX_FW.pin
	firmware/fetch-linux-fw.sh $(SOC)
	@touch $@

# Proprietary device blobs (zap shaders, DSP/modem) — extracted from YOUR device dump.
# No recipe can synthesize these; require a vendor tree. Once staged, the sha256 sidecar
# satisfies the target and downstream stages stop asking for VENDOR.
$(FW_EXTRACT):
	@if [ -z "$(VENDOR)" ]; then \
	  echo "extracted firmware missing for $(SOC)." >&2; \
	  echo "  pass a dump of your device's vendor/modem partitions:" >&2; \
	  echo "    make fw-extract SOC=$(SOC) VENDOR=/path/to/vendor-tree" >&2; \
	  exit 1; \
	fi
	firmware/extract.sh $(SOC) $(VENDOR)

# ==============================================================================
# From-source overlay packages (host — build-overlay.sh drives docker + qemu binfmt)
# ==============================================================================
# Rebuild holo packages with novadeck patches into the local pacman repo work/repo/<soc>/.
# Only when at least one source.pin exists does `base` depend on it (else nothing to build).
$(OVERLAY_DB): base-devel.digest $(OVERLAY_PINS) $(OVERLAY_PATCHES) $(OVERLAY_PKGBUILDS)
	packages/build-overlay.sh

# ==============================================================================
# Base rootfs (host — customize-base.sh drives docker + qemu binfmt itself)
# ==============================================================================
$(BASE_STAMP): base.digest $(PREBUILT_PINS)
	images/customize-base.sh $(SOC)
	@test -f work/base/$(SOC)/usr/bin/sshd   # sentinel: sshd present => release runtime layered in
	@touch $@   # recency marker outside the root-owned base tree (its own mtimes are frozen)

# A built overlay repo is an extra base input: customize-base installs the patched packages
# from it and folds its content hash into the reuse-cache key. Wire it as a prerequisite only
# when source.pin packages exist, so a repo with no overlay still builds normally.
ifneq ($(OVERLAY_PINS),)
$(BASE_STAMP): $(OVERLAY_DB)
endif

# ==============================================================================
# Kernel (container) — needs both firmware sets baked in (CONFIG_EXTRA_FIRMWARE)
# ==============================================================================
$(KERNEL): $(KERNEL_SRC) $(FW_LINUX) $(FW_EXTRACT) | $(BUILD_STAMP)
	$(DOCKER) $(if $(BASE_CONFIG),-e BASE_CONFIG=/src/$(BASE_CONFIG)) \
	  $(BUILD_IMG) kernel/build.sh $(SOC)

# Cross-check the device firmware manifest against the built kernel (non-fatal).
manifest: $(KERNEL) ## Verify firmware-manifest.txt vs the built kernel (in container)
	$(INBUILD) firmware/manifest.sh $(SOC)

# ==============================================================================
# Read-only root (container) — base userspace + kernel + firmware -> Btrfs image
# ==============================================================================
$(ROOTFS): $(KERNEL) $(BASE_STAMP) $(FW_LINUX) $(FW_EXTRACT) $(ASSEMBLE_SRC) | $(BUILD_STAMP)
	$(DOCKER) $(TEST_ENV) $(BUILD_IMG) \
	  images/assemble-rootfs.sh $(SOC) /src/work/base/$(SOC)

# ==============================================================================
# Boot artifact + bootable media (container)
# ==============================================================================
$(BOOTIMG): $(KERNEL) | $(BUILD_STAMP)
	$(INBUILD) boot/package.sh $(SOC)

$(SDCARD): $(BOOTIMG) $(ROOTFS) | $(BUILD_STAMP)
	$(INBUILD) images/make-sdcard.sh $(SOC)

# Signed RAUC OTA bundle (Phase 4). Dev builds mint an ephemeral cert; set
# RAUC_CERT/RAUC_KEY (repo-relative, so they resolve under /src) for a real signature.
bundle: $(ROOTFS) | $(BUILD_STAMP) ## Build a signed RAUC update bundle (in container)
	$(DOCKER) -e RAUC_CERT -e RAUC_KEY $(BUILD_IMG) \
	  images/genbundle.sh $(SOC) $(VERSION)

# ==============================================================================
# Deploy (host) — copy the all-boards KERNEL onto a mounted ESP
# ==============================================================================
deploy: $(BOOTIMG) ## Install the boot image onto ESP=<mountpoint>
	@test -n "$(ESP)" || { echo "pass ESP=<esp-mountpoint>" >&2; exit 2; }
	boot/deploy.sh $(SOC) $(ESP)

# ==============================================================================
# Cleaning
# ==============================================================================
clean: ## Remove built artifacts for SOC (out/<soc>), keep firmware/base caches
	rm -rf $(OUT)

# work/base/<soc> is root-owned (customize-base exports it as root), so a plain rm
# fails for the build user — remove it from inside a throwaway container as root.
clean-base: ## Remove the (root-owned) cached base rootfs for SOC
	docker run --rm -v $(CURDIR)/work/base:/wb busybox rm -rf /wb/$(SOC)
	rm -f $(BASE_STAMP)   # drop the recency marker too, else the next build skips a gone base

clean-overlay: ## Remove the built (arch-scoped) overlay pacman repo + build tree
	rm -rf work/repo work/overlay-build

distclean: clean clean-base clean-overlay ## clean + drop fetched/extracted firmware + kernel work tree
	rm -rf work/kernel/linux-$(SOC)* firmware/linux-fw/$(SOC) firmware/extracted/$(SOC)
