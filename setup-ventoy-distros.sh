#!/usr/bin/env bash
#
# setup-ventoy-distros.sh
#
# Sets up a Ventoy multi-boot USB with 5 minimal Linux ISOs:
#   Arch Linux, Void Linux (base, glibc), Artix Linux (base, runit),
#   antiX Linux (base), Alpine Linux (standard)
#
# WHAT THIS DOES:
#   1. Downloads Ventoy and flashes it to a USB drive you confirm explicitly
#      (this ERASES the USB — nothing else on the machine is touched).
#   2. Downloads the current ISO for each distro above, verifying checksums
#      where the project publishes them.
#   3. Copies the ISOs onto the Ventoy USB (a normal file copy — after
#      Ventoy is installed, this step is non-destructive and repeatable).
#
# SAFETY:
#   - The script will NOT touch any device until you type the device path
#     yourself at the confirmation prompt. There is no default/auto-detect.
#   - Run `lsblk` in another terminal first if you're not sure which
#     device is your USB stick.
#
# USAGE:
#   chmod +x setup-ventoy-distros.sh
#   ./setup-ventoy-distros.sh
#
set -Eeuo pipefail

WORKDIR="${HOME}/ventoy-distros"
ISODIR="${WORKDIR}/isos"
mkdir -p "$ISODIR"
cd "$WORKDIR"

