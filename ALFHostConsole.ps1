##############################################################
# Version: ALF Lab Builder 2.1.0   (should match VERSION.txt - if this file was replaced on its own, check it is from the same release)
# ALFHostConsole.ps1   -   2. ALF Lab Builder - Host Console
# The Host Console: a window on the lab host (the Azure VM) that runs the host-side lab
# steps for you, shows which ones are done, and downloads the two install images with
# a progress bar.
#
# RUN ON: the Hyper-V host (Azure VM), from the folder with the rolled-out scripts (C:\ISO)
# START IT: double-click Launch-ALFHostConsole.cmd - it asks for administrator rights
#
# HOW IT WORKS
#   - Each step runs its numbered script in its own PowerShell window, so you can read the
#     output and answer the script's questions there. The console waits for it to finish.
#   - The status of each step is read from the host itself (is F: there, is Hyper-V installed,
#     does the VM exist), so it's right even if you ran a script by hand.
#   - The two images download inside the console with BITS, with a progress bar. A BITS
#     download carries on if you close the console - open it again to see the progress.
#     If BITS can't download, the console switches to a direct download.
#   - The image names and links come from 01.Host-PrepareDataDisk.ps1 - change them there.
#     The Azure Local release (2601-2611) is chosen in the Planning Console. An ISO already in
#     C:\ISO with Microsoft's full name for that release counts as downloaded.
#
# LEARN: BITS (Background Intelligent Transfer Service) is Windows' built-in download engine.
#        It resumes after network drops and keeps going in the background.
##############################################################

$ALFVersion = "2.1.0"

#Lab VM names - filled in by the Planning Console's "Roll out scripts"
$DCName            = "ContosoDC1"
$AdminStationName  = "{{AdminStationName}}"
$NodeNames         = @("{{NodeName1}}", "{{NodeName2}}")
$PlannedNodeNames  = @($NodeNames)
. (Join-Path $PSScriptRoot 'ALFNodeSettings.ps1')
$NodeSettingsFile  = Join-Path $PSScriptRoot 'ALFHostConsole-Nodes.json'
$NodeNames         = @(Get-ALFNodeNames $NodeSettingsFile $PlannedNodeNames)

#Host layout - must match the scripts
$NATSwitchName     = "InternalSwitchNAT"
$StorageSwitchName = "StorageSwitch"
$DataDrive         = "F"
$ExpectedFolder    = "C:\ISO"            #05 and 11 look for the scripts here
$GeneratedRoot     = "C:\ISO\Generated"  #11 writes each node's files here
$ImageScript       = "01.Host-PrepareDataDisk.ps1"   #image names and download links are read from here

#Smallest believable size for each image - anything smaller is an error page, not the image
$ServerVhdMinGB    = 5
$AzureLocalMinGB   = 3

####### End of variables ######################


