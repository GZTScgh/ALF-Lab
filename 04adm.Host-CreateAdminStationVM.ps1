##############################################################
# Version: ALF Lab Builder 2.1.0   (should match VERSION.txt - if this file was replaced on its own, check it is from the same release)
# 04adm.Host-CreateAdminStationVM.ps1
# Creates the admin station VM from the Server 2025 evaluation VHDX
#
# RUN ON: the Hyper-V host, elevated PowerShell
# AFTER:  04dc.Host-CreateDCVM.ps1 (uses the same evaluation VHDX)
#
# LEARN: The admin station is a separate management server inside the lab. You sign in to it
#        to run Failover Cluster Manager, Hyper-V Manager, Active Directory and DNS tools
#        against the cluster - the same way you'd manage a real Azure Local cluster from a
#        management server, rather than signing in to the nodes themselves.
#        We COPY the evaluation VHDX so the original in C:\ISO stays clean and can be
#        reused. The disk's partition style decides the VM generation:
#        GPT = Generation 2 (UEFI, Secure Boot), MBR = Generation 1.
##############################################################

$VMName     = "{{AdminStationName}}"   #set in the Lab Builder
$VMRoot     = "F:\VMs"
$SourceVhd  = "C:\ISO\26100.1742.amd64fre.ge_release_svc_refresh.240906-0331_server_serverdatacentereval_en-us.vhdx"
$SwitchName = "InternalSwitchNAT"
. (Join-Path $PSScriptRoot 'ALFGuestSizing.ps1')
$Sizing = Get-ALFPlannedGuestSizing
$Budget = Test-ALFLabSizing $Sizing
Assert-ALFGuestSizingHost $Sizing $Budget
$Memory = [long]$Sizing.AdminMemoryGB * 1GB
$vCPU = [int]$Sizing.AdminVcpus

####### End of variables ######################


#Stop if this is the template (values not filled in by the Lab Builder yet)
if ("$VMName" -match '\{\{') {
    throw "This script still has placeholders ({{...}}). Open the Planning Console (Launch-ALFLabBuilder.cmd), fill in the values, and use 'Roll out scripts'."
}

Write-Host "Creating admin station VM: $VMName" -ForegroundColor Cyan

$VMFolder = Join-Path $VMRoot $VMName
$DiskPath = Join-Path $VMFolder "Virtual Hard Disks"
$VhdPath  = Join-Path $DiskPath "$VMName.vhdx"

#Pre-checks
Write-Host "  Run pre-checks" -ForegroundColor Cyan
if (-not (Test-Path $SourceVhd -PathType Leaf)) { throw "Source VHDX not found: $SourceVhd - run 01.Host-PrepareDataDisk.ps1 to download it" }
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) { throw "VM '$VMName' already exists" }
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) { throw "Switch '$SwitchName' not found - run 03.Host-CreateVMSwitches.ps1" }
if (Test-Path $VhdPath) { throw "Disk already exists: $VhdPath" }

#Detect partition style -> VM generation
Write-Host "  Detect disk partition style" -ForegroundColor Cyan
$style = (Mount-VHD -Path $SourceVhd -ReadOnly -NoDriveLetter -Passthru | Get-Disk).PartitionStyle
Dismount-VHD -Path $SourceVhd
$Gen = if ($style -eq 'GPT') { 2 } else { 1 }
Write-Host "    $style -> Generation $Gen"

#Copy the disk
Write-Host "  Copy evaluation VHDX to $VhdPath" -ForegroundColor Cyan
New-Item -Path $DiskPath -ItemType Directory -Force | Out-Null
Copy-Item -Path $SourceVhd -Destination $VhdPath

#Create the VM
Write-Host "  Create the VM" -ForegroundColor Cyan
New-VM -Name $VMName -Generation $Gen -MemoryStartupBytes $Memory `
       -VHDPath $VhdPath -Path $VMRoot -SwitchName $SwitchName | Out-Null

#Configure CPU, memory, checkpoints, start/stop behaviour
Write-Host "  Set $vCPU vCPU, static memory, no checkpoints" -ForegroundColor Cyan
Set-VM -Name $VMName -ProcessorCount $vCPU -StaticMemory -CheckpointType Disabled `
       -AutomaticStartAction Start -AutomaticStopAction ShutDown
if ($Gen -eq 2) { Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows }

#Let Windows Time use the guest's configured source/domain hierarchy, not the Hyper-V host.
Write-Host "  Disable Hyper-V Time Synchronization" -ForegroundColor Cyan
Disable-VMIntegrationService -VMName $VMName -Name "Time Synchronization" -ErrorAction Stop

#Guest services on - lets us copy scripts into the VM with Copy-VMFile
Write-Host "  Enable Guest Service Interface" -ForegroundColor Cyan
Enable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface"

#Start
Write-Host "  Start the VM" -ForegroundColor Cyan
Start-VM -Name $VMName

Get-VM -Name $VMName | Format-Table Name, State, Generation, ProcessorCount, @{n='MemoryGB';e={$_.MemoryStartup/1GB}} -AutoSize
Write-Host "Admin station VM created." -ForegroundColor Green
Write-Host "Next: vmconnect localhost $VMName  - finish first-boot setup and set the Administrator password" -ForegroundColor Green
Write-Host "Configure it with 08adm.Admin-Configure.ps1 AFTER the domain controller is ready (scripts 06dc, 07dc and 08dc)." -ForegroundColor Green
################
