##############################################################
# Version: ALF Lab Builder 2.0.14   (should match VERSION.txt - if this file was replaced on its own, check it is from the same release)
# 08adm.Admin-Configure.ps1
# Sets up the admin station: IP, DNS, management tools, then name + domain join
#
# RUN ON: INSIDE the admin station VM, elevated PowerShell (signed in as local Administrator)
# AFTER:  the domain controller is ready (06dc, 07dc, 08dc) - the admin station uses it for DNS
# COPY IT IN: on the host, run 05.Host-CopyScriptsToVM.ps1
# NOTE:   restarts at the end (asks first) to finish the rename and domain join
# SAFE TO RE-RUN: every step checks first
#
# LEARN: Why an admin station?
#   In a real deployment you don't sign in to the cluster nodes to manage them - you use
#   management tools on a separate server or workstation. The admin station is that server:
#     Failover Cluster Manager  - the cluster, its nodes, disks, networks and roles
#     Hyper-V Manager           - the virtual machines running on the nodes
#     AD and DNS tools          - the cluster's OU, computer objects and DNS records
#   It must be joined to the same domain as the cluster to manage it.
##############################################################

$NewName    = "{{AdminStationName}}"   #computer name (same as the VM name) - set in the Lab Builder
$IPAddress  = "{{AdminStationIP}}"     #set in the Lab Builder
$Prefix     = [int]("{{LabSubnet}}".Split("/")[1])   #taken from the lab subnet
$Gateway    = "{{GatewayIP}}"
$DNSServer  = "{{DCIP}}"               #the domain controller
$DomainName = "contosolab.local"
$TimeZone   = "{{TimeZone}}"   #Windows time zone ID - set in the Lab Builder
$NicName    = "LAN"

#Management tools to install
#LEARN: RSAT = Remote Server Administration Tools - the consoles and PowerShell modules
#       for managing servers remotely. Installing them doesn't add the roles themselves.
$Tools = @(
    "RSAT-Clustering"          #Failover Cluster Manager + FailoverClusters PowerShell module
    "RSAT-Hyper-V-Tools"       #Hyper-V management tools: Hyper-V Manager + Hyper-V PowerShell module
    "RSAT-AD-Tools"            #Active Directory Users and Computers + AD PowerShell module
    "RSAT-DNS-Server"          #DNS Manager
    "GPMC"                     #Group Policy Management
)

####### End of variables ######################


function Set-ALFOptionalGuestTimeZone([string]$RequestedId) {
    try {
        if ([string]::IsNullOrWhiteSpace($RequestedId) -or $RequestedId -match '\{\{|^<TimeZone>$') {
            Write-Host '    Optional time zone not supplied - keeping the current setting.' -ForegroundColor Yellow
            return
        }
        $target = $RequestedId
        $available = @(Get-TimeZone -ListAvailable -ErrorAction Stop)
        if (-not ($available | Where-Object Id -eq $target)) {
            $target = 'Eastern Standard Time'
            Write-Host "    Time zone '$RequestedId' is unavailable - trying Eastern Standard Time." -ForegroundColor Yellow
            if (-not ($available | Where-Object Id -eq $target)) { throw 'Eastern Standard Time is also unavailable.' }
        }
        if ((Get-TimeZone -ErrorAction Stop).Id -eq $target) {
            Write-Host "    Already $target - skipping." -ForegroundColor Yellow
        }
        else {
            Set-TimeZone -Id $target -ErrorAction Stop
            Write-Host "    Set to $target." -ForegroundColor Cyan
        }
    }
    catch {
        Write-Host "    Optional time-zone change skipped: $($_.Exception.Message) Guest configuration will continue." -ForegroundColor Yellow
    }
}

#Stop if this is the template (values not filled in by the Lab Builder yet)
if ("$NewName$IPAddress$Gateway$DNSServer" -match '\{\{') {
    throw "This script still has placeholders ({{...}}). Open the Planning Console (Launch-ALFLabBuilder.cmd), fill in the values, and use 'Roll out scripts'."
}

Write-Host "Configuring admin station $NewName" -ForegroundColor Cyan


#========== NETWORK ==========
Write-Host "  Find the network adapter" -ForegroundColor Cyan
$nic = @(Get-NetAdapter -Physical | Where-Object Status -eq 'Up')
if ($nic.Count -ne 1) { throw "Expected 1 connected adapter, found $($nic.Count)" }
$nic = $nic[0]
if ($nic.Name -ne $NicName) { Rename-NetAdapter -Name $nic.Name -NewName $NicName }
$ifIndex = $nic.ifIndex

