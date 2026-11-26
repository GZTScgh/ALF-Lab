##############################################################
# Version: ALF Lab Builder 2.1.1   (should match VERSION.txt - if this file was replaced on its own, check it is from the same release)
# Azure-Prep.ps1
# Quick Azure preparation for the Azure Local lab, using the values from the Lab Builder:
#   -Step ResourceGroups : create the host VM and cluster resource groups (+ resource providers)
#   -Step Roles          : assign the deployment roles (RBAC) on the cluster resource group
#   -Step Policy         : review the Azure Policy assignments that apply to the cluster resource group
#   -Step All            : all three, in order
#
# RUN ON: your workstation, with the Azure CLI installed (or Azure Cloud Shell)
#         The Lab Builder's Azure buttons run this for you in a new PowerShell window.
#   e.g.  .\Azure-Prep.ps1 -Step Roles
##############################################################

param(
    [ValidateSet("ResourceGroups", "Roles", "Policy", "All")]
    [string]$Step = "All"
)

#Values from the Lab Builder
$TenantId          = "{{TenantId}}"
$SubscriptionId    = "{{SubscriptionId}}"
$Location          = "{{ArcRegion}}"
$HostResourceGroup = "{{HostResourceGroup}}"
$ResourceGroup     = "{{ClusterResourceGroup}}"   #the Azure Local cluster resource group

#Who gets the roles ("" = the account you sign in with)
$DeployUserUPN = ""

$ResourceProviders = @(
    "Microsoft.HybridCompute", "Microsoft.GuestConfiguration", "Microsoft.HybridConnectivity",
    "Microsoft.AzureStackHCI", "Microsoft.Kubernetes", "Microsoft.KubernetesConfiguration",
    "Microsoft.ExtendedLocation", "Microsoft.ResourceConnector", "Microsoft.HybridContainerService",
    "Microsoft.Attestation", "Microsoft.Storage", "Microsoft.Insights", "Microsoft.KeyVault"
)
$ResourceGroupRoles = @(
    "Key Vault Data Access Administrator", "Key Vault Secrets Officer", "Key Vault Contributor",
    "Storage Account Contributor", "Azure Connected Machine Onboarding",
    "Azure Connected Machine Resource Administrator"
)
$SubscriptionRoles = @("Azure Stack HCI Administrator", "Reader")

####### End of variables ######################


#Stop if this is the template (values not filled in by the Lab Builder yet)
if ("$TenantId$SubscriptionId$Location$HostResourceGroup$ResourceGroup" -match '\{\{') {
    throw "This script still has placeholders ({{...}}). Open the Planning Console (Launch-ALFLabBuilder.cmd), fill in the values, and use 'Roll out scripts'."
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "The Azure CLI isn't installed. Install it with:  winget install -e --id Microsoft.AzureCLI   then open a new window."
}

$RGScope  = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$SubScope = "/subscriptions/$SubscriptionId"
$Host.UI.RawUI.WindowTitle = "Azure prep - $Step - $ResourceGroup"


#========== SIGN IN (only if needed) ==========
Write-Host "Azure prep: $Step" -ForegroundColor Cyan
Write-Host "  Tenant $TenantId | Subscription $SubscriptionId | Region $Location"
$acct = (az account show -o json 2>$null) -join "`n" | ConvertFrom-Json
if (-not $acct -or $acct.tenantId -ne $TenantId) {
    Write-Host "  Sign in to tenant $TenantId" -ForegroundColor Cyan
    az login --tenant $TenantId --output none
}
az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { throw "Can't select subscription $SubscriptionId - check you have access to it" }
$acct = (az account show -o json) -join "`n" | ConvertFrom-Json
Write-Host "  Signed in as $($acct.user.name) - subscription '$($acct.name)'" -ForegroundColor Green


#========== STEP: RESOURCE GROUPS ==========
if ($Step -in "ResourceGroups", "All") {
    Write-Host ""
    Write-Host "Create resource groups in $Location" -ForegroundColor Cyan
    #LEARN: az group create is safe to repeat - an existing group is left as it is.
    foreach ($rg in $HostResourceGroup, $ResourceGroup) {
        $exists = (az group exists --name $rg) -eq "true"
        if ($exists) { Write-Host "  $rg - already exists" -ForegroundColor Yellow }
        else {
            az group create --name $rg --location $Location --output none
            Write-Host "  $rg - created" -ForegroundColor Green
        }
    }

    Write-Host "Register resource providers (first time takes a few minutes)" -ForegroundColor Cyan
    foreach ($rp in $ResourceProviders) {
        $state = az provider show --namespace $rp --query registrationState -o tsv
        if ($state -eq "Registered") { Write-Host "  $rp - registered" -ForegroundColor Yellow }
        else {
            az provider register --namespace $rp --wait --output none
            Write-Host "  $rp - registered now" -ForegroundColor Green
        }
    }
}


