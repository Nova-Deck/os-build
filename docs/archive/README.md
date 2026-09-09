# Archived phase documents

**These are closed-phase records, not current documentation.** Each one was the design and
validation log for a bring-up phase that has since shipped. They are kept because ~30 places in
the tree — source comments, stage READMEs, two test suites — cite them for *why* something is
shaped the way it is, and that rationale is not written down anywhere else. They are not kept as
a description of how the system behaves today.

**Read them for rationale. Do not read them for current behaviour**, and do not update them to
match the tree: a phase record that gets edited to stay current stops being a record of what was
decided and why. When something here is contradicted by the shipping system, the tree wins.

| Document | Phase | Status |
|---|---|---|
| [`bringup.md`](bringup.md) | 1 — boot generic arm64 with Turnip Vulkan presenting to KMS | closed (hardware gate cleared) |
| [`bringup-phase2.md`](bringup-phase2.md) | 2 — the SteamOS layers: gamescope session, HW-support, InputPlumber, audio | closed |
| [`bringup-phase3.md`](bringup-phase3.md) | 3 — the native arm64 Steam Deck UI inside the phase-2 session | closed |
| [`phase4.md`](phase4.md) | 4 — sealed manifest rootfs (4a), A/B atomic updates (4b), bootstrap from packages (4c) | closed; **its 4b slot-state design was superseded in phase 5** (stated at the top of the file) |
| [`phase5.md`](phase5.md) | 5 — the SteamDeck-style boot chain: steamcl + GRUB, update path, demote-on-failure | closed; "implemented", HW-validated 2026-08-02 |
| [`phase5-bootattempts.md`](phase5-bootattempts.md) | the `boot-attempts` GRUB module that replaced Valve's steamenv counter | closed; design + post-mortem for a module that still ships |

## Known-stale claims

Recorded here rather than edited into the documents above, so the records stay intact:

- **`phase4.md`** says the kernel "ships at `/usr/lib/novadeck/boot.img`". It does not — phase 5
  replaced that file with the `/usr/lib/novadeck/boot` **directory**, installed by
  `rootfs/lib-assemble-boot.sh`. See [`../ota.md`](../ota.md).
- **`phase4.md`** cites four paths that no longer exist: `boot/cmdline`, `boot/package.sh`,
  `image/initramfs/test-slot-state.sh`, `images/provenance.list` (the last from before the
  2026-08-26 restructure, when `images/` was split into `rootfs/` and `image/`).
- **`phase5.md`** cites `boot/phase5`, which no longer exists.

## Where current documentation lives

| Topic | Document |
|---|---|
| Flashing, reaching, updating and recovering a device | [`../RUNBOOK.md`](../RUNBOOK.md) |
| The update *server* — publishing a bundle, OTA host setup | [`../ota.md`](../ota.md) |
| The boot chain as built today | `boot/README.md`, `image/README.md` |
| The rootfs assembler and its sub-stages | `rootfs/README.md` |
| What has been validated on hardware, and when | [`../worklog/DONE.md`](../worklog/DONE.md) |
