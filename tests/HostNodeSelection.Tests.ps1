# Run in an approved Windows PowerShell STA session. No Hyper-V/Azure operations are executed.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$root = Split-Path $PSScriptRoot -Parent
$before = @(Get-ChildItem -LiteralPath $PSScriptRoot -Force)
$fixtureRoot = Join-Path $PSScriptRoot ('.node-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -Path $fixtureRoot -ItemType Directory
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
function Read-Ast([string]$Path) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Syntax errors in $Path" }
    return $ast
}
try {
    foreach ($file in 'ALFNodeSettings.ps1', 'ALFHostConsole.ps1') {
        $ast = Read-Ast (Join-Path $root $file)
        foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            . ([scriptblock]::Create($fn.Extent.Text))
        }
    }
    $NodeSettingsFile = Join-Path $fixtureRoot 'ALFHostConsole-Nodes.json'
    $planned = @('AzL2001Node1', 'AzL2001Node2')
    $selected = @('AzL2001Node3', 'AzL2001Node4')
    Assert ((@(Get-ALFNodeNames $NodeSettingsFile $planned) -join '|') -eq ($planned -join '|')) 'Missing settings must preserve the plan.'
    Save-ALFNodeNames $NodeSettingsFile $selected
    Assert ((@(Get-ALFNodeNames $NodeSettingsFile $planned) -join '|') -eq ($selected -join '|')) 'Saved selection must survive reload.'
    foreach ($invalid in @(@('', 'Node4'), @('Node3', 'node3'), @('123', 'Node4'), @('Node_3', 'Node4'), @('-Node3', 'Node4'), @('ABCDEFGHIJKLMNOP', 'Node4'), @('Node3'))) {
        Assert-Throws { Save-ALFNodeNames $NodeSettingsFile $invalid } 'Reject invalid node names.'
    }
    Assert ((@(Get-ALFNodeNames $NodeSettingsFile $planned) -join '|') -eq ($selected -join '|')) 'Invalid saves must preserve previous selection.'
    Save-ALFNodeNames $NodeSettingsFile $planned
    Assert ((@(Get-ALFNodeNames $NodeSettingsFile $selected) -join '|') -eq ($planned -join '|')) 'Replacing settings must persist the new pair.'
    Set-Content -LiteralPath $NodeSettingsFile -Value '{broken'
    Assert-Throws { Get-ALFNodeNames $NodeSettingsFile $planned } 'Corrupt selection must fail closed.'
    Save-ALFNodeNames $NodeSettingsFile $selected

    $consoleText = Get-Content -LiteralPath (Join-Path $root 'ALFHostConsole.ps1') -Raw
    $tokens = $null; $errors = $null
    $consoleAst = [Management.Automation.Language.Parser]::ParseInput($consoleText, [ref]$tokens, [ref]$errors)
    $RowXaml = ($tokens | Where-Object { $_.Kind -eq 'HereStringLiteral' -and $_.Value.StartsWith('<Border ') } | Select-Object -First 1).Value
    $DCName = 'ContosoDC1'; $AdminStationName = 'AdminBox'
    $NodeNames = @($planned); $Here = $fixtureRoot; $StateFile = Join-Path $fixtureRoot 'run-state.json'
    $tasksCode = $consoleAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$Tasks' } | Select-Object -First 1
    . ([scriptblock]::Create($tasksCode.Extent.Text))
    $Tasks = @($Tasks | Where-Object Id -in 'Nodes', 'Prepare')
    $script:Rows = @{}; $script:RunState = @{ Nodes = @{ Result = 'OK' }; Prepare = @{ Result = 'OK' }; Disk = @{ Result = 'OK' } }
    $script:Running = $null; $script:Downloads = @{}
    $ui = @{ panelTasks = [Windows.Controls.StackPanel]::new() }
    $cardStart = $consoleText.IndexOf('$step = 0')
    $cardEnd = $consoleText.IndexOf('function Invoke-RunButton', $cardStart)
    . ([scriptblock]::Create($consoleText.Substring($cardStart, $cardEnd - $cardStart)))
    function Write-Log([string]$Text) { $script:LastLog = $Text }
    function Update-AllStatus { $script:Refreshes++ }
    $script:Refreshes = 0
    Update-Buttons
    Assert ($script:Rows.Nodes.nodeOptions.Visibility -eq 'Visible' -and $script:Rows.Prepare.nodeOptions.Visibility -eq 'Collapsed') 'Only step 9 exposes node fields.'
    $script:Rows.Nodes.nodeName1.Text = $selected[0]
    $script:Rows.Nodes.nodeName2.Text = $selected[1]
    Assert (-not $script:Rows.Nodes.run.IsEnabled -and -not $script:Rows.Prepare.run.IsEnabled) 'Unapplied edits block both node steps.'
    Start-LabScript (Get-Task 'Prepare')
    Assert ($script:LastLog -match 'Apply node names') 'Direct Run path must also guard unapplied edits.'
    $script:Rows.Nodes.applyNodes.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert (($NodeNames -join '|') -eq ($selected -join '|')) 'Apply button must update the active pair.'
    Assert ($script:Rows.Nodes.run.IsEnabled -and $script:Rows.Prepare.run.IsEnabled) 'Apply enables both node steps.'
    Assert ($script:Rows.Nodes.desc.Text -match 'AzL2001Node3 and AzL2001Node4') 'Description must show applied names.'
    Assert ($script:Rows.Prepare.desc.Text -match 'AzL2001Node3 and AzL2001Node4' -and $script:Rows.Prepare.desc.Text -match 'Launch-ALFNodeConsole.cmd') 'Prepare must show the updated destinations and launcher.'
    Assert (-not $script:RunState.ContainsKey('Nodes') -and -not $script:RunState.ContainsKey('Prepare') -and $script:RunState.ContainsKey('Disk')) 'Apply clears only node run history.'
    foreach ($reserved in @($DCName, $AdminStationName, $env:COMPUTERNAME)) {
        Assert-Throws { Set-HostNodeNames @($reserved, 'Node4') } 'Reserved VM/host names must be rejected.'
    }
    $script:Running = @{ Task = (Get-Task 'Nodes') }
    Update-Buttons
    Assert (-not $script:Rows.Nodes.applyNodes.IsEnabled -and -not $script:Rows.Nodes.nodeName1.IsEnabled) 'Running steps lock node selection.'
    Assert-Throws { Set-HostNodeNames $planned } 'Apply must reject changes during a running step.'
    $script:Running = $null

    foreach ($file in '10.Host-CreateNodeVMs.ps1', '11.Host-PrepareNodes.ps1') {
        $content = Get-Content -LiteralPath (Join-Path $root ('Rollout\' + $file)) -Raw
        $cut = $content.IndexOf('Write-Host ')
        $prefix = $content.Substring(0, $cut).Replace(". (Join-Path `$PSScriptRoot 'ALFNodeSettings.ps1')", '').Replace('$PSScriptRoot', '$fixtureRoot')
        . ([scriptblock]::Create($prefix))
        $actual = if ($file.StartsWith('10.')) { $NodeNameList } else { $NodeNames }
        Assert (($actual -join '|') -eq ($selected -join '|')) "Manual $file must use the same selected pair."
    }
    $prepare = Get-Content -LiteralPath (Join-Path $root '11.Host-PrepareNodes.ps1') -Raw
    $prepareAst = Read-Ast (Join-Path $root '11.Host-PrepareNodes.ps1')
    $nodesCode = $prepareAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$Nodes' } | Select-Object -First 1
    . ([scriptblock]::Create($nodesCode.Extent.Text))
    Assert ($Nodes[0].Name -eq $selected[0] -and $Nodes[1].Name -eq $selected[1] -and $Nodes[0].IP -eq $NodeIPStart) 'Preparation must retain first/second IP ordering.'
    $Template = Join-Path $fixtureRoot 'template.ps1'
    Set-Content -LiteralPath $Template -Value 'Name=__NODENAME__; IP=__NODEIP__'
    $generateCode = $prepareAst.FindAll({ param($n) $n -is [Management.Automation.Language.PipelineAst] -and $n.Extent.Text.StartsWith('(Get-Content $Template -Raw).Replace') }, $true) | Select-Object -First 1
    foreach ($Node in $Nodes) {
        $NodeName = $Node.Name; $Generated = Join-Path $fixtureRoot ($NodeName + '.ps1')
        . ([scriptblock]::Create($generateCode.Extent.Text))
        Assert ((Get-Content -LiteralPath $Generated -Raw).Contains("Name=$NodeName; IP=$($Node.IP)")) 'Delivered configuration must contain the selected name and original IP.'
    }
    $normalCopies = @(
        @{ Source = 'host-configure'; Dest = 'C:\ISO\12.Node-Configure.ps1' },
        @{ Source = 'host-arc'; Dest = 'C:\ISO\14.Node-ArcRegister.ps1' },
        @{ Source = 'host-console'; Dest = 'C:\ISO\ALFGuestConsole.ps1' },
        @{ Source = 'host-runner'; Dest = 'C:\ISO\ALFGuestStepRunner.ps1' },
        @{ Source = 'host-launcher'; Dest = 'C:\ISO\Launch-ALFNodeConsole.cmd' }
    )
    Test-ALFNodeCopyList $normalCopies
    Assert $true 'The normal five-file delivery must not fail when there are zero extras.'
    Test-ALFNodeCopyList @($normalCopies + @{ Source = 'extra-readme'; Dest = 'C:\ISO\notes.txt' })
    Assert $true 'An extra file with a unique destination must be allowed.'
    $collisionMessage = ''
    try { Test-ALFNodeCopyList @($normalCopies + @{ Source = 'extra-launcher'; Dest = 'c:\iso\launch-alfnodeconsole.cmd' }) }
    catch { $collisionMessage = $_.Exception.Message }
    Assert ($collisionMessage -match 'Launch-ALFNodeConsole.cmd' -and $collisionMessage -match 'host-launcher' -and $collisionMessage -match 'extra-launcher') 'A true case-insensitive collision must list its path and both source files.'

    $deliverySources = Join-Path $fixtureRoot 'delivery-sources'
    $deliveryNode = Join-Path $fixtureRoot 'delivery-node'
    $null = New-Item -Path $deliverySources, $deliveryNode -ItemType Directory
    foreach ($name in '11.Host-PrepareNodes.ps1', '12.Node-Configure.ps1', '14.Node-ArcRegister.ps1', 'ALFGuestConsole.ps1', 'ALFGuestStepRunner.ps1', 'Launch-ALFNodeConsole.cmd') {
        Set-Content -LiteralPath (Join-Path $deliverySources $name) -Value 'fixture only'
    }
    Copy-Item -LiteralPath (Join-Path $deliverySources '12.Node-Configure.ps1') -Destination $deliveryNode
    Assert ((Get-ALFNodeDeliveryCheck 'Node3' $deliveryNode $deliverySources 'vm-3').State -eq 'Attention') 'A generated host script alone must not mark Prepare done.'
    $deliveryReceipt = @{
        NodeName = 'Node3'; VMId = 'vm-3'; VerifiedUtc = [DateTime]::UtcNow.ToString('o')
        TemplateHash = (Get-FileHash -LiteralPath (Join-Path $deliverySources '12.Node-Configure.ps1')).Hash
        PrepareScriptHash = (Get-FileHash -LiteralPath (Join-Path $deliverySources '11.Host-PrepareNodes.ps1')).Hash
        Files = @(Get-ChildItem -LiteralPath $deliverySources -File | Where-Object Name -ne '11.Host-PrepareNodes.ps1' | ForEach-Object {
            @{ Name = $_.Name; Dest = (Join-Path 'C:\ISO' $_.Name); Hash = (Get-FileHash -LiteralPath $_.FullName).Hash }
        })
    }
    $deliveryReceiptPath = Join-Path $deliveryNode 'ALFNodeDelivery.json'
    $deliveryReceipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $deliveryReceiptPath
    Assert ((Get-ALFNodeDeliveryCheck 'Node3' $deliveryNode $deliverySources 'vm-3').State -eq 'Done') 'A matching verified-delivery receipt must be accepted.'
    Assert ((Get-ALFNodeDeliveryCheck 'Node3' $deliveryNode $deliverySources 'new-vm-id').State -eq 'Attention') 'Recreated VMs must not reuse old delivery receipts.'
    Set-Content -LiteralPath (Join-Path $deliverySources 'Launch-ALFNodeConsole.cmd') -Value 'changed fixture'
    Assert ((Get-ALFNodeDeliveryCheck 'Node3' $deliveryNode $deliverySources 'vm-3').State -eq 'Attention') 'Updated console files must invalidate old delivery receipts.'
    Set-Content -LiteralPath $deliveryReceiptPath -Value '{broken'
    Assert ((Get-ALFNodeDeliveryCheck 'Node3' $deliveryNode $deliverySources 'vm-3').State -eq 'Attention') 'Corrupt receipts must fail closed.'
    Assert (-not @(Get-ChildItem -LiteralPath $fixtureRoot -Filter '*.tmp').Count) 'No settings temporary files may remain.'
    Write-Output "PASS: $script:Passed focused node-selection checks; real WPF controls, no provisioning."
}
finally { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
