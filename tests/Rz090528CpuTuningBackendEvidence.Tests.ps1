$ErrorActionPreference = 'Stop'

$repository = Split-Path $PSScriptRoot -Parent
$annotationPath = Join-Path $repository (
    'annotations\2026-07-30-rz09-0528-cpu-tuning-backend-static-analysis.json')
$coveragePath = Join-Path $repository (
    'decoded\rz09-0528-pid-02c6-bios-2.02-device-coverage.json')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

$annotation = Get-Content -Raw -LiteralPath $annotationPath | ConvertFrom-Json
$coverage = Get-Content -Raw -LiteralPath $coveragePath | ConvertFrom-Json

Assert-True ($annotation.device.modelNumber -ceq 'RZ09-0528') `
    'CPU backend evidence model changed.'
Assert-True ($annotation.device.productIdHex -ceq '02C6') `
    'CPU backend evidence PID changed.'
Assert-True ($annotation.evidenceProvenance.nativeLibraryLoaded -eq $false) `
    'Static inspection must not imply that the vendor library was loaded.'
Assert-True ($annotation.evidenceProvenance.backendFunctionInvoked -eq $false) `
    'Static inspection must not imply a backend function call.'
Assert-True ($annotation.evidenceProvenance.settingChanged -eq $false) `
    'Static inspection must not imply a setting change.'

foreach ($hash in @(
        $annotation.backend.verifiedComponentHashes.clientSha256,
        $annotation.backend.verifiedComponentHashes.serverSha256,
        $annotation.backend.verifiedComponentHashes.serviceSha256)) {
    Assert-True ($hash -match '^[0-9A-F]{64}$') `
        'A verified CPU backend component hash is malformed.'
}

foreach ($symbol in @(
        'GetPowerLimitValueAsync',
        'SetPowerLimitValueAsync',
        'GetCurveOptimizerValueAsync',
        'SetCurveOptimizerValueAsync',
        'DeviceInit',
        'DeviceTerminate',
        'RegisterFFIEvent',
        'UnRegisterFFIEvent',
        'CloseAPPServer')) {
    Assert-True (@($annotation.backend.clientApiSymbols) -contains $symbol) `
        "CPU backend discovery dropped '$symbol'."
}
Assert-True (
    @($annotation.backend.serverEmbeddedSymbols) -contains
        'RzAMDOverClockDLL::EnableCPUVoltageOptimizer') `
    'The separately discovered optimizer enable feature was dropped.'
Assert-True (
    @($annotation.backend.serverEmbeddedSymbols) -contains
        'RzAMDOverClockDLL::ResetVoltageOffset') `
    'The separately discovered optimizer reset feature was dropped.'
Assert-True (
    $annotation.nextSafeExperiment.name -ceq 'PreconnectThenIsolate') `
    'The next CPU lifecycle experiment changed.'
Assert-True ($annotation.admission.productionAccess -ceq 'ObservedOnly') `
    'Static inspection must not admit CPU tuning writes.'
Assert-True ($annotation.admission.advancedByThisInspection -eq $false) `
    'Static inspection must not advance CPU tuning coverage.'
Assert-True (
    $coverage.capabilities.performance.ac.cpuPowerLimitWatts -ceq 'Captured') `
    'CPU Power Limit coverage must remain Captured.'
Assert-True (
    $coverage.capabilities.performance.ac.cpuVoltageOptimizer -ceq 'Captured') `
    'CPU Voltage Optimizer coverage must remain Captured.'
Assert-True ($annotation.privacy.binaryCommitted -eq $false) `
    'Vendor binaries must not be committed.'
Assert-True ($annotation.privacy.serialNumbersRetained -eq $false) `
    'Sanitized CPU backend evidence must not retain serial numbers.'
Assert-True ($annotation.privacy.devicePathsRetained -eq $false) `
    'Sanitized CPU backend evidence must not retain device paths.'

Write-Host 'RZ09-0528 CPU tuning backend evidence tests passed.'
