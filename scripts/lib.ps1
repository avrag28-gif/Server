#Requires -Version 7.0
<#
    lib.ps1 - shared configuration and helpers for VM state persistence.

    Dot-source it from every other script in this folder:

        . (Join-Path $PSScriptRoot 'lib.ps1')

    Storage model
    -------------
    Everything is kept as a GitHub Release on this repository:

        tag  : vm-state
        base : baseline.7z            <- manifest of the pristine runner image
               manifest.json           <- pointer to the newest generation
               gen-<id>-work.7z.001..  <- full copy of C:\Users\rdpuser
               gen-<id>-sys.7z.001..   <- delta of Program Files / ProgramData
               gen-<id>-meta.7z        <- registry, tasks, services, env, package lists

    GitHub caps a single release asset at 2 GiB (1000 assets per release, no
    total size or bandwidth limit), so archives are written with 1900 MiB
    volumes.
#>

$ErrorActionPreference  = 'Stop'
$ProgressPreference     = 'SilentlyContinue'
$ConfirmPreference      = 'None'

# ===========================================================================
# Configuration - the only block you normally need to touch.
# ===========================================================================

$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }

$CFG = [ordered]@{
    # Release that holds the state. Override with the STATE_REPO / STATE_TAG
    # environment variables if you ever move storage to another repository.
    Repo            = if ($env:STATE_REPO) { $env:STATE_REPO } else { 'avrag28-gif/Server' }
    Tag             = if ($env:STATE_TAG)  { $env:STATE_TAG  } else { 'vm-state' }

    # 1900 MiB leaves headroom below GitHub's hard 2 GiB per-asset limit.
    VolMiB          = 1900
    # 7z compression level (0-9). 3 is a good balance for a snapshot that
    # re-runs every 20 minutes; raise it if your packs are large and slow.
    Level           = 3
    # How many complete generations to keep on the release (1 = current,
    # extras are only there in case the newest one got corrupted mid-upload).
    KeepGens        = 2

    StateDir        = Join-Path $tempRoot 'vmstate'
    BuildDir        = Join-Path $tempRoot 'vmstate\build'
    DownloadDir     = Join-Path $tempRoot 'vmstate\dl'

    BaselineAsset   = 'baseline.7z'
    ManifestAsset   = 'manifest.json'
    EmptyMarker     = '__state_empty__'
}

# The RDP user's profile. Captured verbatim on every snapshot - this is where
# your projects, documents, downloads and application settings live.
$WORK_ROOTS = @('C:\Users\rdpuser')

# Machine-wide application and configuration roots. The runner image already
# ships ~120 GB here, so these are captured as a DELTA against the baseline
# manifest: only files you actually added or changed get stored.
$SYS_ROOTS = @(
    'C:\Program Files'
    'C:\Program Files (x86)'
    'C:\ProgramData'
)

# Regenerable junk that is deliberately NOT captured. Anything that does not
# match this list is kept - edit freely if a project needs one of these back.
$EXCLUDE_REGEX = '(?i)(' + (@(
    '\\AppData\\Local\\Temp\\'
    '\\AppData\\Local\\Microsoft\\Windows\\INetCache\\'
    '\\AppData\\Local\\Microsoft\\Windows\\Explorer\\(thumb|icon)cache[^\\]*\.db$'
    '\\AppData\\Local\\Packages\\[^\\]+\\TempState\\'
    '\\__pycache__\\'
    '\\\.cache\\'
    '\\node_modules\\\.cache\\'
    '\\\.pytest_cache\\'
    '\\Thumbs\.db$'
) -join '|') + ')'

# ===========================================================================
# Logging
# ===========================================================================

function Log   ([string]$Message) { Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) }
function Step  ([string]$Message) { Write-Host ''; Write-Host "===== $Message =====" -ForegroundColor Cyan }
function Ok    ([string]$Message) { Write-Host "  [ok]   $Message" -ForegroundColor Green }
function Warn  ([string]$Message) { Write-Host "  [warn] $Message" -ForegroundColor Yellow }
function Err   ([string]$Message) { Write-Host "  [FAIL] $Message" -ForegroundColor Red }
function Die   ([string]$Message) { Err $Message; throw $Message }

