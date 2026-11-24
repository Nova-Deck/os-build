#!/usr/bin/env python3
"""Write the x86 manifests of the game-priority layer from the host layer's own manifest.

    game-priority-manifests.py <host manifest> <implicit_layer.d to write>

Each arch gets its OWN layer name. In a pressure-vessel container the host's manifest and both of
these land in one folder, and the Vulkan loader dedupes by name without looking at the arch, so a
shared name would silently drop the layer. library_path is relative to the manifest: an absolute one
resolves against the container's /usr under the compat tool's /run/gfx republish.

Everything else (entry points, the variables that switch it on and off) is the host's, unchanged.
"""
import json
import pathlib
import sys

LIBRARY = "../../../lib/libVkLayer_novadeck_game_priority{suffix}.so"
ARCHES = {"x86_64": "", "i686": ".i686"}


def main(source, destination):
    manifest = json.loads(pathlib.Path(source).read_text(encoding="utf-8"))
    out = pathlib.Path(destination)
    out.mkdir(parents=True, exist_ok=True)
    for arch, suffix in ARCHES.items():
        layer = {**manifest["layer"],
                 "name": f"{manifest['layer']['name']}_{arch}",
                 "library_path": LIBRARY.format(suffix=suffix)}
        text = json.dumps({**manifest, "layer": layer}, indent=2) + "\n"
        (out / f"VkLayer_novadeck_game_priority.{arch}.json").write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
