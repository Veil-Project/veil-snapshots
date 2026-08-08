# Veil mainnet snapshots

Quarterly snapshots of the Veil mainnet blockchain so a fresh wallet can skip syncing from genesis. Download the latest release, verify it, unpack it into your data directory, and the wallet only has to sync the weeks since the snapshot instead of years of history.

Each release contains the `blocks`, `chainstate`, `indexes` and `zerocoin` folders from a fully synced node, compressed with zstd and split into parts under 2GB. Snapshots never contain wallets or keys, your funds are not involved in any way.

## Downloading

Grab every file from the [latest release](../../releases/latest): all the `.tar.zst.part-*` files, `SHA256SUMS`, and `manifest.json`.

Or from a terminal with the [GitHub CLI](https://cli.github.com):

```bash
gh release download -R ohcee/veil-snapshots
```

## Verifying the download

Check that every part matches its published checksum.

macOS:

```bash
shasum -a 256 -c SHA256SUMS
```

Linux:

```bash
sha256sum -c SHA256SUMS
```

Windows (PowerShell will print hashes to compare against the SHA256SUMS file):

```powershell
Get-FileHash veil-mainnet-h*.tar.zst.part-* -Algorithm SHA256
```

## Restoring a snapshot

Your Veil data directory:

| Platform | Path |
|----------|------|
| Windows  | `%APPDATA%\Veil` |
| macOS    | `~/Library/Application Support/Veil` |
| Linux    | `~/.veil` |

Steps:

1. Shut down the Veil wallet completely and wait for it to exit.
2. In the data directory, delete (or move aside) the old `blocks`, `chainstate`, `indexes` and `zerocoin` folders. Leave everything else alone, especially `wallets`.
3. Extract the snapshot into the data directory.
4. Start the wallet. It syncs the remaining blocks from the network normally.

Extract on macOS or Linux (from the folder holding the downloaded parts):

```bash
cat veil-mainnet-h*.tar.zst.part-* | zstd -d | tar -x -C "$HOME/Library/Application Support/Veil"
```

Use `~/.veil` as the target on Linux.

Extract on Windows: join the parts first, then unpack. In `cmd` from the download folder:

```bat
copy /b veil-mainnet-h*.tar.zst.part-* snapshot.tar.zst
```

Then either open `snapshot.tar.zst` with a recent [7-Zip](https://www.7-zip.org) (extract twice, once for the `.zst` and once for the `.tar`), or with the official [zstd build](https://github.com/facebook/zstd/releases) and the tar that ships with Windows 10 and later:

```bat
zstd -d snapshot.tar.zst
tar -xf snapshot.tar -C "%APPDATA%\Veil"
```

## What you are trusting, and how to check it

A snapshot contains prevalidated chain state, so your node skips validating everything inside it. You are trusting that the publisher captured an honest chain. Two ways to check instead of trusting:

**Quick check.** The release notes and `manifest.json` state the snapshot height and best block hash. Compare that hash against any block explorer or any synced node (`veil-cli getblockhash <height>`). If it matches the network's chain, the snapshot is on the real chain.

**Deep check.** `manifest.json` includes the node's `gettxoutsetinfo` output at capture time. After extracting, start the node once with networking off, ask it the same question, and compare:

```bash
veild -connect=0 -listen=0 -daemon
veil-cli gettxoutsetinfo
veil-cli getbestblockhash
veil-cli stop
```

The hashes and totals should match the manifest exactly. Then start the wallet normally. Anyone who runs a Veil node is welcome to do this on each release and post their result, the more independent confirmations the better.

## How these get built

[`build-snapshot.sh`](build-snapshot.sh) runs on a machine with a synced mainnet node. It freezes the tip, records the metadata above, stops the node, streams the four folders through `tar | zstd | split`, restarts the node, writes checksums and the manifest, and publishes everything here as a release with the GitHub CLI. The node is only down for the compression step.

Useful flags while testing: `--dry-run` checks the environment and prints the capture metadata without touching anything, `--no-publish` builds the archive locally without creating a release. Settings like the data directory, repo, compression level and an optional GPG signing key are environment variables documented at the top of the script.

Snapshots are built quarterly, on the 1st of January, April, July and October. A few months of staleness is fine, the wallet just syncs the tail.

On macOS the schedule runs as a LaunchAgent, since macOS blocks `crontab` unless the terminal has Full Disk Access. The plist lives at `~/Library/LaunchAgents/org.veil.snapshots.plist` (see [launchd.plist](org.veil.snapshots.plist) in this repo) and loads with:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.veil.snapshots.plist
```

On a Linux box the equivalent crontab is:

```
PATH=/usr/local/bin:/usr/bin:/bin
17 3 1 1,4,7,10 * cd $HOME/veil-snapshots && ./build-snapshot.sh >> work/cron.log 2>&1
```

Either way the run logs to `work/cron.log`.