#========== STEP: ROLES (RBAC) ==========
if ($Step -in "Roles", "All") {
    Write-Host ""
    Write-Host "Assign deployment roles" -ForegroundColor Cyan
    #LEARN: Owner/Contributor alone is NOT enough - the deployment creates a Key vault and
    #       reads/writes its secrets, which needs the Key Vault data-plane roles. You need
    #       Owner or User Access Administrator to assign roles.
    if ((az group exists --name $ResourceGroup) -ne "true") {
        throw "Resource group $ResourceGroup doesn't exist yet - run the ResourceGroups step first"
    }
    if ($DeployUserUPN) { $UserId = az ad user show --id $DeployUserUPN --query id -o tsv; $Who = $DeployUserUPN }
    else                { $UserId = az ad signed-in-user show --query id -o tsv; $Who = $acct.user.name }
    Write-Host "  Assigning to $Who" -ForegroundColor Cyan

    $existing = (az role assignment list --assignee $UserId --all -o json) -join "`n" | ConvertFrom-Json
    function Grant-Role($Role, $Scope, $Label) {
        if ($existing | Where-Object { $_.roleDefinitionName -eq $Role -and $_.scope -eq $Scope }) {
            Write-Host ("  {0,-15} {1} - already assigned" -f $Label, $Role) -ForegroundColor Yellow; return
        }
        az role assignment create --assignee-object-id $UserId --assignee-principal-type User --role $Role --scope $Scope --output none
        if ($LASTEXITCODE -eq 0) { Write-Host ("  {0,-15} {1} - assigned" -f $Label, $Role) -ForegroundColor Green }
        else { Write-Warning "$Role could not be assigned - you need Owner or User Access Administrator" }
    }
    foreach ($r in $ResourceGroupRoles) { Grant-Role $r $RGScope "Resource group" }
    foreach ($r in $SubscriptionRoles)  { Grant-Role $r $SubScope "Subscription" }

    Write-Host "  Roles now assigned to $Who" -ForegroundColor Cyan
    az role assignment list --assignee $UserId --all --query "[].{Role:roleDefinitionName, Scope:scope}" -o table
    Write-Host "  Sign OUT of the Azure portal and back IN so it picks up the new roles." -ForegroundColor Yellow
}