#========== START AS ADMINISTRATOR, IN STA MODE ==========
#LEARN: Creating disks, switches and VMs needs administrator rights. WPF windows need a
#       single-threaded (STA) PowerShell. If either is missing, start again correctly.
$Principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$IsAdmin = $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
    return
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne "STA") {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module BitsTransfer -ErrorAction SilentlyContinue

$Here      = $PSScriptRoot
$StateFile = Join-Path $Here "ALFHostConsole-State.json"


#========== THE STEPS ==========
#Kind  : Script = runs a lab script in its own window,  Download = downloads an image in the console
#Needs : steps that should be done first (you're warned, not blocked)
$Tasks = @(
    [pscustomobject]@{ Id = "Disk";     Kind = "Script";   Script = "01.Host-PrepareDataDisk.ps1"; Args = "-DiskOnly"; Needs = @()
        Title = "Prepare the data disk"
        Text  = "Attempts the optional time-zone change (any unavailable ID falls back to Eastern Standard Time), brings the 1 TB data disk online as F: and creates C:\ISO and F:\VMs. Time-zone failures warn and do not stop disk preparation." }
    [pscustomobject]@{ Id = "ServerVhd"; Kind = "Download"; Script = ""; Args = ""; Needs = @()
        Title = "Download the Windows Server 2025 evaluation VHDX"
        Text  = "The disk image for the domain controller and the admin station. Saved to C:\ISO." }
    [pscustomobject]@{ Id = "AzureLocalIso"; Kind = "Download"; Script = ""; Args = ""; Needs = @()
        Title = "Download the Azure Local ISO"
        Text  = "The install image for the Azure Local nodes - release {{AzureLocalImageRelease}}, chosen in the Planning Console. Saved to C:\ISO. An ISO already there for the same release is used as is." }
    [pscustomobject]@{ Id = "HyperV";   Kind = "Script";   Script = "02.Host-InstallHyperV.ps1"; Args = ""; Needs = @()
        Title = "Install Hyper-V"
        Text  = "Installs the Hyper-V role and tools. The host restarts at the end (the script asks first) - start the console again after you sign back in." }
    [pscustomobject]@{ Id = "Switches"; Kind = "Script";   Script = "03.Host-CreateVMSwitches.ps1"; Args = ""; Needs = @("HyperV")
        Title = "Create the virtual switches"
        Text  = "InternalSwitchNAT (lab network with internet through NAT) and StorageSwitch (node-to-node storage)." }
    [pscustomobject]@{ Id = "DC";       Kind = "Script";   Script = "04dc.Host-CreateDCVM.ps1"; Args = ""; Needs = @("Disk", "ServerVhd", "Switches")
        Title = "Create the domain controller VM"
        Text  = "Creates $DCName with {{DCVcpus}} vCPUs / {{DCMemoryGB}} GB static RAM from the evaluation VHDX with Hyper-V Time Synchronization disabled. Then connect to it, finish Windows setup and sign in once." }
    [pscustomobject]@{ Id = "Admin";    Kind = "Script";   Script = "04adm.Host-CreateAdminStationVM.ps1"; Args = ""; Needs = @("Disk", "ServerVhd", "Switches")
        Title = "Create the admin station VM"
        Text  = "Creates $AdminStationName with {{AdminVcpus}} vCPUs / {{AdminMemoryGB}} GB static RAM from the evaluation VHDX with Hyper-V Time Synchronization disabled. Then connect to it, finish Windows setup and sign in once." }
    [pscustomobject]@{ Id = "Copy";     Kind = "Script";   Script = "05.Host-CopyScriptsToVM.ps1"; Args = ""; Needs = @("DC", "Admin")
        Title = "Copy the scripts into the DC and admin station"
        Text  = "Disables Hyper-V Time Synchronization on the DC/admin VMs and copies scripts and guided guest consoles into C:\ISO inside each VM. Adds an ALF DC Console or ALF Admin Console shortcut to local Administrator's desktop in the corresponding VM. After Windows setup, use the desktop shortcut or the matching launcher in C:\ISO." }
    [pscustomobject]@{ Id = "Nodes";    Kind = "Script";   Script = "10.Host-CreateNodeVMs.ps1"; Args = ""; Needs = @("Disk", "AzureLocalIso", "Switches")
        Title = "Create the Azure Local node VMs"
        Text  = "Creates $($NodeNames -join ' and ') with Hyper-V Time Synchronization disabled and starts them from the Azure Local ISO. Then install Azure Local on each node." }
    [pscustomobject]@{ Id = "Prepare";  Kind = "Script";   Script = "11.Host-PrepareNodes.ps1"; Args = ""; Needs = @("Nodes")
        Title = "Prepare the nodes"
        Text  = "Targets the VM names applied in step 9: $($NodeNames -join ' and '). Disables Hyper-V Time Synchronization on each selected VM. Copies into C:\ISO INSIDE each VM: 12.Node-Configure.ps1, 14.Node-ArcRegister.ps1, ALFGuestConsole.ps1, ALFGuestStepRunner.ps1, ALFGuestStatus.ps1, ALFGuestDisplay.ps1, Launch-ALFNodeConsole.cmd and AzureLocal-DeploymentTroubleshooter.ps1. The launcher opens the shared ALFGuestConsole in Node mode; there is no separate ALFNodeConsole.ps1. After guest copy verification, open C:\ISO\Launch-ALFNodeConsole.cmd in each VM (SConfig option 15)." }
)


#========== WINDOW LAYOUT ==========
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="2. ALF Lab Builder - Host Console" Height="1000" Width="1300"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="15" Background="#F3F3F3">
  <DockPanel Margin="12">

    <!-- Title -->
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,8">
      <StackPanel Orientation="Horizontal">
        <TextBlock FontSize="22" FontWeight="SemiBold" Foreground="#0B5394" Text="2. ALF Lab Builder - Host Console"/>
        <Border Background="#0B5394" CornerRadius="4" Padding="8,2" Margin="12,4,0,4" VerticalAlignment="Center">
          <TextBlock Name="txtVersion" Foreground="White" FontWeight="SemiBold" Text="v"/>
        </Border>
        <TextBlock Name="txtProgress" FontSize="16" Foreground="#444444" Margin="16,0,0,0" VerticalAlignment="Center"/>
      </StackPanel>
      <TextBlock Name="txtHost" Foreground="Gray" Margin="0,2,0,0"/>
      <Border Name="bannerWarn" Background="#FFF4CE" BorderBrush="#E0B000" BorderThickness="1" CornerRadius="4"
              Padding="10,6" Margin="0,8,0,0" Visibility="Collapsed">
        <TextBlock Name="txtWarn" TextWrapping="Wrap"/>
      </Border>
    </StackPanel>

    <!-- Bottom: buttons and log -->
    <Grid DockPanel.Dock="Bottom" Margin="0,10,0,0">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/><RowDefinition Height="170"/>
      </Grid.RowDefinitions>
      <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
        <Button Name="btnRefresh" Content="Refresh status"      Width="150" Margin="0,0,8,0"/>
        <Button Name="btnFolder"  Content="Open scripts folder" Width="175" Margin="0,0,8,0"/>
        <Button Name="btnHyperV"  Content="Hyper-V Manager"     Width="165" Margin="0,0,8,0"/>
      </StackPanel>
      <TextBox Grid.Row="1" Name="txtLog" IsReadOnly="True" FontFamily="Consolas" FontSize="14"
               VerticalScrollBarVisibility="Auto" TextWrapping="Wrap" Background="#FFFFFF"/>
    </Grid>

    <!-- Middle: one card per step -->
    <ScrollViewer VerticalScrollBarVisibility="Auto">
      <StackPanel Name="panelTasks"/>
    </ScrollViewer>

  </DockPanel>
</Window>
'@

#One card per step. Text is filled in from code, so titles never need XAML escaping.
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
      <TextBlock Name="desc" TextWrapping="Wrap" Foreground="#444444" Margin="0,2,0,0"/>
      <TextBlock Name="script" Foreground="Gray" FontFamily="Consolas" FontSize="13" Margin="0,2,0,0"/>
      <StackPanel Name="nodeOptions" Margin="0,8,0,0" Visibility="Collapsed">
        <TextBlock Text="Override the two planned node names on this host:" TextWrapping="Wrap"/>
        <WrapPanel Margin="0,4,0,0">
          <StackPanel Margin="0,0,10,0">
            <TextBlock Text="First node name"/>
            <TextBox Name="nodeName1" Width="185" MaxLength="15"/>
          </StackPanel>
          <StackPanel Margin="0,0,10,0">
            <TextBlock Text="Second node name"/>
            <TextBox Name="nodeName2" Width="185" MaxLength="15"/>
          </StackPanel>
          <Button Name="applyNodes" Content="Apply node names" Padding="10,4" VerticalAlignment="Bottom"/>
        </WrapPanel>
        <TextBlock Name="nodeSelection" TextWrapping="Wrap" Margin="0,4,0,0"/>
        <TextBlock Text="Both steps 9 and 10 use these names. First/second retain the planned IP order. Existing VMs are not renamed or deleted; the Planning Console plan is unchanged." TextWrapping="Wrap" Foreground="Gray" FontSize="13"/>
      </StackPanel>
      <Grid Name="prog" Margin="0,8,0,0" Visibility="Collapsed">
        <ProgressBar Name="bar" Height="22" Minimum="0" Maximum="100" Foreground="#0B5394"/>
        <TextBlock Name="pct" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="13" FontWeight="SemiBold"/>
      </Grid>
      <TextBlock Name="progText" Foreground="#444444" FontSize="13" Margin="0,2,0,0" Visibility="Collapsed"/>
    </StackPanel>
    <StackPanel Grid.Column="2" VerticalAlignment="Center">
      <TextBlock Name="status" FontWeight="SemiBold" TextWrapping="Wrap"/>
      <TextBlock Name="statusDetail" Foreground="Gray" FontSize="13" TextWrapping="Wrap"/>
    </StackPanel>
    <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Center">
      <Button Name="run" Width="125" Height="34" Margin="0,0,6,0" FontWeight="SemiBold"/>
      <Button Name="extra" Width="125" Height="34"/>
    </StackPanel>
  </Grid>
</Border>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
$xaml.SelectNodes("//*[@Name]") | ForEach-Object { $ui[$_.Name] = $window.FindName($_.Name) }

$Brush = New-Object Windows.Media.BrushConverter
$Colors = @{
    Done      = $Brush.ConvertFromString("#107C10")
    NotDone   = $Brush.ConvertFromString("#605E5C")
    Attention = $Brush.ConvertFromString("#8A6100")
    Running   = $Brush.ConvertFromString("#0B5394")
    Failed    = $Brush.ConvertFromString("#A4262C")
}
$StateText = @{ Done = "Done"; NotDone = "Not started"; Attention = "Needs attention"; Running = "Running"; Failed = "Last run failed" }


#========== HELPERS ==========
function Write-Log([string]$Text) {
    $ui.txtLog.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $Text`r`n")
    $ui.txtLog.ScrollToEnd()
}

function Get-Task([string]$Id) { $Tasks | Where-Object Id -eq $Id }

function Format-Duration([double]$Seconds) {
    if ($Seconds -lt 60)   { return "{0:N0} s" -f $Seconds }
    if ($Seconds -lt 3600) { return "{0:N0} min" -f ($Seconds / 60) }
    return "{0:N1} h" -f ($Seconds / 3600)
}

#Reads a setting such as $ServerVhd = "..." from a lab script, so names and links live in one place
function Get-ScriptSetting([string]$File, [string]$Name) {
    $path = Join-Path $Here $File
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $m = [regex]::Match((Get-Content -LiteralPath $path -Raw), '(?m)^\s*\$' + [regex]::Escape($Name) + '\s*=\s*"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-ImageInfo([string]$Id) {
    if ($Id -eq "ServerVhd") {
        return @{ Name = "Windows Server 2025 evaluation VHDX"; Type = "VHDX"; MinGB = $ServerVhdMinGB
                  Dest = Get-ScriptSetting $ImageScript "ServerVhd"; Url = Get-ScriptSetting $ImageScript "ServerVhdUrl"
                  Page = Get-ScriptSetting $ImageScript "ServerVhdPage" }
    }
    $release = Get-ScriptSetting $ImageScript "AzureLocalImageRelease"
    $info = @{ Name = "Azure Local ISO"; Type = "ISO"; MinGB = $AzureLocalMinGB; Release = $release; Problem = $null
               Dest = Get-ScriptSetting $ImageScript "AzureLocalIso"; Url = Get-ScriptSetting $ImageScript "AzureLocalIsoUrl"
               Page = Get-ScriptSetting $ImageScript "AzureLocalPage" }
    if ($info.Dest) {
        try {
            Test-ALFAzureLocalImageRelease $release
            $info.Dest = Resolve-ALFAzureLocalIso $info.Dest $release
        }
        catch { $info.Problem = $_.Exception.Message; $info.Dest = $null }
    }
    return $info
}

function Test-PendingNodeNames {
    $row = $script:Rows['Nodes']
    return ($row.nodeName1.Text.Trim() -cne $NodeNames[0] -or $row.nodeName2.Text.Trim() -cne $NodeNames[1])
}

function Update-NodeSelection {
    $row = $script:Rows['Nodes']
    $pending = Test-PendingNodeNames
    $row.nodeSelection.Text = if ($pending) {
        "Pending edits - click Apply node names. Currently applied: $($NodeNames -join ' and ')."
    } else { "Applied: $($NodeNames -join ' and ')." }
    $row.applyNodes.IsEnabled = -not $script:Running
    $row.nodeName1.IsEnabled = -not $script:Running
    $row.nodeName2.IsEnabled = -not $script:Running
    foreach ($id in 'Nodes', 'Prepare') {
        $script:Rows[$id].run.IsEnabled = (-not $script:Running -and -not $pending)
    }
}

function Set-HostNodeNames([string[]]$Names) {
    if ($script:Running) { throw 'Wait for the running host step to finish before changing node names.' }
    Test-ALFNodeNames $Names
    foreach ($name in $Names) {
        if ($name -ieq $DCName -or $name -ieq $AdminStationName -or $name -ieq $env:COMPUTERNAME) {
            throw "Node name '$name' conflicts with the DC, admin station or host."
        }
    }
    Save-ALFNodeNames $NodeSettingsFile $Names
    $script:NodeNames = @($Names)
    foreach ($id in 'Nodes', 'Prepare') { $script:RunState.Remove($id) }
    Save-RunState
    (Get-Task 'Nodes').Text = "Creates $($NodeNames -join ' and ') with Hyper-V Time Synchronization disabled and starts them from the Azure Local ISO. Then install Azure Local on each node."
    $script:Rows['Nodes'].desc.Text = (Get-Task 'Nodes').Text
    $prepare = Get-Task 'Prepare'
    $prepare.Text = "Targets the VM names applied in step 9: $($NodeNames -join ' and '). Disables Hyper-V Time Synchronization on each selected VM. Copies into C:\ISO INSIDE each VM: 12.Node-Configure.ps1, 14.Node-ArcRegister.ps1, ALFGuestConsole.ps1, ALFGuestStepRunner.ps1, ALFGuestStatus.ps1, ALFGuestDisplay.ps1, Launch-ALFNodeConsole.cmd and AzureLocal-DeploymentTroubleshooter.ps1. The launcher opens the shared ALFGuestConsole in Node mode; there is no separate ALFNodeConsole.ps1. After guest copy verification, open C:\ISO\Launch-ALFNodeConsole.cmd in each VM (SConfig option 15)."
    $script:Rows['Prepare'].desc.Text = $prepare.Text
}

function Apply-HostNodeNames {
    try {
        $row = $script:Rows['Nodes']
        Set-HostNodeNames @($row.nodeName1.Text.Trim(), $row.nodeName2.Text.Trim())
        Write-Log "Applied node names: $($NodeNames -join ' and '). Steps 9 and 10 now use this pair; existing VMs and the saved plan are unchanged."
        Update-AllStatus
    }
    catch { Write-Log "Node names not applied: $($_.Exception.Message)" }
    Update-Buttons
}

#Last run of each script step - kept in a small file beside the scripts
function Read-RunState {
    $state = @{}
    if (Test-Path -LiteralPath $StateFile) {
        try {
            $json = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) { $state[$p.Name] = @{ Time = $p.Value.Time; Result = $p.Value.Result; NodeNames = $p.Value.NodeNames } }
        }
        catch { }
    }
    return $state
}
function Save-RunState {
    try { $script:RunState | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StateFile -Encoding UTF8 }
    catch { Write-Log "Couldn't save $StateFile - $($_.Exception.Message)" }
}


#========== STATUS CHECKS ==========
#Each check looks at the host itself and returns State (Done / NotDone / Attention / Unknown) and Detail
function Get-TaskCheck($Task) {
    $hyperV = [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)
    switch ($Task.Id) {
        "Disk" {
            $vol = Get-Volume -DriveLetter $DataDrive -ErrorAction SilentlyContinue
            if ($vol -and (Test-Path "${DataDrive}:\VMs") -and (Test-Path "C:\ISO")) {
                return @{ State = "Done"; Detail = ("{0}: {1:N0} GB free" -f $DataDrive, ($vol.SizeRemaining / 1GB)) }
            }
            if ($vol) { return @{ State = "Attention"; Detail = "${DataDrive}: exists but the lab folders are missing - run it again" } }
            return @{ State = "NotDone"; Detail = "" }
        }
        { $_ -in "ServerVhd", "AzureLocalIso" } {
            $img = Get-ImageInfo $Task.Id
            if ($img.Problem) { return @{ State = "Attention"; Detail = $img.Problem } }
            if (-not $img.Dest) { return @{ State = "Attention"; Detail = "Image name not found in $ImageScript" } }
            if (Test-Path -LiteralPath $img.Dest -PathType Leaf) {
                return @{ State = "Done"; Detail = ("{0:N1} GB in {1}" -f ((Get-Item -LiteralPath $img.Dest).Length / 1GB), (Split-Path $img.Dest)) }
            }
            if (Test-Path -LiteralPath "$($img.Dest).download") { return @{ State = "Attention"; Detail = "Unfinished download - start it again" } }
            return @{ State = "NotDone"; Detail = "" }
        }
        "HyperV" {
            $f = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
            if (-not $f) { return @{ State = "Attention"; Detail = "Couldn't read the installed Windows features" } }
            if ("$($f.InstallState)" -eq "InstallPending") { return @{ State = "Attention"; Detail = "Restart the host to finish installing" } }
            if ($f.Installed) {
                $svc = Get-Service vmms -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -eq "Running") { return @{ State = "Done"; Detail = "Installed and running" } }
                return @{ State = "Attention"; Detail = "Installed - restart the host to finish" }
            }
            return @{ State = "NotDone"; Detail = "" }
        }
        "Switches" {
            if (-not $hyperV) { return @{ State = "NotDone"; Detail = "Needs Hyper-V" } }
            $found = @(@($NATSwitchName, $StorageSwitchName) | Where-Object { Get-VMSwitch -Name $_ -ErrorAction SilentlyContinue })
            $nat = Get-NetNat -ErrorAction SilentlyContinue
            if ($found.Count -eq 2 -and $nat) { return @{ State = "Done"; Detail = "$NATSwitchName, $StorageSwitchName and NAT" } }
            if ($found.Count -or $nat)         { return @{ State = "Attention"; Detail = "Partly created - run it again" } }
            return @{ State = "NotDone"; Detail = "" }
        }
        { $_ -in "DC", "Admin" } {
            if (-not $hyperV) { return @{ State = "NotDone"; Detail = "Needs Hyper-V" } }
            $name = if ($Task.Id -eq "DC") { $DCName } else { $AdminStationName }
            $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
            if ($vm) { return @{ State = "Done"; Detail = "$name - $($vm.State)" } }
            return @{ State = "NotDone"; Detail = "" }
        }
        "Nodes" {
            if (-not $hyperV) { return @{ State = "NotDone"; Detail = "Needs Hyper-V" } }
            $vms = @($NodeNames | ForEach-Object { Get-VM -Name $_ -ErrorAction SilentlyContinue })
            if ($vms.Count -eq $NodeNames.Count) { return @{ State = "Done"; Detail = (($vms | ForEach-Object { "$($_.Name) - $($_.State)" }) -join "`n") } }
            if ($vms.Count) { return @{ State = "Attention"; Detail = "$($vms.Count) of $($NodeNames.Count) node VMs found" } }
            return @{ State = "NotDone"; Detail = "" }
        }
        "Prepare" {
            $checks = @($NodeNames | ForEach-Object {
                $vm = if ($hyperV) { Get-VM -Name $_ -ErrorAction SilentlyContinue } else { $null }
                Get-ALFNodeDeliveryCheck $_ (Join-Path $GeneratedRoot $_) $Here "$($vm.Id)"
            })
            $state = if (@($checks | Where-Object State -ne 'Done').Count) { 'Attention' } else { 'Done' }
            return @{ State = $state; Detail = ($checks.Detail -join "`n") }
        }
        default { return @{ State = "Unknown"; Detail = "" } }
    }
}

