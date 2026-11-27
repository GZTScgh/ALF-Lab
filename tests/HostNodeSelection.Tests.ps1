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
    $seventeen = @(1..17 | ForEach-Object { "Node$_" })
    foreach ($invalid in @(@('', 'Node4'), @('Node3', 'node3'), @('123', 'Node4'), @('Node_3', 'Node4'), @('-Node3', 'Node4'), @('ABCDEFGHIJKLMNOP', 'Node4'), @('Node3'), $seventeen, @('Node3', 'Node4', 'NODE3'))) {
        Assert-Throws { Save-ALFNodeNames $NodeSettingsFile $invalid } 'Reject invalid node names.'
    }
    Assert ((@(Get-ALFNodeNames $NodeSettingsFile $planned) -join '|') -eq ($selected -join '|')) 'Invalid saves must preserve previous selection.'
    foreach ($valid in @(@('Node3', 'Node4', 'Node5'), @($seventeen[0..15]))) {
        Save-ALFNodeNames $NodeSettingsFile $valid
        Assert ((@(Get-ALFNodeNames $NodeSettingsFile $planned) -join '|') -eq ($valid -join '|')) "A $($valid.Count)-node selection must save and reload."
    }
    Assert ((Get-ALFNextNodeName @('AzL2001Node1', 'AzL2001Node2')) -eq 'AzL2001Node3') 'Added nodes continue the numbering.'
    Assert ((Get-ALFNextNodeName @('Node3', 'Node4', 'Node5')) -eq 'Node6' -and (Get-ALFNextNodeName @('Node5', 'Node6', 'Node3')) -eq 'Node4') 'Next name skips names already used.'
    Assert ((Get-ALFNextNodeName @('Node09')) -eq 'Node10') 'Next name keeps zero padding.'
    $longNext = Get-ALFNextNodeName @('ABCDEFGHIJKLMN9')
    Assert ($longNext.Length -le 15 -and $longNext -eq 'ABCDEFGHIJKLM10') 'Next name stays within 15 characters.'
    Assert ((Join-ALFNodeNames @('A', 'B')) -eq 'A and B' -and (Join-ALFNodeNames @('A', 'B', 'C')) -eq 'A, B and C') 'Node lists read naturally.'
    $plannedThree = @(Get-ALFPlannedNodeNames $planned '3')
    Assert ($plannedThree.Count -eq 3 -and $plannedThree[2] -eq 'AzL2001Node3' -and (@(Get-ALFPlannedNodeNames $planned '2') -join '|') -eq ($planned -join '|')) 'The planned node count adds suggested names after NodeName2.'
    $plannedSixteen = @(Get-ALFPlannedNodeNames $planned '16')
    Assert ($plannedSixteen.Count -eq 16 -and $plannedSixteen[15] -eq 'AzL2001Node16') 'Sixteen planned nodes get valid names.'
    foreach ($badCount in '1', '17', 'x', '') {
        Assert-Throws { Get-ALFPlannedNodeNames $planned $badCount } "A planned node count of '$badCount' must be rejected."
    }
    Assert ((@(Get-ALFPlannedNodeNames @('{{NodeName1}}', '{{NodeName2}}') '{{NodeCount}}') -join '|') -eq '{{NodeName1}}|{{NodeName2}}') 'Unrolled templates keep their placeholders.'
    Save-ALFNodeNames $NodeSettingsFile $planned
    Assert ((@(Get-ALFNodeNames $NodeSettingsFile $selected) -join '|') -eq ($planned -join '|')) 'Replacing settings must persist the new selection.'
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
    $nodeRow = $script:Rows.Nodes
    Assert ($nodeRow.nodeCount.Items.Count -eq 15 -and [int]$nodeRow.nodeCount.SelectedItem -eq 2 -and $nodeRow.nodeBoxes.Count -eq 2 -and $nodeRow.nodeNamePanel.Children.Count -eq 2) 'Step 9 offers 2-16 nodes and starts with the applied pair.'
    Assert ($nodeRow.nodeBoxes[0].Text -eq $planned[0] -and $nodeRow.nodeBoxes[1].Text -eq $planned[1] -and $nodeRow.run.IsEnabled) 'Applied names fill the boxes without pending edits.'
    $nodeRow.nodeBoxes[0].Text = $selected[0]
    $nodeRow.nodeBoxes[1].Text = $selected[1]
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
    $clickApply = { $nodeRow.applyNodes.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
    $nodeRow.nodeCount.SelectedIndex = 1
    Assert ($nodeRow.nodeBoxes.Count -eq 3 -and $nodeRow.nodeNamePanel.Children.Count -eq 3 -and $nodeRow.nodeBoxes[2].Text -eq 'AzL2001Node5') 'A third box is added with the next node name.'
    Assert (-not $nodeRow.run.IsEnabled -and -not $script:Rows.Prepare.run.IsEnabled -and $nodeRow.nodeSelection.Text -match 'Pending') 'A changed node count blocks both node steps until applied.'
    $NodeIPStart = '192.168.44.51'; $NodeIPEnd = '192.168.44.52'
    & $clickApply
    Assert ($script:LastLog -match 'not applied' -and $script:LastLog -match 'holds only 2' -and $NodeNames.Count -eq 2) 'Apply refuses more nodes than the planned IP range holds.'
    $NodeIPEnd = '192.168.44.59'
    & $clickApply
    $three = @('AzL2001Node3', 'AzL2001Node4', 'AzL2001Node5')
    Assert (($NodeNames -join '|') -eq ($three -join '|') -and ((@(Get-ALFNodeNames $NodeSettingsFile $planned)) -join '|') -eq ($three -join '|')) 'Apply saves a three-node selection.'
    Assert ($nodeRow.run.IsEnabled -and $nodeRow.desc.Text -match 'AzL2001Node3, AzL2001Node4 and AzL2001Node5' -and $script:Rows.Prepare.desc.Text -match 'AzL2001Node3, AzL2001Node4 and AzL2001Node5') 'Descriptions list all applied nodes.'
    Assert ($nodeRow.nodeSelection.Text -match '\(3 nodes\)' -and $script:LastLog -match 'Applied 3 node names') 'Status and log show the node count.'
    Remove-Variable NodeIPStart, NodeIPEnd
    $nodeRow.nodeCount.SelectedIndex = 14
    $sixteen = @($nodeRow.nodeBoxes | ForEach-Object { $_.Text })
    Assert ($sixteen.Count -eq 16 -and @($sixteen | Select-Object -Unique).Count -eq 16 -and $sixteen[15] -eq 'AzL2001Node18') 'Sixteen boxes get distinct suggested names.'
    Test-ALFNodeNames $sixteen
    Assert $true 'Suggested names for sixteen nodes are valid.'
    $nodeRow.nodeCount.SelectedIndex = 0
    Assert ($nodeRow.nodeBoxes.Count -eq 2 -and $nodeRow.nodeNamePanel.Children.Count -eq 2 -and $nodeRow.nodeBoxes[1].Text -eq 'AzL2001Node4' -and -not $nodeRow.run.IsEnabled) 'Lowering the count removes boxes and leaves a pending edit.'
    & $clickApply
    Assert (($NodeNames -join '|') -eq ($selected -join '|') -and $nodeRow.run.IsEnabled -and $nodeRow.desc.Text -match 'AzL2001Node3 and AzL2001Node4') 'Apply returns to a two-node selection.'
    $script:Running = @{ Task = (Get-Task 'Nodes') }
    Update-Buttons
    Assert (-not $nodeRow.applyNodes.IsEnabled -and -not $nodeRow.nodeBoxes[0].IsEnabled -and -not $nodeRow.nodeCount.IsEnabled) 'Running steps lock node selection.'
    Assert-Throws { Set-HostNodeNames $planned } 'Apply must reject changes during a running step.'
    $script:Running = $null

    # Fill the templates from the starter plan (Rollout\ is local-only), then run only their node-name/IP setup assignments.
    $planValues = @{}
    (Get-Content -LiteralPath (Join-Path $root 'LabValues.example.json') -Raw | ConvertFrom-Json).Values |
        Where-Object Key -in 'NodeName1', 'NodeName2', 'NodeIPStart', 'NodeIPEnd', 'NodeCount' | ForEach-Object { $planValues[$_.Key] = [string]$_.Value }
    Assert ($planValues.NodeCount -eq '2') 'The starter plan budgets two nodes.'
    # With a planned count of 3 and no saved step 9 selection, every entry point starts with three nodes.
    $threePlan = $planValues.Clone(); $threePlan.NodeCount = '3'
    $noSelection = Join-Path $fixtureRoot 'no-selection'
    $plannedSetup = @{ 'ALFHostConsole.ps1' = '$PlannedNodeNames', '$NodeSettingsFile', '$NodeNames'; '10.Host-CreateNodeVMs.ps1' = '$NodeNameList'; '11.Host-PrepareNodes.ps1' = '$NodeNames' }
    foreach ($file in $plannedSetup.Keys) {
        $content = Get-Content -LiteralPath (Join-Path $root $file) -Raw
        foreach ($key in $threePlan.Keys) { $content = $content.Replace('{{' + $key + '}}', $threePlan[$key]) }
        $fileTokens = $null; $fileErrors = $null
        $fileAst = [Management.Automation.Language.Parser]::ParseInput($content, [ref]$fileTokens, [ref]$fileErrors)
        $variables = $plannedSetup[$file]
        $code = (@($fileAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -in $variables }) | ForEach-Object { $_.Extent.Text }) -join "`n"
        $resultVariable = @($variables)[-1].TrimStart('$')
        $names = & { . ([scriptblock]::Create($code.Replace('$PSScriptRoot', '$noSelection'))); Get-Variable -Name $resultVariable -ValueOnly }
        Assert (@($names).Count -eq 3 -and @($names)[2] -eq ($planValues.NodeName2 -replace '2$', '3')) "$file must start with the planned Number of Azure Local nodes."
    }
    foreach ($file in '10.Host-CreateNodeVMs.ps1', '11.Host-PrepareNodes.ps1') {
        $content = Get-Content -LiteralPath (Join-Path $root $file) -Raw
        foreach ($key in $planValues.Keys) { $content = $content.Replace('{{' + $key + '}}', $planValues[$key]) }
        $fileTokens = $null; $fileErrors = $null
        $fileAst = [Management.Automation.Language.Parser]::ParseInput($content, [ref]$fileTokens, [ref]$fileErrors)
        $nameVariable = if ($file.StartsWith('10.')) { '$NodeNameList' } else { '$NodeNames' }
        $setup = @($fileAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -in $nameVariable, '$NodeIPStart', '$NodeIPEnd', '$startBytes', '$endLast' })
        Assert ($setup.Count -ge 2 -and $setup[1].Extent.Text -match 'Get-ALFNodeNames') "$file must reload the saved node selection after its planned names."
        $prefix = ($setup | ForEach-Object { $_.Extent.Text }) -join "`n"
        . ([scriptblock]::Create($prefix.Replace('$PSScriptRoot', '$fixtureRoot')))
        $actual = if ($file.StartsWith('10.')) { $NodeNameList } else { $NodeNames }
        Assert (($actual -join '|') -eq ($selected -join '|')) "Manual $file must use the same selected pair."
    }
    $prepare = Get-Content -LiteralPath (Join-Path $root '11.Host-PrepareNodes.ps1') -Raw
    $prepareAst = Read-Ast (Join-Path $root '11.Host-PrepareNodes.ps1')
    $nodesCode = $prepareAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$Nodes' } | Select-Object -First 1
    . ([scriptblock]::Create($nodesCode.Extent.Text))
    Assert ($Nodes[0].Name -eq $selected[0] -and $Nodes[1].Name -eq $selected[1] -and $Nodes[0].IP -eq $NodeIPStart) 'Preparation must retain first/second IP ordering.'
    $savedNodeNames = $NodeNames
    $NodeNames = @('Node3', 'Node4', 'Node5')
    . ([scriptblock]::Create($nodesCode.Extent.Text))
    $ipPrefix = $NodeIPStart.Substring(0, $NodeIPStart.LastIndexOf('.') + 1)
    $firstLast = [int]$NodeIPStart.Split('.')[3]
    Assert ($Nodes.Count -eq 3 -and $Nodes[2].Name -eq 'Node5' -and $Nodes[2].IP -eq ($ipPrefix + ($firstLast + 2))) 'A third node gets the next address in the range.'
    $NodeNames = $savedNodeNames
    . ([scriptblock]::Create($nodesCode.Extent.Text))
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
        @{ Source = 'host-status'; Dest = 'C:\ISO\ALFGuestStatus.ps1' },
        @{ Source = 'host-display'; Dest = 'C:\ISO\ALFGuestDisplay.ps1' },
        @{ Source = 'host-launcher'; Dest = 'C:\ISO\Launch-ALFNodeConsole.cmd' },
        @{ Source = 'host-troubleshooter'; Dest = 'C:\ISO\AzureLocal-DeploymentTroubleshooter.ps1' }
    )
    Test-ALFNodeCopyList $normalCopies
    Assert $true 'The normal eight-file delivery must not fail when there are zero extras.'
    Test-ALFNodeCopyList @($normalCopies + @{ Source = 'extra-readme'; Dest = 'C:\ISO\notes.txt' })
    Assert $true 'An extra file with a unique destination must be allowed.'
    $collisionMessage = ''
    try { Test-ALFNodeCopyList @($normalCopies + @{ Source = 'extra-launcher'; Dest = 'c:\iso\launch-alfnodeconsole.cmd' }) }
    catch { $collisionMessage = $_.Exception.Message }
    Assert ($collisionMessage -match 'Launch-ALFNodeConsole.cmd' -and $collisionMessage -match 'host-launcher' -and $collisionMessage -match 'extra-launcher') 'A true case-insensitive collision must list its path and both source files.'

    $deliverySources = Join-Path $fixtureRoot 'delivery-sources'
    $deliveryNode = Join-Path $fixtureRoot 'delivery-node'
    $null = New-Item -Path $deliverySources, $deliveryNode -ItemType Directory
    foreach ($name in '11.Host-PrepareNodes.ps1', '12.Node-Configure.ps1', '14.Node-ArcRegister.ps1', 'ALFGuestConsole.ps1', 'ALFGuestStepRunner.ps1', 'ALFGuestStatus.ps1', 'ALFGuestDisplay.ps1', 'Launch-ALFNodeConsole.cmd', 'AzureLocal-DeploymentTroubleshooter.ps1') {
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
    foreach ($name in 'ALFGuestStatus.ps1', 'ALFGuestDisplay.ps1') {
        $savedHash = ($deliveryReceipt.Files | Where-Object Name -eq $name).Hash
        ($deliveryReceipt.Files | Where-Object Name -eq $name).Hash = 'stale helper'
        $deliveryReceipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $deliveryReceiptPath
        Assert ((Get-ALFNodeDeliveryCheck 'Node3' $deliveryNode $deliverySources 'vm-3').State -eq 'Attention') 'Both shared helpers are mandatory verified guest files.'
        ($deliveryReceipt.Files | Where-Object Name -eq $name).Hash = $savedHash
    }
    $deliveryReceipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $deliveryReceiptPath
    Set-Content -LiteralPath (Join-Path $deliverySources 'Launch-ALFNodeConsole.cmd') -Value 'changed fixture'
    Assert ((Get-ALFNodeDeliveryCheck 'Node3' $deliveryNode $deliverySources 'vm-3').State -eq 'Attention') 'Updated console files must invalidate old delivery receipts.'
    Set-Content -LiteralPath $deliveryReceiptPath -Value '{broken'
    Assert ((Get-ALFNodeDeliveryCheck 'Node3' $deliveryNode $deliverySources 'vm-3').State -eq 'Attention') 'Corrupt receipts must fail closed.'
    $isoName = 'AzureLocal24H2.26100.32230.LCM.12.2609.0.3009.x64.en-us.iso'
    $bing = 'https://www.bing.com/?ref=aka&shorturl=hcireleaseimage%2F2609'
    Assert ((Get-ALFAzureLocalIsoFileName $bing "attachment; filename=$isoName; filename*=UTF-8''$isoName" '2609') -eq $isoName) 'Read the ISO name from Content-Disposition.'
    Assert ((Get-ALFAzureLocalIsoFileName '' "attachment; filename*=UTF-8''$isoName" '2609') -eq $isoName) 'Read the encoded Content-Disposition name.'
    Assert ((Get-ALFAzureLocalIsoFileName "https://software-static.download.prss.microsoft.com/dbazure/x/$isoName" '' '2609') -eq $isoName) 'Read the ISO name from the final link.'
    Assert ($null -eq (Get-ALFAzureLocalIsoFileName $bing '' '2609')) 'An unpublished release page is not an ISO name.'
    Assert ($null -eq (Get-ALFAzureLocalIsoFileName '' "attachment; filename=$isoName" '2610')) 'Another release ISO name is not used.'
    Assert ($null -eq (Get-ALFAzureLocalIsoFileName '' 'attachment; filename="..\AzureLocal.LCM.12.2609.0.iso"' '2609')) 'A name with a path is rejected.'
    Assert ($null -eq (Get-ALFAzureLocalIsoFileName '' 'attachment; filename=AzureLocal.LCM.12.2609.0.zip' '2609')) 'Only ISO names are used.'
    Assert ($null -eq (Get-ALFAzureLocalIsoFileName '' "attachment; filename=$isoName" '{{AzureLocalImageRelease}}')) 'A placeholder release gives no name.'
    $defaultIso = Join-Path $fixtureRoot 'AzureLocal-2609.iso'
    Assert ((Get-ALFAzureLocalIsoPath $defaultIso 'http://aka.ms/hcireleaseimage/2609' '2609') -eq $defaultIso) 'Only https links are looked up.'
    Assert ((Get-ALFAzureLocalIsoPath $defaultIso 'https://127.0.0.1:1/iso' '2609' 2) -eq $defaultIso) 'An unreachable link keeps the fallback name.'
    $ImageScript = '01.Host-PrepareDataDisk.ps1'
    Set-Content -LiteralPath (Join-Path $fixtureRoot $ImageScript) -Value "`$AzureLocalImageRelease = `"2609`"`r`n`$AzureLocalIso = `"$defaultIso`""
    $isoTask = [pscustomobject]@{ Id = 'AzureLocalIso' }
    Assert ((Get-ImageLabel (Get-ImageInfo 'AzureLocalIso')) -eq "(Microsoft's file name for release 2609)") 'A new ISO card shows that Microsoft names the file.'
    Assert ((Get-ImageSaveHint (Get-ImageInfo 'AzureLocalIso')) -like "*$fixtureRoot*keep Microsoft's file name*.LCM.12.2609.*") 'A browser download keeps Microsoft''s name.'
    Assert ((Get-ImageSaveHint @{ Type = 'VHDX'; Dest = 'C:\ISO\Server.vhdx' }) -eq 'Save the file as C:\ISO\Server.vhdx') 'The VHDX keeps its planned name.'
    Assert ((Get-ImageSaveHint @{ Type = 'ISO'; Dest = $null }) -eq '') 'A missing image name gives no save hint.'
    $msIso = Join-Path $fixtureRoot $isoName
    Set-Content -LiteralPath "$msIso.download" -Value 'partial'
    Assert ((Get-TaskCheck $isoTask).State -eq 'Attention') 'An unfinished download under Microsoft''s name is reported.'
    Move-Item -LiteralPath "$msIso.download" -Destination $msIso
    Assert ((Get-ImageInfo 'AzureLocalIso').Dest -eq $msIso) 'A finished download under Microsoft''s name is used.'
    Assert ((Get-ImageLabel (Get-ImageInfo 'AzureLocalIso')) -eq $isoName) 'The ISO card shows Microsoft''s file name.'
    Assert ((Get-TaskCheck $isoTask).State -eq 'Done') 'A finished download under Microsoft''s name counts as done.'
    $cpu = { param($Vmx, $Slat, $Firmware) [pscustomobject]@{ VMMonitorModeExtensions = $Vmx; SecondLevelAddressTranslationExtensions = $Slat; VirtualizationFirmwareEnabled = $Firmware } }
    $virt = Test-ALFHyperVCapable -Processor (& $cpu $true $true $true) -HyperVInstalled $false -VbsStatus 0
    Assert ($virt.State -eq 'Capable' -and $virt.Details -eq 'Virtualization extensions: yes, SLAT: yes, enabled in firmware: yes') 'Nested virtualization reads as able to run Hyper-V.'
    $virt = Test-ALFHyperVCapable -Processor (& $cpu $false $false $false) -HyperVInstalled $false -VbsStatus 0
    Assert ($virt.State -eq 'NotCapable' -and $virt.Reason -match "can't run Hyper-V") 'A VM size without nested virtualization is not able to run Hyper-V.'
    $virt = Test-ALFHyperVCapable -Processor (& $cpu $false $false $false) -HyperVInstalled $false -VbsStatus 2
    Assert ($virt.State -eq 'Unknown' -and $virt.Reason -match 'Virtualization-based security') 'Virtualization-based security hides the CPU settings, so it is not a clear no.'
    Assert ((Test-ALFHyperVCapable -Processor (& $cpu $false $false $false) -HyperVInstalled $true -VbsStatus 0).State -eq 'Capable') 'Hyper-V already installed proves the VM can run it.'
    Assert ((Test-ALFHyperVCapable -Processor $null -HyperVInstalled $false -VbsStatus $null).State -eq 'Unknown') 'Unreadable CPU settings are not a clear no.'
    Assert ((Test-ALFHyperVCapable -Processor (& $cpu $true $false $true) -HyperVInstalled $false -VbsStatus 0).State -eq 'Unknown') 'Incomplete CPU settings are not a clear no.'
    Assert ((Test-ALFHyperVCapable -Processor (& $cpu $true $true $null) -HyperVInstalled $false -VbsStatus 0).State -eq 'Capable') 'An unreported firmware setting does not block a capable CPU.'
    $script:VirtCheck = @{ State = 'NotCapable'; Reason = "This VM size can't run Hyper-V."; Details = 'x' }
    $diskCheck = Get-TaskCheck ([pscustomobject]@{ Id = 'Disk' })
    Assert ($diskCheck.State -eq 'Attention' -and $diskCheck.Detail -match 'resize the Azure VM') 'The step 1 card flags a VM size that cannot run Hyper-V.'
    $script:VirtCheck = $null
    Assert (-not @(Get-ChildItem -LiteralPath $fixtureRoot -Filter '*.tmp').Count) 'No settings temporary files may remain.'
    Write-Output "PASS: $script:Passed focused node-selection checks; real WPF controls, no provisioning."
}
finally { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
