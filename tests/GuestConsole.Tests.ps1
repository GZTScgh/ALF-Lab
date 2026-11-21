# Run in an approved STA PowerShell session. UI/state and mocked delivery only; no guest configuration is launched.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$script:Passed = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:Passed++
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert $threw $Message
}
$root = Split-Path $PSScriptRoot -Parent
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'ALFGuestConsole.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join '; ') }
$paint = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-GuestCardState' }, $true)[0]
. ([scriptblock]::Create($paint.Extent.Text))
$palette = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$Colors' }, $true)[0]
$Brush = New-Object Windows.Media.BrushConverter
$Colors = & ([scriptblock]::Create($palette.Right.Extent.Text))
$rowText = ($tokens | Where-Object { $_.Kind -eq 'HereStringLiteral' -and $_.Value.StartsWith('<Border ') } | Select-Object -First 1).Value
$row = [Windows.Markup.XamlReader]::Parse($rowText)
$card = @{}
foreach ($name in 'numBack','num','title','why','learn','check','script','run','confirm','status','statusDetail') { $card[$name] = $row.FindName($name) }
foreach ($case in @(
    @{ Status='Student confirmed'; State='Done' },
    @{ Status='Running'; State='Running' },
    @{ Status='Not started'; State='NotDone' },
    @{ Status='Last run failed'; State='Failed' },
    @{ Status='Script returned - check result'; State='Attention' },
    @{ Status='Interrupted / restarted - check result'; State='Attention' },
    @{ Status='Receipt unreadable - check result'; State='Attention' }
)) {
    Set-GuestCardState $card $case.Status ''
    Assert ($card.status.Text -eq $case.Status -and $card.status.Foreground.Color -eq $Colors[$case.State].Color) 'Retain the result meaning and use its matching Host Console status color.'
    $expected = if ($case.State -eq 'Done') { $Colors.Done } else { $Colors.Running }
    Assert ($card.numBack.Background.Color -eq $expected.Color) 'Only student confirmation turns a numbered indicator green; script exit alone must not.'
}
Set-GuestCardState $card 'Student confirmed' 'Missing script: 12.Node-Configure.ps1'
Assert ($card.status.Text -eq 'Needs attention' -and $card.statusDetail.Text -match '12.Node-Configure' -and $card.status.Foreground.Color -eq $Colors.Failed.Color -and $card.numBack.Background.Color -eq $Colors.Running.Color) 'A current script problem must not appear green because an earlier result was confirmed.'
Set-GuestCardState $card 'Not started' ''
Assert ([string]::IsNullOrEmpty($card.statusDetail.Text)) 'Clearing a script problem removes its stale detail.'
$card.num.Text = '2'
$card.title.Text = 'Configure networking, tools, name and domain membership'
$card.learn.Text = 'Read each stage in its PowerShell window; restart when offered, then reopen this console.'
$card.check.Text = 'CHECK AFTERWARD: Verify the planned name, IP address, DNS, domain membership and tools.'
$row.FontFamily = 'Segoe UI'; $row.FontSize = 15
foreach ($width in 960, 1240) {
    $row.Measure([Windows.Size]::new($width, [double]::PositiveInfinity))
    $row.Arrange([Windows.Rect]::new(0, 0, $width, $row.DesiredSize.Height))
    $row.UpdateLayout()
    foreach ($name in 'numBack','title','status','run','confirm') {
        $bounds = $card[$name].TransformToAncestor($row).TransformBounds([Windows.Rect]::new($card[$name].RenderSize))
        Assert ($bounds.Left -ge 0 -and $bounds.Right -le $width -and $bounds.Width -gt 0) 'Numbered cards, status and action buttons stay inside the available row width.'
    }
}
$version = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$ALFVersion' }, $true)[0]
$ALFVersion = & ([scriptblock]::Create($version.Right.Extent.Text))
$guard = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if ($saved.Role -ne $Role') }, $true)[0]
$checkState = [scriptblock]::Create($guard.Extent.Text)
foreach ($Role in 'DC','Admin','Node') {
    foreach ($savedVersion in '2.0.7', '2.0.8', '2.0.9', '2.0.10', '2.0.11', '2.0.12', '2.0.13', $ALFVersion) {
        $saved = [pscustomobject]@{ Role=$Role; Version=$savedVersion }
        & $checkState
        Assert $true 'Accept the same role and compatible saved progress.'
    }
}
$Role = 'Node'
$saved = [pscustomobject]@{ Role='DC'; Version='2.0.7' }
Assert-Throws { & $checkState } 'Do not reuse another role''s confirmations.'
$saved = [pscustomobject]@{ Role='Node'; Version='2.0.6' }
Assert-Throws { & $checkState } 'Do not guess compatibility with earlier workflow releases.'
$saved.Version = '9.0.0'
Assert-Throws { & $checkState } 'Do not accept a future state schema.'

$deliveryAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root '05.Host-CopyScriptsToVM.ps1'), [ref]$tokens, [ref]$errors)
$fn = $deliveryAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Copy-ALFDCConsoleShortcut' }, $true)[0]
. ([scriptblock]::Create($fn.Extent.Text))
$script:ShortcutMock = [pscustomobject]@{ TargetPath=''; WorkingDirectory=''; Description=''; IconLocation=''; Saved=$false }
$script:ShortcutMock | Add-Member -MemberType ScriptMethod -Name Save -Value { $this.Saved = $true }
$script:ShellMock = [pscustomobject]@{}
$script:ShellMock | Add-Member -MemberType ScriptMethod -Name CreateShortcut -Value { param($path) $script:TempPath=$path; return $script:ShortcutMock }
function New-Object { param($ComObject) return $script:ShellMock }
function Set-Content { param($LiteralPath, $Stream, $Value, $ErrorAction) $script:MarkedPath=$LiteralPath }
function Test-Path { param($LiteralPath) return ($LiteralPath -eq $script:TempPath) }
function Remove-Item { param($LiteralPath, [switch]$Force) $script:CleanedPath=$LiteralPath }
function Copy-VMFile {
    param($Name, $SourcePath, $DestinationPath, [switch]$CreateFullPath, $FileSource, [switch]$Force, $ErrorAction)
    if ($script:FailCopy) { throw 'Mock copy failed' }
    $script:CopyArgs = @{ Name=$Name; Source=$SourcePath; Destination=$DestinationPath }
}
try {
    Copy-ALFDCConsoleShortcut 'ContosoDC1' 'C:\ISO'
    Assert ($script:ShortcutMock.Saved -and $script:ShortcutMock.TargetPath -eq 'C:\ISO\Launch-ALFDCConsole.cmd' -and $script:ShortcutMock.WorkingDirectory -eq 'C:\ISO') 'The shortcut opens the guest launcher directly from its scripts folder.'
    Assert ($script:CopyArgs.Name -eq 'ContosoDC1' -and $script:CopyArgs.Destination -eq 'C:\Users\Administrator\Desktop\ALF DC Console.lnk') 'Deliver only to the DC local Administrator desktop, not the host or public desktop.'
    Assert ($script:CleanedPath -eq $script:TempPath) 'Remove the temporary host shortcut after delivery.'
    $script:FailCopy = $true; $script:CleanedPath = ''
    $warning = @(Copy-ALFDCConsoleShortcut 'ContosoDC1' 'C:\ISO' 3>&1)
    Assert ($warning -match 'Mock copy failed' -and $script:CleanedPath -eq $script:TempPath) 'Shortcut delivery failure warns without interrupting script delivery and still cleans its temporary file.'
} finally {
    foreach ($name in 'New-Object','Set-Content','Test-Path','Remove-Item','Copy-VMFile') { Microsoft.PowerShell.Management\Remove-Item -LiteralPath "function:$name" }
}
Write-Output "PASS: $script:Passed guest theme/state/shortcut checks; no configuration run."