#Shows a state on a card
function Set-RowState([string]$Id, [string]$State, [string]$Detail) {
    $row = $script:Rows[$Id]
    $row.status.Text = $StateText[$State]
    $row.status.Foreground = $Colors[$State]
    $row.statusDetail.Text = $Detail
    $row.numBack.Background = if ($State -eq "Done") { $Colors.Done } else { $Colors.Running }
    $script:Current[$Id] = $State
}

#Works out each step's status from the host, plus the last run where the host can't tell
function Update-AllStatus {
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    foreach ($t in $Tasks) {
        if ($script:Downloads.ContainsKey($t.Id)) { continue }                          #shown by the progress bar
        if ($script:Running -and $script:Running.Task.Id -eq $t.Id) { continue }       #shown as Running
        $check = Get-TaskCheck $t
        $last  = $script:RunState[$t.Id]
        if ($t.Id -in 'Nodes', 'Prepare' -and (@($last.NodeNames) -join '|') -cne ($NodeNames -join '|')) { $last = $null }
        $state = $check.State; $detail = $check.Detail
        if ($last -and $state -in "NotDone", "Unknown", "Attention") {
            if ($last.Result -eq "Failed")                           { $state = "Failed"; $detail = "Last run $($last.Time) - see its window. $detail" }
            elseif ($state -eq "Unknown" -and $last.Result -eq "OK") { $state = "Done";   $detail = "Last run $($last.Time)" }
        }
        if ($state -eq "Unknown") { $state = "NotDone" }
        Set-RowState $t.Id $state $detail
    }
    $done = @($Tasks | Where-Object { $script:Current[$_.Id] -eq "Done" }).Count
    $ui.txtProgress.Text = "$done of $($Tasks.Count) steps done"

    #Host summary line
    $cs  = Get-CimInstance Win32_ComputerSystem
    $c   = Get-Volume -DriveLetter C -ErrorAction SilentlyContinue
    $d   = Get-Volume -DriveLetter $DataDrive -ErrorAction SilentlyContinue
    $free = "C: {0:N0} GB free" -f ($c.SizeRemaining / 1GB)
    if ($d) { $free += ("   {0}: {1:N0} GB free" -f $DataDrive, ($d.SizeRemaining / 1GB)) }
    $ui.txtHost.Text = "$env:COMPUTERNAME   |   $($cs.NumberOfLogicalProcessors) logical processors   |   $([math]::Round($cs.TotalPhysicalMemory / 1GB)) GB memory   |   $free   |   Scripts: $Here"
    $window.Cursor = $null
}

