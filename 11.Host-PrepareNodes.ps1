##############################################################
# Version: ALF Lab Builder 2.1.1   (should match VERSION.txt - if this file was replaced on its own, check it is from the same release)
# 11.Host-PrepareNodes.ps1
# Prepares every node from the host, after the Azure Local OS is installed on them:
#   A. Renames the NICs inside each node to match Hyper-V (1-MGMTCOMP1, 2-MGMTCOMP2, ...)
#   B. Builds ONE configure script PER NODE from the 12.Node-Configure.ps1 template,
#      with that node's name and IP filled in
#   C. Copies that script, plus the shared node files, into each node's C:\ISO
#
# RUN ON: the Hyper-V host, elevated PowerShell
# BEFORE: install the OS on every node and set the local Administrator password
#         (use the SAME password on every node)
# SAFE TO RE-RUN: renames are skipped if done, files are overwritten with fresh copies
#
# LEARN: Two Hyper-V features let the host reach INSIDE a VM with no network at all:
#   PowerShell Direct  (Invoke-Command -VMName)  - runs commands in the guest over VMBus
#   Copy-VMFile        ("Guest Service Interface") - copies files into the guest over VMBus
#   That's why this works before the nodes have an IP address.
##############################################################

#Node names, Number of Azure Local nodes and IP range - set in the Lab Builder.
#Node 1 gets the first address of the range, node 2 the next, and so on.
. (Join-Path $PSScriptRoot 'ALFNodeSettings.ps1')
$NodeNames   = @(Get-ALFPlannedNodeNames @("{{NodeName1}}", "{{NodeName2}}") "{{NodeCount}}")
$NodeNames = @(Get-ALFNodeNames (Join-Path $PSScriptRoot 'ALFHostConsole-Nodes.json') $NodeNames)
$NodeIPStart = "{{NodeIPStart}}"
$NodeIPEnd   = "{{NodeIPEnd}}"

#Adapter names - must match the names used when the VMs were created (script 10)
$AdapterNames = @("1-MGMTCOMP1", "2-MGMTCOMP2", "3-STORAGE1", "4-STORAGE2")

#Files
$ScriptFolder   = "C:\ISO"                       #where the lab scripts are on the host
$Template       = "C:\ISO\12.Node-Configure.ps1" #the per-node template (has __NODENAME__ / __NODEIP__)
$CommonFiles    = @("14.Node-ArcRegister.ps1", "ALFGuestConsole.ps1", "ALFGuestStepRunner.ps1", "ALFGuestStatus.ps1", "ALFGuestDisplay.ps1", "Launch-ALFNodeConsole.cmd", "AzureLocal-DeploymentTroubleshooter.ps1")   #shared scripts, guest console and the read-only deployment troubleshooter
$ExtraFolder    = "C:\ISO\NodeFiles"             #OPTIONAL: anything you drop in here goes to every node too
$GeneratedRoot  = "C:\ISO\Generated"             #host copy of each node's filled-in files (for reference)
$GuestFolder    = "C:\ISO"                       #where files land INSIDE each node

####### End of variables ######################
$ErrorActionPreference = 'Stop'


#Stop if this is the template (values not filled in by the Lab Builder yet)
if ("$NodeNames$NodeIPStart$NodeIPEnd" -match '\{\{') {
    throw "This script still has placeholders ({{...}}). Open the Planning Console (Launch-ALFLabBuilder.cmd), fill in the values, and use 'Roll out scripts'."
}

Test-ALFNodeNames $NodeNames
Write-Host "Preparing Azure Local nodes from the host" -ForegroundColor Cyan

