# Version: ALF Lab Builder 2.0.14
# Shared graphical guide for configuration INSIDE a lab guest, not on the Hyper-V host.
param([Parameter(Mandatory = $true)][ValidateSet('DC', 'Admin', 'Node')][string]$Role)

$ALFVersion = '2.0.14'
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
}
catch {
    Write-Host "The $Role graphical console cannot load WPF on this Windows installation." -ForegroundColor Red
    Write-Host $_.Exception.Message
    Write-Host 'No configuration was run. Use the numbered scripts individually and report this compatibility result.'
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

function Get-GuestTasks([string]$GuestRole) {
    switch ($GuestRole) {
        'DC' {
            @(
                [pscustomobject]@{ Id='Ready'; Script=''; Needs=@(); Title='Finish Windows setup and identify this VM'; Why='The domain controller will provide identity and DNS to the lab.'; Learn='Sign in as the local administrator inside the DC VM. Host step 05 must have copied the DC scripts and this console into C:\ISO.'; Check='Confirm that this is the domain-controller VM, Windows setup is complete, and you know its local Administrator password.' }
                [pscustomobject]@{ Id='Network'; Script='06dc.DC-SetNameAndIP.ps1'; Needs=@('Ready'); Title='Set the DC name, IP address and time zone'; Why='A stable address lets every other VM find the domain DNS server.'; Learn='Configures the LAN adapter, static address, gateway and initial DNS; attempts an optional time-zone change (any unavailable ID falls back to Eastern Standard Time; failures warn and continue); renames the machine. If the name changes, it restarts automatically. Sign back in and reopen this console.'; Check='Run hostname and Get-NetIPConfiguration. Confirm ContosoDC1 and the planned DC address/gateway. Complete any restart before confirming.' }
                [pscustomobject]@{ Id='Forest'; Script='07dc.DC-CreateForest.ps1'; Needs=@('Network'); Title='Create the Active Directory forest'; Why='The forest provides lab user/computer accounts, authentication and DNS.'; Learn='Installs AD DS, DNS and management tools, then promotes this VM. You choose a DSRM recovery password. Promotion restarts Windows; sign in as the domain Administrator afterward.'; Check='After restart, run Get-ADDomain and Get-Service NTDS,DNS. Confirm the expected lab domain and running services.' }
                [pscustomobject]@{ Id='DNS'; Script='08dc.DC-PostConfig.ps1'; Needs=@('Forest'); Title='Finish DNS and optional DHCP configuration'; Why='DNS forwarders resolve internet names; reverse DNS maps lab addresses back to names.'; Learn='Configures forwarders, reverse lookup zone and DNS client settings. When enabled in the script, DHCP supplies the planned scope and options. This does not deploy the Azure Local cluster.'; Check='Inspect Get-DnsServerForwarder and Get-DnsServerZone. If DHCP is enabled, check its scope, address range, gateway and DNS options. Confirm other VMs can resolve the lab domain.' }
                [pscustomobject]@{ Id='Artifacts'; Script='09dc.DC-PrepareADForAzureLocal.ps1'; Needs=@('DNS'); Title='Prepare the cluster OU and deployment account'; Why='Azure Local deployment needs a dedicated OU and correctly delegated LCM account.'; Learn='Installs the AD preparation module and asks whether to create the OU/account. Keep the account password in your own secure records, not the console. Choosing not to create them is not completion.'; Check='Confirm the chosen OU, LCM account and required permissions in Active Directory. C:\ISO\LCMAccount.txt records the names, not the password. Give these details to the student deploying the cluster.' }
            )
        }
        'Admin' {
            @(
                [pscustomobject]@{ Id='Ready'; Script=''; Needs=@(); Title='Confirm the DC is ready and Windows setup is finished'; Why='Domain join needs working AD and DNS before configuring the admin station.'; Learn='Complete DC console steps through DNS first. Host step 05 copies the admin script and this console into C:\ISO. Sign in initially as the local administrator.'; Check='Confirm this is the admin-station VM, the DC is online and its DNS/forest setup is finished, and you have a domain account allowed to join computers.' }
                [pscustomobject]@{ Id='Configure'; Script='08adm.Admin-Configure.ps1'; Needs=@('Ready'); Title='Configure networking, tools, name and domain membership'; Why='The admin station is the student workstation for managing the nested lab.'; Learn='One existing script configures static LAN/IP/gateway, uses DC DNS, attempts the optional time-zone change (any unavailable ID falls back to Eastern Standard Time; failures warn and continue), installs cluster/Hyper-V/AD/DNS tools, renames this VM and joins the domain. Read each stage in its PowerShell window; supply domain credentials when prompted. Restart when offered.'; Check='After restart, check hostname, Get-NetIPConfiguration and (Get-CimInstance Win32_ComputerSystem).PartOfDomain. Verify RSAT-Clustering, RSAT-Hyper-V-Tools, RSAT-AD-Tools, RSAT-DNS-Server and GPMC are installed with Get-WindowsFeature.' }
                [pscustomobject]@{ Id='Manage'; Script=''; Needs=@('Configure'); Title='Sign in with a domain account and test management access'; Why='Installed tools are useful only when DNS, credentials and permissions work.'; Learn='Sign in using your domain account. Open Hyper-V Manager, DNS Manager, AD Users and Computers and Failover Cluster Manager as appropriate. Connection permissions may require additional setup; installing tools alone does not grant remote access.'; Check='Resolve the DC name and verify domain sign-in. Open the installed tools and confirm the management connections you need. Do not create a cluster here as a substitute for Azure portal deployment.' }
            )
        }
        'Node' {
            @(
                [pscustomobject]@{ Id='Ready'; Script=''; Needs=@(); Title='Finish Azure Local installation and host-side preparation'; Why='Each node needs its own identity, IP address and correctly named virtual adapters.'; Learn='Install Azure Local and set Administrator on this node. Run host step 11 for all nodes; it renames NICs and copies a node-specific 12.Node-Configure.ps1. From SConfig choose option 15, cd C:\ISO, then run .\Launch-ALFNodeConsole.cmd. GUI compatibility on Server Core is being trialled.'; Check='Confirm this is the intended node, not the host. Inspect the AZLnodename and IPAddress variables in 12.Node-Configure.ps1, and Get-NetAdapter names. Never use another node''s configure script.' }
                [pscustomobject]@{ Id='Configure'; Script='12.Node-Configure.ps1'; Needs=@('Ready'); Title='Configure this node for the lab'; Why='Deployment needs consistent management networking, local credentials and clean storage.'; Learn='Sets management IP/DC DNS; attempts an optional time-zone change (any unavailable ID falls back to Eastern Standard Time; failures warn and continue); creates the second local admin; removes old storage pools and cleans eligible data disks; enables management access; renames the node and offers restart. STORAGE CLEANUP IS DESTRUCTIVE. Use the same second-admin password on both nodes. Domain join is optional here; follow the script and your deployment plan.'; Check='After restart, verify hostname, management IP/gateway/DC DNS, all adapters, the second local admin and the four intended data disks. Read storage-cleanup output and do not confirm if the wrong disks were targeted.' }
                [pscustomobject]@{ Id='AzureReady'; Script=''; Needs=@('Configure'); Title='Confirm Azure prerequisites and the second node'; Why='Both nodes must register into the intended tenant, subscription, cluster resource group and region.'; Learn='In the Planning Console/workstation, complete resource providers, role assignments and policy review (script 13 / Azure preparation). Prepare AD artifacts on the DC. Repeat node configuration on the other node. Keep host and cluster resource groups separate.'; Check='Confirm both node identities/configuration, the target Azure values in 14.Node-ArcRegister.ps1, required roles/providers and policy review, and the AD OU/account. This console cannot prove prerequisites on another VM or in Azure.' }
                [pscustomobject]@{ Id='Arc'; Script='14.Node-ArcRegister.ps1'; Needs=@('AzureReady'); Title='Register this node with Azure Arc'; Why='Arc connects the guest to Azure so Azure Local deployment can discover and manage it.'; Learn='Installs/loads registration components, prompts for Azure device-code sign-in and registers this node. Use the planned tenant/subscription/cluster resource group/region. This is registration, not cluster deployment. Logs are under C:\ISO\Logs.'; Check='Run & "C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe" show and inspect Get-ArcBootstrapStatus when available. Confirm connected registration in the correct Azure target and a healthy portal entry. Repeat on the other node.' }
                [pscustomobject]@{ Id='Deploy'; Script=''; Needs=@('Arc'); Title='Hand off to policy review and Azure portal deployment'; Why='Only after both nodes and AD/Azure prerequisites are ready can the cluster be deployed.'; Learn='Return to workstation script 15 for policy review of the registered nodes, then Planning Console section 7 for Azure portal wizard values. Review health of BOTH nodes. Deploy from the portal; this console does not deploy the cluster.'; Check='Confirm both Arc resources are healthy, policy checks are reviewed, the OU/account details are ready, and you have the cluster wizard values. This acknowledgment means ready to hand off, not a deployed cluster.' }
            )
        }
    }
}

function Get-GuestRecord([string]$Id) { return $script:Records[$Id] }
function Clear-GuestDependentConfirmations([string]$Id) {
    foreach ($dependent in $Tasks | Where-Object { $_.Needs -contains $Id }) {
        if ($script:Records.ContainsKey($dependent.Id)) { $script:Records[$dependent.Id].Confirmed = $false }
        Clear-GuestDependentConfirmations $dependent.Id
    }
}
function Save-GuestState {
    [ordered]@{ Role=$Role; Version=$ALFVersion; Steps=$script:Records } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StateFile -Encoding UTF8 -ErrorAction Stop
}
function Get-GuestStatus($Task) {
    $record = Get-GuestRecord $Task.Id
    if ($script:Processes.ContainsKey($Task.Id)) {
        if (-not $script:Processes[$Task.Id].HasExited) { return 'Running' }
        $script:Processes[$Task.Id].Dispose()
        $script:Processes.Remove($Task.Id)
    }
    if ($record -and $record.Confirmed) { return 'Student confirmed' }
    if ($record -and $record.ResultPath -and (Test-Path -LiteralPath $record.ResultPath)) {
        try {
            $result = Get-Content -LiteralPath $record.ResultPath -Raw | ConvertFrom-Json
            if ($result.ExitCode -eq 0) { return 'Script returned - check result' }
            return 'Last run failed'
        } catch { return 'Receipt unreadable - check result' }
    }
    if ($record -and $record.Started) { return 'Interrupted / restarted - check result' }
    return 'Not started'
}
function Get-GuestMissingNeeds($Task) {
    return @($Task.Needs | Where-Object { -not ($script:Records[$_] -and $script:Records[$_].Confirmed) })
}
function Test-GuestScript($Task) {
    if (-not $Task.Script) { return $null }
    $path = Join-Path $Here $Task.Script
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return "Missing script: $($Task.Script). Repeat host step 05 (DC/admin) or 11 (nodes)." }
    $text = Get-Content -LiteralPath $path -Raw
    if ($text -match '\{\{[A-Za-z0-9_]+\}\}|__NODENAME__|__NODEIP__') { return "Unfilled template: $($Task.Script). Roll out again and repeat host delivery; do not run this copy." }
    if ($text -notmatch ('(?m)^# Version: ALF Lab Builder ' + [regex]::Escape($ALFVersion) + '(?:\s|$)')) { return "Version mismatch or missing stamp: $($Task.Script). Use the same release as this console." }
    return $null
}
function Write-GuestLog([string]$Text) {
    $ui.txtLog.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $Text`r`n")
    $ui.txtLog.ScrollToEnd()
}
function Set-GuestCardState($Card, [string]$Status, [string]$Problem) {
    $state = if ($Problem -or $Status -eq 'Last run failed') { 'Failed' }
        elseif ($Status -eq 'Student confirmed') { 'Done' }
        elseif ($Status -eq 'Running') { 'Running' }
        elseif ($Status -eq 'Not started') { 'NotDone' }
        else { 'Attention' }
    $Card.status.Text = if ($Problem) { 'Needs attention' } else { $Status }
    $Card.status.Foreground = $Colors[$state]
    $Card.statusDetail.Text = $Problem
    $Card.numBack.Background = if ($state -eq 'Done') { $Colors.Done } else { $Colors.Running }
}

