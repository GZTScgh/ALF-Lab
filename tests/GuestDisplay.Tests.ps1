# Run normally in an approved PowerShell session. Native display changes are mocked.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'ALFGuestDisplay.ps1')
$script:Passed=0
function Assert($Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:Passed++
}
function Assert-Throws([scriptblock]$Action,[string]$Pattern) {
    $message=''
    try { & $Action } catch { $message=$_.Exception.Message }
    Assert ($message -match $Pattern) "Expected explicit display warning: $Pattern"
}
Initialize-ALFGuestDisplay
Assert ([Runtime.InteropServices.Marshal]::SizeOf([Activator]::CreateInstance(('ALFLab.GuestDisplay+DeviceMode' -as [type]))) -eq 220) 'DEVMODEW uses the correct native layout.'
$script:Width=1024; $script:Height=768; $script:Remote=$false; $script:Result=0; $script:ChangeCalls=0; $script:Apply=$true
function Get-ALFGuestDisplaySize { return @($script:Width,$script:Height) }
function Test-ALFGuestRemoteDisplay { return $script:Remote }
function Invoke-ALFGuestDisplayChange {
    $script:ChangeCalls++
    if ($script:Result -eq 0 -and $script:Apply) { $script:Width=1600; $script:Height=900 }
    return $script:Result
}
foreach ($role in 'DC','Admin') {
    $script:Width=1024; $script:Height=768
    Assert ((Set-ALFGuestDisplayResolution $role) -match 'Desktop set' -and $script:Width -eq 1600 -and $script:Height -eq 900) 'Both supported guest roles apply the requested size.'
}
$before=$script:ChangeCalls
Assert ((Set-ALFGuestDisplayResolution DC) -match 'already' -and $script:ChangeCalls -eq $before) 'An already-correct size does not change the display.'
$script:Width=1024; $script:Height=768; $script:Remote=$true
Assert-Throws { Set-ALFGuestDisplayResolution Admin } 'connection client'
Assert ($script:ChangeCalls -eq $before) 'Client-controlled sessions do not attempt a native display change.'
$script:Remote=$false; $script:Result=-2
Assert-Throws { Set-ALFGuestDisplayResolution DC } 'not supported'
Assert ($script:Width -eq 1024 -and $script:Height -eq 768) 'Unsupported mode never produces a success response.'
$script:Result=0; $script:Apply=$false
Assert-Throws { Set-ALFGuestDisplayResolution Admin } 'did not apply'
Assert-Throws { Set-ALFGuestDisplayResolution Node } 'only available'
$tokens=$null; $errors=$null
$console=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'ALFGuestConsole.ps1'),[ref]$tokens,[ref]$errors)
$display=$console.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-GuestConsoleDisplay'},$true)[0]
. ([scriptblock]::Create($display.Extent.Text))
Add-Type -AssemblyName PresentationFramework
function Write-GuestLog([string]$Text) { $script:DisplayLog=$Text }
$window=[pscustomobject]@{Width=1024;Height=768};$Role='Admin'
$script:Width=1024;$script:Height=768;$script:Apply=$true;$script:Remote=$false
Set-GuestConsoleDisplay
Assert ($script:Width -eq 1600 -and $script:Height -eq 900) 'A manual display request reuses the tested display helper.'
$script:Width=1024;$script:Height=768;$script:Remote=$true;$before=$script:ChangeCalls
Set-GuestConsoleDisplay
Assert ($script:DisplayLog -match 'connection client' -and $script:ChangeCalls -eq $before) 'A client-controlled display request is logged without a native change.'
$displayCalls=@($console.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-GuestConsoleDisplay'},$true))
$displayClick=$console.FindAll({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'Add_Click' -and $n.Expression.Extent.Text -eq '$ui.btnDisplay'},$true)[0]
Assert ($displayCalls.Count -eq 1 -and $displayClick -and $displayCalls[0].Extent.StartOffset -gt $displayClick.Extent.StartOffset -and $displayCalls[0].Extent.EndOffset -lt $displayClick.Extent.EndOffset) 'Only clicking the manual display button requests a resolution change; opening the console does not.'
Write-Output "PASS: $script:Passed optional display cases; no real display APIs invoked."
