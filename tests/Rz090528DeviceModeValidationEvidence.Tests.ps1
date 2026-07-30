$ErrorActionPreference = 'Stop'

$repository = Split-Path $PSScriptRoot -Parent
$fixturePath = Join-Path $repository (
    'decoded\rz09-0528-pid-02c6-bios-2.02-device-mode-validation.json')
$annotationPath = Join-Path $repository (
    'annotations\2026-07-29-rz09-0528-device-mode-validation-attempts.json')
$coveragePath = Join-Path $repository (
    'decoded\rz09-0528-pid-02c6-bios-2.02-device-coverage.json')
$wrapperPath = Join-Path $repository (
    'tools\Invoke-Rz090528DeviceModeValidation.ps1')

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

$fixture = Get-Content -Raw -LiteralPath $fixturePath | ConvertFrom-Json
$annotation = Get-Content -Raw -LiteralPath $annotationPath | ConvertFrom-Json
$coverage = Get-Content -Raw -LiteralPath $coveragePath | ConvertFrom-Json
$wrapper = Get-Content -Raw -LiteralPath $wrapperPath

Assert-True ($fixture.status -ceq 'ReversibleRoundTripCaptured') `
    'Device-mode evidence must retain the successful reversible round trip.'
Assert-True ($fixture.device.modelNumber -ceq 'RZ09-0528') `
    'Device-mode fixture model changed.'
Assert-True ($fixture.device.productIdHex -ceq '02C6') `
    'Device-mode fixture PID changed.'
Assert-True ($fixture.attempts.Count -eq 3) `
    'Both negative controls and the successful round trip must remain represented.'

$conflict = $fixture.attempts[0]
Assert-True ($conflict.result.failure -ceq 'conflict') `
    'The competing-controller negative control changed.'
Assert-True ($conflict.result.applyAttempted -eq $false) `
    'The conflict attempt must not claim a write.'

$isolated = $fixture.attempts[1]
Assert-True ($isolated.result.baselineMode -ceq 'Driver') `
    'The isolated exact baseline must remain Driver.'
Assert-True ($isolated.result.failure -ceq 'baselineNotNormal') `
    'The isolated fail-closed reason changed.'
Assert-True ($isolated.result.applyAttempted -eq $false) `
    'The isolated attempt must not claim a write.'
Assert-True ($isolated.result.restoreAttempted -eq $false) `
    'No-write negative evidence must not claim a restoration write.'

$roundTrip = $fixture.attempts[2]
Assert-True ($roundTrip.role -ceq 'IsolatedReversibleRoundTrip') `
    'The successful evidence role changed.'
Assert-True ($roundTrip.result.baselineMode -ceq 'Driver') `
    'The successful round trip must retain the exact Driver baseline.'
Assert-True ($roundTrip.result.candidateMode -ceq 'Normal') `
    'The successful candidate must remain Normal.'
Assert-True ($roundTrip.result.restoredMode -ceq 'Driver') `
    'The successful round trip must restore Driver.'
foreach ($requiredTrue in @(
        'applyAttempted',
        'applyAcknowledged',
        'candidateConfirmed',
        'visualCheckConfirmed',
        'restoreAttempted',
        'restoreAcknowledged',
        'restored')) {
    Assert-True ($roundTrip.result.$requiredTrue -eq $true) `
        "Successful round-trip field '$requiredTrue' must remain true."
}
Assert-True ($roundTrip.result.manualRecoveryRequired -eq $false) `
    'The successful round trip must not claim manual recovery.'
Assert-True ($roundTrip.result.failure -ceq 'none') `
    'The successful round trip must retain failure=none.'

foreach ($attempt in $fixture.attempts) {
    Assert-True ($attempt.validationOutputSha256 -match '^[0-9A-F]{64}$') `
        'A validation-output hash is malformed.'
    Assert-True ($attempt.stateSha256 -match '^[0-9A-F]{64}$') `
        'A state hash is malformed.'
    Assert-True ($attempt.servicesAfterAttempt.OpenBlade -ceq 'Running') `
        'OpenBlade service restoration evidence changed.'
    Assert-True (
        $attempt.servicesAfterAttempt.RazerElevationService -ceq 'Running') `
        'Razer Elevation Service restoration evidence changed.'
    Assert-True (
        $attempt.servicesAfterAttempt.RazerGameManagerService3 -ceq 'Running') `
        'Razer Game Manager service restoration evidence changed.'
}

Assert-True ($annotation.admission.productionMutation -ceq 'SetterValidated') `
    'Device-mode mutation must remain setter-validated but not production-admitted.'
Assert-True (
    $coverage.capabilities.keyboardBehavior.normalDeviceMode -ceq
        'SetterValidated') 'Normal mode setter validation must not regress.'
Assert-True (
    $coverage.capabilities.keyboardBehavior.driverDeviceMode -ceq
        'SetterValidated') 'Driver mode setter validation must not regress.'
Assert-True (
    $coverage.capabilities.keyboardBehavior.deviceModeGetter -ceq
        'ProductionAdmitted') 'The already-admitted getter must not regress.'
Assert-True ($fixture.privacy.rawSessionsCommitted -eq $false) `
    'Raw validation sessions must remain private.'
Assert-True (
    $roundTrip.validationOutputSha256 -ceq
        '964E683D4D98DB0E8CF41A17F3986A15C7C314933A614672841E21C00352D9AA') `
    'Successful validation-output provenance changed.'
Assert-True (
    $roundTrip.stateSha256 -ceq
        'D26C681265B1620D287FD53CA3F12C306B00F54DB666965CF887CE8E15D9D705') `
    'Successful wrapper-state provenance changed.'

foreach ($required in @(
        "'OpenBlade'",
        "'Razer Elevation Service'",
        "'Razer Game Manager Service 3'",
        "'RazerAppEngine'",
        'Stop-Service',
        'Stop-Process -Force',
        'Start-Service',
        'opposite the exact starting baseline',
        'exact starting mode',
        'finally')) {
    Assert-True ($wrapper.Contains($required)) `
        "Safety wrapper requirement '$required' is missing."
}

Write-Host 'RZ09-0528 device-mode validation evidence tests passed.'
