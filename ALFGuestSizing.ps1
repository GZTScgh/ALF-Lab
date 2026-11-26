# Version: ALF Lab Builder 2.1.1
# Shared planning and creation checks for the four nested guests.
function Get-ALFGuestSizingFields {
    @(
        @{ Key='HostMemoryGB'; Label='SuperHost RAM (GB, minimum 96)'; Default='96'; Minimum=96; Detail='Enter the SuperHost RAM available to this lab. Custom (on-premises) uses your manually entered capacity; Azure sizes must match known SKU memory. Actual host capacity is checked before guest creation.' }
        @{ Key='HostMemoryReserveGB'; Label='Reserve RAM for SuperHost (GB)'; Default='16'; Minimum=1; Detail='RAM kept for the SuperHost OS and Hyper-V, not assigned to guests. Default 16 GB. Guest RAM plus this reserve must fit the host.' }
        @{ Key='DCVcpus'; Label='DC vCPUs (minimum 2)'; Default='2'; Minimum=2; Detail='Processors for ContosoDC1. Minimum 2. CPU is shared across VMs; this is not a dedicated CPU reservation.' }
        @{ Key='DCMemoryGB'; Label='DC RAM (GB, minimum 2)'; Default='2'; Minimum=2; Detail='Static RAM for ContosoDC1. Minimum 2 GB. Increase if the lab has spare memory.' }
        @{ Key='AdminVcpus'; Label='Admin station vCPUs (minimum 2)'; Default='2'; Minimum=2; Detail='Processors for the planned admin station. Minimum 2. CPU is shared across VMs.' }
        @{ Key='AdminMemoryGB'; Label='Admin station RAM (GB, minimum 4)'; Default='4'; Minimum=4; Detail='Static RAM for the planned admin station. Minimum 4 GB.' }
        @{ Key='NodeVcpus'; Label='Each Azure Local node vCPUs (min 12)'; Default='12'; Minimum=12; Detail='Processors assigned equally to each node. Minimum 12 per node. The plan budgets the Number of Azure Local nodes above (default 2); Host Console step 9 can change it (2-16) and checks the host for that many before creating VMs.' }
        @{ Key='NodeMemoryGB'; Label='Each Azure Local node RAM (GB, min 36)'; Default='36'; Minimum=36; Detail='Static RAM assigned equally to each node. Minimum 36 GB each. The plan budgets this value once per node in the Number of Azure Local nodes above (default 2); Host Console step 9 can change it (2-16) and stops before creating VMs if the host RAM cannot hold that many.' }
    )
}

function Get-ALFNodeCountRow([string]$Group) {
    [pscustomobject]@{
        Key='NodeCount'; Group=$Group; Label='Number of Azure Local nodes (2-16)'; Value='2'
        Description='How many Azure Local node VMs the lab plans for (2 to 16, default 2). The SuperHost RAM and vCPU budget counts each node''s RAM and vCPUs this many times, so memory is planned before the SuperHost is built. Names after NodeName2 are suggested by continuing the numbering (for example AzL2101Node3), and the node IP range must hold one address per node. Host Console step 9 starts with this many nodes and can still change it.'
        Example='2'; Pattern='^([2-9]|1[0-6])$'
        Hint='2 to 16. Budgets node RAM/vCPU on the SuperHost; Host Console step 9 can still change it.'
        UsedIn='ALFGuestSizing.ps1, 00, 04dc, 04adm, 10, 11, ALFHostConsole.ps1'
        DifferentFrom=''; Type=''; Command=''; Private=$false
    }
}

#Adds the node-count row to plans saved before 2.1.1 (before the node sizing rows).
function Initialize-ALFNodeCountPlan($Plan) {
    if ($Plan.Values | Where-Object Key -eq 'NodeCount') { return }
    $anchor = $Plan.Values | Where-Object Key -eq 'NodeVcpus' | Select-Object -First 1
    $after = $false
    if (-not $anchor) {
        $anchor = $Plan.Values | Where-Object Key -eq 'HostAvailableVcpus' | Select-Object -First 1
        $after = $true
    }
    $group = if ($anchor) { $anchor.Group } else { '' }
    $row = Get-ALFNodeCountRow $group
    $rows = @()
    foreach ($existing in $Plan.Values) {
        if ($anchor -and -not $after -and $existing.Key -eq $anchor.Key) { $rows += $row }
        $rows += $existing
        if ($anchor -and $after -and $existing.Key -eq $anchor.Key) { $rows += $row }
    }
    if (-not $anchor) { $rows += $row }
    $Plan.Values = $rows
}

