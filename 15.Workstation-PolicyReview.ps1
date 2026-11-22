##############################################################
# Version: ALF Lab Builder 2.0.16   (should match VERSION.txt - if this file was replaced on its own, check it is from the same release)
# 15.Workstation-PolicyReview.ps1
# Shows exactly which Azure Policies act on the registered Azure Local nodes (Arc machines),
# and - with approval - creates exemptions for the cluster resource group
#
# RUN ON: your workstation or Azure Cloud Shell (PowerShell), with Azure CLI installed
# WHEN:   after 14.Node-ArcRegister.ps1 (the nodes must exist as Arc machines),
#         and again any time deployment operations time out for no obvious reason
#
# LEARN: Why a second policy review?
#   Script 13 reviewed the policy ASSIGNMENTS before the nodes existed - a forecast.
#   Now the nodes are real Arc machines, Azure Policy has evaluated them. This script reads
#   those results ("policy states"), so it shows the policies that ACTUALLY apply to each
#   node, and what each one does (its effect):
#     Deny              - blocks a resource or setting
#     DeployIfNotExists - deploys something automatically (extension, agent, setting)
#     Modify / Append   - changes the resource as it's created or updated
#     Audit...          - only reports, changes nothing
#   In a customer's tenant, a DeployIfNotExists or Modify policy acting on the Arc machines is
#   the usual cause of "nodes are Connected, extensions Succeeded, but deployment times out".
#
#   Exemptions are only created if you choose to, one by one, with an expiry date.
#   Agree them with the customer's governance team first.
##############################################################

$SubscriptionId = "{{SubscriptionId}}"   #set in the Lab Builder
$ResourceGroup  = "{{ClusterResourceGroup}}"   #Azure Local cluster resource group - set in the Lab Builder

#Exemptions created by this script expire after this many days (keeps lab exemptions from lingering)
$ExemptionDays  = 30

####### End of variables ######################


#Stop if this is the template (values not filled in by the Lab Builder yet)
if ("$SubscriptionId$ResourceGroup" -match '\{\{') {
    throw "This script still has placeholders ({{...}}). Open the Planning Console (Launch-ALFLabBuilder.cmd), fill in the values, and use 'Roll out scripts'."
}

Write-Host "Azure Policy review for Azure Local resource group $ResourceGroup" -ForegroundColor Cyan

$RiskyEffects = @("deny", "denyaction", "deployifnotexists", "modify", "append")


#========== SIGN IN ==========
Write-Host "  Check Azure sign-in" -ForegroundColor Cyan
$account = (az account show -o json 2>$null) -join "`n" | ConvertFrom-Json
if (-not $account) {
    az login --output none
    $account = (az account show -o json) -join "`n" | ConvertFrom-Json
}
if ($SubscriptionId) { az account set --subscription $SubscriptionId; $account = (az account show -o json) -join "`n" | ConvertFrom-Json }
$SubscriptionId = $account.id
$RGScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
Write-Host "    Subscription: $($account.name) ($SubscriptionId)"
Write-Host "    Signed in as: $($account.user.name)"


#========== THE NODES ==========
Write-Host "  Find the Arc machines in $ResourceGroup" -ForegroundColor Cyan
$Machines = (az resource list -g $ResourceGroup --resource-type "Microsoft.HybridCompute/machines" -o json) -join "`n" | ConvertFrom-Json
if (-not @($Machines).Count) {
    Write-Warning "No Arc machines in $ResourceGroup yet. Register the nodes with 14.Node-ArcRegister.ps1 first, or use the policy review at the end of script 13."
    return
}
$Machines | ForEach-Object { Write-Host "    $($_.name)" }


#========== OPTIONAL: FRESH EVALUATION ==========
#LEARN: Azure Policy evaluates new resources within about 30 minutes, then roughly every 24 hours.
#       A scan forces a fresh evaluation now (it takes a few minutes).
Write-Host ""
Write-Host "Run a fresh policy evaluation of $ResourceGroup first? Takes a few minutes. (Y/N)" -ForegroundColor Red -BackgroundColor Yellow
if ((Read-Host "Enter Y or N") -match '^[Yy]$') {
    Write-Host "  Evaluating policies (please wait)..." -ForegroundColor Cyan
    az policy state trigger-scan --resource-group $ResourceGroup --output none
    Write-Host "    Evaluation complete" -ForegroundColor Green
}


#========== WHAT ACTS ON THE NODES ==========
Write-Host "  Read policy results for the Arc machines" -ForegroundColor Cyan
$States = (az policy state list --resource-group $ResourceGroup --top 5000 -o json) -join "`n" | ConvertFrom-Json
$NodeStates = @($States | Where-Object { $_.resourceType -like "Microsoft.HybridCompute/machines*" })

if (-not $NodeStates.Count) {
    Write-Warning "No policy results for the Arc machines yet. Azure Policy can take up to 30 minutes after registration - run again later, or answer Y to the evaluation question."
    return
}

#One row per policy (assignment + member policy + effect), with the nodes it hits
$Rows = $NodeStates | Group-Object policyAssignmentId, policyDefinitionReferenceId, policyDefinitionAction | ForEach-Object {
    $first  = $_.Group[0]
    $effect = ([string]$first.policyDefinitionAction).ToLower()
    $nodes  = @($_.Group | ForEach-Object { ($_.resourceId -split "/machines/")[1] -split "/" | Select-Object -First 1 } | Select-Object -Unique)
    $nonCompliant = @($_.Group | Where-Object complianceState -eq "NonCompliant").Count
    [pscustomobject]@{
        Risk            = if ($RiskyEffects -contains $effect) { "REVIEW" } else { "Report only" }
        Effect          = $effect
        Assignment      = $first.policyAssignmentName
        Policy          = if ($first.policyDefinitionReferenceId) { $first.policyDefinitionReferenceId } else { $first.policyDefinitionName }
        Nodes           = ($nodes -join ", ")
        NonCompliant    = $nonCompliant
        AssignedAt      = $first.policyAssignmentScope
        AssignmentId    = $first.policyAssignmentId
        ReferenceId     = $first.policyDefinitionReferenceId
        IsInitiative    = [bool]$first.policySetDefinitionId
    }
}
$Rows = @($Rows | Sort-Object @{e={ if ($_.Risk -eq "REVIEW") { 0 } else { 1 } }}, Effect, Assignment)

