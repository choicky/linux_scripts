[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[0-9a-f]{40}$')][string]$Revision,
    [Parameter(Mandatory=$true)][string[]]$Targets,
    [switch]$ConfigOnly,
    [switch]$ArchiveConfigs,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
$work = Join-Path ([IO.Path]::GetTempPath()) ('caddy-migration-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$results = @()
try {
    $zip = Join-Path $work 'source.zip'
    Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/choicky/linux_scripts/archive/$Revision.zip" -OutFile $zip
    Expand-Archive -LiteralPath $zip -DestinationPath $work
    $root = Join-Path $work "linux_scripts-$Revision"
    $bundle = Join-Path $work 'scripts.tar'
    & tar -cf $bundle -C $root caddy
    if ($LASTEXITCODE -ne 0) { throw 'Could not create script bundle.' }
    foreach ($target in $Targets) {
        if ($target -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') { throw "Invalid SSH alias: $target" }
        $name = 'caddy-migration-' + [Guid]::NewGuid().ToString('N') + '.tar'
        Write-Host "`n===== $target =====" -ForegroundColor Cyan
        & scp -o ConnectTimeout=15 $bundle "${target}:$name"
        if ($LASTEXITCODE -ne 0) {
            $results += [pscustomobject]@{Host=$target; Result='UPLOAD FAILED'}
            continue
        }
        # scp writes into the remote user's home. Root extracts only the caddy
        # subtree from the exact revision downloaded above, into a private dir.
        $flag = ''
        if ($Apply) { $flag = '--apply' }
        if ($ConfigOnly) { $flag += ' --config-only' }
        if ($ArchiveConfigs) { $flag += ' --archive-configs' }
        $remote = @'
set -eu
archive="$HOME/__NAME__"
work=$(sudo mktemp -d /root/caddy-batch.XXXXXXXX)
trap 'rm -f -- "$archive"; sudo rm -rf -- "$work"' EXIT
sudo tar --no-same-owner -xf "$archive" -C "$work"
set +e
sudo bash "$work/caddy/migrate-caddy-debian.sh" __FLAG__
result=$?
exit "$result"
'@
        $remote = $remote.Replace('__NAME__',$name).Replace('__FLAG__',$flag).Replace("`r`n","`n")
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remote))
        & ssh -t -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 $target "printf %s $encoded | base64 -d | bash"
        $sshExit = $LASTEXITCODE
        $result = 'FAILED'
        if ($sshExit -eq 0) {
            $result = 'PLAN OK'
            if ($Apply) { $result = 'APPLIED' }
        }
        elseif ($sshExit -eq 3) { $result = 'SKIPPED' }
        elseif ($sshExit -eq 4) { $result = 'BLOCKED' }
        $results += [pscustomobject]@{Host=$target; Result=$result}
    }
} finally {
    $results | Format-Table -AutoSize
    Remove-Item -LiteralPath $work -Recurse -Force
}
if (@($results | Where-Object { $_.Result -like '*FAILED*' -or $_.Result -eq 'BLOCKED' }).Count -gt 0) { throw 'Some hosts failed or were blocked; inspect their output before retrying.' }
