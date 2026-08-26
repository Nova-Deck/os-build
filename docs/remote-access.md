# Remote access (SSH)

A release image ships the SSH server **on**, but with no host keys baked in and no account that
has a password. Nothing about that grants access: sshd is **key-only**, so a running server with
no authorized key admits nobody. There is no build flag, no baked key, and no default credential
anywhere in the tree. Host keys are generated per-device the first time sshd starts.

Access is granted at runtime, by a person holding the device, and it is granted as a **key only**.
Delivering that key over the network is the job of a small pairing daemon that a physical switch
turns on and off.

## How a user pairs

1. On the device: **Settings → System → Enable Developer Mode**, then turn on the developer
   page's remote-access switch. That **starts the pairing daemon**, which listens on port 32000
   and accepts one SSH public key. There is no countdown — it accepts keys for exactly as long as
   the switch is on, so what the switch shows is the truth about whether the device is listening.
2. From the machine you want to connect *from*:

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

   `<device>` is the address shown in the on-screen network settings. While the daemon is running
   the device also advertises itself over mDNS, so `novadeck.local` usually works too — on
   Windows that resolves natively on recent builds, and otherwise needs Bonjour installed, so
   prefer the address if the name does not resolve.
3. The key is appended to `deck`'s `authorized_keys`. sshd is already running, so you can
   `ssh deck@<device>` immediately — no password, and no need to re-pair.
4. **Turn the switch off once the key is exchanged.** That stops the daemon and closes the port.
   Already-installed keys are left in place (they live in `deck`'s home, which survives updates),
   so an already-paired machine keeps working and never has to re-pair.

Third-party pairing GUIs that speak the same protocol work too; the endpoint is deliberately
compatible. Nothing requires you to install one.

## What the switch gates, and what it is protecting

The switch controls the **pairing daemon**, never sshd. That split is the whole security model:

- **sshd is safe to leave on** because it is key-only. With no authorized key it admits nobody;
  after you pair, it admits exactly the machines whose keys you approved. Leaving it on is what
  lets a headless A/B update be verified — the updated slot trial-boots already reachable.
- **The pairing daemon is the sensitive part**, because `POST /register` has to be
  unauthenticated: the whole point is to accept a key from someone who has no credential yet.
  What makes that safe to expose on a café network is that the port only exists while the daemon
  runs, and the daemon runs only while a human has turned the switch on. Physical presence — a
  hand on the device, flipping a switch on its screen — is the credential.

There is **no time window**. An earlier design closed the port after five minutes; it was dropped
because the switch and the window could disagree (the UI still showed "on" after the window had
silently closed), and because the Steam client re-asserts the switch position at boot anyway, so a
window bought no protection that switching the daemon off does not already give. Accepting keys for
exactly as long as the switch is on is both simpler and honest to what the UI shows.

One consequence to know: because the client re-asserts the switch position at session start,
**leaving the switch on means the daemon comes back up on the next boot**, unattended. That is
intended — the UI says on, so it is on — but it is why step 4 says to turn it off once you are
done. A device you have finished pairing should have the switch off.

A submitted line is rejected unless it is exactly one public key of an allowed type that
`ssh-keygen` can fingerprint. In particular a line that begins with `authorized_keys` options
(`command=`, `permitopen=`, `environment=`) is refused — otherwise a registration could install
a forced command rather than a login.

## What persists across an update

- **The key.** `/home` is its own partition and the RAUC handler copies `/var` only, so
  `/home/deck/.ssh/authorized_keys` is untouched by a bundle install or an A/B switch.
- **sshd being on.** It ships enabled for every build, and its per-device host keys live in the
  `/etc` overlay upper (in the per-slot `/var`), which `usr/lib/rauc/post-install.sh` copies A→B —
  so the host key does not change across an update and clients do not see a false MITM.

Together those mean a release bundle installed into the inactive slot **trial-boots with SSH
already reachable by an already-paired machine** — which is what makes a headless release update
verifiable on a board with no serial console.

Use `deck`, not `root`: `/root` is on the read-only root filesystem and does not survive the
slot write, so a key placed there is gone after the first update.

## Verified on hardware (2026-07-29)

The whole path, end to end: switch → helper → daemon → `POST /register` → `ssh deck@<device>`.

- The developer page renders the switch, and the client calls the helper
  (`steamos-polkit-helpers/steamos-devkit-mode`) by absolute path with `--enable` / `--disable`.
  Confirmed both in the client's own strings and in the device journal. The helper's `*)` → exit
  `22` guard matters: the client also calls `--disable` unprompted at session start to assert the
  switch's initial position.
- The polkit grant works — `allow_active` authorises `pkexec` from the gamepad session with no
  auth prompt, which matters because nothing in that session can draw one.
- mDNS advertising works. (It shipped once as a fatal `ExecStartPre` writing into `/etc` under
  `ProtectSystem=full`, which mounts `/etc` read-only; the write failed `EROFS` and took the whole
  daemon down with it — port closed, switch apparently dead. Fixed by making the advertisement
  non-fatal and carving out `/etc/avahi`; `tests/test-pairingd.sh` pins both.)

## Deliberately not done: an on-screen approval prompt

A second confirmation the client *draws* ("Approve this pairing?") would restore "a human is
standing here **now**" as the guarantee, on top of "a human turned the switch on". The client
ships the entry points (`System.Devkit.RegisterForPairingPrompt` / `RespondToPairingPrompt`),
reached by a `steam://devkit-1/<token>/approve-ssh-key?response=<path>` command where the token is
`~/.steam/steam.token` and the response path must be `/tmp/<subdir>/<file>`. All of that was
confirmed on hardware. It is **not** wired up, for two reasons found during that investigation:

- Drawing the modal requires a JS prompt callback that only Steam's own devkit pairing view
  registers; reaching it from our daemon means injecting into the CEF context over the debug port,
  which is brittle across Steam updates.
- The token that gates the command is readable by any `deck`-uid process — i.e. every game — so a
  prompt gated only by it is forgeable by a running game, and would be a weaker guarantee than it
  looks. A future prompt should be our own overlay, gated on something a game cannot supply.
