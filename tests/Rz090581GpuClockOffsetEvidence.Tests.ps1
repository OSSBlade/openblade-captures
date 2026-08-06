$ErrorActionPreference = 'Stop'

$repository = Split-Path $PSScriptRoot -Parent
$annotationPath = Join-Path $repository (
    'annotations\2026-08-06-rz09-0581-gpu-clock-offset-validation.json')
$evidencePath = Join-Path $repository (
    'decoded\rz09-0581-pid-02e0-bios-4.00-gpu-clock-offset-evidence.json')

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
$evidence = Get-Content -Raw -LiteralPath $evidencePath | ConvertFrom-Json

Assert-True ($annotation.schemaVersion -eq 1) `
    'GPU validation annotation schema changed.'
Assert-True ($evidence.schemaVersion -eq 1) `
    'GPU evidence ledger schema changed.'
Assert-True (
    $annotation.device.modelNumber -ceq 'RZ09-0581' -and
    $annotation.device.vendorIdHex -ceq '1532' -and
    $annotation.device.productIdHex -ceq '02E0' -and
    $annotation.device.bios -ceq '4.00') `
    'GPU validation exact-device identity changed.'
Assert-True (
    $evidence.device.modelNumber -ceq $annotation.device.modelNumber -and
    $evidence.device.productIdHex -ceq $annotation.device.productIdHex -and
    $evidence.device.bios -ceq $annotation.device.bios) `
    'The decoded GPU evidence no longer matches its annotation.'
Assert-True (
    $evidence.annotation -ceq (
        '2026-08-06-rz09-0581-gpu-clock-offset-validation.json')) `
    'The decoded GPU evidence dropped its source annotation.'

foreach ($guard in @(
        'exactHost',
        'exactDevice',
        'synapseInactive',
        'openBladeServiceInactiveDuringMutation',
        'afterburnerInactive',
        'rtssInactive',
        'recheckedImmediatelyBeforeEachMutation')) {
    Assert-True ($annotation.isolationGuards.$guard -eq $true) `
        "GPU validation isolation guard '$guard' must remain true."
}

$api = $annotation.nvidiaApiComparison
Assert-True (
    $api.nvapiEditableP0.coreMinimumMHz -eq -1000 -and
    $api.nvapiEditableP0.coreMaximumMHz -eq 1000 -and
    $api.nvapiEditableP0.memoryMinimumMHz -eq -1000 -and
    $api.nvapiEditableP0.memoryMaximumMHz -eq 3000) `
    'The NVAPI editable P0 ranges changed.'
Assert-True (
    $api.nvmlRaw.coreMinimumMHz -eq -1000 -and
    $api.nvmlRaw.coreMaximumMHz -eq 1000 -and
    $api.nvmlRaw.memoryMinimumMHz -eq -2000 -and
    $api.nvmlRaw.memoryMaximumMHz -eq 6000) `
    'The raw NVML ranges changed.'
Assert-True (
    $api.representation.coreNvmlMultiplier -eq 1 -and
    $api.representation.memoryNvmlMultiplier -eq 2) `
    'The exact-device NVIDIA API representation changed.'

$crossApi = $api.crossApiReadback
Assert-True (
    $crossApi.baselineNvml.coreMHz -eq 0 -and
    $crossApi.baselineNvml.memoryMHz -eq 0 -and
    $crossApi.baselineNvapi.coreMHz -eq 0 -and
    $crossApi.baselineNvapi.memoryMHz -eq 0) `
    'The cross-API baseline changed.'
Assert-True (
    $crossApi.appliedNvml.coreMHz -eq 15 -and
    $crossApi.appliedNvml.memoryMHz -eq 30 -and
    $crossApi.appliedNvapi.coreMHz -eq 15 -and
    $crossApi.appliedNvapi.memoryMHz -eq 15 -and
    $crossApi.mappingConfirmed -eq $true) `
    'The cross-API memory conversion proof changed.'
Assert-True (
    $crossApi.restoredNvml.coreMHz -eq 0 -and
    $crossApi.restoredNvml.memoryMHz -eq 0 -and
    $crossApi.restoredNvapi.coreMHz -eq 0 -and
    $crossApi.restoredNvapi.memoryMHz -eq 0 -and
    $crossApi.restored -eq $true) `
    'The cross-API restoration proof changed.'

