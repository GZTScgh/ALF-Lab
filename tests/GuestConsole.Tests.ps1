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

$detailsText = ($tokens | Where-Object { $_.Kind -eq 'HereStringLiteral' -and $_.Value.StartsWith('<Grid ') } | Select-Object -First 1).Value
$details = [Windows.Markup.XamlReader]::Parse($detailsText)
$ui = @{ txtArcValues=$details.FindName('txtArcValues'); txtTimeStatus=$details.FindName('txtTimeStatus'); txtTargetVersionHelp=$details.FindName('txtTargetVersionHelp') }
Assert ($ui.txtArcValues.IsReadOnly -and $ui.txtTimeStatus.IsReadOnly) 'Arc values and time status are selectable but cannot edit the plan or time settings.'
$targetBox = $details.FindName('txtTargetVersion')
Assert ($targetBox.Parent.Children[0].Text -match '^Target version \(next Arc run\)') 'Name the node override as the target version for the next Arc run.'
foreach ($help in $ui.txtTargetVersionHelp.Text, $targetBox.ToolTip.Text) {
    Assert ($help -match '12\.YYMM|Major\.YYMM' -and $help -match '\b12\.2610\.1004\.50\b' -and $help -match 'Azure Local release information') 'Show the version naming convention with a real example and where to copy a newer release.'
}
$refresh = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Refresh-GuestNodeDetails' }, $true)[0]
. ([scriptblock]::Create($refresh.Extent.Text))
$script:DetailLogs = [Collections.Generic.List[string]]::new()
$script:ArcValuesError = ''; $script:TimeStatusError = ''
function Write-GuestLog([string]$Text) { $script:DetailLogs.Add($Text) }
function Get-ALFGuestArcSettingsText { param($Folder) return 'Prepared Arc values' }
function Get-ALFGuestTimeStatus {
    if ($script:TimeFails) { throw 'Windows Time is stopped' }
    return 'Source: DCFixture'
}
$script:TimeFails = $true
Refresh-GuestNodeDetails
Refresh-GuestNodeDetails
Assert ($ui.txtArcValues.Text -eq 'Prepared Arc values' -and $ui.txtTimeStatus.Text -match 'Windows Time is stopped') 'Time-query failure remains visible without hiding Arc settings.'
Assert ($script:DetailLogs.Count -eq 1 -and $ui.txtTimeStatus.Foreground.Color -eq $Colors.Attention.Color) 'Repeated refresh logs a persistent detail failure only once and highlights it.'
$script:TimeFails = $false
Refresh-GuestNodeDetails
Assert ($ui.txtTimeStatus.Text -eq 'Source: DCFixture' -and $script:TimeStatusError -eq '') 'A recovered query replaces its stale error on refresh.'
$ui.txtArcValues.Text = "Machine:         NodeFixture`r`nTenant ID:       11111111-1111-1111-1111-111111111111`r`nSubscription ID: 22222222-2222-2222-2222-222222222222`r`nResource group:  LabFixtureRG`r`nRegion:          southcentralus`r`nTarget version:  (Choose when the script runs)"
$ui.txtTimeStatus.Text = "Leap Indicator: 0(no warning)`r`nStratum: 3`r`nPrecision: -23`r`nRoot Delay: 0.001s`r`nRoot Dispersion: 0.002s`r`nReferenceId: 0x0A2C000A`r`nLast Successful Sync Time: 11/21/2026 9:00:00 PM`r`nSource: DCFixture`r`nPoll Interval: 10 (1024s)"
foreach ($width in 960, 1236) {
    $details.Measure([Windows.Size]::new($width, [double]::PositiveInfinity))
    $details.Arrange([Windows.Rect]::new(0, 0, $width, $details.DesiredSize.Height))
    $details.UpdateLayout()
    Assert ($details.DesiredSize.Height -le 250) 'Side-by-side registration and time details fit the space below compact Node cards.'
    foreach ($box in $ui.Values) {
        $bounds = $box.TransformToAncestor($details).TransformBounds([Windows.Rect]::new($box.RenderSize))
        Assert ($bounds.Left -ge 0 -and $bounds.Right -le $width -and $bounds.Width -gt 0) 'Copyable values and time output remain inside the available width.'
    }
}
Assert ($source.Contains('Refresh-GuestNodeDetails') -and $source.Contains('Update-GuestTargetVersionEditor') -and $source.Contains('$ui.panelTasks.Children.Add($details)')) 'Refresh the Node values/editor with status and keep them below the runnable Node steps.'

