######################  14.Node-ArcRegister.ps1  ######################
# Version: ALF Lab Builder 2.0.14   (should match VERSION.txt - if this file was replaced on its own, check it is from the same release)
# REGISTER NODE WITH AZURE ARC
#
# RUN ON: INSIDE each node (SConfig option 15 -> PowerShell), one node at a time
#
# LEARN: What this does
#   Azure Arc "projects" this on-premises machine into Azure as a resource
#   (type: Microsoft.HybridCompute/machines). Once registered, Azure can:
#     - see the machine in the portal
#     - install extensions on it (LCM, Edge Device, Remote Support, etc.)
#     - drive the Azure Local deployment from the portal wizard
#   Nothing is deployed yet - this step just "introduces" the node to Azure.
##########################################################################

#Define the tenant you will use to register your machine as Arc device
#LEARN: Entra ID -> Overview -> Tenant ID. This is the identity directory, not the subscription.
$Tenant = "{{TenantId}}"   #set in the Lab Builder - no need to type it inside the node

#Define the subscription where you want to register your machine as Arc device
#LEARN: Billing + resource container. Changing it later means redeploying the cluster.
$Subscription = "{{SubscriptionId}}"   #set in the Lab Builder

#Define the resource group where you want to register your machine as Arc device
#LEARN: Created automatically if it doesn't exist. Use the SAME RG for all nodes in the cluster.
$RG = "{{ClusterResourceGroup}}"   #Azure Local cluster resource group - set in the Lab Builder

#Define the region to use to register your server as Arc device, do not use spaces or capital letters when defining region
#LEARN: Must be an Azure Local supported region, and should match where you deploy the instance.
$Region = "{{ArcRegion}}"   #set in the Lab Builder

#Define the target Azure Local solution version (OPTIONAL)
#LEARN: The solution version the node is brought to for the initial deployment.
#       Leave it blank ("") and the script shows a list of available versions to pick from.
#       Set it to pin every node to the exact same version - useful in labs/workshops so
#       everyone deploys the same build. Format example: "12.2602.1002.10"
$TargetSolutionVersion = ""
#$TargetSolutionVersion = "12.2602.1002.10"   #<-- example of pinning a version

#Show the cmdlet's internal detail as it runs ($true = more learning output)
$ShowVerboseOutput = $true

#Where to save a full log of this run
$LogFolder = "C:\ISO\Logs"

####### End of variables ######################


#Stop if this is the template (values not filled in by the Lab Builder yet)
if ("$Tenant$Subscription$RG$Region" -match '\{\{') {
    throw "This script still has placeholders ({{...}}). Open the Planning Console (Launch-ALFLabBuilder.cmd), fill in the values, and use 'Roll out scripts'."
}

#Start a transcript - everything on screen is also saved to a file for later review
New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
$LogFile = "$LogFolder\ArcRegistration-$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $LogFile | Out-Null

Write-Host "Registering node $env:COMPUTERNAME with Azure Arc" -ForegroundColor Cyan


#========== PRE-FLIGHT CHECKS ==========
#LEARN: Most Arc registration failures come from time, DNS, or outbound HTTPS - check them first.

#Check the ID formats (a typo here gives a confusing error later)
Write-Host "  Check tenant and subscription ID format" -ForegroundColor Cyan
$guidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
if ($Tenant -notmatch $guidPattern)       { Stop-Transcript | Out-Null; throw "Tenant ID is not a valid GUID: $Tenant" }
if ($Subscription -notmatch $guidPattern) { Stop-Transcript | Out-Null; throw "Subscription ID is not a valid GUID: $Subscription" }

#Check the region format
Write-Host "  Check region format" -ForegroundColor Cyan
if ($Region -cmatch '[A-Z\s]') { Stop-Transcript | Out-Null; throw "Region must be lowercase with no spaces (e.g. southcentralus): '$Region'" }

#Check the registration command is available
#LEARN: Current Azure Local images include it. Older images may need the module from PowerShell Gallery.
Write-Host "  Check Arc registration module" -ForegroundColor Cyan
if (-not (Get-Command Invoke-AzStackHciArcInitialization -ErrorAction SilentlyContinue)) {
    Write-Host "    Not found - installing AzsHCI.ARCinstaller from PowerShell Gallery" -ForegroundColor Yellow
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Install-Module AzsHCI.ARCinstaller -Force
}

