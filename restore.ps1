# Downloads the latest Veil mainnet snapshot release, verifies every file,
# and unpacks it into the Veil data directory. Run it with the wallet closed.
#
# Usage (from PowerShell):
#   powershell -ExecutionPolicy Bypass -File .\restore.ps1
#
# Options:
#   -DataDir <path>   target data directory (default: %APPDATA%\Veil)
#   -Tag <tag>        restore a specific release instead of the latest
#   -Check            verify tools and show the plan, download nothing big
#   -Yes              no prompts, assume yes

param(
    [string]$DataDir = "$env:APPDATA\Veil",
    [string]$Tag = "",
    [switch]$Check,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = 'ohcee/veil-snapshots'
if ($Tag) { $Base = "https://github.com/$Repo/releases/download/$Tag" }
else      { $Base = "https://github.com/$Repo/releases/latest/download" }
$Work = Join-Path (Get-Location) 'veil-snapshot-work'

# official zstd build, pinned so a swapped download cannot go unnoticed
$ZstdUrl = 'https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-v1.5.7-win64.zip'
$ZstdZipSha256 = 'acb4e8111511749dc7a3ebedca9b04190e37a17afeb73f55d4425dbf0b90fad9'
$ZstdExeRelPath = 'zstd-v1.5.7-win64\zstd.exe'

function Say([string]$msg) { Write-Host "==> $msg" }
function Die([string]$msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

function Confirm-Step([string]$question) {
    if ($Yes) { return $true }
    $ans = Read-Host "$question [y/N]"
    return $ans -match '^(y|yes)$'
}

function Get-Sha256([string]$path) {
    (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLower()
}

# ---- preflight ----------------------------------------------------------

if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
    Die "tar was not found. It ships with Windows 10 and later, on older Windows use the manual steps in the README."
}

$running = Get-Process -Name veild, veil-qt -ErrorAction SilentlyContinue
if ($running -and -not $Check) {
    Die "a Veil wallet or node is running, close it completely first"
}

New-Item -ItemType Directory -Force -Path $Work | Out-Null
Say "fetching the release file list"
Invoke-WebRequest -UseBasicParsing -Uri "$Base/SHA256SUMS" -OutFile (Join-Path $Work 'SHA256SUMS')
Invoke-WebRequest -UseBasicParsing -Uri "$Base/manifest.json" -OutFile (Join-Path $Work 'manifest.json')

$manifest = Get-Content (Join-Path $Work 'manifest.json') -Raw | ConvertFrom-Json
$sums = @{}
Get-Content (Join-Path $Work 'SHA256SUMS') | ForEach-Object {
    if ($_ -match '^([0-9a-f]{64})\s+(.+)$') { $sums[$Matches[2]] = $Matches[1] }
}
$parts = $sums.Keys | Where-Object { $_ -like '*.tar.zst.part-*' } | Sort-Object
if (-not $parts) { Die "could not read the part list from SHA256SUMS" }

$compGB = [math]::Round($manifest.compressed_bytes / 1GB, 1)
$needGB = [math]::Round($manifest.compressed_bytes * 2.2 / 1GB, 0)
$freeGB = [math]::Round((Get-PSDrive -Name (Split-Path -Qualifier (Get-Location)).TrimEnd(':')).Free / 1GB, 0)

Say "snapshot height $($manifest.height), ${compGB}GB to download in $($parts.Count) parts"
Say "target data directory: $DataDir"

if ($freeGB -lt $needGB) {
    Write-Host "WARNING: this needs roughly ${needGB}GB free during restore, this drive has ${freeGB}GB" -ForegroundColor Yellow
    if (-not $Check) { if (-not (Confirm-Step "continue anyway?")) { exit 1 } }
}

if ($Check) {
    if ($running) { Write-Host "WARNING: a wallet is running, a real restore would refuse to start" -ForegroundColor Yellow }
    Say "check complete, everything needed is in place"
    exit 0
}

# ---- download and verify ------------------------------------------------

foreach ($f in $parts) {
    $dest = Join-Path $Work $f
    if ((Test-Path $dest) -and (Get-Sha256 $dest) -eq $sums[$f]) {
        Say "$f already downloaded and verified, skipping"
        continue
    }
    Say "downloading $f"
    Invoke-WebRequest -UseBasicParsing -Uri "$Base/$f" -OutFile $dest
}

Say "verifying checksums"
foreach ($f in $sums.Keys) {
    $dest = Join-Path $Work $f
    if (-not (Test-Path $dest)) { Die "missing file: $f" }
    if ((Get-Sha256 $dest) -ne $sums[$f]) { Die "checksum mismatch on $f, delete it and rerun to redownload" }
}
Say "all files verified"

# ---- get zstd -----------------------------------------------------------

$zstdExe = Join-Path $Work $ZstdExeRelPath
if (-not (Test-Path $zstdExe)) {
    Say "fetching zstd (official build, checksum pinned)"
    $zstdZip = Join-Path $Work 'zstd-win64.zip'
    Invoke-WebRequest -UseBasicParsing -Uri $ZstdUrl -OutFile $zstdZip
    if ((Get-Sha256 $zstdZip) -ne $ZstdZipSha256) { Die "zstd download did not match its pinned checksum, aborting" }
    Expand-Archive -Path $zstdZip -DestinationPath $Work -Force
    Remove-Item $zstdZip
    if (-not (Test-Path $zstdExe)) { Die "zstd.exe not found after unzip" }
}

# ---- unpack -------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
$existing = @('blocks', 'chainstate', 'indexes', 'zerocoin') | Where-Object { Test-Path (Join-Path $DataDir $_) }
if ($existing) {
    Write-Host "the data directory already has: $($existing -join ', ')"
    if (-not (Confirm-Step "replace them with the snapshot? (wallets and settings are untouched)")) {
        Die "stopped, nothing was changed"
    }
    foreach ($d in $existing) { Remove-Item -Recurse -Force (Join-Path $DataDir $d) }
}

Say "joining the parts (needs a moment)"
$joined = Join-Path $Work 'snapshot.tar.zst'
Push-Location $Work
$joinList = ($parts | ForEach-Object { "`"$_`"" }) -join '+'
cmd /s /c "copy /b $joinList `"snapshot.tar.zst`"" | Out-Null
if ($LASTEXITCODE -ne 0) { Pop-Location; Die "joining the parts failed" }
$parts | ForEach-Object { Remove-Item (Join-Path $Work $_) }
Pop-Location

Say "unpacking into $DataDir (this takes a few minutes)"
cmd /s /c "`"$zstdExe`" -dc `"$joined`" | tar -xf - -C `"$DataDir`""
if ($LASTEXITCODE -ne 0) { Die "unpacking failed, the joined archive is still in $Work" }

Say "cleaning up downloaded files"
Remove-Item -Recurse -Force $Work

Say "done. Start your Veil wallet, it will sync the remaining blocks from the network."
