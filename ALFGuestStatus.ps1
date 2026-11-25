# Version: ALF Lab Builder 2.1.0
# Read-only guest checks. Configuration scripts are inspected, never executed.

$ALFExpectedClusterName = '{{ClusterName}}'

function New-ALFGuestCheck([string]$State, [string]$Detail, [bool]$RunAllowed = $true, [bool]$RestartRequired = $false) {
    return @{ State=$State; Detail=$Detail; RunAllowed=$RunAllowed; RestartRequired=$RestartRequired }
}

function Get-ALFGuestScriptConfig([string]$Folder, [string]$File, [string[]]$Names) {
    $path = Join-Path $Folder $File
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Cannot inspect $File; correct its syntax or redeliver it." }
    $config = @{}
    foreach ($name in $Names) {
        $assignment = @($ast.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
            $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and
            $_.Left.VariablePath.UserPath -eq $name
        }) | Select-Object -First 1
        if (-not $assignment) { throw "Setting '$name' is missing from $File." }
        $text = $assignment.Right.Extent.Text.Trim()
        if ($name -in 'Prefix', 'PrefixLength') {
            $cidr = @($assignment.Right.FindAll({ param($n)
                $n -is [Management.Automation.Language.StringConstantExpressionAst] -and
                $n.Value -match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$'
            }, $true))
            if ($cidr.Count -ne 1) { throw "Cannot read the subnet prefix in $File." }
            $config[$name] = [int]$cidr[0].Value.Split('/')[1]
            if ($config[$name] -lt 1 -or $config[$name] -gt 32) { throw "Invalid subnet prefix in $File." }
        }
        elseif ($text -match '^"([^"\r\n]*)"$' -or $text -match "^'([^'\r\n]*)'$") {
            if ($assignment.Right.FindAll({ param($n)
                $n -is [Management.Automation.Language.ExpandableStringExpressionAst] -and $n.NestedExpressions.Count
            }, $true).Count) { throw "Setting '$name' must be literal data in $File." }
            $config[$name] = $Matches[1]
        }
        elseif ($text -in '$true', '$false') { $config[$name] = $text -eq '$true' }
        elseif ($text -match '^\d+$') { $config[$name] = [int]$text }
        elseif ($text.StartsWith('@(')) {
            $dynamic = @($assignment.Right.FindAll({ param($n)
                $n -is [Management.Automation.Language.CommandAst] -or
                $n -is [Management.Automation.Language.VariableExpressionAst] -or
                $n -is [Management.Automation.Language.InvokeMemberExpressionAst]
            }, $true))
            if ($dynamic.Count) { throw "Setting '$name' must be literal data in $File." }
            $config[$name] = @($assignment.Right.FindAll({ param($n)
                $n -is [Management.Automation.Language.StringConstantExpressionAst]
            }, $true) | ForEach-Object Value)
        }
        else { throw "Cannot inspect setting '$name' without executing $File." }
        if (@($config[$name] | Where-Object { "$_" -match '\{\{|__NODENAME__|__NODEIP__' }).Count) {
            throw "$File still has unfilled settings; redeliver its prepared copy."
        }
    }
    return $config
}

function ConvertTo-ALFGuestTargetVersion([string]$Value = '') {
    $version = $Value.Trim()
    if ($version -and $version -notmatch '^[0-9]+(?:\.[0-9]+){3}$') {
        throw 'Enter the full Azure Local version as four numeric parts (Major.YYMM.Build.Revision), for example 12.2610.1004.50, or leave blank to use the delivered script default.'
    }
    return $version
}

function Get-ALFGuestArcSettingsText([string]$Folder, [string]$TargetSolutionVersionOverride = '') {
    $config = Get-ALFGuestScriptConfig $Folder '14.Node-ArcRegister.ps1' @('Tenant', 'Subscription', 'RG', 'Region', 'TargetSolutionVersion')
    $override = ConvertTo-ALFGuestTargetVersion $TargetSolutionVersionOverride
    $version = if ($override) { "$override (node override)" } elseif ($config.TargetSolutionVersion) { $config.TargetSolutionVersion } else { '(Choose when the script runs)' }
    return @(
        "Machine:         $env:COMPUTERNAME"
        "Tenant ID:       $($config.Tenant)"
        "Subscription ID: $($config.Subscription)"
        "Resource group:  $($config.RG)"
        "Region:          $($config.Region)"
        "Target version:  $version"
    ) -join "`r`n"
}

