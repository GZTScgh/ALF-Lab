# Run in an approved PowerShell session. Azure responses are mocked; no deployment occurs.
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'ALFHostSizing.ps1')
$script:Passed = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:Passed++
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert $threw $Message
}
$sku = [pscustomobject]@{
    name = 'Standard_D48als_v7'
    restrictions = @()
    capabilities = @(
        @{ name = 'vCPUs'; value = '48' },
        @{ name = 'vCPUsConstraintsAllowed'; value = '[2, 4, 20, 24, 48]' },
        @{ name = 'NestedVirtualization'; value = 'True' },
        @{ name = 'PremiumIO'; value = 'True' },
        @{ name = 'MemoryGB'; value = '96' },
        @{ name = 'MaxResourceVolumeMB'; value = '0' }
    )
}
Assert ((Test-ALFHostSizing $sku.name '20' $sku) -eq 48) 'Advertised 20 must validate with a maximum of 48.'
Assert ((Test-ALFHostSizing $sku.name '48' $sku) -eq 48) 'Full SKU count must be permitted.'
$customSize = 'Custom (on-premises)'
Assert ((Test-ALFHostSizing $customSize '64' $sku) -eq 64) 'Custom CPUs are declared capacity, not limited by a stale Azure SKU maximum.'
Assert ([string]::IsNullOrEmpty((Get-ALFHostSizingWarning $customSize '64' $sku))) 'Custom hosts must not show Azure CPU-support warnings.'
foreach ($count in '', '0', '-2', '2.5', '9999999999999999999999') {
    Assert-Throws { Test-ALFHostSizing $customSize $count } 'Custom CPU capacity must still be a bounded positive whole number.'
}
$choices = @(Get-ALFHostSizeChoices $customSize @($sku))
Assert (@($choices | Where-Object { $_ -eq $customSize }).Count -eq 1 -and $choices -contains $sku.name) 'Custom stays available alongside Azure choices without duplication.'
$choices = @(Get-ALFHostSizeChoices 'Standard_D96als_v7' @($sku))
Assert ($choices -contains $customSize -and $choices -contains 'Standard_D96als_v7') 'Refreshing sizes retains both the custom option and the selected Azure size.'
foreach ($count in '', '0', '-2', '2.5', '50', '9999999999999999999999') {
    Assert-Throws { Test-ALFHostSizing $sku.name $count $sku } 'Reject empty, malformed or over-maximum counts.'
}
Assert ((Test-ALFHostSizing $sku.name '20' $null) -eq 48) 'Default 20 must validate without live metadata using the documented maximum.'
Assert ((Get-ALFHostSizingWarning $sku.name '20' $null) -match 'unverified') 'Offline requests must include an Azure support warning.'
Assert-Throws { Test-ALFHostSizing 'Standard_E16s_v5' '20' $null } 'Do not guess maximums for unknown sizes.'
Assert-Throws { Test-ALFHostSizing $sku.name '50' $null } 'Offline default requests still reject counts above 48.'
Assert-Throws { Test-ALFHostSizing 'Standard_E16s_v5' '20' $sku } 'Metadata from another SKU must not be accepted.'
$noConstraints = $sku | ConvertTo-Json -Depth 5 | ConvertFrom-Json
$noConstraints.capabilities = @($noConstraints.capabilities | Where-Object name -ne 'vCPUsConstraintsAllowed')
Assert ((Test-ALFHostSizing $sku.name '20' $noConstraints) -eq 48) 'Missing reduced-count metadata must not block the request.'
Assert ((Get-ALFHostSizingWarning $sku.name '20' $noConstraints) -match 'does not provide') 'Missing reduced-count metadata must produce a warning.'
Assert ((Test-ALFHostSizing $sku.name '21' $sku) -eq 48) 'A non-advertised count within the maximum is a request, not a local failure.'
Assert ((Get-ALFHostSizingWarning $sku.name '21' $sku) -match 'may reject') 'An unlisted count must warn that Azure may reject it.'
Assert ([string]::IsNullOrEmpty((Get-ALFHostSizingWarning $sku.name '20' $sku))) 'A listed count needs no unsupported-count warning.'
Assert ((Test-ALFHostSizing $sku.name '48' $noConstraints) -eq 48) 'Full count must not need reduced-count metadata.'
Assert ([string]::IsNullOrEmpty((Get-ALFHostSizingWarning $sku.name '48' $noConstraints))) 'Full counts must not warn about missing reduced-count metadata.'
$noMaximum = $sku | ConvertTo-Json -Depth 5 | ConvertFrom-Json
$noMaximum.capabilities = @($noMaximum.capabilities | Where-Object name -ne 'vCPUs')
Assert ((Test-ALFHostSizing $sku.name '20' $noMaximum) -eq 48) 'Absent maximum metadata can use the documented default maximum.'
Assert ((Get-ALFHostSizingWarning $sku.name '20' $noMaximum) -match 'unverified') 'Fallback must not be presented as verified metadata.'
foreach ($badMaximum in '0', 'invalid', '9999999999999999999999') {
    $invalidMaximum = $sku | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    ($invalidMaximum.capabilities | Where-Object name -eq 'vCPUs').value = $badMaximum
    Assert-Throws { Test-ALFHostSizing $sku.name '20' $invalidMaximum } 'Invalid maximum metadata must not silently fall back to 48.'
}
$small = $sku | ConvertTo-Json -Depth 5 | ConvertFrom-Json
$small.name = 'Standard_D16als_v7'
($small.capabilities | Where-Object name -eq 'vCPUs').value = '16'
Assert-Throws { Test-ALFHostSizing $small.name '20' $small } 'A smaller selected SKU must constrain the maximum.'

$planningPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ALFLabBuilder.ps1'
$tokens = $null; $errors = $null
$planningAst = [Management.Automation.Language.Parser]::ParseFile($planningPath, [ref]$tokens, [ref]$errors)
$fn = $planningAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-HostSizingStatus' }, $true) | Select-Object -First 1
. ([scriptblock]::Create($fn.Extent.Text))
$items = @(
    [pscustomobject]@{ Key = 'HostVMSize'; Value = $sku.name; Status = ''; Hint = '' },
    [pscustomobject]@{ Key = 'HostAvailableVcpus'; Value = '20'; Status = ''; Hint = '' },
    [pscustomobject]@{ Key = 'SubscriptionId'; Value = '11111111-1111-1111-1111-111111111111' }
)
$script:HostSkus = @(); $script:HostSkuContext = ''
Assert (Update-HostSizingStatus) 'Planning must allow 20 when there has been no Azure refresh.'
Assert ($items[1].Status -eq '20 / 48 max' -and $items[0].Status -eq 'Check Azure') 'Show the requested count and warning, not an invalid status.'
$script:HostSkus = @($noConstraints); $script:HostSkuContext = '11111111-1111-1111-1111-111111111111|southcentralus'
Assert (Update-HostSizingStatus) 'Planning must allow 20 when reduced-count metadata is absent.'
$items[1].Value = '50'
Assert (-not (Update-HostSizingStatus)) 'Planning must still reject counts over the maximum.'
$items[1].Value = '20'
$items[2].Value = '22222222-2222-2222-2222-222222222222'
Assert (Update-HostSizingStatus) 'Changed subscription must use offline default validation without blocking 20.'
Assert ($items[1].Hint -match 'unverified') 'Changed subscription must not reuse verified metadata from another subscription.'
$items[0].Value = $customSize
$items[1].Value = '64'
Assert (Update-HostSizingStatus) 'Planning permits custom capacity above the default Azure maximum without a refresh.'
Assert ($items[0].Status -eq 'On-premises' -and $items[1].Status -eq '64 entered' -and $items[1].Hint -notmatch 'quota') 'Display declared custom capacity, not Azure availability or a fabricated maximum.'
$commandFn = $planningAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-Commands' }, $true)[0]
$expandFn = $planningAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Expand-LabTemplate' }, $true)[0]
. ([scriptblock]::Create($commandFn.Extent.Text))
. ([scriptblock]::Create($expandFn.Extent.Text))
$commandRow = [pscustomobject]@{ Key='CliCreateHostVM'; Type='cli'; Command='az vm create --size "{{HostVMSize}}"'; Value=''; Example=''; Status='' }
$items += $commandRow
Update-Commands
Assert ($commandRow.Status -eq 'Not applicable' -and $commandRow.Value -notmatch 'az vm create') 'Do not display a runnable Azure host command for on-premises sizing.'
$items[0].Value = $sku.name
Update-Commands
Assert ($commandRow.Value -match 'az vm create' -and $commandRow.Value -match 'Standard_D48als_v7' -and $commandRow.Status -eq 'Copy') 'Switching back to Azure restores the selected SKU command and copy status.'
$hostTokens = $null; $hostErrors = $null
$hostAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) '00.Workstation-CreateHostVM.ps1'), [ref]$hostTokens, [ref]$hostErrors)
$guard = $hostAst.FindAll({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith("if (`$VMSize -eq 'Custom (on-premises)')") }, $true)[0]
$VMSize = $customSize
Assert-Throws { & ([scriptblock]::Create($guard.Extent.Text)) } 'Script 00 explicitly refuses Azure creation for a custom on-premises host.'
$restricted = $sku | ConvertTo-Json -Depth 5 | ConvertFrom-Json
$restricted.name = 'Standard_D64als_v7'
$restricted.restrictions = @(@{ type = 'Location'; reasonCode = 'NotAvailableForSubscription' })
$script:MockResponse = @($sku, $restricted) | ConvertTo-Json -Depth 6
function az {
    $script:AzureArgs = @($args)
    $global:LASTEXITCODE = 0
    $script:MockResponse
}
$available = @(Get-ALFHostSkus '11111111-1111-1111-1111-111111111111' 'southcentralus')
Assert ($available.Count -eq 1 -and $available[0].name -eq $sku.name) 'Region-restricted sizes must be filtered.'
Assert ($script:AzureArgs -contains '--subscription' -and $script:AzureArgs -contains 'southcentralus') 'Discovery must explicitly scope subscription and region.'
function az { $global:LASTEXITCODE = 1; 'CLI failed' }
Assert-Throws { Get-ALFHostSkus '11111111-1111-1111-1111-111111111111' 'southcentralus' } 'A failed query must not produce a verified SKU list.'
Remove-Item function:az

