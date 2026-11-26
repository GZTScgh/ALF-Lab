# Version: ALF Lab Builder 2.1.1
# Runs one guest configuration step. A receipt records execution, not configuration verification.
param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [string]$TargetSolutionVersionOverride = ''
)

$ErrorActionPreference = 'Stop'
$exitCode = 0
try {
    $global:LASTEXITCODE = 0
    $stepParameters = @{}
    if ($TargetSolutionVersionOverride) {
        if ([IO.Path]::GetFileName($ScriptPath) -ine '14.Node-ArcRegister.ps1') { throw 'A target-version override is only valid for the Arc registration step.' }
        $stepParameters.TargetSolutionVersionOverride = $TargetSolutionVersionOverride
    }
    & $ScriptPath @stepParameters
    if ($LASTEXITCODE -ne 0) { throw "A native command returned exit code $LASTEXITCODE." }
}
catch {
    $exitCode = 1
    Write-Host "Step failed: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    #A reboot or terminated process may prevent this receipt from being written.
    [ordered]@{ ExitCode = $exitCode; Finished = (Get-Date).ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding UTF8
}
Write-Host 'The guest console refreshes configuration status automatically. Reopen it after any restart.' -ForegroundColor Cyan
Read-Host 'Press Enter to close this step window' | Out-Null
exit $exitCode
