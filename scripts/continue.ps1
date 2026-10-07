#Requires -Version 7.0
<#
    continue.ps1 - decide whether the next 6-hour VM should start automatically.

    The 6-hour ceiling is GitHub's, not ours, so "unlimited" runtime is really
    an unbroken chain of runs. This script starts the next link, guarded so two
    runs can never race each other.

    Repository variables (Settings -> Secrets and variables -> Variables):

        VM_CONTINUE   set to false/0/no/off to stop the chain for good
        VM_MAX_CHAIN  safety ceiling per chain (default 9999)
#>
param(
    [string]$Workflow = 'vm-test.yml',
    [string]$Ref = 'main'
)

. (Join-Path $PSScriptRoot 'lib.ps1')

Step 'Auto-continue'

# ---------------------------------------------------------------- kill switch
$flag = ('{0}' -f $env:VM_CONTINUE).Trim().ToLowerInvariant()
if ($flag -in @('false', '0', 'no', 'off', 'never', 'stop')) {
    Log 'Auto-continue is OFF (repository variable VM_CONTINUE).'
    Log 'Set VM_CONTINUE back to true to resume the chain.'
    exit 0
}

# ------------------------------------------------------------ failure backstop
# A run that broke during setup should halt the chain instead of retrying the
# same broken configuration forever. Cancellation (the normal 6-hour timeout)
# and success both mean "carry on".
$conclusion = ('{0}' -f $env:RUN_CONCLUSION).Trim().ToLowerInvariant()
if ($conclusion -in @('failure', 'skipped', 'action_required')) {
    Log "Previous run concluded '$conclusion' - NOT chaining to avoid an infinite retry loop."
    Log 'Fix the problem, then start it again manually with workflow_dispatch.'
    exit 0
}

# --------------------------------------------------------------- chain ceiling
$ceiling = 9999
if ($env:VM_MAX_CHAIN -and [int]::TryParse($env:VM_MAX_CHAIN, [ref]$ceiling) -eq $false) {
    Warn "VM_MAX_CHAIN ('$env:VM_MAX_CHAIN') is not a number - falling back to 9999"
    $ceiling = 9999
}

$manifest = Get-StateManifest
$chain = if ($manifest -and $manifest.chain) { [int]$manifest.chain } else { 1 }

if ($chain -ge $ceiling) {
    Log "Chain ceiling reached ($chain >= $ceiling) - stopping. Raise VM_MAX_CHAIN to go further."
    exit 0
}
Log ("chain length so far: {0} (limit {1})" -f $chain, $ceiling)

# ------------------------------------------------------------- overlap dedup
# The inline trigger inside vm-test.yml and this workflow_run trigger can both
# fire for the same ending run. Only start a new VM when nothing else is
# already queued or running.
#
# Our own run is obviously 'in_progress' while this script executes, so it has
# to be excluded - otherwise the inline hand-over would always bail out.
$runsJson = & gh run list --repo $CFG.Repo --workflow $Workflow --limit 15 `
    --json databaseId,status,conclusion,createdAt,url 2>&1
if ($LASTEXITCODE -ne 0) {
    Warn ("could not list runs: {0}" -f ($runsJson -join ' '))
    exit 0
}

$busy = @($runsJson | ConvertFrom-Json | Where-Object {
    $_.status -in @('queued', 'in_progress', 'waiting', 'requested', 'pending') -and
    "$($_.databaseId)" -ne "$env:GITHUB_RUN_ID"
})
if ($busy.Count -gt 0) {
    Log ("run {0} is already {1} - not starting a duplicate." -f $busy[0].databaseId, $busy[0].status)
    exit 0
}

# --------------------------------------------------------------- fire the next
Log ("starting the next VM: gh workflow run {0} --ref {1}" -f $Workflow, $Ref)
$arguments = @('workflow', 'run', $Workflow, '--repo', $CFG.Repo, '--ref', $Ref)
$output = & gh @arguments 2>&1
if ($LASTEXITCODE -ne 0) {
    Err ("failed to trigger the next run: {0}" -f ($output -join "`n"))
    exit 1
}

Ok 'next VM queued'
if ($env:GITHUB_STEP_SUMMARY) {
    @(
        '## Auto-continue',
        '',
        'The next 6-hour VM has been queued automatically.',
        '',
        '**To stop the chain:** set repository variable `VM_CONTINUE` to `false`',
        '(Settings -> Secrets and variables -> Variables), or cancel the running workflow.',
        ''
    ) | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}
