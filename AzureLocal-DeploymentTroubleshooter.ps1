#requires -Version 5.1
# Version: ALF Lab Builder 2.0.23
# Delivered to each node by step 10 and opened from the Node Console. Read-only.
<#
.SYNOPSIS
    Read-only Azure Local deployment troubleshooting console.
.DESCRIPTION
    Presents the deployment-progress checks discussed during troubleshooting as
    buttons in a Windows Forms interface. Commands run only on the local node.

    This tool intentionally contains no restart, reboot, feature-installation,
    remediation, or deployment-resume actions.

.NOTES
    Run from an elevated Windows PowerShell 5.1 console in an interactive local
    session (physical console, crash cart, or BMC/iDRAC/iLO/KVM console).
    A GUI launched inside WinRM, PowerShell remoting, or SSH is not displayed on
    the administrator's workstation.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------- Check catalog ----------------------------
$script:Catalog = @()

function Add-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Why,
        [Parameter(Mandatory = $true)][string]$When,
        [Parameter(Mandatory = $true)][string]$LookFor,
        [Parameter(Mandatory = $true)][string]$Command,
        [switch]$Core
    )

    $script:Catalog += [pscustomobject]@{
        Category = $Category
        Name      = $Name
        Why       = $Why
        When      = $When
        LookFor   = $LookFor
        Command   = $Command.Trim()
        Core      = [bool]$Core
    }
}

Add-Check -Category 'Deployment logs' -Name 'Recent CloudDeployment log files' -Core -Why 'Shows which deployment logs are changing most recently. Fresh timestamps or increasing file sizes are direct evidence that the orchestrator is still producing activity.' -When 'Use first whenever the portal appears stuck, then repeat or monitor it to see whether timestamps and sizes continue to move.' -LookFor 'New LastWriteTime values, changing Length values, and files associated with the currently displayed deployment operation.' -Command @'
Get-ChildItem 'C:\CloudDeployment\Logs' -Recurse -File -ErrorAction Stop |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 20 FullName, LastWriteTime, Length |
    Format-Table -AutoSize
'@

Add-Check -Category 'Deployment logs' -Name 'Tail newest CloudDeployment log' -Why 'Opens the newest deployment log without requiring you to type or copy its full path.' -When 'Use after the recent-files check identifies active logging and you want to see what operation is executing now.' -LookFor 'A new operation name, retry counters, task-queue messages, exceptions, or a final success/failure record. Informational warnings about unapproved PowerShell verbs are usually not failures.' -Command @'
$latest = Get-ChildItem 'C:\CloudDeployment\Logs' -Recurse -File -ErrorAction Stop |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

$latest | Format-List FullName, LastWriteTime, Length
if ($null -ne $latest) {
    "`r`n--- Last 200 lines ---"
    Get-Content -LiteralPath $latest.FullName -Tail 200 -ErrorAction Stop
}
'@

Add-Check -Category 'Deployment logs' -Name 'Scan recent deployment logs for failures' -Why 'Searches the 20 most recently modified CloudDeployment logs for common failure terms so you can focus on the first underlying exception rather than a later timeout.' -When 'Use when progress has stopped, the portal reports failure, or a retry is repeating without an obvious reason.' -LookFor 'The earliest meaningful Error, Exception, Failed, HRESULT, or Timeout near the start of the failing operation. Verify context because some logs mention old or handled errors.' -Command @'
$files = Get-ChildItem 'C:\CloudDeployment\Logs' -Recurse -File -ErrorAction Stop |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 20

$files | Select-String -Pattern 'error','exception','failed','HRESULT','timeout' |
    Select-Object Path, LineNumber, Line |
    Format-Table -Wrap
'@

Add-Check -Category 'Deployment logs' -Name 'Compare log activity over 30 seconds' -Why 'Takes two snapshots and calculates which recent log files changed. This turns a vague portal stall into a measurable activity check.' -When 'Use when you need stronger evidence of progress than a single timestamp. The interface remains responsive while this 30-second check runs.' -LookFor 'Changed=True, a positive SizeDelta, or a newer LastWriteTime. No change is a reason to inspect the orchestrator and servicing state; it is not proof by itself that deployment failed.' -Command @'
function Get-CloudDeploymentSnapshot {
    Get-ChildItem 'C:\CloudDeployment\Logs' -Recurse -File -ErrorAction Stop |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 20 FullName, LastWriteTime, Length
}

