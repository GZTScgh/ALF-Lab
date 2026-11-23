##############################################################
# Version: ALF Lab Builder 2.0.21   (should match VERSION.txt - if this file was replaced on its own, check it is from the same release)
# 03.Host-CreateVMSwitches.ps1
# Creates the lab virtual switches on the Hyper-V host
#
#   InternalSwitchNAT - management/compute traffic, internet access through NAT
#   StorageSwitch     - storage traffic, node-to-node only (no host, no internet)
#
# RUN ON: the Hyper-V host (Azure VM), elevated PowerShell, after Hyper-V is installed
#
# LEARN: Why NAT and not an External switch?
#   Azure only delivers traffic to the IP/MAC addresses it assigned to the VM's NIC.
#   Nested VMs on an External switch get no DHCP and their traffic is dropped.
#   With NAT, the host acts like a home router: lab VMs use 192.168.44.x and the
#   host translates their traffic to its own Azure address.
#   The lab range must NOT overlap the Azure VNet the host sits on.
##############################################################

#NAT switch (management + compute)
$NATSwitchName = "InternalSwitchNAT"
$GatewayIP     = "{{GatewayIP}}"       #host side of the NAT switch = default gateway for all lab VMs
$PrefixLength  = [int]("{{LabSubnet}}".Split("/")[1])   #taken from the lab subnet
$NATPrefix     = "{{LabSubnet}}"    #lab network - must NOT overlap the Azure VNet
$NATName       = "LabNAT"

#Private switch (storage)
$StorageSwitchName = "StorageSwitch"

#Firewall rule name
$FirewallRuleName = "Allow ICMPv4 from AzLocal lab"

####### End of variables ######################


#Stop if this is the template (values not filled in by the Lab Builder yet)
if ("$GatewayIP$NATPrefix" -match '\{\{') {
    throw "This script still has placeholders ({{...}}). Open the Planning Console (Launch-ALFLabBuilder.cmd), fill in the values, and use 'Roll out scripts'."
}

Write-Host "Creating lab virtual switches" -ForegroundColor Cyan

#Confirm Hyper-V is running
if (-not (Get-Command New-VMSwitch -ErrorAction SilentlyContinue)) {
    throw "Hyper-V PowerShell module not found - run 02.Host-InstallHyperV.ps1 first"
}

#Show the host's Azure IP so you can confirm the lab range doesn't overlap it
Write-Host "  Host's Azure network address (must NOT be in $NATPrefix):" -ForegroundColor Cyan
Get-NetIPAddress -AddressFamily IPv4 | Where-Object PrefixOrigin -eq "Dhcp" |
    ForEach-Object { Write-Host "    $($_.InterfaceAlias): $($_.IPAddress)/$($_.PrefixLength)" }


#========== NAT SWITCH ==========

#Create the internal switch
Write-Host "  Create internal switch $NATSwitchName" -ForegroundColor Cyan
if (Get-VMSwitch -Name $NATSwitchName -ErrorAction SilentlyContinue) {
    Write-Host "    Already exists - skipping" -ForegroundColor Yellow
} else {
    New-VMSwitch -Name $NATSwitchName -SwitchType Internal | Out-Null
}

#Assign the gateway IP to the host's adapter on that switch
$HostAdapter = "vEthernet ($NATSwitchName)"
Write-Host "  Assign gateway IP $GatewayIP/$PrefixLength to $HostAdapter" -ForegroundColor Cyan
if (Get-NetIPAddress -InterfaceAlias $HostAdapter -IPAddress $GatewayIP -ErrorAction SilentlyContinue) {
    Write-Host "    Already assigned - skipping" -ForegroundColor Yellow
} else {
    New-NetIPAddress -InterfaceAlias $HostAdapter -IPAddress $GatewayIP -PrefixLength $PrefixLength | Out-Null
}

#Create the NAT
Write-Host "  Create NAT $NATName for $NATPrefix" -ForegroundColor Cyan
if (Get-NetNat | Where-Object InternalIPInterfaceAddressPrefix -eq $NATPrefix) {
    Write-Host "    NAT for $NATPrefix already exists - skipping" -ForegroundColor Yellow
} else {
    New-NetNat -Name $NATName -InternalIPInterfaceAddressPrefix $NATPrefix | Out-Null
}

#Allow lab VMs to ping the gateway (needed by the Azure Local infra IP check)
Write-Host "  Create firewall rule: $FirewallRuleName" -ForegroundColor Cyan
if (Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue) {
    Write-Host "    Already exists - skipping" -ForegroundColor Yellow
} else {
    New-NetFirewallRule -DisplayName $FirewallRuleName -Direction Inbound `
        -Protocol ICMPv4 -IcmpType 8 -RemoteAddress $NATPrefix -Action Allow -Profile Any | Out-Null
}


#========== STORAGE SWITCH ==========

#Create the private switch
Write-Host "  Create private switch $StorageSwitchName" -ForegroundColor Cyan
if (Get-VMSwitch -Name $StorageSwitchName -ErrorAction SilentlyContinue) {
    Write-Host "    Already exists - skipping" -ForegroundColor Yellow
} else {
    New-VMSwitch -Name $StorageSwitchName -SwitchType Private | Out-Null
}


#========== VERIFY ==========
Write-Host "  Verify" -ForegroundColor Cyan
Get-VMSwitch | Format-Table Name, SwitchType -AutoSize
Get-NetIPAddress -InterfaceAlias $HostAdapter -AddressFamily IPv4 | Format-Table InterfaceAlias, IPAddress, PrefixLength -AutoSize
Get-NetNat | Format-Table Name, InternalIPInterfaceAddressPrefix -AutoSize

Write-Host "Virtual switches ready. Next: run 04dc.Host-CreateDCVM.ps1" -ForegroundColor Green
################
