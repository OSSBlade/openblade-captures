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

Assert-True ($fixture.status -ceq 'NegativeControlNoWrite') `
    'Device-mode attempts must remain explicit negative controls.'
Assert-True ($fixture.device.modelNumber -ceq 'RZ09-0528') `
    'Device-mode fixture model changed.'
Assert-True ($fixture.device.productIdHex -ceq '02C6') `
    'Device-mode fixture PID changed.'
Assert-True ($fixture.attempts.Count -eq 2) `
    'Both failed device-mode attempts must remain represented.'

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

Assert-True ($annotation.admission.productionMutation -ceq 'Blocked') `
    'Device-mode mutation must remain blocked.'
Assert-True (
    $coverage.capabilities.keyboardBehavior.normalDeviceMode -ceq
        'NotInvestigated') 'Normal mode must remain unadmitted.'
Assert-True (
    $coverage.capabilities.keyboardBehavior.driverDeviceMode -ceq
        'NotInvestigated') 'Driver mode mutation must remain unadmitted.'
Assert-True (
    $coverage.capabilities.keyboardBehavior.deviceModeGetter -ceq
        'ProductionAdmitted') 'The already-admitted getter must not regress.'
Assert-True ($fixture.privacy.rawSessionsCommitted -eq $false) `
    'Raw validation sessions must remain private.'

foreach ($required in @(
        "'OpenBlade'",
        "'Razer Elevation Service'",
        "'Razer Game Manager Service 3'",
        "'RazerAppEngine'",
        'Stop-Service',
        'Stop-Process -Force',
        'Start-Service',
        'finally')) {
    Assert-True ($wrapper.Contains($required)) `
        "Safety wrapper requirement '$required' is missing."
}

Write-Host 'RZ09-0528 device-mode validation evidence tests passed.'
