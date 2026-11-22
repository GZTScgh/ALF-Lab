##############################################################
# Version: ALF Lab Builder 2.0.16   (should match VERSION.txt - if this file was replaced on its own, check it is from the same release)
# 10.Host-CreateNodeVMs.ps1
# Creates the Azure Local node VMs and boots them from the Azure Local ISO
#
# RUN ON: the Hyper-V host, elevated PowerShell
#
# LEARN: What every Azure Local node VM needs in a nested lab
#   - Generation 2 + vTPM + Secure Boot  (Azure Local requires TPM 2.0 and Secure Boot)
#   - static memory, no checkpoints
#   - nested virtualization exposed       (the node runs Hyper-V itself)
#   - MAC spoofing + teaming on every NIC (Network ATC creates virtual switches/teams inside)
#   - VLAN trunk on every NIC             (storage uses tagged VLANs 711/712 by default)
#   - Hyper-V time sync disabled         (Windows Time uses the guest/domain time source)
#   - 4 data disks for Storage Spaces Direct
##############################################################

#List of nodes to create
$NodeNameList = @("{{NodeName1}}", "{{NodeName2}}")   #set in the Lab Builder
. (Join-Path $PSScriptRoot 'ALFNodeSettings.ps1')
$NodeNameList = @(Get-ALFNodeNames (Join-Path $PSScriptRoot 'ALFHostConsole-Nodes.json') $NodeNameList)

#Where the VM folders go (each node gets its own subfolder)
$VMpath = "F:\VMs"

#Azure Local install .ISO
$InstallMedia = "C:\ISO\AzureLocal24H2.26100.32230.LCM.12.2608.0.3020.x64.en-us.iso"

#Where to download the ISO if it's missing from C:\ISO
#LEARN: aka.ms/hcireleaseimage/<release> points to the Azure Local ISO for that release.
#       2608 = the August 2026 release. Change the number for a newer release.
$InstallMediaUrl = "https://aka.ms/hcireleaseimage/2608"

#Size of each node
. (Join-Path $PSScriptRoot 'ALFGuestSizing.ps1')
$Sizing = Get-ALFPlannedGuestSizing
$Budget = Test-ALFLabSizing $Sizing
Assert-ALFGuestSizingHost $Sizing $Budget
$MemoryBytes = [long]$Sizing.NodeMemoryGB * 1GB
$CPUcores = [int]$Sizing.NodeVcpus

#Disks
$BootDiskSize = 200GB
$S2DDiskSize  = 1024GB
$S2DDiskCount = 4

#Virtual switches
$MgmtSwitch    = "InternalSwitchNAT"
$StorageSwitch = "StorageSwitch"

#Network adapter names (same names are used inside the node OS)
$MgmtAdapters    = @("1-MGMTCOMP1", "2-MGMTCOMP2")   #connect to $MgmtSwitch
$StorageAdapters = @("3-STORAGE1", "4-STORAGE2")     #connect to $StorageSwitch

#Key guardian name (lab only)
$GuardianName = "UntrustedGuardian"

#Automatically press a key to boot from the .ISO ($true / $false)
$AutoPressKey = $true

##############################################################


#Stop if this is the template (values not filled in by the Lab Builder yet)
if ("$NodeNameList" -match '\{\{') {
    throw "This script still has placeholders ({{...}}). Open the Planning Console (Launch-ALFLabBuilder.cmd), fill in the values, and use 'Roll out scripts'."
}

Test-ALFNodeNames $NodeNameList
Write-Host "Creating Azure Local node VMs" -ForegroundColor Cyan

#========== AZURE LOCAL ISO: CHECK, DOWNLOAD IF MISSING, VERIFY ==========
Write-Host "  Check for the Azure Local ISO" -ForegroundColor Cyan

#Clean up a leftover partial download from an earlier interrupted run
$TempFile = "$InstallMedia.download"
if (Test-Path $TempFile) {
    Write-Host "    Removing an unfinished earlier download" -ForegroundColor Yellow
    Remove-Item $TempFile -Force
}

