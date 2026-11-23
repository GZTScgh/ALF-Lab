##############################################################
# Version: ALF Lab Builder 2.0.21   (should match VERSION.txt - if this file was replaced on its own, check it is from the same release)
# 01.Host-PrepareDataDisk.ps1
# Prepares the lab host:
#   1. Creates C:\ISO and F:\VMs
#   2. Brings the 1 TB data disk online as F:
#   3. Gets the two install images into C:\ISO (downloads them if missing)
#      (with -DiskOnly it stops after step 2 - the Host Console downloads the images itself)
#        - Windows Server 2025 evaluation VHDX  (for the domain controller)
#        - Azure Local ISO                      (for the cluster nodes)
#
# RUN ON: the Hyper-V host (Azure VM), elevated PowerShell
#
# BEFORE YOU RUN THIS (one time, typed by hand):
#   New-Item -Path C:\ISO -ItemType Directory -Force
#   ...copy all the lab .ps1 files into C:\ISO, then:
#   Get-ChildItem C:\ISO\*.ps1 | Unblock-File
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
#   cd C:\ISO
#   .\01.Host-PrepareDataDisk.ps1
#
# LEARN: A new Azure data disk arrives "RAW" - no partition table, no file system.
#        We only touch RAW disks bigger than 900 GB, so the OS disk is never at risk.
#        ReFS + 64 KB clusters is the recommended format for volumes holding VHDX files.
#        Downloading INSIDE the Azure VM is much faster than uploading through RDP -
#        the files come straight from Microsoft's network.
##############################################################

#-DiskOnly: time zone, data disk and folders only. The Host Console runs it this way and
#           downloads the two images itself, with a progress bar.
param([switch]$DiskOnly)

#Time zone - set in the Lab Builder (detected from the PC running it)
$TimeZone     = "{{TimeZone}}"

#Data disk
$DriveLetter  = "F"
$VolumeLabel  = "LabData"
$MinDiskSize  = 900GB
$LabFolders   = @("C:\ISO", "F:\VMs")    #C:\ISO = scripts + images.  F:\VMs = every lab VM

#Image 1 - Windows Server 2025 evaluation VHDX (domain controller)
#LEARN: This is the Evaluation Center's "VHD download 64-bit edition" (English) link from
#       https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025
#       It's a go.microsoft.com/fwlink link that points to the current evaluation build.
#       If the download ever fails, copy a fresh link from that page and paste it here.
$ServerVhd    = "C:\ISO\26100.1742.amd64fre.ge_release_svc_refresh.240906-0331_server_serverdatacentereval_en-us.vhdx"
$ServerVhdUrl = "https://go.microsoft.com/fwlink/?linkid=2345826&clcid=0x409&culture=en-us&country=us"
$ServerVhdPage = "https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025"

#Image 2 - Azure Local ISO (cluster nodes)
#LEARN: aka.ms/hcireleaseimage/<release> points to the Azure Local ISO for that release.
#       The portal route (Azure portal -> Azure Local -> Get started -> Download software)
#       gives the same image. If $AzureLocalIsoUrl is ever blank, the script falls back to
#       opening that portal page and waiting for you to download it in the browser.
$AzureLocalIso    = "C:\ISO\AzureLocal24H2.26100.32230.LCM.12.2608.0.3020.x64.en-us.iso"
$AzureLocalIsoUrl = "https://aka.ms/hcireleaseimage/2608"   #2608 = Azure Local release; change the number for a newer release
$AzureLocalPage   = "https://portal.azure.com/#view/Microsoft_Azure_ArcCenterUX/ArcCenterMenuBlade/~/hciGetStarted"

####### End of variables ######################


#========== TIME ZONE ==========
#LEARN: Azure VMs start in UTC. Setting the host to the same time zone as the rest of the lab
#       makes Hyper-V, event log and script timestamps line up with the DC, admin station and nodes.
#       This only changes how the time is SHOWN - the clock itself still comes from Azure.
function Set-ALFOptionalHostTimeZone([string]$RequestedId) {
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
        Write-Host "    Optional time-zone change skipped: $($_.Exception.Message) Host configuration will continue." -ForegroundColor Yellow
    }
}

Write-Host "Setting optional time zone" -ForegroundColor Cyan
Set-ALFOptionalHostTimeZone $TimeZone


