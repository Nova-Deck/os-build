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
#   NOVADECK_DEV=1  build a dev image. `set -a; . ./dev.env; set +a` sets this and the rest;
#                dev.env is TRACKED and secret-free, and sources dev.env.local (gitignored) for
#                Wi-Fi creds. This is also the ONLY way to build an image from packages you
#                compiled yourself: a release build requires reviewed artifact pins (verify-pins).
#   NOVADECK_WIFI_SSID/PSK  OPTIONAL dev-only Wi-Fi profile, injected from the environment so it
#                never touches the repo. Absent => a card with NO network and no SSH, i.e. the
#                shipping first-boot condition (the only honest way to test OOBE locally).
#   NOVADECK_WIFI  intent knob for the above: 1 = require creds (fail loudly rather than hand you
#                an unreachable card), 0 = no profile even when creds are set. See dev.env.
#   NOVADECK_SSH_PUBKEY  root's authorized_keys on a dev card. dev.env generates a throwaway key
#                under work/dev-ssh/ rather than using your personal one.
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

# --- signing material, which lives OUTSIDE the repo ---------------------------
# The OTA signing PKI is deliberately not under $(CURDIR): out/ is one `rm -rf` away from taking
# the 20-year root of trust with it, and a device flashed with a keyring whose key is gone rejects
# every future bundle. So the container cannot see it by default -- only /src is mounted.
#
# Set PKIDIR to mount it read-only at /pki for the two targets that need it:
#
#   PKIDIR=~/novadeck-pki make bundle          # a real signature
#   PKIDIR=~/novadeck-pki make test-signing    # incl. the keyring-vs-signing-key check
#
# Unset, both keep their previous behaviour exactly: `bundle` mints an ephemeral dev cert and
# `test-signing` announces the keyring check as skipped. Resolved with $(realpath ...) so a typo --
# or a tilde the shell did not expand -- fails here, loudly, instead of silently mounting nothing.
# NEVER answer this by copying private keys back under the repo.
ifdef PKIDIR
PKI_REAL := $(realpath $(PKIDIR))
ifeq ($(PKI_REAL),)
$(error PKIDIR=$(PKIDIR) does not exist (if it starts with ~, quote it differently: PKIDIR=$$HOME/...))
endif
PKI_MOUNT := -v $(PKI_REAL):/pki:ro -e PKIDIR=/pki
# The filenames ci/gen-signing-ca.sh always mints, so `PKIDIR=... make bundle` is enough on its own.
# ?= keeps an explicit RAUC_CERT/RAUC_KEY (env or command line) winning over these.
RAUC_CERT ?= /pki/release.cert.pem
RAUC_KEY  ?= /pki/release.key.pem
endif
# Dev-only credential env, forwarded into the rootfs assembler (no-op unless NOVADECK_DEV=1).
DEV_ENV := -e NOVADECK_DEV -e NOVADECK_WIFI -e NOVADECK_WIFI_SSID -e NOVADECK_WIFI_PSK -e NOVADECK_SSH_PUBKEY

