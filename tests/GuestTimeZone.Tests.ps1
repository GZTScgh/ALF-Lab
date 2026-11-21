# Run in an approved PowerShell session. Time-zone/storage commands are mocked; guest configuration never runs.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:Passed = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:Passed++
}
function Get-TimeZone {
    [CmdletBinding()]
    param([switch]$ListAvailable)
    if ($script:LookupFails) { throw 'Simulated time-zone lookup failure' }
    if (-not $ListAvailable -and $script:CurrentLookupFails) { throw 'Simulated current-zone lookup failure' }
    if ($ListAvailable) { $script:Zones | ForEach-Object { [pscustomobject]@{ Id = $_ } } }
    else { [pscustomobject]@{ Id = $script:CurrentZone } }
}
function Set-TimeZone {
    [CmdletBinding()]
    param([string]$Id)
    $script:SetCalls.Add($Id)
    if ($script:SetFails) { throw 'Simulated access denied' }
    $script:CurrentZone = $Id
}
function Write-Host {
    param($Object, $ForegroundColor)
    $script:Messages.Add([string]$Object)
}
foreach ($handler in @(
    @{ File = '01.Host-PrepareDataDisk.ps1'; Function = 'Set-ALFOptionalHostTimeZone' },
    @{ File = '06dc.DC-SetNameAndIP.ps1'; Function = 'Set-ALFOptionalGuestTimeZone' },
    @{ File = '08adm.Admin-Configure.ps1'; Function = 'Set-ALFOptionalGuestTimeZone' },
    @{ File = '12.Node-Configure.ps1'; Function = 'Set-ALFOptionalGuestTimeZone' }
)) {
    $name = $handler.File
    $functionName = $handler.Function
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $name), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Syntax errors in $name" }
    $fn = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $functionName }, $true) | Select-Object -First 1
    if (-not $fn) { throw "Missing optional handler in $name" }
    . ([scriptblock]::Create($fn.Extent.Text))
    $script:SetCalls = [Collections.Generic.List[string]]::new()
    $script:Messages = [Collections.Generic.List[string]]::new()
    $script:LookupFails = $false; $script:CurrentLookupFails = $false; $script:SetFails = $false
    $script:Zones = @('Manitoba Standard Time', 'Eastern Standard Time', 'Pacific Standard Time')
    $script:CurrentZone = 'UTC'
    & $functionName 'Manitoba Standard Time'
    Assert ($script:CurrentZone -eq 'Manitoba Standard Time') 'Use requested Manitoba ID when it exists.'
    & $functionName 'Pacific Standard Time'
    Assert ($script:CurrentZone -eq 'Pacific Standard Time') 'Other available IDs must not be replaced by Eastern.'
    $script:Zones = @('Eastern Standard Time'); $script:CurrentZone = 'UTC'; $script:SetCalls.Clear()
    & $functionName 'Manitoba Standard Time'
    Assert ($script:CurrentZone -eq 'Eastern Standard Time' -and $script:SetCalls.Count -eq 1) 'Missing Manitoba must fall back to Eastern.'
    $script:SetCalls.Clear()
    & $functionName 'Manitoba Standard Time'
    Assert ($script:SetCalls.Count -eq 0) 'Already-selected Eastern fallback must not be changed again.'
    $script:CurrentZone = 'UTC'; $script:Messages.Clear()
    & $functionName 'Nonexistent Other Zone'
    Assert ($script:CurrentZone -eq 'Eastern Standard Time' -and $script:SetCalls.Count -eq 1) 'Any other unavailable ID must also fall back to Eastern.'
    Assert (@($script:Messages | Where-Object { $_ -match 'Nonexistent Other Zone.*Eastern Standard Time' }).Count -eq 1) 'Explain which unavailable ID triggered the fallback.'
    $script:Zones = @('UTC'); $script:CurrentZone = 'UTC'; $script:SetCalls.Clear()
    & $functionName 'Manitoba Standard Time'
    Assert ($script:CurrentZone -eq 'UTC' -and $script:SetCalls.Count -eq 0) 'Missing Manitoba and Eastern must leave the current zone and continue.'
    & $functionName 'Nonexistent Other Zone'
    Assert ($script:SetCalls.Count -eq 0) 'An unavailable fallback must not be applied.'
    $script:Zones = @('Eastern Standard Time'); $script:SetFails = $true
    & $functionName 'Eastern Standard Time'
    Assert ($script:CurrentZone -eq 'UTC') 'Set-TimeZone failure must not escape the optional handler.'
    $script:Messages.Clear()
    & $functionName 'Nonexistent Other Zone'
    Assert ($script:CurrentZone -eq 'UTC' -and @($script:Messages | Where-Object { $_ -match 'Simulated access denied.*configuration will continue' }).Count -eq 1) 'A failed Eastern fallback must warn and continue.'
    $script:SetFails = $false; $script:CurrentLookupFails = $true; $script:SetCalls.Clear()
    & $functionName 'Eastern Standard Time'
    Assert ($script:SetCalls.Count -eq 0) 'Current-zone lookup failures must not escape the optional handler.'
    $script:CurrentLookupFails = $false
    $script:LookupFails = $true; $script:SetCalls.Clear()
    & $functionName 'Eastern Standard Time'
    Assert ($script:SetCalls.Count -eq 0) 'Lookup failures must not stop configuration.'
    foreach ($empty in '', ' ', '{{TimeZone}}', '<TimeZone>') {
        & $functionName $empty
        Assert ($script:SetCalls.Count -eq 0) 'Blank/unfilled optional values must skip without trying to set a zone.'
    }
}