$before = @(Get-CloudDeploymentSnapshot)
Start-Sleep -Seconds 30
$after = @(Get-CloudDeploymentSnapshot)

$comparison = foreach ($item in $after) {
    $old = $before | Where-Object FullName -eq $item.FullName | Select-Object -First 1
    [pscustomobject]@{
        File          = $item.FullName
        Changed       = ($null -eq $old -or $item.LastWriteTime -ne $old.LastWriteTime -or $item.Length -ne $old.Length)
        SizeDelta     = if ($null -eq $old) { $item.Length } else { $item.Length - $old.Length }
        LastWriteTime = $item.LastWriteTime
    }
}
$comparison | Sort-Object Changed, LastWriteTime -Descending | Format-Table -AutoSize
'@

Add-Check -Category 'Orchestrator' -Name 'LCMController service status' -Core -Why 'Checks the Azure Local lifecycle/deployment controller service that participates in deployment execution.' -When 'Use when deployment logs stop changing or portal state no longer matches activity on the node.' -LookFor 'Status=Running and the expected startup type. A stopped service is important evidence to capture, but this tool deliberately does not restart it.' -Command @'
Get-Service -Name LCMController -ErrorAction Stop |
    Format-List Name, DisplayName, Status, StartType
'@

Add-Check -Category 'Orchestrator' -Name 'Deployment scheduled task state' -Core -Why 'Checks whether the LCMAzureStackDeploy scheduled task exists and whether Windows reports it as Ready, Running, or Disabled.' -When 'Use with the LCMController check when the workflow looks disconnected from the status shown in Azure.' -LookFor 'A present task and a plausible state. Running can indicate current execution; Ready can be normal between invocations. Missing or Disabled needs investigation.' -Command @'
Get-ScheduledTask -TaskName LCMAzureStackDeploy -ErrorAction Stop |
    Select-Object TaskName, TaskPath, State |
    Format-Table -AutoSize
'@

Add-Check -Category 'Orchestrator' -Name 'Deployment scheduled task execution info' -Core -Why 'Shows the scheduled task last-run time, last result, next run, and missed-run count.' -When 'Use after checking task state to determine whether it ran recently and whether Windows recorded a task-level failure.' -LookFor 'Recent LastRunTime and LastTaskResult. A nonzero result requires interpretation; capture the value and correlate it with deployment logs before making changes.' -Command @'
Get-ScheduledTaskInfo -TaskName LCMAzureStackDeploy -ErrorAction Stop |
    Format-List *
'@

Add-Check -Category 'OpenSSH and servicing' -Name 'OpenSSH Client capability state' -Core -Why 'Confirms whether the Windows OpenSSH Client capability that appears in the deployment operation is installed, absent, or in another servicing state.' -When 'Use when the portal or deployment log is at Install OpenSSH Client.' -LookFor 'State=Installed means the capability is present; NotPresent means installation has not completed or may not have started. Do not manually install it while the deployment orchestrator is active.' -Command @'
Get-WindowsCapability -Online -Name 'OpenSSH.Client*' -ErrorAction Stop |
    Format-List Name, State, DisplayName, Description
'@

Add-Check -Category 'OpenSSH and servicing' -Name 'DISM log tail' -Why 'Shows recent Windows capability servicing activity from DISM, which can reveal the operation and HRESULT behind an OpenSSH installation problem.' -When 'Use if OpenSSH is not installed, DISM is running for a long time, or the deployment log reports a capability-installation failure.' -LookFor 'OpenSSH.Client, Add-Capability, Failed, HRESULT, source/download errors, or a successful completion near the end.' -Command @'
Get-Content 'C:\Windows\Logs\DISM\dism.log' -Tail 200 -ErrorAction Stop
'@

Add-Check -Category 'OpenSSH and servicing' -Name 'CBS log tail' -Why 'Shows recent Component-Based Servicing activity, which is often the deeper source of Windows capability installation results.' -When 'Use with the DISM log when servicing appears active, slow, or failed.' -LookFor 'OpenSSH.Client, failure/error codes, source resolution, pending operations, and completion records. CBS is verbose, so correlate timestamps with deployment activity.' -Command @'
Get-Content 'C:\Windows\Logs\CBS\CBS.log' -Tail 200 -ErrorAction Stop
'@

