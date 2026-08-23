#!/usr/bin/env bash
# mesa-x86 container half — runs INSIDE the pinned x86 Arch image (see build.sh / builder.pin).
# Expects: SNAPSHOT (Arch Archive date, e.g. 2026/08/11), PATCHES (mesa patch list, may be
# empty), HOST_UID/HOST_GID (for output ownership), the repo mounted at /repo.
set -euxo pipefail

: "${SNAPSHOT:?}" "${HOST_UID:?}" "${HOST_GID:?}"
OUT=/repo/work/mesa-x86/out

# HAND THE OUTPUT TREE BACK TO THE BUILD USER ON *ANY* EXIT, not just success. The gates below run
# AFTER `install`, so a gate that fires leaves a populated, root-owned out/ behind -- and the host
# half's `rm -rf "$WORKDIR/out"` on the next run then dies with "Permission denied" on every file,
# turning one honest gate failure into a build that cannot be retried without a container to clean
# up after it. Measured 2026-08-23, on the first failure this gate ever caught.
trap 'chown -R "$HOST_UID:$HOST_GID" /repo/work/mesa-x86 2>/dev/null || true' EXIT

# Pin the whole container to the guest rootfs snapshot: the driver must not reference glibc
# symbols newer than the rootfs ships, and every build dep must come from the rootfs's own
# package generation. multilib supplies the lib32-* halves for the i686 build.
echo "Server=https://archive.archlinux.org/repos/${SNAPSHOT}/\$repo/os/\$arch" >/etc/pacman.d/mirrorlist
printf '[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >>/etc/pacman.conf
pacman -Syyuu --noconfirm
pacman -S --noconfirm --needed \
  meson ninja python-mako python-yaml python-packaging python-ply \
  bison flex cmake glslang \
  libdrm libxcb libx11 libxshmfence libxrandr xcb-util-keysyms wayland wayland-protocols \
  lib32-glibc lib32-gcc-libs lib32-libdrm lib32-libxcb lib32-libx11 \
  lib32-libxshmfence lib32-libxrandr lib32-xcb-util-keysyms \
  lib32-wayland lib32-zlib lib32-expat lib32-zstd