function Get-CimInstance {
    param($ClassName)
    [pscustomobject]@{ NumberOfLogicalProcessors = 20; TotalPhysicalMemory = 96GB }
}
function New-Item {
    param($Path, $ItemType, [switch]$Force)
    $script:CreatedFolders.Add($Path)
}
function Get-Disk {
    if ($script:DiskFails) { throw 'Simulated disk failure' }
    [pscustomobject]@{ Number = 1; FriendlyName = 'LabData'; Size = 1TB; PartitionStyle = 'GPT'; OperationalStatus = 'Online'; BusType = 'SCSI' }
}
function Get-Volume {
    [CmdletBinding()]
    param($DriveLetter)
    [pscustomobject]@{ DriveLetter = $DriveLetter }
}
$hostScript = Join-Path $root 'Rollout\01.Host-PrepareDataDisk.ps1'
foreach ($failure in 'Set', 'Lookup', 'MissingFallback') {
    $script:CreatedFolders = [Collections.Generic.List[string]]::new()
    $script:Messages.Clear(); $script:SetCalls.Clear(); $script:CurrentZone = 'UTC'
    $script:LookupFails = $failure -eq 'Lookup'; $script:SetFails = $failure -eq 'Set'
    $script:DiskFails = $false
    $script:Zones = if ($failure -eq 'MissingFallback') { @('UTC') } else { @('Eastern Standard Time') }
    & $hostScript -DiskOnly | Out-Null
    Assert ($script:CreatedFolders -contains 'C:\ISO' -and $script:CreatedFolders -contains 'F:\VMs') 'Host step 1 must continue to prepare folders after an optional time-zone failure.'
    Assert (@($script:Messages | Where-Object { $_ -match 'Data disk ready' }).Count -eq 1) 'The actual -DiskOnly entry point must finish after a time-zone failure.'
}
$script:DiskFails = $true
$diskFailed = $false
try { & $hostScript -DiskOnly | Out-Null }
catch { $diskFailed = $_.Exception.Message -eq 'Simulated disk failure' }
Assert $diskFailed 'Real disk-preparation failures must still fail host step 1.'
Write-Output "PASS: $script:Passed host/guest time-zone checks; all three guest roles and host -DiskOnly, no system changes."