# ===========================================================================
# Disk
# ===========================================================================

function Get-FreeSpaceGB {
    param([string]$Drive)
    # Default to the volume the state packs are written to, which is the one
    # that actually has to fit them - on a GitHub runner that is D:, not C:.
    if (-not $Drive) {
        $root = $null
        try { $root = [System.IO.Path]::GetPathRoot($CFG.StateDir) } catch { $root = $null }
        if ($root) { $Drive = $root.TrimEnd('\') } else { $Drive = 'C' }
    }
    try { [System.IO.DriveInfo]::new($Drive).AvailableFreeSpace / 1GB }
    catch { 0 }
}

function Assert-FreeSpace {
    param([double]$RequiredGB, [string]$Why)
    $free = Get-FreeSpaceGB
    if ($free -lt $RequiredGB) {
        Warn ('Low disk for {0}: need {1:N1} GB, have {2:N1} GB' -f $Why, $RequiredGB, $free)
        return $false
    }
    Ok ('Disk for {0}: {1:N1} GB free' -f $Why, $free)
    return $true
}

# ===========================================================================
# File enumeration
# ===========================================================================

$script:ENUM_OPTIONS = [System.IO.EnumerationOptions]@{
    IgnoreInaccessible       = $true
    RecurseSubdirectories    = $true
    ReturnSpecialDirectories = $false
    # Skip reparse points so junctions/symlinks neither loop the walk nor get
    # captured twice.
    AttributesToSkip         = [System.IO.FileAttributes]::ReparsePoint
    MatchCasing              = [System.IO.MatchCasing]::CaseInsensitive
    MatchType                = [System.IO.MatchType]::Simple
}

function Get-StateFiles {
    <#
        Yields [System.IO.FileSystemInfo] for every file under $Roots,
        honouring $EXCLUDE_REGEX. Missing roots are reported, not fatal.
    #>
    param(
        [Parameter(Mandatory)] [string[]]$Roots,
        [string]$ExcludeRegex
    )
    foreach ($root in $Roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        if (-not (Test-Path -LiteralPath $root)) {
            Log ("  missing root: {0}" -f $root)
            continue
        }
        $dir = [System.IO.DirectoryInfo]::new($root)
        foreach ($file in $dir.EnumerateFiles('*', $script:ENUM_OPTIONS)) {
            if ($ExcludeRegex -and $file.FullName -match $ExcludeRegex) { continue }
            $file
        }
    }
}

function Get-ManifestFromRoots {
    <#
        Builds "fullPath -> length|mtimeTicks" for a set of roots.
    #>
    param(
        [Parameter(Mandatory)] [string[]]$Roots,
        [string]$ExcludeRegex = $EXCLUDE_REGEX
    )
    $map = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in (Get-StateFiles -Roots $Roots -ExcludeRegex $ExcludeRegex)) {
        $map[$file.FullName] = '{0}|{1}' -f $file.Length, $file.LastWriteTimeUtc.Ticks
    }
    return $map
}

function Get-DeltaPaths {
    <#
        Files under $Roots that are new or differ from the baseline manifest.
        Returns the full paths plus the number of unchanged files skipped.
    #>
    param(
        [Parameter(Mandatory)] [string[]]$Roots,
        [Parameter(Mandatory)] $Baseline,
        [string]$ExcludeRegex = $EXCLUDE_REGEX
    )
    $delta  = [System.Collections.Generic.List[string]]::new()
    $same   = 0
    $total  = 0
    foreach ($file in (Get-StateFiles -Roots $Roots -ExcludeRegex $ExcludeRegex)) {
        $total++
        $sig = '{0}|{1}' -f $file.Length, $file.LastWriteTimeUtc.Ticks
        if ($Baseline -and $Baseline.ContainsKey($file.FullName) -and $Baseline[$file.FullName] -eq $sig) {
            $same++
            continue
        }
        $delta.Add($file.FullName)
    }
    [pscustomobject]@{ Paths = $delta; Total = $total; Unchanged = $same }
}

# ===========================================================================
# Manifest files (plain "path<TAB>length|mtime" lines)
# ===========================================================================

function Write-ManifestFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Map)
    $dir = Split-Path -Parent $Path
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $writer = [System.IO.StreamWriter]::new($Path, $false, $utf8)
    try {
        foreach ($entry in $Map.GetEnumerator()) {
            $writer.WriteLine(("{0}`t{1}" -f $entry.Key, $entry.Value))
        }
    }
    finally { $writer.Dispose() }
}

