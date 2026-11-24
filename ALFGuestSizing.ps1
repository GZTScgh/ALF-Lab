# Version: ALF Lab Builder 2.0.23
# Shared planning and creation checks for the four nested guests.
function Get-ALFGuestSizingFields {
    @(
        @{ Key='HostMemoryGB'; Label='SuperHost RAM (GB, minimum 96)'; Default='96'; Minimum=96; Detail='Enter the SuperHost RAM available to this lab. Custom (on-premises) uses your manually entered capacity; Azure sizes must match known SKU memory. Actual host capacity is checked before guest creation.' }
        @{ Key='HostMemoryReserveGB'; Label='Reserve RAM for SuperHost (GB)'; Default='16'; Minimum=1; Detail='RAM kept for the SuperHost OS and Hyper-V, not assigned to guests. Default 16 GB. Guest RAM plus this reserve must fit the host.' }
        @{ Key='DCVcpus'; Label='DC vCPUs (minimum 2)'; Default='2'; Minimum=2; Detail='Processors for ContosoDC1. Minimum 2. CPU is shared across VMs; this is not a dedicated CPU reservation.' }
        @{ Key='DCMemoryGB'; Label='DC RAM (GB, minimum 2)'; Default='2'; Minimum=2; Detail='Static RAM for ContosoDC1. Minimum 2 GB. Increase if the lab has spare memory.' }
        @{ Key='AdminVcpus'; Label='Admin station vCPUs (minimum 2)'; Default='2'; Minimum=2; Detail='Processors for the planned admin station. Minimum 2. CPU is shared across VMs.' }
        @{ Key='AdminMemoryGB'; Label='Admin station RAM (GB, minimum 4)'; Default='4'; Minimum=4; Detail='Static RAM for the planned admin station. Minimum 4 GB.' }
        @{ Key='NodeVcpus'; Label='Each Azure Local node vCPUs (min 12)'; Default='12'; Minimum=12; Detail='Processors assigned equally to each of the two nodes. Minimum 12 per node. Host step 9 name overrides do not change this sizing.' }
        @{ Key='NodeMemoryGB'; Label='Each Azure Local node RAM (GB, min 36)'; Default='36'; Minimum=36; Detail='Static RAM assigned equally to each of the two nodes. Minimum 36 GB each; the RAM budget counts this value twice.' }
    )
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

function Test-ALFLabSizing($Values, $Sku) {
    $numbers = @{}
    $fields = @(@{Key='HostAvailableVcpus'; Label='SuperHost available vCPUs'; Minimum=20}) + @(Get-ALFGuestSizingFields)
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
    [long]$guestMemory = [long]$numbers.DCMemoryGB + $numbers.AdminMemoryGB + 2L * $numbers.NodeMemoryGB
    [long]$memoryBudget = [long]$numbers.HostMemoryGB - $numbers.HostMemoryReserveGB
    if ($guestMemory -gt $memoryBudget) {
        $exception = [ArgumentException]::new("Guests need $guestMemory GB RAM; only $memoryBudget GB is allocatable after the $($numbers.HostMemoryReserveGB)-GB SuperHost reserve. Increase host RAM/choose a matching larger SKU, or reduce guest allocations within their minimums.")
        $exception.Data['Field'] = 'HostMemoryReserveGB'
        throw $exception
    }
    [long]$guestCpus = [long]$numbers.DCVcpus + $numbers.AdminVcpus + 2L * $numbers.NodeVcpus
    $warning = if ($guestCpus -gt $numbers.HostAvailableVcpus) {
        "$guestCpus guest vCPUs share $($numbers.HostAvailableVcpus) SuperHost vCPUs. This lab uses CPU overcommit; concurrent CPU-heavy workloads may compete. Guest allocations do not increase the host's available CPU count."
    } else { '' }
    if ($knownMemory -eq 0 -and -not $onPremises) { $warning += ' Selected SKU RAM is unverified; the budget uses your declared SuperHost RAM. Actual host capacity is checked before guest creation.' }
    return [pscustomobject]@{
        GuestMemoryGB=$guestMemory; AllocatableMemoryGB=$memoryBudget
        RemainingHostMemoryGB=([long]$numbers.HostMemoryGB - $guestMemory)
        HostReserveGB=$numbers.HostMemoryReserveGB; GuestVcpus=$guestCpus
        HostVcpus=$numbers.HostAvailableVcpus; Warning=$warning.Trim()
    }
}

function Get-ALFPlannedGuestSizing {
    $values = @{
        HostVMSize='{{HostVMSize}}'; HostAvailableVcpus='{{HostAvailableVcpus}}'
        HostMemoryGB='{{HostMemoryGB}}'; HostMemoryReserveGB='{{HostMemoryReserveGB}}'
        DCVcpus='{{DCVcpus}}'; DCMemoryGB='{{DCMemoryGB}}'
        AdminVcpus='{{AdminVcpus}}'; AdminMemoryGB='{{AdminMemoryGB}}'
        NodeVcpus='{{NodeVcpus}}'; NodeMemoryGB='{{NodeMemoryGB}}'
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
    if ($actualCpus -lt 20 -or $actualCpus -lt [int]$Values.HostAvailableVcpus) {
        throw "This SuperHost exposes $actualCpus vCPUs, fewer than the planned $($Values.HostAvailableVcpus) (lab minimum 20). Correct the host sizing before creating guests."
    }
    # Firmware/OS accounting can report slightly less than the installed memory.
    if ([math]::Ceiling($actualMemoryGB) -lt [int]$Values.HostMemoryGB -or $Budget.GuestMemoryGB + $Budget.HostReserveGB -gt $actualMemoryGB) {
        throw "This SuperHost reports $([math]::Round($actualMemoryGB,2)) GB RAM; the plan declares $($Values.HostMemoryGB) GB and requires $($Budget.GuestMemoryGB + $Budget.HostReserveGB) GB including reserve. Correct the plan or use a larger host before creating guests."
    }
    Write-Host "  Sizing plan: $($Budget.GuestMemoryGB) GB guest RAM, $($Budget.RemainingHostMemoryGB) GB left for the host; $($Budget.GuestVcpus) shared guest vCPUs." -ForegroundColor Cyan
    if ($Budget.Warning) { Write-Warning $Budget.Warning -WarningAction Continue }
}