function Refresh-GuestStatus {
    $confirmed = 0
    $busy = @($script:Processes.Values | Where-Object { -not $_.HasExited }).Count -gt 0
    foreach ($task in $Tasks) {
        $card = $script:Cards[$task.Id]
        $status = Get-GuestStatus $task
        $problem = Test-GuestScript $task
        Set-GuestCardState $card $status $problem
        $card.run.IsEnabled = [bool]$task.Script -and -not $busy -and -not $problem
        $card.confirm.IsEnabled = -not $busy -and -not $problem
        if ($status -eq 'Student confirmed') { $confirmed++ }
    }
    $ui.txtProgress.Text = "$confirmed of $($Tasks.Count) steps student-confirmed"
}
function Start-GuestStep([string]$Id) {
    $task = $Tasks | Where-Object Id -eq $Id | Select-Object -First 1
    if (-not $task -or -not $task.Script) { return }
    if (@($script:Processes.Values | Where-Object { -not $_.HasExited }).Count) { return }
    $problem = Test-GuestScript $task
    if ($problem) { Write-GuestLog $problem; return }
    $needs = Get-GuestMissingNeeds $task
    if ($needs.Count) { Write-GuestLog "Confirm these prerequisite steps first: $($needs -join ', ')."; return }
    $message = "Run '$($task.Title)' INSIDE $env:COMPUTERNAME ($Role)?`n`n$($task.Learn)`n`nA separate PowerShell window will handle credentials and output. A restart may close both windows. Reopen this console after signing back in."
    if ([Windows.MessageBox]::Show($window, $message, 'Confirm configuration step', 'YesNo', 'Warning') -ne 'Yes') { return }
    $resultPath = Join-Path $Here ("ALFGuestConsole-$Role-$Id-" + [guid]::NewGuid().ToString('N') + '.json')
    $script:Records[$Id] = @{ Confirmed=$false; Started=(Get-Date).ToString('o'); ResultPath=$resultPath }
    Clear-GuestDependentConfirmations $Id
    Save-GuestState
    try {
        $runner = Join-Path $Here 'ALFGuestStepRunner.ps1'
        if (-not (Test-Path -LiteralPath $runner)) { throw 'ALFGuestStepRunner.ps1 is missing.' }
        $args = "-NoProfile -STA -File `"$runner`" -ScriptPath `"$(Join-Path $Here $task.Script)`" -ResultPath `"$resultPath`""
        $script:Processes[$Id] = Start-Process powershell.exe -ArgumentList $args -PassThru -ErrorAction Stop
        $script:Records[$Id].ProcessId = $script:Processes[$Id].Id
        $script:Records[$Id].ProcessStarted = $script:Processes[$Id].StartTime.ToUniversalTime().ToString('o')
        Save-GuestState
        Write-GuestLog "Started $($task.Script). Read its output; do not confirm until after checking the result and any restart."
    } catch { Write-GuestLog "Could not start step: $($_.Exception.Message). Windows protections have not been changed." }
    Refresh-GuestStatus
}
function Confirm-GuestStep([string]$Id) {
    $task = $Tasks | Where-Object Id -eq $Id | Select-Object -First 1
    if (@($script:Processes.Values | Where-Object { -not $_.HasExited }).Count) { return }
    if ((Get-GuestMissingNeeds $task).Count) { Write-GuestLog 'Confirm the earlier prerequisite steps first.'; return }
    if (Test-GuestScript $task) { Write-GuestLog (Test-GuestScript $task); return }
    $message = "Check before confirming:`n`n$($task.Check)`n`nHave you personally checked these results on the intended VM, including any required restart?`n`nThis records YOUR confirmation; it does not automatically test configuration or declare cluster deployment complete."
    if ([Windows.MessageBox]::Show($window, $message, 'Check and confirm step', 'YesNo', 'Question') -ne 'Yes') { return }
    if (-not $script:Records.ContainsKey($Id)) { $script:Records[$Id] = @{} }
    $script:Records[$Id].Confirmed = $true
    $script:Records[$Id].ConfirmedAt = (Get-Date).ToString('o')
    Save-GuestState
    Write-GuestLog "Student confirmed: $($task.Title)."
    Refresh-GuestStatus
}