#Check the clock
#LEARN: Azure sign-in tokens and TLS certificates are time-sensitive. A clock that's off by
#       more than a few minutes causes sign-in failures and false "SSL inspection" errors.
Write-Host "  Check time and time source" -ForegroundColor Cyan
Write-Host "    Local time : $(Get-Date)"
Write-Host "    Time source: $((w32tm /query /source).Trim())"

#Check DNS
#LEARN: The node resolves Azure endpoints through your lab DNS (ContosoDC1 -> forwarders).
Write-Host "  Check DNS resolution of Azure endpoints" -ForegroundColor Cyan
foreach ($name in "login.microsoftonline.com", "management.azure.com") {
    if (Resolve-DnsName $name -ErrorAction SilentlyContinue) { Write-Host "    $name resolves" -ForegroundColor Green }
    else { Write-Warning "Cannot resolve $name - check DNS server and forwarders" }
}

#Check outbound HTTPS
#LEARN: Arc only needs OUTBOUND port 443. Nothing has to be opened inbound to the node.
Write-Host "  Check outbound HTTPS (port 443)" -ForegroundColor Cyan
foreach ($name in "login.microsoftonline.com", "management.azure.com") {
    if ((Test-NetConnection $name -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded) {
        Write-Host "    $name :443 reachable" -ForegroundColor Green
    } else { Write-Warning "$name :443 NOT reachable - check NAT/firewall" }
}


#========== SHOW WHAT WILL HAPPEN ==========
Write-Host ""
Write-Host "  Registration settings:" -ForegroundColor Cyan
Write-Host "    Machine        : $env:COMPUTERNAME"
Write-Host "    Tenant         : $Tenant"
Write-Host "    Subscription   : $Subscription"
Write-Host "    Resource group : $RG"
Write-Host "    Region         : $Region"
if ($TargetSolutionVersion) { Write-Host "    Target version : $TargetSolutionVersion" }
else                        { Write-Host "    Target version : (you'll be asked to pick one from a list)" }
Write-Host ""


#========== BUILD THE PARAMETERS ==========
#LEARN: "Splatting" - put parameters in a hashtable and pass them with @ instead of $.
#       This makes it easy to add optional parameters only when they have a value.
$ArcParams = @{
    TenantId       = $Tenant
    SubscriptionID = $Subscription
    ResourceGroup  = $RG
    Region         = $Region
    Cloud          = "AzureCloud"
}
if ($TargetSolutionVersion) { $ArcParams.TargetSolutionVersion = $TargetSolutionVersion }
if ($ShowVerboseOutput)     { $ArcParams.Verbose = $true }


#========== REGISTER ==========
#LEARN: Sign-in uses "device code" flow. You'll see a code on screen:
#         1. On ANY machine with a browser, go to https://microsoft.com/devicelogin
#         2. Enter the code and sign in with an account that has the Arc/RG roles
#       This is why you don't need a browser on the node itself.
#LEARN: If the node needs an update to reach the target version, the update takes
#       ~40-45 minutes and then reboots. After the reboot, RUN THIS SCRIPT AGAIN to finish.
Write-Host "  Starting Arc registration - watch for the device login code" -ForegroundColor Cyan
Invoke-AzStackHciArcInitialization @ArcParams


#========== CHECK THE RESULT ==========
#LEARN: Get-ArcBootstrapStatus reports the registration state, even after a reboot or timeout.
Write-Host ""
Write-Host "  Check registration status" -ForegroundColor Cyan
$status = Get-ArcBootstrapStatus
Write-Host "    Status: $($status.Response.Status)"

switch ($status.Response.Status) {
    "Succeeded" { Write-Host "    Registration completed successfully" -ForegroundColor Green }
    "Failed"    { Write-Warning "Registration failed - re-run this script. If it fails again, run Collect-ArcBootstrapSupportLogs" }
    default     { Write-Host "    Still in progress (or updating) - re-run Get-ArcBootstrapStatus in a few minutes" -ForegroundColor Yellow }
}

#Show the Arc agent's view of this machine
#LEARN: azcmagent is the Arc agent's command-line tool. "Agent Status: Connected" = healthy.
Write-Host "  Arc agent details" -ForegroundColor Cyan
& "C:\Program Files\AzureConnectedMachineAgent\azcmagent.exe" show

Stop-Transcript | Out-Null
Write-Host ""
Write-Host "Done. Full log saved to: $LogFile" -ForegroundColor Green
Write-Host "Next: in the Azure portal, open resource group '$RG' - this node should appear as a Machine - Azure Arc resource." -ForegroundColor Green
Write-Host "When ALL nodes are registered: run 15.Workstation-PolicyReview.ps1 to check which Azure Policies act on them." -ForegroundColor Green
################