function Get-ALFGuestTimeStatus {
    $previousExit = $global:LASTEXITCODE
    try {
        $output = @(& w32tm.exe /query /status 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "w32tm /query /status failed (exit $LASTEXITCODE): $($output -join ' ')" }
        $text = ($output -join "`r`n").Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { throw 'w32tm /query /status returned no time status.' }
        return $text
    }
    finally { $global:LASTEXITCODE = $previousExit }
}

function Test-ALFGuestSameSet($Actual, $Expected) {
    $a = @($Actual | ForEach-Object { "$_" } | Sort-Object -Unique)
    $b = @($Expected | ForEach-Object { "$_" } | Sort-Object -Unique)
    return ($a -join '|') -ieq ($b -join '|')
}

function Get-ALFGuestNetworkCheck($Config) {
    $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    if ($computer.Name -ine $Config.Name) {
        $pending = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction Stop
        if ($pending.ComputerName -ieq $Config.Name) {
            return New-ALFGuestCheck 'Attention' 'Restart required to finish the computer name change.' $false $true
        }
        return New-ALFGuestCheck 'NotDone' 'Computer name is not configured yet.'
    }
    $adapter = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object Name -eq $Config.Alias)
    if ($adapter.Count -ne 1) { return New-ALFGuestCheck 'NotDone' "Adapter $($Config.Alias) is not configured." }
    $index = $adapter[0].ifIndex
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object InterfaceIndex -eq $index)
    $address = @($addresses | Where-Object {
        $_.IPAddress -eq $Config.IP -and $_.PrefixLength -eq $Config.Prefix -and "$($_.AddressState)" -eq 'Preferred'
    })
    $routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
        $_.InterfaceIndex -eq $index -and $_.DestinationPrefix -eq '0.0.0.0/0'
    })
    $ipInterface = Get-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop
    if ($address.Count -ne 1 -or $addresses.Count -ne 1 -or
        -not ($routes | Where-Object NextHop -eq $Config.Gateway) -or "$($ipInterface.Dhcp)" -ne 'Disabled') {
        return New-ALFGuestCheck 'NotDone' 'Static IP, prefix or gateway does not match the plan.'
    }
    if ($Config.DNS) {
        $dns = Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop
        if (-not (Test-ALFGuestSameSet $dns.ServerAddresses @($Config.DNS))) {
            return New-ALFGuestCheck 'NotDone' 'DNS client does not point to the lab DC.'
        }
    }
    return New-ALFGuestCheck 'Done' "$($Config.Name) | $($Config.IP)/$($Config.Prefix)"
}

