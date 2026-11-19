#!/usr/bin/env python3
"""Edit a staged overlay PKGBUILD for build-overlay.sh: bump pkgrel, register the pin's patches.

    overlay-pkgbuild.py PKGBUILD [--suffix N] [PATCH...]

  - pkgrel=R becomes pkgrel=R.N, so pacman prefers our build over the holo one on upgrade.
  - each patch is applied with `patch -p1` right after the first `cd <dir>` in prepare(), and
    appended to source=() so makepkg copies it into $srcdir.
  - each patch gets a 'SKIP' in EVERY generic checksum array the PKGBUILD declares (sha256sums,
    b2sums, ...), or in a new sha256sums when it declares none, so the arrays stay as long as
    source=().

WHY THE SKIPS. makepkg checks every source against every checksum array the PKGBUILD declares,
entry by entry, so a source+= with no matching sums entry fails the build. That used to be
answered with `makepkg --skipinteg`, which switched off EVERY checksum, so no upstream tarball in
the overlay was ever verified (#150). The patches need no checksum here: they are committed
files, and packages/inputhash.sh already hashes them into the stamp and the lock.

Architecture-specific arrays (sha256sums_aarch64, ...) are left alone: the patches go into the
generic source=(), which only the generic arrays describe.

Exits 3 when there are patches but prepare() has no `cd <dir>` to place them after.
"""
import re
import sys

KINDS = ("ck", "md5", "sha1", "sha224", "sha256", "sha384", "sha512", "b2")
SUMS = re.compile(r"^(%s)sums\+?=\(" % "|".join(KINDS))
PKGREL = re.compile(r"^pkgrel=(\S+)")
PREPARE = re.compile(r"^prepare\s*\(\)")
CD = re.compile(r"^\s*cd\s+\S+")


class NoCd(Exception):
    pass


def declared_sums(lines):
    """The generic checksum arrays a PKGBUILD assigns at the top level, in first-seen order."""
    seen = []
    for line in lines:
        m = SUMS.match(line)
        if m and m.group(1) not in seen:
            seen.append(m.group(1))
    return seen


def edit(text, patches, suffix=""):
    """The edited PKGBUILD text. Raises NoCd when patches cannot be placed."""
    lines = text.splitlines()
    out, in_prepare, applied = [], False, False
    for line in lines:
        m = PKGREL.match(line)
        if m and suffix:
            out.append("pkgrel=%s.%s" % (m.group(1), suffix))
            continue
        out.append(line)
        if PREPARE.match(line):
            in_prepare = True
        if in_prepare and not applied and CD.match(line):
            out.extend('  patch -p1 < "$srcdir/%s"' % p for p in patches)
            applied = True
    result = "\n".join(out) + "\n"
    if not patches:
        return result
    if not applied:
        raise NoCd("no 'cd <dir>' found in prepare(); cannot place patch step")
    skips = " ".join("'SKIP'" for _ in patches)
    result += "\nsource+=(%s)\n" % " ".join("'%s'" % p for p in patches)
    for kind in declared_sums(lines) or ["sha256"]:
        result += "%ssums+=(%s)\n" % (kind, skips)
    return result


def main(argv):
    args = argv[1:]
    if not args:
        sys.stderr.write("usage: overlay-pkgbuild.py PKGBUILD [--suffix N] [PATCH...]\n")
        return 2
    path, rest, suffix = args[0], args[1:], ""
    if rest[:1] == ["--suffix"]:
        if len(rest) < 2:
            sys.stderr.write("--suffix needs a value\n")
            return 2
        suffix, rest = rest[1].strip(), rest[2:]
    with open(path) as f:
        text = f.read()
    try:
        edited = edit(text, rest, suffix)
    except NoCd as exc:
        sys.stderr.write("ERROR: %s\n" % exc)
        return 3
    with open(path, "w") as f:
        f.write(edited)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
