##############################################################
# Version: ALF Lab Builder 2.0.14   (should match VERSION.txt - if this file was replaced on its own, check it is from the same release)
# 13.Workstation-AzurePrereqs.ps1
# Registers the Azure resource providers and assigns the roles Azure Local needs
#
# RUN ON: your workstation or Azure Cloud Shell (PowerShell), with Azure CLI installed
# RUN AS: an account with Owner or User Access Administrator on the subscription
#
# LEARN:
#   Resource providers - each Azure service has to be "switched on" for a subscription
#                        before you can create its resources.
#   Roles              - Owner/Contributor alone is NOT enough. The deployment creates a
#                        Key Vault and reads/writes its secrets, which needs the Key Vault
#                        data-plane roles below. Missing them gives "Insufficient permissions
#                        at resource group level" on the Key Vault step of the wizard.
#   After assigning roles, sign out of the portal and back in so your token picks them up.
#   Azure Policy  - the end of this script reviews the policies that will apply to the nodes.
##############################################################

$TenantId       = "{{TenantId}}"         #set in the Lab Builder
$SubscriptionId = "{{SubscriptionId}}"   #set in the Lab Builder
$ResourceGroup  = "{{ClusterResourceGroup}}"   #Azure Local cluster resource group - set in the Lab Builder
$Location       = "{{ArcRegion}}"        #set in the Lab Builder

#Who will run the deployment ("" = the account you sign in with)
$DeployUserUPN  = ""

$ResourceProviders = @(
    "Microsoft.HybridCompute", "Microsoft.GuestConfiguration", "Microsoft.HybridConnectivity",
    "Microsoft.AzureStackHCI", "Microsoft.Kubernetes", "Microsoft.KubernetesConfiguration",
    "Microsoft.ExtendedLocation", "Microsoft.ResourceConnector", "Microsoft.HybridContainerService",
    "Microsoft.Attestation", "Microsoft.Storage", "Microsoft.Insights", "Microsoft.KeyVault"
)

$ResourceGroupRoles = @(
    "Key Vault Data Access Administrator",
    "Key Vault Secrets Officer",
    "Key Vault Contributor",
    "Storage Account Contributor",
    "Azure Connected Machine Onboarding",
    "Azure Connected Machine Resource Administrator"
)

$SubscriptionRoles = @(
    "Azure Stack HCI Administrator",
    "Reader"
)

####### End of variables ######################


#Stop if this is the template (values not filled in by the Lab Builder yet)
if ("$TenantId$SubscriptionId$ResourceGroup$Location" -match '\{\{') {
    throw "This script still has placeholders ({{...}}). Open the Planning Console (Launch-ALFLabBuilder.cmd), fill in the values, and use 'Roll out scripts'."
}

Write-Host "Preparing Azure for the Azure Local deployment" -ForegroundColor Cyan

#Sign in
Write-Host "  Sign in to Azure" -ForegroundColor Cyan
az login --tenant $TenantId --output none
az account set --subscription $SubscriptionId

#Resource group (created if missing)
Write-Host "  Check resource group $ResourceGroup" -ForegroundColor Cyan
az group create --name $ResourceGroup --location $Location --output none

#Register resource providers
Write-Host "  Register resource providers (can take a few minutes)" -ForegroundColor Cyan
foreach ($rp in $ResourceProviders) {
    $state = az provider show --namespace $rp --query registrationState -o tsv
    if ($state -eq "Registered") {
        Write-Host "    $rp - already registered" -ForegroundColor Yellow
    } else {
        Write-Host "    $rp - registering"
        az provider register --namespace $rp --wait --output none
    }
}

#Who gets the roles
if ($DeployUserUPN) { $UserId = az ad user show --id $DeployUserUPN --query id -o tsv }
else                { $UserId = az ad signed-in-user show --query id -o tsv }
Write-Host "  Assign roles to object id $UserId" -ForegroundColor Cyan

$RGScope  = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$SubScope = "/subscriptions/$SubscriptionId"

#Resource group roles
foreach ($role in $ResourceGroupRoles) {
    az role assignment create --assignee-object-id $UserId --assignee-principal-type User `
        --role $role --scope $RGScope --output none
    Write-Host "    RG  : $role"
}

#Subscription roles
foreach ($role in $SubscriptionRoles) {
    az role assignment create --assignee-object-id $UserId --assignee-principal-type User `
        --role $role --scope $SubScope --output none
    Write-Host "    Sub : $role"
}

#Verify
Write-Host "  Verify" -ForegroundColor Cyan
az role assignment list --assignee $UserId --all --query "[].{Role:roleDefinitionName, Scope:scope}" -o table



#==================================================================
# AZURE POLICY REVIEW (before Arc registration)
#==================================================================
#LEARN: Why this matters
#   This lab often runs in a CUSTOMER's tenant. Their Azure Policy assignments - usually set at
#   the management group or subscription and INHERITED by your resource group - apply to the
#   Arc machines the moment the nodes register. Some only report (Audit), but others act:
#     Deny              - blocks a resource or setting from being created
#     DeployIfNotExists - automatically deploys something (an extension, an agent, a setting)
#     Modify / Append   - changes the resource (tags, settings) as it's created or updated
#   On Azure Local nodes these can block the deployment, or install extensions that interfere
#   with it. The symptom is confusing: the nodes show "Connected", every extension says
#   "Succeeded", but deployment operations time out ("No updates received from device").
#
#   This section only READS. It changes nothing. Share the report with the customer's
#   governance team BEFORE you start, and agree on exemptions for the cluster resource group.
#   After the nodes are registered, run 15.Workstation-PolicyReview.ps1 for the exact list of
#   policies acting on the Arc machines, and to create exemptions if they're approved.

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
$ReportFile = Join-Path (Get-Location) "PolicyReview-$ResourceGroup-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
$Report | Export-Csv -Path $ReportFile -NoTypeInformation
Write-Host "  Report saved: $ReportFile" -ForegroundColor Green

#LEARN: How exemptions work (do this only with the customer's approval)
#   - Exempt the CLUSTER resource group only - never disable the customer's assignment itself.
#   - Category "Waiver" = accepted risk; "Mitigated" = the requirement is met another way.
#   - Give it an expiry date for a lab, so it doesn't outlive the lab.
#   - You need permission to exempt (e.g. Resource Policy Contributor) - customers often keep this
#     with their governance team.
#   Example:
#     az policy exemption create --name "AzLLab-$ResourceGroup" --policy-assignment <AssignmentId> `
#        --scope $RGScope --exemption-category Waiver --expires-on 2026-12-31T00:00:00Z `
#        --description "Azure Local lab - policy interferes with Arc deployment operations"
#   15.Workstation-PolicyReview.ps1 can create these for you after the nodes are registered.

Write-Host ""
Write-Host "Azure ready. Sign out of the portal and back in, then run 14.Node-ArcRegister.ps1 on each node." -ForegroundColor Green
Write-Host "After the nodes are registered, run 15.Workstation-PolicyReview.ps1 to check which policies act on them." -ForegroundColor Green
################