#Work out each node's IP from the range
$startBytes = ([System.Net.IPAddress]::Parse($NodeIPStart)).GetAddressBytes()
$endLast    = ([System.Net.IPAddress]::Parse($NodeIPEnd)).GetAddressBytes()[3]
$Nodes = for ($n = 0; $n -lt $NodeNames.Count; $n++) {
    $last = $startBytes[3] + $n
    if ($last -gt $endLast) { throw "Not enough addresses in the node IP range $NodeIPStart - $NodeIPEnd for $($NodeNames.Count) nodes" }
    @{ Name = $NodeNames[$n]; IP = "$($startBytes[0]).$($startBytes[1]).$($startBytes[2]).$last" }
}
Write-Host "Selected destination VMs (from the step 9 applied names, or the plan if no override is saved):" -ForegroundColor Cyan
$Nodes | ForEach-Object { Write-Host "    VM '$($_.Name)' -> $GuestFolder inside that VM; configure IP $($_.IP)" }
Write-Host "Console entry point: $GuestFolder\Launch-ALFNodeConsole.cmd -> ALFGuestConsole.ps1 -Role Node" -ForegroundColor Cyan
Write-Host "No standalone ALFNodeConsole.ps1 is required. Host Generated folders alone do not prove guest delivery." -ForegroundColor Yellow

#========== PRE-CHECKS ==========
Write-Host "  Run pre-checks" -ForegroundColor Cyan
if (-not (Test-Path $Template)) { throw "Template not found: $Template" }
if ((Get-Content $Template -Raw) -notmatch "__NODENAME__") { throw "$Template has no __NODENAME__ placeholder - copy the original template back into C:\ISO" }
foreach ($f in $CommonFiles) {
    if (-not (Test-Path (Join-Path $ScriptFolder $f))) { throw "Common file not found: $ScriptFolder\$f" }
}
$Extras = @()
if (Test-Path $ExtraFolder) { $Extras = Get-ChildItem -Path $ExtraFolder -File -Recurse }
Write-Host "    Template, $($CommonFiles.Count) common file(s), $($Extras.Count) extra file(s) from $ExtraFolder"

#One local Administrator credential for all nodes
Write-Host "  Choosing and remembering passwords is your responsibility." -ForegroundColor Yellow
$cred = Get-Credential -UserName "Administrator" -Message "Local Administrator password for the nodes (same on every node)"