Add-Check -Category 'OpenSSH and servicing' -Name 'Find OpenSSH evidence in servicing logs' -Why 'Filters recent CBS and DISM content to the terms most relevant to the currently observed Install OpenSSH Client operation.' -When 'Use when full log tails are too noisy or the deployment has been sitting at OpenSSH for an extended period.' -LookFor 'The most recent OpenSSH.Client/Add-Capability line and any adjacent Failed or HRESULT entry. A mention alone does not mean failure.' -Command @'
$paths = 'C:\Windows\Logs\DISM\dism.log','C:\Windows\Logs\CBS\CBS.log'
foreach ($path in $paths) {
    "`r`n=== $path ==="
    Get-Content -LiteralPath $path -Tail 3000 -ErrorAction Stop |
        Select-String -Pattern 'OpenSSH.Client','Add-Capability','Failed','HRESULT' |
        Select-Object -Last 100
}
'@

Add-Check -Category 'OpenSSH and servicing' -Name 'Servicing process activity' -Core -Why 'Shows PowerShell and Windows servicing processes involved in orchestration or capability installation, including cumulative CPU and start time.' -When 'Use twice several minutes apart when you need to determine whether the process is still doing work.' -LookFor 'A relevant process that remains present and whose cumulative CPU increases between runs. No process may mean the operation has not started, already finished, or stopped.' -Command @'
Get-Process powershell,TiWorker,TrustedInstaller,dism,dismhost -ErrorAction SilentlyContinue |
    Select-Object ProcessName, Id, CPU, StartTime |
    Sort-Object ProcessName, Id |
    Format-Table -AutoSize
'@

Add-Check -Category 'OpenSSH and servicing' -Name 'Windows servicing service status' -Core -Why 'Checks TrustedInstaller, Windows Update, and BITS, which may participate in capability installation and content retrieval.' -When 'Use when DISM/CBS indicates a source or servicing issue, or when no servicing progress is visible.' -LookFor 'Status and StartType. These services can start on demand, so Stopped by itself is not proof of a fault; correlate it with logs and active processes.' -Command @'
Get-Service TrustedInstaller,wuauserv,bits -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType |
    Format-Table -AutoSize
'@

Add-Check -Category 'OpenSSH and servicing' -Name 'PackageManagement provider inventory' -Why 'Shows installed PackageManagement modules and providers. This is useful because the observed deployment log was repeatedly acquiring providers from PackageManagement 1.4.8.1.' -When 'Use only when the newest deployment log remains at Acquiring providers for assembly without later entries or other evidence of work.' -LookFor 'PackageManagement module/provider versions and whether provider discovery itself returns an error or hangs. Inventory differences are clues, not instructions to update packages during deployment.' -Command @'
'--- PackageManagement modules ---'
Get-Module PackageManagement -ListAvailable |
    Select-Object Name, Version, Path |
    Sort-Object Version -Descending |
    Format-Table -AutoSize

'--- Package providers ---'
Get-PackageProvider -ListAvailable -ErrorAction Continue |
    Select-Object Name, Version, ProviderPath |
    Format-Table -AutoSize
'@

Add-Check -Category 'Additional logs' -Name 'Recent MASLogs files' -Core -Why 'Finds the most recently modified files under MASLogs, where additional Azure Local lifecycle and deployment diagnostics may be written.' -When 'Use when CloudDeployment logs identify a component but do not contain the underlying detail, or when preparing evidence for support.' -LookFor 'Recent controller, deployment exception, validation, or component-specific files whose timestamps match the issue.' -Command @'
Get-ChildItem 'C:\MASLogs' -Recurse -File -ErrorAction Stop |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 20 FullName, LastWriteTime, Length |
    Format-Table -AutoSize
'@

Add-Check -Category 'Node context' -Name 'Domain membership' -Core -Why 'Confirms whether the local node is joined to the expected domain. A change from workgroup to domain membership is evidence that deployment completed at least part of the configuration workflow.' -When 'Use when domain membership is a deployment milestone or differs from an earlier observation.' -LookFor 'PartOfDomain=True and the expected Domain value. This proves a configuration milestone, but not that the current operation is still advancing.' -Command @'
Get-CimInstance Win32_ComputerSystem -ErrorAction Stop |
    Select-Object Name, Domain, PartOfDomain |
    Format-Table -AutoSize
'@