# NOVADECK_DEV changes the rootfs CONTENT (Wi-Fi profile, SSH host keys + authorized_keys) but is
# an environment variable, which make cannot see. Without this, an existing release rootfs.img looks
# up-to-date to a `NOVADECK_DEV=1 make sdcard`, the assembler is skipped, and you flash a RELEASE
# root wrapped in a dev-built card — no Wi-Fi, no SSH, and no error anywhere. (Cost me a boot cycle
# on 2026-07-09.) Encode the mode in a stamp file that rootfs depends on, so flipping it rebuilds.
# Lives under work/ (host-owned); out/images is written by the container as root.
#
# THE NAME: this was NOVADECK_TEST until 2026-07-30. It was chosen while debugging the very first
# Steam OOBE, where "test" meant a throwaway card, and it long outlived that — this is the normal
# development cycle now, and the release path is the one that is special. Renamed with the artifact
# pins, since both turn on the same distinction: who built these bytes.
# The Wi-Fi profile is a THIRD state, not a sub-detail of dev, and it has to reach the stamp or it
# fails exactly the way NOVADECK_DEV did before this stamp existed. "dev with creds" and "dev
# without creds" produce different rootfs CONTENT (an /etc/NetworkManager profile that auto-joins,
# or nothing), so sharing work/.rootfs-mode-dev between them means dropping the creds leaves the
# image looking up-to-date: the assembler is skipped and you flash the PREVIOUS card, still
# auto-joining, while believing you are testing the offline first boot. No error anywhere.
#
# DEV_WIFI mirrors the assembler's own decision (images/assemble-rootfs.sh, `dev_wifi`) and must
# keep mirroring it: it is the EFFECTIVE outcome, not the knob. That distinction is the point —
# forgetting to source dev.env.local is indistinguishable from asking for no Wi-Fi as far as the
# image is concerned, so both must land on the same stamp. (NOVADECK_WIFI=1 with no creds is a hard
# error in the assembler, so make needs no case for it.)
DEV_WIFI     := $(if $(filter 0,$(NOVADECK_WIFI)),,$(if $(NOVADECK_WIFI_SSID),$(if $(NOVADECK_WIFI_PSK),1,),))
ROOTFS_MODE  := $(if $(filter 1,$(NOVADECK_DEV)),dev$(if $(DEV_WIFI),,-nowifi),release)
MODE_STAMP   := work/.rootfs-mode-$(ROOTFS_MODE)

# The BASE tree is mode-dependent for the same reason and needs the same treatment: NOVADECK_DEV=1
# adds DEV_PKGS (evtest, usbutils) to the bootstrap (images/customize-base.sh:176), so a dev base
# and a release base are DIFFERENT trees. Every $(BASE_STAMP) prerequisite is a file and none of them
# encodes the mode, so without this a base built in one mode looks up-to-date to the other and make
# never invokes customize-base.sh at all — its mode-aware reuse key (`dev:1`, line 306) is
# unreachable in exactly the case it was written for. Caught on 2026-07-28 building a release bundle
# straight after a dev card: the release guard tripped on `only in tree: evtest usbutils`. The
# reverse direction — a release base under a DEV card — has no guard at all (guard-rootfs.sh is
# release-only) and is the direction that cost the 2026-07-09 boot cycle.
#
# This is a PREREQUISITE stamp, not a per-mode rename of $(BASE_STAMP). Naming the stamp
# work/.base-$(ROOTFS_MODE).stamp would be wrong: stamps accumulate, the tree does not. There is one
# work/base, so a `.base-dev.stamp` left behind by an earlier dev build still looks satisfied after
# a release build has since overwritten that tree — the stale-tree bug back again, silently. Instead
# there is one stamp for the tree and one marker for the mode it was built in, and the marker rule
# deletes its siblings so only ever one exists (same shape as $(MODE_STAMP) above). Flipping the mode
# re-creates the marker newer than $(BASE_STAMP), which re-runs customize-base.sh, which then really
# rebuilds because the mode is in its reuse key too. A flip costs a full base rebuild — the correct
# price, and the one `make relock` already pays deliberately.
# Deliberately NOT $(ROOTFS_MODE): that one carries the -nowifi dimension, and the base does not
# have one. DEV_PKGS keys off NOVADECK_DEV alone, and the Wi-Fi profile is written by the ASSEMBLER,
# not by the bootstrap — so a dev base is byte-identical whether or not creds were present. Reusing
# ROOTFS_MODE here would rename this marker on a Wi-Fi flip and charge a full base rebuild (the
# expensive half of the build) for a change that cannot affect work/base. Toggling Wi-Fi costs a
# rootfs re-assembly and nothing more.
BASE_MODE       := $(if $(filter 1,$(NOVADECK_DEV)),dev,release)
BASE_MODE_STAMP := work/.base-mode-$(BASE_MODE)

