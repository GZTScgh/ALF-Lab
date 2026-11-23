##############################################################
# Version: ALF Lab Builder 2.0.22   (should match VERSION.txt - if this file was replaced on its own, check it is from the same release)
# 05.Host-CopyScriptsToVM.ps1
# Copies lab scripts from the host into a VM (no clipboard or network needed)
#
# RUN ON: the Hyper-V host, elevated PowerShell
# USE:    after the VM's OS is installed and you have signed in once
#
# LEARN: Copy-VMFile uses the Hyper-V "Guest Service Interface" (VMBus), not the network.
#        It works even before the VM has an IP address.
##############################################################

#Which VMs get which scripts (a VM that doesn't exist or isn't running is skipped)
#   The NODES get their files from 11.Host-PrepareNodes.ps1 instead,
#   because each node needs its own filled-in copy of 12.Node-Configure.ps1.
$CopyPlan = [ordered]@{
    "ContosoDC1"           = "*.DC-*.ps1"       #domain controller scripts (06dc, 07dc, 08dc, 09dc)
    "{{AdminStationName}}" = "*.Admin-*.ps1"    #admin station script (08adm) - name set in the Lab Builder
}

$GuestLaunchers = @{
    "ContosoDC1" = "Launch-ALFDCConsole.cmd"
    "{{AdminStationName}}" = "Launch-ALFAdminConsole.cmd"
}
$ConsoleFiles = @("ALFGuestConsole.ps1", "ALFGuestStepRunner.ps1", "ALFGuestStatus.ps1", "ALFGuestDisplay.ps1")

$SourceFolder = "C:\ISO"     #where the scripts are on the host
$GuestFolder  = "C:\ISO"     #where they go inside the VM

####### End of variables ######################


#Stop if this is the template (values not filled in by the Lab Builder yet)
if ("$($CopyPlan.Keys)" -match '\{\{') {
    throw "This script still has placeholders ({{...}}). Open the Planning Console (Launch-ALFLabBuilder.cmd), fill in the values, and use 'Roll out scripts'."
}

function Copy-ALFGuestConsoleShortcut {
    param(
        [string]$VMName,
        [string]$GuestFolder,
        [ValidateSet('Launch-ALFDCConsole.cmd', 'Launch-ALFAdminConsole.cmd')][string]$Launcher
    )
    $consoleName = if ($Launcher -eq 'Launch-ALFDCConsole.cmd') { 'DC' } else { 'Admin' }
    $description = if ($consoleName -eq 'DC') { 'Open the ALF Lab Builder Domain Controller Console' } else { 'Open the ALF Lab Builder Admin Station Console' }
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('ALF-' + $consoleName + '-Console-' + [guid]::NewGuid().ToString('N') + '.lnk')
    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($temp)
        $shortcut.TargetPath = Join-Path $GuestFolder $Launcher
        $shortcut.WorkingDirectory = $GuestFolder
        $shortcut.Description = $description
        $shortcut.IconLocation = 'C:\Windows\System32\shell32.dll,18'
        $shortcut.Save()
        $destination = "C:\Users\Public\Desktop\ALF $consoleName Console.lnk"
        Copy-VMFile -Name $VMName -SourcePath $temp -DestinationPath $destination -CreateFullPath -FileSource Host -Force -ErrorAction Stop
        Write-Host "  $consoleName desktop shortcut: $destination -> $($shortcut.TargetPath)" -ForegroundColor Green
    }
    catch {
        Write-Warning "$consoleName desktop shortcut was not created: $($_.Exception.Message). The console can still be opened from $GuestFolder\$Launcher."
    }
    finally {
        if ($shortcut -and [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
        if ($shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

foreach ($VMName in $CopyPlan.Keys) {
    $Filter = $CopyPlan[$VMName]
    Write-Host "Copying $Filter to $VMName" -ForegroundColor Cyan

    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm)                { Write-Warning "$VMName doesn't exist yet - skipping"; continue }
    Write-Host "  Disable Hyper-V Time Synchronization on $VMName" -ForegroundColor Cyan
    Disable-VMIntegrationService -VMName $VMName -Name "Time Synchronization" -ErrorAction Stop
    if ($vm.State -ne "Running") { Write-Warning "$VMName is not running - skipping"; continue }

    $Scripts = @(Get-ChildItem -Path $SourceFolder -Filter $Filter -File)
    if (-not $Scripts) { Write-Warning "No scripts matching '$Filter' in $SourceFolder"; continue }
    $Required = @($ConsoleFiles) + @($GuestLaunchers[$VMName])
    $Missing = @($Required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $SourceFolder $_) -PathType Leaf) })
    if ($Missing.Count) { throw "Guest console files missing from rollout: $($Missing -join ', '). Roll out the complete release again." }
    $Scripts += @($Required | ForEach-Object { Get-Item -LiteralPath (Join-Path $SourceFolder $_) })

    #Guest services must be on
    Enable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface"

    foreach ($Script in $Scripts) {
        Write-Host "  $($Script.Name)" -ForegroundColor Cyan
        Copy-VMFile -Name $VMName -SourcePath $Script.FullName `
            -DestinationPath (Join-Path $GuestFolder $Script.Name) `
            -CreateFullPath -FileSource Host -Force
    }
    Copy-ALFGuestConsoleShortcut $VMName $GuestFolder ($GuestLaunchers[$VMName])
}

Write-Host "Done. Inside the VM the scripts are in $GuestFolder" -ForegroundColor Green
Write-Host "On the DC or admin station: use the matching ALF Console shortcut on the Public Desktop, available to local and domain users, or the launcher in $GuestFolder. Existing elevation prompts still apply." -ForegroundColor Green
Write-Host "Guest consoles detect progress automatically. Reopen the same console after any restart." -ForegroundColor Green
################
