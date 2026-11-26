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
}
finally { Remove-Item -LiteralPath $out -Recurse -Force }

# A plan saved by another copy of the Lab Builder can point at that copy's (older) template folder.
foreach ($name in 'Get-ALFRolloutTemplateFiles','Get-ALFTemplateVersion','Get-ALFStaleTemplateFiles','Get-ALFFullFolderPath','Resolve-ALFRolloutFolders','Invoke-Rollout') {
    $fn=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)[0]
    . ([scriptblock]::Create($fn.Extent.Text))
}
function Set-ClusterIdentifier { $true }
function Update-HostSizingStatus { $true }
function Update-LabSizingStatus { $true }
function Test-Values { 0 }
function Save-Values { }
$ALFVersion='2.1.1'
$items=@([pscustomobject]@{Key='HostAvailableVcpus';Value='16';Type='';Label='SuperHost available vCPUs'})
$work=Join-Path ([IO.Path]::GetTempPath()) ('ALF-RolloutVersion-' + [guid]::NewGuid().ToString('N'))
$builder=Join-Path $work 'Builder'; $older=Join-Path $work 'Older'; $custom=Join-Path $work 'CustomRollout'
$null=New-Item -Path $builder,$older -ItemType Directory
try {
    Set-Content -LiteralPath (Join-Path $builder 'ALFGuestSizing.ps1') -Value "# Version: ALF Lab Builder 2.1.1`r`n`$minimum = {{HostAvailableVcpus}}" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $builder 'Notes.txt') -Value 'No version stamp' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $builder 'ALFLabBuilder.ps1') -Value '# Version: ALF Lab Builder 2.0.0' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $older 'ALFGuestSizing.ps1') -Value "# Version: ALF Lab Builder 2.1.0`r`n`$minimum = 20" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $older 'Notes.txt') -Value 'No version stamp' -Encoding UTF8

    $stale=@(Get-ALFStaleTemplateFiles $older $ALFVersion)
    Assert ($stale.Count -eq 1 -and $stale[0].Name -eq 'ALFGuestSizing.ps1' -and $stale[0].Version -eq '2.1.0') 'A template stamped with another release is reported with its version.'
    Assert (@(Get-ALFStaleTemplateFiles $builder $ALFVersion).Count -eq 0) 'Unstamped files and the Planning Console itself are not treated as another release.'

    $folders=Resolve-ALFRolloutFolders $older (Join-Path $older 'Rollout') $builder $ALFVersion
    Assert ($folders.TemplateFolder -eq $builder -and $folders.RolloutFolder -eq (Join-Path $builder 'Rollout') -and $folders.Note -match '2\.1\.0') 'A saved older template folder and its default rollout folder move to this Planning Console with a note.'
    $folders=Resolve-ALFRolloutFolders $older $custom $builder $ALFVersion
    Assert ($folders.TemplateFolder -eq $builder -and $folders.RolloutFolder -eq $custom) 'A custom rollout folder is kept when the older template folder is replaced.'
    $folders=Resolve-ALFRolloutFolders '' '' $builder $ALFVersion
    Assert ($folders.TemplateFolder -eq $builder -and $folders.RolloutFolder -eq (Join-Path $builder 'Rollout') -and -not $folders.Note) 'Empty folders default to this Planning Console without a note.'
    $folders=Resolve-ALFRolloutFolders $builder $custom $older $ALFVersion
    Assert ($folders.TemplateFolder -eq $builder -and $folders.RolloutFolder -eq $custom -and -not $folders.Note) 'A chosen template folder from the same release is kept.'

    $script:Log=@()
    $ui=[pscustomobject]@{ txtTemplates=[pscustomobject]@{Text=$older}; txtRollout=[pscustomobject]@{Text=$custom}; txtSizingSummary=[pscustomobject]@{Text=''} }
    Invoke-Rollout
    Assert (-not (Test-Path -LiteralPath $custom) -and ($script:Log -match 'Rollout blocked: 1 file\(s\) .* version 2\.1\.0.*Set the Template folder')) 'Rollout is blocked, writing nothing, when templates are from another release.'

    $script:Log=@()
    $ui.txtTemplates.Text=$builder
    Invoke-Rollout
    Assert ((Get-Content -LiteralPath (Join-Path $custom 'ALFGuestSizing.ps1') -Raw) -match '\$minimum = 16') 'Rollout from this release fills in values.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $custom 'ALFLabBuilder.ps1')) -and ($script:Log -match 'Notes\.txt has no version stamp')) 'Unstamped files still roll out with a warning; the Planning Console is not rolled out.'
}
finally { Remove-Item -LiteralPath $work -Recurse -Force }
Write-Output "PASS: $script:Passed launcher byte/rollout cases; no console launched."
