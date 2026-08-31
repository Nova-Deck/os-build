"""Is frame generation actually usable on this device, and if not, exactly why.

There are FOUR independent ways this feature can be unavailable, and three of them look
identical from the game's side: nothing happens. A layer that silently no-ops is
indistinguishable from one the user forgot to turn on, so the panel has to be able to say which
of these it is rather than showing a dead toggle:

  1. the image ships no layer            -- build problem, not the user's
  2. the merged FEX guest is not mounted -- the overlay is `nofail`, so this boots fine and
                                            costs x86 games their driver; frame gen goes with it
  3. Lossless Scaling is not installed   -- the generation shaders live in its depot
  4. it IS installed, but on the default Steam branch, which does not ship lsfg-vk.dll

(4) is the one nobody guesses. lsfg-vk v2 reads `lsfg-vk.dll`, which Lossless Scaling publishes
ONLY on a Steam beta branch literally named `lsfg-vk`. The default branch ships `Lossless.dll`,
which the layer parses far enough to look like it is working and then fails deep in pipeline
setup with `Unable to find base shader 'mipmaps' in DLL`. That message names a shader, so it
sends the reader looking at the GPU. Detecting the branch here is the difference between a
one-line fix and an afternoon.
"""
from pathlib import Path

# Where assemble-rootfs.sh stages the payload, and where the runtime overlay merges it. The
# payload path proves the IMAGE carries the layer; the merged path proves the guest is actually
# mounted, which is a separate failure with a separate fix.
PAYLOAD_LAYER = Path("/usr/share/novadeck/guestos-x86-mesa/usr/lib/liblsfg-vk-layer.so")
# The HOST aarch64 layer (packages/lsfg-vk). Proton titles need this one and not the x86 payload:
# Valve's compat tool thunks their Vulkan out to the host arm64 driver, and pressure-vessel
# imports implicit layers from the host's implicit_layer.d. Since Proton titles are most of the
# library, a missing host layer is the more damaging of the two -- and it fails silently, because
# a layer that is never discovered logs nothing at all.
HOST_LAYER = Path("/usr/lib/liblsfg-vk-layer.so")
HOST_MANIFEST = Path("/usr/share/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation.json")
MERGED_MANIFEST = Path(
    "/usr/share/guestos/fex-mesa/usr/share/vulkan/implicit_layer.d"
    "/VkLayer_LSFGVK_frame_generation.json"
)

STEAM_ROOT = Path("/home/deck/.local/share/Steam")
DEPOT_NAME = "Lossless Scaling"
DLL_NAME = "lsfg-vk.dll"          # what v2 needs; only on the `lsfg-vk` beta branch
LEGACY_DLL_NAME = "Lossless.dll"  # what the default branch ships; v2 cannot use it


def _steamapps_dirs():
    """Every steamapps dir Steam knows about, not just the default library.

    Deliberately the same shape as the listing in steam.py rather than a shared helper: the two
    plugins load their py_modules as separate processes, and a module staged in by the build
    would be invisible to the offline suite, which imports from the repo checkout.
    """
    dirs = {STEAM_ROOT / "steamapps"}
    for library in (STEAM_ROOT / "steamapps/libraryfolders.vdf",
                    STEAM_ROOT / "config/libraryfolders.vdf"):
        try:
            lines = library.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            parts = line.strip().split('"')
            if len(parts) >= 4 and parts[1] == "path":
                dirs.add(Path(parts[3]) / "steamapps")
    return sorted(dirs)


def find_dll():
    """(path_to_lsfg_vk_dll, depot_dir_if_installed). Either may be None."""
    depot = None
    for steamapps in _steamapps_dirs():
        candidate = steamapps / "common" / DEPOT_NAME
        try:
            if not candidate.is_dir():
                continue
        except OSError:
            continue
        depot = depot or candidate
        dll = candidate / DLL_NAME
        try:
            if dll.is_file():
                return str(dll), str(candidate)
        except OSError:
            continue
    return None, (str(depot) if depot else None)


def status():
    """A verdict plus the one sentence that tells the user what to do about it.

    `ready` gates the controls; `reason` is a stable machine token so the panel picks its own
    wording; `detail` is the human half. Never raises -- a panel that cannot render its own
    error state is worse than the error.
    """
    def _exists(path):
        try:
            return path.is_file()
        except OSError:
            return False

    layer_staged = _exists(PAYLOAD_LAYER)
    host_layer = _exists(HOST_LAYER) and _exists(HOST_MANIFEST)
    try:
        guest_mounted = MERGED_MANIFEST.is_file()
    except OSError:
        guest_mounted = False

    dll, depot = find_dll()

    if not layer_staged and not host_layer:
        return {
            "ready": False, "reason": "no-layer", "dll": None,
            "detail": "This image does not ship the frame-generation layer.",
        }
    if layer_staged and not guest_mounted:
        return {
            "ready": False, "reason": "no-guest", "dll": None,
            "detail": "The x86 game environment is not mounted, so frame generation "
                      "cannot load. A reboot usually clears this.",
        }
    if dll:
        # Ready, but say so honestly when only half the coverage is present: the two layers serve
        # different kinds of game and neither substitutes for the other.
        if not host_layer:
            return {"ready": True, "reason": "ok", "dll": dll,
                    "detail": "Windows games (Proton) will not be affected on this image — "
                              "only native Linux games."}
        if not layer_staged:
            return {"ready": True, "reason": "ok", "dll": dll,
                    "detail": "Native Linux games will not be affected on this image — "
                              "only Windows games."}
        return {"ready": True, "reason": "ok", "dll": dll, "detail": ""}
    if depot:
        legacy = Path(depot) / LEGACY_DLL_NAME
        try:
            has_legacy = legacy.is_file()
        except OSError:
            has_legacy = False
        if has_legacy:
            return {
                "ready": False, "reason": "wrong-branch", "dll": None,
                "detail": "Lossless Scaling is installed, but on its default branch. "
                          "Frame generation needs its 'lsfg-vk' beta branch: open its "
                          "Properties in Steam, choose Betas, pick 'lsfg-vk', and let it update.",
            }
        return {
            "ready": False, "reason": "no-dll", "dll": None,
            "detail": "Lossless Scaling is installed but its frame-generation files are "
                      "missing. Verify its files in Steam, and make sure it is on the "
                      "'lsfg-vk' beta branch.",
        }
    return {
        "ready": False, "reason": "not-installed", "dll": None,
        "detail": "Frame generation needs Lossless Scaling, a paid app on Steam, switched "
                  "to its 'lsfg-vk' beta branch.",
    }