function Initialize-ALFGuestSizingPlan($Plan) {
    $anchor = $Plan.Values | Where-Object Key -eq 'HostAvailableVcpus' | Select-Object -First 1
    if (-not $anchor) { return }
    $rows = @()
    foreach ($row in $Plan.Values) {
        $rows += $row
        if ($row.Key -eq $anchor.Key) {
            foreach ($field in Get-ALFGuestSizingFields) {
                if (-not ($Plan.Values | Where-Object Key -eq $field.Key)) {
                    $rows += [pscustomobject]@{
                        Key=$field.Key; Group=$anchor.Group; Label=$field.Label; Value=$field.Default
                        Description=$field.Detail; Example=$field.Default; Pattern='^[1-9][0-9]*$'
                        Hint=$field.Detail; UsedIn='ALFGuestSizing.ps1, 00, 04dc, 04adm, 10'
                        DifferentFrom=''; Type=''; Command=''; Private=$false
                    }
                }
            }
        }
    }
    $Plan.Values = $rows
}

#NodeCount is the number of Azure Local nodes (2-16). Without -NodeCount the plan's NodeCount value
#is used (2 if the plan has none); script 10 passes the count actually chosen in Host Console step 9.
function Test-ALFLabSizing($Values, $Sku, [int]$NodeCount = 2) {
    if (-not $PSBoundParameters.ContainsKey('NodeCount') -and $Values -and "$($Values['NodeCount'])" -ne '') {
        $plannedCount = [string]$Values['NodeCount']
        if ($plannedCount -notmatch '^([2-9]|1[0-6])$') {
            $exception = [ArgumentException]::new("Number of Azure Local nodes must be a whole number from 2 to 16, not '$plannedCount'.")
            $exception.Data['Field'] = 'NodeCount'
            throw $exception
        }
        $NodeCount = [int]$plannedCount
    }
    if ($NodeCount -lt 2 -or $NodeCount -gt 16) { throw "The lab needs 2 to 16 Azure Local nodes, not $NodeCount." }
    $numbers = @{}
    #12 is the floor (a node needs 12 vCPUs); 20 is recommended, and 12-19 only warns.
    $fields = @(@{Key='HostAvailableVcpus'; Label='SuperHost available vCPUs'; Minimum=12}) + @(Get-ALFGuestSizingFields)
    foreach ($field in $fields) {
        $text = [string]$Values[$field.Key]
        $number = 0
        if ($text -notmatch '^[1-9][0-9]*$' -or -not [int]::TryParse($text, [ref]$number) -or $number -lt $field.Minimum) {
            $exception = [ArgumentException]::new("$($field.Label) must be a whole number of at least $($field.Minimum).")
            $exception.Data['Field'] = $field.Key
            throw $exception
        }
        $numbers[$field.Key] = $number
    }
    $onPremises = $Values['HostVMSize'] -eq 'Custom (on-premises)'
    if ($onPremises) { $Sku = $null }
    if ($Sku -and $Sku.name -cne $Values['HostVMSize']) { throw 'SKU metadata does not match the planned SuperHost size.' }
    $memoryText = if ($Sku) { [string]($Sku.capabilities | Where-Object name -eq 'MemoryGB' | Select-Object -First 1).value } else { '' }
    [decimal]$knownMemory = 0
    if ($memoryText) {
        if (-not [decimal]::TryParse($memoryText, [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$knownMemory) -or $knownMemory -le 0) {
            throw 'Azure returned invalid RAM metadata for the selected SKU.'
        }
    }
    elseif ($Values['HostVMSize'] -ceq 'Standard_D48als_v7') { $knownMemory = 96 }
    if ($knownMemory -gt 0 -and $numbers.HostMemoryGB -ne $knownMemory) {
        $exception = [ArgumentException]::new("$($Values['HostVMSize']) has $knownMemory GB RAM, not $($numbers.HostMemoryGB). Choose a larger SKU or correct SuperHost RAM; the RAM field cannot resize an Azure SKU.")
        $exception.Data['Field'] = 'HostMemoryGB'
        throw $exception
    }
    foreach ($key in 'DCVcpus','AdminVcpus','NodeVcpus') {
        if ($numbers[$key] -gt $numbers.HostAvailableVcpus) {
            $exception = [ArgumentException]::new("$key cannot exceed the SuperHost's $($numbers.HostAvailableVcpus) available vCPUs. Increase the host CPU setting or lower this guest allocation.")
            $exception.Data['Field'] = $key
            throw $exception
        }
    }
    [long]$guestMemory = [long]$numbers.DCMemoryGB + $numbers.AdminMemoryGB + [long]$NodeCount * $numbers.NodeMemoryGB
    [long]$memoryBudget = [long]$numbers.HostMemoryGB - $numbers.HostMemoryReserveGB
    if ($guestMemory -gt $memoryBudget) {
        $fewer = if ($NodeCount -gt 2) { ', or plan fewer nodes (Planning Console Number of Azure Local nodes, or Host Console step 9)' } else { '' }
        $exception = [ArgumentException]::new("Guests ($NodeCount nodes, DC and admin station) need $guestMemory GB RAM; only $memoryBudget GB is allocatable after the $($numbers.HostMemoryReserveGB)-GB SuperHost reserve. Increase host RAM/choose a matching larger SKU, or reduce guest allocations within their minimums$fewer.")
        $exception.Data['Field'] = 'HostMemoryReserveGB'
        throw $exception
    }
    [long]$guestCpus = [long]$numbers.DCVcpus + $numbers.AdminVcpus + [long]$NodeCount * $numbers.NodeVcpus
    $warning = if ($numbers.HostAvailableVcpus -lt 20) {
        "$($numbers.HostAvailableVcpus) SuperHost vCPUs is below the recommended 20 (minimum 12). The lab can run for testing, but expect slower deployment, updates and validation."
    } else { '' }
    if ($guestCpus -gt $numbers.HostAvailableVcpus) {
        $warning += " $guestCpus guest vCPUs share $($numbers.HostAvailableVcpus) SuperHost vCPUs. This lab uses CPU overcommit; concurrent CPU-heavy workloads may compete. Guest allocations do not increase the host's available CPU count."
    }
    if ($knownMemory -eq 0 -and -not $onPremises) { $warning += ' Selected SKU RAM is unverified; the budget uses your declared SuperHost RAM. Actual host capacity is checked before guest creation.' }
    return [pscustomobject]@{
        GuestMemoryGB=$guestMemory; AllocatableMemoryGB=$memoryBudget
        RemainingHostMemoryGB=([long]$numbers.HostMemoryGB - $guestMemory)
        HostReserveGB=$numbers.HostMemoryReserveGB; GuestVcpus=$guestCpus
        HostVcpus=$numbers.HostAvailableVcpus; NodeCount=$NodeCount; Warning=$warning.Trim()
    }
}

function Get-ALFPlannedGuestSizing {
    $values = @{
        HostVMSize='{{HostVMSize}}'; HostAvailableVcpus='{{HostAvailableVcpus}}'
        HostMemoryGB='{{HostMemoryGB}}'; HostMemoryReserveGB='{{HostMemoryReserveGB}}'
        DCVcpus='{{DCVcpus}}'; DCMemoryGB='{{DCMemoryGB}}'
        AdminVcpus='{{AdminVcpus}}'; AdminMemoryGB='{{AdminMemoryGB}}'
        NodeVcpus='{{NodeVcpus}}'; NodeMemoryGB='{{NodeMemoryGB}}'; NodeCount='{{NodeCount}}'
    }
    if (@($values.Values | Where-Object { $_ -match '\{\{' }).Count) {
        throw 'Guest sizing has unfilled placeholders. Save planning values and roll out the complete release before creating VMs.'
    }
    return $values
}

function Assert-ALFGuestSizingHost($Values, $Budget) {
    $hostInfo = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $actualCpus = [int]$hostInfo.NumberOfLogicalProcessors
    $actualMemoryGB = $hostInfo.TotalPhysicalMemory / 1GB
    if ($actualCpus -lt 12 -or $actualCpus -lt [int]$Values.HostAvailableVcpus) {
        throw "This SuperHost exposes $actualCpus vCPUs, fewer than the planned $($Values.HostAvailableVcpus) (lab minimum 12, recommended 20). Correct the host sizing before creating guests."
    }
    # Firmware/OS accounting can report slightly less than the installed memory.
    if ([math]::Ceiling($actualMemoryGB) -lt [int]$Values.HostMemoryGB -or $Budget.GuestMemoryGB + $Budget.HostReserveGB -gt $actualMemoryGB) {
        throw "This SuperHost reports $([math]::Round($actualMemoryGB,2)) GB RAM; the plan declares $($Values.HostMemoryGB) GB and requires $($Budget.GuestMemoryGB + $Budget.HostReserveGB) GB including reserve. Correct the plan or use a larger host before creating guests."
    }
    Write-Host "  Sizing plan: $($Budget.GuestMemoryGB) GB guest RAM, $($Budget.RemainingHostMemoryGB) GB left for the host; $($Budget.GuestVcpus) shared guest vCPUs." -ForegroundColor Cyan
    if ($Budget.Warning) { Write-Warning $Budget.Warning -WarningAction Continue }
}
