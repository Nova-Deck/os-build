#!/usr/bin/env bash
# lsfg-vk-x86 container half — runs INSIDE the pinned x86 Arch image (see build.sh / builder.pin).
# Expects: SNAPSHOT (Arch Archive date), LSFG_TAG (upstream tag), HOST_UID/HOST_GID, repo at /repo.
set -euxo pipefail

: "${SNAPSHOT:?}" "${LSFG_TAG:?}" "${HOST_UID:?}" "${HOST_GID:?}"
OUT=/repo/work/lsfg-vk-x86/out

# Pin the whole container to the guest rootfs snapshot: the layer loads INSIDE the FEX guest, so
# it must not reference glibc symbols newer than that guest ships. multilib supplies the lib32-*
# halves for the i686 build.
echo "Server=https://archive.archlinux.org/repos/${SNAPSHOT}/\$repo/os/\$arch" >/etc/pacman.d/mirrorlist
printf '[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >>/etc/pacman.conf
pacman -Syyuu --noconfirm
# Upstream's documented build deps, minus Qt6 (LSFGVK_BUILD_UI=OFF). Everything else the project
# needs is vendored in thirdparty/ -- toml++, the Vulkan headers, vk_video and the Vulkan-Hpp
# umbrella -- which is why this list is so short for a Vulkan project.
pacman -S --noconfirm --needed \
  git cmake ninja clang llvm \
  lib32-glibc lib32-gcc-libs

cd /tmp
rm -rf lsfg-vk
# Shallow clone of the exact tag. NO patches are applied anywhere in this file, and none may be:
# CC-BY-NC-ND forbids shipping a modified build (see builder.pin).
git clone --depth 1 --branch "$LSFG_TAG" https://git.lsfg-vk.dev/lsfg-vk.git lsfg-vk
cd lsfg-vk

# The manifest's library_path must stay MANIFEST-RELATIVE. The payload is mounted at
# /usr/share/guestos/fex-mesa rather than at /, and Valve's compat tool republishes that tree
# somewhere else again -- an absolute path would resolve against the wrong root and the Vulkan
# loader would drop the layer with NO error at all. From share/vulkan/implicit_layer.d, three
# levels up is the prefix root, so ../../../lib/ is usr/lib. This is what upstream's own
# dist/podman build uses, and what our HW-validated prebuilt carried.
build_one() { # build_one <build-dir> <extra cmake args...>
  local dir="$1"; shift
  cmake -B "$dir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DLSFGVK_MANAGED=ON \
    -DLSFGVK_BUILD_LAYER=ON \
    -DLSFGVK_BUILD_UI=OFF \
    -DLSFGVK_INSTALL_LIBRARIES=OFF \
    "$@"
  cmake --build "$dir"
}

# x86_64: layer + the CLI, which is the on-device diagnostic (healthcheck/benchmark/validate).
build_one build-x86_64 \
  -DLSFGVK_LAYER_LIBRARY_PATH=../../../lib/liblsfg-vk-layer.so \
  -DLSFGVK_BUILD_CLI=ON

# i686: layer only. LSFGVK_LAYER_MULTILIB_X86 appends _x86 to the layer NAME and .x86 to both the
# library and the manifest, so the two arches coexist in one directory without colliding -- which
# is exactly what the guest tree needs, since the relative library_path puts both in usr/lib.
build_one build-i686 \
  -DCMAKE_CXX_FLAGS=-m32 \
  -DLSFGVK_LAYER_MULTILIB_X86=ON \
  -DLSFGVK_LAYER_LIBRARY_PATH=../../../lib/liblsfg-vk-layer.x86.so \
  -DLSFGVK_BUILD_CLI=OFF

rm -rf "$OUT"
install -Dm0644 build-x86_64/lsfg-vk-layer/liblsfg-vk-layer.so     "$OUT/usr/lib/liblsfg-vk-layer.so"
install -Dm0644 build-i686/lsfg-vk-layer/liblsfg-vk-layer.x86.so   "$OUT/usr/lib/liblsfg-vk-layer.x86.so"
install -Dm0755 build-x86_64/lsfg-vk-cli/lsfg-vk-cli               "$OUT/usr/bin/lsfg-vk-cli"
install -Dm0644 build-x86_64/lsfg-vk-layer/VkLayer_LSFGVK_frame_generation.json \
  "$OUT/usr/share/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation.json"
install -Dm0644 build-i686/lsfg-vk-layer/VkLayer_LSFGVK_frame_generation.json \
  "$OUT/usr/share/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation.x86.json"

# The arches must be what they claim. The two layers differ only by filename, so a build-dir mixup
# would produce a payload that looks complete and silently serves the wrong arch to one of them.
elf_class() { readelf -h "$1" | sed -n 's/.*Class:[[:space:]]*ELF\(32\|64\).*/\1/p'; }
[ "$(elf_class "$OUT/usr/lib/liblsfg-vk-layer.so")" = 64 ] \
  || { echo "ERROR: lsfg-vk-x86: the 64-bit layer is not ELF64" >&2; exit 1; }
[ "$(elf_class "$OUT/usr/lib/liblsfg-vk-layer.x86.so")" = 32 ] \
  || { echo "ERROR: lsfg-vk-x86: the 32-bit layer is not ELF32" >&2; exit 1; }

for m in "$OUT"/usr/share/vulkan/implicit_layer.d/*.json; do
  grep -q '"library_path": "\.\./\.\./\.\./lib/' "$m" || {
    echo "ERROR: lsfg-vk-x86: $(basename "$m") lost its manifest-relative library_path" >&2
    sed -n 's/.*"library_path"/  "library_path"/p' "$m" >&2
    exit 1; }
done
# The two manifests must declare DIFFERENT layer names, or the loader sees one layer twice and
# the 32-bit half never loads. LSFGVK_LAYER_MULTILIB_X86 is what makes them differ; asserting it
# here means a future upstream that drops that suffix fails loudly instead of quietly.
n64="$(sed -n 's/.*"name": "\([^"]*\)".*/\1/p' "$OUT/usr/share/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation.json")"
n32="$(sed -n 's/.*"name": "\([^"]*\)".*/\1/p' "$OUT/usr/share/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation.x86.json")"
[ -n "$n64" ] && [ -n "$n32" ] && [ "$n64" != "$n32" ] \
  || { echo "ERROR: lsfg-vk-x86: both manifests declare the same layer name ('$n64')" >&2; exit 1; }

# Gate: the produced .so must not need a glibc newer than the container's own, which is pinned to
# the guest rootfs generation (builder.pin). A symbol version above that ceiling loads fine here
# and fails inside the FEX guest, where nobody is watching.
glibc_max="$(ldd --version | sed -n '1s/.* //p')"
for so in "$OUT"/usr/lib/liblsfg-vk-layer*.so "$OUT"/usr/bin/lsfg-vk-cli; do
  worst="$(readelf -V "$so" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -uV | tail -1)"
  [ -n "$worst" ] || continue
  printf '[lsfg-vk-x86] %s needs at most %s (container glibc %s)\n' "$(basename "$so")" "$worst" "$glibc_max"
  [ "$(printf '%s\n%s\n' "${worst#GLIBC_}" "$glibc_max" | sort -V | tail -1)" = "$glibc_max" ] \
    || { echo "ERROR: lsfg-vk-x86: $(basename "$so") needs $worst, above the container's glibc $glibc_max" >&2; exit 1; }
done

chown -R "$HOST_UID:$HOST_GID" /repo/work/lsfg-vk-x86
