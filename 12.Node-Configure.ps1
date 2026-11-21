######################  12.Node-Configure.ps1  ######################
# Version: ALF Lab Builder 2.0.14   (should match VERSION.txt - if this file was replaced on its own, check it is from the same release)
# CUSTOMISE EACH NODE - name, IP, DNS, time, Remote Desktop
#
# THIS FILE IS A TEMPLATE. Don't edit or run it on the host.
#   11.Host-PrepareNodes.ps1 makes one copy PER NODE with that node's name and IP
#   filled in, and copies it into the node as C:\ISO\12.Node-Configure.ps1
#
# RUN ON: INSIDE each node (SConfig option 15 -> PowerShell), as local Administrator:
#           cd C:\ISO
#           .\12.Node-Configure.ps1
#
# LEARN: Every node needs a static management IP and the DC as DNS. Wrong DNS breaks
#        Arc registration. Windows Time retains its configured source until domain join;
#        domain members normally follow the domain hierarchy. Hyper-V time sync is disabled.
#        Joining the domain is optional - the script asks at the end.
##################################################################

#variables here - filled in per node by 11.Host-PrepareNodes.ps1
$AZLnodename    = "__NODENAME__"
$IPAddress      = "__NODEIP__"

#same for every node
$InterfaceAlias = "1-MGMTCOMP1"     #Change if your adapter name is different
$PrefixLength   = [int]("{{LabSubnet}}".Split("/")[1])   #taken from the lab subnet (24 = 255.255.255.0)
$Gateway        = "{{GatewayIP}}"
$DNSServer1     = "{{DCIP}}"
$TimeZone       = "{{TimeZone}}"   #Windows time zone ID - set in the Lab Builder
#$MgmtVlanID    = 110               #Uncomment only if the management network uses a VLAN

#Local admin account created on every node (same on all nodes)
#LEARN: You'll use this account in the Azure portal deployment wizard as the "local administrator".
#       Its password must be IDENTICAL on every node. It comes from the Lab Builder, or the script asks.
#       Password rules: 14+ characters with an uppercase, lowercase, number and special character.
#       The name must NOT be the same as the LCM deployment user (script 09dc).
#       Choosing and remembering passwords is your responsibility.
$LocalAdminName     = "{{LocalAdminName}}"   #set in the Lab Builder
#Password: injected by the Lab Builder if you entered it there (plain text - keep this file safe).
#          If it was left empty, the script asks for it instead.
$LocalAdminPassword = '{{LocalAdminPassword}}'
$LocalAdminFullName = "Second local admin account"

#Expected number of data disks for Storage Spaces Direct (script 10 creates 4)
$ExpectedDataDisks  = 4

#Domain join (optional - asked at the end of the script)
$DomainName     = "contosolab.local"
$DomainOUPath   = ""                #Optional, e.g. "OU=Servers,DC=contosolab,DC=local" - leave blank for the default Computers container

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
if ("$LocalAdminName$Gateway$DNSServer1" -match '\{\{') {
    throw "This script still has placeholders ({{...}}). Open the Planning Console (Launch-ALFLabBuilder.cmd), fill in the values, and use 'Roll out scripts'."
}

#Stop if this is the unfilled template
if ($AZLnodename -like "__*" -or $IPAddress -like "__*") {
    throw "This is the template. Run 11.Host-PrepareNodes.ps1 on the host - it puts a filled-in copy in each node."
}

Write-Host "Configuring node: $AZLnodename ($IPAddress)" -ForegroundColor Cyan

#Confirm the management adapter exists
if (-not (Get-NetAdapter -Name $InterfaceAlias -ErrorAction SilentlyContinue)) {
    throw "Adapter '$InterfaceAlias' not found - run 11.Host-PrepareNodes.ps1 on the host first"
}

#set Management VLAN - if necessary
#Write-Host "  Set management VLAN" -ForegroundColor Cyan
#Set-NetAdapter -Name $InterfaceAlias -VlanID $MgmtVlanID -Confirm:$false

#disable DHCP on all network adapters (management gets a static IP below)
Write-Host "  Disable DHCP on all adapters" -ForegroundColor Cyan
Get-NetAdapter -Physical | ForEach-Object { Set-NetIPInterface -InterfaceIndex $_.ifIndex -Dhcp Disabled }

#Remove any old IP address and gateway from the management adapter (makes the script safe to re-run)
Write-Host "  Clear old IP settings on $InterfaceAlias" -ForegroundColor Cyan
Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false
Get-NetRoute -InterfaceAlias $InterfaceAlias -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false

#Set static IP address
Write-Host "  Set IP address $IPAddress/$PrefixLength, gateway $Gateway" -ForegroundColor Cyan
New-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $IPAddress -PrefixLength $PrefixLength -DefaultGateway $Gateway | Out-Null

#Set DNS server
Write-Host "  Set DNS server $DNSServer1" -ForegroundColor Cyan
Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ServerAddresses $DNSServer1

