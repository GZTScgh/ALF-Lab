# Run in an approved STA PowerShell session. Sizing and mocked host checks only; no provisioning.
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'ALFGuestSizing.ps1')
$script:Passed = 0
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:Passed++ }
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert $threw $Message
}
$values = @{
    HostVMSize='Standard_D48als_v7'; HostAvailableVcpus='20'; HostMemoryGB='96'; HostMemoryReserveGB='16'
    DCVcpus='2'; DCMemoryGB='2'; AdminVcpus='2'; AdminMemoryGB='4'; NodeVcpus='12'; NodeMemoryGB='36'
}
$budget = Test-ALFLabSizing $values
Assert ($budget.GuestMemoryGB -eq 78 -and $budget.AllocatableMemoryGB -eq 80 -and $budget.RemainingHostMemoryGB -eq 18) 'The four default guests must fit a 96-GB host while preserving its 16-GB reserve.'
Assert ($budget.GuestVcpus -eq 28 -and $budget.Warning -match 'overcommit') 'The 20-vCPU default must allow 28 shared guest vCPUs and warn, not force 28 host CPUs.'
Assert ($budget.Warning -notmatch 'recommended 20') 'The recommended 20 vCPUs gives no below-recommended warning.'
foreach ($cpus in '16', '12') {
    $lean = $values.Clone(); $lean.HostAvailableVcpus = $cpus
    $leanBudget = Test-ALFLabSizing $lean
    Assert ($leanBudget.HostVcpus -eq [int]$cpus -and $leanBudget.Warning -match "^$cpus SuperHost vCPUs is below the recommended 20" -and $leanBudget.Warning -match 'overcommit') "$cpus SuperHost vCPUs is allowed for testing with a performance warning."
}
$leanNodes = $values.Clone(); $leanNodes.HostAvailableVcpus = '16'; $leanNodes.NodeVcpus = '16'
Assert ((Test-ALFLabSizing $leanNodes).GuestVcpus -eq 36) 'Nodes may use every vCPU of a 16-vCPU SuperHost.'
foreach ($case in @(
    @('HostAvailableVcpus','11'),  @('HostMemoryGB','95'), @('HostMemoryReserveGB','0'),
    @('DCVcpus','1'), @('DCMemoryGB','1'), @('AdminVcpus','1'), @('AdminMemoryGB','3'),
    @('NodeVcpus','11'), @('NodeMemoryGB','35'), @('NodeVcpus','21')
)) {
    $bad = $values.Clone(); $bad[$case[0]] = $case[1]
    Assert-Throws { Test-ALFLabSizing $bad } 'Reject sizes below the lab minimum or a single guest exceeding host CPUs.'
}
foreach ($text in '', '-2', '12.5', '9999999999999999999999') {
    $bad = $values.Clone(); $bad.NodeVcpus = $text
    Assert-Throws { Test-ALFLabSizing $bad } 'Require bounded positive whole-number CPU allocations.'
}
$exact = $values.Clone(); $exact.HostMemoryReserveGB = '18'
Assert ((Test-ALFLabSizing $exact).AllocatableMemoryGB -eq 78) 'Allow guest memory exactly equal to the allocatable budget.'
$exact.HostMemoryReserveGB = '19'
Assert-Throws { Test-ALFLabSizing $exact } 'Reject even a one-GB RAM over-allocation after reserving host memory.'
$larger = $values.Clone(); $larger.HostVMSize = 'Standard_D96als_v7'; $larger.HostAvailableVcpus = '48'; $larger.HostMemoryGB = '192'
$larger.DCVcpus = '4'; $larger.DCMemoryGB = '8'; $larger.AdminVcpus = '4'; $larger.AdminMemoryGB = '8'; $larger.NodeVcpus = '20'; $larger.NodeMemoryGB = '64'
$sku = [pscustomobject]@{ name=$larger.HostVMSize; capabilities=@(@{name='MemoryGB';value='192'}) }
$scaled = Test-ALFLabSizing $larger $sku
Assert ($scaled.GuestMemoryGB -eq 144 -and $scaled.GuestVcpus -eq 48 -and [string]::IsNullOrEmpty($scaled.Warning)) 'Apply equal enlarged node allocations twice and allow a larger balanced host without CPU-sharing warnings.'
$wrong = $values.Clone(); $wrong.HostMemoryGB = '192'
Assert-Throws { Test-ALFLabSizing $wrong } 'Typing more RAM must not pretend the default Azure SKU gained memory.'
Assert-Throws { Test-ALFLabSizing $values $sku } 'Do not use memory metadata from another SKU.'
Assert ((Test-ALFLabSizing $larger).Warning -match 'unverified') 'Unknown SKU RAM can budget declared memory, but must not claim Azure verification.'
$custom = $values.Clone(); $custom.HostVMSize = 'Custom (on-premises)'; $custom.HostAvailableVcpus = '64'; $custom.HostMemoryGB = '256'
$custom.NodeVcpus = '24'; $custom.NodeMemoryGB = '64'
$customBudget = Test-ALFLabSizing $custom $sku
Assert ($customBudget.GuestMemoryGB -eq 134 -and $customBudget.GuestVcpus -eq 52 -and [string]::IsNullOrEmpty($customBudget.Warning)) 'Use manually entered custom CPU/RAM without Azure metadata checks or unverified-SKU warnings.'
$threeNodes = Test-ALFLabSizing $custom $sku -NodeCount 3
Assert ($threeNodes.GuestMemoryGB -eq 198 -and $threeNodes.GuestVcpus -eq 76 -and $threeNodes.Warning -match 'overcommit') 'Budget every node chosen in Host Console step 9.'
$defaultTooMany = ''
try { Test-ALFLabSizing $values -NodeCount 3 | Out-Null } catch { $defaultTooMany = $_.Exception.Message }
Assert ($defaultTooMany -match '3 nodes' -and $defaultTooMany -match 'fewer nodes') 'The default 96-GB host holds only two nodes and says how to fix it.'
$plannedThree = $values.Clone(); $plannedThree.NodeCount = '3'
$plannedTooMany = ''
try { Test-ALFLabSizing $plannedThree | Out-Null } catch { $plannedTooMany = $_.Exception.Message }
Assert ($plannedTooMany -match '3 nodes' -and $plannedTooMany -match 'Planning Console') 'The planned Number of Azure Local nodes is budgeted from the plan values.'
Assert ((Test-ALFLabSizing $plannedThree -NodeCount 2).NodeCount -eq 2) 'The count chosen in Host Console step 9 overrides the plan.'
$customThree = $custom.Clone(); $customThree.NodeCount = '3'
Assert ((Test-ALFLabSizing $customThree $sku).GuestMemoryGB -eq 198) 'A larger host can plan three nodes up front.'
foreach ($text in '1', '17', 'x', '02') {
    $bad = $custom.Clone(); $bad.NodeCount = $text; $field = ''
    try { Test-ALFLabSizing $bad | Out-Null } catch { $field = $_.Exception.Data['Field'] }
    Assert ($field -eq 'NodeCount') "A planned node count of '$text' must be rejected on its own field."
}
Assert-Throws { Test-ALFLabSizing $custom -NodeCount 16 } 'Sixteen 64-GB nodes do not fit a 256-GB host.'
foreach ($count in 1, 17) {
    Assert-Throws { Test-ALFLabSizing $custom -NodeCount $count } 'The lab supports 2 to 16 nodes.'
}
$badCustom = $custom.Clone(); $badCustom.NodeMemoryGB = '128'
Assert-Throws { Test-ALFLabSizing $badCustom } 'Custom hosts still enforce the RAM reserve and guest budget.'
$badCustom = $custom.Clone(); $badCustom.HostAvailableVcpus = '11'
Assert-Throws { Test-ALFLabSizing $badCustom } 'The same minimum host CPU requirement applies on-premises.'
$badCustom = $custom.Clone(); $badCustom.HostMemoryGB = '95'
Assert-Throws { Test-ALFLabSizing $badCustom } 'The same minimum host RAM requirement applies on-premises.'

