#Requires -Version 7.0
<#
    snapshot.ps1 - capture the whole VM and push it to the state release.

    Three packs are produced for each generation:

        gen-<id>-work.7z.*   C:\Users\rdpuser, verbatim
                             (projects, documents, downloads, app settings,
                              NTUSER.DAT, hidden and system files included)
        gen-<id>-sys.7z.*    Program Files / Program Files (x86) / ProgramData
                             as a DELTA against the pristine baseline - only
                             what you installed or changed
        gen-<id>-meta.7z     registry hives, the RDP user's personal hive,
                             scheduled tasks, service start types, environment
                             variables and package manifests

    The whole set is skipped when its content hash matches the last published
    generation, so an idle VM costs nothing.
#>
param(
    [switch]$Force,        # publish even when nothing changed
    [string]$Reason = 'periodic',
    [string]$ChainOverride
)

. (Join-Path $PSScriptRoot 'lib.ps1')

$sw = [System.Diagnostics.Stopwatch]::StartNew()
Step ('Snapshot ({0})' -f $Reason)

# Start from a clean build area - stale volumes from a larger previous
# generation would otherwise get uploaded alongside the new ones.
$null = Remove-Item -LiteralPath $CFG.BuildDir -Recurse -Force -ErrorAction SilentlyContinue
$null = Remove-Item -LiteralPath $CFG.DownloadDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $CFG.BuildDir | Out-Null

$previous = Get-StateManifest

# ---------------------------------------------------------------------------
# Meta first: its contents feed the change signature.
# ---------------------------------------------------------------------------
$metaRoot = Join-Path $CFG.BuildDir 'meta'
New-Item -ItemType Directory -Force -Path (Join-Path $metaRoot 'registry'),
                                         (Join-Path $metaRoot 'tasks') | Out-Null

function Export-RegistryKey {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Key)
    $target = Join-Path $metaRoot ("registry\" + $Name)
    $output = & reg export $Key $target /y 2>&1
    if ($LASTEXITCODE -eq 0) { Ok ('registry {0}' -f $Key) }
    else { Warn ('registry export failed for {0}: {1}' -f $Key, ($output -join ' ')) }
}

Export-RegistryKey -Name 'hklm-software.reg'       -Key 'HKLM\SOFTWARE'
Export-RegistryKey -Name 'hklm-services.reg'       -Key 'HKLM\SYSTEM\CurrentControlSet\Services'
Export-RegistryKey -Name 'hklm-terminalserver.reg' -Key 'HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server'
Export-RegistryKey -Name 'machine-env.reg'         -Key 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'

# --- the RDP user's personal hive -------------------------------------------
# NTUSER.DAT is locked while that user is logged in, so two export paths:
#   logged in   -> export/save from HKU\<SID>
#   logged out  -> load the file as HKU\VMState, export, unload
# user-hive.key records which key the .reg/.bin belong to, so restore.ps1 can
# load it at exactly the same path.
$ntUser = 'C:\Users\rdpuser\NTUSER.DAT'
$sid    = Get-LocalUserSid -Name 'rdpuser'
if (Test-Path -LiteralPath $ntUser) {
    $loadKey = $null
    if ($sid -and (Test-Path "Registry::HKEY_USERS\$sid")) {
        $loadKey = $sid                                   # user is logged in
    }
    else {
        $probe = & reg load 'HKU\VMState' $ntUser 2>&1
        if ($LASTEXITCODE -eq 0) {
            $loadKey = 'VMState'
            $null = & reg unload 'HKU\VMState' 2>&1
        }
        else { Warn ('personal hive is locked and not loadable: {0}' -f ($probe -join ' ')) }
    }

    if ($loadKey) {
        if ($loadKey -eq 'VMState') {
            $loadOut = & reg load 'HKU\VMState' $ntUser 2>&1
            if ($LASTEXITCODE -ne 0) { $loadKey = $null; Warn ($loadOut -join ' ') }
        }

        if ($loadKey) {
            $regOut = & reg export "HKU\$loadKey" (Join-Path $metaRoot 'registry\user-hive.reg') /y 2>&1
            if ($LASTEXITCODE -ne 0) {
                Warn ('user hive .reg export failed: {0}' -f ($regOut -join ' '))
            }
            else {
                # Binary copy too - restore prefers it, it round-trips exactly.
                $null = & reg save "HKU\$loadKey" (Join-Path $metaRoot 'registry\user-hive.bin') /y 2>&1
                Set-Content -LiteralPath (Join-Path $metaRoot 'registry\user-hive.key') -Value $loadKey -Encoding ascii
                Ok 'rdpuser personal hive exported'
            }
            if ($loadKey -eq 'VMState') { $null = & reg unload 'HKU\VMState' 2>&1 }
        }
    }
}
else { Log 'rdpuser has no NTUSER.DAT yet (never logged in) - personal settings not captured.' }