Add-Check -Category 'Node context' -Name 'Node time and uptime' -Core -Why 'Provides the local clock, boot time, and uptime needed to correlate node state with Azure and log timestamps.' -When 'Use in a core snapshot or when timestamps seem inconsistent, especially after a possible reboot.' -LookFor 'Unexpected recent boot time or a clock/time-zone mismatch that could make log ordering misleading.' -Command @'
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
[pscustomobject]@{
    ComputerName = $env:COMPUTERNAME
    LocalTime    = Get-Date
    TimeZone     = (Get-TimeZone).Id
    LastBootTime = $os.LastBootUpTime
    Uptime       = (Get-Date) - $os.LastBootUpTime
} | Format-List
'@

# ---------------------------- UI helpers ----------------------------
$script:SelectedCheck = $null
$script:CurrentPowerShell = $null
$script:CurrentAsync = $null
$script:CurrentLabel = $null
$script:MonitorEnabled = $false
$script:MonitorCheck = $null

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-UiBusy {
    param([bool]$Busy)
    $runButton.Enabled = -not $Busy
    $coreButton.Enabled = -not $Busy
    $stopButton.Enabled = $Busy
    $progressBar.Style = if ($Busy) { 'Marquee' } else { 'Blocks' }
    if (-not $Busy) { $progressBar.Value = 0 }
}

function Add-OutputText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { $Text = '(Command returned no output.)' }
    $outputBox.AppendText($Text)
    if (-not $Text.EndsWith("`r`n")) { $outputBox.AppendText("`r`n") }
    $outputBox.SelectionStart = $outputBox.TextLength
    $outputBox.ScrollToCaret()
}

function Start-CheckScript {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$ScriptText
    )

    if ($null -ne $script:CurrentAsync) {
        [System.Windows.Forms.MessageBox]::Show('A check is already running. Stop it or wait for it to finish.', 'Azure Local Deployment Troubleshooter', 'OK', 'Information') | Out-Null
        return
    }

    $header = "`r`n======================================================================`r`n[{0}] {1}`r`nHost: {2}`r`n======================================================================`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'), $Label, $env:COMPUTERNAME
    Add-OutputText $header
    $statusLabel.Text = "Running: $Label"
    Set-UiBusy $true

    try {
        $script:CurrentPowerShell = [PowerShell]::Create()
        [void]$script:CurrentPowerShell.AddScript($ScriptText)
        $script:CurrentLabel = $Label
        $script:CurrentAsync = $script:CurrentPowerShell.BeginInvoke()
    }
    catch {
        Add-OutputText ("Could not start command: {0}" -f $_.Exception.Message)
        if ($null -ne $script:CurrentPowerShell) { $script:CurrentPowerShell.Dispose() }
        $script:CurrentPowerShell = $null
        $script:CurrentAsync = $null
        $script:CurrentLabel = $null
        $statusLabel.Text = 'Ready'
        Set-UiBusy $false
    }
}

function Complete-CurrentScript {
    try {
        $results = $script:CurrentPowerShell.EndInvoke($script:CurrentAsync)
        $text = ($results | Out-String -Width 300)
        Add-OutputText $text

        if ($script:CurrentPowerShell.Streams.Warning.Count -gt 0) {
            Add-OutputText "--- Warnings ---"
            Add-OutputText (($script:CurrentPowerShell.Streams.Warning | ForEach-Object { $_.ToString() }) -join "`r`n")
        }
        if ($script:CurrentPowerShell.Streams.Error.Count -gt 0) {
            Add-OutputText "--- Errors ---"
            Add-OutputText (($script:CurrentPowerShell.Streams.Error | ForEach-Object { $_.ToString() }) -join "`r`n")
        }
        $statusLabel.Text = "Completed: $($script:CurrentLabel)"
    }
    catch [System.Management.Automation.PipelineStoppedException] {
        Add-OutputText 'Command stopped by operator.'
        $statusLabel.Text = 'Stopped'
    }
    catch {
        Add-OutputText ("Command failed: {0}" -f $_.Exception.Message)
        $statusLabel.Text = 'Failed'
    }
    finally {
        if ($null -ne $script:CurrentPowerShell) { $script:CurrentPowerShell.Dispose() }
        $script:CurrentPowerShell = $null
        $script:CurrentAsync = $null
        $script:CurrentLabel = $null
        Set-UiBusy $false
    }
}

