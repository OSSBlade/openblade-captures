$ErrorActionPreference = 'Stop'

$repository = Split-Path $PSScriptRoot -Parent
$annotationPath = Join-Path $repository (
    'annotations\2026-07-30-rz09-0528-gpu-clock-offset-validation.json')
$coveragePath = Join-Path $repository (
    'decoded\rz09-0528-pid-02c6-bios-2.02-device-coverage.json')

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

$annotation = Get-Content -Raw -LiteralPath $annotationPath | ConvertFrom-Json
$coverage = Get-Content -Raw -LiteralPath $coveragePath | ConvertFrom-Json

Assert-True ($annotation.schemaVersion -eq 1) `
    'GPU validation annotation schema changed.'
Assert-True ($annotation.device.modelNumber -ceq 'RZ09-0528') `
    'GPU validation model changed.'
Assert-True ($annotation.device.productIdHex -ceq '02C6') `
    'GPU validation PID changed.'
foreach ($guard in @(
        'confirmationMatched',
        'exactHost',
        'exactDevice',
        'synapseInactive',
        'openBladeServiceInactive',
        'recheckedImmediatelyBeforeMutation')) {
    Assert-True ($annotation.isolationGuards.$guard -eq $true) `
        "GPU validation isolation guard '$guard' must remain true."
}
Assert-True ($annotation.validation.baseline.coreMHz -eq 0) `
    'GPU core baseline changed.'
Assert-True ($annotation.validation.baseline.memoryMHz -eq 0) `
    'GPU memory baseline changed.'
Assert-True ($annotation.validation.requested.coreMHz -eq 1) `
    'GPU adjacent core request changed.'
Assert-True ($annotation.validation.requested.memoryMHz -eq 1) `
    'GPU adjacent memory request changed.'
Assert-True ($annotation.validation.applied -eq $false) `
    'The unconfirmed GPU write must not be represented as applied.'
Assert-True ($annotation.validation.readBack -eq $false) `
    'The unconfirmed GPU write must not be represented as read back.'
Assert-True ($annotation.validation.restored -eq $true) `
    'GPU baseline restoration must remain recorded.'
Assert-True ($annotation.validation.success -eq $false) `
    'The negative control must not be represented as successful.'
Assert-True (
    $annotation.validation.classification -ceq 'ReadbackNotConfirmedRestored') `
    'GPU failure classification changed.'
Assert-True (
    $annotation.admission.gpuClockOffsets -ceq 'QueryValidated') `
    'GPU offsets must remain query-validated.'
Assert-True (
    $annotation.admission.gpuOverclockAccess -ceq 'ObservedOnly') `
    'GPU overclock access must remain observed-only.'
Assert-True (
    $coverage.capabilities.performance.ac.gpuClockOffsets -ceq (
        'QueryValidated')) `
    'Coverage must not advance the GPU offset setter.'
Assert-True (
    $coverage.capabilities.performance.ac.gpuOverclockToggle -ceq 'Captured') `
    'Coverage must not advance the unowned GPU overclock toggle.'

foreach ($evidence in @(
        $annotation.privateEvidence.validationOutput,
        $annotation.privateEvidence.wrapperState)) {
    Assert-True ($evidence.sha256 -match '^[0-9A-F]{64}$') `
        'A private GPU evidence hash is malformed.'
    Assert-True ($evidence.byteLength -gt 0) `
        'A private GPU evidence length is missing.'
}
Assert-True ($annotation.privateEvidence.committed -eq $false) `
    'Private GPU validation outputs must remain uncommitted.'
Assert-True ($annotation.privacy.rawOutputsCommitted -eq $false) `
    'Raw GPU validation outputs must remain private.'
Assert-True ($annotation.privacy.serialNumbersRetained -eq $false) `
    'Sanitized GPU evidence must not retain serial numbers.'
Assert-True ($annotation.privacy.devicePathsRetained -eq $false) `
    'Sanitized GPU evidence must not retain device paths.'
Assert-True ($annotation.privacy.uniqueIdentifiersRetained -eq $false) `
    'Sanitized GPU evidence must not retain unique identifiers.'

Write-Host 'RZ09-0528 GPU clock-offset evidence tests passed.'