#========== STEP: AZURE POLICY REVIEW ==========
if ($Step -in "Policy", "All") {
    #LEARN: This only READS - it changes nothing. Customer tenants often have policies, inherited
    #       from a management group or the subscription, that act on Arc machines as soon as the
    #       nodes register. After the nodes register, run 15.Workstation-PolicyReview.ps1 for the
    #       exact list, and to create exemptions the customer has approved.

    Write-Host ""
    Write-Host "Review Azure Policy for resource group $ResourceGroup" -ForegroundColor Cyan

    $RiskyEffects = @("deny", "denyaction", "deployifnotexists", "modify", "append")

    #Read any Azure resource by its id (works for built-in and custom definitions)
    function Get-AzResourceJson([string]$Id) {
        $out = az rest --method get --url "https://management.azure.com$($Id)?api-version=2023-04-01" 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return (($out -join "`n") | ConvertFrom-Json) }
        return $null
    }

    #Find a definition's effect, following "[parameters('effect')]" to the assigned or default value
    function Resolve-Effect($Definition, $AssignedParams) {
        $effect = [string]$Definition.properties.policyRule.then.effect
        if ($effect -match "^\[parameters\('(.+)'\)\]$") {
            $name = $Matches[1]
            $assigned = if ($AssignedParams) { $AssignedParams.$name.value } else { $null }
            $effect = if ($assigned) { $assigned } else { [string]$Definition.properties.parameters.$name.defaultValue }
            if ($effect -match "^\[parameters") { $effect = "(set by initiative)" }
        }
        return $effect.ToLower()
    }

    #Does the rule mention Arc machines or Azure Local?
    function Test-TargetsArc($Definition) {
        $rule = $Definition.properties.policyRule | ConvertTo-Json -Depth 50 -Compress
        return [bool]($rule -match 'Microsoft\.HybridCompute|Microsoft\.AzureStackHCI')
    }

    #1. Every assignment that applies to the resource group, including inherited ones
    Write-Host "  Read policy assignments (including inherited from subscription / management group)" -ForegroundColor Cyan
    $Assignments = (az policy assignment list --scope $RGScope --disable-scope-strict-match -o json) -join "`n" | ConvertFrom-Json
    Write-Host "    $(@($Assignments).Count) assignment(s) apply to $ResourceGroup"

    $Report = foreach ($a in $Assignments) {
        $defId = [string]$a.policyDefinitionId
        $isSet = $defId -match "/policySetDefinitions/"
        $level = if ($a.scope -match "managementGroups/([^/]+)") { "Mgmt group: $($Matches[1])" }
                 elseif ($a.scope -match "resourceGroups/([^/]+)$") { "Resource group" }
                 else { "Subscription" }
        $effects = @(); $arc = $false; $note = ""

        $def = Get-AzResourceJson $defId
        if (-not $def) { $note = "Definition not readable" }
        elseif (-not $isSet) {
            $effects = @(Resolve-Effect $def $a.parameters)
            $arc = Test-TargetsArc $def
        }
        else {
            #Initiative: look inside its member policies (large initiatives are only summarised)
            $members = @($def.properties.policyDefinitions)
            if ($members.Count -le 60) {
                foreach ($m in $members) {
                    $md = Get-AzResourceJson $m.policyDefinitionId
                    if ($md -and (Test-TargetsArc $md)) {
                        $arc = $true
                        $effects += Resolve-Effect $md $null
                    }
                }
                $note = "Initiative with $($members.Count) policies"
            } else {
                $note = "Large initiative ($($members.Count) policies) - check with script 15 after registration"
            }
        }

        $effects = @($effects | Where-Object { $_ } | Select-Object -Unique)
        $enforced = $a.enforcementMode -ne "DoNotEnforce"
        $risk = if (-not $enforced) { "Not enforced" }
                elseif ($arc -and ($effects | Where-Object { $RiskyEffects -contains $_ })) { "REVIEW - acts on Arc machines" }
                elseif ($arc) { "Applies to Arc machines (report only)" }
                elseif ($effects | Where-Object { $RiskyEffects -contains $_ }) { "Can change or block resources" }
                else { "Low" }

        [pscustomobject]@{
            Risk        = $risk
            Assignment  = $a.displayName
            Type        = if ($isSet) { "Initiative" } else { "Policy" }
            AssignedAt  = $level
            Effects     = ($effects -join ", ")
            TargetsArc  = $arc
            Note        = $note
            AssignmentId = $a.id
        }
    }

    #Show the riskiest first
    $Order = @{ "REVIEW - acts on Arc machines" = 0; "Can change or block resources" = 1; "Applies to Arc machines (report only)" = 2; "Low" = 3; "Not enforced" = 4 }
    $Report = @($Report | Sort-Object { $Order[$_.Risk] }, Assignment)
    $Report | Format-Table Risk, Assignment, Type, AssignedAt, Effects, Note -AutoSize -Wrap

    $Review = @($Report | Where-Object Risk -eq "REVIEW - acts on Arc machines")
    if ($Review.Count) {
        Write-Host "  $($Review.Count) assignment(s) act on Arc machines - discuss these with the customer BEFORE registering the nodes:" -ForegroundColor Yellow
        $Review | ForEach-Object { Write-Host "    - $($_.Assignment)  [$($_.Effects)]  ($($_.AssignedAt))" -ForegroundColor Yellow }
    } else {
        Write-Host "  No enforced Deny / DeployIfNotExists / Modify policies found that target Arc machines." -ForegroundColor Green
    }

    #2. Exemptions already in place
    Write-Host "  Existing policy exemptions for $ResourceGroup" -ForegroundColor Cyan
    $Exemptions = (az policy exemption list --scope $RGScope --disable-scope-strict-match -o json 2>$null) -join "`n" | ConvertFrom-Json
    if (@($Exemptions).Count) {
        $Exemptions | Format-Table @{n='Exemption';e={$_.displayName}}, exemptionCategory, expiresOn, @{n='Assignment';e={($_.policyAssignmentId -split '/')[-1]}} -AutoSize
    } else {
        Write-Host "    None"
    }

    #3. Save the report for the customer's governance team
    $ReportFile = Join-Path $PSScriptRoot "PolicyReview-$ResourceGroup-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
    $Report | Export-Csv -Path $ReportFile -NoTypeInformation
    Write-Host "  Report saved: $ReportFile" -ForegroundColor Green
    Write-Host "After the nodes register, run 15.Workstation-PolicyReview.ps1 for the exact policies acting on them." -ForegroundColor Green
}

Write-Host ""
Write-Host "Done: $Step" -ForegroundColor Green
################
