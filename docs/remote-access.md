# Remote access (SSH)

A release image ships with the SSH server installed but **off**, no host keys, and no account
that has a password. Nothing about that changes at build time — there is no build flag, no baked
key, and no default credential anywhere in the tree.

Access is granted at runtime, by a person holding the device, and it is granted as a **key only**.

## How a user pairs

1. On the device: **Settings → System → Enable Developer Mode**, then turn on the developer
   page's remote-access switch. That opens a **five-minute pairing window**. Turning the switch
   on grants nothing by itself: the SSH server is still not running.
2. From the machine you want to connect *from*, within those five minutes.

   Linux / macOS:

   ```sh
   curl -X POST --data-binary @~/.ssh/id_ed25519.pub http://<device>:32000/register
   ```

   Windows — **`curl.exe`, not `curl`**. Windows has shipped real curl in `System32` since
   Windows 10 1803, but in the default Windows PowerShell (5.1) the bare word `curl` is an
   alias for `Invoke-WebRequest`, which takes different arguments and fails with a confusing
   error. Spelling out the `.exe` bypasses the alias. There is no `~`, so use `$env:USERPROFILE`
   (PowerShell) or `%USERPROFILE%` (cmd):

   ```powershell
   curl.exe -X POST --data-binary "@$env:USERPROFILE\.ssh\id_ed25519.pub" http://<device>:32000/register
   ```

   Or with no curl at all, using PowerShell's own client — `-InFile` sends the file's bytes
   unmodified, which is what this needs:

   ```powershell
   Invoke-RestMethod -Method Post -Uri http://<device>:32000/register `
     -InFile "$env:USERPROFILE\.ssh\id_ed25519.pub"
   ```

   Windows has also shipped the OpenSSH client since 1809, so `ssh-keygen` and `ssh` are
   present and the key is in the usual place. If you have no key yet, `ssh-keygen -t ed25519`
   works identically there. CRLF line endings in the key file are handled.

   `<device>` is the address shown in the on-screen network settings. While the window is open
   the device also advertises itself over mDNS, so `novadeck.local` usually works too — on
   Windows that resolves natively on recent builds, and otherwise needs Bonjour installed, so
   prefer the address if the name does not resolve.
3. The key is appended to `deck`'s `authorized_keys`, the SSH server is switched on, and you can
   `ssh deck@<device>` from then on — no password, and no need to re-pair.

Turning the switch **off** stops accepting keys *and* stops the SSH server. Already-installed
keys are left alone, so turning it back on does not require pairing again.

Third-party pairing GUIs that speak the same protocol work too; the endpoint is deliberately
compatible. Nothing requires you to install one.

## Why the window, and what it is protecting

`POST /register` has to be unauthenticated — the whole point is to accept a key from someone who
has no credentials yet. What makes that safe to expose on a café network is that the port only
accepts registrations while a window is open, and a window can only be opened by someone
physically holding the device and flipping a switch on its screen. Physical presence is the
credential.

The window is measured from the agent's own start against `CLOCK_MONOTONIC`, so there is no
stamp file to forge and no clock to trust. The unit is `Restart=no` and has **no `[Install]`
section**, which means a window cannot be opened by a crash, by a restart loop, or by an
unattended boot — the agent is structurally un-enableable and can only be started by the switch.
`images/test-pairingd.sh` pins all of that.

A submitted line is rejected unless it is exactly one public key of an allowed type that
`ssh-keygen` can fingerprint. In particular a line that begins with `authorized_keys` options
(`command=`, `permitopen=`, `environment=`) is refused — otherwise a registration could install
a forced command rather than a login.

## What persists across an update

- **The key.** `/home` is its own partition and the RAUC handler copies `/var` only, so
  `/home/deck/.ssh/authorized_keys` is untouched by a bundle install or an A/B switch.
- **The SSH server being on.** `systemctl enable` writes into `/etc`, whose overlay upper lives
  in the per-slot `/var`, which the handler copies A→B.

Together those mean a release bundle installed into the inactive slot **trial-boots with SSH
already reachable** — which is what makes a headless release update verifiable on a board with
no serial console.

Use `deck`, not `root`: `/root` is on the read-only root filesystem and does not survive the
slot write, so a key placed there is gone after the first update.

## Not yet verified on hardware

- That the developer page renders the switch at all, and that it calls the helper with
  `--enable` / `--disable`. That contract is inferred from the equivalent helper on the
  reference platform, not from our own client's strings. If the client passes something else,
  the helper exits `22` and the switch appears dead — that is the first thing to check.
- The on-screen pairing-approval prompt. The shipped client contains the entry points for one
  (`RegisterForPairingPrompt` / `RespondToPairingPrompt`), and wiring it up as a second
  confirmation on top of the window is the intended next step. It is deliberately not wired up
  yet: a consent gate nobody has seen draw is worse than one whose behaviour is fully
  determined.
