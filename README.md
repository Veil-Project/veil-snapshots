# Veil blockchain snapshots

Quarterly snapshots of the Veil blockchain, mainnet and testnet, so a fresh wallet can skip syncing from genesis. Download the latest release, verify it, unpack it into your data directory, and the wallet only has to sync the weeks since the snapshot instead of years of history.

Hosting costs nothing and there is no server to keep alive. The snapshots are ordinary GitHub release assets, built and published automatically by nodes that people already run.

The restore scripts are [tested on Windows, macOS and Linux](../../actions/workflows/restore-test.yml) on every change, against a small fixture release that exercises the whole path from download through checksums to unpacking.

Each release contains the `blocks`, `chainstate`, `indexes` and `zerocoin` folders from a fully synced node, compressed with zstd and split into parts under 2GB. Snapshots never contain wallets or keys, your funds are not involved in any way, and every release ships checksums plus a manifest so you can prove the chain state is genuine rather than trusting whoever built it.

## Easy mode

One script does all of it: downloads the latest snapshot, verifies every checksum, and unpacks it into the right place.

Expect about 25GB of downloading, roughly 20 minutes on a decent connection, and around 55GB of free disk space while it runs. When it finishes, your data directory holds about 28GB and the downloads are deleted.

**Before you start:** install the [Veil wallet](https://veil-project.com/get-started/) and run it once so it creates your wallet, then close it completely. A snapshot replaces chain data only. It never contains or creates a wallet, so yours has to exist first.

### Step 1, install the two tools the script uses

macOS (needs [Homebrew](https://brew.sh)):

```bash
brew install aria2 zstd
```

Debian or Ubuntu:

```bash
sudo apt install aria2 zstd
```

Installing aria2 is worth it. The script picks it up automatically and it makes the download dramatically faster and more reliable. A real run of the full 24.6GB took 17 minutes with aria2, on a connection where plain downloads had been failing outright. Without it the script falls back to curl, which works but is slower and gives up more easily.

### Step 2, download the script and test your setup

```bash
curl -fsSLO https://raw.githubusercontent.com/Veil-Project/veil-snapshots/main/restore.sh && bash restore.sh --check
```

That downloads nothing big. It just confirms your tools, disk space and data directory are ready, and tells you what it would fetch. Fix anything it complains about before moving on.

### Step 3, do the restore

Close your Veil wallet first, then:

```bash
bash restore.sh
```

It asks before replacing anything. If the download gets interrupted, rerun the same command, it never starts over: verified parts are kept and partial ones resume where they stopped. When it finishes, start your wallet and it syncs the rest from the network.

One thing to expect on that first start: the wallet may rescan the chain, and the progress bar can sit there a while. That is normal and it is not the snapshot being wrong. A brand new wallet skips almost all of it and finishes quickly, because it only scans back as far as its own keys exist. A wallet that already has history, or one holding imported keys with no recorded creation date, rescans from the beginning and that can take hours. Let it finish, it only happens once.

### Testnet

Same script, add `--testnet`:

```bash
bash restore.sh --testnet
```

It fetches the newest testnet release and unpacks into the `testnet4` folder inside your data directory, leaving your mainnet chain alone. Start the wallet with `-testnet` afterwards. Testnet releases are tagged `testnet-h<height>` and mainnet ones `mainnet-h<height>`, so the two never collide.

### Windows

In PowerShell, from a folder where you want the download to land:

```powershell
iwr -useb https://raw.githubusercontent.com/Veil-Project/veil-snapshots/main/restore.ps1 -OutFile restore.ps1; Set-ExecutionPolicy -Scope Process Bypass -Force; .\restore.ps1 -Check
```

That is the same setup test as above. When it looks good, close your wallet and run the real thing:

```powershell
.\restore.ps1
```

The Windows script fetches its own copy of zstd from the official zstd releases and checks it against a pinned checksum, so there is nothing else to install.

Everything below is the same process done by hand.

## Downloading

Grab every file from the [latest release](../../releases/latest): all the `.tar.zst.part-*` files, `SHA256SUMS`, and `manifest.json`.

Or from a terminal with the [GitHub CLI](https://cli.github.com):

```bash
gh release download -R Veil-Project/veil-snapshots -p '*'
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

0. If this is a brand new install, run the Veil wallet once first so it creates your wallet, then close it. Snapshots replace chain data only, they never contain or create a wallet.
1. Shut down the Veil wallet completely and wait for it to exit.
2. In the data directory, delete (or move aside) the old `blocks`, `chainstate`, `indexes` and `zerocoin` folders. Leave everything else alone, especially `wallets`.
3. Extract the snapshot into the data directory.
4. Start the wallet. It syncs the remaining blocks from the network normally.

Extract on macOS, from the folder holding the downloaded parts:

```bash
cat veil-mainnet-h*.tar.zst.part-* | zstd -d | tar -x -C "$HOME/Library/Application Support/Veil"
```

Extract on Linux:

```bash
cat veil-mainnet-h*.tar.zst.part-* | zstd -d | tar --warning=no-unknown-keyword -x -C "$HOME/.veil"
```

Snapshots built on a Mac carry Apple extended attributes that GNU tar does not recognize, and without that flag it prints `Ignoring unknown extended header keyword` once per file. Those are warnings, not errors, and the files extract correctly either way. The flag just keeps the output readable.

Extract on Windows: join the parts first, then unpack. Order matters here, so use PowerShell rather than `copy /b` with a wildcard, which joins in whatever order the folder happens to return and can silently produce a broken archive:

```powershell
$out = [System.IO.File]::Create("$PWD\snapshot.tar.zst")
Get-ChildItem veil-mainnet-h*.tar.zst.part-* | Sort-Object Name | ForEach-Object {
    $in = [System.IO.File]::OpenRead($_.FullName); $in.CopyTo($out); $in.Close()
}
$out.Close()
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

[`build-snapshot.sh`](build-snapshot.sh) runs on a machine with a synced node. It freezes the tip, records the metadata above, stops the node, streams the four folders through `tar | zstd | split`, restarts the node, writes checksums and the manifest, and publishes everything here as a release with the GitHub CLI. The node is only down for the compression step.

A release is created as a draft and only made public once the last file is uploaded. Uploading 25GB takes half an hour, and a release that goes public while it is still filling up is worse than no release at all: it shows as the newest one, `restore.sh` points at it, and the checksums it needs have not arrived yet. Drafts are invisible until they are finished, so there is no window to get caught in.

Both chains are built this way and live in this repo side by side. Mainnet releases are tagged `mainnet-h<height>` and testnet ones `testnet-h<height>`. Only mainnet is ever marked "latest" on GitHub, so plain download links keep pointing at mainnet no matter how recently testnet was rebuilt.

Useful flags while testing: `--dry-run` checks the environment and prints the capture metadata without touching anything, `--no-publish` builds the archive locally without creating a release, `--force` builds even when a recent release already exists. Settings like the data directory, repo, compression level and an optional GPG signing key are environment variables documented at the top of the script.

If the upload fails after the archive is built, which happens for boring reasons like a dropped connection or missing write access, do not run the whole thing again. The parts are still in the work directory:

```bash
./build-snapshot.sh --publish-only
```

That picks up the newest finished build for that chain, re-verifies every checksum, and uploads it. It never touches the node, so there is no second outage and no recompressing tens of gigabytes.

One error worth knowing, because gh reports it misleadingly:

```
! Failed to create release, "workflow" scope may be required.
To request it, run: gh auth refresh -h github.com -s workflow
```

That almost always means you lack **write access to the target repo**, not that your token is missing a scope. Re-authenticating will appear to succeed and change nothing. Check what you actually have:

```bash
gh api repos/<owner>/<repo> -q .permissions
```

If `push` is `false`, no token will help, someone with admin on that repo has to grant you write access. Then rerun with `--publish-only`.

Add `--testnet` to snapshot testnet instead. It reads the `testnet4` folder and publishes under a `testnet-` tag. Each chain's freshness is tracked separately, so a recent mainnet release never stops a testnet build.

If the node is managed by systemd, hand the script the unit rather than letting it stop the process directly, otherwise `Restart=on-failure` can relaunch the node in the middle of the archive:

```bash
STOP_CMD="systemctl stop veild" START_CMD="systemctl start veild" ./build-snapshot.sh --testnet
```

**Give the node time to shut down.** systemd's default `TimeoutStopSec` is 90 seconds, and a mainnet node flushing its chainstate can take longer than that, on a 30GB chain we measured 97 seconds. If systemd kills it part way through, the anon index is left ahead of the chain index, which Veil itself notes in `validation.cpp`, and the next start fails with `Duplicate anon-output ... Attempting to repair anon index` before shutting down again. It recovers on a second start, but a snapshot taken from that datadir carries the damage to everyone who restores it. Raise the timeout well past what a stop actually takes:

```bash
sudo systemctl edit veild
```

```
[Service]
TimeoutStopSec=1800
```

The build checks for this anyway. If the node did not log a completed shutdown, it restarts the node and refuses to archive rather than publish a broken snapshot.

### Seeding a torrent

By default the build deletes its parts once they are on GitHub. Pass `--keep` to leave them in the work directory instead, which is what you want if you also intend to seed them.

The useful trick is that the release download URLs work as **webseeds**, so a torrent made from these files pulls from GitHub as well as from any peers. People with a torrent client get the resilience and resume behaviour of BitTorrent, and the swarm never dies even with zero seeders, because GitHub is always serving.

Two details decide whether those webseeds actually work, and both are easy to get wrong.

A torrent's name comes from the directory you point the tool at, so building from `.` produces a torrent literally named `.`, which clients turn into junk filenames. Point it at the directory by name from the parent instead.

And for a multi-file torrent, a client requests `webseed + torrent_name + / + filename`. Release assets live at `.../releases/download/<tag>/<file>`, so the torrent's directory has to be named exactly the **tag** and the webseed has to stop at `.../releases/download/`. Get either wrong and every webseed request 404s, leaving a torrent that only works while a human is seeding it. `--keep` names the work directory after the tag for exactly this reason, so run the command from its parent:

```bash
cd work
transmission-create -o mainnet-h<height>.torrent \
    -w https://github.com/<owner>/veil-snapshots/releases/download/ \
    -t udp://tracker.opentrackr.org:1337/announce \
    mainnet-h<height>
```

`mktorrent -w <url>` works the same way. Worth confirming before you share it: load the torrent with no peers available and check it downloads from the webseed alone.

Attach the resulting `.torrent` to the release so people find it beside the parts it describes. A torrent can carry several `-w` webseeds, so if more than one person publishes the same snapshot, one torrent can pull from all of their releases at once.

### Run a builder

This pipeline is not meant to have an owner. Anyone with a synced node can run a builder, on either chain, and several people running one at once is the point, that's the redundancy:

1. Clone this repo on the machine with the node.
2. `gh auth login` with a GitHub account that has write access to this repo.
3. Test it with `./build-snapshot.sh --dry-run` (add `--testnet` for testnet).
4. Install the schedule below, with your own day of the month.

Before doing anything, the script checks the newest release *for that chain*. If it is younger than 60 days (`MIN_AGE_DAYS`) it exits without touching the node, and a fresh mainnet release never blocks a testnet build or the other way round. That makes shared scheduling safe: stagger each builder a few days apart (the 1st, the 3rd, the 5th), whoever fires first that quarter publishes, and everyone else's run sees the fresh release and stops. If the first builder's machine is dead that quarter, the next one picks it up automatically.

The node is only down for about the compression step: under 3 minutes for a 28GB mainnet chain on an M4 Mac mini, about 8 minutes for a 14GB testnet chain on a 4 core VPS. The upload afterwards runs with the node back up.

Rough sizes, so you know what disk you need. Mainnet is 28GB on disk and compresses to 24.6GB in 14 parts, testnet is 14GB and compresses to 9.8GB in 6 parts. Mainnet barely compresses because most of its bulk is RingCT and zerocoin proofs, which are already dense.

### Schedule

Snapshots are built quarterly, on the 1st of January, April, July and October. A few months of staleness is fine, the wallet just syncs the tail.

On macOS use a LaunchAgent rather than cron, since macOS blocks `crontab` unless the terminal has Full Disk Access. Copy [`org.veil.snapshots.plist`](org.veil.snapshots.plist) from this repo to `~/Library/LaunchAgents/`, edit the paths inside it to match your setup, then load it with:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.veil.snapshots.plist
```

On a Linux box the equivalent crontab is:

```
PATH=/usr/local/bin:/usr/bin:/bin
17 3 1 1,4,7,10 * cd $HOME/veil-snapshots && git pull -q && ./build-snapshot.sh >> $HOME/veil-snapshot-cron.log 2>&1
```

The `git pull` keeps the builder tracking whatever is published here, so fixes reach it without anyone logging in.

A node under systemd needs the unit passed in, and that means running as a user who can call `systemctl`. This is the entry currently building testnet:

```
PATH=/usr/local/bin:/usr/bin:/bin
SHELL=/bin/bash
17 3 1 1,4,7,10 * cd /root/veil-snapshots && git pull -q && VEIL_BIN=/home/veil DATADIR=/home/veil/.veil WORKDIR=/root/snapshot-work STOP_CMD="systemctl stop veild" START_CMD="systemctl start veild" ./build-snapshot.sh --testnet >> /root/veil-snapshot-cron.log 2>&1
```

Worth testing a scheduled entry in a stripped environment before trusting it, since cron gives you almost none of your usual shell:

```bash
env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=$HOME /bin/bash -c 'cd ~/veil-snapshots && ./build-snapshot.sh --dry-run'
```