$ui.txtTargetVersion = $details.FindName('txtTargetVersion')
$ui.btnApplyTargetVersion = $details.FindName('btnApplyTargetVersion')
$script:Processes = @{}
$script:Cards = @{ Arc=@{run=$row.FindName('run')} }
$script:Current = @{ Arc=(New-ALFGuestCheck 'Done' 'Connected') }
$script:NodeTargetVersion = ''
foreach ($name in 'Save-GuestState','Update-GuestTargetVersionEditor','Apply-GuestTargetVersion') {
    $definition = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)[0]
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Refresh-GuestStatus {}
$Role = 'Node'; $ALFVersion = '2.1.1'
$StateFile = Join-Path ([IO.Path]::GetTempPath()) ('ALF-TargetState-' + [guid]::NewGuid().ToString('N') + '.json')
$script:Records = @{ Arc=@{Started='start';ResultPath='receipt'} }
try {
    $Role = 'DC'
    $script:Records = @{ Network=@{ResultPath='network-receipt'}; Forest=@{Started='start'} }
    Save-GuestState
    $script:Records.Forest.ResultPath = 'forest-receipt'
    Save-GuestState
    $saved = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    Assert ($saved.Steps.Network.ResultPath -eq 'network-receipt' -and $saved.Steps.Forest.ResultPath -eq 'forest-receipt') 'Saving DC step 2 must replace an existing state file without an empty-backup-path error or losing step 1 progress.'
    $Role = 'Node'
    $script:Records = @{ Arc=@{Started='start';ResultPath='receipt'} }
    $ui.txtTargetVersion.Text = ' 12.2602.1002.10 '
    Update-GuestTargetVersionEditor
    Assert ($ui.btnApplyTargetVersion.IsEnabled -and -not $script:Cards.Arc.run.IsEnabled) 'Unapplied target edits cannot silently run Arc with an older value.'
    Apply-GuestTargetVersion
    $saved = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    Assert ($saved.TargetSolutionVersionOverride -eq '12.2602.1002.10' -and $saved.Steps.Arc.ResultPath -eq 'receipt') 'Save a trimmed node-only override alongside, not instead of, execution progress.'
    $script:NodeTargetVersion = ConvertTo-ALFGuestTargetVersion $saved.TargetSolutionVersionOverride
    $ui.txtTargetVersion.Text = ''
    Apply-GuestTargetVersion
    Assert ((Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json).TargetSolutionVersionOverride -eq '') 'Applying blank removes the pin and preserves the delivered script default.'
    $script:Processes = @{ Arc=[pscustomobject]@{HasExited=$false} }
    $ui.txtTargetVersion.Text = '12.2602.1002.11'
    Update-GuestTargetVersionEditor
    $before = (Get-FileHash -LiteralPath $StateFile).Hash
    Apply-GuestTargetVersion
    Assert (-not $ui.txtTargetVersion.IsEnabled -and -not $ui.btnApplyTargetVersion.IsEnabled -and (Get-FileHash -LiteralPath $StateFile).Hash -eq $before) 'A running step cannot change the persisted or active target.'
    $script:Processes = @{}
    function Set-Content {
        param($LiteralPath,$Value,$Encoding,$ErrorAction)
        Microsoft.PowerShell.Management\Set-Content -LiteralPath $LiteralPath -Value 'partial' -Encoding UTF8
        throw 'Mock state write failed'
    }
    Assert-Throws { Save-GuestState } 'State-write failure must remain explicit.'
    Assert ((Get-FileHash -LiteralPath $StateFile).Hash -eq $before) 'A failed temporary write cannot truncate saved progress or the applied override.'
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath 'function:Set-Content'
    $Role = 'Admin'
    Save-GuestState
    Assert (-not (Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json).PSObject.Properties['TargetSolutionVersionOverride']) 'DC/Admin state never receives a node target-version setting.'
}
finally { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $StateFile -Force }