#Set time zone (display only - the clock itself is left at the Windows defaults)
Write-Host "  Optional time zone $TimeZone" -ForegroundColor Cyan
Set-ALFOptionalGuestTimeZone $TimeZone

#========== LOCAL ADMIN ACCOUNT ==========
Write-Host "  Local admin account $LocalAdminName" -ForegroundColor Cyan
$Exists = [bool](Get-LocalUser -Name $LocalAdminName -ErrorAction SilentlyContinue)
$SetPassword = $true
$HasInjected = $LocalAdminPassword -and ($LocalAdminPassword -notmatch '^\{\{')
if ($Exists -and -not $HasInjected) {
    Write-Host "    $LocalAdminName already exists." -ForegroundColor Yellow
    $SetPassword = (Read-Host "    Set a new password for it? (Y/N)") -match '^[Yy]$'
}

#Was the password injected by the Lab Builder?
$Injected = $LocalAdminPassword -and ($LocalAdminPassword -notmatch '^\{\{')
if ($Injected) { $SetPassword = $true }   #always set it, so every node ends up with the same password

if ($SetPassword) {
    if ($Injected) {
        Write-Host "    Using the password from the Lab Builder" -ForegroundColor Cyan
        $SecurePwd = ConvertTo-SecureString $LocalAdminPassword -AsPlainText -Force
        $p1 = $LocalAdminPassword; $p2 = $LocalAdminPassword
    } else {
        Write-Host "    Enter the password for $LocalAdminName - use the SAME password on every node." -ForegroundColor Cyan
        Write-Host "    14+ characters, with an uppercase, lowercase, number and special character" -ForegroundColor Yellow
        Write-Host "    Choosing and remembering passwords is your responsibility." -ForegroundColor Yellow
        $SecurePwd = Read-Host "    Password" -AsSecureString
        $SecurePwd2 = Read-Host "    Type it again" -AsSecureString
        $p1 = [System.Net.NetworkCredential]::new("", $SecurePwd).Password
        $p2 = [System.Net.NetworkCredential]::new("", $SecurePwd2).Password
    }
    if ($p1 -cne $p2) { throw "The two passwords don't match - run the script again" }
    if ($p1.Length -lt 14 -or $p1 -cnotmatch '[A-Z]' -or $p1 -cnotmatch '[a-z]' -or $p1 -notmatch '\d' -or $p1 -notmatch '[^A-Za-z0-9]') {
        throw "Password must be 14+ characters with an uppercase, lowercase, number and special character"
    }
    Remove-Variable p1, p2

    if ($Exists) {
        Set-LocalUser -Name $LocalAdminName -Password $SecurePwd -PasswordNeverExpires $true
        Write-Host "    Password updated" -ForegroundColor Green
    } else {
        New-LocalUser -Name $LocalAdminName -Password $SecurePwd -FullName $LocalAdminFullName `
            -Description "Local admin account" -PasswordNeverExpires | Out-Null
        Write-Host "    Created" -ForegroundColor Green
    }
}
if (-not (Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue | Where-Object Name -like "*\$LocalAdminName")) {
    Add-LocalGroupMember -Group "Administrators" -Member $LocalAdminName
}
Write-Host "    $LocalAdminName is a member of Administrators" -ForegroundColor Green


#========== OPTIONAL NETWORK SETTINGS ==========
#LEARN: Not needed for this lab - left here so you know they exist.
#Disable IPv6 - if necessary
#Disable-NetAdapterBinding -Name * -ComponentID ms_tcpip6

#Enable RDMA - if necessary (physical servers with RDMA-capable NICs; not used in a nested lab)
#Enable-NetAdapterRdma -Name "*"

#LEARN: Drivers and firmware - on physical servers, install the OEM's drivers/firmware here.
#       Not applicable to a virtual machine lab.
#LEARN: Keep Hyper-V Time Synchronization disabled on the host for this VM.
#       Check w32tm /query /source inside the guest: domain members normally use the domain
#       hierarchy (ContosoDC1 in this lab); unjoined guests use their configured Windows source.


#========== CLEAN THE DATA DISKS ==========
#LEARN: Storage Spaces Direct needs EMPTY data disks - no partitions, no old storage pools.
#       The Azure Local hardware check fails if a disk still has data on it (common on
#       rebuilds). Brand-new disks are RAW and are left alone.
#       Only disks that are NOT boot, NOT system and NOT USB are touched.
Write-Host "  Clean the data disks" -ForegroundColor Cyan

#Remove any old storage pools first (a disk in a pool can't be cleared)
$OldPools = Get-StoragePool -IsPrimordial $false -ErrorAction SilentlyContinue
foreach ($pool in $OldPools) {
    Write-Host "    Removing old storage pool $($pool.FriendlyName)" -ForegroundColor Yellow
    $pool | Set-StoragePool -IsReadOnly $false -ErrorAction SilentlyContinue
    $pool | Get-VirtualDisk -ErrorAction SilentlyContinue | Remove-VirtualDisk -Confirm:$false
    $pool | Remove-StoragePool -Confirm:$false
}

#Get disks that are: not boot, not system, not USB
$disks = Get-Disk | Where-Object {
    $_.BusType -ne 'USB' -and
    $_.IsBoot -eq $false -and
    $_.IsSystem -eq $false
}
if (@($disks).Count -ne $ExpectedDataDisks) {
    Write-Warning "Found $(@($disks).Count) data disks, expected $ExpectedDataDisks - check the VM's disks on the host"
}

foreach ($disk in $disks) {
    Write-Host "    Disk $($disk.Number) ($([math]::Round($disk.Size/1GB)) GB, $($disk.PartitionStyle))" -NoNewline

    #Bring online and make writable
    if ($disk.IsOffline)  { Set-Disk -Number $disk.Number -IsOffline $false }
    if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false }

    #Clear anything on it. RAW = already empty, nothing to do.
    if ($disk.PartitionStyle -eq 'RAW') {
        Write-Host " - already empty" -ForegroundColor Green
    } else {
        Clear-Disk -Number $disk.Number -RemoveData -RemoveOEM -Confirm:$false
        Write-Host " - cleared" -ForegroundColor Yellow
    }
}

#Show the status of the disks at the end (data disks should be RAW, CanPool = True)
Get-Disk | Sort-Object Number | Format-Table Number, FriendlyName, @{n='SizeGB';e={[math]::Round($_.Size/1GB)}},
    PartitionStyle, OperationalStatus, IsBoot -AutoSize
Get-PhysicalDisk | Sort-Object DeviceId | Format-Table DeviceId, FriendlyName, CanPool, CannotPoolReason -AutoSize


#Enable Remote Desktop
Write-Host "  Enable Remote Desktop" -ForegroundColor Cyan
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0

#Enable firewall rule for Remote Desktop
Write-Host "  Enable Remote Desktop firewall rule" -ForegroundColor Cyan
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

#Rename computer
Write-Host "  Rename computer to $AZLnodename" -ForegroundColor Cyan
Rename-Computer -NewName $AZLnodename -Force -WarningAction SilentlyContinue

#Quick check
Write-Host "  Test connection to gateway and DNS" -ForegroundColor Cyan
if (Test-Connection $Gateway -Count 2 -Quiet)    { Write-Host "    Gateway $Gateway OK" -ForegroundColor Green } else { Write-Warning "Gateway $Gateway not reachable" }
if (Test-Connection $DNSServer1 -Count 2 -Quiet) { Write-Host "    DNS $DNSServer1 OK" -ForegroundColor Green }    else { Write-Warning "DNS $DNSServer1 not reachable" }
Get-Date

#Join the domain (optional)
Write-Host ""
Write-Host "OPTIONAL: you can join this node to $DomainName now, or leave it in a workgroup." -ForegroundColor Yellow
Write-Host "Join this computer to $DomainName now? (Y/N)" -ForegroundColor Red -BackgroundColor Yellow
$joinChoice = Read-Host "Enter Y or N"
if ($joinChoice -match '^[Yy]$') {

    #Confirm the domain can be found through DNS
    Write-Host "  Check $DomainName can be resolved" -ForegroundColor Cyan
    if (-not (Resolve-DnsName $DomainName -ErrorAction SilentlyContinue)) {
        Write-Warning "Cannot resolve $DomainName - check DNS ($DNSServer1). Skipping domain join."
    }
    else {
        Write-Host "  Join $DomainName as $AZLnodename" -ForegroundColor Cyan
        Write-Host "  Choosing and remembering passwords is your responsibility." -ForegroundColor Yellow
        $DomainCred = Get-Credential -Message "Domain account allowed to join computers (e.g. CONTOSOLAB\Administrator)"

        $joinParams = @{
            DomainName = $DomainName
            Credential = $DomainCred
            Options    = "JoinWithNewName"   #uses the new computer name from the rename step above
            Force      = $true
        }
        if ($DomainOUPath) { $joinParams.OUPath = $DomainOUPath }

        try {
            Add-Computer @joinParams -ErrorAction Stop -WarningAction SilentlyContinue
            Write-Host "    Joined $DomainName" -ForegroundColor Green
        }
        catch {
            Write-Warning "Domain join failed: $($_.Exception.Message)"
        }
    }
}
else {
    Write-Host "  Skipping domain join" -ForegroundColor Cyan
}

Write-Host "Configuration complete. A restart is required for the computer name change." -ForegroundColor Green
Write-Host "Choosing and remembering passwords is your responsibility." -ForegroundColor Yellow
Write-Host "Local admin for the deployment wizard: $LocalAdminName  (password from the Lab Builder, or the one you typed)" -ForegroundColor Green
Write-Host "Would you like to reboot now? (Y/N)" -ForegroundColor Red -BackgroundColor Yellow
$choice = Read-Host "Enter Y or N"
if ($choice -match '^[Yy]$') {
    Restart-Computer
}
################
