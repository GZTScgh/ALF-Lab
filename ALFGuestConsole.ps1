# Version: ALF Lab Builder 2.0.23
# Shared DC/admin/node console. Completion is detected from this guest.
param([Parameter(Mandatory = $true)][ValidateSet('DC', 'Admin', 'Node')][string]$Role)

$ALFVersion = '2.0.23'
$Here = $PSScriptRoot
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
}
catch {
    Write-Host "The $Role console cannot load WPF: $($_.Exception.Message). No configuration was run." -ForegroundColor Red
    exit 1
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -STA -File `"$PSCommandPath`" -Role $Role"
    return
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Start-Process powershell.exe -ArgumentList "-NoProfile -STA -File `"$PSCommandPath`" -Role $Role"
    return
}
try {
    foreach ($file in 'ALFGuestStatus.ps1', 'ALFGuestDisplay.ps1') {
        $path = Join-Path $Here $file
        $text = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ($text -notmatch ('(?m)^# Version: ALF Lab Builder ' + [regex]::Escape($ALFVersion) + '(?:\s|$)')) {
            throw "$file is not from this release; redeliver the complete guest console."
        }
        . $path
    }
}
catch { Write-Host "Console helpers could not load: $($_.Exception.Message). No configuration was run." -ForegroundColor Red; exit 1 }

function Get-GuestTasks([string]$GuestRole) {
    switch ($GuestRole) {
        'DC' {
            @(
                [pscustomobject]@{ Id='Network'; Script='06dc.DC-SetNameAndIP.ps1'; Needs=@(); Title='Set the DC name and network'; Text='Set the static IP and computer name. Restarts if renamed.' }
                [pscustomobject]@{ Id='Forest'; Script='07dc.DC-CreateForest.ps1'; Needs=@('Network'); Title='Create the domain'; Text='Install AD DS and DNS, then promote and restart the DC.' }
                [pscustomobject]@{ Id='DNS'; Script='08dc.DC-PostConfig.ps1'; Needs=@('Forest'); Title='Configure DNS and optional DHCP'; Text='Set DNS forwarders, reverse lookup and the planned DHCP scope.' }
                [pscustomobject]@{ Id='Artifacts'; Script='09dc.DC-PrepareADForAzureLocal.ps1'; Needs=@('DNS'); Title='Install Azure Local AD tools'; Text='Install the preparation module; optionally create the cluster OU/account.' }
            )
        }
        'Admin' {
            @(
                [pscustomobject]@{ Id='Configure'; Script='08adm.Admin-Configure.ps1'; Needs=@(); Title='Configure the admin station'; Text='Set networking, install management tools and join the domain. Restart afterward.' }
            )
        }
        'Node' {
            @(
                [pscustomobject]@{ Id='Configure'; Script='12.Node-Configure.ps1'; Needs=@(); Title='Configure this node'; Text='Set networking and the local admin. Includes destructive data-disk cleanup.'; Destructive=$true }
                [pscustomobject]@{ Id='Arc'; Script='14.Node-ArcRegister.ps1'; Needs=@('Configure'); Title='Register with Azure Arc'; Text='Register this node in Azure. May update and restart before finishing.' }
            )
        }
    }
}

function Write-GuestLog([string]$Text) {
    $ui.txtLog.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $Text`r`n")
    $ui.txtLog.ScrollToEnd()
}
function Save-GuestState {
    $state = [ordered]@{ Role=$Role; Version=$ALFVersion; SchemaVersion=2; Steps=$script:Records }
    if ($Role -eq 'Node') { $state.TargetSolutionVersionOverride = $script:NodeTargetVersion }
    $temp = $StateFile + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temp -Encoding UTF8 -ErrorAction Stop
        # Ordinary $null binds to an empty backup path in Windows PowerShell.
        if (Test-Path -LiteralPath $StateFile) { [IO.File]::Replace($temp, $StateFile, [NullString]::Value) }
        else { [IO.File]::Move($temp, $StateFile) }
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}
function Update-GuestTargetVersionEditor {
    $busy = @($script:Processes.Values | Where-Object { -not $_.HasExited }).Count -gt 0
    $dirty = $ui.txtTargetVersion.Text.Trim() -cne $script:NodeTargetVersion
    $ui.txtTargetVersion.IsEnabled = -not $busy
    $ui.btnApplyTargetVersion.IsEnabled = -not $busy -and $dirty
    $script:Cards.Arc.run.IsEnabled = -not $busy -and -not $dirty -and $script:Current.Arc.RunAllowed
    $script:Cards.Arc.run.ToolTip = if ($dirty) { 'Apply the target version change or restore the saved text before running Arc.' } elseif ($script:Current.Arc.RunAllowed) { 'Run Arc with the displayed target version.' } else { $script:Current.Arc.Detail }
}
function Apply-GuestTargetVersion {
    if (@($script:Processes.Values | Where-Object { -not $_.HasExited }).Count) { Write-GuestLog 'Wait for the current step window to close before changing the target version.'; return }
    $previous = $script:NodeTargetVersion
    try {
        $script:NodeTargetVersion = ConvertTo-ALFGuestTargetVersion $ui.txtTargetVersion.Text
        Save-GuestState
        $ui.txtTargetVersion.Text = $script:NodeTargetVersion
        Write-GuestLog 'Target version saved on this node for the next Arc run. Blank uses the delivered script default; no registration or update was started.'
    }
    catch {
        $script:NodeTargetVersion = $previous
        $message = "Target version was not saved: $($_.Exception.Message)"
        Write-GuestLog $message
        [Windows.MessageBox]::Show($window, $message, 'Target version', 'OK', 'Warning') | Out-Null
    }
    Refresh-GuestStatus
}
function Set-GuestConsoleDisplay([bool]$ShowWarning = $false) {
    try {
        Write-GuestLog (Set-ALFGuestDisplayResolution $Role)
        $work = [Windows.SystemParameters]::WorkArea
        $window.Width = [Math]::Min(1300, $work.Width)
        $window.Height = [Math]::Min(850, $work.Height)
    }
    catch {
        $message = "Optional display restore skipped: $($_.Exception.Message)"
        Write-GuestLog $message
        if ($ShowWarning) { [Windows.MessageBox]::Show($window, $message, 'Display setting', 'OK', 'Warning') | Out-Null }
    }
}
function Test-GuestScript($Task) {
    $path = Join-Path $Here $Task.Script
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return "Missing $($Task.Script); redeliver the guest files." }
    $text = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    $requiredText = $text.Replace('{{TimeZone}}', '').Replace('{{LocalAdminPassword}}', '')
    if ($requiredText -match '\{\{[A-Za-z0-9_]+\}\}|__NODENAME__|__NODEIP__') { return "Unfilled $($Task.Script); redeliver its prepared copy." }
    if ($text -notmatch ('(?m)^# Version: ALF Lab Builder ' + [regex]::Escape($ALFVersion) + '(?:\s|$)')) { return "Wrong release: $($Task.Script)." }
    return $null
}
function Get-GuestStatus($Task) {
    $running = $false
    if ($script:Processes.ContainsKey($Task.Id)) {
        $process = $script:Processes[$Task.Id]
        if (-not $process.HasExited) { $running=$true }
        else { $process.Dispose(); $script:Processes.Remove($Task.Id) }
    }
    if ($running) { return New-ALFGuestCheck 'Running' 'In its own PowerShell window.' $false }
    try { $problem = Test-GuestScript $Task }
    catch { return New-ALFGuestCheck 'Attention' "Script could not be inspected: $($_.Exception.Message)" $false }
    if ($problem) { return New-ALFGuestCheck 'Attention' $problem $false }
    $check = Get-ALFGuestTaskCheck $Task $Role $Here
    $record = $script:Records[$Task.Id]
    $receipt = $null; $receiptError = ''
    if ($record.ResultPath -and (Test-Path -LiteralPath $record.ResultPath)) {
        try {
            $receipt = Get-Content -LiteralPath $record.ResultPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($receipt.ExitCode -isnot [int] -and $receipt.ExitCode -isnot [long]) { throw 'Result has no valid exit code.' }
        }
        catch { $receiptError = "Step result could not be read: $($_.Exception.Message)" }
    }
    return Resolve-ALFGuestTaskState $check $record $false $receipt $receiptError
}
function Set-GuestCardState($Card, $Check) {
    $Card.status.Text = $StateText[$Check.State]
    $Card.status.Foreground = $Colors[$Check.State]
    $Card.statusDetail.Text = $Check.Detail
    $Card.numBack.Background = if ($Check.State -eq 'Done') { $Colors.Done } else { $Colors.Running }
}
function Refresh-GuestNodeDetails {
    try {
        $ui.txtArcValues.Text = Get-ALFGuestArcSettingsText $Here $script:NodeTargetVersion
        $ui.txtArcValues.Foreground = $Colors.NotDone
        $script:ArcValuesError = ''
    }
    catch {
        $message = "Arc values unavailable: $($_.Exception.Message)"
        $ui.txtArcValues.Text = $message
        $ui.txtArcValues.Foreground = $Colors.Attention
        if ($script:ArcValuesError -ne $message) { Write-GuestLog $message }
        $script:ArcValuesError = $message
    }
    try {
        $ui.txtTimeStatus.Text = Get-ALFGuestTimeStatus
        $ui.txtTimeStatus.Foreground = $Colors.NotDone
        $script:TimeStatusError = ''
    }
    catch {
        $message = "Time status unavailable: $($_.Exception.Message)"
        $ui.txtTimeStatus.Text = $message
        $ui.txtTimeStatus.Foreground = $Colors.Attention
        if ($script:TimeStatusError -ne $message) { Write-GuestLog $message }
        $script:TimeStatusError = $message
    }
}
function Refresh-GuestStatus {
    $busy = @($script:Processes.Values | Where-Object { -not $_.HasExited }).Count -gt 0
    $done = 0
    foreach ($task in $Tasks) {
        $check = Get-GuestStatus $task
        $script:Current[$task.Id] = $check
        $card = $script:Cards[$task.Id]
        Set-GuestCardState $card $check
        $card.run.IsEnabled = -not $busy -and $check.RunAllowed
        $card.run.ToolTip = if ($check.RunAllowed) { 'Run this setup script.' } else { $check.Detail }
        $card.open.IsEnabled = Test-Path -LiteralPath (Join-Path $Here $task.Script)
        if ($check.State -eq 'Done') { $done++ }
    }
    $ui.btnDisplay.IsEnabled = -not $busy
    $ui.txtProgress.Text = "$done of $($Tasks.Count) steps done"
    if ($Role -eq 'Node') {
        Refresh-GuestNodeDetails
        Update-GuestTargetVersionEditor
    }
}
function Start-GuestStep([string]$Id) {
    $task = $Tasks | Where-Object Id -eq $Id | Select-Object -First 1
    if (-not $task) { throw "Unknown guest step '$Id'." }
    if (@($script:Processes.Values | Where-Object { -not $_.HasExited }).Count) { Write-GuestLog 'Wait for the current step window to close.'; return }
    if ($Role -eq 'Node' -and $Id -eq 'Arc' -and $ui.txtTargetVersion.Text.Trim() -cne $script:NodeTargetVersion) {
        Write-GuestLog 'Apply the target version change or restore the saved text before running Arc.'
        return
    }
    Refresh-GuestStatus
    $check = $script:Current[$Id]
    if (-not $check.RunAllowed) { Write-GuestLog $check.Detail; return }
    $missing = @($task.Needs | Where-Object { $script:Current[$_].State -ne 'Done' })
    if ($missing.Count) {
        $titles = @($Tasks | Where-Object Id -in $missing | ForEach-Object Title)
        if ([Windows.MessageBox]::Show($window, "These steps are not done yet:`n$($titles -join "`n")`n`nRun this step anyway?", 'Earlier steps incomplete', 'YesNo', 'Warning') -ne 'Yes') { return }
    }
    if ($task.Destructive) {
        $message = 'This removes storage pools and clears eligible data disks on THIS node. Never run it on a deployed cluster. Continue?'
        if ([Windows.MessageBox]::Show($window, $message, 'Destructive disk cleanup', 'YesNo', 'Warning') -ne 'Yes') { return }
    }
    $resultPath = Join-Path $Here ("ALFGuestConsole-$Role-$Id-" + [guid]::NewGuid().ToString('N') + '.json')
    $script:Records[$Id] = @{ Started=(Get-Date).ToString('o'); ResultPath=$resultPath }
    try {
        $runner = Join-Path $Here 'ALFGuestStepRunner.ps1'
        if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw 'ALFGuestStepRunner.ps1 is missing.' }
        Save-GuestState
        $argList = "-NoProfile -STA -File `"$runner`" -ScriptPath `"$(Join-Path $Here $task.Script)`" -ResultPath `"$resultPath`""
        if ($Role -eq 'Node' -and $Id -eq 'Arc' -and $script:NodeTargetVersion) {
            $target = ConvertTo-ALFGuestTargetVersion $script:NodeTargetVersion
            $argList += " -TargetSolutionVersionOverride `"$target`""
        }
        $process = Start-Process powershell.exe -ArgumentList $argList -WorkingDirectory $Here -PassThru -ErrorAction Stop
        $script:Processes[$Id] = $process
        $script:Records[$Id].ProcessId = $process.Id
        $script:Records[$Id].ProcessStarted = $process.StartTime.ToUniversalTime().ToString('o')
        Save-GuestState
        Write-GuestLog "Started $($task.Script). Reopen this console after any restart."
    }
    catch {
        $script:Records[$Id].LaunchError = "Could not start or record the step: $($_.Exception.Message)"
        Write-GuestLog $script:Records[$Id].LaunchError
        try { Save-GuestState }
        catch { Write-GuestLog "Could not save the failure: $($_.Exception.Message)" }
    }
    Refresh-GuestStatus
}

$Tasks = @(Get-GuestTasks $Role)
$StateFile = Join-Path $Here "ALFGuestConsole-$Role-State.json"
$script:Records = @{}
$script:Processes = @{}
$script:Cards = @{}
$script:Current = @{}
$script:ArcValuesError = ''
$script:TimeStatusError = ''
$script:NodeTargetVersion = ''
if (Test-Path -LiteralPath $StateFile) {
    try {
        $saved = Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $script:Records = ConvertTo-ALFGuestRecords $saved $Role $ALFVersion @($Tasks | ForEach-Object Id)
        if ($Role -eq 'Node' -and $saved.PSObject.Properties['TargetSolutionVersionOverride']) {
            if ($saved.TargetSolutionVersionOverride -isnot [string]) { throw 'Saved node target version must be text.' }
            $script:NodeTargetVersion = ConvertTo-ALFGuestTargetVersion $saved.TargetSolutionVersionOverride
        }
        foreach ($id in $script:Records.Keys) {
            $record = $script:Records[$id]
            if ($record.ProcessId -and $record.ProcessStarted) {
                $process = Get-Process -Id $record.ProcessId -ErrorAction SilentlyContinue
                if ($process -and $process.StartTime.ToUniversalTime().ToString('o') -eq $record.ProcessStarted) { $script:Processes[$id] = $process }
            }
        }
    }
    catch { Write-Host "Cannot safely load guest state: $($_.Exception.Message). Original state preserved." -ForegroundColor Red; exit 1 }
}
$roleTitle = @{ DC='Domain Controller'; Admin='Admin Station'; Node='Azure Local Node' }[$Role]
$next = @{
    DC='Next: finish the admin station and nodes, then prepare the Azure Local deployment.'
    Admin='Next: use the management tools and follow the Azure Local deployment steps.'
    Node='Next: register the other node, review Azure Policy, then deploy from the Azure portal.'
}[$Role]
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="ALF Guest Console" Width="1300" Height="850"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="15" Background="#F3F3F3">
  <DockPanel Margin="12">
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,8">
      <WrapPanel>
        <TextBlock Name="txtTitle" FontSize="22" FontWeight="SemiBold" Foreground="#0B5394"/>
        <Border Background="#0B5394" CornerRadius="4" Padding="8,2" Margin="12,4,0,4" VerticalAlignment="Center">
          <TextBlock Name="txtVersion" Foreground="White" FontWeight="SemiBold"/>
        </Border>
        <TextBlock Name="txtProgress" FontSize="16" Foreground="#444444" Margin="16,0,0,0" VerticalAlignment="Center"/>
      </WrapPanel>
      <TextBlock Name="txtMachine" Foreground="Gray" TextWrapping="Wrap" Margin="0,2,0,0"/>
    </StackPanel>
    <Grid DockPanel.Dock="Bottom" Margin="0,10,0,0">
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="110"/></Grid.RowDefinitions>
      <TextBlock Name="txtNext" Grid.Row="0" TextWrapping="Wrap" Foreground="#444444" Margin="0,0,0,8"/>
      <WrapPanel Grid.Row="1" Margin="0,0,0,8">
        <Button Name="btnRefresh" Content="Refresh status" Width="150" Margin="0,0,8,0"/>
        <Button Name="btnFolder" Content="Open scripts folder" Width="175" Margin="0,0,8,0"/>
        <Button Name="btnDisplay" Content="1600 x 900 display" Width="165" ToolTip="Set this desktop to 1600 x 900 when supported."/>
      </WrapPanel>
      <TextBox Name="txtLog" Grid.Row="2" IsReadOnly="True" FontFamily="Consolas" FontSize="13"
               TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="#FFFFFF"/>
    </Grid>
    <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Name="panelTasks"/></ScrollViewer>
  </DockPanel>
</Window>
'@
$RowXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        BorderBrush="#DDDDDD" BorderThickness="1" Background="White" CornerRadius="4" Padding="10" Margin="0,0,0,6">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="50"/><ColumnDefinition Width="*"/><ColumnDefinition Width="250"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <Border Grid.Column="0" Name="numBack" Width="34" Height="34" CornerRadius="17" Background="#0B5394" VerticalAlignment="Top">
      <TextBlock Name="num" Foreground="White" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <StackPanel Grid.Column="1" Margin="4,0,12,0">
      <TextBlock Name="title" FontSize="16" FontWeight="SemiBold" TextWrapping="Wrap"/>
      <TextBlock Name="desc" TextWrapping="Wrap" Foreground="#444444" Margin="0,2,0,0"/>
      <TextBlock Name="script" FontFamily="Consolas" FontSize="13" TextWrapping="Wrap" Foreground="Gray" Margin="0,2,0,0"/>
    </StackPanel>
    <StackPanel Grid.Column="2" VerticalAlignment="Center" Margin="0,0,8,0">
      <TextBlock Name="status" FontWeight="SemiBold" TextWrapping="Wrap"/>
      <TextBlock Name="statusDetail" Foreground="Gray" FontSize="13" TextWrapping="Wrap"/>
    </StackPanel>
    <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Center">
      <Button Name="run" Content="Run" Width="100" Height="34" Margin="0,0,6,0" FontWeight="SemiBold"/>
      <Button Name="open" Content="Open script" Width="110" Height="34"/>
    </StackPanel>
  </Grid>
</Border>
'@
$NodeDetailsXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Margin="0,2,0,6">
  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
  <Border Grid.Column="0" BorderBrush="#DDDDDD" BorderThickness="1" Background="White" CornerRadius="4" Padding="10" Margin="0,0,6,0">
    <StackPanel>
      <TextBlock Text="Arc registration values" FontSize="16" FontWeight="SemiBold" Foreground="#0B5394"/>
      <TextBlock Text="14.Node-ArcRegister.ps1" FontFamily="Consolas" FontSize="13" Foreground="Gray" Margin="0,2,0,4"/>
      <TextBox Name="txtArcValues" IsReadOnly="True" BorderThickness="0" Background="Transparent" Padding="0"
               FontFamily="Consolas" FontSize="13" TextWrapping="Wrap"/>
      <Grid Margin="0,6,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock Text="Target version (next Arc run):" FontSize="13" VerticalAlignment="Center" Margin="0,0,6,0"/>
        <TextBox Name="txtTargetVersion" Grid.Column="1" FontFamily="Consolas" FontSize="13" Height="26" MaxLength="64">
          <TextBox.ToolTip>
            <TextBlock FontFamily="Consolas" FontSize="13" Text="Azure Local solution version: Major.YYMM.Build.Revision&#x0a;  12   = major line (12 = OS 26100 / 24H2, new deployments)&#x0a;  2610 = release train, YYMM (2610 = October 2026)&#x0a;  1004 = build family; copy it from Microsoft, do not guess&#x0a;  50   = revision; a re-release gets a higher number&#x0a;Examples: 12.2610.1004.50  12.2604.1003.1006  12.2602.1002.501&#x0a;Newer release: copy its full version from Microsoft Learn&#x0a;'Azure Local release information'.&#x0a;Apply saves it on this node only; it is used the next time Arc runs.&#x0a;Blank = script default (normally a list to pick from)."/>
          </TextBox.ToolTip>
        </TextBox>
        <Button Name="btnApplyTargetVersion" Grid.Column="2" Content="Apply" Width="65" Height="26" Margin="6,0,0,0"/>
      </Grid>
      <TextBlock Name="txtTargetVersionHelp" FontSize="12" Foreground="Gray" TextWrapping="Wrap" Margin="0,4,0,0"
                 Text="Format 12.YYMM.Build.Revision, e.g. 12.2610.1004.50 or 12.2602.1002.501 (2610 = Oct 2026). For a newer release, copy the full version from Microsoft Learn 'Azure Local release information'. Blank = pick from a list."/>
    </StackPanel>
  </Border>
  <Border Grid.Column="1" BorderBrush="#DDDDDD" BorderThickness="1" Background="White" CornerRadius="4" Padding="10" Margin="6,0,0,0">
    <StackPanel>
      <TextBlock Text="Time synchronization (NTP/domain)" FontSize="16" FontWeight="SemiBold" TextWrapping="Wrap" Foreground="#0B5394"/>
      <TextBlock Text="w32tm /query /status" FontFamily="Consolas" FontSize="13" Foreground="Gray" Margin="0,2,0,4"/>
      <TextBox Name="txtTimeStatus" IsReadOnly="True" BorderThickness="0" Background="Transparent" Padding="0"
               FontFamily="Consolas" FontSize="13" TextWrapping="Wrap"/>
    </StackPanel>
  </Border>
</Grid>
'@
$Brush = New-Object Windows.Media.BrushConverter
$Colors = @{
    Done=$Brush.ConvertFromString('#107C10'); NotDone=$Brush.ConvertFromString('#605E5C')
    Attention=$Brush.ConvertFromString('#8A6100'); Running=$Brush.ConvertFromString('#0B5394'); Failed=$Brush.ConvertFromString('#A4262C')
}
$StateText = @{ Done='Done'; NotDone='Not started'; Attention='Needs attention'; Running='Running'; Failed='Failed' }
try { $window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml)) }
catch { Write-Host "Console window failed: $($_.Exception.Message). No configuration was run." -ForegroundColor Red; exit 1 }
$ui = @{}
$xaml.SelectNodes('//*[@Name]') | ForEach-Object { $ui[$_.Name] = $window.FindName($_.Name) }
$window.Title = "3. ALF Lab Builder - $roleTitle Console"
$ui.txtTitle.Text = $window.Title
$ui.txtVersion.Text = "v$ALFVersion"
$ui.txtMachine.Text = "$env:COMPUTERNAME | $roleTitle | Scripts: $Here"
$ui.txtNext.Text = $next
if ($Role -eq 'Node') { $ui.btnDisplay.Visibility = 'Collapsed' }
$count = 0
foreach ($task in $Tasks) {
    $count++
    $row = [Windows.Markup.XamlReader]::Parse($RowXaml)
    $card = @{}
    foreach ($name in 'numBack','num','title','desc','script','run','open','status','statusDetail') { $card[$name]=$row.FindName($name) }
    $card.num.Text = "$count"
    $card.title.Text = $task.Title
    $card.desc.Text = $task.Text
    $card.script.Text = $task.Script
    $id = $task.Id
    $path = Join-Path $Here $task.Script
    $card.run.Add_Click({ Start-GuestStep $id }.GetNewClosure())
    $card.open.Add_Click({ Start-Process notepad.exe -ArgumentList "`"$path`"" }.GetNewClosure())
    $script:Cards[$id] = $card
    $ui.panelTasks.Children.Add($row) | Out-Null
}
if ($Role -eq 'Node') {
    $details = [Windows.Markup.XamlReader]::Parse($NodeDetailsXaml)
    foreach ($name in 'txtArcValues','txtTimeStatus','txtTargetVersion','btnApplyTargetVersion') { $ui[$name] = $details.FindName($name) }
    $ui.txtTargetVersion.Text = $script:NodeTargetVersion
    $ui.txtTargetVersion.Add_TextChanged({ Update-GuestTargetVersionEditor })
    $ui.btnApplyTargetVersion.Add_Click({ Apply-GuestTargetVersion })
    $ui.panelTasks.Children.Add($details) | Out-Null
}
$ui.btnRefresh.Add_Click({ Refresh-GuestStatus })
$ui.btnFolder.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$Here`"" })
$ui.btnDisplay.Add_Click({ Set-GuestConsoleDisplay $true })
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(10)
$timer.Add_Tick({ Refresh-GuestStatus })
$window.Add_Closing({
    param($sender, $e)
    if (@($script:Processes.Values | Where-Object { -not $_.HasExited }).Count) {
        if ([Windows.MessageBox]::Show($window, 'A step is still running. Closing this console does not stop it. Close anyway?', 'Step still running', 'YesNo', 'Warning') -ne 'Yes') { $e.Cancel=$true }
    }
    elseif ($Role -eq 'Node' -and $ui.txtTargetVersion.Text.Trim() -cne $script:NodeTargetVersion) {
        if ([Windows.MessageBox]::Show($window, 'The target version change has not been applied. Close without saving it?', 'Target version', 'YesNo', 'Warning') -ne 'Yes') { $e.Cancel=$true }
    }
})
Write-GuestLog 'Status is detected from this guest. Reopen the console after any restart.'
$work = [Windows.SystemParameters]::WorkArea
$window.Width = [Math]::Min($window.Width, $work.Width)
$window.Height = [Math]::Min($window.Height, $work.Height)
Refresh-GuestStatus
$timer.Start()
try { $window.ShowDialog() | Out-Null } finally { $timer.Stop() }
