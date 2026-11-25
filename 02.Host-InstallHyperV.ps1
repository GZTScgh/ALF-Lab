##############################################################
# Version: ALF Lab Builder 2.1.0   (should match VERSION.txt - if this file was replaced on its own, check it is from the same release)
# 02.Host-InstallHyperV.ps1
# Installs the Hyper-V role and management tools on the host
#
# RUN ON: the Hyper-V host (Azure VM), elevated PowerShell
# NOTE:   a restart is needed at the end - the script asks before restarting
#
# LEARN: Azure turns nested virtualization on automatically for supported sizes.
#        You can't switch it on from inside the VM - you pick a size that has it.
##############################################################

####### End of variables ######################


Write-Host "Installing Hyper-V on $env:COMPUTERNAME" -ForegroundColor Cyan

#Confirm this is Windows Server
Write-Host "  Check operating system" -ForegroundColor Cyan
$OS = (Get-CimInstance Win32_OperatingSystem).Caption
Write-Host "    $OS"
if ($OS -notmatch "Server") { throw "This script is for Windows Server" }

#Confirm the VM size supports nested virtualization
Write-Host "  Check nested virtualization support" -ForegroundColor Cyan
if ((Get-WindowsFeature Hyper-V).Installed) {
    Write-Host "    Hyper-V already installed - skipping check" -ForegroundColor Yellow
} else {
    $req = Get-ComputerInfo -Property HyperVRequirement*
    $req | Format-List
    if ($req.HyperVRequirementVMMonitorModeExtensions -eq $false -or
        $req.HyperVRequirementVirtualizationFirmwareEnabled -eq $false) {
        throw "This VM size doesn't support nested virtualization - resize the Azure VM"
    }
    Write-Host "    Nested virtualization supported" -ForegroundColor Green
}

#Install Hyper-V role + management tools (Hyper-V Manager and PowerShell module)
Write-Host "  Install Hyper-V role and management tools" -ForegroundColor Cyan
$result = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools
$result | Format-Table Success, RestartNeeded, ExitCode -AutoSize

Get-WindowsFeature Hyper-V, RSAT-Hyper-V-Tools, Hyper-V-Tools, Hyper-V-PowerShell |
    Format-Table Name, InstallState -AutoSize

#Restart if needed - ask first
if ($result.RestartNeeded -eq "Yes") {
    Write-Host "Hyper-V installed. A restart is required before Hyper-V can be used." -ForegroundColor Green
    Write-Host "After the restart, sign in again and run 03.Host-CreateVMSwitches.ps1" -ForegroundColor Green
    Write-Host "Would you like to restart now? (Y/N)" -ForegroundColor Red -BackgroundColor Yellow
    $choice = Read-Host "Enter Y or N"
    if ($choice -match '^[Yy]$') {
        Write-Host "Restarting in 5 seconds - your Remote Desktop session will disconnect..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
        Restart-Computer -Force
    } else {
        Write-Host "Not restarting. Restart the server yourself before running 03.Host-CreateVMSwitches.ps1" -ForegroundColor Yellow
    }
} else {
    Write-Host "Hyper-V is ready - no restart needed. Next: run 03.Host-CreateVMSwitches.ps1" -ForegroundColor Green
}
################