Write-Host "  Set IP $IPAddress/$Prefix, gateway $Gateway" -ForegroundColor Cyan
$current   = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
$currentGw = (Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).NextHop
if ($current.IPAddress -contains $IPAddress -and @($current).Count -eq 1 -and $currentGw -eq $Gateway) {
    Write-Host "    Already set - skipping" -ForegroundColor Yellow
} else {
    Set-NetIPInterface -InterfaceIndex $ifIndex -Dhcp Disabled
    $current | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false
    New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $IPAddress -PrefixLength $Prefix -DefaultGateway $Gateway | Out-Null
}

#Wait for the new address to become usable (duplicate address detection)
for ($i = 1; $i -le 15; $i++) {
    $state = (Get-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $IPAddress -ErrorAction SilentlyContinue).AddressState
    if ($state -eq "Preferred") { break }
    if ($state -eq "Duplicate") { throw "$IPAddress is already in use by another machine on the lab network" }
    Start-Sleep -Seconds 1
}

#DNS = the domain controller (needed to find and join the domain)
Write-Host "  Set DNS server $DNSServer (the domain controller)" -ForegroundColor Cyan
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $DNSServer

Write-Host "  Optional time zone $TimeZone" -ForegroundColor Cyan
Set-ALFOptionalGuestTimeZone $TimeZone

#Connectivity
Write-Host "  Test connectivity" -ForegroundColor Cyan
$ProgressPreference = "SilentlyContinue"
$dcOK  = Test-NetConnection -ComputerName $DNSServer -InformationLevel Quiet -WarningAction SilentlyContinue
$domOK = [bool](Resolve-DnsName $DomainName -ErrorAction SilentlyContinue)
$webOK = (Test-NetConnection www.microsoft.com -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded
$ProgressPreference = "Continue"
if ($dcOK)  { Write-Host "    Domain controller $DNSServer reachable" -ForegroundColor Green } else { Write-Warning "Can't reach the domain controller $DNSServer" }
if ($domOK) { Write-Host "    $DomainName resolves"                  -ForegroundColor Green } else { Write-Warning "Can't resolve $DomainName - is the DC finished (scripts 07dc and 08dc)?" }
if ($webOK) { Write-Host "    Internet (HTTPS) OK"                    -ForegroundColor Green } else { Write-Warning "No internet access - check the host NAT" }


#========== MANAGEMENT TOOLS ==========
Write-Host "  Install management tools" -ForegroundColor Cyan
foreach ($t in $Tools) {
    $f = Get-WindowsFeature -Name $t
    if ($f.Installed) { Write-Host "    $($f.DisplayName) - already installed" -ForegroundColor Yellow }
    else {
        Install-WindowsFeature -Name $t -IncludeAllSubFeature | Out-Null
        Write-Host "    $($f.DisplayName) - installed" -ForegroundColor Green
    }
}


#========== NAME + DOMAIN JOIN ==========
#LEARN: Rename and join in one go - "JoinWithNewName" joins with the new name, so only
#       one restart is needed for both.
$joined = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
$named  = $env:COMPUTERNAME -eq $NewName

if ($joined -and $named) {
    Write-Host "  Already named $NewName and joined to the domain - nothing to do" -ForegroundColor Yellow
    Write-Host "Admin station ready. Sign in as CONTOSOLAB\Administrator and open Failover Cluster Manager." -ForegroundColor Green
    return
}

if (-not $domOK) { throw "Can't resolve $DomainName - finish the domain controller (scripts 07dc and 08dc) and run this script again" }

Write-Host "  Rename to $NewName and join $DomainName" -ForegroundColor Cyan
Write-Host "  Choosing and remembering passwords is your responsibility." -ForegroundColor Yellow
$DomainCred = Get-Credential -Message "Domain account allowed to join computers (e.g. CONTOSOLAB\Administrator)"

$joinParams = @{ DomainName = $DomainName; Credential = $DomainCred; Force = $true; ErrorAction = "Stop" }
if (-not $named) { $joinParams.NewName = $NewName }
Add-Computer @joinParams -WarningAction SilentlyContinue
Write-Host "    Joined $DomainName as $NewName" -ForegroundColor Green

Write-Host ""
Write-Host "Admin station configured. A restart is needed to finish the rename and domain join." -ForegroundColor Green
Write-Host "After the restart, sign in as CONTOSOLAB\Administrator and open Failover Cluster Manager (cluadmin.msc)." -ForegroundColor Green
Write-Host "Would you like to restart now? (Y/N)" -ForegroundColor Red -BackgroundColor Yellow
if ((Read-Host "Enter Y or N") -match '^[Yy]$') { Restart-Computer -Force }
################
