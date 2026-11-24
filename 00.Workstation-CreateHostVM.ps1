##############################################################
# Version: ALF Lab Builder 2.0.23   (should match VERSION.txt - if this file was replaced on its own, check it is from the same release)
# 00.Workstation-CreateHostVM.ps1
# Creates the Azure VM that hosts the whole nested lab
#
# RUN ON: your workstation or Azure Cloud Shell (PowerShell), with Azure CLI installed
# RUNS:   once per lab
#
# LEARN: Why these choices
#   - Default Standard_D48als_v7 = 48 maximum vCPUs / 96 GiB RAM; request 20 available vCPUs.
#     Validate the maximum locally; Azure enforces supported CPU options at creation.
#     Default guests use 78 GB (DC 2 + admin 4 + 2 nodes x 36); the 16 GB host reserve fits, leaving 18 GB.
#   - NO "d" in the size name. A "d" size adds local temporary disks that are WIPED
#     every time the VM is stopped (deallocated). We use a 1 TB Premium SSD instead.
#   - RDP is opened to YOUR public IP only, never to the whole internet.
##############################################################

#Azure location of the lab
$TenantId       = "{{TenantId}}"         #set in the Lab Builder
$SubscriptionId = "{{SubscriptionId}}"   #set in the Lab Builder
$ResourceGroup  = "{{HostResourceGroup}}"   #resource group for the host VM (set in the Lab Builder)
$Location       = "{{ArcRegion}}"        #same region as the cluster - set in the Lab Builder

#Host VM
$VMName       = "{{HostVMName}}"     #max 15 characters (Windows computer name limit) - set in the Lab Builder
$VMSize       = "{{HostVMSize}}"       #selected in Planning Console section 2
$AvailableVcpus = "{{HostAvailableVcpus}}" #default/minimum lab request: 20; validate against this region's SKU metadata
. (Join-Path $PSScriptRoot 'ALFHostSizing.ps1')
. (Join-Path $PSScriptRoot 'ALFGuestSizing.ps1')
$Image        = "MicrosoftWindowsServer:WindowsServer:2025-datacenter-g2:latest"
$AdminUser    = "{{HostAdminName}}"   #Azure VM administrator account - set in the Lab Builder
$OSDiskGB     = 256
$DataDiskGB   = 1024                  #holds every lab VM (F: drive)

#Auto-shutdown time in UTC (HHMM) - "" to skip. Stops (deallocates) the VM nightly to save cost.
$AutoShutdownUTC = "2300"

####### End of variables ######################


if ($VMSize -eq 'Custom (on-premises)') {
    throw 'Azure host creation is not applicable to Custom (on-premises). Use your existing Windows/Hyper-V SuperHost and start with the host-side lab steps; no Azure sign-in or resource creation was attempted.'
}

#Stop if this is the template (values not filled in by the Lab Builder yet)
if ("$TenantId$SubscriptionId$Location$VMName$ResourceGroup$AdminUser$VMSize$AvailableVcpus" -match '\{\{') {
    throw "This script still has placeholders ({{...}}). Open the Planning Console (Launch-ALFLabBuilder.cmd), fill in the values, and use 'Roll out scripts'."
}

Write-Host "Creating lab host VM $VMName" -ForegroundColor Cyan

#Sign in and select the subscription
Write-Host "  Sign in to Azure" -ForegroundColor Cyan
az login --tenant $TenantId --output none
if ($LASTEXITCODE -ne 0) { throw 'Azure sign-in failed; no resources were created.' }
az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { throw 'Could not select the planned subscription; no resources were created.' }
az account show --query "{Subscription:name, State:state}" -o table

#Read regional metadata if available; do not reject reduced-core requests just because it is absent.
Write-Host "  Check requested host sizing for $VMSize in $Location" -ForegroundColor Cyan
$skus = @()
try { $skus = @(Get-ALFHostSkus $SubscriptionId $Location) }
catch { Write-Host "    SKU discovery unavailable: $($_.Exception.Message)" -ForegroundColor Yellow }
$sku = $skus | Where-Object name -ceq $VMSize | Select-Object -First 1
$maximum = Test-ALFHostSizing $VMSize $AvailableVcpus $sku
$sizingWarning = Get-ALFHostSizingWarning $VMSize $AvailableVcpus $sku
if ($sizingWarning) { Write-Host "    WARNING: $sizingWarning" -ForegroundColor Yellow }
Write-Host "    Requested $AvailableVcpus available vCPUs; SKU maximum $maximum. Base VM price is unchanged. Check regional/family quota separately." -ForegroundColor Yellow

$labBudget = Test-ALFLabSizing (Get-ALFPlannedGuestSizing) $sku
Write-Host "    Planned guests: $($labBudget.GuestMemoryGB) GB RAM; $($labBudget.RemainingHostMemoryGB) GB remains for SuperHost ($($labBudget.HostReserveGB) GB reserve)." -ForegroundColor Cyan
if ($labBudget.Warning) { Write-Warning $labBudget.Warning -WarningAction Continue }

#Create the resource group
Write-Host "  Create resource group $ResourceGroup" -ForegroundColor Cyan
az group create --name $ResourceGroup --location $Location --output none

#Find your public IP (RDP will only be allowed from here)
$MyIP = (Invoke-RestMethod -Uri "https://api.ipify.org")
Write-Host "    Your public IP: $MyIP"

#Create the VM - you will be prompted for the admin password
#LEARN: Password must be 12-123 characters with 3 of: upper, lower, number, symbol.
Write-Host "  Create VM (you will be asked for the admin password)" -ForegroundColor Cyan
Write-Host "  Choosing and remembering passwords is your responsibility." -ForegroundColor Yellow
az vm create `
  --resource-group $ResourceGroup `
  --name $VMName `
  --location $Location `
  --size $VMSize `
  --v-cpus-available $AvailableVcpus `
  --image $Image `
  --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true `
  --admin-username $AdminUser `
  --os-disk-size-gb $OSDiskGB `
  --storage-sku os=Premium_LRS 0=Premium_LRS `
  --data-disk-sizes-gb $DataDiskGB `
  --data-disk-caching None `
  --public-ip-sku Standard `
  --nsg-rule NONE `
  --output none
if ($LASTEXITCODE -ne 0) { throw 'Azure VM creation failed. Review the SKU, vCPU options, quota and capacity error above; no RDP/shutdown actions were run.' }

#Allow RDP from your IP only
Write-Host "  Allow RDP from $MyIP only" -ForegroundColor Cyan
az network nsg rule create `
  --resource-group $ResourceGroup --nsg-name "${VMName}NSG" `
  --name Allow-RDP-MyIP --priority 1000 `
  --access Allow --protocol Tcp --direction Inbound `
  --source-address-prefixes "$MyIP/32" --destination-port-ranges 3389 --output none

#Auto-shutdown
if ($AutoShutdownUTC) {
    Write-Host "  Set auto-shutdown at $AutoShutdownUTC UTC" -ForegroundColor Cyan
    az vm auto-shutdown --resource-group $ResourceGroup --name $VMName --time $AutoShutdownUTC --output none
}

#Show how to connect
$PublicIP = az vm show -d --resource-group $ResourceGroup --name $VMName --query publicIps -o tsv
Write-Host "Host VM ready." -ForegroundColor Green
Write-Host "Connect with RDP to $PublicIP as $AdminUser, then run 01.Host-PrepareDataDisk.ps1" -ForegroundColor Green
################
