# Version: ALF Lab Builder 2.1.1
# Shared host-only node selection, Azure Local image and Hyper-V capability helpers; never edits the Planning Console plan.

#The Azure Local image release is the YYMM number from the Planning Console (2608 = the August 2026 release).
function Test-ALFAzureLocalImageRelease([string]$Release) {
    if ($Release -match '\{\{') { throw 'The Azure Local image release is still a placeholder ({{...}}). Choose it in the Planning Console (4. Azure Local cluster) and use Roll out scripts.' }
    if ($Release -notmatch '^2[6-9](0[1-9]|1[0-2])$') { throw "Azure Local image release '$Release' is not valid. Use the YYMM release number, for example 2608. The Planning Console lists 2601-2611." }
}

#Returns the ISO to use: the planned file name if it exists, otherwise an ISO already in the same folder
#that Microsoft named for the same release (for example AzureLocal24H2.26100.32230.LCM.12.2608.0.3020.x64.en-us.iso).
function Resolve-ALFAzureLocalIso([string]$Default, [string]$Release) {
    if (Test-Path -LiteralPath $Default -PathType Leaf) { return $Default }
    $folder = Split-Path -Path $Default -Parent
    if ($folder -and $Release -match '^[0-9]{4}$' -and (Test-Path -LiteralPath $folder -PathType Container)) {
        $match = Get-ChildItem -LiteralPath $folder -Filter 'AzureLocal*.iso' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*.LCM.12.$Release.*" } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($match) { return $match.FullName }
    }
    return $Default
}

#Picks Microsoft's file name for the release ISO from a download's Content-Disposition header or the last
#part of its final link. $null when neither is an Azure Local ISO for that release (an unpublished
#release ends at a web page) or the name isn't a plain file name.
function Get-ALFAzureLocalIsoFileName([string]$Uri, [string]$ContentDisposition, [string]$Release) {
    if ($Release -notmatch '^[0-9]{4}$') { return $null }
    $names = @()
    if ($ContentDisposition -match 'filename\*?\s*=\s*(?:UTF-8''[^'']*'')?"?([^";]+)"?') { $names += $Matches[1].Trim() }
    if ($Uri) { try { $names += ([Uri]$Uri).Segments[-1] } catch { } }
    foreach ($name in $names) {
        try { $name = [Uri]::UnescapeDataString($name) } catch { continue }
        if ($name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { continue }
        if ($name -like 'AzureLocal*.iso' -and $name -like "*.LCM.12.$Release.*") { return $name }
    }
    return $null
}

#The path to download the release ISO to, keeping Microsoft's file name
#(for example C:\ISO\AzureLocal24H2.26100.32230.LCM.12.2609.0.3009.x64.en-us.iso).
#LEARN: A HEAD request follows the aka.ms redirect and reads only the headers, not the ISO itself.
#       If the link can't be reached or doesn't end at that release's ISO, $Default is used.
function Get-ALFAzureLocalIsoPath([string]$Default, [string]$Url, [string]$Release, [int]$TimeoutSeconds = 15) {
    if ($Url -notmatch '^https://') { return $Default }
    $response = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $request = [Net.WebRequest]::Create($Url)
        $request.Method = 'HEAD'
        $request.AllowAutoRedirect = $true
        $request.Timeout = $TimeoutSeconds * 1000
        $response = $request.GetResponse()
        $name = Get-ALFAzureLocalIsoFileName $response.ResponseUri.AbsoluteUri $response.Headers['Content-Disposition'] $Release
        if ($name) { return Join-Path (Split-Path -Path $Default -Parent) $name }
    }
    catch { }
    finally { if ($response) { $response.Close() } }
    return $Default
}

