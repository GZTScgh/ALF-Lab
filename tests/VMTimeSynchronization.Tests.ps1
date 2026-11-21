# Run in an approved PowerShell session. Hyper-V operations are mocked; no VM is changed.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:Calls = [Collections.Generic.List[string]]::new()
function Disable-VMIntegrationService {
    [CmdletBinding()]
    param([string]$VMName, [string]$Name)
    if ($Name -ne 'Time Synchronization') { throw 'Only Time Synchronization may be disabled.' }
    $script:Calls.Add($VMName)
}
$passed = 0
foreach ($entry in @(
    @('04dc.Host-CreateDCVM.ps1', 'VMName', 'ContosoDC1'),
    @('04adm.Host-CreateAdminStationVM.ps1', 'VMName', 'AdminStation'),
    @('10.Host-CreateNodeVMs.ps1', 'NodeName', 'AzL2778Node1'),
    @('10.Host-CreateNodeVMs.ps1', 'NodeName', 'AzL2778Node2'),
    @('05.Host-CopyScriptsToVM.ps1', 'VMName', 'ContosoDC1'),
    @('05.Host-CopyScriptsToVM.ps1', 'VMName', 'AdminStation'),
    @('11.Host-PrepareNodes.ps1', 'NodeName', 'AzL2778Node1'),
    @('11.Host-PrepareNodes.ps1', 'NodeName', 'AzL2778Node2')
)) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $entry[0]), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Syntax errors in $($entry[0])" }
    $commands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Disable-VMIntegrationService' }, $true))
    if (-not $commands.Count) { throw "Missing time synchronization action in $($entry[0])" }
    Set-Variable -Name $entry[1] -Value $entry[2]
    foreach ($command in $commands) {
        $script:Calls.Clear()
        . ([scriptblock]::Create($command.Extent.Text))
        if ($script:Calls.Count -ne 1 -or $script:Calls[0] -ne $entry[2]) { throw "Wrong VM target in $($entry[0])" }
        $passed++
    }
}
Write-Output "PASS: $passed creation/existing-VM action checks; no Hyper-V changes."
