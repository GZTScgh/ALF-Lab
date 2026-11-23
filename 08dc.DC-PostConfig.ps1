##############################################################
# Version: ALF Lab Builder 2.0.22   (should match VERSION.txt - if this file was replaced on its own, check it is from the same release)
# 08dc.DC-PostConfig.ps1
# DNS and (optional) DHCP for the lab after the forest is created
#
# RUN ON: INSIDE ContosoDC1, signed in as {{DomainNetbios}}\Administrator
#
# LEARN:
#   DNS forwarders - the DC answers lab names itself and forwards internet names.
#   Reverse zone   - lets IP addresses resolve back to names (PTR records).
#   Time           - Windows Time retains its configured source; Hyper-V time sync is disabled
#                    by the host scripts. This script does not configure upstream NTP.
#   DHCP           - optional convenience for extra lab VMs. Azure Local nodes use static IPs.
##############################################################

$DCIP        = "{{DCIP}}"   #set in the Lab Builder
$Forwarders  = @("8.8.8.8", "1.1.1.1")
$ReverseNet  = "{{LabSubnet}}"   #set in the Lab Builder
#Reverse zone name, built from the subnet - e.g. 192.168.44.0/24 -> 44.168.192.in-addr.arpa (/24 networks)
$NetOctets   = ($ReverseNet -split "/")[0].Split(".")
$ReverseZone = "$($NetOctets[2]).$($NetOctets[1]).$($NetOctets[0]).in-addr.arpa"

#Optional DHCP scope (keep it clear of node IPs and the Azure Local infrastructure pool)
$InstallDHCP = $true
$DhcpStart   = "{{DhcpStart}}"   #set in the Lab Builder
$DhcpEnd     = "{{DhcpEnd}}"
$DhcpMask    = "255.255.255.0"
$DhcpScopeId = ($ReverseNet -split "/")[0]   #network address of the lab subnet
$Gateway     = "{{GatewayIP}}"   #set in the Lab Builder
$DnsDomain   = "{{DomainFqdn}}"   #set in the Lab Builder

####### End of variables ######################


#Stop if this is the template (values not filled in by the Lab Builder yet)
if ("$DCIP$ReverseNet$Gateway$DhcpStart$DhcpEnd$DnsDomain" -match '\{\{') {
    throw "This script still has placeholders ({{...}}). Open the Planning Console (Launch-ALFLabBuilder.cmd), fill in the values, and use 'Roll out scripts'."
}

Write-Host "Post-configuring $env:COMPUTERNAME" -ForegroundColor Cyan

#Check AD is running
Write-Host "  Check AD services" -ForegroundColor Cyan
Get-Service NTDS, DNS, Netlogon, ADWS | Format-Table Name, Status -AutoSize
$Domain = Get-ADDomain
Write-Host "    Domain: $($Domain.DNSRoot)  NetBIOS: $($Domain.NetBIOSName)"

#DNS client points to itself
Write-Host "  Point DNS client at itself" -ForegroundColor Cyan
$ifIndex = (Get-NetIPAddress -IPAddress $DCIP).InterfaceIndex
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $DCIP, "127.0.0.1"

#Forwarders
Write-Host "  Set DNS forwarders $($Forwarders -join ', ')" -ForegroundColor Cyan
Set-DnsServerForwarder -IPAddress $Forwarders | Out-Null

#Reverse zone
Write-Host "  Create reverse lookup zone $ReverseZone" -ForegroundColor Cyan
if (Get-DnsServerZone -Name $ReverseZone -ErrorAction SilentlyContinue) {
    Write-Host "    Already exists - skipping" -ForegroundColor Yellow
} else {
    Add-DnsServerPrimaryZone -NetworkId $ReverseNet -ReplicationScope Forest
}
ipconfig /registerdns | Out-Null

#DHCP (optional)
if ($InstallDHCP) {
    Write-Host "  Install DHCP and create scope $DhcpStart - $DhcpEnd" -ForegroundColor Cyan
    Install-WindowsFeature DHCP -IncludeManagementTools | Out-Null
    netsh dhcp add securitygroups | Out-Null
    Restart-Service DHCPServer

    $DCFqdn = "$env:COMPUTERNAME.$DnsDomain"
    if (-not (Get-DhcpServerInDC | Where-Object IPAddress -eq $DCIP)) {
        Add-DhcpServerInDC -DnsName $DCFqdn -IPAddress $DCIP
    }
    #Tell Server Manager the post-install wizard is done
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12" -Name ConfigurationState -Value 2

    if (-not (Get-DhcpServerv4Scope -ScopeId $DhcpScopeId -ErrorAction SilentlyContinue)) {
        Add-DhcpServerv4Scope -Name "LabScope" -StartRange $DhcpStart -EndRange $DhcpEnd `
            -SubnetMask $DhcpMask -LeaseDuration (New-TimeSpan -Days 8) -State Active
    }
    Set-DhcpServerv4OptionValue -ScopeId $DhcpScopeId -Router $Gateway -DnsServer $DCIP -DnsDomain $DnsDomain
} else {
    Write-Host "  Skip DHCP" -ForegroundColor Cyan
}

#Verify
Write-Host "  Verify" -ForegroundColor Cyan
Resolve-DnsName www.microsoft.com -ErrorAction SilentlyContinue | Select-Object -First 1 Name, IPAddress | Format-Table -AutoSize
Write-Host "    Time source: $((w32tm /query /source).Trim())   (default - not changed by the lab)"
dcdiag /q

Write-Host "DC ready. (No dcdiag output above = healthy.) Next: run 09dc.DC-PrepareADForAzureLocal.ps1" -ForegroundColor Green
################