#Enables the Run buttons when nothing is running (downloads can run alongside scripts)
function Update-Buttons {
    foreach ($t in $Tasks) {
        $row = $script:Rows[$t.Id]
        if ($t.Kind -eq "Download") {
            $row.run.Content   = if ($script:Downloads.ContainsKey($t.Id)) { "Cancel" } else { "Download" }
            $row.run.IsEnabled = $true
        }
        else {
            $row.run.Content   = "Run"
            $row.run.IsEnabled = -not $script:Running
        }
    }
    Update-NodeSelection
}


#========== RUN A LAB SCRIPT ==========
#LEARN: The script runs in its own PowerShell window (so you can answer its questions).
#       -EncodedCommand passes the wrapper without any quoting problems. The wrapper catches
#       errors, waits for Enter, and returns exit code 0 (finished) or 1 (stopped with an error).
function Start-LabScript($Task) {
    if ($Task.Id -in 'Nodes', 'Prepare' -and (Test-PendingNodeNames)) {
        Write-Log 'Click Apply node names before running either node step.'
        return
    }
    if ($script:Running) { Write-Log "Wait for $($script:Running.Task.Script) to finish first."; return }
    $path = Join-Path $Here $Task.Script
    if (-not (Test-Path -LiteralPath $path)) { Write-Log "Not found: $path - copy the rolled-out scripts into $Here"; return }

    #Warn about steps that aren't done yet
    $missing = @($Task.Needs | Where-Object { $script:Current[$_] -ne "Done" } | ForEach-Object { (Get-Task $_).Title })
    if ($missing.Count) {
        $answer = [System.Windows.MessageBox]::Show("These steps aren't done yet:`n`n  - $($missing -join "`n  - ")`n`nRun '$($Task.Title)' anyway?",
            "2. ALF Lab Builder - Host Console", "YesNo", "Warning")
        if ($answer -ne "Yes") { return }
    }

    $title  = "ALF step - $($Task.Script)" -replace "'", "''"
    $folder = $Here -replace "'", "''"
    $wrapper = @"
`$host.UI.RawUI.WindowTitle = '$title'
Set-Location -LiteralPath '$folder'
`$ok = `$true
try { & '.\$($Task.Script)' $($Task.Args) }
catch { `$ok = `$false; Write-Host ''; Write-Host ("ERROR: " + `$_.Exception.Message) -ForegroundColor Red }
Write-Host ''
if (`$ok) { Write-Host 'Finished.' -ForegroundColor Green } else { Write-Host 'Stopped with an error - see above.' -ForegroundColor Red }
Read-Host 'Press Enter to close this window and go back to the Host Console' | Out-Null
if (`$ok) { exit 0 } else { exit 1 }
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapper))
    $proc = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" -WorkingDirectory $Here -PassThru
    $null = $proc.Handle   #keeps the exit code readable after the window closes
    $script:Running = @{ Task = $Task; Process = $proc; Started = Get-Date }
    Set-RowState $Task.Id "Running" "In its own window - started $(Get-Date -Format 'HH:mm')"
    Write-Log "Started $($Task.Script) $($Task.Args) in a new window."
    Update-Buttons
}

function Watch-LabScript {
    $r = $script:Running
    if (-not $r -or -not $r.Process.HasExited) { return }
    $ok = ($r.Process.ExitCode -eq 0)
    $script:RunState[$r.Task.Id] = @{ Time = (Get-Date -Format "yyyy-MM-dd HH:mm"); Result = $(if ($ok) { "OK" } else { "Failed" }) }
    if ($r.Task.Id -in 'Nodes', 'Prepare') { $script:RunState[$r.Task.Id].NodeNames = @($NodeNames) }
    Save-RunState
    $mins = [math]::Round(((Get-Date) - $r.Started).TotalMinutes, 1)
    if ($ok) { Write-Log "$($r.Task.Script) finished ($mins min)." }
    else     { Write-Log "$($r.Task.Script) stopped with an error ($mins min) - the details were in its window." }
    $script:Running = $null
    Update-AllStatus
    Update-Buttons
}


#========== DOWNLOAD AN IMAGE ==========
function Show-DownloadUI([string]$Id, [bool]$Visible) {
    $row = $script:Rows[$Id]
    $v = if ($Visible) { "Visible" } else { "Collapsed" }
    $row.prog.Visibility = $v
    $row.progText.Visibility = $v
    if ($Visible) { $row.bar.Value = 0; $row.bar.IsIndeterminate = $true; $row.pct.Text = ""; $row.progText.Text = "Starting..." }
}

function Start-ImageDownload($Task) {
    $img = Get-ImageInfo $Task.Id
    if ($img.Problem) { Write-Log $img.Problem; return }
    if (-not $img.Dest) { Write-Log "No image name found in $ImageScript - is it in $Here?"; return }
    if ($img.Url -notmatch '^https://') {
        Write-Log "No download link set in $ImageScript for the $($img.Name) - opening the download page instead. Save the file as $($img.Dest)"
        if ($img.Page) { Start-Process $img.Page }
        return
    }
    if (Test-Path -LiteralPath $img.Dest) {
        $answer = [System.Windows.MessageBox]::Show("$($img.Dest) is already there.`n`nDelete it and download it again?", "2. ALF Lab Builder - Host Console", "YesNo", "Question")
        if ($answer -ne "Yes") { return }
        Remove-Item -LiteralPath $img.Dest -Force
    }
    $folder = Split-Path $img.Dest
    New-Item -Path $folder -ItemType Directory -Force | Out-Null
    $freeGB = (Get-Volume -DriveLetter $folder.Substring(0, 1)).SizeRemaining / 1GB
    if ($freeGB -lt ($img.MinGB * 3)) { Write-Log ("WARNING: only {0:N0} GB free on {1} - the download may not fit." -f $freeGB, $folder.Substring(0, 2)) }

    $temp = "$($img.Dest).download"
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    $dl = @{ Id = $Task.Id; Name = $img.Name; Type = $img.Type; Url = $img.Url; Dest = $img.Dest; Temp = $temp; MinGB = $img.MinGB
             LastBytes = [int64]0; LastTime = $null; Speed = 0.0; Started = Get-Date; TransientSince = $null }
    try {
        $job = Start-BitsTransfer -Source $img.Url -Destination $temp -Asynchronous -Priority Foreground -DisplayName "ALF: $($img.Name)" -ErrorAction Stop
        $dl.Mode = "BITS"; $dl.JobId = $job.JobId
        Write-Log "Downloading the $($img.Name) with BITS to $($img.Dest)"
    }
    catch {
        Write-Log "BITS couldn't start ($($_.Exception.Message)) - using a direct download instead."
        Start-DirectDownload $dl
    }
    $script:Downloads[$Task.Id] = $dl
    Show-DownloadUI $Task.Id $true
    Set-RowState $Task.Id "Running" "Downloading"
    Update-Buttons
}

#Fallback: download in a background runspace and report progress through a shared table
#LEARN: A runspace is a second PowerShell engine in the same process. The window stays
#       responsive because the download loop runs there, not on the window's thread.
function Start-DirectDownload($dl) {
    $sync = [hashtable]::Synchronized(@{ Bytes = [int64]0; Total = [int64]-1; Done = $false; Error = $null; Cancel = $false })
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($Url, $File, $Sync)
        $out = $null; $client = $null
        try {
            Add-Type -AssemblyName System.Net.Http
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $client = New-Object System.Net.Http.HttpClient
            $client.Timeout = [TimeSpan]::FromHours(12)
            $resp = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
            [void]$resp.EnsureSuccessStatusCode()
            if ($resp.Content.Headers.ContentLength) { $Sync.Total = [int64]$resp.Content.Headers.ContentLength }
            $stream = $resp.Content.ReadAsStreamAsync().Result
            $out = [IO.File]::Create($File)
            $buffer = New-Object byte[] 4194304
            while (($n = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                if ($Sync.Cancel) { $Sync.Error = "Cancelled"; break }
                $out.Write($buffer, 0, $n)
                $Sync.Bytes += $n
            }
            $stream.Dispose()
        }
        catch { $Sync.Error = $_.Exception.GetBaseException().Message }
        finally {
            if ($out) { $out.Dispose() }
            if ($client) { $client.Dispose() }
            $Sync.Done = $true
        }
    }).AddArgument($dl.Url).AddArgument($dl.Temp).AddArgument($sync)
    $dl.Mode = "Direct"; $dl.Sync = $sync; $dl.PS = $ps; $dl.Handle = $ps.BeginInvoke()
    $dl.LastBytes = [int64]0; $dl.LastTime = $null; $dl.Speed = 0.0
    Write-Log "Direct download of the $($dl.Name) started."
}

function Stop-ImageDownload([string]$Id, [string]$Reason) {
    $dl = $script:Downloads[$Id]
    if (-not $dl) { return }
    if ($dl.Mode -eq "BITS") {
        Get-BitsTransfer -JobId $dl.JobId -ErrorAction SilentlyContinue | Remove-BitsTransfer -ErrorAction SilentlyContinue
    }
    elseif ($dl.Sync) {
        $dl.Sync.Cancel = $true
        $deadline = (Get-Date).AddSeconds(10)
        while (-not $dl.Sync.Done -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        try { $dl.PS.Dispose() } catch { }
    }
    Remove-Item -LiteralPath $dl.Temp -Force -ErrorAction SilentlyContinue
    $script:Downloads.Remove($Id)
    Show-DownloadUI $Id $false
    Write-Log "$($dl.Name): $Reason"
    Update-AllStatus
    Update-Buttons
}

#Checks the finished file, puts it in place and makes sure it opens
function Complete-ImageDownload([string]$Id) {
    $dl = $script:Downloads[$Id]
    $sizeGB = [math]::Round((Get-Item -LiteralPath $dl.Temp).Length / 1GB, 1)
    if ($sizeGB -lt $dl.MinGB) {
        Remove-Item -LiteralPath $dl.Temp -Force -ErrorAction SilentlyContinue
        $script:Downloads.Remove($Id)
        Show-DownloadUI $Id $false
        Write-Log "$($dl.Name): the download is only $sizeGB GB, so it's a web page, not the image. The link in $ImageScript is probably wrong or expired - use 'Open page' to get the file or a fresh link."
        Set-RowState $Id "Failed" "Download too small - link wrong or expired"
        Update-Buttons
        return
    }
    Move-Item -LiteralPath $dl.Temp -Destination $dl.Dest -Force
    $mins = [math]::Round(((Get-Date) - $dl.Started).TotalMinutes, 1)
    Write-Log "$($dl.Name): downloaded $sizeGB GB in $mins min - $($dl.Dest)"

    #LEARN: Mounting the image read-only proves it isn't corrupt or half-downloaded.
    #       Mount-DiskImage works without Hyper-V, so this check works before step 4.
    try {
        if ($dl.Type -eq "ISO") {
            $m = Mount-DiskImage -ImagePath $dl.Dest -PassThru -ErrorAction Stop
            $label = ($m | Get-Volume).FileSystemLabel
            Dismount-DiskImage -ImagePath $dl.Dest | Out-Null
            Write-Log "$($dl.Name): the ISO opens correctly (label $label)."
        }
        else {
            $m = Mount-DiskImage -ImagePath $dl.Dest -Access ReadOnly -NoDriveLetter -PassThru -ErrorAction Stop
            $style = ($m | Get-Disk).PartitionStyle
            Dismount-DiskImage -ImagePath $dl.Dest | Out-Null
            Write-Log "$($dl.Name): the VHDX opens correctly (partition style $style)."
        }
    }
    catch { Write-Log "WARNING: $($dl.Name) downloaded but won't open ($($_.Exception.Message)) - download it again." }

    $script:Downloads.Remove($Id)
    Show-DownloadUI $Id $false
    Update-AllStatus
    Update-Buttons
}

#Called every second while a download runs: moves the progress bar
function Update-Download([string]$Id) {
    $dl = $script:Downloads[$Id]
    $row = $script:Rows[$Id]
    $done = [int64]0; $total = [int64]0; $note = ""

    if ($dl.Mode -eq "BITS") {
        $job = Get-BitsTransfer -JobId $dl.JobId -ErrorAction SilentlyContinue
        if (-not $job) { Stop-ImageDownload $Id "the BITS download disappeared - start it again."; return }
        $state = "$($job.JobState)"
        if ($state -eq "Transferred") { Complete-BitsTransfer -BitsJob $job; Complete-ImageDownload $Id; return }
        if ($state -eq "Error") {
            $why = "$($job.ErrorDescription)".Trim()
            Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dl.Temp -Force -ErrorAction SilentlyContinue
            Write-Log "$($dl.Name): BITS stopped ($why) - switching to a direct download."
            Start-DirectDownload $dl
            return
        }
        if ($state -eq "TransientError") {
            #BITS retries on its own. If it's still stuck after 2 minutes, switch to a direct download.
            if (-not $dl.TransientSince) { $dl.TransientSince = Get-Date }
            if (((Get-Date) - $dl.TransientSince).TotalSeconds -gt 120) {
                Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $dl.Temp -Force -ErrorAction SilentlyContinue
                Write-Log "$($dl.Name): BITS kept failing ($("$($job.ErrorDescription)".Trim())) - switching to a direct download."
                Start-DirectDownload $dl
                return
            }
            $note = "network problem - BITS is retrying"
        }
        else { $dl.TransientSince = $null }
        if ($state -eq "Suspended") { Resume-BitsTransfer -BitsJob $job -Asynchronous | Out-Null }
        if ($state -in "Queued", "Connecting") { $note = "connecting" }
        $done = [int64]$job.BytesTransferred
        if ($job.BytesTotal -ne [uint64]::MaxValue) { $total = [int64]$job.BytesTotal }
    }
    else {
        $s = $dl.Sync
        if ($s.Done) {
            try { $dl.PS.EndInvoke($dl.Handle); $dl.PS.Dispose() } catch { }
            if ($s.Error) {
                Remove-Item -LiteralPath $dl.Temp -Force -ErrorAction SilentlyContinue
                $script:Downloads.Remove($Id)
                Show-DownloadUI $Id $false
                Write-Log "$($dl.Name): the download failed ($($s.Error)). Try again, or use 'Open page' to download it in the browser and save it as $($dl.Dest)"
                Set-RowState $Id "Failed" "Download failed - see the log"
                Update-Buttons
            }
            else { Complete-ImageDownload $Id }
            return
        }
        $done = [int64]$s.Bytes
        if ($s.Total -gt 0) { $total = [int64]$s.Total }
    }

    #Speed (smoothed) and time left
    $now = Get-Date
    if ($dl.LastTime) {
        $secs = ($now - $dl.LastTime).TotalSeconds
        if ($secs -gt 0 -and $done -ge $dl.LastBytes) {
            $instant = ($done - $dl.LastBytes) / $secs
            $dl.Speed = if ($dl.Speed -gt 0) { 0.7 * $dl.Speed + 0.3 * $instant } else { $instant }
        }
    }
    $dl.LastTime = $now; $dl.LastBytes = $done

    $text = "{0:N2} GB" -f ($done / 1GB)
    if ($total -gt 0) {
        $percent = [math]::Min(100, 100.0 * $done / $total)
        $row.bar.IsIndeterminate = $false
        $row.bar.Value = $percent
        $row.pct.Text = "{0:N0} %" -f $percent
        $text += " of {0:N2} GB" -f ($total / 1GB)
        if ($dl.Speed -gt 0) { $text += "   -   about $(Format-Duration (($total - $done) / $dl.Speed)) left" }
    }
    else { $row.bar.IsIndeterminate = $true; $row.pct.Text = "" }
    if ($dl.Speed -gt 0) { $text += "   -   {0:N0} MB/s" -f ($dl.Speed / 1MB) }
    if ($dl.Mode -eq "Direct") { $text += "   -   direct download" }
    if ($note) { $text += "   -   $note" }
    $row.progText.Text = $text
}

#BITS downloads keep going when the console is closed - pick them up again when it opens
function Resume-ExistingDownloads {
    foreach ($t in ($Tasks | Where-Object Kind -eq "Download")) {
        $img = Get-ImageInfo $t.Id
        $job = Get-BitsTransfer -ErrorAction SilentlyContinue | Where-Object DisplayName -eq "ALF: $($img.Name)" | Select-Object -First 1
        if (-not $job -or -not $img.Dest) { continue }
        $script:Downloads[$t.Id] = @{ Id = $t.Id; Name = $img.Name; Type = $img.Type; Url = $img.Url; Dest = $img.Dest; Temp = "$($img.Dest).download"
                                      MinGB = $img.MinGB; Mode = "BITS"; JobId = $job.JobId; LastBytes = [int64]0; LastTime = $null; Speed = 0.0
                                      Started = $job.CreationTime; TransientSince = $null }
        Show-DownloadUI $t.Id $true
        Set-RowState $t.Id "Running" "Downloading"
        Write-Log "Picked up the BITS download of the $($img.Name) that was already running."
    }
}


#========== BUILD THE CARDS ==========
$script:Rows      = @{}
$script:Current   = @{}
$script:Downloads = @{}
$script:Running   = $null
$script:RunState  = Read-RunState

$step = 0
foreach ($t in $Tasks) {
    $step++
    $card = [Windows.Markup.XamlReader]::Parse($RowXaml)
    $row = @{}
    foreach ($n in "numBack", "num", "title", "desc", "script", "prog", "bar", "pct", "progText", "status", "statusDetail", "run", "extra", "nodeOptions", "nodeName1", "nodeName2", "applyNodes", "nodeSelection") { $row[$n] = $card.FindName($n) }
    $row.num.Text   = "$step"
    $row.title.Text = $t.Title
    $row.desc.Text  = $t.Text
    if ($t.Id -eq 'Nodes') {
        $row.nodeOptions.Visibility = 'Visible'
        $row.nodeName1.Text = $NodeNames[0]
        $row.nodeName2.Text = $NodeNames[1]
        $row.applyNodes.Add_Click({ Apply-HostNodeNames })
        $row.nodeName1.Add_TextChanged({ Update-NodeSelection })
        $row.nodeName2.Add_TextChanged({ Update-NodeSelection })
    }
    if ($t.Kind -eq "Script") {
        $row.script.Text   = ("{0} {1}" -f $t.Script, $t.Args).Trim()
        $row.extra.Content = "View script"
    }
    else {
        $img = Get-ImageInfo $t.Id
        $row.script.Text   = if ($img.Dest) { Split-Path $img.Dest -Leaf } elseif ($img.Problem) { "(release not set - see the Planning Console)" } else { "(name not found in $ImageScript)" }
        $row.extra.Content = "Open page"
    }
    $row.run.Tag = $t.Id
    $row.extra.Tag = $t.Id
    $row.run.Add_Click({ param($sender, $e) Invoke-RunButton $sender.Tag })
    $row.extra.Add_Click({ param($sender, $e) Invoke-ExtraButton $sender.Tag })
    $ui.panelTasks.Children.Add($card) | Out-Null
    $script:Rows[$t.Id] = $row
}

function Invoke-RunButton([string]$Id) {
    $t = Get-Task $Id
    if ($t.Kind -eq "Download") {
        if ($script:Downloads.ContainsKey($Id)) {
            $answer = [System.Windows.MessageBox]::Show("Stop downloading the $((Get-ImageInfo $Id).Name)?", "2. ALF Lab Builder - Host Console", "YesNo", "Question")
            if ($answer -eq "Yes") { Stop-ImageDownload $Id "download cancelled." }
        }
        else { Start-ImageDownload $t }
    }
    else { Start-LabScript $t }
}

function Invoke-ExtraButton([string]$Id) {
    $t = Get-Task $Id
    if ($t.Kind -eq "Download") {
        $img = Get-ImageInfo $Id
        if ($img.Problem) { Write-Log $img.Problem }
        elseif ($img.Page) { Start-Process $img.Page; Write-Log "Opened the $($img.Name) download page. A file you download yourself goes in C:\ISO as $(Split-Path $img.Dest -Leaf)" }
    }
    else {
        $path = Join-Path $Here $t.Script
        if (Test-Path -LiteralPath $path) { Start-Process notepad.exe "`"$path`"" } else { Write-Log "Not found: $path" }
    }
}


#========== CHECKS WHEN THE CONSOLE OPENS ==========
function Test-ConsoleSetup {
    $warn = @()
    if ("$AdminStationName $NodeNames" -match '\{\{') {
        $warn += "This copy of the console hasn't been rolled out by the Planning Console, so the VM names are missing. In the Planning Console use 'Roll out scripts', then copy the Rollout folder to $ExpectedFolder."
    }
    if ($Here.TrimEnd('\') -ne $ExpectedFolder) {
        $warn += "The console is running from $Here. Scripts 05 and 11 look for the lab files in $ExpectedFolder - copy everything into $ExpectedFolder and start the console from there."
    }
    #Every lab file carries a version stamp - flag scripts from a different release
    foreach ($t in ($Tasks | Where-Object Kind -eq "Script")) {
        $path = Join-Path $Here $t.Script
        if (-not (Test-Path -LiteralPath $path)) { $warn += "Missing: $($t.Script)"; continue }
        $text = Get-Content -LiteralPath $path -Raw
        if ($text -match '(?m)^# Version: ALF Lab Builder (\S+)') {
            if ($Matches[1] -ne $ALFVersion) { $warn += "$($t.Script) is from version $($Matches[1]); this console is version $ALFVersion." }
        }
        else { $warn += "$($t.Script) has no version stamp - it may be from an older release." }
        if ($text -match '\{\{[A-Za-z0-9_]+\}\}') { $warn += "$($t.Script) still has {{...}} placeholders - roll it out with the Planning Console." }
    }
    foreach ($w in $warn) { Write-Log "WARNING: $w" }
    if ($warn.Count) {
        $ui.txtWarn.Text = ($warn -join "`n")
        $ui.bannerWarn.Visibility = "Visible"
    }
}


#========== BUTTONS AND TIMER ==========
$ui.btnRefresh.Add_Click({ Update-AllStatus; Write-Log "Status refreshed." })
$ui.btnFolder.Add_Click({ Start-Process explorer.exe "`"$Here`"" })
$ui.btnHyperV.Add_Click({
    if (Get-Command Get-VM -ErrorAction SilentlyContinue) { Start-Process virtmgmt.msc } else { Write-Log "Hyper-V Manager isn't installed yet - that's step 4." }
})

#Every second: watch the running script and move the download progress bars
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    try {
        Watch-LabScript
        foreach ($id in @($script:Downloads.Keys)) { Update-Download $id }
    }
    catch { Write-Log "Error: $($_.Exception.Message)" }
})

$window.Add_Closing({
    param($sender, $e)
    $direct = @($script:Downloads.Values | Where-Object Mode -eq "Direct")
    if ($direct.Count) {
        $answer = [System.Windows.MessageBox]::Show("Closing the console stops the direct download of the $($direct[0].Name). Close anyway?",
            "2. ALF Lab Builder - Host Console", "YesNo", "Warning")
        if ($answer -ne "Yes") { $e.Cancel = $true; return }
        foreach ($d in $direct) { $d.Sync.Cancel = $true }
    }
    $timer.Stop()
})


#========== START ==========
$ui.txtVersion.Text = "Version $ALFVersion"
$window.Title = "2. ALF Lab Builder - Host Console  (v$ALFVersion)  -  $env:COMPUTERNAME"
$work = [System.Windows.SystemParameters]::WorkArea
if ($window.Width  -gt $work.Width)  { $window.Width  = $work.Width }
if ($window.Height -gt $work.Height) { $window.Height = $work.Height }

Write-Log "2. ALF Lab Builder - Host Console $ALFVersion on $env:COMPUTERNAME - scripts in $Here"
Test-ConsoleSetup
Resume-ExistingDownloads
Update-AllStatus
Update-Buttons
Write-Log "Each Run opens the script in its own PowerShell window - answer its questions there. The downloads run here."
$timer.Start()
$window.ShowDialog() | Out-Null
