$ErrorActionPreference = 'Stop'

$repository = Split-Path $PSScriptRoot -Parent
$annotationPath = Join-Path $repository (
    'annotations\2026-07-29-rz09-0528-windows-lighting-handoff-validation.json')
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
$coverage = Get-Content -Raw -LiteralPath $coveragePath | ConvertFrom-Json
$evidence = Get-Content -Raw -LiteralPath $evidencePath | ConvertFrom-Json

Assert-True ($annotation.device.modelNumber -ceq 'RZ09-0528') `
    'Lighting handoff model changed.'
Assert-True ($annotation.device.productIdHex -ceq '02C6') `
    'Lighting handoff PID changed.'
Assert-True ($annotation.evidenceProvenance.visualStateUsedAsFirmwareReadback -eq $false) `
    'Visual UI state must not be promoted to firmware readback.'
Assert-True ($annotation.operatorCorrelatedSequence.Count -eq 5) `
    'The complete handoff and restart sequence must remain represented.'
Assert-True ($annotation.operatorCorrelatedSequence[1].independentReadback.rawValue -eq 0) `
    'The startup Off counterexample must remain explicit.'
Assert-True ($annotation.operatorCorrelatedSequence[3].independentReadback.rawValue -eq 128) `
    'The post-delegation Static 50 readback changed.'
Assert-True ($annotation.operatorCorrelatedSequence[4].independentReadback.rawValue -eq 128) `
    'The post-restart Static 50 readback changed.'
Assert-True ($annotation.finalState.openBladeKeyboardLightingControlMode -ceq
    'WindowsDynamicLighting') 'Final ownership must remain delegated to Windows.'
Assert-True ($annotation.finalState.restorationConfirmed -eq $true) `
    'Final Static 50 restoration must remain confirmed.'
Assert-True ($annotation.installerValidation.servicePreserved -eq $true) `
    'The same-version replacement must preserve the service.'
Assert-True ($coverage.capabilities.conflicts.windowsDynamicLightingDelegation -ceq
    'ProductionAdmitted') 'Windows lighting delegation coverage regressed.'
Assert-True (
    $evidence.annotations -contains
        '2026-07-29-rz09-0528-windows-lighting-handoff-validation.json') `
    'The exact-device evidence index dropped the handoff annotation.'
Assert-True ($annotation.evidenceProvenance.packetCapturePerformed -eq $false) `
    'The annotation must not imply an unperformed packet capture.'

Write-Host 'RZ09-0528 Windows lighting handoff evidence tests passed.'
