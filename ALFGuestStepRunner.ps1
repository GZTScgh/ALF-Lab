# Version: ALF Lab Builder 2.0.14
# Runs one guest configuration step. A receipt records execution, not configuration verification.
param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [Parameter(Mandatory = $true)][string]$ResultPath
)

$ErrorActionPreference = 'Stop'
$exitCode = 0
try {
    $global:LASTEXITCODE = 0
    & $ScriptPath
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
Write-Host 'Return to the guest console and check the result before confirming this step.' -ForegroundColor Cyan
Read-Host 'Press Enter to close this step window' | Out-Null
exit $exitCode
