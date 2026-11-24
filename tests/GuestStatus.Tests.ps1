# Run normally in an approved PowerShell session. All guest queries are mocked.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'ALFGuestStatus.ps1')
$script:Passed = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:Passed++
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw=$false
    try { & $Action } catch { $threw=$true }
    Assert $threw $Message
}
$folder = Join-Path ([IO.Path]::GetTempPath()) ('ALF-GuestStatus-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -Path $folder -ItemType Directory
try {
    $replacements = @{
        '{{LabSubnet}}'='10.44.0.0/24'; '{{DCIP}}'='10.44.0.10'; '{{GatewayIP}}'='10.44.0.1'
        '{{AdminStationName}}'='ContosoADM1'; '{{AdminStationIP}}'='10.44.0.11'; '{{LocalAdminName}}'='NodeAdmin'
        '{{DhcpStart}}'='10.44.0.100'; '{{DhcpEnd}}'='10.44.0.150'
        '{{DomainFqdn}}'='contosolab.local'; '{{DomainNetbios}}'='CONTOSOLAB'
        '{{TenantId}}'='11111111-1111-1111-1111-111111111111'; '{{SubscriptionId}}'='22222222-2222-2222-2222-222222222222'
        '{{ClusterResourceGroup}}'='LabRG'; '{{ArcRegion}}'='southcentralus'
        '__NODENAME__'='LastMinuteNode3'; '__NODEIP__'='10.44.0.3'
    }
    foreach ($name in '06dc.DC-SetNameAndIP.ps1','07dc.DC-CreateForest.ps1','08dc.DC-PostConfig.ps1','08adm.Admin-Configure.ps1','09dc.DC-PrepareADForAzureLocal.ps1','12.Node-Configure.ps1','14.Node-ArcRegister.ps1') {
        $text = Get-Content -LiteralPath (Join-Path $root $name) -Raw
        foreach ($key in $replacements.Keys) { $text=$text.Replace($key, $replacements[$key]) }
        Set-Content -LiteralPath (Join-Path $folder $name) -Value $text
    }
    $node = Get-ALFGuestScriptConfig $folder '12.Node-Configure.ps1' @('AZLnodename','IPAddress','PrefixLength')
    Assert ($node.AZLnodename -eq 'LastMinuteNode3' -and $node.IPAddress -eq '10.44.0.3' -and $node.PrefixLength -eq 24) 'Detect the delivered node override, not a planning-default name/IP.'
    Assert-Throws { Get-ALFGuestScriptConfig $root '12.Node-Configure.ps1' @('AZLnodename') } 'Unfilled node identity must fail explicitly.'
    Set-Content -LiteralPath (Join-Path $folder 'dynamic.ps1') -Value '$Name = (Get-Date)'
    Assert-Throws { Get-ALFGuestScriptConfig $folder 'dynamic.ps1' @('Name') } 'Never execute expressions when inspecting settings.'
    Set-Content -LiteralPath (Join-Path $folder 'dynamic.ps1') -Value '$Name = "$(Get-Date)"'
    Assert-Throws { Get-ALFGuestScriptConfig $folder 'dynamic.ps1' @('Name') } 'Do not present interpolated expressions as literal registration inputs.'
    $arcPath = Join-Path $folder '14.Node-ArcRegister.ps1'
    $arcSource = Get-Content -LiteralPath $arcPath -Raw
    $values = Get-ALFGuestArcSettingsText $folder
    foreach ($value in $replacements['{{TenantId}}'], $replacements['{{SubscriptionId}}'], 'LabRG', 'southcentralus', $env:COMPUTERNAME) {
        Assert ($values.Contains($value)) 'Show the delivered Azure target and actual machine used by the Arc script.'
    }
    Assert ($values.Contains('(Choose when the script runs)')) 'Blank target solution version describes the existing interactive selection.'
    Assert ((Get-ALFGuestArcSettingsText $folder ' 12.2602.1002.11 ').Contains('12.2602.1002.11 (node override)')) 'Show the applied node override as the next Arc target.'
    foreach ($invalid in '12.2602', '12.2602.1002.x', '12.2602.1002.10"; Get-Date') {
        Assert-Throws { ConvertTo-ALFGuestTargetVersion $invalid } 'Reject malformed or executable target text before saving or constructing launch arguments.'
    }
    Set-Content -LiteralPath $arcPath -Value ($arcSource.Replace('$TargetSolutionVersion = ""', '$TargetSolutionVersion = "12.2602.1002.10"').Replace('"LabRG"', '"UpdatedRG"'))
    $values = Get-ALFGuestArcSettingsText $folder
    Assert ($values.Contains('12.2602.1002.10') -and $values.Contains('UpdatedRG') -and -not $values.Contains('Resource group:  LabRG')) 'Reread pinned versions and edited delivered inputs instead of caching planning values.'
    Assert ((Get-ALFGuestArcSettingsText $folder '').Contains('Target version:  12.2602.1002.10')) 'Clearing the node override returns to a pinned delivered default, not an unconditional empty version.'
    Assert-Throws { Get-ALFGuestArcSettingsText $root } 'Unfilled registration inputs are reported, not shown as a usable target.'
    Set-Content -LiteralPath $arcPath -Value $arcSource
    $script:TimeOutput = @('Leap Indicator: 0(no warning)', 'Stratum: 3', 'Last Successful Sync Time: 11/21/2026 9:00:00 PM', 'Source: DCFixture')
    $script:TimeExit = 0
    function w32tm.exe {
        param($Query, $Status)
        $script:TimeArgs = @($Query, $Status)
        $global:LASTEXITCODE = $script:TimeExit
        return $script:TimeOutput
    }
    try {
        $priorExit = $global:LASTEXITCODE
        $global:LASTEXITCODE = 42
        Assert ((Get-ALFGuestTimeStatus) -ceq ($script:TimeOutput -join "`r`n")) 'Show time source, last synchronization and stratum without rewriting or claiming NTP health.'
        Assert (($script:TimeArgs -join ' ') -eq '/query /status' -and $global:LASTEXITCODE -eq 42) 'Use only a read-only time query and preserve native exit status.'
        $script:TimeExit = 1; $script:TimeOutput = @('The service has not been started.')
        Assert-Throws { Get-ALFGuestTimeStatus } 'A failed or stopped Windows Time query must remain explicit.'
        Assert ($global:LASTEXITCODE -eq 42) 'Restore native exit status after a failed query.'
        $script:TimeExit = 0; $script:TimeOutput = @()
        Assert-Throws { Get-ALFGuestTimeStatus } 'Empty time status cannot look like a successful query.'
    }
    finally {
        $global:LASTEXITCODE = $priorExit
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath 'function:w32tm.exe'
    }
    foreach ($version in '2.0.7','2.0.14','2.0.15','2.0.16','2.0.17','2.0.18','2.0.19','2.0.20','2.0.21','2.0.22','2.0.23') {
        $saved = [pscustomobject]@{
            Role='Node'; Version=$version
            Steps=[pscustomobject]@{
                Ready=[pscustomobject]@{ Confirmed=$true }
                Configure=[pscustomobject]@{ Confirmed=$true; ConfirmedAt='old'; Started='start'; ResultPath='receipt'; ProcessId=42; ProcessStarted='UTC' }
            }
        }
        $records = ConvertTo-ALFGuestRecords $saved 'Node' '2.0.23' @('Configure','Arc')
        Assert ($records.Configure.Started -eq 'start' -and $records.Configure.ProcessId -eq 42 -and $records.Configure.ProcessStarted -eq 'UTC' -and $records.Configure.ResultPath -eq 'receipt') 'Preserve compatible execution/process metadata.'
        Assert (-not $records.ContainsKey('Ready') -and -not $records.Configure.ContainsKey('Confirmed')) 'Discard manual cards and confirmation proof.'
    }
    Assert-Throws { ConvertTo-ALFGuestRecords $saved 'DC' '2.0.23' @('Network') } 'Reject cross-role state.'
    $saved.Version='9.0.0'
    Assert-Throws { ConvertTo-ALFGuestRecords $saved 'Node' '2.0.23' @('Configure') } 'Reject unsupported state releases.'
    Assert ((Resolve-ALFGuestTaskState (New-ALFGuestCheck 'NotDone' 'Missing') @{Confirmed=$true} $false $null '').State -eq 'NotDone') 'Old confirmations never turn a step green.'
    Assert ((Resolve-ALFGuestTaskState (New-ALFGuestCheck 'NotDone' 'Missing') @{} $false @{ExitCode=0} '').State -eq 'Attention') 'Successful exit is not configuration completion.'
    Assert ((Resolve-ALFGuestTaskState (New-ALFGuestCheck 'Done' 'Detected') @{} $true $null '').State -eq 'Running') 'Running process remains visible.'
    Assert ((Resolve-ALFGuestTaskState (New-ALFGuestCheck 'Done' 'Detected') @{} $false @{ExitCode=1} '').Detail -match 'Last run') 'Detected state wins over a prior failure while preserving its warning.'
    Assert ((Resolve-ALFGuestTaskState (New-ALFGuestCheck 'NotDone' 'Missing') @{LaunchError='Launch failed'} $false $null '').State -eq 'Failed') 'Persisted launch failures remain visible.'
    Assert ((Resolve-ALFGuestTaskState (New-ALFGuestCheck 'Attention' 'Restart required' $false $true) @{} $false @{ExitCode=1} '').RestartRequired) 'Restart information is not replaced by an old failure.'

    $script:Computer = [pscustomobject]@{Name='LastMinuteNode3'; DomainRole=3; PartOfDomain=$false; Domain='WORKGROUP'}
    $script:PendingName='LastMinuteNode3'; $script:IP='10.44.0.3'; $script:Alias='1-MGMTCOMP1'
    $script:DNS=@('10.44.0.10'); $script:ClusterPresent=$false; $script:ClusterName='ClusterFixture'
    $script:Raw=$true; $script:UserEnabled=$true; $script:DhcpThrows=$false; $script:ToolsInstalled=$true
    $script:ClusterLookupFails=$false; $script:SecureChannel=$true; $script:ModuleInstalled=$true; $script:HasGateway=$true
    $script:ExistingPool=$false; $script:PoolQueryFails=$false
    $script:Bootstrap='Succeeded'; $script:AgentThrows=$false
    $script:Agent=[pscustomobject]@{status='Connected';resourceName='LastMinuteNode3';tenantId=$replacements['{{TenantId}}'];subscriptionId=$replacements['{{SubscriptionId}}'];resourceGroup='LabRG';location='southcentralus'}
    $ALFExpectedClusterName='ClusterFixture'
    function Get-CimInstance { param($ClassName,$ErrorAction) return $script:Computer }
    function Get-NetAdapter { param([switch]$Physical,$ErrorAction) [pscustomobject]@{Name=$script:Alias;ifIndex=1} }
    function Get-NetIPAddress { param($InterfaceIndex,$IPAddress,$AddressFamily,$ErrorAction) [pscustomobject]@{IPAddress=$script:IP;PrefixLength=24;AddressState='Preferred';InterfaceIndex=1} }
    function Get-NetRoute {
        param($InterfaceIndex,$DestinationPrefix,$AddressFamily,$ErrorAction)
        if ($script:HasGateway) { [pscustomobject]@{InterfaceIndex=1;DestinationPrefix='0.0.0.0/0';NextHop='10.44.0.1'} }
    }
    function Get-NetIPInterface { param($InterfaceIndex,$AddressFamily,$ErrorAction) [pscustomobject]@{Dhcp='Disabled'} }
    function Get-DnsClientServerAddress { param($InterfaceIndex,$AddressFamily,$ErrorAction) [pscustomobject]@{ServerAddresses=$script:DNS} }
    function Get-ItemProperty {
        param($Path,$ErrorAction)
        if ($Path -like '*ComputerName') { return [pscustomobject]@{ComputerName=$script:PendingName} }
        return [pscustomobject]@{fDenyTSConnections=0}
    }
    function Get-LocalUser { param($ErrorAction) [pscustomobject]@{Name='NodeAdmin';Enabled=$script:UserEnabled;SID='S-1-5-21-123-1001'} }
    function Get-LocalGroupMember { param($SID,$ErrorAction) [pscustomobject]@{SID='S-1-5-21-123-1001'} }
    function Get-NetFirewallRule { param($DisplayGroup,$ErrorAction) [pscustomobject]@{Enabled=$true} }
    function Get-Disk {
        param($ErrorAction)
        if ($script:ClusterPresent) { throw 'Cluster-owned physical disks need not appear in Get-Disk.' }
        1..4 | ForEach-Object { [pscustomobject]@{IsBoot=$false;IsSystem=$false;BusType='SCSI';PartitionStyle=$(if($script:Raw){'RAW'}else{'GPT'});IsOffline=$false;IsReadOnly=$false} }
    }
    function Get-StoragePool {
        param($IsPrimordial,$ErrorAction)
        if ($script:PoolQueryFails) { throw 'Storage provider query failed' }
        if ($PSBoundParameters.ContainsKey('IsPrimordial') -and -not $IsPrimordial -and -not $script:ExistingPool) {
            throw "No MSFT_StoragePool objects found with property 'IsPrimordial' equal to 'False'."
        }
        [pscustomobject]@{Name='Primordial';IsPrimordial=$true}
        if ($script:ExistingPool) { [pscustomobject]@{Name='ExistingPool';IsPrimordial=$false} }
    }
    function Test-Path {
        param($Path,$LiteralPath,$PathType,$ErrorAction)
        $actual=if($LiteralPath){$LiteralPath}else{$Path}
        if ($actual -eq 'HKLM:\Cluster') {
            if ($script:ClusterLookupFails) { throw 'Cluster membership could not be read' }
            return $script:ClusterPresent
        }
        if ($actual -like 'HKLM:*') { return $false }
        if ($actual -like '*azcmagent.exe') { return $true }
        return Microsoft.PowerShell.Management\Test-Path -LiteralPath $actual
    }
    function Get-Cluster { param($ErrorAction) [pscustomobject]@{Name=$script:ClusterName} }
    function Get-Service {
        param($ErrorAction)
        'NTDS','DNS','ADWS','Netlogon','DHCPServer' | ForEach-Object { [pscustomobject]@{Name=$_;Status='Running'} }
    }
    function Get-ADDomain { param($Server,$ErrorAction) [pscustomobject]@{DNSRoot='contosolab.local';NetBIOSName='CONTOSOLAB'} }
    function Get-DnsServerForwarder { param($ComputerName,$ErrorAction) [pscustomobject]@{IPAddress=@('8.8.8.8','1.1.1.1')} }
    function Get-DnsServerZone { param($ComputerName,$ErrorAction) [pscustomobject]@{ZoneName='0.44.10.in-addr.arpa';IsReverseLookupZone=$true} }
    function Get-DhcpServerInDC {
        param($ErrorAction)
        if ($script:DhcpThrows) { throw 'DHCP query failed' }
        [pscustomobject]@{IPAddress='10.44.0.10'}
    }
    function Get-DhcpServerv4Scope { param($ComputerName,$ErrorAction) [pscustomobject]@{ScopeId='10.44.0.0';State='Active';StartRange='10.44.0.100';EndRange='10.44.0.150';SubnetMask='255.255.255.0'} }
    function Get-DhcpServerv4OptionValue {
        param($ComputerName,$ScopeId,$ErrorAction)
        @([pscustomobject]@{OptionId=3;Value=@('10.44.0.1')},[pscustomobject]@{OptionId=6;Value=@('10.44.0.10')},[pscustomobject]@{OptionId=15;Value=@('contosolab.local')})
    }
    function Get-WindowsFeature { param($Name,$ErrorAction) $Name | ForEach-Object { [pscustomobject]@{Name=$_;Installed=$script:ToolsInstalled;InstallState='Installed'} } }
    function Test-ComputerSecureChannel { param($ErrorAction) return $script:SecureChannel }
    function Get-Module {
        param([switch]$ListAvailable,$Name,$ErrorAction)
        if ($script:ModuleInstalled) { [pscustomobject]@{Name=$Name} }
    }
    function Get-ArcBootstrapStatus { param($ErrorAction) [pscustomobject]@{Response=[pscustomobject]@{Status=$script:Bootstrap}} }
    function Get-ALFGuestArcAgentInfo {
        param($Path)
        if ($script:AgentThrows) { throw 'Agent output was malformed' }
        return $script:Agent
    }
    $nodeTask=@{Id='Configure';Script='12.Node-Configure.ps1'}
    Assert ((Get-ALFGuestTaskCheck $nodeTask Node $folder).State -eq 'Done') 'Prepared RAW node disks and actual node settings are detected.'
    Assert ((Get-ALFGuestTaskCheck $nodeTask Node $folder).Detail -match 'RAW data disks ready') 'No non-primordial pool is the expected ready-to-pool state.'
    $script:ExistingPool=$true
    Assert ((Get-ALFGuestTaskCheck $nodeTask Node $folder).State -eq 'NotDone') 'An actual non-primordial pool still prevents claiming unpooled RAW readiness.'
    $script:ExistingPool=$false; $script:PoolQueryFails=$true
    $check=Get-ALFGuestTaskCheck $nodeTask Node $folder
    Assert ($check.State -eq 'Attention' -and -not $check.RunAllowed -and $check.Detail -match 'Storage provider query failed') 'Genuine storage lookup failures remain explicit and cannot allow disk cleanup.'
    $script:PoolQueryFails=$false; $script:Raw=$false
    Assert ((Get-ALFGuestTaskCheck $nodeTask Node $folder).State -eq 'NotDone') 'No pool alone is not proof of RAW disk readiness.'
    $script:Raw=$true
    $script:HasGateway=$false
    $check=Get-ALFGuestTaskCheck $nodeTask Node $folder
    Assert ($check.State -eq 'NotDone' -and $check.RunAllowed) 'A missing default route is ordinary incomplete setup, not a blocked status failure.'
    $script:HasGateway=$true
    $script:ClusterLookupFails=$true
    $check=Get-ALFGuestTaskCheck $nodeTask Node $folder
    Assert ($check.State -eq 'Attention' -and -not $check.RunAllowed) 'Unknown cluster membership must not allow destructive setup.'
    $script:ClusterLookupFails=$false
    $script:Computer.Name='OLD'; $script:PendingName='LastMinuteNode3'
    $check=Get-ALFGuestTaskCheck $nodeTask Node $folder
    Assert ($check.RestartRequired -and -not $check.RunAllowed) 'Pending name changes require restart, not a green card or disk-cleanup rerun.'
    $script:Computer.Name='LastMinuteNode3'; $script:UserEnabled=$false
    Assert ((Get-ALFGuestTaskCheck $nodeTask Node $folder).State -eq 'NotDone') 'Disabled local admin prevents completion.'
    $script:UserEnabled=$true; $script:Raw=$false; $script:ClusterPresent=$true
    $check=Get-ALFGuestTaskCheck $nodeTask Node $folder
    Assert ($check.State -eq 'Done' -and -not $check.RunAllowed) 'Deployed lab storage does not regress to NotDone or allow destructive rerun.'
    $script:ClusterName='AnotherCluster'
    $check=Get-ALFGuestTaskCheck $nodeTask Node $folder
    Assert ($check.State -eq 'Attention' -and -not $check.RunAllowed) 'Another cluster is reported explicitly and protected from cleanup.'
    $script:ClusterPresent=$false
    $script:Computer.Name='ContosoDC1'; $script:Computer.DomainRole=5; $script:Computer.PartOfDomain=$true
    $script:IP='10.44.0.10'; $script:Alias='LAN'; $script:DNS=@('10.44.0.10','127.0.0.1')
    Assert ((Get-ALFGuestTaskCheck @{Id='Network';Script='06dc.DC-SetNameAndIP.ps1'} DC $folder).State -eq 'Done') 'DC network stays done after DNS legitimately changes to itself.'
    $dnsTask=@{Id='DNS';Script='08dc.DC-PostConfig.ps1'}
    Assert ((Get-ALFGuestTaskCheck $dnsTask DC $folder).State -eq 'Done') 'Actual DNS and DHCP settings are required for completion.'
    $script:DhcpThrows=$true
    Assert ((Get-ALFGuestTaskCheck $dnsTask DC $folder).State -eq 'Attention') 'DHCP probe errors remain visible.'
    $dnsFile=Join-Path $folder $dnsTask.Script
    Set-Content -LiteralPath $dnsFile -Value ((Get-Content -LiteralPath $dnsFile -Raw).Replace('$InstallDHCP = $true','$InstallDHCP = $false'))
    Assert ((Get-ALFGuestTaskCheck $dnsTask DC $folder).State -eq 'Done') 'Optional DHCP is not probed when disabled.'
    $artifactsTask=@{Id='Artifacts';Script='09dc.DC-PrepareADForAzureLocal.ps1'}
    Assert ((Get-ALFGuestTaskCheck $artifactsTask DC $folder).Detail -match 'OU/account creation remains optional') 'Installed AD module does not claim optional AD objects were created.'
    $script:ModuleInstalled=$false
    Assert ((Get-ALFGuestTaskCheck $artifactsTask DC $folder).State -eq 'NotDone') 'Missing AD preparation module is not done.'
    $script:Computer.Name='ContosoADM1'; $script:Computer.Domain='contosolab.local'; $script:IP='10.44.0.11'; $script:DNS=@('10.44.0.10')
    $adminTask=@{Id='Configure';Script='08adm.Admin-Configure.ps1'}
    Assert ((Get-ALFGuestTaskCheck $adminTask Admin $folder).State -eq 'Done') 'Admin completion includes actual management tools and domain membership.'
    $script:ToolsInstalled=$false
    Assert ((Get-ALFGuestTaskCheck $adminTask Admin $folder).State -eq 'NotDone') 'Missing admin tools prevent false completion.'
    $script:ToolsInstalled=$true; $script:SecureChannel=$false
    Assert ((Get-ALFGuestTaskCheck $adminTask Admin $folder).State -eq 'Attention') 'Pending/broken domain connectivity does not falsely complete admin setup.'
    $arcTask=@{Id='Arc';Script='14.Node-ArcRegister.ps1'}
    Assert ((Get-ALFGuestTaskCheck $arcTask Node $folder).State -eq 'Done') 'Arc requires bootstrap success and a matching connected agent.'
    $script:Agent.resourceName='OldNodeName'
    Assert ((Get-ALFGuestTaskCheck $arcTask Node $folder).State -eq 'Attention') 'Arc resource name must honor the delivered node override.'
    $script:Agent.resourceName='LastMinuteNode3'
    $script:Bootstrap='Failed'
    Assert ((Get-ALFGuestTaskCheck $arcTask Node $folder).State -eq 'Failed') 'Connected agent alone does not hide a failed bootstrap.'
    $script:Bootstrap='Succeeded'; $script:Agent.subscriptionId='different'
    Assert ((Get-ALFGuestTaskCheck $arcTask Node $folder).State -eq 'Attention') 'A different Azure target is not done.'
    $script:Agent.subscriptionId=$replacements['{{SubscriptionId}}']; $script:AgentThrows=$true
    Assert ((Get-ALFGuestTaskCheck $arcTask Node $folder).Detail -match 'Status check failed') 'Malformed agent output is explicitly reported.'
    Write-Output "PASS: $script:Passed detected-status/state cases; no guest settings changed."
}
finally { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $folder -Recurse -Force }