#========== HELPER: download a large file safely ==========
#LEARN: BITS (Background Intelligent Transfer Service) is Windows' built-in download engine.
#       It's much faster than Invoke-WebRequest for multi-GB files and shows a progress bar.
#       We download to a temporary ".download" name so a half-finished file is never used.
function Get-LabFile {
    param([string]$Url, [string]$Destination, [string]$Name, [double]$MinSizeGB)

    $TempFile = "$Destination.download"
    Write-Host "    Downloading $Name..." -ForegroundColor Cyan
    try {
        Start-BitsTransfer -Source $Url -Destination $TempFile -DisplayName $Name -ErrorAction Stop
    }
    catch {
        Write-Host "    BITS failed ($($_.Exception.Message)) - retrying with Invoke-WebRequest" -ForegroundColor Yellow
        $ProgressPreference = "SilentlyContinue"   #the progress bar makes Invoke-WebRequest very slow
        Invoke-WebRequest -Uri $Url -OutFile $TempFile -UseBasicParsing
        $ProgressPreference = "Continue"
    }

    #A tiny file means we downloaded a web page instead of the image
    $SizeGB = [math]::Round((Get-Item $TempFile).Length / 1GB, 1)
    if ($SizeGB -lt $MinSizeGB) {
        Remove-Item $TempFile -Force
        throw "$Name download is only $SizeGB GB - the link is probably wrong or expired. Copy a fresh link."
    }
    Move-Item -Path $TempFile -Destination $Destination -Force
    Write-Host "    Downloaded: $Destination ($SizeGB GB)" -ForegroundColor Green
}

#========== HELPER: wait for a browser download, then move it to C:\ISO ==========
function Wait-ForBrowserDownload {
    param([string]$Page, [string]$Pattern, [string]$Destination, [string]$Name, [double]$MinSizeGB)

    $Downloads = Join-Path $env:USERPROFILE "Downloads"
    Write-Host "    Opening $Name download page in the browser..." -ForegroundColor Cyan
    Start-Process $Page
    Write-Host "    Download $Name in the browser (it saves to $Downloads)." -ForegroundColor Yellow
    Read-Host "    Press Enter here when the download has FINISHED" | Out-Null

    $File = Get-ChildItem -Path $Downloads -Filter $Pattern -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $File) { throw "No file matching '$Pattern' found in $Downloads - download it, then run this script again" }

    $SizeGB = [math]::Round($File.Length / 1GB, 1)
    if ($SizeGB -lt $MinSizeGB) { throw "$($File.Name) is only $SizeGB GB - is the download still running?" }

    Write-Host "    Moving $($File.Name) to $Destination" -ForegroundColor Cyan
    Move-Item -Path $File.FullName -Destination $Destination -Force
    Write-Host "    Ready: $Destination ($SizeGB GB)" -ForegroundColor Green
}


Write-Host "Preparing the lab host: $env:COMPUTERNAME" -ForegroundColor Cyan

#Show the host size - nodes need ~74 GB RAM in total (2 x 36 GB + 2 GB DC)
Write-Host "  Host resources" -ForegroundColor Cyan
$cs = Get-CimInstance Win32_ComputerSystem
Write-Host "    Logical processors: $($cs.NumberOfLogicalProcessors)"
Write-Host "    Memory            : $([math]::Round($cs.TotalPhysicalMemory/1GB)) GB"

#Create C:\ISO first (holds the scripts and the two images)
Write-Host "  Create C:\ISO" -ForegroundColor Cyan
New-Item -Path "C:\ISO" -ItemType Directory -Force | Out-Null


#========== DATA DISK ==========

#Show all disks
Write-Host "  Current disks" -ForegroundColor Cyan
Get-Disk | Format-Table Number, FriendlyName, @{n='SizeGB';e={[math]::Round($_.Size/1GB)}}, PartitionStyle, OperationalStatus, BusType -AutoSize

#Bring the data disk online and format it (skips if F: already exists)
Write-Host "  Bring the data disk online as ${DriveLetter}:" -ForegroundColor Cyan
if (Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue) {
    Write-Host "    ${DriveLetter}: already exists - skipping" -ForegroundColor Yellow
} else {
    $disk = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' -and $_.Size -gt $MinDiskSize } | Select-Object -First 1
    if (-not $disk) { throw "No RAW disk larger than $($MinDiskSize/1GB) GB found - is the data disk attached?" }
    Write-Host "    Using disk $($disk.Number): $([math]::Round($disk.Size/1GB)) GB"

    #Online + writable
    if ($disk.IsOffline)  { Set-Disk -Number $disk.Number -IsOffline $false }
    if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false }

    #Initialize (GPT), partition, format
    Write-Host "  Initialize GPT, create partition, format ReFS 64 KB" -ForegroundColor Cyan
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru |
        New-Partition -DriveLetter $DriveLetter -UseMaximumSize |
        Format-Volume -FileSystem ReFS -AllocationUnitSize 65536 -NewFileSystemLabel $VolumeLabel -Confirm:$false | Out-Null
}