$plan = [pscustomobject]@{ ClusterIdentifier='3222'; Values=@(
    [pscustomobject]@{Key='HostAvailableVcpus';Group='2. Host';Value='20'},
    [pscustomobject]@{Key='HostVMName';Group='2. Host';Value='LABHOST3222-vm'}
) }
Initialize-ALFGuestSizingPlan $plan
Assert (($plan.Values | Where-Object Key -eq 'NodeVcpus').Value -eq '12' -and ($plan.Values | Where-Object Key -eq 'HostMemoryGB').Value -eq '96') 'Older plans acquire the requested node and SuperHost defaults.'
($plan.Values | Where-Object Key -eq 'DCMemoryGB').Value = '8'
Initialize-ALFGuestSizingPlan $plan
Assert ($plan.Values.Count -eq 10 -and ($plan.Values | Where-Object Key -eq 'DCMemoryGB').Value -eq '8' -and $plan.ClusterIdentifier -eq '3222') 'Repeated migration must not duplicate fields, change selected sizes or retarget names.'
Initialize-ALFNodeCountPlan $plan
$keys = @($plan.Values | ForEach-Object Key)
$countRow = $plan.Values | Where-Object Key -eq 'NodeCount'
Assert ($keys[$keys.IndexOf('NodeCount') + 1] -eq 'NodeVcpus' -and $countRow.Value -eq '2' -and $countRow.Group -eq '2. Host') 'Older plans gain a 2-node count in the host section, just before the node sizing rows.'
$countRow.Value = '4'
Initialize-ALFNodeCountPlan $plan
Assert ($plan.Values.Count -eq 11 -and ($plan.Values | Where-Object Key -eq 'NodeCount').Value -eq '4') 'Repeated migration keeps the chosen node count.'
$exampleRows = @((Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'LabValues.example.json') -Raw | ConvertFrom-Json).Values)
$exampleKeys = @($exampleRows | ForEach-Object Key)
$exampleCount = $exampleRows | Where-Object Key -eq 'NodeCount'
$migratedCount = Get-ALFNodeCountRow $exampleCount.Group
$sameFields = @('Label', 'Value', 'Example', 'Pattern', 'Description', 'Hint', 'UsedIn' | Where-Object { $exampleCount.$_ -cne $migratedCount.$_ }).Count -eq 0
Assert ($sameFields -and $exampleKeys[$exampleKeys.IndexOf('NodeCount') + 1] -eq 'NodeVcpus') 'New plans and migrated plans get the same node-count row before the node sizing rows.'

