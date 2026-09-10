#!/usr/bin/env bash
# novadeck read-only root assembler — stages `decky-payload` and `boot-splash`.
#
# SOURCED by rootfs/assemble-rootfs.sh, never executed. Split out of it for issue #43; the code
# and its rationale are unchanged (tests/test-mkroot.sh reads the `# STAGE <name>` banners out of
# this file set, and asserts the roster it was audited against).
#
# EVERY build, release included -- guard-rootfs.sh assertion 9 requires the plugin dists. Split out
# of the dev-gated blocks that used to bracket them; the assembler notes their position there was
# arbitrary (they only have to precede debug-capture).
#
# Reads the assembler's globals rather than taking arguments -- $stage (the staged tree), $ROOT
# (repo root), $OUT (build outputs). Turning ~20 implicit globals into positional parameters is
# where a verbatim move stops being verbatim, so it is deliberately not done.

# STAGE decky-payload — EVERY build, not a dev injection. It was numbered 4c-3 and sat between the
# DEV-ONLY blocks, which is how a stage every image needs came to be filed under a heading that says
# NEVER part of a release build; the only thing it ever required of its position was to precede
# debug-capture. Renamed when it moved to this file (issue #43). The loader binary arrives
# via its
# prebuilt pin as a BASE ingredient; the first-party plugins are OUR source in this repo, so
# they stage here like rootfs/overlay content. /usr/share is the read-only master copy;
# /usr/lib/novadeck/decky-sync materializes it into /home/deck/homebrew at boot, which is where
# the loader actually loads from. The sync itself needs no list: it copies every directory it
# finds under /usr/share/decky-plugins.
# dist/ is built by `make decky-plugin` (a $(ROOTFS) prerequisite); missing means a stale
# invocation bypassed make — fail rather than assemble an image without its settings UI.
# Keep this list in step with DECKY_PLUGINS in the Makefile and assertion 9 in guard-rootfs.sh.
for plugin_name in novadeck-control novadeck-monitor novadeck-framegen; do
  plugin_src="$ROOT/apps/decky/$plugin_name"
  plugin_dest="$stage/usr/share/decky-plugins/$plugin_name"
  [ -s "$plugin_src/dist/index.js" ] || {
    echo "decky plugin dist missing: ${plugin_src#"$ROOT"/}/dist/index.js (run: make decky-plugin)" >&2
    exit 1
  }
  echo "  injecting Decky plugin $plugin_name -> /usr/share/decky-plugins/"
  install -d -m 0755 "$plugin_dest"
  install -m 0644 "$plugin_src/plugin.json" "$plugin_src/package.json" "$plugin_src/main.py" "$plugin_dest/"
  cp -a "$plugin_src/py_modules" "$plugin_src/dist" "$plugin_dest/"
  rm -f "$plugin_dest/dist/"*.map
  find "$plugin_dest" -name __pycache__ -type d -prune -exec rm -rf {} +
done
unset plugin_name plugin_src plugin_dest

# STAGE boot-splash — the drawer (was 4c-4): the SAME binary and asset the initramfs carries, installed into the
# sealed root as well. Both copies are needed and neither is redundant: the initramfs one paints
# from before root is mounted until the session takes the display, and this one paints the
# shutdown and reboot screens, long after the initramfs has been freed.
#
# Built by `make splash` (a $(ROOTFS) prerequisite via $(INITRAMFS)). Missing means a stale
# invocation bypassed make; fail rather than assemble an image whose shutdown screen is black.
splash_bin="$ROOT/apps/novadeck-splash/build/novadeck-splash"
splash_asset="$ROOT/work/splash/logo.nds1"
splash_font="$stage/usr/share/fonts/noto/NotoSansMono-Medium.ttf"
[ -s "$splash_bin" ] && [ -s "$splash_asset" ] || {
  echo "splash payload missing: ${splash_bin#"$ROOT"/} / ${splash_asset#"$ROOT"/} (run: make splash)" >&2
  exit 1
}
[ -s "$splash_font" ] || {
  echo "splash font missing from the base: ${splash_font#"$stage"/} — the status line needs it" >&2
  exit 1
}
echo "  injecting boot splash -> /usr/lib/novadeck/novadeck-splash"
install -D -m 0755 "$splash_bin" "$stage/usr/lib/novadeck/novadeck-splash"
install -D -m 0644 "$splash_asset" "$stage/usr/share/novadeck/splash/logo.nds1"
# A symlink, not a copy: the font is already in the image and it is 600 KB. The initramfs copy
# has to be a real file (there is no /usr/share/fonts there), but this one does not.
install -d -m 0755 "$stage/usr/share/novadeck/splash"
ln -sfn ../../fonts/noto/NotoSansMono-Medium.ttf "$stage/usr/share/novadeck/splash/font.ttf"
unset splash_bin splash_asset splash_font