#Checks this VM can run Hyper-V (on Azure: the VM size supports nested virtualization).
#Returns @{ State = 'Capable', 'NotCapable' or 'Unknown'; Reason; Details }.
#LEARN: Windows shows the CPU's virtualization settings in Win32_Processor. While a hypervisor runs Windows
#       itself (Hyper-V already installed, or virtualization-based security) they read "no" even on a
#       capable VM, so only a clear "no" counts as NotCapable. The parameters let tests supply the facts.
function Test-ALFHyperVCapable {
    param($Processor, $HyperVInstalled, $VbsStatus)
    if (-not $PSBoundParameters.ContainsKey('HyperVInstalled')) { $HyperVInstalled = [bool](Get-Service -Name vmms -ErrorAction SilentlyContinue) }
    if ($HyperVInstalled) { return @{ State = 'Capable'; Reason = 'Hyper-V is already installed on this VM.'; Details = 'Hyper-V: installed' } }
    if (-not $PSBoundParameters.ContainsKey('Processor')) {
        $Processor = try { Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1 } catch { $null }
    }
    if (-not $PSBoundParameters.ContainsKey('VbsStatus')) {
        $VbsStatus = try { (Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop).VirtualizationBasedSecurityStatus } catch { $null }
    }
    $vmx = $null; $slat = $null; $firmware = $null
    if ($Processor) { $vmx = $Processor.VMMonitorModeExtensions; $slat = $Processor.SecondLevelAddressTranslationExtensions; $firmware = $Processor.VirtualizationFirmwareEnabled }
    $word = { param($Value) if ($null -eq $Value) { 'unknown' } elseif ($Value) { 'yes' } else { 'no' } }
    $details = "Virtualization extensions: $(& $word $vmx), SLAT: $(& $word $slat), enabled in firmware: $(& $word $firmware)"
    if ($VbsStatus -eq 2) { $details += ' (virtualization-based security is running)' }
    if ($vmx -eq $true -and $slat -eq $true -and $firmware -ne $false) {
        return @{ State = 'Capable'; Reason = 'This VM can run Hyper-V (nested virtualization).'; Details = $details }
    }
    if ($VbsStatus -ne 2 -and $vmx -eq $false) {
        return @{ State = 'NotCapable'; Reason = "This VM size can't run Hyper-V: it doesn't offer nested virtualization."; Details = $details }
    }
    $reason = "The CPU's virtualization settings are incomplete."
    if (-not $Processor) { $reason = "Couldn't read the CPU's virtualization settings." }
    elseif ($VbsStatus -eq 2) { $reason = "Virtualization-based security hides the CPU's virtualization settings." }
    return @{ State = 'Unknown'; Reason = $reason; Details = $details }
}

#Shows the Hyper-V check in a host step. Stops when this VM size can't run Hyper-V, unless you type YES.
function Assert-ALFHyperVCapable([string]$Step) {
    $check = Test-ALFHyperVCapable
    Write-Host "    $($check.Details)"
    if ($check.State -eq 'Capable') { Write-Host "    $($check.Reason)" -ForegroundColor Green; return }
    if ($check.State -eq 'Unknown') {
        Write-Host "    $($check.Reason) Continuing - if Hyper-V doesn't install or start, resize the Azure VM to a size that supports nested virtualization." -ForegroundColor Yellow
        return
    }
    Write-Host "    $($check.Reason)" -ForegroundColor Red
    Write-Host "    Resize the Azure VM to a size that supports nested virtualization (Planning Console > Refresh Azure sizes lists them), then run $Step again." -ForegroundColor Red
    if ((Read-Host '    Type YES to continue anyway (anything else stops)') -notmatch '^\s*YES\s*$') {
        throw "Stopped: this VM can't run Hyper-V. Resize the Azure VM, then run $Step again."
    }
    Write-Host '    Continuing anyway - Hyper-V may not install or run on this VM size.' -ForegroundColor Yellow
}

#A lab has 2 to 16 Azure Local nodes (the planned pair is the default).
function Test-ALFNodeNames([string[]]$Names) {
    if ($Names.Count -lt 2 -or $Names.Count -gt 16) { throw "Enter 2 to 16 node names (got $($Names.Count))." }
    foreach ($name in $Names) {
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$' -or $name -match '^[0-9]+$') {
            throw 'Each node name must be 1-15 letters, digits or hyphens, start with a letter or digit, and not be entirely numeric.'
        }
    }
    $duplicates = @($Names | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
    if ($duplicates.Count) { throw "Each node name must be different (repeated: $($duplicates -join ', '))." }
}

#Suggests a name for an added node: the last name with its trailing number increased
#(AzL2101Node2 -> AzL2101Node3), skipping names already in the list and staying within 15 characters.
function Get-ALFNextNodeName([string[]]$Names) {
    $last = if ($Names.Count) { $Names[-1] } else { 'Node1' }
    if ($last -match '^(.*?)([0-9]+)$' -and $Matches[1]) { $prefix = $Matches[1]; $number = [long]$Matches[2]; $width = $Matches[2].Length }
    else { $prefix = $last; $number = 1; $width = 1 }
    for ($i = 1; $i -le 1000; $i++) {
        $digits = ($number + $i).ToString().PadLeft($width, '0')
        $stem = if ($prefix.Length + $digits.Length -gt 15) { $prefix.Substring(0, [Math]::Max(0, 15 - $digits.Length)) } else { $prefix }
        $candidate = $stem + $digits
        if ($candidate -match '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$' -and $candidate -notmatch '^[0-9]+$' -and $Names -notcontains $candidate) { return $candidate }
    }
    for ($i = 1; $i -le 1000; $i++) { if ($Names -notcontains "Node$i") { return "Node$i" } }
}

#"A and B" for two names, "A, B and C" for more.
function Join-ALFNodeNames([string[]]$Names) {
    if ($Names.Count -le 2) { return ($Names -join ' and ') }
    return (($Names[0..($Names.Count - 2)] -join ', ') + ' and ' + $Names[-1])
}

