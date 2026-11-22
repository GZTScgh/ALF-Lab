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
Write-Output "PASS: $script:Passed optional display cases; no real display APIs invoked."
