# novadeck master build orchestrator.
#
# Drives the whole Phase-1 pipeline — toolchain image, kernel, firmware, base
# rootfs, read-only root, boot artifact, SD card / RAUC bundle — as one incremental
# dependency graph so each stage rebuilds only when its inputs change. The individual
# stage scripts under kernel/ firmware/ images/ boot/ stay the source of truth; this
# file only wires them together and pins WHERE each one runs (host vs container).
#
# Quick start:
#   make sdcard        # full bring-up image -> out/images/sdcard.img
#   make help          # list every target
#
# Conventions:
#   * The build is UNIFIED — one image serves every supported SoC/board. There is no SOC
#     argument: the kernel is built with the union of all config fragments, patches and
#     device trees (kernel/), and the boot artifact bundles every board DTB (the ABL DTB
#     picker selects at boot).
#   * Container stages run in the novadeck-build image with the repo bind-mounted at
#     /src; host stages either need the network or drive docker themselves (base
#     customization registers qemu binfmt, so it cannot run nested in the container).
#   * Stamp files live under the already-gitignored out/ work/ firmware/ trees.
#
# Memory: builds cross-compile INSIDE docker, never on the host. Don't reorder the
# kernel patches. work/base is root-owned (clean-base uses docker to remove it).

BUILD_IMG ?= novadeck-build

# Optional knobs forwarded to the underlying scripts:
#   BASE_CONFIG  repo-relative path to a full verbatim kernel .config (e.g. a ROCKNIX
#                config) — skips the defconfig+fragment merge in kernel/build.sh.
#   VERSION      RAUC bundle version (defaults to the date inside genbundle.sh).
#   ESP          mounted EFI System Partition, for `make deploy`.
#   NOVADECK_TEST=1 + NOVADECK_WIFI_SSID/PSK + NOVADECK_SSH_PUBKEY  inject test-only
#                Wi-Fi/SSH creds into the rootfs (never part of a release build).
BASE_CONFIG ?=
VERSION     ?=

OUT := out

# --- where each stage runs ----------------------------------------------------
# Container: repo bind-mounted at /src. INBUILD is the plain run; DOCKER lets a
# recipe insert `-e VAR` flags (which must precede the image name) before the image.
DOCKER   := docker run --rm -v $(CURDIR):/src -w /src
INBUILD := $(DOCKER) $(BUILD_IMG)
# Test-only credential env, forwarded into the rootfs assembler (no-op unless TEST=1).
TEST_ENV := -e NOVADECK_TEST -e NOVADECK_WIFI_SSID -e NOVADECK_WIFI_PSK -e NOVADECK_SSH_PUBKEY

# --- artifacts (real file targets drive incremental rebuilds) -----------------
BUILD_STAMP := out/.build-image.stamp
# Open linux-firmware blobs are SoC-agnostic — the unified kernel embeds the union — so this
# is a single flat tree, not per-SoC.
FW_LINUX     := firmware/linux-fw/.fetched.stamp
# Device-proprietary blobs are SoC-agnostic (the qcom-firmwares repo mirrors /lib/firmware,
# blobs self-namespaced by their on-device path), so this is shared across all SoCs.
FW_QCOM      := firmware/qcom-fw/sha256sums.txt
# The base tree is exported root-owned with the source image's FROZEN mtimes (e.g. sshd dates
# to the image build, not to this run), so it can't be the make target — a content change
# wouldn't bump any in-tree mtime and downstream stages would skip. A stamp outside that tree,
# touched after a successful customize, carries the real recency instead. It also lets a prebuilt-pin
# bump propagate: the pins are listed as prerequisites so editing one re-runs customize-base.
PREBUILT_PINS := $(wildcard packages/*/prebuilt.pin)
# From-source overlay packages (packages/*/source.pin + patches) — rebuilt holo packages with
# novadeck patches, landed in the local pacman repo work/repo/<arch>/ that customize-base.sh
# prepends ahead of the holo repos. The repo db is the make target; the pins+patches are
# prerequisites so a pin or patch change rebuilds the overlay (and then the base).
OVERLAY_PINS    := $(wildcard packages/*/source.pin)
OVERLAY_PATCHES := $(wildcard packages/*/patches/*.patch)
# Checked-in local PKGBUILDs (pkgbuild_local in a source.pin, e.g. packages/mesa/PKGBUILD) are
# build inputs too — track them so editing a recipe (deps, meson options) rebuilds the overlay.
OVERLAY_PKGBUILDS := $(wildcard packages/*/PKGBUILD)
# Overlay packages are ARCH-scoped (a rebuilt aarch64 gamescope serves every aarch64 device),
# so the repo is shared at work/repo/<arch>/.
OVERLAY_ARCH    ?= aarch64
OVERLAY_DB      := work/repo/$(OVERLAY_ARCH)/novadeck.db.tar.zst
BASE_STAMP   := work/.base.stamp
KERNEL       := $(OUT)/Image.gz
ROOTFS       := $(OUT)/images/rootfs.img
BOOTIMG      := $(OUT)/boot/novadeck-boot.img
SDCARD       := $(OUT)/images/sdcard.img
# Native arm64 Steam SEED baked into the RO root (steam/fetch-steam-seed.sh, host network). The
# client binary it stages is the make target; the pin + fetcher are its prerequisites.
STEAM_SEED   := work/steam-seed/steamrtarm64/steam

