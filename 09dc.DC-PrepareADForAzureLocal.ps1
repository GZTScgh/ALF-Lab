##############################################################
# Version: ALF Lab Builder 2.0.23   (should match VERSION.txt - if this file was replaced on its own, check it is from the same release)
# 09dc.DC-PrepareADForAzureLocal.ps1
# Installs the Azure Local Active Directory preparation module, then (optionally)
# creates the Azure Local OU and the deployment (LCM) user
#
# RUN ON: INSIDE ContosoDC1, signed in as {{DomainNetbios}}\Administrator
# RUN AS: a .ps1 FILE (.\09dc.DC-PrepareADForAzureLocal.ps1) - it prompts for input
# SAFE TO RE-RUN: the module install and the OU step both check first
#
# TWO PARTS:
#   PART 1 - LAB SETUP   : install the AsHciADArtifactsPreCreationTool module   (always)
#   PART 2 - LAB EXERCISE: create the OU + LCM user                             (asks first)
#     Answer N when you're building the lab for students - they do Part 2 themselves.
#     Answer Y when you're doing the lab exercise (or re-run this script later).
#
# LEARN: Azure Local needs, before deployment:
#   - a dedicated OU with Group Policy inheritance BLOCKED (no surprise GPO settings)
#   - a deployment user (the "LCM user" - Lifecycle Manager) with full rights on that OU
#   The deployment later joins the nodes to the domain and puts them in this OU,
#   along with the cluster name object.
#
# LEARN: BEST PRACTICE - ONE OU AND ONE LCM ACCOUNT PER CLUSTER
#   Every Azure Local instance (cluster) gets its own OU and its own LCM account.
#     - Each cluster's computer objects stay together and can be managed on their own.
#     - The LCM account only has rights on ITS cluster's OU. If it's ever compromised,
#       only that one cluster is affected.
#     - The LCM account name must be unique for each Azure Local instance.
#     - Don't move the computer objects to another OU after deployment - it isn't supported.
#   A naming pattern that keeps them paired makes this easy - name the OU after the cluster:
#     Cluster {{ClusterName}}  ->  {{OUPath}}   +   {{LCMAccountName}}
#     Cluster LABcluster1056  ->  OU=LABcluster1056   +   LCMaccount1056
##############################################################

$ModuleName = "AsHciADArtifactsPreCreationTool"

#Starting values for Part 2 - you'll be shown these and can change them before anything is created
$DefaultOUPath  = "{{OUPath}}"            #set in the Lab Builder
$DefaultLCMUser = "{{LCMAccountName}}"    #set in the Lab Builder

#The nodes' local admin (script 12). The LCM account must NOT use the same name.
$NodeLocalAdmin = "{{LocalAdminName}}"    #set in the Lab Builder

#Where to save the OU and LCM account name so they can be looked up later (the password is never saved)
$DetailsFile = "C:\ISO\LCMAccount.txt"

####### End of variables ######################


#Stop if this is the template (values not filled in by the Lab Builder yet)
if ("$DefaultOUPath$DefaultLCMUser$NodeLocalAdmin" -match '\{\{') {
    throw "This script still has placeholders ({{...}}). Open the Planning Console (Launch-ALFLabBuilder.cmd), fill in the values, and use 'Roll out scripts'."
}

Write-Host "Preparing Active Directory for Azure Local" -ForegroundColor Cyan


#==================================================================
# PART 1 - LAB SETUP: install the AD preparation module
#==================================================================
Write-Host ""
Write-Host "PART 1 - Install the Azure Local AD preparation module" -ForegroundColor Cyan

#PowerShell Gallery prerequisites (fresh servers need these)
#LEARN: The PowerShell Gallery only accepts TLS 1.2, and Install-Module needs the NuGet provider.
Write-Host "  Enable TLS 1.2" -ForegroundColor Cyan
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "  Check NuGet package provider" -ForegroundColor Cyan
if (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object Version -ge 2.8.5.201) {
    Write-Host "    Already installed - skipping" -ForegroundColor Yellow
} else {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
}

#Trust the PowerShell Gallery so Install-Module doesn't stop to ask
Write-Host "  Trust the PowerShell Gallery" -ForegroundColor Cyan
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

#Install the module (latest version; older versions removed first, as Microsoft recommends)
Write-Host "  Install $ModuleName" -ForegroundColor Cyan
$Installed = Get-InstalledModule $ModuleName -AllVersions -ErrorAction SilentlyContinue
$Latest    = Find-Module $ModuleName -Repository PSGallery

if ($Installed -and ($Installed.Version -contains $Latest.Version) -and @($Installed).Count -eq 1) {
    Write-Host "    Version $($Latest.Version) already installed - skipping" -ForegroundColor Yellow
} else {
    if ($Installed) {
        Write-Host "    Removing older version(s): $(($Installed.Version) -join ', ')" -ForegroundColor Yellow
        $Installed | Uninstall-Module -Force
    }
    Install-Module $ModuleName -Repository PSGallery -Force
}