$script:HostInfo = [pscustomobject]@{NumberOfLogicalProcessors=20;TotalPhysicalMemory=([long](95.9 * 1GB))}
function Get-CimInstance { param($ClassName, $ErrorAction) return $script:HostInfo }
try {
    Assert-ALFGuestSizingHost $values $budget 3>$null
    Assert $true 'Allow normal OS/firmware accounting slightly below the nominal 96 GB.'
    $script:HostInfo.NumberOfLogicalProcessors = 16
    Assert-Throws { Assert-ALFGuestSizingHost $values $budget } 'Reject a real host exposing fewer CPUs than planned.'
    $lean = $values.Clone(); $lean.HostAvailableVcpus = '16'
    Assert-ALFGuestSizingHost $lean (Test-ALFLabSizing $lean) 3>$null
    Assert $true 'A 16-vCPU SuperHost planned for 16 vCPUs can create guests (with a warning).'
    $lean.HostAvailableVcpus = '12'; $script:HostInfo.NumberOfLogicalProcessors = 11
    Assert-Throws { Assert-ALFGuestSizingHost $lean (Test-ALFLabSizing $lean) } 'Reject a real host below the 12-vCPU lab minimum.'
    $script:HostInfo.NumberOfLogicalProcessors = 20; $script:HostInfo.TotalPhysicalMemory = 80GB
    Assert-Throws { Assert-ALFGuestSizingHost $values $budget } 'Reject a real host too small for the planned RAM and reserve before creating disks or VMs.'
    $script:HostInfo.NumberOfLogicalProcessors = 64; $script:HostInfo.TotalPhysicalMemory = 256GB
    Assert-ALFGuestSizingHost $custom $customBudget
    Assert $true 'A custom host matching declared capacity can create the planned guests.'
    $script:HostInfo.NumberOfLogicalProcessors = 32
    Assert-Throws { Assert-ALFGuestSizingHost $custom $customBudget } 'Manual on-premises sizing must not hide an undersized real host.'
} finally { Remove-Item function:Get-CimInstance }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'ALFLabBuilder.ps1'), [ref]$tokens, [ref]$errors)
$fn = $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-LabSizingStatus'}, $true)[0]
. ([scriptblock]::Create($fn.Extent.Text))
$items = @($values.GetEnumerator() | ForEach-Object {[pscustomobject]@{Key=$_.Key;Value=$_.Value;Status='';Hint=''}})
$ui = @{txtSizingSummary=[Windows.Controls.TextBlock]::new()}
$script:HostSkus = @(); $script:HostSkuContext = ''
Assert (Update-LabSizingStatus) 'Planning accepts the default budget even without Azure refresh.'
Assert ($ui.txtSizingSummary.Text -match '78 / 80' -and $ui.txtSizingSummary.Text -match '28 guest vCPUs / 20') 'Show RAM headroom and shared CPU allocations together.'
($items | Where-Object Key -eq 'HostAvailableVcpus').Value = '16'
Assert ((Update-LabSizingStatus) -and $ui.txtSizingSummary.Text -match 'below the recommended 20' -and ($items | Where-Object Key -eq 'HostAvailableVcpus').Status -eq '') 'Planning allows a 16-vCPU SuperHost and shows the performance warning.'
($items | Where-Object Key -eq 'HostAvailableVcpus').Value = '11'
Assert (-not (Update-LabSizingStatus) -and ($items | Where-Object Key -eq 'HostAvailableVcpus').Status -eq 'Invalid sizing') 'Planning flags a SuperHost below the 12-vCPU minimum.'
$cpuItem = $items | Where-Object Key -eq 'HostAvailableVcpus'; $cpuItem.Value = '20'; $cpuItem.Status = ''
$items += [pscustomobject]@{Key='NodeCount';Value='3';Status='';Hint=''}
Assert (-not (Update-LabSizingStatus) -and $ui.txtSizingSummary.Text -match '3 nodes' -and ($items | Where-Object Key -eq 'HostMemoryReserveGB').Status -eq 'Invalid sizing') 'Planning three nodes on the default SuperHost is flagged before rollout.'
($items | Where-Object Key -eq 'NodeCount').Value = '17'
Assert (-not (Update-LabSizingStatus) -and ($items | Where-Object Key -eq 'NodeCount').Status -eq 'Invalid sizing') 'An out-of-range node count marks its own row.'
($items | Where-Object Key -eq 'NodeCount').Value = '2'
Assert ((Update-LabSizingStatus) -and $ui.txtSizingSummary.Text -match '^2 nodes: 78 / 80' -and ($items | Where-Object Key -eq 'NodeCount').Status -eq 'OK') 'The summary names the planned node count.'
($items | Where-Object Key -eq 'NodeMemoryGB').Value = '72'
Assert (-not (Update-LabSizingStatus)) 'Planning reports insufficient RAM before command copying or rollout.'
Assert ($ui.txtSizingSummary.Text -match '^INVALID LAB SIZING:') 'Expose the actionable allocation failure in the live summary.'
($items | Where-Object Key -eq 'NodeVcpus').Value = ''
($items | Where-Object Key -eq 'DCMemoryGB').Value = ''
Update-LabSizingStatus | Out-Null
Assert (($items | Where-Object Key -eq 'NodeVcpus').Status -eq 'Invalid sizing' -and ($items | Where-Object Key -eq 'DCMemoryGB').Status -eq 'Invalid sizing') 'Several invalid input fields must not be shown as OK when the first validation failure is reported.'
Write-Output "PASS: $script:Passed guest-sizing checks; no provisioning."