function Read-ManifestFile {
    param([Parameter(Mandatory)][string]$Path)
    $map = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        $i = $line.LastIndexOf("`t")
        if ($i -lt 1) { continue }
        $map[$line.Substring(0, $i)] = $line.Substring($i + 1)
    }
    return $map
}

# ===========================================================================
# 7-Zip
# ===========================================================================

function Get-SevenZip {
    $found = Get-Command '7z' -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    foreach ($candidate in @(
        (Join-Path ${env:ProgramFiles} '7-Zip\7z.exe'),
        (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe')
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    Die '7-Zip was not found on this runner.'
}

function Write-SevenZipList {
    <#
        Writes a 7-Zip list file. Every line is quoted so paths containing
        spaces stay intact, and a BOM is emitted so 7-Zip decodes UTF-8.
        Paths are rewritten relative to $Base so the archive extracts cleanly.
    #>
    param(
        [Parameter(Mandatory)][string]$ListPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Paths,
        [string]$Base
    )
    $dir = Split-Path -Parent $ListPath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $prefix = if ($Base) { $Base.TrimEnd('\') + '\' } else { $null }
    $utf8Bom = [System.Text.UTF8Encoding]::new($true)
    $writer = [System.IO.StreamWriter]::new($ListPath, $false, $utf8Bom)
    try {
        foreach ($path in $Paths) {
            $relative = $path
            if ($prefix -and $path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $relative = $path.Substring($prefix.Length)
            }
            $writer.WriteLine('"' + $relative + '"')
        }
    }
    finally { $writer.Dispose() }
}

function New-StateArchive {
    <#
        Packs the files listed in $ListPath into $OutputBase. Volumes are
        produced automatically: name.7z.001, name.7z.002, ...
        Returns the created files (empty when there was nothing to pack).
    #>
    param(
        [Parameter(Mandatory)][string]$ListPath,
        [Parameter(Mandatory)][string]$OutputBase,
        [Parameter(Mandatory)][string]$WorkingDir,
        [string]$WorkingDirRoot,
        [int]$Level = $CFG.Level,
        [int]$VolumeMiB = $CFG.VolMiB
    )
    $paths = @()
    if (Test-Path -LiteralPath $ListPath) {
        $paths = @([System.IO.File]::ReadAllLines($ListPath) |
            ForEach-Object { $_.Trim('"') } | Where-Object { $_ })
    }

    if ($paths.Count -eq 0) {
        Warn ('nothing to pack for {0}' -f (Split-Path -Leaf $OutputBase))
        return @()
    }

    # A zero-entry archive is invalid in 7z, so when a root is empty we fall
    # back to a single marker file rather than failing the whole snapshot.
    $sevenZip = Get-SevenZip
    Push-Location $WorkingDir
    try {
        $arguments = @(
            'a', '-t7z', "-mx=$Level", "-v${VolumeMiB}m",
            '-y', '-spd', '-bso0', '-bsp0',
            $OutputBase, "@$ListPath"
        )
        & $sevenZip @arguments
        $code = $LASTEXITCODE
    }
    finally { Pop-Location }

    if ($code -ge 2) { Die ("7z pack failed with exit code {0}" -f $code) }
    if ($code -eq 1) { Warn '7z reported warnings while packing (some files may have been locked).' }

    $created = @(Get-ChildItem -LiteralPath (Split-Path -Parent $OutputBase) -Filter `
        ((Split-Path -Leaf $OutputBase) + '.*') -File -ErrorAction SilentlyContinue)
    Log ('  packed {0} file(s) -> {1}' -f $paths.Count, (Split-Path -Leaf $OutputBase))
    return $created
}

function Expand-StateArchive {
    <#
        Extracts a .7z (or its .001 volume) into $Destination.
        Exit codes: 0 = ok, 1 = warnings (locked files), >= 2 = fatal.
    #>
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Archive)) { Die "archive not found: $Archive" }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    $sevenZip = Get-SevenZip
    # Note: no -snld here (or in the pack path). 7-Zip 26.03 accepts the switch
    # for "a" but rejects it for "x" with exit code 7, and nothing needs it.
    $arguments = @('x', "-o$Destination", '-y', '-bso0', '-bsp0', $Archive)
    & $sevenZip @arguments
    $code = $LASTEXITCODE

    if ($code -ge 2) { Die ("7z extract failed with exit code {0} for {1}" -f $code, (Split-Path -Leaf $Archive)) }
    if ($code -eq 1) {
        Warn ('7z warnings while extracting {0} - some files were locked and kept their old content.' -f
            (Split-Path -Leaf $Archive))
    }
}

# ===========================================================================
# GitHub Releases (via gh)
# ===========================================================================

function Invoke-Gh {
    param([Parameter(Mandatory, ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $output = & gh @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        Die ("gh {0}`n{1}" -f ($Arguments -join ' '), ($output -join "`n"))
    }
    $output
}

function Test-StateRelease {
    $null -ne (& gh release view $CFG.Tag --repo $CFG.Repo --json tagName 2>$null |
        ConvertFrom-Json -ErrorAction SilentlyContinue)
}

function Ensure-StateRelease {
    if (Test-StateRelease) { return }
    Log ("creating state release '{0}' on {1}" -f $CFG.Tag, $CFG.Repo)
    $arguments = @(
        'release', 'create', $CFG.Tag, '--repo', $CFG.Repo,
        '--title', 'VM persistent state',
        '--notes', 'Auto-managed snapshots of the Windows VM. Managed by scripts/snapshot.ps1 - do not edit by hand.'
    )
    $output = & gh @arguments 2>&1
    if ($LASTEXITCODE -ne 0 -and ($output -join ' ') -notmatch 'already exists') {
        Die ("unable to create release {0}: {1}" -f $CFG.Tag, ($output -join "`n"))
    }
    Ok ("release '{0}' ready" -f $CFG.Tag)
}

function Get-StateAssets {
    param([string]$Pattern = '*')
    if (-not (Test-StateRelease)) { return @() }
    $json = & gh release view $CFG.Tag --repo $CFG.Repo --json assets 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    $release = $json | ConvertFrom-Json
    @($release.assets | Where-Object { $_.name -like $Pattern })
}

function Publish-StateAsset {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { Die "cannot upload missing file: $Path" }
    $name = Split-Path -Leaf $Path
    $arguments = @('release', 'upload', $CFG.Tag, '--repo', $CFG.Repo, '--clobber', $Path)
    $output = & gh @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { Die ("upload of {0} failed: {1}" -f $name, ($output -join "`n")) }
    Log ("  uploaded {0}" -f $name)
}

function Request-StateAssets {
    <#
        Downloads assets matching each pattern. Returns $true when every
        pattern matched at least one asset.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Patterns,
        [Parameter(Mandatory)][string]$Destination
    )
    if (-not (Test-StateRelease)) { return $false }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    $allMatched = $true
    foreach ($pattern in $Patterns) {
        $arguments = @(
            'release', 'download', $CFG.Tag, '--repo', $CFG.Repo,
            '--pattern', $pattern, '--dir', $Destination, '--clobber'
        )
        $output = & gh @arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            $allMatched = $false
            if (($output -join ' ') -notmatch 'no assets|not found|no matches') {
                Log ("  download of '{0}' returned: {1}" -f $pattern, ($output -join ' '))
            }
        }
    }
    return $allMatched
}

function Remove-StateAsset {
    param([Parameter(Mandatory)][string]$Name)
    $arguments = @('release', 'delete-asset', $CFG.Tag, $Name, '--repo', $CFG.Repo, '-y')
    $output = & gh @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { Warn ("could not delete asset {0}: {1}" -f $Name, ($output -join ' ')) }
}

function Prune-StateGenerations {
    <#
        Keeps only the newest $CFG.KeepGens generations, deleting older assets
        so the release never grows without bound.
    #>
    param([Parameter(Mandatory)][string]$CurrentGeneration)

    $assets = @(Get-StateAssets -Pattern 'gen-*')
    if ($assets.Count -eq 0) { return }

    $groups = @($assets | Group-Object { ($_.name -split '-work|-sys|-meta')[0] } |
        Sort-Object Name -Descending)

    if ($groups.Count -le $CFG.KeepGens) { return }

    foreach ($stale in ($groups | Select-Object -Skip $CFG.KeepGens)) {
        if ($stale.Name -eq $CurrentGeneration) { continue }
        foreach ($asset in $stale.Group) {
            Log ("  pruning {0}" -f $asset.name)
            Remove-StateAsset -Name $asset.name
        }
    }
}

# ===========================================================================
# manifest.json - pointer to the newest state generation
# ===========================================================================

function Get-StateManifest {
    if (-not (Test-StateRelease)) { return $null }
    New-Item -ItemType Directory -Force -Path $CFG.StateDir | Out-Null
    $target = Join-Path $CFG.StateDir $CFG.ManifestAsset

    $arguments = @(
        'release', 'download', $CFG.Tag, '--repo', $CFG.Repo,
        '--pattern', $CFG.ManifestAsset, '--dir', $CFG.StateDir, '--clobber'
    )
    $null = & gh @arguments 2>&1
    if (-not (Test-Path -LiteralPath $target)) { return $null }

    try { Get-Content -LiteralPath $target -Raw -Encoding utf8 | ConvertFrom-Json }
    catch { Warn 'manifest.json could not be parsed - treating state as empty.'; $null }
}

function Set-StateManifest {
    param([Parameter(Mandatory)]$Manifest)
    New-Item -ItemType Directory -Force -Path $CFG.StateDir | Out-Null
    $target = Join-Path $CFG.StateDir $CFG.ManifestAsset
    $Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $target -Encoding utf8
    Publish-StateAsset -Path $target
}

function New-GenerationId {
    Get-Date -Format 'yyyyMMdd-HHmmss'
}

# ===========================================================================
# Small shared helpers
# ===========================================================================

function Get-LocalUserSid {
    param([Parameter(Mandatory)][string]$Name)
    try {
        ([System.Security.Principal.NTAccount]$Name).Translate(
            [System.Security.Principal.SecurityIdentifier]).Value
    }
    catch { $null }
}

function Ensure-RdpUser {
    <#
        Creates the RDP account if it is not there yet. Called before restore
        so the profile has somewhere to land.
    #>
    if ([string]::IsNullOrWhiteSpace($env:RDP_PASSWORD)) {
        Die 'Missing GitHub Actions secret: RDP_PASSWORD'
    }
    $secure = ConvertTo-SecureString $env:RDP_PASSWORD -AsPlainText -Force

    $existing = Get-LocalUser -Name 'rdpuser' -ErrorAction SilentlyContinue
    if ($existing) {
        Set-LocalUser -Name 'rdpuser' -Password $secure
    }
    else {
        New-LocalUser -Name 'rdpuser' -Password $secure -AccountNeverExpires -PasswordNeverExpires
    }
    $null = Add-LocalGroupMember -Group 'Administrators' -Member 'rdpuser' -ErrorAction SilentlyContinue
    $null = Add-LocalGroupMember -Group 'Remote Desktop Users' -Member 'rdpuser' -ErrorAction SilentlyContinue
    Ok 'rdpuser account ready'
}

# ===========================================================================
# Baseline - the manifest of a pristine runner image
#
# The image already contains ~120 GB (Visual Studio, Android SDK, ...). Rather
# than storing all of it, we snapshot its file list once and afterwards only
# keep whatever differs from it. Without this, every snapshot would be tens of
# gigabytes and would never finish uploading.
# ===========================================================================

function Get-BaselinePath {
    Join-Path $CFG.StateDir 'baseline.txt'
}

function New-Baseline {
    <#
        Captures the current state of $SYS_ROOTS as the reference image.
        Call this BEFORE restoring state or provisioning the machine.
    #>
    [OutputType([hashtable])]
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Log 'building runner baseline (this is a one-off per image)...'
    $map = Get-ManifestFromRoots -Roots $SYS_ROOTS -ExcludeRegex $EXCLUDE_REGEX
    $stopwatch.Stop()
    Ok ('baseline: {0:N0} files indexed in {1:N0}s' -f $map.Count, $stopwatch.Elapsed.TotalSeconds)
    $map
}

function Read-Baseline {
    <#
        Returns the baseline manifest, downloading it from the release when
        needed. Returns an empty map when no baseline exists yet.
    #>
    [OutputType([hashtable])]
    $local = Get-BaselinePath
    if (-not (Test-Path -LiteralPath $local)) {
        $null = Request-StateAssets -Patterns @($CFG.BaselineAsset) -Destination $CFG.StateDir
        $archive = Join-Path $CFG.StateDir $CFG.BaselineAsset
        if (Test-Path -LiteralPath $archive) {
            # The manifest is stored compressed only to keep the asset small;
            # extract next to it and rename to .txt.
            Expand-StateArchive -Archive $archive -Destination $CFG.StateDir
            $extracted = Get-ChildItem -LiteralPath $CFG.StateDir -Filter 'baseline*' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -ne '.7z' } | Select-Object -First 1
            if ($extracted) { Move-Item -LiteralPath $extracted.FullName -Destination $local -Force }
        }
    }
    if (-not (Test-Path -LiteralPath $local)) { return @{} }
    Read-ManifestFile -Path $local
}

function Publish-Baseline {
    param(
        [Parameter(Mandatory)][hashtable]$Map,
        [switch]$Force
    )
    if (-not $Force -and (Read-Baseline).Count -gt 0) {
        Ok 'baseline already published - keeping it'
        return $false
    }

    $local = Get-BaselinePath
    Write-ManifestFile -Path $local -Map $Map

    $outputBase = Join-Path $CFG.BuildDir $CFG.BaselineAsset
    New-Item -ItemType Directory -Force -Path $CFG.BuildDir | Out-Null
    Remove-Item -LiteralPath $outputBase, ($outputBase + '.001') -Force -ErrorAction SilentlyContinue

    # Pack from inside the state directory using the bare file name. Passing an
    # absolute path would make 7-Zip store the whole directory tree, and
    # Read-Baseline would then never find the extracted manifest.
    $sevenZip = Get-SevenZip
    Push-Location $CFG.StateDir
    try {
        $arguments = @('a', '-t7z', '-mx=3', '-y', '-bso0', '-bsp0', $outputBase, 'baseline.txt')
        & $sevenZip @arguments
        $code = $LASTEXITCODE
    }
    finally { Pop-Location }
    if ($code -ge 2) { Die 'failed to compress the baseline manifest' }

    Ensure-StateRelease
    Publish-StateAsset -Path $outputBase
    return $true
}

function Repair-ProfileAcl {
    <#
        7-Zip does not carry NTFS ACLs, so the restored profile would be owned
        by nobody. Re-grant the RDP user full control over their own folder.
    #>
    $profile = 'C:\Users\rdpuser'
    if (-not (Test-Path -LiteralPath $profile)) { return }
    $null = & icacls $profile /grant 'rdpuser:(OI)(CI)F' /T /C /Q 2>&1
    if ($LASTEXITCODE -eq 0) { Ok 'profile ACLs repaired' }
    else { Warn 'icacls returned a non-zero exit code while fixing profile ACLs' }
}
