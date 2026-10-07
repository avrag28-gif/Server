#Requires -Version 7.0
<#
    restore.ps1 - bring a fresh runner back to exactly where the last one left off.

    Order matters:
        1. files     the RDP user's profile (resolved dynamically: projects,
                     documents, app settings)
                     Program Files / ProgramData delta vs the baseline
        2. registry  HKLM keys, the RDP user's NTUSER.DAT hive, env vars
        3. tasks     custom scheduled tasks
        4. services  start-type changes
        5. ACLs      7-Zip drops NTFS ACLs, so ownership is re-applied last

    Every stage is independent: a failure in one is logged and the rest still
    run, because a half-restored VM is far better than none.
#>
param(
    [switch]$SkipFiles,
    [switch]$SkipSystem,
    [switch]$SkipMeta,
    [switch]$VerboseMeta
)

. (Join-Path $PSScriptRoot 'lib.ps1')

# Resolved once, before anything writes into it: on a machine where the profile
# folder got suffixed this is the difference between restoring the real profile
# and silently dropping every file into a directory Windows will never use.
$profileRoot = Resolve-ProfilePath

Step 'Restoring VM state'

$manifest = Get-StateManifest
if (-not $manifest -or -not $manifest.generation) {
    Log 'No previous state on the release - first run, nothing to restore.'
    if ($env:GITHUB_STEP_SUMMARY) {
        '## VM state`n`nFirst run: no previous state to restore.' |
            Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
    exit 0
}

$generation = [string]$manifest.generation
$chain = if ($manifest.chain) { [int]$manifest.chain } else { 1 }
Log ('generation {0}  (chain {1})' -f $generation, $chain)
if ($manifest.capturedAt) { Log ('captured    {0}' -f $manifest.capturedAt) }

if ($manifest.connection) {
    Log ('last RDP endpoint: {0}  (Tailscale host {1})' -f
        $manifest.connection.tailscaleIp, $manifest.connection.hostname)
}

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------
Step 'Downloading state packs'

$downloadDir = $CFG.DownloadDir
$null = Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

$patterns = @()
if (-not $SkipSystem) { $patterns += ('{0}-sys.7z*'   -f $generation) }
if (-not $SkipFiles)  { $patterns += ('{0}-work.7z*'  -f $generation) }
if (-not $SkipMeta)   { $patterns += ('{0}-meta.7z*'  -f $generation) }

if ($patterns.Count -gt 0) {
    $null = Request-StateAssets -Patterns $patterns -Destination $downloadDir
}

$assets = @(Get-ChildItem -LiteralPath $downloadDir -File -ErrorAction SilentlyContinue)
if ($assets.Count -eq 0) {
    Warn 'No state assets for this generation were found - starting from a clean image.'
    exit 0
}
Log ('downloaded {0} file(s), {1:N1} GB total' -f $assets.Count,
    (($assets | Measure-Object Length -Sum).Sum / 1GB))

# Rough headroom check: archives must unpack somewhere.
$packedGB = ($assets | Measure-Object Length -Sum).Sum / 1GB
$null = Assert-FreeSpace -RequiredGB ($packedGB * 2 + 3) -Why 'restore'

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------
if (-not $SkipFiles) {
    $work = @($assets | Where-Object { $_.Name -like ('{0}-work.7z*' -f $generation) })
    if ($work.Count -gt 0) {
        Step ('Restoring user profile  ({0})' -f $profileRoot)
        $first = ($work | Sort-Object Name | Select-Object -First 1).FullName
        Expand-StateArchive -Archive $first -Destination 'C:\'
        Ok 'profile files restored'
        # The ACL repair happens once, after the personal hive section below -
        # that is where the profile folder may also be created from scratch.
    }
    else { Warn 'no user-profile pack in this generation' }
}

if (-not $SkipSystem) {
    $sys = @($assets | Where-Object { $_.Name -like ('{0}-sys.7z*' -f $generation) })
    if ($sys.Count -gt 0) {
        Step 'Restoring installed applications  (Program Files, ProgramData)'
        $first = ($sys | Sort-Object Name | Select-Object -First 1).FullName
        Expand-StateArchive -Archive $first -Destination 'C:\'
        Ok 'application delta restored'
    }
    else { Warn 'no application pack in this generation' }
}

# ---------------------------------------------------------------------------
# Meta: registry / tasks / services / env
# ---------------------------------------------------------------------------
if ($SkipMeta) {
    Log 'Skipping registry, tasks, services and environment (-SkipMeta).'
    Repair-ProfileAcl
    exit 0
}

$metaArchive = @($assets | Where-Object { $_.Name -like ('{0}-meta.7z*' -f $generation) })
if ($metaArchive.Count -eq 0) {
    Warn 'no meta pack in this generation - registry and settings not restored'
    Repair-ProfileAcl
    exit 0
}

Step 'Restoring registry, tasks, services and environment'
$metaDir = Join-Path $CFG.StateDir 'restore-meta'
$null = Remove-Item -LiteralPath $metaDir -Recurse -Force -ErrorAction SilentlyContinue
Expand-StateArchive -Archive ($metaArchive | Select-Object -First 1).FullName -Destination $metaDir

# --- 1. machine-wide registry ------------------------------------------------
$regDir = Join-Path $metaDir 'registry'
if (Test-Path -LiteralPath $regDir) {
    foreach ($hive in (Get-ChildItem -LiteralPath $regDir -Filter '*.reg' -File)) {
        if ($hive.Name -eq 'user-hive.reg') { continue }   # handled below
        $output = & reg import $hive.FullName 2>&1
        if ($LASTEXITCODE -eq 0) { Ok ('imported {0}' -f $hive.Name) }
        else { Warn ('could not import {0}: {1}' -f $hive.Name, ($output -join ' ')) }
    }
}

# --- 2. the RDP user's personal hive (NTUSER.DAT) ----------------------------
$ntUser = Join-Path $profileRoot 'NTUSER.DAT'
$userReg   = Join-Path $regDir 'user-hive.reg'
$userBin   = Join-Path $regDir 'user-hive.bin'
$userKey   = Join-Path $regDir 'user-hive.key'

$hiveCaptured = (Test-Path -LiteralPath $userReg) -or (Test-Path -LiteralPath $userBin)

# NTUSER.DAT is held exclusively by the registry while that user is logged
# in - which is exactly when snapshots get taken - so 7z routinely cannot
# read it and the work pack arrives without it. The meta pack always has it,
# because `reg save` works on a loaded hive and its output is a registry hive
# in its own right. Put it in place before anything tries to load it,
# otherwise Windows mints a fresh empty profile at logon and every personal
# setting is quietly lost.
if ($hiveCaptured -and -not (Test-Path -LiteralPath $ntUser)) {
    if (Test-Path -LiteralPath $userBin) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ntUser) | Out-Null
        try {
            Copy-Item -LiteralPath $userBin -Destination $ntUser -Force -ErrorAction Stop
            Ok ('created {0} from the saved hive (profile folder was empty)' -f $ntUser)
        }
        catch { Warn ("could not materialise NTUSER.DAT: {0}" -f $_.Exception.Message) }
    }
    else {
        Warn 'personal hive was captured as .reg only and NTUSER.DAT is absent - a base hive is required to reload it.'
    }
}

