#Requires -Version 7.0
<#
    smoke-test.ps1 - local roundtrip test for the persistence scripts.
    Not part of the workflow; run it on your own machine to sanity check
    lib.ps1 before pushing changes to the VM.
#>
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib.ps1')

$failures = 0
function Assert([bool]$Condition, [string]$Label) {
    if ($Condition) { Write-Host "  [pass] $Label" -ForegroundColor Green }
    else            { Write-Host "  [FAIL] $Label" -ForegroundColor Red; $script:failures++ }
}

$scratch = Join-Path $env:LOCALAPPDATA ("vmstate-test-" + (Get-Random))
# Deliberately NOT under AppData\Local\Temp: $EXCLUDE_REGEX filters that whole
# tree out, and a fixture living there would be excluded along with it.
try {
    Step 'Tooling'
    $sevenZip = Get-SevenZip
    Ok "7-Zip: $sevenZip"
    Assert ([bool]$sevenZip) '7-Zip located'

    # ---------------------------------------------------------------------
    Step 'Fixture: profile-like tree'
    $root = Join-Path $scratch 'C-Drive'
    # Deliberately awkward: spaces, unicode, long path, hidden/system file.
    $paths = @(
        'Users\rdpuser\Documents\My Project\read me.txt'
        'Users\rdpuser\Documents\café naïve\данные.txt'
        'Users\rdpuser\Downloads\deep\nested\folder\file.bin'
        'Users\rdpuser\NTUSER.DAT'
        'Users\rdpuser\AppData\Local\Temp\should-be-excluded.tmp'
        'Program Files\Some App\bin\app.exe'
        'Program Files (x86)\Other App\config with spaces.json'
    )
    foreach ($rel in $paths) {
        $full = Join-Path $root $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
        Set-Content -LiteralPath $full -Value ("content of " + $rel) -Encoding utf8
    }
    [System.IO.File]::SetAttributes(
        (Join-Path $root 'Users\rdpuser\NTUSER.DAT'),
        [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System)
    Assert ((Get-ChildItem -LiteralPath $root -Recurse -File -Force).Count -eq $paths.Count) 'fixture created (7 files)'

    # ---------------------------------------------------------------------
    Step 'Get-StateFiles / Get-ManifestFromRoots'
    # The script works against the real C:\; here we point it at the fixture
    # by temporarily overriding the root variables.
    $WORK_ROOTS = @((Join-Path $root 'Users\rdpuser'))
    $SYS_ROOTS  = @((Join-Path $root 'Program Files'), (Join-Path $root 'Program Files (x86)'))
    $EXCLUDE_REGEX_SAVE = $EXCLUDE_REGEX

    $workFiles = @(Get-StateFiles -Roots $WORK_ROOTS -ExcludeRegex $EXCLUDE_REGEX)
    # NTUSER.DAT is hidden+system, AppData\Local\Temp must be excluded.
    Assert ($workFiles.Count -eq 4) "profile files indexed (got $($workFiles.Count), want 4 incl. hidden NTUSER.DAT)"
    Assert (-not ($workFiles | Where-Object { $_.FullName -match '\\Temp\\' })) 'Temp excluded'

    $map = Get-ManifestFromRoots -Roots $WORK_ROOTS -ExcludeRegex $EXCLUDE_REGEX
    Assert ($map.Count -eq 4) "manifest built ($($map.Count) entries)"
    $sampleValue = $null
    if ($map.Count -gt 0) { $sampleValue = @($map.Values)[0] }
    Assert ([bool]($sampleValue -match '^\d+\|\d+$')) "manifest signature format is length|mtime (got '$sampleValue')"

    # ---------------------------------------------------------------------
    Step 'Baseline delta'
    $baseline = Get-ManifestFromRoots -Roots $SYS_ROOTS -ExcludeRegex $EXCLUDE_REGEX
    Assert ($baseline.Count -eq 2) "sys baseline has 2 files (got $($baseline.Count))"

    # Nothing changed yet -> delta must be empty.
    $delta = Get-DeltaPaths -Roots $SYS_ROOTS -Baseline $baseline -ExcludeRegex $EXCLUDE_REGEX
    Assert ($delta.Paths.Count -eq 0) "unchanged tree yields empty delta (got $($delta.Paths.Count))"
    Assert ($delta.Unchanged -eq 2)   "unchanged count = 2 (got $($delta.Unchanged))"

    # Modify one file and add another -> exactly two entries in the delta.
    Add-Content -LiteralPath (Join-Path $root 'Program Files\Some App\bin\app.exe') -Value 'patched'
    Start-Sleep -Milliseconds 1100
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'Program Files\New App') | Out-Null
    Set-Content  -LiteralPath (Join-Path $root 'Program Files\New App\new.dll') -Value 'brand new' -Encoding utf8

    $delta = Get-DeltaPaths -Roots $SYS_ROOTS -Baseline $baseline -ExcludeRegex $EXCLUDE_REGEX
    Assert ($delta.Paths.Count -eq 2) "delta picks up modify + add (got $($delta.Paths.Count), want 2)"
    Assert (($delta.Paths | Where-Object { $_ -like '*New App*' }).Count -eq 1) 'new file present in delta'
    Assert ($delta.Unchanged -eq 1) "untouched file still counted unchanged (got $($delta.Unchanged))"

    # ---------------------------------------------------------------------
    Step '7z list file + archive roundtrip'
    $build = Join-Path $scratch 'build'
    New-Item -ItemType Directory -Force -Path $build | Out-Null

    $deltaPaths = @($delta.Paths)
    $listPath = Join-Path $build 'test-work.lst'
    # Base is the fixture drive root, so entries become Users\..., Program Files\...
    Write-SevenZipList -ListPath $listPath -Paths $deltaPaths -Base ($root + '\')

    $lines = [System.IO.File]::ReadAllLines($listPath)
    Assert ($lines.Count -eq $deltaPaths.Count) "list file line count ($($lines.Count))"
    $spaced = @($lines | Where-Object { $_ -like '*Some App*' })
    Assert ($spaced.Count -eq 1 -and $spaced[0] -eq '"Program Files\Some App\bin\app.exe"') `
        'relative path with spaces, correctly quoted'
    # ReadAllText auto-detects (and strips) the BOM, so check raw bytes.
    $listBytes = [System.IO.File]::ReadAllBytes($listPath)
    $hasBom = $listBytes.Length -ge 3 -and
              $listBytes[0] -eq 0xEF -and $listBytes[1] -eq 0xBB -and $listBytes[2] -eq 0xBF
    Assert $hasBom 'list file has a UTF-8 BOM (so 7-Zip decodes UTF-8)'

    $outputBase = Join-Path $build 'gen-test.7z'
    $created = New-StateArchive -ListPath $listPath -OutputBase $outputBase -WorkingDir $root -Level 1 -VolumeMiB 1
    Assert ($created.Count -ge 1) "archive created ($($created.Count) volume(s))"

    # ---------------------------------------------------------------------
    Step 'Extract and compare'
    $out = Join-Path $scratch 'restored'
    Expand-StateArchive -Archive $created[0].FullName -Destination $out

    Assert (Test-Path -LiteralPath (Join-Path $out 'Program Files\Some App\bin\app.exe')) `
        'restored: Program Files\Some App\bin\app.exe'
    Assert (Test-Path -LiteralPath (Join-Path $out 'Program Files\New App\new.dll')) `
        'restored: the newly added file'

    # The whole point of the baseline: untouched files must NOT be re-packed.
    Assert (-not (Test-Path -LiteralPath (Join-Path $out 'Program Files (x86)\Other App\config with spaces.json'))) `
        'unchanged file correctly excluded from the delta'

    $restoredApp = Join-Path $out 'Program Files\Some App\bin\app.exe'
    $originalApp = Join-Path $root  'Program Files\Some App\bin\app.exe'
    Assert ((Get-Content -LiteralPath $restoredApp -Raw) -eq (Get-Content -LiteralPath $originalApp -Raw)) `
        'restored content matches byte-for-byte (spaces in path survived)'

    # ---------------------------------------------------------------------
    Step 'Work pack roundtrip (unicode, hidden files, deep nesting)'
    $workList = Join-Path $build 'work.lst'
    Write-SevenZipList -ListPath $workList -Paths ($workFiles | ForEach-Object FullName) -Base ($root + '\')
    $workCreated = New-StateArchive -ListPath $workList -OutputBase (Join-Path $build 'work.7z') `
        -WorkingDir $root -Level 1 -VolumeMiB 1900
    Assert ($workCreated.Count -ge 1) 'work pack created'

    $profileOut = Join-Path $scratch 'restored-profile'
    Expand-StateArchive -Archive (@($workCreated)[0].FullName) -Destination $profileOut

    Assert (Test-Path -LiteralPath (Join-Path $profileOut 'Users\rdpuser\Documents\My Project\read me.txt')) `
        'spaced directory restored'
    Assert (Test-Path -LiteralPath (Join-Path $profileOut 'Users\rdpuser\Documents\café naïve\данные.txt')) `
        'unicode path restored intact'
    Assert (Test-Path -LiteralPath (Join-Path $profileOut 'Users\rdpuser\Downloads\deep\nested\folder\file.bin')) `
        'deeply nested path restored'
    Assert (Test-Path -LiteralPath (Join-Path $profileOut 'Users\rdpuser\NTUSER.DAT')) `
        'hidden+system NTUSER.DAT captured (needed for the personal registry hive)'
    Assert ((Get-Item -LiteralPath (Join-Path $profileOut 'Users\rdpuser\NTUSER.DAT') -Force).Attributes -band `
        [System.IO.FileAttributes]::Hidden) 'NTUSER.DAT kept its Hidden attribute'
    Assert (-not (Test-Path -LiteralPath (Join-Path $profileOut 'Users\rdpuser\AppData\Local\Temp\should-be-excluded.tmp'))) `
        'excluded Temp file not captured'

    # ---------------------------------------------------------------------
    Step 'Manifest file roundtrip'
    $mf = Join-Path $scratch 'manifest.txt'
    Write-ManifestFile -Path $mf -Map $map
    $back = Read-ManifestFile -Path $mf
    Assert ($back.Count -eq $map.Count) "manifest survives write/read ($($back.Count))"
    $allEqual = $true
    foreach ($k in $map.Keys) { if ($back[$k] -ne $map[$k]) { $allEqual = $false; break } }
    Assert $allEqual 'manifest values identical after roundtrip'
    # Case-insensitive lookup matters: Windows paths come back with varying case.
    $sampleKey = ($map.Keys | Select-Object -First 1)
    Assert ($back[$sampleKey.ToUpperInvariant()] -ne $null) 'manifest lookup is case-insensitive'

    # ---------------------------------------------------------------------
    Step 'Generation pruning logic'
    $fakeAssets = @(
        @{ name = 'gen-20260101-000000-work.7z.001' },
        @{ name = 'gen-20260101-000000-sys.7z.001' },
        @{ name = 'gen-20260102-000000-work.7z.001' },
        @{ name = 'gen-20260103-000000-work.7z.001' },
        @{ name = 'gen-20260103-000000-meta.7z' },
        @{ name = 'baseline.7z' },
        @{ name = 'manifest.json' }
    ) | ForEach-Object { [pscustomobject]$_ }
    $groups = @($fakeAssets | Where-Object { $_.name -like 'gen-*' } |
        Group-Object { ($_.name -split '-work|-sys|-meta')[0] } | Sort-Object Name -Descending)
    Assert ($groups.Count -eq 3) "3 generations grouped (got $($groups.Count))"
    $keep = @($groups | Select-Object -Skip $CFG.KeepGens)
    Assert ($keep.Count -eq 1) "KeepGens=$($CFG.KeepGens) leaves 1 generation to prune (got $($keep.Count))"
    Assert ($keep[0].Name -eq 'gen-20260101-000000') 'oldest generation is the one selected for pruning'

    # ---------------------------------------------------------------------
    Step 'Volume size stays under GitHub 2GiB per-asset cap'
    $volBytes = $CFG.VolMiB * 1MB
    Assert ($volBytes -lt 2GB) "volume $($CFG.VolMiB) MiB < 2 GiB"
    Assert ($volBytes -ge 1GB) 'volume is not wastefully small'
}
finally {
    $null = Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures -eq 0) { Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green; exit 0 }
Write-Host "$failures CHECK(S) FAILED" -ForegroundColor Red; exit 1