function Build-CoreScript {
    $builder = New-Object System.Text.StringBuilder
    foreach ($check in @($script:Catalog | Where-Object Core)) {
        [void]$builder.AppendLine("'`r`n### $($check.Name) ###'")
        [void]$builder.AppendLine('& {')
        [void]$builder.AppendLine($check.Command)
        [void]$builder.AppendLine('} 2>&1 | Out-String -Width 300')
    }
    return $builder.ToString()
}

# ---------------------------- Form ----------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Azure Local Deployment Troubleshooter (Read-only)'
$form.StartPosition = 'CenterScreen'
# Node VMs often run at 1024 x 768, so never open larger than the visible desktop.
$workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Size = New-Object System.Drawing.Size([Math]::Min(1280, $workArea.Width), [Math]::Min(860, $workArea.Height))
$form.MinimumSize = New-Object System.Drawing.Size([Math]::Min(1050, $workArea.Width), [Math]::Min(700, $workArea.Height))
$form.AutoScaleMode = 'Dpi'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$main = New-Object System.Windows.Forms.TableLayoutPanel
$main.Dock = 'Fill'
$main.ColumnCount = 1
$main.RowCount = 4
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 70)))
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 48)))
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 52)))
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 54)))
$form.Controls.Add($main)

$banner = New-Object System.Windows.Forms.Panel
$banner.Dock = 'Fill'
$banner.BackColor = [System.Drawing.Color]::FromArgb(0, 90, 158)
$main.Controls.Add($banner, 0, 0)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'Azure Local Deployment Troubleshooter'
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point(16, 10)
$banner.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = 'Read-only progress and evidence checks for the local node - no restart, install, reboot, or remediation actions'
$subtitleLabel.ForeColor = [System.Drawing.Color]::White
$subtitleLabel.AutoSize = $true
$subtitleLabel.Location = New-Object System.Drawing.Point(18, 43)
$banner.Controls.Add($subtitleLabel)

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.Orientation = 'Vertical'
$split.SplitterDistance = 355
$split.Panel1MinSize = 275
$split.Panel2MinSize = 550
$main.Controls.Add($split, 0, 1)

$tree = New-Object System.Windows.Forms.TreeView
$tree.Dock = 'Fill'
$tree.HideSelection = $false
$tree.FullRowSelect = $true
$tree.ShowLines = $true
$split.Panel1.Controls.Add($tree)

$detailTabs = New-Object System.Windows.Forms.TabControl
$detailTabs.Dock = 'Fill'
$split.Panel2.Controls.Add($detailTabs)

$detailsTab = New-Object System.Windows.Forms.TabPage
$detailsTab.Text = 'Why / When / Interpretation'
$detailTabs.TabPages.Add($detailsTab)

$detailsBox = New-Object System.Windows.Forms.RichTextBox
$detailsBox.Dock = 'Fill'
$detailsBox.ReadOnly = $true
$detailsBox.BackColor = [System.Drawing.Color]::White
$detailsBox.BorderStyle = 'None'
$detailsBox.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$detailsTab.Controls.Add($detailsBox)

$commandTab = New-Object System.Windows.Forms.TabPage
$commandTab.Text = 'PowerShell command'
$detailTabs.TabPages.Add($commandTab)

$commandBox = New-Object System.Windows.Forms.RichTextBox
$commandBox.Dock = 'Fill'
$commandBox.ReadOnly = $true
$commandBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$commandBox.ForeColor = [System.Drawing.Color]::Gainsboro
$commandBox.Font = New-Object System.Drawing.Font('Consolas', 10)
$commandBox.WordWrap = $false
$commandTab.Controls.Add($commandBox)

$outputGroup = New-Object System.Windows.Forms.GroupBox
$outputGroup.Text = 'Session output'
$outputGroup.Dock = 'Fill'
$main.Controls.Add($outputGroup, 0, 2)

$outputBox = New-Object System.Windows.Forms.RichTextBox
$outputBox.Dock = 'Fill'
$outputBox.ReadOnly = $true
$outputBox.BackColor = [System.Drawing.Color]::FromArgb(15, 15, 15)
$outputBox.ForeColor = [System.Drawing.Color]::Gainsboro
$outputBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$outputBox.WordWrap = $false
$outputBox.DetectUrls = $false
$outputGroup.Controls.Add($outputBox)