$runner = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'ALFGuestStepRunner.ps1'), [ref]$tokens, [ref]$errors)
$runBlock = $runner.FindAll({ param($n) $n -is [Management.Automation.Language.TryStatementAst] }, $true)[0]
$ResultPath = Join-Path ([IO.Path]::GetTempPath()) ('ALF-TargetReceipt-' + [guid]::NewGuid().ToString('N') + '.json')
function 14.Node-ArcRegister.ps1 { param($TargetSolutionVersionOverride='ScriptDefault') $script:ReceivedTarget=$TargetSolutionVersionOverride }
function 12.Node-Configure.ps1 { $script:ConfigureCalls++ }
try {
    $ScriptPath = '14.Node-ArcRegister.ps1'; $TargetSolutionVersionOverride = '12.2602.1002.10'; $exitCode=0
    . ([scriptblock]::Create($runBlock.Extent.Text))
    Assert ($script:ReceivedTarget -eq $TargetSolutionVersionOverride -and $exitCode -eq 0) 'Runner forwards exactly the applied target to Arc, not a rewritten delivered file.'
    $TargetSolutionVersionOverride = ''
    . ([scriptblock]::Create($runBlock.Extent.Text))
    Assert ($script:ReceivedTarget -eq 'ScriptDefault') 'Blank sends no override argument and leaves the script default intact.'
    $ScriptPath = '12.Node-Configure.ps1'; $TargetSolutionVersionOverride = '12.2602.1002.10'; $script:ConfigureCalls=0
    . ([scriptblock]::Create($runBlock.Extent.Text))
    Assert ($script:ConfigureCalls -eq 0 -and $exitCode -eq 1) 'Override arguments cannot reach destructive node configuration or another guest step.'
}
finally {
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $ResultPath -Force
    foreach ($name in '14.Node-ArcRegister.ps1','12.Node-Configure.ps1') { Microsoft.PowerShell.Management\Remove-Item -LiteralPath "function:$name" }
}