function Get-ALFGuestForestCheck([string]$Folder) {
    $config = Get-ALFGuestScriptConfig $Folder '07dc.DC-CreateForest.ps1' @('DomainName', 'NetBIOS', 'ExpectedPC')
    $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    if ($computer.Name -ine $config.ExpectedPC -or $computer.DomainRole -notin 4, 5) {
        $restart = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
            (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        if ($restart) { return New-ALFGuestCheck 'Attention' 'Restart required; domain promotion is not active yet.' $false $true }
        return New-ALFGuestCheck 'NotDone' 'Domain controller promotion is not active.'
    }
    $services = @(Get-Service -ErrorAction Stop | Where-Object Name -in @('NTDS', 'DNS', 'ADWS', 'Netlogon'))
    if ($services.Count -ne 4 -or @($services | Where-Object Status -ne 'Running').Count) {
        return New-ALFGuestCheck 'Attention' 'AD/DNS services are not all running.'
    }
    $domain = Get-ADDomain -Server localhost -ErrorAction Stop
    if ($domain.DNSRoot -ine $config.DomainName -or $domain.NetBIOSName -ine $config.NetBIOS) {
        return New-ALFGuestCheck 'Attention' 'The active domain does not match this lab.' $false
    }
    return New-ALFGuestCheck 'Done' $domain.DNSRoot
}

function Get-ALFGuestDnsCheck([string]$Folder) {
    $forest = Get-ALFGuestForestCheck $Folder
    if ($forest.State -ne 'Done') { return $forest }
    $config = Get-ALFGuestScriptConfig $Folder '08dc.DC-PostConfig.ps1' @(
        'DCIP', 'Forwarders', 'ReverseNet', 'InstallDHCP', 'DhcpStart', 'DhcpEnd', 'DhcpMask', 'Gateway', 'DnsDomain'
    )
    $octets = $config.ReverseNet.Split('/')[0].Split('.')
    $reverseZone = "$($octets[2]).$($octets[1]).$($octets[0]).in-addr.arpa"
    $forwarders = Get-DnsServerForwarder -ComputerName localhost -ErrorAction Stop
    $zones = @(Get-DnsServerZone -ComputerName localhost -ErrorAction Stop)
    $ip = @(Get-NetIPAddress -IPAddress $config.DCIP -AddressFamily IPv4 -ErrorAction Stop)
    if ($ip.Count -ne 1) { return New-ALFGuestCheck 'NotDone' 'The planned DC address is missing.' }
    $dns = Get-DnsClientServerAddress -InterfaceIndex $ip[0].InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop
    if (-not (Test-ALFGuestSameSet $forwarders.IPAddress $config.Forwarders) -or
        -not ($zones | Where-Object { $_.ZoneName -eq $reverseZone -and $_.IsReverseLookupZone }) -or
        -not (Test-ALFGuestSameSet $dns.ServerAddresses @($config.DCIP, '127.0.0.1'))) {
        return New-ALFGuestCheck 'NotDone' 'DNS forwarders, reverse zone or DNS client settings are incomplete.'
    }
    if ($config.InstallDHCP) {
        $authorized = @(Get-DhcpServerInDC -ErrorAction Stop)
        $scopes = @(Get-DhcpServerv4Scope -ComputerName localhost -ErrorAction Stop)
        $scopeId = $config.ReverseNet.Split('/')[0]
        $scope = @($scopes | Where-Object { "$($_.ScopeId)" -eq $scopeId })
        $service = @(Get-Service -ErrorAction Stop | Where-Object Name -eq 'DHCPServer')
        if ($scope.Count -ne 1 -or "$($scope[0].State)" -ne 'Active' -or
            "$($scope[0].StartRange)" -ne $config.DhcpStart -or "$($scope[0].EndRange)" -ne $config.DhcpEnd -or
            "$($scope[0].SubnetMask)" -ne $config.DhcpMask -or
            -not ($authorized | Where-Object { "$($_.IPAddress)" -eq $config.DCIP }) -or
            $service.Count -ne 1 -or $service[0].Status -ne 'Running') {
            return New-ALFGuestCheck 'NotDone' 'DHCP authorization, service or scope is incomplete.'
        }
        $options = @(Get-DhcpServerv4OptionValue -ComputerName localhost -ScopeId $scopeId -ErrorAction Stop)
        if (-not (Test-ALFGuestSameSet ($options | Where-Object OptionId -eq 3).Value @($config.Gateway)) -or
            -not (Test-ALFGuestSameSet ($options | Where-Object OptionId -eq 6).Value @($config.DCIP)) -or
            -not (Test-ALFGuestSameSet ($options | Where-Object OptionId -eq 15).Value @($config.DnsDomain))) {
            return New-ALFGuestCheck 'NotDone' 'DHCP router, DNS or domain options do not match the plan.'
        }
    }
    return New-ALFGuestCheck 'Done' $(if ($config.InstallDHCP) { 'DNS and DHCP configured.' } else { 'DNS configured; DHCP is optional.' })
}

function Get-ALFGuestArcAgentInfo([string]$Path) {
    $previousExit = $global:LASTEXITCODE
    try {
        $text = & $Path show --json
        if ($LASTEXITCODE -ne 0) { throw "Arc agent status query failed (exit $LASTEXITCODE)." }
        return ($text -join "`n") | ConvertFrom-Json -ErrorAction Stop
    }
    finally { $global:LASTEXITCODE = $previousExit }
}

function Get-ALFGuestTaskCheck($Task, [string]$Role, [string]$Folder) {
    $clusterPresent = $false
    try {
        switch ("$Role/$($Task.Id)") {
            'DC/Network' {
                $c = Get-ALFGuestScriptConfig $Folder $Task.Script @('NewName', 'IPAddress', 'Prefix', 'Gateway', 'NicName')
                return Get-ALFGuestNetworkCheck @{ Name=$c.NewName; IP=$c.IPAddress; Prefix=$c.Prefix; Gateway=$c.Gateway; Alias=$c.NicName }
            }
            'DC/Forest' { return Get-ALFGuestForestCheck $Folder }
            'DC/DNS' { return Get-ALFGuestDnsCheck $Folder }
            'DC/Artifacts' {
                $c = Get-ALFGuestScriptConfig $Folder $Task.Script @('ModuleName')
                $modules = @(Get-Module -ListAvailable -Name $c.ModuleName -ErrorAction Stop)
                if (-not $modules) { return New-ALFGuestCheck 'NotDone' 'AD preparation module is not installed.' }
                return New-ALFGuestCheck 'Done' 'AD preparation module installed. OU/account creation remains optional.'
            }
            'Admin/Configure' {
                $c = Get-ALFGuestScriptConfig $Folder $Task.Script @('NewName', 'IPAddress', 'Prefix', 'Gateway', 'DNSServer', 'NicName', 'DomainName', 'Tools')
                $network = Get-ALFGuestNetworkCheck @{ Name=$c.NewName; IP=$c.IPAddress; Prefix=$c.Prefix; Gateway=$c.Gateway; Alias=$c.NicName; DNS=$c.DNSServer }
                if ($network.State -ne 'Done') { return $network }
                $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
                $features = @(Get-WindowsFeature -Name $c.Tools -ErrorAction Stop)
                if (@($features | Where-Object { "$($_.InstallState)" -eq 'InstallPending' }).Count) {
                    return New-ALFGuestCheck 'Attention' 'Restart required to finish management tools.' $false $true
                }
                if (-not $computer.PartOfDomain -or $computer.Domain -ine $c.DomainName -or
                    $features.Count -ne $c.Tools.Count -or @($features | Where-Object { -not $_.Installed }).Count) {
                    return New-ALFGuestCheck 'NotDone' 'Domain membership or management tools are incomplete.'
                }
                if (-not (Test-ComputerSecureChannel -ErrorAction Stop)) {
                    return New-ALFGuestCheck 'Attention' 'Domain connection is not ready; restart or check DC connectivity.'
                }
                return New-ALFGuestCheck 'Done' 'Name, networking, domain join and management tools detected.'
            }
            'Node/Configure' {
                $clusterPresent = Test-Path 'HKLM:\Cluster' -ErrorAction Stop
                $c = Get-ALFGuestScriptConfig $Folder $Task.Script @('AZLnodename', 'IPAddress', 'PrefixLength', 'Gateway', 'DNSServer1', 'InterfaceAlias', 'LocalAdminName', 'ExpectedDataDisks')
                $network = Get-ALFGuestNetworkCheck @{ Name=$c.AZLnodename; IP=$c.IPAddress; Prefix=$c.PrefixLength; Gateway=$c.Gateway; Alias=$c.InterfaceAlias; DNS=$c.DNSServer1 }
                if ($network.State -ne 'Done') { if ($clusterPresent) { $network.RunAllowed=$false }; return $network }
                $user = @(Get-LocalUser -ErrorAction Stop | Where-Object Name -eq $c.LocalAdminName)
                $admins = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)
                $rdp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction Stop
                $rules = @(Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction Stop)
                if ($user.Count -ne 1 -or -not $user[0].Enabled -or
                    -not ($admins | Where-Object { "$($_.SID)" -eq "$($user[0].SID)" }) -or
                    $rdp.fDenyTSConnections -ne 0 -or -not $rules.Count -or
                    @($rules | Where-Object { "$($_.Enabled)" -ne 'True' }).Count) {
                    return New-ALFGuestCheck 'NotDone' 'Local admin or remote access settings are incomplete.' (-not $clusterPresent)
                }
                if ($clusterPresent) {
                    $cluster = Get-Cluster -ErrorAction Stop
                    if ($ALFExpectedClusterName -match '\{\{' -or $cluster.Name -ine $ALFExpectedClusterName) {
                        return New-ALFGuestCheck 'Attention' 'This node already belongs to another cluster; do not rerun setup.' $false
                    }
                    return New-ALFGuestCheck 'Done' 'Node configured; storage is managed by the lab cluster.' $false
                }
                $disks = @(Get-Disk -ErrorAction Stop | Where-Object { -not $_.IsBoot -and -not $_.IsSystem -and "$($_.BusType)" -ne 'USB' })
                $pools = @(Get-StoragePool -ErrorAction Stop | Where-Object { -not $_.IsPrimordial })
                if ($disks.Count -ne $c.ExpectedDataDisks -or $pools.Count -or
                    @($disks | Where-Object { "$($_.PartitionStyle)" -ne 'RAW' -or $_.IsOffline -or $_.IsReadOnly }).Count) {
                    return New-ALFGuestCheck 'NotDone' 'Data disks are not ready. Run performs destructive disk cleanup.'
                }
                return New-ALFGuestCheck 'Done' 'Node configured; RAW data disks ready for cluster pooling.'
            }
            'Node/Arc' {
                $c = Get-ALFGuestScriptConfig $Folder $Task.Script @('Tenant', 'Subscription', 'RG', 'Region')
                $node = Get-ALFGuestScriptConfig $Folder '12.Node-Configure.ps1' @('AZLnodename')
                $agentPath = 'C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe'
                if (-not (Test-Path -LiteralPath $agentPath) -or -not (Get-Command Get-ArcBootstrapStatus -ErrorAction SilentlyContinue)) {
                    return New-ALFGuestCheck 'NotDone' 'Arc registration components are not available yet.'
                }
                $bootstrap = Get-ArcBootstrapStatus -ErrorAction Stop
                if ([string]::IsNullOrWhiteSpace($bootstrap.Response.Status)) { throw 'Arc bootstrap returned no status.' }
                if ($bootstrap.Response.Status -eq 'Failed') { return New-ALFGuestCheck 'Failed' 'Arc bootstrap reports failure; review the registration log.' }
                if ($bootstrap.Response.Status -ne 'Succeeded') { return New-ALFGuestCheck 'Attention' 'Arc bootstrap is incomplete or still updating.' }
                $agent = Get-ALFGuestArcAgentInfo $agentPath
                foreach ($field in 'status', 'resourceName', 'tenantId', 'subscriptionId', 'resourceGroup', 'location') {
                    if ([string]::IsNullOrWhiteSpace($agent.$field)) { throw "Arc agent status is missing '$field'." }
                }
                if ($agent.status -ine 'Connected' -or $agent.resourceName -ine $node.AZLnodename -or $agent.tenantId -ine $c.Tenant -or
                    $agent.subscriptionId -ine $c.Subscription -or $agent.resourceGroup -ine $c.RG -or $agent.location -ine $c.Region) {
                    return New-ALFGuestCheck 'Attention' 'Arc is disconnected or registered to a different Azure target.'
                }
                return New-ALFGuestCheck 'Done' 'Arc bootstrap succeeded; agent is connected to the planned Azure target.'
            }
            default { throw "No status check exists for $Role/$($Task.Id)." }
        }
    }
    catch {
        $allowRun = -not $clusterPresent -and -not ($Role -eq 'Node' -and $Task.Id -eq 'Configure')
        return New-ALFGuestCheck 'Attention' "Status check failed: $($_.Exception.Message)" $allowRun
    }
}