Import-Module $ModuleName -Force
Get-InstalledModule $ModuleName | Format-Table Name, Version -AutoSize

#Show what the module gives you
#LEARN: New-HciAdObjectsPreCreation is the one command used in Part 2.
Write-Host "  Commands in the module" -ForegroundColor Cyan
Get-Command -Module $ModuleName | Format-Table Name -AutoSize

Write-Host "Part 1 complete - module installed." -ForegroundColor Green


#==================================================================
# PART 2 - LAB EXERCISE: create the OU and the LCM deployment user
#==================================================================
Write-Host ""
Write-Host "PART 2 - Create the Azure Local OU and LCM deployment user" -ForegroundColor Cyan
Write-Host "  This is a lab EXERCISE. If you're setting up the lab for students, answer N." -ForegroundColor Yellow

#Show what already exists, so you can pick names that don't clash
$DomainDN = (Get-ADDomain).DistinguishedName
Write-Host "  Domain: $((Get-ADDomain).DNSRoot)   ($DomainDN)" -ForegroundColor Cyan
$ExistingOUs = Get-ADOrganizationalUnit -Filter * -SearchBase $DomainDN -SearchScope OneLevel |
               Where-Object Name -ne "Domain Controllers"
if ($ExistingOUs) {
    Write-Host "  Existing OUs at the top of the domain:" -ForegroundColor Cyan
    $ExistingOUs | ForEach-Object { Write-Host "    $($_.DistinguishedName)" }
} else {
    Write-Host "  No Azure Local OUs exist yet." -ForegroundColor Cyan
}

Write-Host ""
Write-Host "Create an Azure Local OU and LCM deployment user now? (Y/N)" -ForegroundColor Red -BackgroundColor Yellow
$choice = Read-Host "Enter Y or N"

if ($choice -notmatch '^[Yy]$') {
    Write-Host "  Skipped creating the OU and LCM user." -ForegroundColor Cyan
    Write-Host "  To do it later, run this script again and answer Y." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Next: on the HOST run 10.Host-CreateNodeVMs.ps1" -ForegroundColor Green
    return
}


#---------- STEP 1: CHOOSE THE OU ----------
#LEARN: The OU path is a "distinguished name" (DN) - read it right to left. For example:
#         DC=local, DC=contosolab   = the domain contosolab.local
#         OU={{ClusterName}}         = an OU called {{ClusterName}} at the top of that domain
#       The OU can sit inside another OU too, e.g. "OU={{ClusterName}},OU=AzureLocal,DC=contosolab,DC=local"
#       (useful when you have many clusters - see "large scale deployments" in Microsoft's docs).
#       These characters are NOT allowed anywhere in the path:  &  "  '  <  >
Write-Host ""
Write-Host "STEP 1 - Choose the OU for this cluster" -ForegroundColor Cyan
Write-Host "  Best practice: ONE OU per cluster. Use a new OU for each cluster you deploy." -ForegroundColor Yellow
Write-Host "  Current OU path: $DefaultOUPath" -ForegroundColor Green
$entry = Read-Host "  Press Enter to use it, or type a different OU path"
$OUPath = if ([string]::IsNullOrWhiteSpace($entry)) { $DefaultOUPath } else { $entry.Trim() }