$Here = $PSScriptRoot
$StateFile = Join-Path $Here "ALFGuestConsole-$Role-State.json"
$script:Records = @{}
$script:Processes = @{}
$script:Cards = @{}
$stateWarning = ''
if (Test-Path -LiteralPath $StateFile) {
    try {
        $saved = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
        # Planning-only sizing changes keep the existing guest workflow/state schema.
        if ($saved.Role -ne $Role -or $saved.Version -notin @($ALFVersion, '2.0.7', '2.0.8', '2.0.9', '2.0.10', '2.0.11', '2.0.12', '2.0.13')) { throw 'State belongs to another role or release.' }
        foreach ($property in $saved.Steps.PSObject.Properties) {
            $record = @{}
            foreach ($field in $property.Value.PSObject.Properties) { $record[$field.Name] = $field.Value }
            $script:Records[$property.Name] = $record
            if ($record.ProcessId -and $record.ProcessStarted) {
                $process = Get-Process -Id $record.ProcessId -ErrorAction SilentlyContinue
                if ($process -and $process.StartTime.ToUniversalTime().ToString('o') -eq $record.ProcessStarted) {
                    $script:Processes[$property.Name] = $process
                }
            }
        }
    } catch {
        Write-Host "Cannot safely load console state: $($_.Exception.Message). Original state preserved: $StateFile" -ForegroundColor Red
        exit 1
    }
}
$Tasks = @(Get-GuestTasks $Role)
$roleTitle = @{ DC='Domain Controller'; Admin='Admin Station'; Node='Azure Local Node' }[$Role]
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="ALF Guest Console" Width="1300" Height="1000"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="15" Background="#F3F3F3">
  <DockPanel Margin="12">
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,8">
      <WrapPanel>
        <TextBlock Name="txtTitle" FontSize="22" FontWeight="SemiBold" Foreground="#0B5394"/>
        <Border Background="#0B5394" CornerRadius="4" Padding="8,2" Margin="12,4,0,4" VerticalAlignment="Center">
          <TextBlock Name="txtVersion" Foreground="White" FontWeight="SemiBold"/>
        </Border>
        <TextBlock Name="txtProgress" FontSize="16" Foreground="#444444" Margin="16,0,0,0" VerticalAlignment="Center" TextWrapping="Wrap"/>
      </WrapPanel>
      <TextBlock Name="txtMachine" Foreground="Gray" TextWrapping="Wrap" Margin="0,2,0,0"/>
      <Border Background="#FFF4CE" BorderBrush="#E0B000" BorderThickness="1" CornerRadius="4" Padding="10,6" Margin="0,8,0,0">
        <TextBlock Text="Run one step at a time on this guest. After a restart, reopen this console. Check and confirm each result before continuing. Closing a script successfully is NOT proof its configuration succeeded." TextWrapping="Wrap"/>
      </Border>
    </StackPanel>
    <Grid DockPanel.Dock="Bottom" Margin="0,10,0,0">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/><RowDefinition Height="170"/>
      </Grid.RowDefinitions>
      <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
        <Button Name="btnRefresh" Content="Refresh status" Width="150" Margin="0,0,8,0"/>
        <Button Name="btnFolder" Content="Open scripts folder" Width="175" Margin="0,0,8,0"/>
      </StackPanel>
      <TextBox Grid.Row="1" Name="txtLog" IsReadOnly="True" FontFamily="Consolas" FontSize="14"
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
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="50"/><ColumnDefinition Width="*"/><ColumnDefinition Width="250"/><ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <Border Grid.Column="0" Name="numBack" Width="34" Height="34" CornerRadius="17" Background="#0B5394" VerticalAlignment="Top">
      <TextBlock Name="num" Foreground="White" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <StackPanel Grid.Column="1" Margin="4,0,12,0">
      <TextBlock Name="title" FontSize="16" FontWeight="SemiBold" TextWrapping="Wrap"/>
      <TextBlock Name="why" FontWeight="SemiBold" TextWrapping="Wrap" Foreground="#444444" Margin="0,2,0,0"/>
      <TextBlock Name="learn" TextWrapping="Wrap" Foreground="#444444" Margin="0,4,0,0"/>
      <TextBlock Name="check" TextWrapping="Wrap" Foreground="#555555" Margin="0,6,0,0"/>
      <TextBlock Name="script" FontFamily="Consolas" FontSize="13" TextWrapping="Wrap" Foreground="Gray" Margin="0,4,0,0"/>
    </StackPanel>
    <StackPanel Grid.Column="2" VerticalAlignment="Center" Margin="0,0,8,0">
      <TextBlock Name="status" FontWeight="SemiBold" TextWrapping="Wrap"/>
      <TextBlock Name="statusDetail" Foreground="Gray" FontSize="13" TextWrapping="Wrap"/>
    </StackPanel>
    <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Center">
      <Button Name="run" Content="Run step" Width="125" Height="34" Margin="0,0,6,0" FontWeight="SemiBold"/>
      <Button Name="confirm" Content="Check and confirm" Width="155" Height="34"/>
    </StackPanel>
  </Grid>