# --- artifact-pin enforcement (release only) -----------------------------------
# A RELEASE build installs overlay packages whose BYTES are named by a reviewed
# packages/*/artifact.pin; a dev build does not. That is the whole dev/release distinction and it
# is deliberately not a separate knob: a gate only CI remembers to set is a gate that rots, and
# there is no legitimate release image that a developer builds locally — CI builds those, from
# store artifacts a pin-bump PR recorded. See packages/verify-pins.sh.
#
# The lock already answers "were these built from the reviewed SOURCES?" on every build and every
# machine. This answers the question the lock deliberately gave up: "are these the reviewed BYTES?"
PINNED := $(if $(filter release,$(ROOTFS_MODE)),1,)

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
# Slot B's var, emitted by the same run. Identical but for /var/lib/novadeck/slot, which is the
# independent witness of which slot actually mounted (the roots are content-identical by design).
VARIMG_B     := $(OUT)/images/var-b.img
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
# kernel/build.sh IS here (added 2026-07-26): it is the recipe itself — it decides the config
# merge, the firmware embed and the =m/=y assertions, so editing it changes the Image but make
# could not see that. Editing it alone used to be a silent no-op that only showed up as a stale
# kernel on the card. Same class of bug as the bootstrap-script dep fixed in c0d2cb6.
KERNEL_SRC := kernel/SOURCE.pin kernel/embed.list kernel/build.sh \
              $(wildcard kernel/*.config) \
              $(wildcard kernel/patches/*.patch) \
              $(wildcard kernel/dts/qcom/*)

.DEFAULT_GOAL := help

# ==============================================================================
# Phony orchestration targets
# ==============================================================================
.PHONY: help all image toolchain kernel fw-linux fw-qcom base overlay overlay-pull overlay-publish \
        verify-pins pin-artifacts verify-lock \
        rootfs manifest relock \
        initramfs boot sdcard verify-card test bundle deploy clean clean-base clean-overlay distclean

help: ## Show this help
	@echo "novadeck build — unified image (all SoCs/boards)"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'
	@echo
	@echo "Knobs: BASE_CONFIG VERSION ESP OVERLAY_PULL   dev build: set -a; . ./dev.env; set +a"

all: sdcard ## Alias for `sdcard` (the full bring-up image)

image: $(ROOTFS) ## Read-only Btrfs root only (out/images/rootfs.img)

toolchain: $(BUILD_STAMP) ## Build the novadeck-build cross-compile docker image
kernel:    $(KERNEL)       ## Build Image.gz + all dtbs + modules (in build container)
fw-linux:  $(FW_LINUX)     ## Fetch open linux-firmware blobs (host, network)
fw-qcom:   $(FW_QCOM)      ## Fetch device-proprietary firmware from the qcom-firmwares repo (host, network)
# OVERLAY_PULL := 0 is what keeps this goal's documented contract (see $(OVERLAY_DB)): `make
# overlay` is a PURE LOCAL BUILD that touches no network. A target-specific variable applies to
# the target AND its prerequisites, which is exactly the reach needed — the value follows down
# into $(OVERLAY_DB)'s recipe. Reaching the same db through an image goal (sdcard/image/rootfs)
# leaves the default 1 in place and pulls first.
# Caveat for `make overlay sdcard` in ONE invocation: the shared db is considered once, so it gets
# whichever value make reaches first. Run them as two invocations if the distinction matters.
overlay:   OVERLAY_PULL := 0
overlay:   $(OVERLAY_DB)   ## Rebuild from-source overlay pkgs (patched gamescope) -> work/repo/<arch>/
base:      $(BASE_STAMP)   ## Bootstrap the aarch64 root from packages (host; docker+qemu)
rootfs:    $(ROOTFS)       ## Assemble the read-only root + var images (in container)
initramfs: $(INITRAMFS)    ## Build the initramfs that mounts ro-root + /etc overlay (in container)
boot:      $(BOOTIMG)      ## Package the all-boards boot artifact (in container)
sdcard:    $(SDCARD)       ## Build the flashable SD-card image (in container)

# Asserts the BUILT card the way guard-rootfs.sh asserts the built tree — the guard stops at the
# staged tree (it runs before mkfs), so nothing else checks the GPT, the ESP, or the per-slot
# filesystem identities an A/B switch depends on. Unprivileged: no loop mounts, no root.
verify-card: $(SDCARD) | $(BUILD_STAMP) ## Verify the built A/B card image (in container)
	$(INBUILD) images/verify-card.sh

# The two offline suites over the A/B boot logic. Neither needs a build, a container, root or a
# device — they are pure shell over temp-dir state — so there is no reason not to run them, and
# until now there was no target that did. That absence is not academic: the RAUC backend had no
# offline coverage at all, and a broken one reached hardware and aborted a real install.
#
# HOST-SIDE ON PURPOSE, unlike everything else here. All three scripts execute the shipped artifacts
# (images/initramfs/init, fs-overlay/usr/bin/novadeck-bootctl and fs-overlay/usr/lib/rauc/
# post-install.sh) against a sandbox; putting them in the container would test the same files
# through an extra layer that can only add failure modes.
#
# The three cover the update path end to end, each from the side the others cannot see: the
# initramfs READS the slot state, novadeck-bootctl WRITES it, and the post-install hook DRIVES both
# while reformatting a partition. None of them needs root — the hook suite stubs the commands that
# would touch real storage.
# A second's worth of committed-file arithmetic, and the reason it is a PREREQUISITE of `test`
# rather than a step inside images/fetchlock.sh: fetchlock makes the same comparison but needs a
# populated work/repo plus the ~382 snapshot packages it verifies alongside, so on a clean machine
# nothing runs it until the overlay pipeline's retrieval job — hours of aarch64 compiles after the
# wrong row was pushed. Hanging it off `test` is what puts it on every push and every PR: the ci
# workflow runs `make test`, and it triggers on paths overlay.yml deliberately ignores, so a commit
# touching ONLY images/manifest.lock is still checked.
verify-lock: ## Check the lock's novadeck rows against packages/ (host, seconds, no build)
	bash packages/verify-lock-rows.sh

test: verify-lock ## Run the offline slot-state + bootctl + post-install suites (host, no build needed)
	bash images/initramfs/test-slot-state.sh
	bash images/test-bootctl.sh
	bash images/test-post-install.sh
	bash images/test-pairingd.sh

# The fourth suite, separate because it is the one that CANNOT run on the host: it signs real
# bundles and verifies them through the shipped system.conf, so it needs rauc. Every case in it is
# a negative — it feeds images/rauc/verify-signing.sh a deliberately broken config or cert profile
# and requires it to go red — because the failure mode of a check is not "it breaks", it is "it
# stays green while asserting nothing".
test-signing: $(BUILD_STAMP) ## Prove the RAUC signing self-test still catches what it claims (container; PKIDIR= adds the keyring check)
	$(DOCKER) $(PKI_MOUNT) $(BUILD_IMG) images/test-verify-signing.sh

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
#
# THE PULL RUNS FIRST, and it is in this recipe rather than being a prerequisite for a reason: it
# then fires exactly when make has already decided the repo is out of date, i.e. precisely when a
# source.pin/patch bump would otherwise start a multi-hour qemu compile for artifacts CI has
# already built. On an up-to-date repo the rule never runs, so there is NO per-build network cost.
# (`make sdcard` after ab3121b raised the ISA floor recompiled fex-emu + mesa + mangohud locally,
# with no signal that the store already had all three. That is the failure this closes.)
#
# It cannot turn a working build into a broken one: pull-all is NEVER fatal (see overlay-store.sh)
# — a miss, an unreadable package, or an unreachable registry all log and return 0, and whatever
# could not be retrieved simply gets compiled, which is the old behaviour exactly.
#
# It also cannot clobber a local iteration. pull-all tests is_fresh BEFORE touching the network, and
# that is the same per-package input-hash test build-overlay.sh applies: a package you already built
# here is skipped without a request, and an uncommitted edit's hash is absent from the store, so it
# costs one 404 manifest probe and then compiles. Nothing overwrites artifacts whose stamp is current.
# OVERLAY_PULL=0 opts out entirely (no pull, no probe) for a hermetic loop; `make overlay` sets it.
OVERLAY_PULL ?= 1
$(OVERLAY_DB): base-devel.digest $(OVERLAY_PINS) $(OVERLAY_PATCHES) $(OVERLAY_PKGBUILDS)
	$(if $(filter 1,$(OVERLAY_PULL)),packages/overlay-store.sh pull-all)
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

# Retrieve overlay packages someone already built, instead of compiling them here. Keyed by the
# same packages/inputhash.sh digest the lock records, so a hit means "built from exactly these
# sources" — see packages/overlay-store.sh. Pulling needs NO credentials.
#
# Every IMAGE goal (sdcard/image/rootfs/base) now does this for you, from $(OVERLAY_DB)'s own
# recipe — so a cold clone reaches a card without knowing this target exists. `make overlay` still
# does NOT (it sets OVERLAY_PULL=0): that goal remains a pure local build with no network in it.
# This stays a cache either way, never something the lock leans on — the lock pins the novadeck
# rows to their SOURCES, so a pulled artifact and a locally compiled one satisfy it identically.
#
# Run it by hand to pre-warm the repo without building anything, or to see what the store has.
# A miss is not an error: whatever could not be pulled simply gets compiled.
overlay-pull: ## Fetch already-built overlay packages from the store into work/repo/<arch>/
	packages/overlay-store.sh pull-all

# Publish what THIS machine built. Depends on the stamp so it can only ever publish a repo make
# considers current — publishing artifacts whose sources have since moved is the one failure this
# store cannot detect afterwards, because the input hash is the only claim attached to them.
# (overlay-store.sh re-checks that per package too; this just stops the obvious case earlier.)
overlay-publish: $(OVERLAY_STAMP) ## Publish locally built overlay packages to the store (needs login)
	packages/overlay-store.sh push-all

# The byte check a release build must pass. Not wired to $(OVERLAY_STAMP): it reads the lock and the
# committed pins and re-hashes what is on disk, so it must run even when make thinks the repo is
# current -- that is precisely the case a substitution produces.
verify-pins: ## Verify overlay artifact BYTES against packages/*/artifact.pin (release gate)
	packages/verify-pins.sh

# Record the bytes built here as the reviewed ones. Normally CI's pin-bump PR does this; run it by
# hand when you deliberately intend to make a local build the pinned one, then review the diff.
pin-artifacts: $(OVERLAY_STAMP) ## (Re)generate packages/*/artifact.pin from the built overlay repo
	packages/verify-pins.sh --write

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
# images/customize-base.sh is listed LAST but matters most: it is the script that turns all of
# the above into a tree, so editing it changes the tree. Its absence here meant a fix to the
# bootstrap was silently a no-op -- make saw the stamp as satisfied and never invoked it. (Cost a
# build cycle on 2026-07-26: a `make sdcard` after a script fix rebuilt nothing.) The script also
# folds its own sha256 into its reuse marker, because the make prereq alone only gets the script
# RUN -- the marker check inside it would otherwise still short-circuit.
#
# $(BASE_MODE_STAMP) is the NOVADECK_DEV prerequisite (see its definition): it is the only one of
# these that changes when nothing on disk does.
#
# The mode assertion in the recipe is the other half of that. A marker file saying which mode the
# tree was built in is a claim, and an unchecked claim is how the stale-base bug shipped in the first
# place. customize-base.sh records `dev:1` in its own reuse key for a dev bootstrap, so the built
# tree states its own mode: assert that against the mode we asked for. This guards BOTH directions,
# which nothing downstream does -- guard-rootfs.sh only ever runs on a release build.
# The artifact-pin gate is ORDER-ONLY (`|`), and that is load-bearing rather than stylistic.
# verify-pins is .PHONY, so as a normal prerequisite it would be perpetually newer than the stamp
# and every release `make` would rebuild the base from scratch. Order-only still RUNS it (a phony
# target is always out of date) while leaving the stamp's own up-to-date check alone -- the same
# reason every container stage carries `| $(BUILD_STAMP)`.
#
# It gates the BASE rather than the image targets so the check happens BEFORE these bytes are
# installed, not after. Checking work/repo rather than the built tree is sound because
# $(OVERLAY_STAMP) already keys off sha256sum $(OVERLAY_DB): a substitution inside work/repo moves
# the db, which rebuilds the base anyway, so there is no window where a verified repo and an
# unverified tree coexist.
$(BASE_STAMP): base-devel.digest snapshot.pin images/manifest.lock images/fetchlock.sh \
               images/pacman.conf images/os-release images/customize-base.sh $(PREBUILT_PINS) \
               $(BASE_MODE_STAMP) | $(if $(PINNED),verify-pins)
	images/customize-base.sh
	@test -f work/base/usr/bin/sshd   # sentinel: sshd present => release runtime laid down
	@: "sentinel: the pairing agent's interpreter and key validator. Both arrive as transitive"; \
	 : "dependencies of other packages, so a dependency change elsewhere could remove them and"; \
	 : "the only symptom would be that remote access silently stops working on a shipped image."; \
	 for f in usr/bin/python3 usr/bin/ssh-keygen; do \
	   test -e "work/base/$$f" || { \
	     echo "novadeck-pairingd needs /$$f and the base tree has no such file" >&2; exit 1; }; \
	 done
	@: "sentinel: the tree must be in the mode this build asked for (see above)"; \
	 got=release; grep -qx 'dev:1' work/base/usr/lib/novadeck/pkgs 2>/dev/null && got=dev; \
	 [ "$$got" = "$(ROOTFS_MODE)" ] || { \
	   echo "base tree is a $$got build, this is a $(ROOTFS_MODE) build (stale work/base)" >&2; \
	   exit 1; }
	@mkdir -p $(@D) && touch $@   # recency marker outside the root-owned tree (frozen mtimes)

# Switching NOVADECK_DEV swaps which marker exists, so the base is rebuilt on the next make. The
# rm is what keeps it a marker rather than a cache: exactly one mode is ever claimed, and it is
# always the mode work/base was last built in.
$(BASE_MODE_STAMP):
	@mkdir -p $(@D) && rm -f work/.base-mode-* && touch $@
	@echo "[novadeck] base mode: $(ROOTFS_MODE)"

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
# Release-only by construction: genmanifest.sh refuses a dev base.
#
# NOVADECK_DEV is cleared here rather than passed through: with it set, the base would be built
# with the dev tooling and genmanifest.sh would then refuse it -- correct, but only after a full
# emulated install. The lock is a release artifact, so force release up front.
#
# The overlay repo IS a prerequisite even though the base stamp is not. Dropping $(BASE_STAMP)
# dropped its transitive overlay dependency with it, and without a built work/repo/aarch64 the
# resolve would satisfy mesa/gamescope/sddm from the snapshot instead of from our patched builds
# — locking upstream binaries under a `snapshot` class. That is a silently WRONG lock, which is
# worse than a failed one, so declare the overlay directly.
relock: $(if $(OVERLAY_PINS),$(OVERLAY_STAMP)) ## Re-resolve from PKGS and regenerate images/manifest.lock (host; release only)
	NOVADECK_DEV= NOVADECK_RESOLVE=1 FORCE=1 images/customize-base.sh
	images/genmanifest.sh
	rm -f $(BASE_STAMP) work/.base-mode-*   # the tree left behind is a RESOLVE tree: claim no mode for it
	@echo "review the diff, commit it, then rebuild: git diff images/manifest.lock"

# ==============================================================================
# Read-only root (container) — base userspace + kernel + firmware -> Btrfs image
# ==============================================================================
# Switching NOVADECK_DEV swaps which stamp exists, so the rootfs is rebuilt on the next make.
$(MODE_STAMP):
	@mkdir -p $(@D) && rm -f work/.rootfs-mode-* && touch $@
	@echo "[novadeck] rootfs mode: $(ROOTFS_MODE)"

# $(BOOTIMG) is a prerequisite because the root now CARRIES its own kernel at
# /usr/lib/novadeck/boot.img — that is what lets the RAUC post-install hook install a kernel that
# matches the modules in the slot it just wrote. No cycle: BOOTIMG needs KERNEL + INITRAMFS, and
# the initramfs is built from work/base, never from the assembled root.
$(ROOTFS): $(KERNEL) $(BOOTIMG) $(BASE_STAMP) $(FW_LINUX) $(FW_QCOM) $(STEAM_SEED) $(ASSEMBLE_SRC) $(MODE_STAMP) | $(BUILD_STAMP)
	$(DOCKER) $(DEV_ENV) -e NOVADECK_DEBUG $(BUILD_IMG) \
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

# var.img and var-b.img are co-products of the same assembler run as rootfs.img.
$(VARIMG): $(ROOTFS)
$(VARIMG_B): $(ROOTFS)

$(SDCARD): $(BOOTIMG) $(ROOTFS) $(VARIMG) $(VARIMG_B) $(STEAM_SEED) images/make-sdcard.sh | $(BUILD_STAMP)
	$(INBUILD) images/make-sdcard.sh

# Signed RAUC OTA bundle (Phase 4). Dev builds mint an ephemeral cert. For a real signature use
# PKIDIR=~/novadeck-pki (mounts the PKI at /pki and points RAUC_CERT/RAUC_KEY at it), or set
# RAUC_CERT/RAUC_KEY yourself to paths the CONTAINER can see -- repo-relative ones resolve under
# /src, anything else needs PKIDIR or a mount of your own.
bundle: $(ROOTFS) | $(BUILD_STAMP) ## Build a signed RAUC update bundle (in container; PKIDIR= to sign for real)
	$(DOCKER) $(PKI_MOUNT) -e RAUC_CERT="$(RAUC_CERT)" -e RAUC_KEY="$(RAUC_KEY)" $(BUILD_IMG) \
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
	rm -f $(BASE_STAMP) work/.base-mode-*   # drop the recency + mode markers too, else the next build skips a gone base

clean-overlay: ## Remove the built (arch-scoped) overlay pacman repo + build tree
	rm -rf work/repo work/overlay-build

# THREE THINGS THIS DELIBERATELY DOES *NOT* REMOVE, all of which surprise people:
#
#   work/prebuilt      the pinned-download cache (customize-base.sh documents it as persistent).
#   work/pacman-cache  the package cache.
#   work/repo          the built overlay packages (NOT clean-overlay — this target no longer runs it).
#
# Together they are ~3.5G, i.e. essentially everything left under work/ after this target runs,
# which is why "distclean left stuff behind" is a reasonable first reading. It is a CHOICE: every
# byte in them is content-addressed against a pin or a package version, so a stale entry cannot
# be served — a mismatched sha is re-fetched, and the FEX guest .ero alone is ~1.9G to pull again.
# Nothing in the build reads them as INPUT to a decision; they only ever save a download. To drop
# them anyway (moving machines, reclaiming disk, or proving a pin still resolves upstream):
#
#   rm -rf work/prebuilt work/pacman-cache && make clean-overlay
#
# work/repo is the newest member and the one with real history. It used to go via clean-overlay,
# and because images/manifest.lock then pinned the overlay's ARTIFACT bytes — which our
# non-reproducible builds move on every rebuild from identical inputs — `make distclean && make
# sdcard` could not succeed on its own: it stopped at work/.base.stamp on a hash mismatch and
# needed a full `make relock` to get going again. The lock now pins those rows to their SOURCES
# (packages/inputhash.sh, read by images/fetchlock.sh), so a rebuild is no longer a lock change
# and that hard stop is gone. Keeping the repo is now purely about not re-paying for it: rebuilding
# all ~10 packages under qemu is the single most expensive thing in this build, and fex-emu alone
# dominates it. `make clean-overlay` is still there when you actually want them rebuilt.
distclean: clean clean-base ## clean + drop fetched firmware + kernel tree (KEEPS the download + overlay caches)
	# work/kernel is root-owned (the kernel build's modules_install runs as root in the build
	# image), so remove it from inside a throwaway container like clean/clean-base — a host-side
	# rm fails with permission errors. work/steam-seed (host-fetched) goes the same way for
	# uniformity. firmware/* are fetched on the host, so a plain rm is fine.
	docker run --rm -v $(CURDIR)/work:/wb busybox rm -rf /wb/kernel /wb/steam-seed
	rm -rf firmware/linux-fw firmware/qcom-fw