if (Test-Path -Path $InstallMedia -PathType Leaf) {
    Write-Host "    Found: $InstallMedia ($([math]::Round((Get-Item $InstallMedia).Length/1GB,1)) GB)" -ForegroundColor Green
}
else {
    Write-Host "    Not found - downloading from $InstallMediaUrl" -ForegroundColor Yellow
    New-Item -Path (Split-Path $InstallMedia) -ItemType Directory -Force | Out-Null

    #Download to a temporary name first, so a half-finished download is never used
    #LEARN: BITS is Windows' built-in download engine - fast for multi-GB files, with a progress bar.
    #       If BITS can't follow the aka.ms redirect, Invoke-WebRequest is used instead.
    try {
        Start-BitsTransfer -Source $InstallMediaUrl -Destination $TempFile -DisplayName "Azure Local ISO" -ErrorAction Stop
    }
    catch {
        Write-Host "    BITS failed ($($_.Exception.Message)) - retrying with Invoke-WebRequest" -ForegroundColor Yellow
        $ProgressPreference = "SilentlyContinue"   #the progress bar makes Invoke-WebRequest very slow
        Invoke-WebRequest -Uri $InstallMediaUrl -OutFile $TempFile -UseBasicParsing
        $ProgressPreference = "Continue"
    }

    #A tiny file means a web page came back instead of the ISO
    $SizeGB = [math]::Round((Get-Item $TempFile).Length / 1GB, 1)
    if ($SizeGB -lt 3) {
        Remove-Item $TempFile -Force
        throw "Azure Local ISO download is only $SizeGB GB - check `$InstallMediaUrl (or download it from the Azure portal into C:\ISO)"
    }

    #Give it the name the rest of the script expects
    Move-Item -Path $TempFile -Destination $InstallMedia -Force
    Write-Host "    Downloaded: $InstallMedia ($SizeGB GB)" -ForegroundColor Green
}

#Confirm the ISO opens (proves it isn't corrupt or half-downloaded)
try {
    $IsoMount = Mount-DiskImage -ImagePath $InstallMedia -PassThru -ErrorAction Stop
    $IsoLabel = ($IsoMount | Get-Volume).FileSystemLabel
    Dismount-DiskImage -ImagePath $InstallMedia | Out-Null
    Write-Host "    ISO mounts correctly (label: $IsoLabel)" -ForegroundColor Green
}
catch {
    throw "$InstallMedia won't open - delete it and run this script again to re-download it"
}


#========== OTHER PRE-CHECKS ==========
Write-Host "  Run pre-checks" -ForegroundColor Cyan

#Confirm the virtual switches exist
if (-not (Get-VMSwitch -Name $MgmtSwitch -ErrorAction SilentlyContinue))    { throw "Switch not found: $MgmtSwitch" }
if (-not (Get-VMSwitch -Name $StorageSwitch -ErrorAction SilentlyContinue)) { throw "Switch not found: $StorageSwitch" }

#Confirm the host has enough free memory
$FreeGB   = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB)
$NeededGB = ($MemoryBytes / 1GB) * $NodeNameList.Count
Write-Host "    Host free memory: $FreeGB GB, nodes need: $NeededGB GB"
if ($FreeGB -lt $NeededGB) { Write-Warning "Not enough free memory - nodes may fail to start. Lower `$MemoryBytes or use a bigger host size." }

#Confirm the main VM folder exists
New-Item -Path $VMpath -ItemType Directory -Force | Out-Null

#Set up the key guardian (only creates it the first time on a fresh Hyper-V host)
#LEARN: The guardian protects the vTPM keys. "Untrusted" = local self-signed certs, lab only.
Write-Host "  Check key guardian $GuardianName" -ForegroundColor Cyan
if (-not (Get-HgsGuardian -Name $GuardianName -ErrorAction SilentlyContinue)) {
    New-HgsGuardian -Name $GuardianName -GenerateCertificates | Out-Null
}