$PreparationResults = @()
foreach ($Node in $Nodes) {
    $NodeName = $Node.Name
    $outcome = @{ Name = $NodeName; Success = $false; Detail = 'Not completed' }
    $PreparationResults += $outcome
    try {
        $receiptPath = Join-Path (Join-Path $GeneratedRoot $NodeName) 'ALFNodeDelivery.json'
        if (Test-Path -LiteralPath $receiptPath) { Remove-Item -LiteralPath $receiptPath -Force }
        Write-Host ""
        Write-Host "Processing node: $NodeName ($($Node.IP))" -ForegroundColor Cyan

        #Node must exist and be running
        $vm = Get-VM -Name $NodeName -ErrorAction SilentlyContinue
        if (-not $vm) { throw "Destination VM '$NodeName' does not exist. Check the applied names in step 9." }
        Write-Host "  Disable Hyper-V Time Synchronization on $NodeName" -ForegroundColor Cyan
        Disable-VMIntegrationService -VMName $NodeName -Name "Time Synchronization" -ErrorAction Stop
        if ($vm.State -ne "Running") { throw "Destination VM '$NodeName' is not running. Start it and complete the Azure Local OS installation." }

        #Check we can sign in with PowerShell Direct (proves the OS is installed and the password is right)
        Write-Host "  Check PowerShell Direct sign-in" -ForegroundColor Cyan
        try {
            $guestName = Invoke-Command -VMName $NodeName -Credential $cred -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
            Write-Host "    Signed in - current computer name: $guestName" -ForegroundColor Green
        }
        catch {
            throw "Can't sign in to $NodeName - is the OS installed and the Administrator password set? ($($_.Exception.Message))"
        }


        #========== A. RENAME NICS ==========
        #LEARN: Inside the node, Windows names adapters "Ethernet", "Ethernet 2"... in no fixed order.
        #       The MAC address is the one value Hyper-V and the guest both see, so we match on it.
        Write-Host "  A. Rename NICs to match Hyper-V" -ForegroundColor Cyan
        foreach ($AdapterName in $AdapterNames) {
            $HostMac = (Get-VMNetworkAdapter -VMName $NodeName -Name $AdapterName -ErrorAction SilentlyContinue).MacAddress
            if (-not $HostMac) { throw "No Hyper-V adapter named $AdapterName on $NodeName." }

            #Hyper-V shows 00155D010243, Windows shows 00-15-5D-01-02-03
            $GuestMac = $HostMac -replace '(..)(?!$)', '$1-'

            $result = Invoke-Command -VMName $NodeName -Credential $cred -ScriptBlock {
                param($GuestMac, $AdapterName)
                $a = Get-NetAdapter -Physical | Where-Object { $_.MacAddress -eq $GuestMac }
                if (-not $a)                     { throw "Guest adapter with MAC $GuestMac was not found." }
                elseif ($a.Name -eq $AdapterName) { "already named" }
                else { Rename-NetAdapter -Name $a.Name -NewName $AdapterName -ErrorAction Stop; "renamed from $($a.Name)" }
            } -ArgumentList $GuestMac, $AdapterName -ErrorAction Stop
            Write-Host "    $AdapterName ($GuestMac): $result"
        }

        #MAC spoofing, teaming and VLAN trunk (also set by script 10 - safe to repeat)
        Get-VMNetworkAdapter -VMName $NodeName | Set-VMNetworkAdapter -MacAddressSpoofing On -AllowTeaming On
        Get-VMNetworkAdapter -VMName $NodeName | Set-VMNetworkAdapterVlan -Trunk -NativeVlanId 0 -AllowedVlanIdList "0-1000"


        #========== B. BUILD THIS NODE'S CONFIGURE SCRIPT ==========
        #LEARN: One template, many nodes. The host fills in __NODENAME__ and __NODEIP__ so each
        #       node gets a script that already knows who it is - students never edit variables.
        Write-Host "  B. Build 12.Node-Configure.ps1 for $NodeName" -ForegroundColor Cyan
        $NodeFolder = Join-Path $GeneratedRoot $NodeName
        New-Item -Path $NodeFolder -ItemType Directory -Force | Out-Null

        $Generated = Join-Path $NodeFolder "12.Node-Configure.ps1"
        (Get-Content $Template -Raw).Replace("__NODENAME__", $NodeName).Replace("__NODEIP__", $Node.IP) |
            Set-Content -Path $Generated -Encoding UTF8
        Write-Host "    $Generated  (name $NodeName, IP $($Node.IP))"


        #========== C. COPY FILES INTO THE NODE ==========
        Write-Host "  C. Copy files into $NodeName`:$GuestFolder" -ForegroundColor Cyan

        #Guest Service Interface must be on for Copy-VMFile
        Enable-VMIntegrationService -VMName $NodeName -Name "Guest Service Interface"

        #Build the copy list: source on host -> destination in guest
        $CopyList = @()
        $CopyList += @{ Source = $Generated; Dest = Join-Path $GuestFolder "12.Node-Configure.ps1" }
        foreach ($f in $CommonFiles) {
            $CopyList += @{ Source = Join-Path $ScriptFolder $f; Dest = Join-Path $GuestFolder $f }
        }
        foreach ($x in $Extras) {
            $relative = $x.FullName.Substring($ExtraFolder.Length).TrimStart('\')   #keeps sub-folders
            $CopyList += @{ Source = $x.FullName; Dest = Join-Path $GuestFolder $relative }
        }

        Test-ALFNodeCopyList $CopyList
        $manifest = @($CopyList | ForEach-Object {
            [pscustomobject]@{ Name = (Split-Path $_.Dest -Leaf); Dest = $_.Dest; Hash = (Get-FileHash -LiteralPath $_.Source -Algorithm SHA256).Hash }
        })
        $copyFailures = @()
        foreach ($item in $CopyList) {
            try {
                Copy-VMFile -Name $NodeName -SourcePath $item.Source -DestinationPath $item.Dest `
                    -CreateFullPath -FileSource Host -Force -ErrorAction Stop
                Write-Host "    $NodeName -> $($item.Dest)" -ForegroundColor Green
            }
            catch {
                $copyFailures += "$NodeName -> $($item.Dest): $($_.Exception.Message)"
                Write-Warning "    Copy failed: $($copyFailures[-1])"
            }
        }
        if ($copyFailures.Count) { throw "Guest file copies failed: $($copyFailures -join '; ')" }

        #Keep downloaded-file protections intact when delivering the guest console and scripts.

        #========== VERIFY ==========
        Write-Host "  Verify (inside $NodeName)" -ForegroundColor Cyan
        Invoke-Command -VMName $NodeName -Credential $cred -ErrorAction Stop -ScriptBlock {
            param($Manifest)
            foreach ($file in $Manifest) {
                $actual = Get-FileHash -LiteralPath $file.Dest -Algorithm SHA256 -ErrorAction Stop
                if ($actual.Hash -ne $file.Hash) { throw "Guest content does not match the host copy: $($file.Dest)" }
                "    VERIFIED: $($file.Dest)"
            }
        } -ArgumentList (,$manifest)
        @{
            NodeName = $NodeName
            VMId = "$($vm.Id)"
            VerifiedUtc = [DateTime]::UtcNow.ToString('o')
            TemplateHash = (Get-FileHash -LiteralPath $Template -Algorithm SHA256).Hash
            PrepareScriptHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
            Files = $manifest
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
        $outcome.Success = $true
        $outcome.Detail = "Guest files verified. Open $GuestFolder\Launch-ALFNodeConsole.cmd inside VM '$NodeName'."
    }
    catch {
        $outcome.Detail = $_.Exception.Message
        Write-Warning "Node '$NodeName' NOT prepared: $($outcome.Detail)"
    }
}

#========== REMINDER: LOCAL ADMIN ACCOUNT ==========
$AdminName = [regex]::Match((Get-Content $Template -Raw), '\$LocalAdminName\s*=\s*"([^"]+)"').Groups[1].Value
Write-Host ""
Write-Host "12.Node-Configure.ps1 creates the local admin account '$AdminName' on each node." -ForegroundColor Green
Write-Host "It uses the password set in the Lab Builder; if none was set, it asks - use the SAME password on every node." -ForegroundColor Green
Write-Host "Choosing and remembering passwords is your responsibility." -ForegroundColor Yellow

Write-Host ""
Write-Host 'Preparation results by destination VM:' -ForegroundColor Cyan
foreach ($result in $PreparationResults) {
    $color = if ($result.Success) { 'Green' } else { 'Red' }
    Write-Host "    $($result.Name): $($result.Detail)" -ForegroundColor $color
}
$failed = @($PreparationResults | Where-Object { -not $_.Success })
if ($failed.Count) {
    throw "Step 10 incomplete: $($failed.Name -join ', '). No successful delivery was recorded for these VMs. Correct the errors above and rerun step 10."
}
Write-Host "All selected VMs have verified guest copies. Next, INSIDE each selected VM (SConfig option 15):" -ForegroundColor Green
Write-Host "    cd C:\ISO" -ForegroundColor Green
Write-Host "    .\Launch-ALFNodeConsole.cmd" -ForegroundColor Green
Write-Host "The GUI is a compatibility trial on Azure Local. If WPF cannot load, report the error and use the numbered scripts individually." -ForegroundColor Yellow
Write-Host "If Windows policy blocks execution, report it and follow your organization's approved script-signing process." -ForegroundColor Yellow
################
