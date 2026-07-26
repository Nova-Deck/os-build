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

# work/ must be created by the HOST, and before anything else runs. Several stages that write
# into it are root inside docker (the kernel build's modules_install, the base export), so on a
# tree where work/ does not exist — a fresh clone, or a `rm -rf work` full-rebuild test —
# whichever container stage lands first creates work/ ITSELF root-owned. Every host-side stage
# after that then dies on mkdir/touch inside it: packages/build-overlay.sh, work/.base.stamp,
# work/.rootfs-mode-*, work/steam-seed. (Cost a rebuild on 2026-07-26.)
#
# out/ never had this problem because out/.build-image.stamp is host-made through the
# `| $(BUILD_STAMP)` order-only prereq that every container stage carries. work/ has no single
# equivalent gate, and adding one per stage would silently regress the day a new stage forgets
# it — so create the directory at parse time, which no target can route around. Only the
# top-level directory is host-owned; the root-owned trees INSIDE it (work/base, work/kernel) are
# by design, and clean-base/distclean already remove those from inside a container.
$(shell mkdir -p work)

# --- where each stage runs ----------------------------------------------------
# Container: repo bind-mounted at /src. INBUILD is the plain run; DOCKER lets a
# recipe insert `-e VAR` flags (which must precede the image name) before the image.
DOCKER   := docker run --rm -v $(CURDIR):/src -w /src
INBUILD := $(DOCKER) $(BUILD_IMG)
# Test-only credential env, forwarded into the rootfs assembler (no-op unless TEST=1).
TEST_ENV := -e NOVADECK_TEST -e NOVADECK_WIFI_SSID -e NOVADECK_WIFI_PSK -e NOVADECK_SSH_PUBKEY

# NOVADECK_TEST changes the rootfs CONTENT (Wi-Fi profile, SSH host keys + authorized_keys) but is
# an environment variable, which make cannot see. Without this, an existing release rootfs.img looks
# up-to-date to a `NOVADECK_TEST=1 make sdcard`, the assembler is skipped, and you flash a RELEASE
# root wrapped in a test-built card — no Wi-Fi, no SSH, and no error anywhere. (Cost me a boot cycle
# on 2026-07-09.) Encode the mode in a stamp file that rootfs depends on, so flipping it rebuilds.
# Lives under work/ (host-owned); out/images is written by the container as root.
ROOTFS_MODE  := $(if $(filter 1,$(NOVADECK_TEST)),test,release)
MODE_STAMP   := work/.rootfs-mode-$(ROOTFS_MODE)

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
# prepends ahead of the holo repos. The repo db is the make target; the union of pins+patches+
# PKGBUILDs is its prerequisite so ANY overlay input change re-invokes build-overlay.sh. The
# script is INCREMENTAL: it hashes each package's own inputs and rebuilds only the changed
# package(s) (so a one-line gamescope patch no longer recompiles mesa), then re-indexes the db.
OVERLAY_PINS    := $(wildcard packages/*/source.pin)
OVERLAY_PATCHES := $(wildcard packages/*/patches/*.patch)
# Checked-in local PKGBUILDs (pkgbuild_local in a source.pin, e.g. packages/mesa/PKGBUILD) are
# build inputs too — track them so editing a recipe (deps, meson options) rebuilds that package.
OVERLAY_PKGBUILDS := $(wildcard packages/*/PKGBUILD)
# Overlay packages are ARCH-scoped (a rebuilt aarch64 gamescope serves every aarch64 device),
# so the repo is shared at work/repo/<arch>/.
OVERLAY_ARCH    ?= aarch64
OVERLAY_DB      := work/repo/$(OVERLAY_ARCH)/novadeck.db.tar.zst
# Content stamp advanced by build-overlay.sh ONLY when it actually re-indexes (a package really
# rebuilt). base keys off THIS, not novadeck.db's mtime — the script bumps the db even on a no-op
# run (to stop make re-invoking it), and that spurious bump used to cascade the whole expensive
# customize-base off a byte-identical repo.
OVERLAY_STAMP   := work/repo/$(OVERLAY_ARCH)/.overlay.stamp
BASE_STAMP   := work/.base.stamp
KERNEL       := $(OUT)/Image.gz
ROOTFS       := $(OUT)/images/rootfs.img
# Sibling image the assembler emits alongside the root (see images/partition-table.txt):
# the writable state partition, which also carries the /etc overlay upper.
VARIMG       := $(OUT)/images/var.img
INITRAMFS    := $(OUT)/initramfs.cpio.gz
BOOTIMG      := $(OUT)/boot/novadeck-boot.img
SDCARD       := $(OUT)/images/sdcard.img
# Native arm64 Steam SEED (steam-seed/fetch-steam-seed.sh, host network). make-sdcard pre-seeds this tree
# directly into the /home partition, so a healthy first boot does no copy and needs no network. The
# client binary it stages is the make target; the pin + fetcher are its prerequisites.
STEAM_SEED   := work/steam-seed/steamrtarm64/steam

