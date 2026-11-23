# Run normally in an approved PowerShell session. Rollout writes temporary data only; no console is launched.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$script:Passed=0
function Assert($Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:Passed++
}
$rolloutFolder=Join-Path $root 'Rollout'
$launchers=@(Get-ChildItem -LiteralPath $root -File -Filter '*.cmd')
Assert ($launchers.Count -ge 5) 'The five template launchers must be present.'
# Rollout\ is local-only (gitignored); check its generated launchers too when it exists.
if (Test-Path -LiteralPath $rolloutFolder) { $launchers+=@(Get-ChildItem -LiteralPath $rolloutFolder -File -Filter '*.cmd') }
foreach ($file in $launchers) {
    $bytes=[IO.File]::ReadAllBytes($file.FullName)
    Assert ([Text.Encoding]::ASCII.GetString($bytes).StartsWith('@echo off') -and -not @($bytes | Where-Object { $_ -gt 127 }).Count) "Launcher must start at @echo off without a BOM: $($file.Name)"
}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'ALFLabBuilder.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors.Message -join '; ') }
$rollout=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Rollout'},$true)[0]
$guard=$rollout.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.Contains('contains non-ASCII text')},$true)[0]
$encoding=$rollout.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$encoding'},$true)[0]
$write=$rollout.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-Content' -and $n.Extent.Text.Contains('-Encoding $encoding')},$true)[0]
if (-not $guard -or -not $encoding -or -not $write) { throw 'Rollout must select batch-safe encoding and reject lossy CMD conversion.' }
$writer=[scriptblock]::Create(($guard.Extent.Text,$encoding.Extent.Text,$write.Extent.Text) -join "`n")
$out=Join-Path ([IO.Path]::GetTempPath()) ('ALF-LauncherEncoding-' + [guid]::NewGuid().ToString('N'))
$null=New-Item -Path $out -ItemType Directory
$script:Log=@()
function Write-Log([string]$Text) { $script:Log += $Text }
try {
    $f=[pscustomobject]@{Name='fixture.cmd';Extension='.cmd'}
    $new="@echo off`r`necho ALF_ENCODING_OK`r`n"
    & $writer
    $bytes=[IO.File]::ReadAllBytes((Join-Path $out $f.Name))
    Assert ($bytes[0] -eq 0x40 -and [Text.Encoding]::ASCII.GetString($bytes) -ceq $new) 'Future CMD rollout preserves exact ASCII bytes without a BOM.'
    $f=[pscustomobject]@{Name='fixture.ps1';Extension='.ps1'}
    $new='# ' + [char]0x03A9
    & $writer
    Assert ((Get-Content -LiteralPath (Join-Path $out $f.Name) -Raw) -ceq $new) 'PowerShell rollout retains Unicode rather than converting everything to ASCII.'
    $f=[pscustomobject]@{Name='unsupported.cmd';Extension='.cmd'}
    $new='@echo off' + [char]0x03A9
    & $writer
    Assert (-not (Test-Path -LiteralPath (Join-Path $out $f.Name)) -and $script:Log[-1] -match 'Rollout failed') 'Non-ASCII CMD text fails visibly without writing a corrupted launcher.'
    Write-Output "PASS: $script:Passed launcher byte/rollout cases; no console launched."
}
finally { Remove-Item -LiteralPath $out -Recurse -Force }
