##############################################################
# Version: ALF Lab Builder 2.0.14   (should match VERSION.txt - if this file was replaced on its own, check it is from the same release)
# 06dc.DC-SetNameAndIP.ps1
# Sets the DC's static IP, DNS, time zone and computer name
#
# RUN ON: INSIDE ContosoDC1, elevated PowerShell (signed in as local Administrator)
# NOTE:   restarts the VM at the end ONLY if the computer name changed
# SAFE TO RE-RUN: every step checks first and skips what's already done
#
# LEARN: Servers that provide infrastructure (DNS, AD, DHCP) always get a static IP.
#        DNS points to a public resolver for now - after AD is installed it points to itself.
#        A brand-new IP address isn't usable straight away: Windows first checks nobody
#        else on the network has it ("duplicate address detection", 2-3 seconds).
#        Testing before that finishes gives "Generic failure", so we wait for it.
##############################################################

$NewName   = "ContosoDC1"
$IPAddress = "{{DCIP}}"          #domain controller / DNS server - set in the Lab Builder
$Prefix    = [int]("{{LabSubnet}}".Split("/")[1])   #taken from the lab subnet
$Gateway   = "{{GatewayIP}}"       #the Hyper-V host's InternalSwitchNAT adapter
$TempDns   = "8.8.8.8"
$TimeZone  = "{{TimeZone}}"   #Windows time zone ID - set in the Lab Builder
$NicName   = "LAN"

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
if ("$IPAddress$Gateway" -match '\{\{') {
    throw "This script still has placeholders ({{...}}). Open the Planning Console (Launch-ALFLabBuilder.cmd), fill in the values, and use 'Roll out scripts'."
}

Write-Host "Configuring $NewName" -ForegroundColor Cyan


#========== NETWORK ADAPTER ==========

#Find the network adapter (expects exactly one)
Write-Host "  Find the network adapter" -ForegroundColor Cyan
$nic = @(Get-NetAdapter -Physical | Where-Object Status -eq 'Up')
if ($nic.Count -ne 1) {
    Get-NetAdapter | Format-Table Name, InterfaceDescription, Status -AutoSize
    throw "Expected 1 connected adapter, found $($nic.Count). On the host check: Get-VMNetworkAdapter -VMName ContosoDC1"
}
$nic = $nic[0]
Write-Host "    $($nic.Name) - $($nic.InterfaceDescription)"

#Friendly adapter name
Write-Host "  Rename adapter to $NicName" -ForegroundColor Cyan
if ($nic.Name -eq $NicName) {
    Write-Host "    Already named $NicName - skipping" -ForegroundColor Yellow
} else {
    Rename-NetAdapter -Name $nic.Name -NewName $NicName
}
$ifIndex = $nic.ifIndex


#========== STATIC IP ==========

Write-Host "  Set IP $IPAddress/$Prefix, gateway $Gateway" -ForegroundColor Cyan
$current = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
$currentGw = (Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).NextHop

if ($current.IPAddress -contains $IPAddress -and @($current).Count -eq 1 -and $current.PrefixLength -eq $Prefix -and $currentGw -eq $Gateway) {
    Write-Host "    Already set - skipping" -ForegroundColor Yellow
} else {
    Set-NetIPInterface -InterfaceIndex $ifIndex -Dhcp Disabled
    $current | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false
    New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $IPAddress -PrefixLength $Prefix -DefaultGateway $Gateway | Out-Null
}

#Wait for the new address to become usable (duplicate address detection)
Write-Host "  Wait for the address to become ready" -ForegroundColor Cyan
$ready = $false
for ($i = 1; $i -le 15; $i++) {
    $state = (Get-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $IPAddress -ErrorAction SilentlyContinue).AddressState
    if ($state -eq "Preferred") { $ready = $true; break }
    if ($state -eq "Duplicate") { throw "$IPAddress is already in use by another machine on the lab network" }
    Start-Sleep -Seconds 1
}
if ($ready) { Write-Host "    $IPAddress is ready" -ForegroundColor Green }
else        { Write-Warning "$IPAddress is still '$state' after 15 seconds - continuing anyway" }


#========== DNS + TIME ZONE ==========

Write-Host "  Set temporary DNS $TempDns" -ForegroundColor Cyan
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $TempDns

Write-Host "  Optional time zone $TimeZone" -ForegroundColor Cyan
Set-ALFOptionalGuestTimeZone $TimeZone


#========== CONNECTIVITY ==========
#LEARN: Three separate tests tell you WHERE a problem is:
#       gateway fails  -> the VM can't reach the host (wrong switch, or host IP/firewall rule missing)
#       DNS fails      -> the host can reach out but name lookups don't work
#       HTTPS fails    -> NAT isn't translating traffic to the internet
Write-Host "  Test connectivity" -ForegroundColor Cyan
$ProgressPreference = "SilentlyContinue"

#1. Gateway (retry a few times - the first ping after an IP change often times out)
$gwOK = $false
for ($i = 1; $i -le 5; $i++) {
    if ((Test-NetConnection -ComputerName $Gateway -InformationLevel Quiet -WarningAction SilentlyContinue)) { $gwOK = $true; break }
    Start-Sleep -Seconds 2
}
if ($gwOK) { Write-Host "    1. Gateway $Gateway    OK" -ForegroundColor Green }
else {
    Write-Warning "1. Gateway $Gateway not reachable. On the HOST check:"
    Write-Host "       Get-VMNetworkAdapter -VMName ContosoDC1 | Select SwitchName      (should be InternalSwitchNAT)"
    Write-Host "       Get-NetIPAddress -InterfaceAlias 'vEthernet (InternalSwitchNAT)'  (should show $Gateway)"
    Write-Host "       Get-NetFirewallRule -DisplayName 'Allow ICMPv4 from AzLocal lab'  (should exist - run 03)"
}

#2. DNS
$dnsOK = [bool](Resolve-DnsName www.microsoft.com -Server $TempDns -DnsOnly -ErrorAction SilentlyContinue)
if ($dnsOK) { Write-Host "    2. DNS lookup           OK" -ForegroundColor Green }
else { Write-Warning "2. DNS lookup through $TempDns failed - check the host NAT: Get-NetNat" }

#3. Internet (HTTPS)
$webOK = (Test-NetConnection www.microsoft.com -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded
if ($webOK) { Write-Host "    3. Internet (HTTPS)     OK" -ForegroundColor Green }
else { Write-Warning "3. No internet access - on the HOST check: Get-NetNat  (should show {{LabSubnet}})" }
$ProgressPreference = "Continue"

#Show the final network settings
Get-NetIPConfiguration -InterfaceIndex $ifIndex | Format-List InterfaceAlias, IPv4Address, IPv4DefaultGateway, DNSServer


#========== COMPUTER NAME ==========

Write-Host "  Set computer name $NewName" -ForegroundColor Cyan
if ($env:COMPUTERNAME -eq $NewName) {
    Write-Host "    Already named $NewName - no restart needed" -ForegroundColor Yellow
    Write-Host "Done. Next: run Windows Update (sconfig, option 6), then run 07dc.DC-CreateForest.ps1" -ForegroundColor Green
}
else {
    if (-not ($gwOK -and $webOK)) {
        Write-Warning "Connectivity tests failed - fix them before continuing (you can re-run this script after the restart)."
    }
    Rename-Computer -NewName $NewName -Force -WarningAction SilentlyContinue
    Write-Host "After the restart: run Windows Update (sconfig, option 6), then run 07dc.DC-CreateForest.ps1" -ForegroundColor Green
    Write-Host "Restarting in 10 seconds..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    Restart-Computer -Force
}
################