#Check the OU path
if ($OUPath -notmatch '^OU=')                      { throw "The OU path must start with OU=  (you entered: $OUPath)" }
if ($OUPath -match '[&"''<>]')                     { throw "The OU path can't contain & `" ' < >  (you entered: $OUPath)" }
if ($OUPath -notmatch ([regex]::Escape($DomainDN) + '$')) { throw "The OU path must end with $DomainDN  (you entered: $OUPath)" }

$OUExists = [bool](Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$OUPath'" -ErrorAction SilentlyContinue)
if ($OUExists) {
    Write-Warning "That OU already exists. Best practice is a NEW OU for each cluster."
    Write-Host "  Users already in it:" -ForegroundColor Yellow
    Get-ADUser -Filter * -SearchBase $OUPath | ForEach-Object { Write-Host "    $($_.SamAccountName)" }
    if ((Read-Host "  Use this existing OU anyway? (Y/N)") -notmatch '^[Yy]$') {
        Write-Host "Stopped. Run the script again and type a new OU path." -ForegroundColor Yellow
        return
    }
}


#---------- STEP 2: CHOOSE THE LCM ACCOUNT NAME ----------
#LEARN: The LCM (Lifecycle Manager) account is what the deployment - and later updates,
#       node repairs and node additions - use to work in Active Directory.
#       Rules: 1-20 characters, letters/numbers/-/_ only, can't start with a number or '-',
#              can't be "admin", can't match the nodes' local admin ($NodeLocalAdmin),
#              and must be unique for each cluster.
#       Enter the USERNAME ONLY - no {{DomainNetbios}}\ prefix and no @domain.
Write-Host ""
Write-Host "STEP 2 - Choose the LCM deployment account for this cluster" -ForegroundColor Cyan
Write-Host "  Best practice: ONE LCM account per cluster, paired with the OU above." -ForegroundColor Yellow
Write-Host "  Current LCM account name: $DefaultLCMUser" -ForegroundColor Green
$entry = Read-Host "  Press Enter to use it, or type a different name"
$LCMUser = if ([string]::IsNullOrWhiteSpace($entry)) { $DefaultLCMUser } else { $entry.Trim() }

#Check the name
if ($LCMUser -match '\\|@')                               { throw "Enter the username only, without {{DomainNetbios}}\ or @domain" }
if ($LCMUser -notmatch '^[A-Za-z_][A-Za-z0-9_-]{0,19}$')  { throw "Name must be 1-20 letters/numbers/-/_ and can't start with a number or '-'  (you entered: $LCMUser)" }
if ($LCMUser -eq "admin")                                 { throw "The name can't be 'admin'" }
if ($LCMUser -eq $NodeLocalAdmin)                         { throw "The name can't be the same as the nodes' local admin ($NodeLocalAdmin)" }
if (Get-ADUser -Filter "SamAccountName -eq '$LCMUser'" -ErrorAction SilentlyContinue) {
    throw "An account called $LCMUser already exists. Each cluster needs its OWN LCM account - choose a new name."
}


#---------- STEP 3: CHOOSE THE PASSWORD ----------
#LEARN: You'll type this password into the Azure portal deployment wizard.
#       Rules: 14+ characters with an uppercase, lowercase, number and special character.
Write-Host ""
Write-Host "STEP 3 - Set the password for $LCMUser" -ForegroundColor Cyan
Write-Host "  14+ characters, with an uppercase, lowercase, number and special character" -ForegroundColor Yellow
Write-Host "  Choosing and remembering passwords is your responsibility." -ForegroundColor Yellow
$Pwd1 = Read-Host "  Password" -AsSecureString
$Pwd2 = Read-Host "  Type it again" -AsSecureString
$Plain1 = [System.Net.NetworkCredential]::new("", $Pwd1).Password
$Plain2 = [System.Net.NetworkCredential]::new("", $Pwd2).Password

if ($Plain1 -cne $Plain2) { throw "The two passwords don't match - run the script again" }
if ($Plain1.Length -lt 14 -or $Plain1 -cnotmatch '[A-Z]' -or $Plain1 -cnotmatch '[a-z]' -or $Plain1 -notmatch '\d' -or $Plain1 -notmatch '[^A-Za-z0-9]') {
    throw "Password must be 14+ characters with an uppercase, lowercase, number and special character"
}


#---------- STEP 4: CONFIRM, THEN CREATE ----------
Write-Host ""
Write-Host "STEP 4 - Review before anything is created" -ForegroundColor Cyan
Write-Host "    OU path     : $OUPath $(if ($OUExists) { '(already exists)' } else { '(new)' })"
Write-Host "    LCM account : $LCMUser   (signs in as $((Get-ADDomain).NetBIOSName)\$LCMUser)"
Write-Host "Create these now? (Y/N)" -ForegroundColor Red -BackgroundColor Yellow
if ((Read-Host "Enter Y or N") -notmatch '^[Yy]$') {
    Write-Host "Stopped - nothing was created. Run the script again when you're ready." -ForegroundColor Yellow
    return
}

Write-Host "  Create OU and LCM account" -ForegroundColor Cyan
$LcmCred = [System.Management.Automation.PSCredential]::new($LCMUser, $Pwd1)
New-HciAdObjectsPreCreation -AzureStackLCMUserCredential $LcmCred -AsHciOUName $OUPath


#---------- VERIFY ----------
Write-Host "  Verify" -ForegroundColor Cyan
Get-ADOrganizationalUnit -Identity $OUPath -Properties gPOptions | Format-Table Name, DistinguishedName, gPOptions -AutoSize
Write-Host "    gPOptions = 1 means Group Policy inheritance is blocked"
Get-ADUser -Filter "SamAccountName -eq '$LCMUser'" -SearchBase $OUPath | Format-Table SamAccountName, Enabled, DistinguishedName -AutoSize

#Save the OU and account name so they can be looked up later (never the password)
"Azure Local AD objects - created $(Get-Date)`r`n  OU path    : $OUPath`r`n  LCM account: $LCMUser   ($((Get-ADDomain).NetBIOSName)\$LCMUser)" |
    Add-Content -Path $DetailsFile

Write-Host ""
Write-Host "Part 2 complete. You'll need these in the deployment wizard:" -ForegroundColor Green
Write-Host "    OU path        : $OUPath" -ForegroundColor Green
Write-Host "    LCM account    : $LCMUser   (domain: $((Get-ADDomain).DNSRoot))" -ForegroundColor Green
Write-Host "    Password       : the one you just chose (not saved)" -ForegroundColor Green
Write-Host "    Also saved in  : $DetailsFile" -ForegroundColor Green
Remove-Variable Plain1, Plain2

Write-Host ""
Write-Host "Next: on the HOST run 10.Host-CreateNodeVMs.ps1" -ForegroundColor Green
################
