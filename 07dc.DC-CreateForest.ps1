##############################################################
# Version: ALF Lab Builder 2.0.16   (should match VERSION.txt - if this file was replaced on its own, check it is from the same release)
# 07dc.DC-CreateForest.ps1
# Installs AD DS + DNS and creates the contosolab.local forest
#
# RUN ON: INSIDE ContosoDC1, elevated PowerShell (local Administrator)
# RUN AS: a .ps1 FILE (.\07dc.DC-CreateForest.ps1) - pasting breaks the password prompt
# NOTE:   the VM restarts at the end
#
# LEARN: A single-label name like "ContosoLAB" is not supported for AD domains.
#        We use contosolab.local (DNS name) with NetBIOS name CONTOSOLAB, so
#        sign-ins still look like CONTOSOLAB\username.
#        DSRM = Directory Services Restore Mode - the "break glass" password for AD recovery.
##############################################################

$DomainName = "contosolab.local"
$NetBIOS    = "CONTOSOLAB"
$ExpectedPC = "ContosoDC1"

####### End of variables ######################


Write-Host "Creating forest $DomainName" -ForegroundColor Cyan

#Pre-checks
Write-Host "  Run pre-checks" -ForegroundColor Cyan
if ($env:COMPUTERNAME -ne $ExpectedPC) { throw "Computer name is $env:COMPUTERNAME - run 06dc.DC-SetNameAndIP.ps1 first" }
if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) { throw "Already part of a domain - nothing to do" }

#Install roles
Write-Host "  Install AD DS, DNS and management tools" -ForegroundColor Cyan
Install-WindowsFeature AD-Domain-Services, DNS, GPMC, RSAT-AD-Tools, RSAT-DNS-Server -IncludeManagementTools | Out-Null

#DSRM password
Write-Host "  Enter the DSRM password (store it somewhere safe)" -ForegroundColor Cyan
Write-Host "  Choosing and remembering passwords is your responsibility." -ForegroundColor Yellow
$DsrmPwd = Read-Host -AsSecureString "DSRM password"

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
Write-Host "After the restart sign in as CONTOSOLAB\Administrator and run 08dc.DC-PostConfig.ps1" -ForegroundColor Green
Install-ADDSForest @params -Force -WarningAction SilentlyContinue
################