foreach ($name in 'AdminToolsXaml','AdminLinks','AzureCliWinget') {
    $assign = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq "`$$name" }, $true)[0]
    Set-Variable -Name $name -Value (& ([scriptblock]::Create($assign.Right.Extent.Text)))
}
Assert ($AdminLinks.WacDownload -eq 'https://aka.ms/DownloadWAC' -and $AdminLinks.WacWhatsNew -match '^https://techcommunity\.microsoft\.com/blog/windows-admin-center-blog/.+/4573651$') 'Admin links open the WAC download and the WAC 2611 virtualization mode announcement.'
Assert ($AzureCliWinget -match '^winget install -e --id Microsoft\.AzureCLI ' -and $AzureCliWinget -match '--accept-source-agreements' -and $AzureCliWinget -match '--accept-package-agreements') 'Azure CLI installs by exact winget id without interactive agreement prompts.'
$adminIf = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq "`$Role -eq 'Admin'" }, $true))
Assert ($adminIf.Count -eq 1 -and $adminIf[0].Clauses[0].Item2.Extent.Text.Contains('$ui.panelTasks.Children.Add($adminTools)') -and ([regex]::Matches($source, [regex]::Escape('Parse($AdminToolsXaml)'))).Count -eq 1 -and @(Get-GuestTasks Admin).Count -eq 1) 'Only the Admin console adds the optional WAC/Azure CLI panel, without adding a setup step.'
$adminTools = [Windows.Markup.XamlReader]::Parse($AdminToolsXaml)
$adminUi = @{}
foreach ($name in 'btnWacWhatsNew','btnWacDownload','btnAzureCli','txtAdminLinks') { $adminUi[$name] = $adminTools.FindName($name) }
Assert ($adminUi.btnWacWhatsNew.Content -match '2611' -and $adminUi.btnWacDownload.Content -eq 'Download Windows Admin Center' -and $adminUi.btnAzureCli.Content -match 'Azure CLI \(winget\)' -and $adminUi.txtAdminLinks.IsReadOnly) 'Admin panel offers both WAC links, the Azure CLI install and read-only copyable link text.'
$adminUi.txtAdminLinks.Text = "WAC 2611 what's new: $($AdminLinks.WacWhatsNew)`r`nWAC download:         $($AdminLinks.WacDownload)`r`nAzure CLI:            $AzureCliWinget"
$adminTools.SetValue([Windows.Documents.TextElement]::FontFamilyProperty, [Windows.Media.FontFamily]::new('Segoe UI'))
$adminTools.SetValue([Windows.Documents.TextElement]::FontSizeProperty, [double]15)
foreach ($width in 960, 1236) {
    $adminTools.Measure([Windows.Size]::new($width, [double]::PositiveInfinity))
    $adminTools.Arrange([Windows.Rect]::new(0, 0, $width, $adminTools.DesiredSize.Height))
    $adminTools.UpdateLayout()
    Assert ($adminTools.DesiredSize.Height -le 260) 'The Admin tools panel fits below the single Admin card.'
    foreach ($control in $adminUi.Values) {
        $bounds = $control.TransformToAncestor($adminTools).TransformBounds([Windows.Rect]::new($control.RenderSize))
        Assert ($bounds.Left -ge 0 -and $bounds.Right -le $width -and $bounds.Width -gt 0) 'Admin tool buttons and link text stay inside the available width.'
    }
}
foreach ($name in 'Open-GuestLink','Start-GuestAzureCliInstall') {
    $definition = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)[0]
    . ([scriptblock]::Create($definition.Extent.Text))
}
$Here = 'C:\ISO'
function Start-Process {
    param($FilePath, $ArgumentList, $WorkingDirectory, $ErrorAction)
    if ($script:FailStart) { throw 'Mock start failed' }
    $script:Started = @{ FilePath=$FilePath; ArgumentList=$ArgumentList; WorkingDirectory=$WorkingDirectory }
}
function Get-Command { param($Name, $ErrorAction) if ($script:HasWinget) { [pscustomobject]@{ Name=$Name } } }
try {
    $script:FailStart = $false; $script:Started = $null
    Open-GuestLink 'the Windows Admin Center download' $AdminLinks.WacDownload
    Assert ($script:Started.FilePath -eq 'https://aka.ms/DownloadWAC' -and @($script:DetailLogs)[-1].Contains('https://aka.ms/DownloadWAC')) 'The WAC download link opens in the default browser and is logged.'
    $script:FailStart = $true
    Open-GuestLink 'the Windows Admin Center 2611 announcement' $AdminLinks.WacWhatsNew
    Assert (@($script:DetailLogs)[-1] -match 'Copy this link' -and @($script:DetailLogs)[-1].Contains($AdminLinks.WacWhatsNew)) 'A browser failure leaves the full link in the log to copy.'
    $script:FailStart = $false; $script:Started = $null; $script:HasWinget = $false
    Start-GuestAzureCliInstall
    Assert ($null -eq $script:Started -and @($script:DetailLogs)[-1] -match 'winget was not found' -and @($script:DetailLogs)[-1].Contains($AdminLinks.AzureCliMsi)) 'Missing winget explains the fix and offers the Azure CLI installer link instead of starting anything.'
    $script:HasWinget = $true
    Start-GuestAzureCliInstall
    Assert ($script:Started.FilePath -eq 'powershell.exe' -and $script:Started.ArgumentList -match '-NoExit' -and $script:Started.ArgumentList.Contains($AzureCliWinget) -and @($script:DetailLogs)[-1].Contains($AzureCliWinget)) 'Azure CLI installs with winget in its own visible PowerShell window.'
    $script:FailStart = $true
    Start-GuestAzureCliInstall
    Assert (@($script:DetailLogs)[-1] -match 'Could not start' -and @($script:DetailLogs)[-1].Contains($AzureCliWinget)) 'A failed launch shows the winget command to run manually.'
}
finally { foreach ($name in 'Start-Process','Get-Command') { Microsoft.PowerShell.Management\Remove-Item -LiteralPath "function:$name" } }

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
        $script:FailCopy = $false; $script:CleanedPath = ''; $script:MarkedPath = ''; $script:ShortcutMock.Saved = $false
        Copy-ALFGuestConsoleShortcut $case.VM 'C:\ISO' $case.Launcher
        Assert (-not $script:MarkedPath) 'Do not tag the lab-made shortcut as downloaded from the Internet (Zone.Identifier ZoneId=3).'
        Assert ($script:ShortcutMock.Saved -and $script:ShortcutMock.TargetPath -eq "C:\ISO\$($case.Launcher)" -and $script:ShortcutMock.WorkingDirectory -eq 'C:\ISO') 'Each shortcut opens its own guest launcher from the guest scripts folder.'
        Assert ($script:CopyArgs.Name -eq $case.VM -and $script:CopyArgs.Destination -eq "C:\Users\Public\Desktop\$($case.Shortcut)" -and $script:CopyArgs.Source -eq $script:TempPath) 'Deliver each launcher to its VM Public Desktop so local and domain profiles share it, not to the host.'
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