function Resolve-ALFGuestTaskState($Check, $Record, [bool]$Running, $Receipt, [string]$ReceiptError) {
    if ($Running) { return New-ALFGuestCheck 'Running' 'In its own PowerShell window.' $false }
    if ($ReceiptError) { return New-ALFGuestCheck 'Attention' $ReceiptError $Check.RunAllowed }
    if ($Check.State -eq 'Done') {
        if ($Receipt -and $Receipt.ExitCode -ne 0) { $Check.Detail += ' Last run reported an error; configuration is currently detected.' }
        if ($Record.LaunchError) { $Check.Detail += " $($Record.LaunchError)" }
        return $Check
    }
    if ($Check.RestartRequired -or $Check.State -eq 'Failed') { return $Check }
    if ($Record.LaunchError) { return New-ALFGuestCheck 'Failed' $Record.LaunchError $Check.RunAllowed }
    if ($Receipt -and $Receipt.ExitCode -ne 0) { return New-ALFGuestCheck 'Failed' "Last run failed. $($Check.Detail)" $Check.RunAllowed }
    if ($Receipt) { return New-ALFGuestCheck 'Attention' "Configuration incomplete. $($Check.Detail)" $Check.RunAllowed }
    if ($Record.Started) { return New-ALFGuestCheck 'Attention' "Restarted or interrupted. $($Check.Detail)" $Check.RunAllowed }
    return $Check
}

function ConvertTo-ALFGuestRecords($Saved, [string]$Role, [string]$Version, [string[]]$Ids) {
    $compatible = @($Version, '2.0.7', '2.0.8', '2.0.9', '2.0.10', '2.0.11', '2.0.12', '2.0.13', '2.0.14', '2.0.15', '2.0.16', '2.0.17', '2.0.18', '2.0.19', '2.0.20', '2.0.21', '2.0.22', '2.0.23')
    if ($Saved.Role -ne $Role -or $Saved.Version -notin $compatible -or
        ($Saved.SchemaVersion -and $Saved.SchemaVersion -notin 1, 2) -or -not $Saved.Steps) {
        throw 'State belongs to another role/release, or has an unsupported schema.'
    }
    $records = @{}
    foreach ($property in $Saved.Steps.PSObject.Properties) {
        if ($property.Name -notin $Ids) { continue }
        $record = @{}
        foreach ($field in $property.Value.PSObject.Properties) {
            if ($field.Name -in 'Started', 'ResultPath', 'ProcessId', 'ProcessStarted', 'LaunchError') { $record[$field.Name] = $field.Value }
        }
        $records[$property.Name] = $record
    }
    return $records
}
