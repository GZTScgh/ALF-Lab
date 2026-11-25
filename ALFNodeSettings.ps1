# Version: ALF Lab Builder 2.1.0
# Shared host-only node selection and Azure Local image helpers; never edits the Planning Console plan.

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
#(AzL2100Node2 -> AzL2100Node3), skipping names already in the list and staying within 15 characters.
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
