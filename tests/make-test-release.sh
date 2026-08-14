#!/usr/bin/env bash
# Builds and publishes the tiny synthetic release that the restore tests use.
#
# It is packed exactly the way build-snapshot.sh packs a real snapshot, tar
# through zstd through split, with the same SHA256SUMS and manifest.json
# layout, just a few kilobytes instead of tens of gigabytes. That lets the
# restore scripts be tested on a CI runner, which has nowhere near the disk
# for a real one.
#
# Only needs re-running if the release format changes.
#
# Usage: tests/make-test-release.sh [--no-publish]

set -euo pipefail

REPO="${REPO:-ohcee/veil-snapshots}"
TAG="test-h0"
NAME="veil-test-h0"
# small enough that the archive lands in several parts, so the tests cover
# joining them back together in the right order
PART_SIZE="${PART_SIZE:-48k}"
MARKER="veil-snapshot-restore-test"

PUBLISH=1
[ "${1:-}" = "--no-publish" ] && PUBLISH=0

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

say() { echo "==> $*"; }

# ---- fake chain data ----------------------------------------------------

SRC="$WORK/src"
mkdir -p "$SRC"/{blocks,chainstate,indexes,zerocoin}

# every folder gets a marker the tests assert on, plus enough filler that the
# archive splits into more than one part
for d in blocks chainstate indexes zerocoin; do
    echo "$MARKER $d" > "$SRC/$d/marker.txt"
done
# random rather than repetitive: real chain data barely compresses, and text
# filler would shrink to almost nothing and never split into parts
head -c 200000 /dev/urandom > "$SRC/blocks/blk00000.dat"
head -c 20000 /dev/urandom > "$SRC/chainstate/000001.log"

OUT="$WORK/$TAG"
mkdir -p "$OUT"

TAR_CREATE_OPTS=""
if tar --version 2>&1 | grep -qi bsdtar; then
    TAR_CREATE_OPTS="--no-mac-metadata --no-xattrs"
elif tar --version 2>&1 | grep -qi "GNU tar"; then
    TAR_CREATE_OPTS="--no-xattrs"
fi

# shellcheck disable=SC2086
COPYFILE_DISABLE=1 tar $TAR_CREATE_OPTS -C "$SRC" -cf - blocks chainstate indexes zerocoin \
    | zstd -T0 -10 -q \
    | split -b "$PART_SIZE" - "$OUT/$NAME.tar.zst.part-"

cd "$OUT"

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

: > SHA256SUMS
PARTS_JSONL="$OUT/.parts.jsonl"
: > "$PARTS_JSONL"
TOTAL_BYTES=0
for f in "$NAME".tar.zst.part-*; do
    bytes=$(wc -c < "$f" | tr -d ' ')
    hash=$(sha256 "$f")
    echo "$hash  $f" >> SHA256SUMS
    jq -n --arg file "$f" --argjson bytes "$bytes" --arg sha256 "$hash" \
        '{file: $file, bytes: $bytes, sha256: $sha256}' >> "$PARTS_JSONL"
    TOTAL_BYTES=$((TOTAL_BYTES + bytes))
done

jq -n --arg name "$NAME" --argjson totalbytes "$TOTAL_BYTES" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile parts "$PARTS_JSONL" \
    '{name: $name, chain: "test-fixture", created: $created, height: 0,
      bestblockhash: "0000000000000000000000000000000000000000000000000000000000000000",
      node: "/synthetic/", folders: ["blocks","chainstate","indexes","zerocoin"],
      compressed_bytes: $totalbytes,
      restore: "cat *.tar.zst.part-* | zstd -d | tar -x -C <datadir>",
      txoutsetinfo: {}, parts: $parts}' > manifest.json
rm -f "$PARTS_JSONL"
echo "$(sha256 manifest.json)  manifest.json" >> SHA256SUMS

PART_COUNT=$(ls "$NAME".tar.zst.part-* | wc -l | tr -d ' ')
say "built $PART_COUNT parts, $TOTAL_BYTES bytes total"
[ "$PART_COUNT" -ge 2 ] || { echo "ERROR: need at least 2 parts to test joining" >&2; exit 1; }

if [ "$PUBLISH" = 0 ]; then
    say "publish skipped, files are in $OUT"
    # keep them around for inspection
    cp -R "$OUT" "${TMPDIR:-/tmp}/$TAG-preview"
    say "copied to ${TMPDIR:-/tmp}/$TAG-preview"
    exit 0
fi

# ---- publish ------------------------------------------------------------

if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    say "replacing the existing $TAG release"
    gh release delete "$TAG" -R "$REPO" --yes --cleanup-tag
fi

gh release create "$TAG" -R "$REPO" --prerelease --latest=false \
    --title "Test fixture, not a real snapshot" \
    --notes "A few kilobytes of fake chain data, packed exactly like a real snapshot so the restore scripts can be tested on CI runners that have nowhere near the disk for a real one.

This is **not** a Veil snapshot. Restoring it gives you four folders of nonsense. Real snapshots are tagged \`mainnet-h<height>\` and \`testnet-h<height>\`.

Rebuilt by \`tests/make-test-release.sh\` whenever the release format changes."

for f in "$NAME".tar.zst.part-* SHA256SUMS manifest.json; do
    gh release upload "$TAG" -R "$REPO" --clobber "$f"
done

say "published: $(gh release view "$TAG" -R "$REPO" --json url -q .url)"
