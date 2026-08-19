#!/usr/bin/env bash
# Copies one published release from a source repo to a mirror repo, so a repo
# can carry the same downloads as another without rebuilding the snapshot.
#
# Run it from a host with a fast uplink (a VPS, or a builder that still has
# the parts): it downloads the assets and reuploads them, so a slow home line
# is the wrong place for the tens of gigabytes involved. A builder can instead
# publish to several repos in one pass with MIRROR_REPOS, see build-snapshot.sh;
# this script is for backfilling releases that already exist.
#
# Usage: mirror-release.sh <tag> [--from <owner/repo>] [--to <owner/repo>] [--dir <path>]
#   --from  source repo    (default: Veil-Project/veil-snapshots)
#   --to    mirror repo    (default: ohcee/veil-snapshots)
#   --dir   working dir for the assets (default: a temp dir, removed after)

set -euo pipefail

TAG=""
FROM="Veil-Project/veil-snapshots"
TO="ohcee/veil-snapshots"
DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM="$2"; shift 2 ;;
        --to)   TO="$2"; shift 2 ;;
        --dir)  DIR="$2"; shift 2 ;;
        -*)     echo "unknown option: $1" >&2; exit 2 ;;
        *)      TAG="$1"; shift ;;
    esac
done
[ -n "$TAG" ] || { echo "usage: mirror-release.sh <tag> [--from o/r] [--to o/r] [--dir path]" >&2; exit 2; }

command -v gh >/dev/null 2>&1 || { echo "gh cli not installed" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh not authenticated, run: gh auth login" >&2; exit 1; }
gh api "repos/$TO" -q .permissions.push | grep -q true \
    || { echo "no write access to $TO" >&2; exit 1; }

CLEANUP=0
if [ -z "$DIR" ]; then DIR=$(mktemp -d); CLEANUP=1; fi
trap '[ "$CLEANUP" = 1 ] && rm -rf "$DIR"' EXIT

say() { echo "==> $*"; }

if gh release view "$TAG" -R "$TO" >/dev/null 2>&1; then
    say "$TO already has $TAG, checking for any missing assets"
fi

say "downloading $TAG from $FROM"
gh release download "$TAG" -R "$FROM" -D "$DIR" --skip-existing

say "verifying checksums before reuploading"
( cd "$DIR" && { command -v sha256sum >/dev/null 2>&1 \
    && sha256sum -c SHA256SUMS || shasum -a 256 -c SHA256SUMS; } ) \
    || { echo "checksums do not match, refusing to mirror a broken copy" >&2; exit 1; }

# match the source's latest flag: only mainnet releases are "latest"
LATEST_FLAG="--latest=false"
case "$TAG" in mainnet-*) LATEST_FLAG="--latest" ;; esac

if ! gh release view "$TAG" -R "$TO" >/dev/null 2>&1; then
    NOTES=$(gh release view "$TAG" -R "$FROM" --json body -q .body)
    TITLE=$(gh release view "$TAG" -R "$FROM" --json name -q .name)
    gh release create "$TAG" -R "$TO" --draft --title "$TITLE" --notes "$NOTES"
    say "created $TAG on $TO as a draft"
fi

for f in "$DIR"/*; do
    name=$(basename "$f")
    attempt=1
    until gh release upload "$TAG" -R "$TO" --clobber "$f"; do
        attempt=$((attempt + 1))
        [ "$attempt" -gt 3 ] && { echo "upload failed 3 times for $name" >&2; exit 1; }
        say "retrying $name (attempt $attempt)"
        sleep 10
    done
    say "uploaded $name"
done

# shellcheck disable=SC2086
gh release edit "$TAG" -R "$TO" --draft=false $LATEST_FLAG >/dev/null
say "mirrored: $(gh release view "$TAG" -R "$TO" --json url -q .url)"
