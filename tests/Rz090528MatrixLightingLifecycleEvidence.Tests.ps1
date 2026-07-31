$ErrorActionPreference = 'Stop'

$repository = Split-Path $PSScriptRoot -Parent
$annotationPath = Join-Path $repository (
    'annotations\2026-07-30-rz09-0528-openblade-matrix-lighting-lifecycle.json')
$isolatedPath = Join-Path $repository (
    'annotations\2026-07-30-rz09-0528-openblade-matrix-lighting-validation.json')
$coveragePath = Join-Path $repository (
    'decoded\rz09-0528-pid-02c6-bios-2.02-device-coverage.json')
$evidencePath = Join-Path $repository (
    'decoded\rz09-0528-pid-02c6-bios-2.02-evidence.json')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

$annotation = Get-Content -Raw -LiteralPath $annotationPath | ConvertFrom-Json
$isolated = Get-Content -Raw -LiteralPath $isolatedPath | ConvertFrom-Json
$coverage = Get-Content -Raw -LiteralPath $coveragePath | ConvertFrom-Json
$evidence = Get-Content -Raw -LiteralPath $evidencePath | ConvertFrom-Json

Assert-True ($annotation.device.modelNumber -ceq 'RZ09-0528') `
    'Matrix lifecycle model changed.'
Assert-True ($annotation.device.productIdHex -ceq '02C6') `
    'Matrix lifecycle PID changed.'
Assert-True ($annotation.staticLifecycle.minimumHoldSeconds -ge 30) `
    'Static installed lifecycle hold regressed.'
Assert-True ($annotation.staticLifecycle.rendererOwnership -ceq 'Static') `
    'Static renderer ownership must remain confirmed.'
Assert-True ($annotation.staticLifecycle.writesBlocked -eq $false) `
    'Static must not leave production writes blocked.'
Assert-True ($annotation.spectrumLifecycle.initialTransitionAccepted -eq $true) `
    'The successful isolated Spectrum transition must not be dropped.'
Assert-True ($annotation.spectrumLifecycle.continuousRendererFaulted -eq $true) `
    'The installed Spectrum renderer failure must remain explicit.'
Assert-True ($annotation.spectrumLifecycle.matrixReadbackAvailable -eq $false) `
    'Spectrum visual state must not be promoted to matrix readback.'
Assert-True ($annotation.restoration.rendererOwnership -ceq 'Static') `
    'Static restoration ownership changed.'
Assert-True ($annotation.restoration.writesBlocked -eq $false) `
    'Static restoration must recover production writes.'
Assert-True ($annotation.admission.productionEffects.Count -eq 2) `
    'Unexpected PID 02C6 production effect count.'
Assert-True ($annotation.admission.productionEffects -contains 'Off') `
    'Off production admission regressed.'
Assert-True ($annotation.admission.productionEffects -contains 'Static') `
    'Static production admission regressed.'
Assert-True (
    $annotation.admission.setterValidatedButNotProductionAdmitted -contains
        'Spectrum') 'Spectrum must remain represented outside production.'
Assert-True ($isolated.admission.effects -notcontains 'Spectrum') `
    'The isolated annotation must not overstate Spectrum admission.'
Assert-True (
    $isolated.admission.setterValidatedButNotAdmitted -contains 'Spectrum') `
    'The isolated Spectrum setter evidence was dropped.'
Assert-True (
    $coverage.capabilities.keyboardLighting.effects.static.base -ceq
        'ProductionAdmitted') 'Static base admission regressed.'
Assert-True (
    $coverage.capabilities.keyboardLighting.effects.static.colors -ceq
        'ProductionAdmitted') 'Static color admission regressed.'
Assert-True (
    $coverage.capabilities.keyboardLighting.effects.spectrum.base -ceq
        'SetterValidated') 'Spectrum setter validation was lost.'
foreach ($leaf in @('hostColorSequence', 'frameCadence')) {
    Assert-True (
        $coverage.capabilities.keyboardLighting.effects.spectrum.$leaf -ceq
            'Captured') "Spectrum $leaf must remain captured."
}
foreach ($fileName in @(
        '2026-07-30-rz09-0528-openblade-matrix-lighting-validation.json',
        '2026-07-30-rz09-0528-openblade-matrix-lighting-lifecycle.json')) {
    Assert-True ($evidence.annotations -contains $fileName) `
        "The evidence index dropped $fileName."
}
foreach ($hash in @(
        $annotation.evidenceProvenance.successfulDeploymentReportSha256,
        $annotation.staticLifecycle.snapshotSha256,
        $annotation.staticLifecycle.reportSha256,
        $annotation.staticLifecycle.diagnosticsSha256,
        $annotation.spectrumLifecycle.snapshotSha256,
        $annotation.spectrumLifecycle.reportSha256,
        $annotation.spectrumLifecycle.diagnosticsSha256,
        $annotation.restoration.serviceRestartReportSha256,
        $annotation.restoration.snapshotSha256,
        $annotation.restoration.reportSha256,
        $annotation.restoration.diagnosticsSha256)) {
    Assert-True ([string]$hash -cmatch '^[0-9A-F]{64}$') `
        'A private lifecycle artifact hash is malformed.'
}
Assert-True ($annotation.evidenceProvenance.rawArtifactsCommitted -eq $false) `
    'Private lifecycle artifacts must not be committed.'
Assert-True ($annotation.evidenceProvenance.packetCapturePerformed -eq $false) `
    'The lifecycle annotation must not imply an unperformed packet capture.'

Write-Host 'RZ09-0528 matrix lighting lifecycle evidence tests passed.'
