# Version: ALF Lab Builder 2.0.22
# SKU capabilities are scoped to the chosen subscription and region.
function Initialize-ALFHostSizingPlan($Plan) {
    $hostRow = $Plan.Values | Where-Object Key -eq 'HostVMName' | Select-Object -First 1
    if (-not $hostRow) { return }
    $rows = @()
    foreach ($row in $Plan.Values) {
        $rows += $row
        if ($row.Key -eq 'HostVMName') {
            foreach ($spec in @(@('HostVMSize', 'Host VM size (SKU)', 'Standard_D48als_v7', '^(Standard_[A-Za-z0-9_]+|Custom \(on-premises\))$'), @('HostAvailableVcpus', 'Available vCPUs (default 20)', '20', '^[1-9][0-9]*$'))) {
                if (-not ($Plan.Values | Where-Object Key -eq $spec[0])) {
                    $rows += [pscustomobject]@{ Key = $spec[0]; Group = $hostRow.Group; Label = $spec[1]; Value = $spec[2]; Description = 'Optional Refresh Azure sizes inspects regional support. Requests up to the known maximum pass locally; missing/unlisted reduced-count support warns without blocking. Base VM price is unchanged; quota is separate.'; Example = $spec[2]; Pattern = $spec[3]; Hint = 'Default D48als_v7 maximum: 48. Requested available vCPUs: 20, subject to Azure-supported counts.'; UsedIn = '00.Workstation-CreateHostVM.ps1, CliCreateHostVM'; DifferentFrom = ''; Type = ''; Command = ''; Private = $false }
                }
            }
        }
    }
    $Plan.Values = $rows
    $sizeRow = $Plan.Values | Where-Object Key -eq 'HostVMSize' | Select-Object -First 1
    $sizeRow.Pattern = '^(Standard_[A-Za-z0-9_]+|Custom \(on-premises\))$'
    $sizeAdded = $false
    $Plan.Values = @(
        foreach ($row in $rows) {
            if (-not $sizeAdded -and $row.Group -eq $sizeRow.Group) {
                $sizeRow
                $sizeAdded = $true
            }
            if ($row.Key -ne 'HostVMSize') { $row }
        }
    )
    $cli = $Plan.Values | Where-Object Key -eq 'CliCreateHostVM' | Select-Object -First 1
    if ($cli -and $cli.Command -notmatch 'HostVMSize') {
        $cli.Command = $cli.Command.Replace('--size Standard_D48als_v7', '--size "{{HostVMSize}}" --v-cpus-available {{HostAvailableVcpus}}')
    }
}

function Get-ALFHostSizeChoices([string]$SelectedSize, $Skus) {
    @('Standard_D48als_v7', 'Custom (on-premises)', $SelectedSize) + @($Skus | ForEach-Object { $_.name }) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
}

function Get-ALFHostSkus([string]$SubscriptionId, [string]$Location) {
    if ($SubscriptionId -notmatch '^[0-9a-fA-F-]{36}$' -or $Location -notmatch '^[a-z0-9]+$') { throw 'Enter a valid subscription ID and Azure region first.' }
    $output = & az vm list-skus --subscription $SubscriptionId --location $Location --resource-type virtualMachines --output json
    if ($LASTEXITCODE -ne 0) { throw 'Azure SKU query failed. Sign in with az login and check subscription access.' }
    $skus = $output -join "`n" | ConvertFrom-Json -ErrorAction Stop
    return @($skus | Where-Object {
        $_.name -match '^Standard_[A-Za-z0-9_]+$' -and
        -not @($_.restrictions | Where-Object type -eq 'Location').Count -and
        @($_.capabilities | Where-Object { $_.name -eq 'NestedVirtualization' -and $_.value -eq 'True' }).Count -and
        @($_.capabilities | Where-Object { $_.name -eq 'PremiumIO' -and $_.value -eq 'True' }).Count -and
        @($_.capabilities | Where-Object { $_.name -eq 'MemoryGB' -and [double]$_.value -ge 96 }).Count -and
        @($_.capabilities | Where-Object { $_.name -eq 'vCPUs' -and [int]$_.value -ge 20 }).Count -and
        @($_.capabilities | Where-Object { $_.name -eq 'MaxResourceVolumeMB' -and [double]$_.value -eq 0 }).Count
    } | Sort-Object name)
}

function Test-ALFHostSizing([string]$Size, [string]$AvailableVcpus, $Sku) {
    if ($Size -notmatch '^(Standard_[A-Za-z0-9_]+|Custom \(on-premises\))$') { throw 'Select a valid Standard VM size or Custom (on-premises).' }
    $count = 0
    if ($AvailableVcpus -notmatch '^[1-9][0-9]*$' -or -not [int]::TryParse($AvailableVcpus, [ref]$count)) {
        throw 'Available vCPUs must be a positive whole number.'
    }
    # Custom capacity is declared by the student, not constrained by an Azure SKU.
    if ($Size -eq 'Custom (on-premises)') { return $count }
    if ($Sku -and $Sku.name -cne $Size) { throw 'SKU metadata does not match the selected VM size.' }
    $maximum = 0
    if ($Sku) {
        $maximumText = [string]($Sku.capabilities | Where-Object name -eq 'vCPUs' | Select-Object -First 1).value
        if ($maximumText -and (-not [int]::TryParse($maximumText, [ref]$maximum) -or $maximum -le 0)) {
            throw 'Azure returned an invalid maximum vCPU count for this SKU.'
        }
    }
    # Only this documented default has an offline maximum; do not guess other SKU limits.
    if ($maximum -eq 0 -and $Size -ceq 'Standard_D48als_v7') { $maximum = 48 }
    if ($maximum -le 0) { throw 'Maximum vCPUs unknown for this size. Refresh Azure sizes to read its maximum.' }
    if ($count -gt $maximum) { throw "Available vCPUs cannot exceed this SKU's maximum ($maximum)." }
    return $maximum
}

function Get-ALFHostSizingWarning([string]$Size, [string]$AvailableVcpus, $Sku) {
    $maximum = Test-ALFHostSizing $Size $AvailableVcpus $Sku
    if ($Size -eq 'Custom (on-premises)') { return '' }
    if (-not $Sku -or -not ($Sku.capabilities | Where-Object name -eq 'vCPUs' | Select-Object -First 1).value) {
        return "Using the documented $maximum-vCPU maximum for $Size. Regional availability and reduced-core support are unverified; Azure will validate the $AvailableVcpus-vCPU request during creation."
    }
    if ([int]$AvailableVcpus -lt $maximum) {
        $allowedText = [string]($Sku.capabilities | Where-Object name -eq 'vCPUsConstraintsAllowed' | Select-Object -First 1).value
        if ([string]::IsNullOrWhiteSpace($allowedText)) {
            return "Azure metadata does not provide supported reduced counts for $Size. The $AvailableVcpus-vCPU request is allowed locally; Azure will validate it during creation."
        }
        $allowed = @([regex]::Matches($allowedText, '\d+') | ForEach-Object { $_.Value })
        if ($AvailableVcpus -notin $allowed) {
            return "Azure metadata does not explicitly list $AvailableVcpus for $Size (reported: $allowedText). The request is allowed locally but Azure may reject it during creation."
        }
    }
    return ''
}