#Create the lab folders
Write-Host "  Create lab folders" -ForegroundColor Cyan
foreach ($folder in $LabFolders) {
    New-Item -Path $folder -ItemType Directory -Force | Out-Null
    Write-Host "    $folder"
}

if ($DiskOnly) {
    Write-Host "Data disk ready. Download the two images with the Host Console (or run this script without -DiskOnly)." -ForegroundColor Green
    return
}


#========== IMAGE 1: WINDOWS SERVER 2025 EVALUATION VHDX ==========
Write-Host "  Image 1: Windows Server 2025 evaluation VHDX" -ForegroundColor Cyan
if (Test-Path $ServerVhd -PathType Leaf) {
    Write-Host "    Found: $ServerVhd ($([math]::Round((Get-Item $ServerVhd).Length/1GB,1)) GB) - skipping download" -ForegroundColor Yellow
}
elseif ($ServerVhdUrl -match '^https://') {
    Get-LabFile -Url $ServerVhdUrl -Destination $ServerVhd -Name "Windows Server 2025 evaluation VHDX" -MinSizeGB 5
}
else {
    Write-Host "    No download link set in `$ServerVhdUrl - using the browser instead" -ForegroundColor Yellow
    Wait-ForBrowserDownload -Page $ServerVhdPage -Pattern "*.vhdx" -Destination $ServerVhd `
        -Name "Windows Server 2025 evaluation VHDX (English, 'VHD download 64-bit edition')" -MinSizeGB 5
}

#Confirm it's a usable virtual disk
#LEARN: Hyper-V isn't installed yet (that's script 02), so we use the built-in Storage
#       cmdlet Mount-DiskImage, which can open VHDX files read-only without Hyper-V.
try {
    $vhdMount = Mount-DiskImage -ImagePath $ServerVhd -Access ReadOnly -NoDriveLetter -PassThru -ErrorAction Stop
    $VhdStyle = ($vhdMount | Get-Disk).PartitionStyle
    Dismount-DiskImage -ImagePath $ServerVhd | Out-Null
    Write-Host "    VHDX opens correctly (partition style: $VhdStyle)" -ForegroundColor Green
}
catch { throw "$ServerVhd is not a valid virtual disk - delete it and run this script again" }


#========== IMAGE 2: AZURE LOCAL ISO ==========
Write-Host "  Image 2: Azure Local ISO" -ForegroundColor Cyan
if (Test-Path $AzureLocalIso -PathType Leaf) {
    Write-Host "    Found: $AzureLocalIso ($([math]::Round((Get-Item $AzureLocalIso).Length/1GB,1)) GB) - skipping download" -ForegroundColor Yellow
}
elseif ($AzureLocalIsoUrl -match '^https://') {
    Get-LabFile -Url $AzureLocalIsoUrl -Destination $AzureLocalIso -Name "Azure Local ISO" -MinSizeGB 3
}
else {
    Write-Host "    Sign in to the Azure portal -> Azure Local -> Get started -> Download software" -ForegroundColor Yellow
    Wait-ForBrowserDownload -Page $AzureLocalPage -Pattern "*.iso" -Destination $AzureLocalIso `
        -Name "Azure Local ISO" -MinSizeGB 3
}

#Confirm the ISO opens
#LEARN: Mounting the ISO read-only proves the file isn't corrupt or half-downloaded.
$mount = Mount-DiskImage -ImagePath $AzureLocalIso -PassThru
$IsoLabel = ($mount | Get-Volume).FileSystemLabel
Dismount-DiskImage -ImagePath $AzureLocalIso | Out-Null
Write-Host "    ISO mounts correctly (label: $IsoLabel)" -ForegroundColor Green


#========== VERIFY ==========
Write-Host "  Verify" -ForegroundColor Cyan
Get-Volume -DriveLetter $DriveLetter | Format-Table DriveLetter, FileSystemLabel, FileSystem,
    @{n='SizeGB';e={[math]::Round($_.Size/1GB)}}, @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB)}} -AutoSize
Get-ChildItem C:\ISO -File | Format-Table Name, @{n='SizeGB';e={[math]::Round($_.Length/1GB,1)}} -AutoSize

Write-Host "Host prepared. Next: run 02.Host-InstallHyperV.ps1" -ForegroundColor Green
################
