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
. (Join-Path $root 'ALFGuestStatus.ps1')
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
foreach ($name in 'numBack','num','title','desc','script','run','open','status','statusDetail') { $card[$name] = $row.FindName($name) }
$StateText = @{ Done='Done'; Running='Running'; NotDone='Not started'; Failed='Failed'; Attention='Needs attention' }
foreach ($state in 'Done','Running','NotDone','Failed','Attention') {
    Set-GuestCardState $card (New-ALFGuestCheck $state 'Detected status')
    Assert ($card.status.Text -eq $StateText[$state] -and $card.status.Foreground.Color -eq $Colors[$state].Color) 'Use the matching Host Console status label/color.'
    $expected = if ($state -eq 'Done') { $Colors.Done } else { $Colors.Running }
    Assert ($card.numBack.Background.Color -eq $expected.Color) 'Only detected completion turns the numbered indicator green.'
}
foreach ($name in 'why','learn','check','confirm') { Assert (-not $row.FindName($name)) 'Remove verbose learning/check blocks and confirmation controls.' }
Set-GuestCardState $card (New-ALFGuestCheck 'NotDone' '')
Assert ([string]::IsNullOrEmpty($card.statusDetail.Text)) 'Clearing a script problem removes its stale detail.'
$card.num.Text = '2'
$card.title.Text = 'Configure the admin station'
$card.desc.Text = 'Set networking, install management tools and join the domain. Restart afterward.'
$card.script.Text = '08adm.Admin-Configure.ps1'
$card.status.Text = 'Needs attention'
$card.statusDetail.Text = 'Restart required to finish the computer name change.'
$row.SetValue([Windows.Documents.TextElement]::FontFamilyProperty, [Windows.Media.FontFamily]::new('Segoe UI'))
$row.SetValue([Windows.Documents.TextElement]::FontSizeProperty, [double]15)
foreach ($width in 960, 1236) {
    $row.Measure([Windows.Size]::new($width, [double]::PositiveInfinity))
    $row.Arrange([Windows.Rect]::new(0, 0, $width, $row.DesiredSize.Height))
    $row.UpdateLayout()
    Assert ($row.DesiredSize.Height -le 170) 'Compact cards fit within 170 pixels at both supported widths.'
    foreach ($name in 'numBack','title','status','run','open') {
        $bounds = $card[$name].TransformToAncestor($row).TransformBounds([Windows.Rect]::new($card[$name].RenderSize))
        Assert ($bounds.Left -ge 0 -and $bounds.Right -le $width -and $bounds.Width -gt 0) 'Numbered cards, status and action buttons stay inside the available row width.'
    }
}
$tasksFn = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-GuestTasks' }, $true)[0]
. ([scriptblock]::Create($tasksFn.Extent.Text))
foreach ($case in @(@{Role='DC'; Count=4}, @{Role='Admin'; Count=1}, @{Role='Node'; Count=2})) {
    $tasks = @(Get-GuestTasks $case.Role)
    Assert ($tasks.Count -eq $case.Count -and -not @($tasks | Where-Object { -not $_.Script }).Count) 'Keep only runnable setup cards in each role.'
}
Assert ((Get-GuestTasks Node | Where-Object Id -eq 'Configure').Destructive) 'Retain the dedicated destructive node cleanup warning.'
$source = $ast.Extent.Text
Assert ($source -notmatch 'ConfirmedAt|Check and confirm|Confirm-GuestStep') 'No manual confirmation is used as completion proof.'
Assert ($source -match 'ProcessStarted' -and $source -match 'StartTime.ToUniversalTime') 'Restore running steps only with both PID and start-time identity.'
Assert ($source.Contains('if ($Role -eq ''Node'') { $ui.btnDisplay.Visibility')) 'Display option is hidden on nodes.'

$deliveryAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root '05.Host-CopyScriptsToVM.ps1'), [ref]$tokens, [ref]$errors)
$fn = $deliveryAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Copy-ALFGuestConsoleShortcut' }, $true)[0]
. ([scriptblock]::Create($fn.Extent.Text))
$call = $deliveryAst.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Copy-ALFGuestConsoleShortcut' }, $true)[0]
Assert ($call.Parent.Parent.Parent -is [Management.Automation.Language.ForEachStatementAst] -and $call.Extent.Text -match 'GuestLaunchers\[\$VMName\]') 'Shortcut delivery applies to every prepared DC/admin VM using its own delivered launcher, not only the DC.'
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
    $script:CopyArgs = @{ Name=$Name; Source=$SourcePath; Destination=$DestinationPath; Force=[bool]$Force; CreateFullPath=[bool]$CreateFullPath; FileSource=$FileSource }
}
try {
    foreach ($case in @(
        @{ VM='ContosoDC1'; Launcher='Launch-ALFDCConsole.cmd'; Shortcut='ALF DC Console.lnk' },
        @{ VM='ContosoADM1'; Launcher='Launch-ALFAdminConsole.cmd'; Shortcut='ALF Admin Console.lnk' }
    )) {
        $script:FailCopy = $false; $script:CleanedPath = ''; $script:ShortcutMock.Saved = $false
        Copy-ALFGuestConsoleShortcut $case.VM 'C:\ISO' $case.Launcher
        Assert ($script:ShortcutMock.Saved -and $script:ShortcutMock.TargetPath -eq "C:\ISO\$($case.Launcher)" -and $script:ShortcutMock.WorkingDirectory -eq 'C:\ISO') 'Each shortcut opens its own guest launcher from the guest scripts folder.'
        Assert ($script:CopyArgs.Name -eq $case.VM -and $script:CopyArgs.Destination -eq "C:\Users\Administrator\Desktop\$($case.Shortcut)" -and $script:CopyArgs.Source -eq $script:TempPath) 'Deliver the shortcut only to that VM local Administrator desktop, not the host or public desktop.'
        Assert ($script:CopyArgs.Force -and $script:CopyArgs.CreateFullPath -and $script:CopyArgs.FileSource -eq 'Host') 'Repeat delivery refreshes the fixed guest shortcut and can create the desktop path.'
        Assert ($script:CleanedPath -eq $script:TempPath) 'Remove the temporary host shortcut after delivery.'
        $script:FailCopy = $true; $script:CleanedPath = ''
        $warning = @(Copy-ALFGuestConsoleShortcut $case.VM 'C:\ISO' $case.Launcher 3>&1)
        Assert ($warning -match 'Mock copy failed' -and $warning -match [regex]::Escape($case.Launcher) -and $script:CleanedPath -eq $script:TempPath) 'Shortcut delivery failure names the fallback launcher, warns without interrupting script delivery and cleans its temporary file.'
    }
} finally {
    foreach ($name in 'New-Object','Set-Content','Test-Path','Remove-Item','Copy-VMFile') { Microsoft.PowerShell.Management\Remove-Item -LiteralPath "function:$name" }
}
Write-Output "PASS: $script:Passed guest theme/state/shortcut checks; no configuration run."
