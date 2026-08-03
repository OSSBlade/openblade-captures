$ErrorActionPreference = 'Stop'

$repository = Split-Path $PSScriptRoot -Parent
$capturePath = Join-Path $repository (
    'tools\Start-Rz090528AllEffectsOracleCapture.ps1')
$analyzerPath = Join-Path $repository (
    'tools\Analyze-Rz090528AllEffectsOracle.ps1')
$captureSource = Get-Content -Raw -LiteralPath $capturePath
$analyzerSource = Get-Content -Raw -LiteralPath $analyzerPath

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

foreach ($scriptPath in @($capturePath, $analyzerPath)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath,
        [ref]$tokens,
        [ref]$errors)
    Assert-True ($errors.Count -eq 0) `
        "$([IO.Path]::GetFileName($scriptPath)) must parse in Windows PowerShell 5.1."
}

Assert-True (
    $captureSource -match [regex]::Escape('$DeviceAddress = 3') -and
    $captureSource -match [regex]::Escape('$usbPcapDevice = ''\\.\USBPcap2''')) `
    'The wrapper must target only the verified capture-plane address and controller.'
Assert-True (
    $captureSource -match 'CapturePlaneAddressVerifiedAtUtc' -and
    $captureSource -match 'TotalMinutes -gt 15' -and
    $captureSource -match 'USBPcap descriptor discovery') `
    'The wrapper must require a fresh USBPcap capture-plane address verification.'
Assert-True (
    $captureSource -match 'SkipServiceManagement' -and
    $captureSource -match 'SkipAdministratorCheck' -and
    $captureSource -match "Get-Service -Name OpenBlade" -and
    $captureSource -match "Get-Process -Name RazerAppEngine") `
    'The elevated child must preserve the established service and administrator safety gates.'
Assert-True (
    $captureSource -match 'Get-PnpDevice -PresentOnly' -and
    $captureSource -match 'PID_\$expectedProductId' -and
    $captureSource -match 'composite.Count -ne 1') `
    'The elevated child must independently confirm one exact present composite device.'
Assert-True (
    $captureSource -notmatch 'Serial|UUID|IdentifyingNumber') `
    'The wrapper must not collect unique device identifiers.'

foreach ($required in @(
        '$expectedModel = ''RZ09-0528''',
        '$expectedVendorId = ''1532''',
        '$expectedProductId = ''02C6''',
        '$expectedDeviceAddress = 3',
        '$expectedController = ''\\.\USBPcap2''')) {
    Assert-True ($analyzerSource -match [regex]::Escape($required)) `
        "The analyzer dropped exact-target gate '$required'."
}
Assert-True (
    $analyzerSource -match "state.status -cne 'Completed'" -and
    $analyzerSource -match "state.stopMode -cne 'Graceful'" -and
    $analyzerSource -match '@\(\$state.errors\)\.Count -ne 0') `
    'The analyzer must reject failed, incomplete, or non-graceful captures.'
Assert-True (
    $analyzerSource -match "finalUiState.keyboardEffect -cne 'Static'" -and
    $analyzerSource -match "finalUiState.keyboardColor -cne 'green'" -and
    $analyzerSource -match 'brightnessPercent -ne 50' -and
    $analyzerSource -match "finalUiState.logoMode -cne 'Static'") `
    'The analyzer must require the user-visible Static green 50% restoration.'
Assert-True (
    $analyzerSource -match "commandClass -ceq '03'" -and
    $analyzerSource -match "commandId -ceq '0B'" -and
    $analyzerSource -match "commandId -ceq '0A'" -and
    $analyzerSource -match "Substring\(16, 4\) -cne '0500'") `
    'The analyzer must validate the exact 03/0B rows and 03/0A 0500 latch.'
Assert-True (
    $analyzerSource -match '\[Security\.Cryptography\.SHA256\]::Create\(\)' -and
    $analyzerSource -notmatch 'Get-FileHash') `
    'The analyzer must use its Windows PowerShell 5.1-safe SHA-256 implementation.'

Write-Host 'RZ09-0528 all-effects oracle tooling tests passed.'
