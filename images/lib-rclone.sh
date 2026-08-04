# novadeck R2 plumbing — the pinned rclone and the credential environment, shared by
# images/publish-card.sh and images/r2-preflight.sh.
#
# Sourced, never executed. Its own file because two readers need the identical fetch-and-verify and
# the identical remote definition; two copies of a credential setup is how one of them quietly grows
# a different default. Same "one formula, N readers" discipline packages/inputhash.sh already has.
# shellcheck shell=bash

RCLONE_PIN="${RCLONE_PIN:-$ROOT/images/rclone.pin}"

pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

# --- rclone, pinned -------------------------------------------------------------------------
# Fetched to work/tools/ and verified against images/rclone.pin rather than installed from a distro
# repo: the tool that moves our artifacts should not float between a runner and a developer's box.
rclone_bin() {
  local ver url sha host dest zip dir
  [ -f "$RCLONE_PIN" ] || die "no rclone pin: $RCLONE_PIN"
  ver="$(pin_field "$RCLONE_PIN" version)"
  case "$(uname -m)" in
    x86_64)        host=amd64 ;;
    aarch64|arm64) host=arm64 ;;
    *) die "no pinned rclone for $(uname -m) — add it to $RCLONE_PIN" ;;
  esac
  url="$(pin_field "$RCLONE_PIN" "url_$host")"
  sha="$(pin_field "$RCLONE_PIN" "sha256_$host")"
  [ -n "$ver" ] && [ -n "$url" ] && [ -n "$sha" ] || die "$RCLONE_PIN: missing version/url/sha for $host"

  dest="$ROOT/work/tools/rclone-$ver-$host/rclone"
  if [ ! -x "$dest" ]; then
    log "fetching rclone $ver ($host)"
    mkdir -p "$(dirname "$dest")"
    zip="$(mktemp)"
    curl -fsSL "$url" -o "$zip" || die "rclone $ver: download failed ($url)"
    # Verify BEFORE extracting, exactly as oras_bin does: an archive is executed-adjacent code, and
    # checking it after unpacking means the bad bytes already reached the filesystem.
    echo "$sha  $zip" | sha256sum -c --status - \
      || { rm -f "$zip"; die "rclone $ver: sha256 mismatch against $RCLONE_PIN"; }
    dir="$(mktemp -d)"
    unzip -q -j "$zip" "*/rclone" -d "$dir" || die "rclone $ver: archive has no rclone binary"
    mv "$dir/rclone" "$dest"
    rm -rf "$zip" "$dir"
    chmod +x "$dest"
  fi
  printf '%s\n' "$dest"
}

# --- the R2 remote --------------------------------------------------------------------------
# Configured entirely through the environment so no credential is ever written to disk — the same
# instinct as .github/workflows/image.yml keeping the RAUC key in $RUNNER_TEMP: anything left in the
# workspace gets swept into artifacts and caches. The remote is named "r2"; paths are r2:<bucket>/...
r2_env() {
  : "${R2_ACCOUNT_ID:?R2_ACCOUNT_ID not set}"
  : "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID not set}"
  : "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY not set}"
  : "${R2_BUCKET:?R2_BUCKET not set}"
  : "${R2_PUBLIC_BASE:?R2_PUBLIC_BASE not set (the r2.dev URL, or a custom domain if one is attached)}"

  export RCLONE_CONFIG_R2_TYPE=s3
  export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
  export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
  export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export RCLONE_CONFIG_R2_REGION=auto
  # R2 implements no per-object ACLs; asking for one makes every PUT fail. Public access is a
  # BUCKET setting (Settings -> Public access -> r2.dev subdomain), which is why this says private
  # and the bucket is what is public.
  export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
  export RCLONE_CONFIG_R2_ACL=private
}