$minimumStep = $api.minimumUiStepValidation
Assert-True (
    $minimumStep.requestedLogical.coreMHz -eq 5 -and
    $minimumStep.requestedLogical.memoryMHz -eq 5 -and
    $minimumStep.appliedLogical.coreMHz -eq 5 -and
    $minimumStep.appliedLogical.memoryMHz -eq 5 -and
    $minimumStep.restoredLogical.coreMHz -eq 0 -and
    $minimumStep.restoredLogical.memoryMHz -eq 0 -and
    $minimumStep.readBack -eq $true -and
    $minimumStep.restored -eq $true) `
    'The minimum UI-step validation proof changed.'
Assert-True (
    $evidence.validation.minimumUiStepMHz -eq 5 -and
    $evidence.validation.minimumUiStepValidation.readbackConfirmed -eq $true -and
    $evidence.validation.minimumUiStepValidation.restored -eq $true) `
    'The decoded evidence dropped the validated minimum UI step.'

$expectedModes = @('Balanced', 'Silent', 'Performance')
Assert-True ($annotation.performanceModeValidation.Count -eq 3) `
    'The GPU performance-mode matrix changed.'
for ($index = 0; $index -lt $expectedModes.Count; $index++) {
    $mode = $annotation.performanceModeValidation[$index]
    Assert-True ($mode.mode -ceq $expectedModes[$index]) `
        "GPU validation mode $index changed."
    Assert-True (
        $mode.requestedLogical.coreMHz -eq 15 -and
        $mode.requestedLogical.memoryMHz -eq 15 -and
        $mode.readBack -eq $true -and
        $mode.restoredToZero -eq $true) `
        "GPU validation for $($mode.mode) lost readback or restoration."
}

Assert-True (
    $annotation.finalState.performance -ceq 'Balanced' -and
    $annotation.finalState.coreOffsetMHz -eq 0 -and
    $annotation.finalState.memoryOffsetMHz -eq 0) `
    'The final GPU or performance baseline changed.'
Assert-True (
    $annotation.admission.gpuOverclockAccess -ceq 'ReadWrite' -and
    $annotation.admission.biosScope -ceq '4.00' -and
    $annotation.admission.policyCoreMinimumMHz -eq -1000 -and
    $annotation.admission.policyCoreMaximumMHz -eq 400 -and
    $annotation.admission.policyMemoryMinimumMHz -eq -1000 -and
    $annotation.admission.policyMemoryMaximumMHz -eq 3000 -and
    $annotation.admission.supportsEnableDisable -eq $true) `
    'The exact BIOS 4.00 GPU-overclock admission changed.'

Assert-True (
    $annotation.evidenceProvenance.openBladeTypedApplyPerformed -eq $false -and
    $annotation.evidenceProvenance.openBladeReadbackConfirmed -eq $false -and
    $annotation.evidenceProvenance.openBladeRestorationConfirmed -eq $false -and
    $annotation.evidenceProvenance.captureRunnerReadbackConfirmed -eq $true -and
    $annotation.evidenceProvenance.captureRunnerRestorationConfirmed -eq $true) `
    'GPU evidence provenance no longer distinguishes the validation runner.'
Assert-True (
    $annotation.privacy.rawOutputsCommitted -eq $false -and
    $annotation.privacy.serialNumbersRetained -eq $false -and
    $annotation.privacy.devicePathsRetained -eq $false -and
    $annotation.privacy.userProfileNamesRetained -eq $false -and
    $annotation.privacy.uniqueIdentifiersRetained -eq $false) `
    'Sanitized GPU evidence retained private machine data.'

Write-Host 'RZ09-0581 GPU clock-offset evidence tests passed.'
