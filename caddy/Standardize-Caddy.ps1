[CmdletBinding()]
param(
    [string[]]$Targets = @(
        'hk', 'sg', 'jp', 'jp2', 'jp3', 'jp4', 'kr', 'kr2', 'kr3',
        'us', 'us2', 'us3', 'us4', 'us5', 'us6', 'us7', 'tr', 'sz'
    ),
    [switch]$Apply,
    [string]$Revision = 'main'
)
$ErrorActionPreference = 'Stop'
if ($Revision -notmatch '^(main|[0-9a-fA-F]{40})$') {
    throw 'Revision must be main or a full commit SHA.'
}
foreach ($target in $Targets) {
    if ($target -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
        throw "Invalid SSH alias: $target"
    }
}
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) { throw 'OpenSSH client not found.' }

# sudo receives its password from the allocated terminal; shell text is Base64
# encoded to avoid Windows PowerShell 5.1 / native SSH quoting differences.
$remote = @'
set -eu
command -v git >/dev/null || { echo 'ERROR: install git first.'; exit 1; }
work=$(mktemp -d /tmp/linux-scripts-caddy.XXXXXXXX)
trap 'rm -rf "$work"' EXIT
# Use a separate checkout; do not reset or modify a user's existing repository.
git clone --quiet --depth 1 https://github.com/choicky/linux_scripts.git "$work/repo"
if [ '__REVISION__' != main ]; then
    git -C "$work/repo" fetch --quiet --depth 1 origin __REVISION__
    git -C "$work/repo" checkout --quiet --detach FETCH_HEAD
fi
printf 'Repository revision: '
git -C "$work/repo" rev-parse HEAD
bash "$work/repo/caddy/migrate-caddy-debian.sh" __APPLY__
'@
$applyArg = if ($Apply) { '--apply' } else { '' }
$remote = $remote.Replace('__REVISION__', $Revision).Replace('__APPLY__', $applyArg).Replace("`r`n", "`n")
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remote))
$failed = @()
$success = @()
foreach ($target in $Targets) {
    Write-Host "`n===== $target : apply=$($Apply.IsPresent) =====" -ForegroundColor Cyan
    ssh -tt -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 `
        $target "printf %s $encoded | base64 -d | sudo bash"
    if ($LASTEXITCODE -eq 0) {
        $success += $target
    } else {
        $failed += $target
        Write-Host "$target failed or SSH disconnected. Inspect service state before retrying." -ForegroundColor Red
    }
}
Write-Host "`nSuccessful: $($success -join ', ')" -ForegroundColor Green
if ($failed.Count -gt 0) {
    Write-Host "Failed/disconnected: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}
