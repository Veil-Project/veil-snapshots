#!/usr/bin/env bash
# Downloads the latest Veil mainnet snapshot release, verifies every file,
# and unpacks it into the Veil data directory. Run it with the wallet closed.
#
# Usage: restore.sh [--datadir <path>] [--tag <release-tag>] [--check] [--yes]
#   --datadir  target data directory (default: the platform's standard one)
#   --tag      restore a specific release instead of the latest
#   --check    verify tools and show the plan, download nothing big
#   --yes      no prompts, assume yes (for scripted use)

set -euo pipefail

REPO="ohcee/veil-snapshots"

DATADIR=""
TAG=""
CHECK=0
YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --datadir) DATADIR="$2"; shift 2 ;;
        --tag)     TAG="$2"; shift 2 ;;
        --check)   CHECK=1; shift ;;
        --yes)     YES=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$DATADIR" ]; then
    if [ "$(uname)" = "Darwin" ]; then
        DATADIR="$HOME/Library/Application Support/Veil"
    else
        DATADIR="$HOME/.veil"
    fi
fi
if [ -n "$TAG" ]; then
    BASE="https://github.com/$REPO/releases/download/$TAG"
else
    BASE="https://github.com/$REPO/releases/latest/download"
fi
WORK="veil-snapshot-work"

say() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

dl() {
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --progress-bar -C - -o "$2" "$1" \
            || curl -fL --retry 3 --progress-bar -o "$2" "$1"
    else
        wget -c -O "$2" "$1"
    fi
}

confirm() {
    [ "$YES" = 1 ] && return 0
    [ -t 0 ] || die "not running in a terminal, rerun with --yes to skip prompts"
    printf "%s [y/N] " "$1"
    read -r ans
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---- preflight ----------------------------------------------------------

command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
    || die "need curl or wget installed"
command -v tar >/dev/null 2>&1 || die "need tar installed"
if ! command -v zstd >/dev/null 2>&1; then
    if [ "$(uname)" = "Darwin" ]; then
        die "zstd is not installed. Install it with: brew install zstd"
    else
        die "zstd is not installed. Install it with your package manager, e.g.: sudo apt install zstd"
    fi
fi

WALLET_RUNNING=0
if pgrep -x veild >/dev/null 2>&1 || pgrep -x veil-qt >/dev/null 2>&1 \
    || pgrep -x Veil >/dev/null 2>&1; then
    WALLET_RUNNING=1
fi
if [ "$WALLET_RUNNING" = 1 ] && [ "$CHECK" = 0 ]; then
    die "a Veil wallet or node is running, close it completely first"
fi

mkdir -p "$WORK"
say "fetching the release file list"
dl "$BASE/SHA256SUMS" "$WORK/SHA256SUMS"
dl "$BASE/manifest.json" "$WORK/manifest.json"

HEIGHT=$(grep -o '"height": *[0-9]*' "$WORK/manifest.json" | head -1 | grep -o '[0-9]*' || echo "unknown")
COMPRESSED=$(grep -o '"compressed_bytes": *[0-9]*' "$WORK/manifest.json" | head -1 | grep -o '[0-9]*' || echo 0)
PARTS=$(awk '/\.tar\.zst\.part-/ {print $2}' "$WORK/SHA256SUMS")
PART_COUNT=$(echo "$PARTS" | wc -l | tr -d ' ')
[ -n "$PARTS" ] || die "could not read the part list from SHA256SUMS"

COMP_GB=$(echo "$COMPRESSED" | awk '{printf "%.1f", $1 / 1073741824}')
NEED_KB=$(echo "$COMPRESSED" | awk '{printf "%d", $1 * 2.2 / 1024}')
AVAIL_KB=$(df -k "$WORK" | tail -1 | awk '{print $4}')

say "snapshot height $HEIGHT, ${COMP_GB}GB to download in $PART_COUNT parts"
say "target data directory: $DATADIR"

if [ "$AVAIL_KB" -lt "$NEED_KB" ]; then
    echo "WARNING: this needs roughly $((NEED_KB / 1048576))GB free during restore, you have $((AVAIL_KB / 1048576))GB" >&2
    [ "$CHECK" = 1 ] || confirm "continue anyway?" || exit 1
fi

if [ "$CHECK" = 1 ]; then
    [ "$WALLET_RUNNING" = 1 ] && echo "WARNING: a wallet is running, a real restore would refuse to start" >&2
    say "check complete, everything needed is in place"
    exit 0
fi

# ---- download and verify ------------------------------------------------

for f in $PARTS; do
    want=$(awk -v f="$f" '$2 == f {print $1}' "$WORK/SHA256SUMS")
    if [ -f "$WORK/$f" ] && [ "$(sha256 "$WORK/$f")" = "$want" ]; then
        say "$f already downloaded and verified, skipping"
        continue
    fi
    say "downloading $f"
    dl "$BASE/$f" "$WORK/$f"
done

say "verifying checksums"
cd "$WORK"
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c SHA256SUMS
else
    shasum -a 256 -c SHA256SUMS
fi
cd ..

# ---- unpack -------------------------------------------------------------

mkdir -p "$DATADIR"
EXISTING=""
for d in blocks chainstate indexes zerocoin; do
    [ -d "$DATADIR/$d" ] && EXISTING="$EXISTING $d"
done
if [ -n "$EXISTING" ]; then
    echo "the data directory already has:$EXISTING"
    confirm "replace them with the snapshot? (wallets and settings are untouched)" \
        || die "stopped, nothing was changed"
    for d in $EXISTING; do
        rm -rf "${DATADIR:?}/$d"
    done
fi

say "unpacking into $DATADIR (this takes a few minutes)"
cat "$WORK"/*.tar.zst.part-* | zstd -d | tar -x -C "$DATADIR"

say "cleaning up downloaded files"
rm -rf "$WORK"

say "done. Start your Veil wallet, it will sync the remaining blocks from the network."
