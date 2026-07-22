# Architecture review

This repository already has a solid architectural base for an OS-image build system:

- a **single top-level Makefile** orchestrates the build graph
- implementation stays in **stage-local scripts** under `kernel/`, `images/`, `boot/`, `firmware/`, and `packages/`
- all major external inputs are **pinned** for reproducibility
- the build produces **one unified image** for all supported Snapdragon targets

That said, the current design also has a few coupling points that will become more expensive as Phase 4+ work grows.

## What is working well

### 1. Clear stage ownership

The repository layout maps cleanly to the build pipeline:

- `kernel/` owns kernel config, patches, and DTBs
- `firmware/` owns firmware fetch/verification
- `packages/` owns overlay package inputs
- `images/` owns rootfs and A/B image assembly
- `boot/` owns boot artifact packaging

This is a good boundary model and should be preserved.

### 2. Reproducibility-first inputs

Pinned base images, firmware sources, and package sources keep the build explainable and repeatable. That is especially important for firmware-heavy handheld bring-up work.

### 3. Unified-image strategy

Using one build for all supported SoCs avoids duplicated pipelines and reduces per-device drift. For a small hardware matrix, that is a strong default.

## Main architectural risks

### 1. Implicit stage contracts

Most stage boundaries are documented conceptually, but many **actual contracts** are still implicit: expected inputs, produced artifacts, required environment variables, and which paths are considered stable.

This makes refactors harder because contributors often need to read both the Makefile and the stage script to infer the full contract.

### 2. `images/assemble-rootfs.sh` is a concentration point

The rootfs assembly step is the most coupled part of the repository. It pulls together:

- the customized base
- kernel artifacts
- firmware payloads
- `fs-overlay/`
- test-only credential injection
- final image generation

That is workable today, but it is the clearest place where future changes are likely to pile up.

### 3. Build mode is environment-driven

`NOVADECK_TEST=1` is practical, but test/release differences are controlled by environment rather than by a first-class build mode. That increases the chance of accidental test payload carry-over in local workflows.

### 4. Artifact paths are scattered

Important artifact locations are stable, but they are defined in multiple places. That increases maintenance cost whenever stage outputs or intermediate paths need to change.

## Recommended improvements

The highest-value improvements are small and documentation-friendly.

### Recommendation 1: document explicit stage contracts

Add a short contract section for each major stage covering:

- inputs
- outputs
- required environment variables
- whether the stage runs on the host or in the build container

Suggested files to document first:

- `kernel/build.sh`
- `images/customize-base.sh`
- `images/assemble-rootfs.sh`
- `packages/build-overlay.sh`
- `boot/package.sh`

**Why first:** this gives the biggest maintainability win with the smallest possible change.

### Recommendation 2: promote build mode to a first-class knob

Replace the current test/release distinction being primarily environment-driven with an explicit mode such as:

- `BUILD_MODE=release`
- `BUILD_MODE=test`

`NOVADECK_TEST` can still be derived internally if needed, but the public interface should make the mode visible in `make help` and CI.

**Why next:** it reduces operator error without changing the overall build model.

### Recommendation 3: split rootfs assembly into named sub-stages

Keep `images/assemble-rootfs.sh` as the entry point, but separate its logical phases into clearly named functions or sourced helpers, such as:

- stage base userspace
- stage kernel artifacts
- stage firmware
- apply `fs-overlay/`
- apply test-only customization
- emit final images

**Why next:** it lowers coupling at the most complex point in the pipeline without changing repository behavior.

### Recommendation 4: centralize artifact path definitions

Create one shared artifact-path definition file for common outputs such as:

- `out/Image.gz`
- `out/dtbs/`
- `out/images/rootfs.img`
- `out/images/var.img`
- `out/boot/novadeck-boot.img`

**Why later:** not urgent, but it will make future refactors safer.

### Recommendation 5: formalize patch ordering expectations

Kernel patch order is currently convention-driven. If patch count grows, add a simple manifest or documented ordering rule so patch dependencies are explicit rather than encoded only in filenames and comments.

**Why later:** current scale may not require more than documentation, but growth likely will.

## Suggested implementation order

1. **Document stage contracts**
2. **Make build mode explicit**
3. **Modularize rootfs assembly**
4. **Centralize artifact paths**
5. **Formalize patch ordering**

## Recommendation summary

The repository does **not** need an architectural rewrite. The current overall design is sound.

The best improvements are to make the existing architecture easier to understand and safer to evolve:

- turn implicit stage boundaries into explicit contracts
- make build mode visible
- reduce complexity at the rootfs assembly choke point
- centralize shared path assumptions

Those changes preserve the current strengths of the repo while lowering maintenance risk as more boards, update logic, and CI automation are added.