# The mesa source is whatever the HOST mesa builds, fetched through the one helper every mesa
# build shares: it reads the URL + sha256 out of packages/mesa/PKGBUILD, tries upstream, falls
# back to the verified mirror, and refuses anything that does not match the pinned hash. One
# source of truth; a host mesa bump is a guest mesa bump with nothing else to edit.
/repo/packages/mesa/fetch-source.sh /tmp
SOURCE_TARBALL="$(bash -c 'source /repo/packages/mesa/PKGBUILD >/dev/null 2>&1; echo "${source[0]##*/}"')"
: "${SOURCE_TARBALL:?packages/mesa/PKGBUILD yielded no source url}"

cd /tmp
tar xf "$SOURCE_TARBALL"
cd "$(tar tf "$SOURCE_TARBALL" | head -1 | cut -d/ -f1)"

# Same patches, same order, as the host mesa build (declared in packages/mesa/source.pin).
for p in ${PATCHES:-}; do
  patch -p1 <"/repo/packages/mesa/patches/$p"
done

cat >/tmp/cross32 <<'EOF'
[binaries]
c = ['gcc', '-m32']
cpp = ['g++', '-m32']
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'

[properties]
pkg_config_libdir = '/usr/lib32/pkgconfig:/usr/share/pkgconfig'

[host_machine]
system = 'linux'
cpu_family = 'x86'
cpu = 'i686'
endian = 'little'
EOF

# Turnip only, loaders off: the guest rootfs already ships its GL/EGL/loader stack; the payload
# replaces exactly the driver the ICDs point at. -march=x86-64 baseline like the rootfs
# userspace — FEX emulates AVX in slower 128-bit halves, so a wider baseline would pessimize.
common=(
  --buildtype release --prefix /usr
  -Db_ndebug=true
  -Dgallium-drivers= -Dvulkan-drivers=freedreno -Dfreedreno-kmds=msm
  -Dplatforms=x11,wayland -Dglx=disabled -Degl=disabled -Dgbm=disabled
  -Dopengl=false -Dllvm=disabled -Dallow-fallback-for=libdrm
)
CFLAGS='-march=x86-64' CXXFLAGS='-march=x86-64' \
  meson setup build-x86_64 --libdir lib "${common[@]}"
ninja -C build-x86_64
CFLAGS='-march=x86-64' CXXFLAGS='-march=x86-64' \
  meson setup build-i686 --libdir lib32 --cross-file /tmp/cross32 "${common[@]}"
ninja -C build-i686

install -Dm0644 build-x86_64/src/freedreno/vulkan/libvulkan_freedreno.so    "$OUT/usr/lib/libvulkan_freedreno.so"
install -Dm0644 build-x86_64/src/freedreno/vulkan/freedreno_icd.x86_64.json "$OUT/usr/share/vulkan/icd.d/freedreno_icd.x86_64.json"
install -Dm0644 build-i686/src/freedreno/vulkan/libvulkan_freedreno.so      "$OUT/usr/lib32/libvulkan_freedreno.so"
install -Dm0644 build-i686/src/freedreno/vulkan/freedreno_icd.i686.json     "$OUT/usr/share/vulkan/icd.d/freedreno_icd.i686.json"

# TEMPORARY WORKAROUND (2026-08-19) — revalidate at the next fex-rootfs bump. Mesa writes an
# ABSOLUTE library_path into the ICD, which is only correct when this tree is mounted at /. It
# is not: Valve's compat tool republishes it as the /run/gfx graphics-provider mount, where
# /usr/lib/... resolves to the CONTAINER's /usr instead of the provider copy. A bare filename
# makes the Vulkan loader resolve through the dlopen search path, which is correct on every
# mount point (and is how Valve's own runtime ICDs are shipped). The guest ld.so.cache lists
# both drivers, so the merged-mount consumers resolve it identically. If a future guest image
# ships relative-path ICDs of its own (or Valve's tooling starts rewriting them), drop this.
sed -i 's|"library_path": "/usr/lib/libvulkan_freedreno.so"|"library_path": "libvulkan_freedreno.so"|' \
  "$OUT/usr/share/vulkan/icd.d/freedreno_icd.x86_64.json"
sed -i 's|"library_path": "/usr/lib32/libvulkan_freedreno.so"|"library_path": "libvulkan_freedreno.so"|' \
  "$OUT/usr/share/vulkan/icd.d/freedreno_icd.i686.json"
for icd in "$OUT"/usr/share/vulkan/icd.d/freedreno_icd.*.json; do
  grep -q '"library_path": "libvulkan_freedreno.so"' "$icd" \
    || { echo "ERROR: mesa-x86: $icd still carries an absolute library_path (mesa changed its ICD format?)" >&2; exit 1; }
done

# The guest rootfs ships no xcb-keysyms (verified against the 2026-08-11 image), but a Turnip
# built here links it (mesa's x11 WSI). An ICD with an unresolvable NEEDED is dropped SILENTLY
# by pressure-vessel's dlopen inspection, so the dep rides along for both arches.
# assemble-rootfs.sh re-checks the full NEEDED closure against the real guest at image build.
install -Dm0644 /usr/lib/libxcb-keysyms.so.1   "$OUT/usr/lib/libxcb-keysyms.so.1"
install -Dm0644 /usr/lib32/libxcb-keysyms.so.1 "$OUT/usr/lib32/libxcb-keysyms.so.1"

# Gate: container glibc == rootfs glibc (the snapshot pin above), so a symbol-version ceiling
# above the container's own glibc could never load in the guest.
glibc_max="$(ldd --version | sed -n '1s/.* //p')"
for so in "$OUT/usr/lib/libvulkan_freedreno.so" "$OUT/usr/lib32/libvulkan_freedreno.so"; do
  ceiling="$(readelf --dyn-syms -W "$so" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1)"
  if [ "$(printf '%s\n%s\n' "$ceiling" "$glibc_max" | sort -V | tail -1)" != "$glibc_max" ]; then
    echo "ERROR: $so references GLIBC_$ceiling, newer than the rootfs glibc $glibc_max" >&2
    exit 1
  fi
done

