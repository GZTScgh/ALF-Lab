# Version: ALF Lab Builder 2.0.22
# Shared host-only node selection; never edits the Planning Console plan.

function Test-ALFNodeNames([string[]]$Names) {
    if ($Names.Count -ne 2) { throw 'Enter exactly two node names.' }
    foreach ($name in $Names) {
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$' -or $name -match '^[0-9]+$') {
            throw 'Each node name must be 1-15 letters, digits or hyphens, start with a letter or digit, and not be entirely numeric.'
        }
    }
    if ($Names[0] -ieq $Names[1]) { throw 'The two node names must be different.' }
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
        foreach ($name in '12.Node-Configure.ps1', '14.Node-ArcRegister.ps1', 'ALFGuestConsole.ps1', 'ALFGuestStepRunner.ps1', 'ALFGuestStatus.ps1', 'ALFGuestDisplay.ps1', 'Launch-ALFNodeConsole.cmd') {
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