$plan = [pscustomobject]@{ ClusterIdentifier = '2778'; Values = @(
    [pscustomobject]@{ Key = 'HostVMName'; Group = '2. Host'; Value = 'LABHOST2778-vm' },
    [pscustomobject]@{ Key = 'CliCreateHostVM'; Command = 'az vm create --size Standard_D48als_v7' }
) }
Initialize-ALFHostSizingPlan $plan
Assert (($plan.Values | Where-Object Key -eq 'HostVMSize').Value -eq $sku.name) 'Legacy plans must acquire a default SKU row.'
Assert (($plan.Values | Where-Object Key -eq 'HostAvailableVcpus').Value -eq '20') 'Legacy plans must acquire the requested default count.'
Assert ($plan.ClusterIdentifier -eq '2778' -and ($plan.Values | Where-Object Key -eq 'HostVMName').Value -eq 'LABHOST2778-vm') 'Migration must preserve student names and identifiers.'
($plan.Values | Where-Object Key -eq 'HostAvailableVcpus').Value = '24'
Initialize-ALFHostSizingPlan $plan
Assert (@($plan.Values | Where-Object Key -eq 'HostVMSize').Count -eq 1 -and ($plan.Values | Where-Object Key -eq 'HostAvailableVcpus').Value -eq '24') 'Repeated migration must preserve selected values and not duplicate rows.'
Assert (($plan.Values | Where-Object Key -eq 'CliCreateHostVM').Command.Contains('--v-cpus-available {{HostAvailableVcpus}}')) 'Legacy CLI commands must use selected counts.'
($plan.Values | Where-Object Key -eq 'HostVMSize').Value = $customSize
Initialize-ALFHostSizingPlan $plan
$sizeRow = $plan.Values | Where-Object Key -eq 'HostVMSize'
Assert ($sizeRow.Value -eq $customSize -and $sizeRow.Value -match $sizeRow.Pattern) 'Save/reload migration retains a valid custom selection.'
Assert (($plan.Values | Where-Object Group -eq '2. Host' | Select-Object -First 1).Key -eq 'HostVMSize') 'The size choice appears first in the host section after migration and reload.'
Write-Output "PASS: $script:Passed host-sizing checks; mocked Azure metadata, no provisioning."