# Repo sources the rootfs assembler reads directly (itself + the trees it copies in: the
# gamescope-session overlay, the HW-support overlay, and InputPlumber config). find recurses,
# so files added under those trees are tracked automatically — no per-file Makefile edits.
ASSEMBLE_SRC := $(shell find images/assemble-rootfs.sh session hw-support steam audio devices/inputplumber -type f 2>/dev/null)

# Kernel inputs: any change re-triggers the (full, from-scratch) kernel build. The unified
# kernel globs every fragment/patch/dts, and bakes the firmware embed list + common cmdline.
KERNEL_SRC := kernel/SOURCE.pin kernel/embed.list boot/cmdline \
              $(wildcard kernel/*.config) \
              $(wildcard kernel/patches/*.patch) \
              $(wildcard kernel/dts/qcom/*)

.DEFAULT_GOAL := help

# ==============================================================================
# Phony orchestration targets
# ==============================================================================
.PHONY: help all image toolchain kernel fw-linux fw-qcom base overlay rootfs manifest \
        boot sdcard bundle deploy clean clean-base clean-overlay distclean

help: ## Show this help
	@echo "novadeck build — unified image (all SoCs/boards)"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'
	@echo
	@echo "Knobs: BASE_CONFIG VERSION ESP NOVADECK_TEST(+creds)"

all: sdcard ## Alias for `sdcard` (the full bring-up image)

image: $(ROOTFS) ## Read-only Btrfs root only (out/images/rootfs.img)

toolchain: $(BUILD_STAMP) ## Build the novadeck-build cross-compile docker image
kernel:    $(KERNEL)       ## Build Image.gz + all dtbs + modules (in build container)
fw-linux:  $(FW_LINUX)     ## Fetch open linux-firmware blobs (host, network)
fw-qcom:   $(FW_QCOM)      ## Fetch device-proprietary firmware from the qcom-firmwares repo (host, network)
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
	firmware/fetch-linux-fw.sh
	@touch $@

# Device-proprietary blobs (zap shaders, DSP/modem, tplg, ath12k, Renesas) — fetched from the
# pinned Nova-Deck/qcom-firmwares repo + verified against its sha256sums.txt. The repo's sha
# sidecar lands as the target; @touch bumps recency past the pin (cp -a preserves old mtimes).
$(FW_QCOM): firmware/QCOM_FW.pin
	firmware/fetch-qcom-fw.sh
	@touch $@

# Native arm64 Steam seed (client + SR3 runtime) — fetched on the host, staged into work/steam-seed/
# and baked into the RO root by assemble-rootfs. Pinned channel/runtime in steam/STEAM_SEED.pin.
$(STEAM_SEED): steam/STEAM_SEED.pin steam/fetch-steam-seed.sh
	steam/fetch-steam-seed.sh
	@touch $@

# ==============================================================================
# From-source overlay packages (host — build-overlay.sh drives docker + qemu binfmt)
# ==============================================================================
# Rebuild holo packages with novadeck patches into the local pacman repo work/repo/<arch>/.
# Only when at least one source.pin exists does `base` depend on it (else nothing to build).
$(OVERLAY_DB): base-devel.digest $(OVERLAY_PINS) $(OVERLAY_PATCHES) $(OVERLAY_PKGBUILDS)
	packages/build-overlay.sh

# ==============================================================================
# Base rootfs (host — customize-base.sh drives docker + qemu binfmt itself)
# ==============================================================================
$(BASE_STAMP): base.digest $(PREBUILT_PINS)
	images/customize-base.sh
	@test -f work/base/usr/bin/sshd   # sentinel: sshd present => release runtime layered in
	@mkdir -p $(@D) && touch $@   # recency marker outside the root-owned base tree (frozen mtimes)

# A built overlay repo is an extra base input: customize-base installs the patched packages
# from it and folds its content hash into the reuse-cache key. Wire it as a prerequisite only
# when source.pin packages exist, so a repo with no overlay still builds normally.
ifneq ($(OVERLAY_PINS),)
$(BASE_STAMP): $(OVERLAY_DB)
endif

# ==============================================================================
# Kernel (container) — needs both firmware sets baked in (CONFIG_EXTRA_FIRMWARE)
# ==============================================================================
$(KERNEL): $(KERNEL_SRC) $(FW_LINUX) $(FW_QCOM) | $(BUILD_STAMP)
	$(DOCKER) $(if $(BASE_CONFIG),-e BASE_CONFIG=/src/$(BASE_CONFIG)) \
	  $(BUILD_IMG) kernel/build.sh

# Cross-check the device firmware manifest against the built kernel (non-fatal).
manifest: $(KERNEL) ## Verify firmware-manifest.txt vs the built kernel (in container)
	$(INBUILD) firmware/manifest.sh

# ==============================================================================
# Read-only root (container) — base userspace + kernel + firmware -> Btrfs image
# ==============================================================================
$(ROOTFS): $(KERNEL) $(BASE_STAMP) $(FW_LINUX) $(FW_QCOM) $(STEAM_SEED) $(ASSEMBLE_SRC) | $(BUILD_STAMP)
	$(DOCKER) $(TEST_ENV) $(BUILD_IMG) \
	  images/assemble-rootfs.sh /src/work/base

# ==============================================================================
# Boot artifact + bootable media (container)
# ==============================================================================
$(BOOTIMG): $(KERNEL) | $(BUILD_STAMP)
	$(INBUILD) boot/package.sh

$(SDCARD): $(BOOTIMG) $(ROOTFS) | $(BUILD_STAMP)
	$(INBUILD) images/make-sdcard.sh

# Signed RAUC OTA bundle (Phase 4). Dev builds mint an ephemeral cert; set
# RAUC_CERT/RAUC_KEY (repo-relative, so they resolve under /src) for a real signature.
bundle: $(ROOTFS) | $(BUILD_STAMP) ## Build a signed RAUC update bundle (in container)
	$(DOCKER) -e RAUC_CERT -e RAUC_KEY $(BUILD_IMG) \
	  images/genbundle.sh $(VERSION)

# ==============================================================================
# Deploy (host) — copy the all-boards KERNEL onto a mounted ESP
# ==============================================================================
deploy: $(BOOTIMG) ## Install the boot image onto ESP=<mountpoint>
	@test -n "$(ESP)" || { echo "pass ESP=<esp-mountpoint>" >&2; exit 2; }
	boot/deploy.sh $(ESP)

# ==============================================================================
# Cleaning
# ==============================================================================
# out/ is partly root-owned: the container stages (kernel modules_install, rootfs assembly,
# sdcard) run as root in the build image, so a host-side rm fails on e.g. out/modroot. Remove
# the artifacts from inside a throwaway container as root, like clean-base. (out/.build-image.stamp
# is host-owned and deliberately kept so the toolchain image isn't rebuilt.)
clean: ## Remove built artifacts (out/), keep firmware/base caches + toolchain stamp
	docker run --rm -v $(CURDIR)/out:/wo busybox rm -rf /wo/Image.gz /wo/dtbs /wo/modroot /wo/images /wo/boot

# work/base is root-owned (customize-base exports it as root), so a plain rm fails for the
# build user — remove it from inside a throwaway container as root.
clean-base: ## Remove the (root-owned) cached base rootfs
	docker run --rm -v $(CURDIR)/work:/wb busybox rm -rf /wb/base
	rm -f $(BASE_STAMP)   # drop the recency marker too, else the next build skips a gone base

clean-overlay: ## Remove the built (arch-scoped) overlay pacman repo + build tree
	rm -rf work/repo work/overlay-build

distclean: clean clean-base clean-overlay ## clean + drop fetched firmware + kernel work tree
	# work/kernel is root-owned (the kernel build's modules_install runs as root in the build
	# image), so remove it from inside a throwaway container like clean/clean-base — a host-side
	# rm fails with permission errors. work/steam-seed (host-fetched) goes the same way for
	# uniformity. firmware/* are fetched on the host, so a plain rm is fine.
	docker run --rm -v $(CURDIR)/work:/wb busybox rm -rf /wb/kernel /wb/steam-seed
	rm -rf firmware/linux-fw firmware/qcom-fw