#Create the nodes of the cluster, loop through each node name
foreach ($NodeName in $NodeNameList) {
    Write-Host "Processing node: $NodeName" -ForegroundColor Cyan

    #Existing VMs are not resized by this planning change; creation uses the saved allocations.
    if (Get-VM -Name $NodeName -ErrorAction SilentlyContinue) {
        Disable-VMIntegrationService -VMName $NodeName -Name "Time Synchronization" -ErrorAction Stop
        Write-Warning "$NodeName already exists - Time Synchronization disabled; skipping creation"
        continue
    }

    #Create a folder for this node's disks:  F:\VMs\<NodeName>\Virtual Hard Disks
    $DiskPath = "$VMpath\$NodeName\Virtual Hard Disks"
    New-Item -Path $DiskPath -ItemType Directory -Force | Out-Null

    #Create the boot disk
    Write-Host "  Create boot disk" -ForegroundColor Cyan
    $BootVHD = "$DiskPath\$NodeName-Boot.vhdx"
    New-VHD -Path $BootVHD -SizeBytes $BootDiskSize -Dynamic | Out-Null

    #Create the base VM, assign base properties
    Write-Host "  Create the VM" -ForegroundColor Cyan
    New-VM -Name $NodeName -MemoryStartupBytes $MemoryBytes -VHDPath $BootVHD -Generation 2 -Path $VMpath | Out-Null

    #Disable dynamic memory
    Set-VMMemory -VMName $NodeName -DynamicMemoryEnabled $false

    #Disable checkpoints
    Set-VM -VMName $NodeName -CheckpointType Disabled

    #Change the # of processors
    Write-Host "  Set $CPUcores vCPU, $($MemoryBytes/1GB) GB static memory, nested virtualization" -ForegroundColor Cyan
    Set-VMProcessor -VMName $NodeName -Count $CPUcores

    #Enable nested virtualization
    Set-VMProcessor -VMName $NodeName -ExposeVirtualizationExtensions $true

    #Remove the default network adapter
    Get-VMNetworkAdapter -VMName $NodeName | Remove-VMNetworkAdapter

    #Add the management/compute adapters
    Write-Host "  Add network adapters" -ForegroundColor Cyan
    foreach ($Adapter in $MgmtAdapters) {
        Add-VMNetworkAdapter -VMName $NodeName -Name $Adapter -SwitchName $MgmtSwitch
    }

    #Add the storage adapters
    foreach ($Adapter in $StorageAdapters) {
        Add-VMNetworkAdapter -VMName $NodeName -Name $Adapter -SwitchName $StorageSwitch
    }

    #Enable MAC spoofing, teaming, and device naming on all adapters
    #(device naming passes the adapter name into the node OS)
    Get-VMNetworkAdapter -VMName $NodeName | Set-VMNetworkAdapter -MacAddressSpoofing On -AllowTeaming On -DeviceNaming On

    #Allow VLAN-tagged traffic on all adapters (storage uses VLANs 711/712 by default)
    Get-VMNetworkAdapter -VMName $NodeName | Set-VMNetworkAdapterVlan -Trunk -NativeVlanId 0 -AllowedVlanIdList "0-1000"

    #Set up the key protector
    Write-Host "  Enable vTPM" -ForegroundColor Cyan
    $owner = Get-HgsGuardian -Name $GuardianName
    $kp = New-HgsKeyProtector -Owner $owner -AllowUntrustedRoot
    Set-VMKeyProtector -VMName $NodeName -KeyProtector $kp.RawData

    #Enable TPM
    Enable-VMTPM -VMName $NodeName

    #Create the S2D disks and attach them to the VM
    Write-Host "  Create and attach $S2DDiskCount S2D disks" -ForegroundColor Cyan
    for ($i = 1; $i -le $S2DDiskCount; $i++) {
        $S2DVHD = "$DiskPath\$NodeName-S2D$i.vhdx"
        New-VHD -Path $S2DVHD -SizeBytes $S2DDiskSize -Dynamic | Out-Null
        Add-VMHardDiskDrive -VMName $NodeName -Path $S2DVHD
    }

    #Keep Hyper-V host time separate from the guest/domain time source.
    Disable-VMIntegrationService -VMName $NodeName -Name "Time Synchronization" -ErrorAction Stop

    #Enable guest services (used by 05.Host-CopyScriptsToVM.ps1)
    Enable-VMIntegrationService -VMName $NodeName -Name "Guest Service Interface"

    #Mount the ISO
    Write-Host "  Attach install media and boot from it" -ForegroundColor Cyan
    $dvd = Add-VMDvdDrive -VMName $NodeName -Path $InstallMedia -Passthru

    #Boot from the ISO first
    Set-VMFirmware -VMName $NodeName -FirstBootDevice $dvd

    #Start the VM
    Write-Host "  Starting the node VM: $NodeName" -ForegroundColor Cyan
    Start-VM -Name $NodeName

    #Auto-press a key to boot from the .ISO
    #Sends Enter to the VM keyboard every half second for ~8 seconds
    if ($AutoPressKey) {
        $VMObject = Get-CimInstance -Namespace "root\virtualization\v2" -ClassName "Msvm_ComputerSystem" -Filter "ElementName='$NodeName'"
        for ($i = 1; $i -le 16; $i++) {
            try {
                $Keyboard = Get-CimAssociatedInstance -InputObject $VMObject -ResultClassName "Msvm_Keyboard" -ErrorAction Stop
                Invoke-CimMethod -InputObject $Keyboard -MethodName "TypeKey" -Arguments @{ keyCode = [uint32]13 } | Out-Null
            }
            catch { }   #keyboard isn't ready yet in the first second or two - just try again
            Start-Sleep -Milliseconds 500
        }
    }
}


#Show what was created
Get-VM -Name $NodeNameList | Format-Table Name, State, ProcessorCount, @{n='MemoryGB';e={$_.MemoryStartup/1GB}} -AutoSize
Get-VMHardDiskDrive -VMName $NodeNameList | Format-Table VMName, Path -AutoSize

Write-Host "Nodes created. GO INSTALL THE OS on each node (vmconnect) - pick the 200 GB boot drive." -ForegroundColor Green
Write-Host "Then set the local Administrator password and run 11.Host-PrepareNodes.ps1" -ForegroundColor Green
################