log()  { echo -e "\n\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33mWARN:\033[0m $*"; }
fail() { echo -e "\033[1;31mERROR:\033[0m $*"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1 (install it and re-run)"; }
for t in curl wget grep sed awk sha256sum tar sort; do need "$t"; done

# ---------------------------------------------------------------------------
# STEP 1: Ventoy install (interactive, explicit device confirmation)
# ---------------------------------------------------------------------------
install_ventoy() {
  log "Checking for existing Ventoy install script..."
  if ! command -v Ventoy2Disk.sh >/dev/null 2>&1 && [ ! -d "${WORKDIR}/ventoy" ]; then
    log "Fetching latest Ventoy release info from GitHub..."
    local api="https://api.github.com/repos/ventoy/Ventoy/releases/latest"
    local tag url
    tag=$(curl -fsSL "$api" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    [ -n "$tag" ] || fail "could not determine latest Ventoy version"
    local ver="${tag#v}"
    url="https://github.com/ventoy/Ventoy/releases/download/${tag}/ventoy-${ver}-linux.tar.gz"
    log "Downloading Ventoy ${tag}..."
    wget -q --show-progress -O ventoy.tar.gz "$url"
    tar xzf ventoy.tar.gz
    mv "ventoy-${ver}" ventoy
  fi

  echo
  echo "Available block devices:"
  lsblk -d -o NAME,SIZE,MODEL,TRAN
  echo
  echo "⚠️  Ventoy will ERASE the ENTIRE device you specify below (not just a partition)."
  echo "    Type the full path, e.g. /dev/sdb  — NOT /dev/sdb1, and NOT your main disk."
  read -r -p "Type the device path for your USB stick (or 'skip' to skip Ventoy setup): " DEV

  if [ "$DEV" = "skip" ]; then
    warn "Skipping Ventoy install. ISOs will still be downloaded below."
    return
  fi

  [ -b "$DEV" ] || fail "not a valid block device: $DEV"

  echo
  read -r -p "Confirm: ERASE $DEV and install Ventoy? Type the device path again to confirm: " CONFIRM
  [ "$CONFIRM" = "$DEV" ] || fail "confirmation did not match — aborting, nothing was touched."

  log "Installing Ventoy on $DEV ..."
  sudo bash "${WORKDIR}/ventoy/Ventoy2Disk.sh" -i "$DEV"
  log "Ventoy installed. The USB should now have a large exFAT/NTFS partition for ISOs."
}

# ---------------------------------------------------------------------------
# STEP 2: ISO downloads (each function is independent — one failing
# doesn't stop the others; re-run the script to retry just the missing ones)
# ---------------------------------------------------------------------------

verify() { # verify <file> <sha256>
  local f="$1" sum="$2"
  [ -z "$sum" ] && { warn "no checksum available for $f, skipping verification"; return 0; }
  echo "${sum}  ${f}" | sha256sum -c - || fail "checksum mismatch for $f — file is corrupt or tampered, delete it and retry"
}

# Download with curl (not wget — wget's -L/--relative flag behaves
# inconsistently across distros/builds, curl's -L is universal) and
# sanity-check the result size so a redirected-to-an-HTML-error-page
# never gets silently saved as a fake "ISO".
MIN_ISO_BYTES=52428800   # 50MB — real ISOs here are hundreds of MB to ~1.5GB
download() { # download <url> <outfile>
  local url="$1" out="$2"
  curl -fL --progress-bar -o "$out" "$url" || { rm -f "$out"; fail "download failed: $url"; }
  local size
  size=$(stat -c%s "$out" 2>/dev/null || stat -f%z "$out")
  if [ "$size" -lt "$MIN_ISO_BYTES" ]; then
    rm -f "$out"
    fail "downloaded file for $out was only ${size} bytes — that's an error page, not an ISO. The source URL likely changed; check it manually."
  fi
}

get_arch() {
  log "Arch Linux..."
  local base="https://geo.mirror.pkgbuild.com/iso/latest"
  local f="archlinux-x86_64.iso"
  local sum
  sum=$(curl -fsSL "$base/sha256sums.txt" | awk -v f="$f" '$2==f{print $1}')
  [ -f "$ISODIR/$f" ] || download "$base/$f" "$ISODIR/$f"
  (cd "$ISODIR" && verify "$f" "$sum")
}

get_void() {
  log "Void Linux (base, glibc)..."
  local idx="https://repo-default.voidlinux.org/live/current/"
  local listing f sum
  listing=$(curl -fsSL "$idx")
  f=$(echo "$listing" | grep -oE 'void-live-x86_64-[0-9]{8}-base\.iso' | sort -u | tail -1)
  [ -n "$f" ] || fail "could not find current Void base ISO — check $idx manually"
  # checksum file is singular: sha256sum.txt, BSD-style "SHA256 (file) = hash" lines
  sum=$(curl -fsSL "${idx}sha256sum.txt" | grep "$f" | awk '{print $NF}')
  [ -f "$ISODIR/$f" ] || download "${idx}${f}" "$ISODIR/$f"
  (cd "$ISODIR" && verify "$f" "$sum")
}

get_artix() {
  log "Artix Linux (base, runit)..."
  # Artix's own site only links out to third-party mirrors (unstable to
  # scrape); SourceForge hosts the same official ISOs directly and reliably.
  local rss="https://sourceforge.net/projects/artix-linux/rss?path=/iso/base"
  local xml url f
  xml=$(curl -fsSL "$rss")
  url=$(echo "$xml" | grep -oE 'https://sourceforge\.net/projects/artix-linux/files/iso/base/[^"<]*runit[^"<]*x86_64\.iso/download' | sort -u | tail -1)
  [ -n "$url" ] || fail "could not find current Artix base-runit ISO via SourceForge RSS — check https://sourceforge.net/projects/artix-linux/files/iso/base/ manually"
  f=$(basename "$(dirname "$url")")
  [ -f "$ISODIR/$f" ] || download "$url" "$ISODIR/$f"
  warn "Artix: no machine-readable checksum from SourceForge RSS — verify manually against https://artixlinux.org/download.php if you want to double-check."
}

get_antix() {
  log "antiX Linux (base)..."
  local rss="https://sourceforge.net/projects/antix-linux/rss?path=/Final"
  local xml url f
  xml=$(curl -fsSL "$rss")
  url=$(echo "$xml" | grep -oE 'https://sourceforge\.net/projects/antix-linux/files/Final/[^"<]*_x64-base\.iso/download' | sort -u | tail -1)
  [ -n "$url" ] || fail "could not find current antiX base ISO via RSS — check https://antixlinux.com manually"
  f=$(basename "$(dirname "$url")")
  [ -f "$ISODIR/$f" ] || download "$url" "$ISODIR/$f"
  warn "antiX: verify the checksum manually against https://antixlinux.com (md5/sha256 published per release) — no reliable machine-readable checksum source for it."
}

get_alpine() {
  log "Alpine Linux (virt — slimmed kernel, lightest official flavor)..."
  local base="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64"
  local yaml version f sum
  yaml=$(curl -fsSL "${base}/latest-releases.yaml")
  # the yaml lists flavors in sequence; grab the block after the "Virtual"
  # marker and before the next flavor marker ("Xen"), then pull version/sha256
  version=$(echo "$yaml" | awk '/"Xen"/{f=0} f{print} /"Virtual"/{f=1}' | grep 'version:' | head -1 | awk '{print $2}')
  [ -n "$version" ] || fail "could not determine latest Alpine virt version — check $base/latest-releases.yaml manually"
  f="alpine-virt-${version}-x86_64.iso"
  sum=$(echo "$yaml" | awk '/"Xen"/{f=0} f{print} /"Virtual"/{f=1}' | grep 'sha256:' | head -1 | awk '{print $2}')
  [ -f "$ISODIR/$f" ] || download "${base}/${f}" "$ISODIR/$f"
  (cd "$ISODIR" && verify "$f" "$sum")
}

# ---------------------------------------------------------------------------
# STEP 3: copy ISOs onto the Ventoy USB
# ---------------------------------------------------------------------------
copy_to_usb() {
  echo
  read -r -p "Mount point of the Ventoy USB data partition (e.g. /media/you/Ventoy), or 'skip': " MNT
  [ "$MNT" = "skip" ] && { warn "Skipping copy — ISOs are in $ISODIR"; return; }
  [ -d "$MNT" ] || fail "not a directory: $MNT"
  log "Copying ISOs to $MNT ..."
  cp -v "$ISODIR"/*.iso "$MNT"/
  sync
  log "Done. Safely unmount the USB before removing it."
}

# ---------------------------------------------------------------------------
main() {
  install_ventoy
  log "Downloading ISOs (each step is independent; re-run to retry a failed one)..."
  get_arch   || warn "Arch download/verify failed — see message above"
  get_void   || warn "Void download/verify failed — see message above"
  get_artix  || warn "Artix download/verify failed — see message above"
  get_antix  || warn "antiX download/verify failed — see message above"
  get_alpine || warn "Alpine download/verify failed — see message above"
  log "ISOs saved in: $ISODIR"
  ls -lh "$ISODIR"
  copy_to_usb
}

main "$@"