# --- scheduled tasks ---------------------------------------------------------
$taskLines = [System.Collections.Generic.List[string]]::new()
try {
    $custom = @(Get-ScheduledTask -ErrorAction Stop |
        Where-Object { $_.TaskPath -notlike '\Microsoft\Windows\*' })
    foreach ($task in $custom) {
        $full     = $task.TaskPath + $task.TaskName
        $fileName = ($full.Trim('\') -replace '[\\/:*?"<>|]', '_') + '.xml'
        $xmlPath  = Join-Path $metaRoot ("tasks\" + $fileName)
        try {
            $xml = Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
            Set-Content -LiteralPath $xmlPath -Value $xml -Encoding utf8
            $taskLines.Add(("{0}`t{1}" -f $fileName, $full))
        }
        catch { Warn ('could not export task {0}: {1}' -f $full, $_.Exception.Message) }
    }
    Ok ('scheduled tasks captured: {0}' -f $custom.Count)
}
catch { Warn ('task enumeration failed: {0}' -f $_.Exception.Message) }
Set-Content -LiteralPath (Join-Path $metaRoot 'tasks\index.tsv') -Value $taskLines -Encoding utf8

# --- service start types -----------------------------------------------------
try {
    $services = Get-Service -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{
            Name      = $_.Name
            StartType = "$($_.StartType)"
            Status    = "$($_.Status)"
        }
    }
    $services | Export-Csv -LiteralPath (Join-Path $metaRoot 'services.csv') -NoTypeInformation -Encoding utf8
    Ok ('services captured: {0}' -f $services.Count)
}
catch { Warn ('service enumeration failed: {0}' -f $_.Exception.Message) }

# --- installed application inventory ---------------------------------------
# Fast: read the uninstall keys directly. Always regenerated.
try {
    $apps = @(
        Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                         'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
            Where-Object DisplayName |
            Select-Object DisplayName, DisplayVersion, Publisher, InstallLocation |
            Sort-Object DisplayName
    )
    $apps | Format-Table -AutoSize | Out-String -Width 200 |
        Set-Content -LiteralPath (Join-Path $metaRoot 'installed-apps.txt') -Encoding utf8
    Ok ('installed applications: {0}' -f $apps.Count)
}
catch { Warn ('application inventory failed: {0}' -f $_.Exception.Message) }

# ---------------------------------------------------------------------------
# Baseline - required for the system delta
# ---------------------------------------------------------------------------
$baseline = Read-Baseline
if ($baseline.Count -eq 0) {
    Warn 'No baseline manifest. Run scripts/baseline.ps1 BEFORE restore on the first run.'
    Warn 'Application delta will be skipped for this generation (profile is still saved).'
}

# ---------------------------------------------------------------------------
# Work pack - the user profile, captured verbatim
# ---------------------------------------------------------------------------
Log 'indexing user profile...'
$workFiles = @(Get-StateFiles -Roots $WORK_ROOTS -ExcludeRegex $EXCLUDE_REGEX)
Log ('  {0:N0} files under {1}' -f $workFiles.Count, ($WORK_ROOTS -join ', '))

# ---------------------------------------------------------------------------
# System pack - delta against the pristine image
# ---------------------------------------------------------------------------
$sysPaths = @()
$sysTotal = 0
$sysSame  = 0
if ($baseline.Count -gt 0) {
    Log 'computing application delta...'
    $delta = Get-DeltaPaths -Roots $SYS_ROOTS -Baseline $baseline -ExcludeRegex $EXCLUDE_REGEX
    $sysPaths = @($delta.Paths)
    $sysTotal = $delta.Total
    $sysSame  = $delta.Unchanged
    Log ('  {0:N0} changed / {1:N0} total  ({2:N0} unchanged skipped)' -f
        $sysPaths.Count, $sysTotal, $sysSame)
}

# ---------------------------------------------------------------------------
# Change signature - skip the upload entirely when nothing moved
# ---------------------------------------------------------------------------
function Get-TextHash([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        ([System.BitConverter]::ToString(
            $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '')
    }
    finally { $sha.Dispose() }
}

$workLines = ($workFiles | ForEach-Object { '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks }) -join "`n"
$sysLines  = ($sysPaths  | ForEach-Object {
        $f = Get-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue
        if ($f) { '{0}|{1}|{2}' -f $f.FullName, $f.Length, $f.LastWriteTimeUtc.Ticks }
    }) -join "`n"
$metaLines = (Get-ChildItem -LiteralPath $metaRoot -Recurse -File | ForEach-Object {
        '{0}|{1}|{2}' -f $_.FullName.Substring($metaRoot.Length), $_.Length, $_.LastWriteTimeUtc.Ticks
    }) -join "`n"

# Chain and endpoint are resolved BEFORE the signature check. They are kept out
# of the hash deliberately: a new run restores a byte-identical profile but
# still gets a fresh chain link and a fresh Tailscale address, and that must
# not force a pointless re-upload of several gigabytes.
$chain = if ($ChainOverride) {
    [int]$ChainOverride
}
elseif ($previous -and $previous.runId -eq $env:GITHUB_RUN_ID) {
    [int]$previous.chain
}
elseif ($previous) {
    [int]$previous.chain + 1
}
else { 1 }

$connection = $null
$tailscale = Join-Path ${env:ProgramFiles} 'Tailscale\tailscale.exe'
if (Test-Path -LiteralPath $tailscale) {
    try {
        $statusJson = & $tailscale status --json 2>$null
        if ($LASTEXITCODE -eq 0) {
            $self = ($statusJson | ConvertFrom-Json).Self
            $connection = [ordered]@{
                hostname     = $self.HostName
                dnsName      = ($self.DNSName -replace '\.$', '')
                tailscaleIp  = @($self.TailscaleIPs | Where-Object { $_ -notmatch ':' })[0]
                os           = $self.OS
            }
        }
    }
    catch { Warn ('could not read Tailscale status: {0}' -f $_.Exception.Message) }
}
$connectionJson = if ($connection) { $connection | ConvertTo-Json -Compress } else { '' }

$signature = Get-TextHash ("{0}`n{1}`n{2}" -f $workLines, $sysLines, $metaLines)

if (-not $Force -and $previous -and $previous.signature -eq $signature) {
    $survivors = @(Get-StateAssets -Pattern ('{0}-*' -f $previous.generation))
    if ($survivors.Count -gt 0) {
        $sw.Stop()

        $previousConnection = ''
        if ($previous.connection) {
            $previousConnection = ConvertTo-Json -InputObject $previous.connection -Compress
        }

        $sameRun = ("$($previous.runId)" -eq "$env:GITHUB_RUN_ID")
        $sameChain = ("$($previous.chain)" -eq "$chain")
        $sameConnection = ($previousConnection -eq $connectionJson)

        if ($sameRun -and $sameChain -and $sameConnection) {
            Ok ('no changes since generation {0} - upload skipped ({1:N0}s)' -f
                $previous.generation, $sw.Elapsed.TotalSeconds)
            exit 0
        }

        # The files are byte-identical, but the session metadata moved on: a
        # fresh run keeps the restored profile while getting a new chain link
        # and a new Tailscale address. Repoint the manifest without uploading
        # a single byte.
        foreach ($pair in @(
            @('chain', $chain),
            @('runId', $env:GITHUB_RUN_ID),
            @('runNumber', $env:GITHUB_RUN_NUMBER),
            @('capturedAt', (Get-Date).ToString('o')),
            @('reason', $Reason),
            @('connection', $connection)
        )) {
            if ($previous.PSObject.Properties[$pair[0]]) { $previous.($pair[0]) = $pair[1] }
            else { $previous | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] }
        }
        Set-StateManifest -Manifest $previous

        Ok ('content unchanged - manifest repointed (chain {0}, gen {1}, {2:N0}s)' -f
            $chain, $previous.generation, $sw.Elapsed.TotalSeconds)
        exit 0
    }
    Warn 'signature matched but the assets are gone - republishing.'
}

# ---------------------------------------------------------------------------
# Pack
# ---------------------------------------------------------------------------
$generation = New-GenerationId
$created    = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

if ($workFiles.Count -gt 0) {
    $listPath = Join-Path $CFG.BuildDir ("{0}-work.lst" -f $generation)
    Write-SevenZipList -ListPath $listPath -Paths ($workFiles | ForEach-Object FullName) -Base 'C:\'
    $files = New-StateArchive -ListPath $listPath `
        -OutputBase (Join-Path $CFG.BuildDir ("{0}-work.7z" -f $generation)) `
        -WorkingDir 'C:\'
    foreach ($f in $files) { $created.Add($f) }
}
else { Warn 'user profile is empty - nothing to pack' }

if ($sysPaths.Count -gt 0) {
    $listPath = Join-Path $CFG.BuildDir ("{0}-sys.lst" -f $generation)
    Write-SevenZipList -ListPath $listPath -Paths $sysPaths -Base 'C:\'
    $files = New-StateArchive -ListPath $listPath `
        -OutputBase (Join-Path $CFG.BuildDir ("{0}-sys.7z" -f $generation)) `
        -WorkingDir 'C:\'
    foreach ($f in $files) { $created.Add($f) }
}
else { Log 'no application delta to pack.' }

# Meta is always packed, even when tiny - it carries the registry.
$metaFiles = @(Get-ChildItem -LiteralPath $metaRoot -Recurse -File)
if ($metaFiles.Count -gt 0) {
    $listPath = Join-Path $CFG.BuildDir ("{0}-meta.lst" -f $generation)
    Write-SevenZipList -ListPath $listPath -Paths ($metaFiles | ForEach-Object FullName) -Base $metaRoot
    $files = New-StateArchive -ListPath $listPath `
        -OutputBase (Join-Path $CFG.BuildDir ("{0}-meta.7z" -f $generation)) `
        -WorkingDir $metaRoot
    foreach ($f in $files) { $created.Add($f) }
}

if ($created.Count -eq 0) { Die 'snapshot produced no archives at all' }

$totalBytes = ($created | Measure-Object Length -Sum).Sum
Log ('pack size: {0:N2} GB across {1} asset(s)' -f ($totalBytes / 1GB), $created.Count)

# Never push more than the machine can afford to lose track of.
if (($totalBytes / 1GB) -gt (Get-FreeSpaceGB) - 5) {
    Warn 'Not enough free disk to guarantee a clean next restore; continuing anyway.'
}

# ---------------------------------------------------------------------------
# Publish
# ---------------------------------------------------------------------------
Ensure-StateRelease

# Upload everything first, then prune. If we pruned first and the upload died,
# the previous generation would be gone too.
foreach ($file in $created) { Publish-StateAsset -Path $file.FullName }

# $chain and $connection were resolved above, before the signature comparison.

$manifest = [ordered]@{
    version     = 1
    generation  = $generation
    chain       = $chain
    runId       = $env:GITHUB_RUN_ID
    runNumber   = $env:GITHUB_RUN_NUMBER
    capturedAt  = (Get-Date).ToString('o')
    signature   = $signature
    reason      = $Reason
    computer    = $env:COMPUTERNAME
    counts      = [ordered]@{
        workFiles    = $workFiles.Count
        sysChanged   = $sysPaths.Count
        sysTotal     = $sysTotal
        sysUnchanged = $sysSame
        baselineSize = $baseline.Count
    }
    sizes       = [ordered]@{
        packedBytes = $totalBytes
        assets      = $created.Count
    }
    assets      = @($created | ForEach-Object Name)
    connection  = $connection
}

Set-StateManifest -Manifest $manifest
Prune-StateGenerations -CurrentGeneration $generation

$sw.Stop()
Ok ('snapshot {0} published in {1:N0}s' -f $generation, $sw.Elapsed.TotalSeconds)

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if ($env:GITHUB_STEP_SUMMARY) {
    $lines = @(
        '## Snapshot published',
        '',
        '| | |',
        '| --- | --- |',
        ('| generation | `{0}` |' -f $generation),
        ('| trigger | {0} |' -f $Reason),
        ('| chain | {0} |' -f $chain),
        ('| profile files | {0:N0} |' -f $workFiles.Count),
        ('| apps changed | {0:N0} of {1:N0} |' -f $sysPaths.Count, $sysTotal),
        ('| packed | {0:N2} GB in {1} asset(s) |' -f ($totalBytes / 1GB), $created.Count),
        ('| elapsed | {0:N0}s |' -f $sw.Elapsed.TotalSeconds),
        ''
    )
    if ($connection) {
        $lines += @(
            ('**RDP endpoint:** `{0}` (Tailscale host `{1}`)' -f $connection.tailscaleIp, $connection.hostname),
            ''
        )
    }
    $lines | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}
