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
    [CmdletBinding()]
    param($ClassName, $Namespace)
    switch ($ClassName) {
        'Win32_Processor' { $script:Cpu }
        'Win32_DeviceGuard' { [pscustomobject]@{ VirtualizationBasedSecurityStatus = 0 } }
        default { [pscustomobject]@{ NumberOfLogicalProcessors = 20; TotalPhysicalMemory = 96GB } }
    }
}
function Get-Service {
    [CmdletBinding()]
    param($Name)
    if ($script:HyperVService) { [pscustomobject]@{ Name = $Name } }
}
function Read-Host {
    param($Prompt)
    $script:Prompts.Add([string]$Prompt)
    $script:Answer
}
$capableCpu = [pscustomobject]@{ VMMonitorModeExtensions = $true; SecondLevelAddressTranslationExtensions = $true; VirtualizationFirmwareEnabled = $true }
$noNestedCpu = [pscustomobject]@{ VMMonitorModeExtensions = $false; SecondLevelAddressTranslationExtensions = $false; VirtualizationFirmwareEnabled = $false }
$script:HyperVService = $false
$script:Prompts = [Collections.Generic.List[string]]::new()
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
# Test a filled-in copy of the template (Rollout\ is local-only) next to its shared helpers. Dot-source it so the mocks keep this script's $script: state.
$hostFolder = Join-Path ([IO.Path]::GetTempPath()) ('ALF-HostTimeZone-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($hostFolder)
$hostScript = Join-Path $hostFolder '01.Host-PrepareDataDisk.ps1'
$hostText = (Get-Content -LiteralPath (Join-Path $root '01.Host-PrepareDataDisk.ps1') -Raw).Replace('{{TimeZone}}', 'Manitoba Standard Time')
[IO.File]::WriteAllText($hostScript, $hostText, [Text.UTF8Encoding]::new($true))
Copy-Item -LiteralPath (Join-Path $root 'ALFNodeSettings.ps1') -Destination $hostFolder
function Reset-HostRun {
    $script:CreatedFolders = [Collections.Generic.List[string]]::new()
    $script:Messages.Clear(); $script:SetCalls.Clear(); $script:Prompts.Clear(); $script:CurrentZone = 'UTC'
    $script:DiskFails = $false; $script:Cpu = $capableCpu; $script:HyperVService = $false; $script:Answer = ''
}
try {
    foreach ($failure in 'Set', 'Lookup', 'MissingFallback') {
        Reset-HostRun
        $script:LookupFails = $failure -eq 'Lookup'; $script:SetFails = $failure -eq 'Set'
        $script:Zones = if ($failure -eq 'MissingFallback') { @('UTC') } else { @('Eastern Standard Time') }
        . $hostScript -DiskOnly | Out-Null
        Assert ($script:CreatedFolders -contains 'C:\ISO' -and $script:CreatedFolders -contains 'F:\VMs') 'Host step 1 must continue to prepare folders after an optional time-zone failure.'
        Assert (@($script:Messages | Where-Object { $_ -match 'Data disk ready' }).Count -eq 1) 'The actual -DiskOnly entry point must finish after a time-zone failure.'
        Assert (@($script:Messages | Where-Object { $_ -match 'Optional time-zone change skipped|Manitoba Standard Time.*unavailable' }).Count -ge 1) 'Host step 1 must reach the optional time-zone handler.'
        Assert (@($script:Messages | Where-Object { $_ -match '^\s*This VM can run Hyper-V \(nested' }).Count -eq 1 -and $script:Prompts.Count -eq 0) 'A VM that can run Hyper-V passes the check without a question.'
    }
    $script:LookupFails = $false; $script:SetFails = $false; $script:Zones = @('Eastern Standard Time')
    Reset-HostRun
    $script:Cpu = $noNestedCpu; $script:Answer = 'no'
    $stopped = $false
    try { . $hostScript -DiskOnly | Out-Null }
    catch { $stopped = $_.Exception.Message -match "Stopped: this VM can't run Hyper-V.*step 1" }
    Assert $stopped 'A VM size without nested virtualization stops step 1 unless you type YES.'
    Assert ($script:Prompts.Count -eq 1 -and $script:CreatedFolders.Count -eq 0) 'Step 1 asks once and builds nothing when stopped.'
    Assert (@($script:Messages | Where-Object { $_ -match 'Resize the Azure VM.*Refresh Azure sizes' }).Count -eq 1) 'Explain how to fix a VM size without nested virtualization.'
    Reset-HostRun
    $script:Cpu = $noNestedCpu; $script:Answer = ' yes '
    . $hostScript -DiskOnly | Out-Null
    Assert ($script:CreatedFolders -contains 'C:\ISO' -and @($script:Messages | Where-Object { $_ -match 'Data disk ready' }).Count -eq 1) 'Typing YES continues step 1.'
    Assert (@($script:Messages | Where-Object { $_ -match 'Continuing anyway' }).Count -eq 1) 'Continuing anyway is called out.'
    Reset-HostRun
    $script:Cpu = $noNestedCpu; $script:HyperVService = $true
    . $hostScript -DiskOnly | Out-Null
    Assert ($script:Prompts.Count -eq 0 -and $script:CreatedFolders -contains 'C:\ISO') 'An installed Hyper-V hides the CPU settings but proves the VM can run it.'
    Reset-HostRun
    $script:DiskFails = $true
    $diskFailed = $false
    try { . $hostScript -DiskOnly | Out-Null }
    catch { $diskFailed = $_.Exception.Message -eq 'Simulated disk failure' }
    Assert $diskFailed 'Real disk-preparation failures must still fail host step 1.'
}
finally { Remove-Item -LiteralPath $hostFolder -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output "PASS: $script:Passed host/guest time-zone checks; all three guest roles and host -DiskOnly, no system changes."