$footer = New-Object System.Windows.Forms.TableLayoutPanel
$footer.Dock = 'Fill'
$footer.ColumnCount = 8
$footer.RowCount = 2
$footer.Padding = New-Object System.Windows.Forms.Padding(6, 4, 6, 2)
[void]$footer.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 30)))
[void]$footer.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 17)))
[void]$footer.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$footer.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$footer.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$footer.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$footer.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$footer.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$footer.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$footer.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 170)))
$main.Controls.Add($footer, 0, 3)

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = 'Run selected'
$runButton.AutoSize = $true
$footer.Controls.Add($runButton, 0, 0)

$coreButton = New-Object System.Windows.Forms.Button
$coreButton.Text = 'Run core snapshot'
$coreButton.AutoSize = $true
$footer.Controls.Add($coreButton, 1, 0)

$monitorButton = New-Object System.Windows.Forms.Button
$monitorButton.Text = 'Monitor selected (60s)'
$monitorButton.AutoSize = $true
$footer.Controls.Add($monitorButton, 2, 0)

$stopButton = New-Object System.Windows.Forms.Button
$stopButton.Text = 'Stop running command'
$stopButton.AutoSize = $true
$stopButton.Enabled = $false
$footer.Controls.Add($stopButton, 3, 0)

$copyButton = New-Object System.Windows.Forms.Button
$copyButton.Text = 'Copy command'
$copyButton.AutoSize = $true
$footer.Controls.Add($copyButton, 4, 0)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = 'Save output'
$saveButton.AutoSize = $true
$footer.Controls.Add($saveButton, 5, 0)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'Ready'
$statusLabel.AutoEllipsis = $true
$statusLabel.Dock = 'Fill'
$statusLabel.TextAlign = 'MiddleLeft'
$footer.Controls.Add($statusLabel, 6, 0)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Dock = 'Fill'
$progressBar.MarqueeAnimationSpeed = 35
$footer.Controls.Add($progressBar, 7, 0)

$sessionLabel = New-Object System.Windows.Forms.Label
$sessionLabel.AutoSize = $true
$sessionLabel.ForeColor = [System.Drawing.Color]::DimGray
$sessionLabel.Text = 'Local host: {0}   |   Elevated: {1}   |   Checks: {2}' -f $env:COMPUTERNAME, (Test-IsAdministrator), $script:Catalog.Count
$footer.SetColumnSpan($sessionLabel, 8)
$footer.Controls.Add($sessionLabel, 0, 1)

# Populate command tree.
foreach ($group in @($script:Catalog | Group-Object Category)) {
    $categoryNode = New-Object System.Windows.Forms.TreeNode($group.Name)
    foreach ($check in $group.Group) {
        $node = New-Object System.Windows.Forms.TreeNode($check.Name)
        $node.Tag = $check
        [void]$categoryNode.Nodes.Add($node)
    }
    [void]$tree.Nodes.Add($categoryNode)
}
$tree.ExpandAll()

# ---------------------------- Events ----------------------------
$tree.add_AfterSelect({
    param($sender, $eventArgs)
    $item = $eventArgs.Node.Tag
    if ($null -eq $item) { return }

    $script:SelectedCheck = $item
    $detailsBox.Clear()
    $detailsBox.SelectionFont = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
    $detailsBox.AppendText($item.Name + "`r`n`r`n")
    $detailsBox.SelectionFont = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    $detailsBox.AppendText("WHY`r`n")
    $detailsBox.SelectionFont = New-Object System.Drawing.Font('Segoe UI', 10)
    $detailsBox.AppendText($item.Why + "`r`n`r`n")
    $detailsBox.SelectionFont = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    $detailsBox.AppendText("WHEN TO USE IT`r`n")
    $detailsBox.SelectionFont = New-Object System.Drawing.Font('Segoe UI', 10)
    $detailsBox.AppendText($item.When + "`r`n`r`n")
    $detailsBox.SelectionFont = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    $detailsBox.AppendText("WHAT TO LOOK FOR`r`n")
    $detailsBox.SelectionFont = New-Object System.Drawing.Font('Segoe UI', 10)
    $detailsBox.AppendText($item.LookFor)
    $commandBox.Text = $item.Command
})

$runButton.add_Click({
    if ($null -eq $script:SelectedCheck) {
        [System.Windows.Forms.MessageBox]::Show('Select a check from the tree first.', 'Azure Local Deployment Troubleshooter', 'OK', 'Information') | Out-Null
        return
    }
    Start-CheckScript -Label $script:SelectedCheck.Name -ScriptText $script:SelectedCheck.Command
})

