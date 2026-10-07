#Requires -Version 7.0
<#
    baseline.ps1 - capture the pristine runner image as a reference manifest.

    MUST run before restore.ps1 / provisioning. If the baseline were taken
    after the machine was modified, your own state would be baked into it and
    the delta would silently stop capturing anything.

    .\baseline.ps1           build it only when none exists yet
    .\baseline.ps1 -Force    rebuild and republish (use after GitHub rolls a
                             new runner image, when app deltas look wrong)
#>
param(
    [switch]$Force,
    [switch]$LocalOnly
)

. (Join-Path $PSScriptRoot 'lib.ps1')

Step 'Runner baseline'

$existing = Read-Baseline
if ($existing.Count -gt 0 -and -not $Force) {
    Ok ('baseline already present: {0:N0} files. Nothing to do (use -Force to rebuild).' -f $existing.Count)
    exit 0
}

$map = New-Baseline
if ($map.Count -eq 0) { Die 'baseline is empty - refusing to publish it' }

if ($LocalOnly) {
    Write-ManifestFile -Path (Get-BaselinePath) -Map $map
    Ok ('written locally to {0}' -f (Get-BaselinePath))
    exit 0
}

Ensure-StateRelease
if (Publish-Baseline -Map $map -Force:$Force) {
    Ok ('baseline published to release {0}' -f $CFG.Tag)
}