if ((Test-Path -LiteralPath $ntUser) -and $hiveCaptured) {
    $loadKey = 'VMState'
    if (Test-Path $userKey) { $loadKey = (Get-Content -LiteralPath $userKey -Raw).Trim() }

    $output = & reg load "HKU\$loadKey" $ntUser 2>&1
    if ($LASTEXITCODE -eq 0) {
        if (Test-Path $userBin) {
            $out2 = & reg restore "HKU\$loadKey" $userBin 2>&1
            if ($LASTEXITCODE -eq 0) { Ok 'restored rdpuser hive from binary snapshot' }
            else {
                Warn ("binary hive restore failed ({0}) - falling back to .reg" -f ($out2 -join ' '))
                if (Test-Path $userReg) {
                    $out3 = & reg import $userReg 2>&1
                    if ($LASTEXITCODE -eq 0) { Ok 'restored rdpuser hive from .reg' }
                    else { Warn ('user hive .reg import failed: {0}' -f ($out3 -join ' ')) }
                }
            }
        }
        elseif (Test-Path $userReg) {
            $out3 = & reg import $userReg 2>&1
            if ($LASTEXITCODE -eq 0) { Ok 'restored rdpuser personal settings (NTUSER.DAT)' }
            else { Warn ('user hive .reg import failed: {0}' -f ($out3 -join ' ')) }
        }
        $null = & reg unload "HKU\$loadKey" 2>&1
    }
    else {
        Warn ('could not load NTUSER.DAT: {0}' -f ($output -join ' '))
    }
}
else { Log 'No personal hive captured yet (rdpuser has probably never logged in).' }