$coreButton.add_Click({
    Start-CheckScript -Label 'Core deployment snapshot' -ScriptText (Build-CoreScript)
})

$stopButton.add_Click({
    if ($null -ne $script:CurrentPowerShell) {
        $statusLabel.Text = 'Stopping command...'
        try { $script:CurrentPowerShell.Stop() } catch { }
    }
})

$copyButton.add_Click({
    if ($null -eq $script:SelectedCheck) { return }
    try {
        [System.Windows.Forms.Clipboard]::SetText($script:SelectedCheck.Command)
        $statusLabel.Text = 'Command copied to clipboard'
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Clipboard unavailable: $($_.Exception.Message)", 'Azure Local Deployment Troubleshooter', 'OK', 'Warning') | Out-Null
    }
})

$saveButton.add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = 'Save troubleshooting session output'
    $dialog.Filter = 'Text files (*.txt)|*.txt|Log files (*.log)|*.log|All files (*.*)|*.*'
    $dialog.FileName = 'AzureLocal-Deployment-{0}-{1}.txt' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss')
    if ($dialog.ShowDialog() -eq 'OK') {
        $preamble = "Azure Local Deployment Troubleshooter`r`nHost: $env:COMPUTERNAME`r`nSaved: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')`r`nRead-only checks only`r`n`r`n"
        [System.IO.File]::WriteAllText($dialog.FileName, $preamble + $outputBox.Text, [System.Text.Encoding]::UTF8)
        $statusLabel.Text = "Saved: $($dialog.FileName)"
    }
    $dialog.Dispose()
})

$monitorTimer = New-Object System.Windows.Forms.Timer
$monitorTimer.Interval = 60000
$monitorTimer.add_Tick({
    if ($script:MonitorEnabled -and $null -eq $script:CurrentAsync -and $null -ne $script:MonitorCheck) {
        Start-CheckScript -Label ("Monitor: {0}" -f $script:MonitorCheck.Name) -ScriptText $script:MonitorCheck.Command
    }
})

$monitorButton.add_Click({
    if (-not $script:MonitorEnabled) {
        if ($null -eq $script:SelectedCheck) {
            [System.Windows.Forms.MessageBox]::Show('Select the check you want to repeat first.', 'Azure Local Deployment Troubleshooter', 'OK', 'Information') | Out-Null
            return
        }
        $script:MonitorEnabled = $true
        $script:MonitorCheck = $script:SelectedCheck
        $monitorButton.Text = 'Stop monitoring'
        $monitorButton.BackColor = [System.Drawing.Color]::LightGoldenrodYellow
        $monitorTimer.Start()
        if ($null -eq $script:CurrentAsync) {
            Start-CheckScript -Label ("Monitor: {0}" -f $script:MonitorCheck.Name) -ScriptText $script:MonitorCheck.Command
        }
    }
    else {
        $script:MonitorEnabled = $false
        $script:MonitorCheck = $null
        $monitorTimer.Stop()
        $monitorButton.Text = 'Monitor selected (60s)'
        $monitorButton.UseVisualStyleBackColor = $true
        $statusLabel.Text = 'Monitoring stopped'
    }
})

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 250
$pollTimer.add_Tick({
    if ($null -ne $script:CurrentAsync -and $script:CurrentAsync.IsCompleted) {
        Complete-CurrentScript
    }
})
$pollTimer.Start()

$form.add_FormClosing({
    $monitorTimer.Stop()
    $pollTimer.Stop()
    if ($null -ne $script:CurrentPowerShell) {
        try { $script:CurrentPowerShell.Stop() } catch { }
        try { $script:CurrentPowerShell.Dispose() } catch { }
    }
})

# Select the first actual check.
if ($tree.Nodes.Count -gt 0 -and $tree.Nodes[0].Nodes.Count -gt 0) {
    $tree.SelectedNode = $tree.Nodes[0].Nodes[0]
}

if (-not (Test-IsAdministrator)) {
    Add-OutputText "WARNING: This session is not elevated. Some logs and system checks may return Access Denied. Close the tool and start Windows PowerShell as Administrator for complete results.`r`n"
}
else {
    Add-OutputText "Ready. Select a check, read why/when to use it, and click Run selected. Use Run core snapshot for a fast, read-only baseline.`r`n"
}

[void]$form.ShowDialog()

$pollTimer.Dispose()
$monitorTimer.Dispose()
$form.Dispose()