Write-Host ""
Write-Host "Policies acting on the Azure Local nodes" -ForegroundColor Cyan
$Rows | Format-Table Risk, Effect, Assignment, Policy, Nodes, NonCompliant -AutoSize -Wrap

$Review = @($Rows | Where-Object Risk -eq "REVIEW")
Write-Host "  $($Rows.Count) policy result(s) apply to the nodes; $($Review.Count) can change or block them." -ForegroundColor Cyan

#Extensions on the nodes that the lab didn't install - often deployed by a DeployIfNotExists policy
Write-Host "  Extensions on the nodes (the lab installs only the AzureEdge* ones)" -ForegroundColor Cyan
foreach ($m in $Machines) {
    $ext = (az connectedmachine extension list --machine-name $m.name -g $ResourceGroup -o json 2>$null) -join "`n" | ConvertFrom-Json
    foreach ($e in @($ext)) {
        $mark = if ($e.name -like "AzureEdge*") { "" } else { "  <- not from the lab - check which policy deployed it" }
        Write-Host ("    {0,-10} {1,-36} {2}{3}" -f $m.name, $e.name, $e.properties.provisioningState, $mark)
    }
}

#Save the report
$ReportFile = Join-Path (Get-Location) "PolicyResults-$ResourceGroup-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
$Rows | Export-Csv -Path $ReportFile -NoTypeInformation
Write-Host "  Report saved: $ReportFile" -ForegroundColor Green


#========== OPTIONAL: CREATE EXEMPTIONS ==========
#LEARN: An exemption tells Azure Policy to skip a resource group for ONE assignment
#       (or, for an initiative, just the specific member policies listed).
#   - It applies to the CLUSTER resource group only. The customer's assignment is untouched.
#   - Category "Waiver" = accepted risk for this lab. It expires automatically.
#   - You need permission to exempt (e.g. Resource Policy Contributor, plus the
#     "exempt" right on the assignment). If it fails, the customer's governance team must do it.
#   - After an exemption, any extension the policy already deployed stays - remove it from the
#     node's Extensions blade if it's interfering.
if (-not $Review.Count) {
    Write-Host ""
    Write-Host "No Deny / DeployIfNotExists / Modify policies act on the nodes - no exemptions needed." -ForegroundColor Green
    return
}

Write-Host ""
Write-Host "Policies that can change or block the nodes:" -ForegroundColor Yellow
for ($n = 0; $n -lt $Review.Count; $n++) {
    Write-Host ("  [{0}] {1,-18} {2}  ->  {3}" -f ($n + 1), $Review[$n].Effect, $Review[$n].Assignment, $Review[$n].Policy) -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Only exempt policies the customer's governance team has APPROVED." -ForegroundColor Red -BackgroundColor Yellow
$pick = Read-Host "Enter the numbers to exempt (e.g. 1,3), or press Enter to skip"
if ([string]::IsNullOrWhiteSpace($pick)) { Write-Host "No exemptions created." -ForegroundColor Cyan; return }

$Expires = (Get-Date).ToUniversalTime().AddDays($ExemptionDays).ToString("yyyy-MM-ddT00:00:00Z")
$Chosen  = @($pick.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } |
             ForEach-Object { $Review[[int]$_ - 1] } | Where-Object { $_ })

#One exemption per assignment; for initiatives, list the member policies being exempted
foreach ($group in ($Chosen | Group-Object AssignmentId)) {
    $first = $group.Group[0]
    #Exemption name: AzLLab-<resource group>-<assignment>, max 64 characters
    $name = "AzLLab-$ResourceGroup-" + ($first.Assignment -replace '[^A-Za-z0-9-]', '')
    if ($name.Length -gt 64) { $name = $name.Substring(0, 64) }
    $ExArgs = @("policy", "exemption", "create",
               "--name", $name,
               "--display-name", "Azure Local lab - $($first.Assignment)",
               "--policy-assignment", $first.AssignmentId,
               "--scope", $RGScope,
               "--exemption-category", "Waiver",
               "--expires-on", $Expires,
               "--description", "Azure Local nested lab: policy acts on Arc machines and interferes with deployment operations. Expires $Expires.",
               "--output", "none")
    $refs = @($group.Group | Where-Object { $_.IsInitiative -and $_.ReferenceId } | ForEach-Object ReferenceId | Select-Object -Unique)
    if ($refs.Count) { $ExArgs += @("--policy-definition-reference-ids") + $refs }

    Write-Host "  Create exemption $name" -ForegroundColor Cyan
    if ($refs.Count) { Write-Host "    Only these policies in the initiative: $($refs -join ', ')" }
    az @ExArgs
    if ($LASTEXITCODE -eq 0) { Write-Host "    Created - expires $Expires" -ForegroundColor Green }
    else { Write-Warning "Couldn't create the exemption - you may not have permission. Send the report to the customer's governance team." }
}

Write-Host ""
Write-Host "Done. Exemptions can take up to 30 minutes to take effect. Then retry the deployment step that timed out." -ForegroundColor Green
################