# Repo sources the rootfs assembler reads directly (itself + the unified fs-overlay/ payload tree
# it copies in wholesale). find recurses, so files added under fs-overlay/ are tracked
# automatically — no per-file Makefile edits.
#
# images/seal.list + images/seal-rootfs.sh are assembler inputs too: the seal is the last thing
# that touches the staged tree (Phase 4a step 3), so editing what gets stripped changes the image
# exactly as editing fs-overlay/ does.
#
# images/guard-rootfs.sh is listed for the opposite reason -- it changes no bytes in the image, but
# it decides whether one is produced at all (Phase 4a step 4). A tightened assertion has to re-run
# against the tree it was tightened for, not wait for the next unrelated fs-overlay edit.
# images/manifest.lock is one of its inputs (it asserts the tree still matches the lock) and is
# already a $(BASE_STAMP) prerequisite, which reaches the rootfs transitively.
#
ASSEMBLE_SRC := $(shell find images/assemble-rootfs.sh images/seal-rootfs.sh images/seal.list \
                              images/guard-rootfs.sh fs-overlay -type f 2>/dev/null)

# Kernel inputs: any change re-triggers the (full, from-scratch) kernel build. The unified
# kernel globs every fragment/patch/dts, and bakes the firmware embed list.
# boot/cmdline is NOT here: nothing in kernel/build.sh reads it (the cmdline rides in the boot
# image header, applied by boot/package.sh), so listing it only bought needless kernel rebuilds.
KERNEL_SRC := kernel/SOURCE.pin kernel/embed.list \
              $(wildcard kernel/*.config) \
              $(wildcard kernel/patches/*.patch) \
              $(wildcard kernel/dts/qcom/*)

.DEFAULT_GOAL := help

# ==============================================================================
# Phony orchestration targets
# ==============================================================================
.PHONY: help all image toolchain kernel fw-linux fw-qcom base overlay rootfs manifest relock \
        initramfs boot sdcard bundle deploy clean clean-base clean-overlay distclean

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
base:      $(BASE_STAMP)   ## Bootstrap the aarch64 root from packages (host; docker+qemu)
rootfs:    $(ROOTFS)       ## Assemble the read-only root + var images (in container)
initramfs: $(INITRAMFS)    ## Build the initramfs that mounts ro-root + /etc overlay (in container)
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

# Native arm64 Steam seed (client + SR3 runtime) — fetched on the host, staged into work/steam-seed/,
# then pre-seeded into /home by make-sdcard. Pinned channel/runtime in steam-seed/STEAM_SEED.pin.
$(STEAM_SEED): steam-seed/STEAM_SEED.pin steam-seed/fetch-steam-seed.sh
	steam-seed/fetch-steam-seed.sh
	@touch $@

# ==============================================================================
# From-source overlay packages (host — build-overlay.sh drives docker + qemu binfmt)
# ==============================================================================
# Rebuild changed holo packages with novadeck patches into the local pacman repo work/repo/<arch>/.
# Union prereq re-invokes the script on any input change; the script self-selects which package(s)
# to rebuild (per-package input hash). Only when a source.pin exists does `base` depend on it.
$(OVERLAY_DB): base-devel.digest $(OVERLAY_PINS) $(OVERLAY_PATCHES) $(OVERLAY_PKGBUILDS)
	packages/build-overlay.sh

# Advance .overlay.stamp only when the overlay repo's CONTENT actually changed, and do it in THIS
# target's own recipe so make observes the new mtime within the same invocation (base depends on
# this stamp). Keying on the db's sha (not its mtime) is what lets build-overlay.sh keep bumping
# novadeck.db's mtime on a no-op run WITHOUT cascading into a base rebuild: the sha is unchanged, so
# the stamp is left alone. A REAL re-index changes the sha, we touch the stamp, and base rebuilds
# right away — the previous ORDER-ONLY `| $(OVERLAY_DB)` form could not, because the stamp was
# advanced as a side effect of the DB rule and make never re-stat'd it mid-run (a stale-mtime miss
# that silently shipped a base built against the OLD overlay). $@.sha persists the last-seen hash.
$(OVERLAY_STAMP): $(OVERLAY_DB)
	@newsha=$$(sha256sum $(OVERLAY_DB) | cut -d' ' -f1); \
	 [ "$$(cat $@.sha 2>/dev/null)" = "$$newsha" ] || { printf '%s\n' "$$newsha" > $@.sha; touch $@; }
	@[ -e $@ ] || touch $@   # first-ever run: ensure the stamp exists even if the sha file seeded it

# ==============================================================================
# Root bootstrap (host — customize-base.sh drives docker + qemu binfmt itself)
# ==============================================================================
# Every prerequisite here is an input to the tree work/base ends up containing. Without one
# listed, the stamp short-circuits `make base` and editing that input is silently a no-op --
# the script's own reuse check never gets to run, because make never invokes the script.
#
# base-devel.digest pins the arm64 image the bootstrap EXECUTES in (Phase 4c; it contributes
# no files to the root, but it is the pacman that lays them down). snapshot.pin selects the
# package-repo revision every row is installed from.
#
# images/manifest.lock is the strongest input: under the default LOCKED mode customize-base.sh
# installs exactly the package FILES it declares (Phase 4a step 2), so editing the lock changes
# the tree. images/fetchlock.sh is listed for the same reason build scripts generally are -- it
# is what turns the lock into that install. images/pacman.conf and images/os-release are the
# two committed declarations the bootstrap stages into the container: the repo set the root is
# resolved from, and the root's own identity.
$(BASE_STAMP): base-devel.digest snapshot.pin images/manifest.lock images/fetchlock.sh \
               images/pacman.conf images/os-release $(PREBUILT_PINS)
	images/customize-base.sh
	@test -f work/base/usr/bin/sshd   # sentinel: sshd present => release runtime laid down
	@mkdir -p $(@D) && touch $@   # recency marker outside the root-owned tree (frozen mtimes)

# A built overlay repo is an extra base input: customize-base installs the patched packages
# from it and folds its content hash into the reuse-cache key. Wire it as a prerequisite only
# when source.pin packages exist, so a repo with no overlay still builds normally.
ifneq ($(OVERLAY_PINS),)
$(BASE_STAMP): $(OVERLAY_STAMP)
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

# Regenerate images/manifest.lock (Phase 4a). Deliberately NOT a dependency of the image build:
# the lock is a reviewed artifact, so it is regenerated on purpose and its diff is read, never
# refreshed as a silent build side effect.
#
# It must NOT go through $(BASE_STAMP), which builds in LOCKED mode -- relocking a tree that was
# itself installed from the lock can only ever reproduce that lock. Re-resolving is the whole
# point, so this drives customize-base.sh directly in NOVADECK_RESOLVE=1 mode: pacman -Sy resolves
# PKGS against the pinned snapshot, and genmanifest.sh then records what that produced.
#
# The resulting tree is a RESOLVE tree and must never ship, so the stamp is REMOVED rather than
# touched. The next build re-runs customize-base.sh, which sees mode:resolve in the reuse marker,
# rebuilds in locked mode, and so ships a tree actually verified against the new lock.
# Release-only by construction: genmanifest.sh refuses a test base.
#
# NOVADECK_TEST is cleared here rather than passed through: with it set, the base would be built
# with the test tooling and genmanifest.sh would then refuse it -- correct, but only after a full
# emulated install. The lock is a release artifact, so force release up front.
#
# The overlay repo IS a prerequisite even though the base stamp is not. Dropping $(BASE_STAMP)
# dropped its transitive overlay dependency with it, and without a built work/repo/aarch64 the
# resolve would satisfy mesa/gamescope/sddm from the snapshot instead of from our patched builds
# — locking upstream binaries under a `snapshot` class. That is a silently WRONG lock, which is
# worse than a failed one, so declare the overlay directly.
relock: $(if $(OVERLAY_PINS),$(OVERLAY_STAMP)) ## Re-resolve from PKGS and regenerate images/manifest.lock (host; release only)
	NOVADECK_TEST= NOVADECK_RESOLVE=1 FORCE=1 images/customize-base.sh
	images/genmanifest.sh
	rm -f $(BASE_STAMP)
	@echo "review the diff, commit it, then rebuild: git diff images/manifest.lock"

# ==============================================================================
# Read-only root (container) — base userspace + kernel + firmware -> Btrfs image
# ==============================================================================
# Switching NOVADECK_TEST swaps which stamp exists, so the rootfs is rebuilt on the next make.
$(MODE_STAMP):
	@mkdir -p $(@D) && rm -f work/.rootfs-mode-* && touch $@
	@echo "[novadeck] rootfs mode: $(ROOTFS_MODE)"

$(ROOTFS): $(KERNEL) $(BASE_STAMP) $(FW_LINUX) $(FW_QCOM) $(STEAM_SEED) $(ASSEMBLE_SRC) $(MODE_STAMP) | $(BUILD_STAMP)
	$(DOCKER) $(TEST_ENV) -e NOVADECK_DEBUG $(BUILD_IMG) \
	  images/assemble-rootfs.sh /src/work/base

# ==============================================================================
# Boot artifact + bootable media (container)
# ==============================================================================
# The initramfs mounts the ro root, stacks the /etc overlay on /var, and switch_roots. It is
# staged out of the base rootfs (bash + util-linux), so the base is a prerequisite.
$(INITRAMFS): images/mkinitramfs.sh images/initramfs/init $(BASE_STAMP) | $(BUILD_STAMP)
	$(INBUILD) images/mkinitramfs.sh /src/work/base

$(BOOTIMG): $(KERNEL) $(INITRAMFS) boot/cmdline boot/package.sh | $(BUILD_STAMP)
	$(INBUILD) boot/package.sh

# var.img is a co-product of the same assembler run as rootfs.img.
$(VARIMG): $(ROOTFS)

$(SDCARD): $(BOOTIMG) $(ROOTFS) $(VARIMG) $(STEAM_SEED) | $(BUILD_STAMP)
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
	docker run --rm -v $(CURDIR)/out:/wo busybox rm -rf /wo/Image.gz /wo/dtbs /wo/modroot /wo/images /wo/boot /wo/initramfs.cpio.gz

# work/base is root-owned (the bootstrap's pacman writes it as root inside a container), so a
# plain rm fails for the build user — remove it from inside a throwaway container as root.
clean-base: ## Remove the (root-owned) bootstrapped root tree
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