#The planned node names for the Planning Console's Number of Azure Local nodes (2-16):
#NodeName1/NodeName2, then suggested names (AzL2101Node3, ...). Unfilled templates pass through unchanged.
function Get-ALFPlannedNodeNames([string[]]$Names, [string]$Count) {
    if ("$($Names -join '')$Count" -match '\{\{') { return $Names }
    if ($Count -notmatch '^([2-9]|1[0-6])$') {
        throw "The planned Number of Azure Local nodes must be 2 to 16 (got '$Count'). Correct it in the Planning Console and use Roll out scripts."
    }
    $planned = [Collections.Generic.List[string]]::new()
    foreach ($name in $Names) { if ($planned.Count -lt [int]$Count) { $planned.Add($name) } }
    while ($planned.Count -lt [int]$Count) { $planned.Add((Get-ALFNextNodeName $planned.ToArray())) }
    Test-ALFNodeNames $planned.ToArray()
    return $planned.ToArray()
}

function Get-ALFNodeNames([string]$SettingsPath, [string[]]$DefaultNames) {
    if (-not (Test-Path -LiteralPath $SettingsPath)) { return $DefaultNames }
    try {
        $settings = Get-Content -LiteralPath $SettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $names = @($settings.NodeNames)
        if (@($names | Where-Object { $_ -isnot [string] }).Count) { throw 'NodeNames must contain strings.' }
        Test-ALFNodeNames $names
        return $names
    }
    catch { throw "Cannot read node selection from ${SettingsPath}: $($_.Exception.Message). Correct the file or remove it to use the planned names." }
}

function Test-ALFNodeCopyList($CopyList) {
    # Copy-list entries are hashtables; named-property grouping does not read their Dest keys.
    $duplicates = @($CopyList | Group-Object -Property { $_.Dest } | Where-Object Count -gt 1)
    if ($duplicates.Count) {
        $details = @($duplicates | ForEach-Object {
            "$($_.Name) <- $((@($_.Group | ForEach-Object { $_.Source })) -join ', ')"
        })
        throw "Duplicate guest destinations: $($details -join '; '). Keep one source for each destination and retry."
    }
}

function Get-ALFNodeDeliveryCheck([string]$NodeName, [string]$NodeFolder, [string]$ScriptFolder, [string]$VMId) {
    $missing = @{ State = 'Attention'; Detail = "${NodeName}: no verified guest delivery - run step 10." }
    $receiptPath = Join-Path $NodeFolder 'ALFNodeDelivery.json'
    if (-not $VMId -or -not (Test-Path -LiteralPath $receiptPath)) { return $missing }
    try {
        $receipt = Get-Content -LiteralPath $receiptPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($receipt.NodeName -cne $NodeName -or $receipt.VMId -ne $VMId -or -not $receipt.VerifiedUtc) { return $missing }
        foreach ($pair in @(@('12.Node-Configure.ps1', 'TemplateHash'), @('11.Host-PrepareNodes.ps1', 'PrepareScriptHash'))) {
            if ((Get-FileHash -LiteralPath (Join-Path $ScriptFolder $pair[0]) -Algorithm SHA256 -ErrorAction Stop).Hash -ne $receipt.($pair[1])) { return $missing }
        }
        foreach ($name in '12.Node-Configure.ps1', '14.Node-ArcRegister.ps1', 'ALFGuestConsole.ps1', 'ALFGuestStepRunner.ps1', 'ALFGuestStatus.ps1', 'ALFGuestDisplay.ps1', 'Launch-ALFNodeConsole.cmd', 'AzureLocal-DeploymentTroubleshooter.ps1') {
            $entry = @($receipt.Files | Where-Object { $_.Name -ceq $name -and $_.Dest -ceq (Join-Path 'C:\ISO' $name) })
            if ($entry.Count -ne 1 -or $entry[0].Dest -cne (Join-Path 'C:\ISO' $name)) { return $missing }
            $sourceFolder = if ($name -eq '12.Node-Configure.ps1') { $NodeFolder } else { $ScriptFolder }
            if ((Get-FileHash -LiteralPath (Join-Path $sourceFolder $name) -Algorithm SHA256 -ErrorAction Stop).Hash -ne $entry[0].Hash) { return $missing }
        }
        return @{ State = 'Done'; Detail = "${NodeName}: guest copies last verified $($receipt.VerifiedUtc). Open C:\ISO\Launch-ALFNodeConsole.cmd inside this VM." }
    }
    catch { return $missing }
}

function Save-ALFNodeNames([string]$SettingsPath, [string[]]$Names) {
    Test-ALFNodeNames $Names
    $temporary = "$SettingsPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        @{ NodeNames = $Names } | ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding UTF8 -ErrorAction Stop
        if (Test-Path -LiteralPath $SettingsPath) {
            #[NullString]::Value = no backup file. Plain $null becomes "" in Windows PowerShell 5.1 and Replace() throws.
            [System.IO.File]::Replace($temporary, $SettingsPath, [NullString]::Value)
        }
        else { [System.IO.File]::Move($temporary, $SettingsPath) }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}