</Border>
'@
$Brush = New-Object Windows.Media.BrushConverter
$Colors = @{
    Done      = $Brush.ConvertFromString("#107C10")
    NotDone   = $Brush.ConvertFromString("#605E5C")
    Attention = $Brush.ConvertFromString("#8A6100")
    Running   = $Brush.ConvertFromString("#0B5394")
    Failed    = $Brush.ConvertFromString("#A4262C")
}
try { $window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml)) }
catch { Write-Host "Graphical console could not create a window: $($_.Exception.Message). No configuration was run." -ForegroundColor Red; exit 1 }
$ui = @{}
$xaml.SelectNodes('//*[@Name]') | ForEach-Object { $ui[$_.Name] = $window.FindName($_.Name) }
$window.Title = "3. ALF Lab Builder - $roleTitle Console"
$ui.txtTitle.Text = "3. ALF Lab Builder - $roleTitle Console"
$ui.txtVersion.Text = "v$ALFVersion"
$ui.txtMachine.Text = "Role: $Role | THIS guest: $env:COMPUTERNAME | Scripts: $Here"
$count = 0
foreach ($task in $Tasks) {
    $count++
    $row = [Windows.Markup.XamlReader]::Parse($RowXaml)
    $card = @{}
    foreach ($name in 'numBack','num','title','why','learn','check','script','run','confirm','status','statusDetail') { $card[$name] = $row.FindName($name) }
    $card.num.Text = "$count"
    $card.title.Text = $task.Title
    $card.why.Text = "WHY: $($task.Why)"
    $card.learn.Text = $task.Learn
    $card.check.Text = "CHECK AFTERWARD: $($task.Check)"
    $card.script.Text = if ($task.Script) { "Script: $($task.Script) | Prerequisites: $($task.Needs -join ', ')" } else { 'Manual checkpoint - no configuration command is run' }
    $id = $task.Id
    $card.run.Add_Click({ Start-GuestStep $id }.GetNewClosure())
    $card.confirm.Add_Click({ Confirm-GuestStep $id }.GetNewClosure())
    $script:Cards[$id] = $card
    $ui.panelTasks.Children.Add($row) | Out-Null
}
$ui.btnRefresh.Add_Click({ Refresh-GuestStatus })
$ui.btnFolder.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$Here`"" })
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(3)
$timer.Add_Tick({ Refresh-GuestStatus })
$window.Add_Closing({
    param($sender, $e)
    if (@($script:Processes.Values | Where-Object { -not $_.HasExited }).Count) {
        if ([Windows.MessageBox]::Show($window, 'A step window is still running. Closing this console does not stop it. Close the console anyway?', 'Step still running', 'YesNo', 'Warning') -ne 'Yes') { $e.Cancel=$true }
    }
})
$work = [Windows.SystemParameters]::WorkArea
$window.Width = [Math]::Min($window.Width, $work.Width)
$window.Height = [Math]::Min($window.Height, $work.Height)
Write-GuestLog "Opened $roleTitle guide on $env:COMPUTERNAME. Confirm the role and read each step before running."
Refresh-GuestStatus
$timer.Start()
try { $window.ShowDialog() | Out-Null } finally { $timer.Stop() }
