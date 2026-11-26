##############################################################
# Version: ALF Lab Builder 2.1.1   (should match VERSION.txt - if this file was replaced on its own, check it is from the same release)
# 07dc.DC-CreateForest.ps1
# Installs AD DS + DNS and creates the lab forest (planned domain, default contosolab.local)
#
# RUN ON: INSIDE ContosoDC1, elevated PowerShell (local Administrator)
# RUN AS: a .ps1 FILE (.\07dc.DC-CreateForest.ps1)
# NOTE:   the VM restarts at the end. No password is asked for.
#
# LEARN: A single-label name like "ContosoLAB" is not supported for AD domains.
#        We use a DNS name such as contosolab.local with a NetBIOS name such as CONTOSOLAB,
#        so sign-ins still look like CONTOSOLAB\username.
#        DSRM = Directory Services Restore Mode - the "break glass" password for AD recovery.
#        Windows requires one to create a forest, but this lab never uses it, so the script
#        sets a random 32-character DSRM password that is never shown or saved. If you ever
#        need DSRM, sign in as a domain admin on the DC and set a new one:
#          ntdsutil "set dsrm password" "reset password on server null" quit quit
##############################################################

$DomainName = "{{DomainFqdn}}"      #set in the Lab Builder (default contosolab.local)
$NetBIOS    = "{{DomainNetbios}}"   #set in the Lab Builder (default CONTOSOLAB)
$ExpectedPC = "ContosoDC1"

####### End of variables ######################

#Random password straight into a SecureString: at least one upper, lower, digit and symbol
function New-ALFRandomPassword([int]$Length = 32) {
    $sets = 'ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#%+-=?@^_'
    $all  = -join $sets
    $rng  = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $byte = New-Object byte[] 1
    #unbiased random index below $Max
    $pick = { param([int]$Max) do { $rng.GetBytes($byte) } while ($byte[0] -ge 256 - (256 % $Max)); [int]$byte[0] % $Max }
    $chars = New-Object char[] $Length
    try {
        for ($i = 0; $i -lt $Length; $i++) {
            $set = if ($i -lt $sets.Count) { $sets[$i] } else { $all }
            $chars[$i] = $set[(& $pick $set.Length)]
        }
        #shuffle so the required characters are not always first
        for ($i = $Length - 1; $i -gt 0; $i--) {
            $j = & $pick ($i + 1)
            $c = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $c
        }
        $secure = New-Object Security.SecureString
        foreach ($c in $chars) { $secure.AppendChar($c) }
        $secure
    }
    finally {
        [Array]::Clear($chars, 0, $chars.Length)
        $c = $null
        $rng.Dispose()
    }
}


#Stop if this is the template (values not filled in by the Lab Builder yet)
if ("$DomainName$NetBIOS" -match '\{\{') {
    throw "This script still has placeholders ({{...}}). Open the Planning Console (Launch-ALFLabBuilder.cmd), fill in the values, and use 'Roll out scripts'."
}

Write-Host "Creating forest $DomainName" -ForegroundColor Cyan

#Pre-checks
Write-Host "  Run pre-checks" -ForegroundColor Cyan
if ($env:COMPUTERNAME -ne $ExpectedPC) { throw "Computer name is $env:COMPUTERNAME - run 06dc.DC-SetNameAndIP.ps1 first" }
if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) { throw "Already part of a domain - nothing to do" }

#Install roles
Write-Host "  Install AD DS, DNS and management tools" -ForegroundColor Cyan
Install-WindowsFeature AD-Domain-Services, DNS, GPMC, RSAT-AD-Tools, RSAT-DNS-Server -IncludeManagementTools | Out-Null

#DSRM password - required by Windows, not used in this lab (see LEARN at the top)
Write-Host "  Set a random DSRM password (not shown or saved; not needed in this lab)" -ForegroundColor Cyan
$DsrmPwd = New-ALFRandomPassword

$params = @{
    DomainName                    = $DomainName
    DomainNetbiosName             = $NetBIOS
    ForestMode                    = "WinThreshold"   #2016 functional level - widest compatibility
    DomainMode                    = "WinThreshold"
    InstallDns                    = $true
    CreateDnsDelegation           = $false
    SafeModeAdministratorPassword = $DsrmPwd
}

#Validate first
#LEARN: Test-ADDSForestInstallation runs the same checks as the wizard without changing anything.
Write-Host "  Validate forest prerequisites" -ForegroundColor Cyan
$test = Test-ADDSForestInstallation @params -WarningAction SilentlyContinue
if ($test.Status -ne "Success") { throw "Pre-check failed: $($test.Message)" }
Write-Host "    Prerequisites passed" -ForegroundColor Green

#Promote
Write-Host "  Promote to domain controller (restarts automatically)" -ForegroundColor Cyan
Write-Host "After the restart sign in as $NetBIOS\Administrator and run 08dc.DC-PostConfig.ps1" -ForegroundColor Green
Install-ADDSForest @params -Force -WarningAction SilentlyContinue
################
