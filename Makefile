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
#   * Container stages run in the novadeck-kbuild image with the repo bind-mounted at
#     /src; host stages either need the network or drive docker themselves (base
#     customization registers qemu binfmt, so it cannot run nested in the container).
#   * Stamp files live under the already-gitignored out/ work/ firmware/ trees.
#
# Memory: builds cross-compile INSIDE docker, never on the host. Don't reorder the
# kernel patches. work/base/<soc> is root-owned (clean-base uses docker to remove it).

# SOC is mandatory — every artifact path and stage script is per-SoC, so there is no
# safe default. An empty/unset SOC is a caller error; only `help` (and a bare `make`,
# which defaults to help) is exempt so the target list is always reachable.
SOC        ?=
ifneq ($(filter-out help,$(MAKECMDGOALS)),)
ifeq ($(strip $(SOC)),)
$(error SOC is required — pass SOC=<soc>, e.g. `make kernel SOC=sm8650`)
endif
endif

KBUILD_IMG ?= novadeck-kbuild

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
# Container: repo bind-mounted at /src. INKBUILD is the plain run; DOCKER lets a
# recipe insert `-e VAR` flags (which must precede the image name) before the image.
DOCKER   := docker run --rm -v $(CURDIR):/src -w /src
INKBUILD := $(DOCKER) $(KBUILD_IMG)
# Test-only credential env, forwarded into the rootfs assembler (no-op unless TEST=1).
TEST_ENV := -e NOVADECK_TEST -e NOVADECK_WIFI_SSID -e NOVADECK_WIFI_PSK -e NOVADECK_SSH_PUBKEY

# --- artifacts (real file targets drive incremental rebuilds) -----------------
KBUILD_STAMP := out/.kbuild-image.stamp
FW_LINUX     := firmware/linux-fw/$(SOC)/.fetched.stamp
FW_EXTRACT   := firmware/extracted/$(SOC)/sha256sums.txt
BASE         := work/base/$(SOC)/usr/bin/sshd
KERNEL       := $(OUT)/Image.gz
ROOTFS       := $(OUT)/images/rootfs.img
BOOTIMG      := $(OUT)/boot/$(SOC)-boot.img
SDCARD       := $(OUT)/images/sdcard.img

# Kernel inputs: any change re-triggers the (full, from-scratch) kernel build.
KERNEL_SRC := kernel/SOURCE.pin kernel/$(SOC)/$(SOC).config \
              $(wildcard kernel/$(SOC)/patches/*.patch) \
              $(wildcard kernel/$(SOC)/dts/qcom/*)

.DEFAULT_GOAL := help

# ==============================================================================
# Phony orchestration targets
# ==============================================================================
.PHONY: help all image toolchain kernel fw-linux fw-extract base rootfs manifest \
        boot sdcard bundle deploy clean clean-base distclean

help: ## Show this help
	@echo "novadeck build — SOC=$(SOC)"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'
	@echo
	@echo "Knobs: SOC BASE_CONFIG VENDOR VERSION ESP NOVADECK_TEST(+creds)"

all: sdcard ## Alias for `sdcard` (the full bring-up image)

image: $(ROOTFS) ## Read-only Btrfs root only (out/<soc>/images/rootfs.img)

toolchain: $(KBUILD_STAMP) ## Build the novadeck-kbuild cross-compile docker image
kernel:    $(KERNEL)       ## Build Image.gz + dtbs + modules (in kbuild container)
fw-linux:  $(FW_LINUX)     ## Fetch open linux-firmware blobs (host, network)
fw-extract: $(FW_EXTRACT)  ## Stage device firmware from VENDOR=<vendor-partition-tree>
base:      $(BASE)         ## Fetch + customize the pinned aarch64 base rootfs (host)
rootfs:    $(ROOTFS)       ## Assemble the read-only root (kernel+fw+base, in container)
boot:      $(BOOTIMG)      ## Package the all-boards boot artifact (in container)
sdcard:    $(SDCARD)       ## Build the flashable SD-card image (in container)

# ==============================================================================
# Toolchain image
# ==============================================================================
$(KBUILD_STAMP): kernel/Dockerfile
	docker build -t $(KBUILD_IMG) -f kernel/Dockerfile kernel
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
# Base rootfs (host — customize-base.sh drives docker + qemu binfmt itself)
# ==============================================================================
$(BASE): base.digest
	images/customize-base.sh $(SOC)
	@test -f $@   # sentinel: sshd present => release runtime layered in

# ==============================================================================
# Kernel (container) — needs both firmware sets baked in (CONFIG_EXTRA_FIRMWARE)
# ==============================================================================
$(KERNEL): $(KERNEL_SRC) $(FW_LINUX) $(FW_EXTRACT) | $(KBUILD_STAMP)
	$(DOCKER) $(if $(BASE_CONFIG),-e BASE_CONFIG=/src/$(BASE_CONFIG)) \
	  $(KBUILD_IMG) kernel/build.sh $(SOC)

# Cross-check the device firmware manifest against the built kernel (non-fatal).
manifest: $(KERNEL) ## Verify firmware-manifest.txt vs the built kernel (in container)
	$(INKBUILD) firmware/manifest.sh $(SOC)

# ==============================================================================
# Read-only root (container) — base userspace + kernel + firmware -> Btrfs image
# ==============================================================================
$(ROOTFS): $(KERNEL) $(BASE) $(FW_LINUX) $(FW_EXTRACT) | $(KBUILD_STAMP)
	$(DOCKER) $(TEST_ENV) $(KBUILD_IMG) \
	  images/assemble-rootfs.sh $(SOC) /src/work/base/$(SOC)

# ==============================================================================
# Boot artifact + bootable media (container)
# ==============================================================================
$(BOOTIMG): $(KERNEL) | $(KBUILD_STAMP)
	$(INKBUILD) boot/package.sh $(SOC)

$(SDCARD): $(BOOTIMG) $(ROOTFS) | $(KBUILD_STAMP)
	$(INKBUILD) images/make-sdcard.sh $(SOC)

# Signed RAUC OTA bundle (Phase 4). Dev builds mint an ephemeral cert; set
# RAUC_CERT/RAUC_KEY (repo-relative, so they resolve under /src) for a real signature.
bundle: $(ROOTFS) | $(KBUILD_STAMP) ## Build a signed RAUC update bundle (in container)
	$(DOCKER) -e RAUC_CERT -e RAUC_KEY $(KBUILD_IMG) \
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

distclean: clean clean-base ## clean + drop fetched/extracted firmware + kernel work tree
	rm -rf work/kernel/linux-$(SOC)* firmware/linux-fw/$(SOC) firmware/extracted/$(SOC)