# Runs unconditionally whenever the folder exists: 7-Zip carries no NTFS ACLs,
# and the hive step above may have created the folder moments ago.
Repair-ProfileAcl

# --- 3. environment variables ------------------------------------------------
$machineEnv = Join-Path $regDir 'machine-env.reg'
if (Test-Path $machineEnv) {
    $null = & reg import $machineEnv 2>&1
    if ($LASTEXITCODE -eq 0) {
        Ok 'machine environment restored'
        # Make PATH visible to the remaining steps of this run.
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('Path', 'User')
    }
}

# --- 4. scheduled tasks ------------------------------------------------------
$taskIndex = Join-Path $metaDir 'tasks\index.tsv'
if (Test-Path -LiteralPath $taskIndex) {
    $restored = 0
    $skipped  = 0
    foreach ($line in (Get-Content -LiteralPath $taskIndex)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t", 2
        if ($parts.Count -ne 2) { continue }
        $file = Join-Path $metaDir ('tasks\' + $parts[0])
        $full = $parts[1]
        if (-not (Test-Path -LiteralPath $file)) { $skipped++; continue }

        $taskPath = Split-Path -Parent $full
        $taskName = Split-Path -Leaf   $full
        if ([string]::IsNullOrEmpty($taskPath)) { $taskPath = '\' }

        try {
            $xml = Get-Content -LiteralPath $file -Raw
            $null = Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Xml $xml -Force -ErrorAction Stop
            $restored++
        }
        catch {
            $skipped++
            if ($VerboseMeta) { Warn ('task {0}: {1}' -f $full, $_.Exception.Message) }
        }
    }
    Ok ('scheduled tasks restored: {0} ok, {1} skipped' -f $restored, $skipped)
}
else { Log 'No scheduled tasks captured.' }

# --- 5. service start types --------------------------------------------------
$servicesCsv = Join-Path $metaDir 'services.csv'
if (Test-Path -LiteralPath $servicesCsv) {
    $changed = 0
    $absent  = 0
    foreach ($row in (Import-Csv -LiteralPath $servicesCsv)) {
        $target = switch ($row.StartType) {
            'Automatic'            { 'Automatic' }
            'AutomaticDelayedStart' { 'Automatic' }
            'Manual'               { 'Manual' }
            'Disabled'             { 'Disabled' }
            default                { $null }   # Boot / System / Invalid: leave alone
        }
        if (-not $target) { continue }

        $service = Get-Service -Name $row.Name -ErrorAction SilentlyContinue
        if (-not $service) { $absent++; continue }
        if ("$($service.StartType)" -eq $target) { continue }

        try {
            Set-Service -Name $row.Name -StartupType $target -ErrorAction Stop
            $changed++
        }
        catch { if ($VerboseMeta) { Warn ("service {0}: {1}" -f $row.Name, $_.Exception.Message) } }
    }
    Ok ('service start types adjusted: {0} changed, {1} not present' -f $changed, $absent)
}
else { Log 'No service state captured.' }

# --- 6. package manifests (reference / fallback reinstall) -------------------
$installed = @(Get-ChildItem -LiteralPath $metaDir -Filter 'installed-*' -File -ErrorAction SilentlyContinue)
if ($installed.Count -gt 0) {
    foreach ($file in $installed) { Log ('package manifest: {0}' -f $file.Name) }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Log ''
Ok 'restore complete'

if ($env:GITHUB_STEP_SUMMARY) {
    $lines = @(
        '## VM state restored',
        '',
        ('| field | value |'),
        ('| --- | --- |'),
        ('| generation | `{0}` |' -f $generation),
        ('| chain | {0} |' -f $chain),
        ('| captured | {0} |' -f $manifest.capturedAt),
        ('| assets | {0} |' -f $assets.Count),
        ('| packed size | {0:N2} GB |' -f $packedGB),
        ''
    )
    if ($manifest.connection) {
        $lines += @(
            ('**Connect via Tailscale:** `{0}`  (RDP user `rdpuser`)' -f $manifest.connection.tailscaleIp),
            ''
        )
    }
    $lines | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}
