[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$hyperBoostPath = Join-Path $repository `
    'annotations\2026-08-09-rz09-0581-hyperboost-write-validation-repeat.json'
$fixedPath = Join-Path $repository `
    'annotations\2026-08-09-rz09-0581-cooling-pad-fixed-write-synapse-recovery.json'
$observationsPath = Join-Path $repository `
    'decoded\rz09-0581-pid-02e0-bios-4.00-cooling-pad-protocol-observations.json'
$validator = Join-Path $repository 'tools\Test-CaptureEvidence.ps1'
$hyperBoost = Get-Content -LiteralPath $hyperBoostPath -Raw | ConvertFrom-Json
$fixed = Get-Content -LiteralPath $fixedPath -Raw | ConvertFrom-Json
$observations = Get-Content -LiteralPath $observationsPath -Raw | ConvertFrom-Json

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

& $validator -AnnotationPath $hyperBoostPath -SchemaOnly | Out-Null
& $validator -AnnotationPath $fixedPath -SchemaOnly | Out-Null

Assert-True ($hyperBoost.evidenceProvenance.controller -ceq `
        'OpenBlade.Capture 0.5.0+68085fa7a19dfd02a7edd8f78d258c8479c5414e') `
    'The repeated HyperBoost evidence lost its exact controller revision.'
Assert-True ($hyperBoost.capture.sha256 -ceq `
        '7F439C7C2EF0E09B24477081C36EDC271AB1AF6861CF9EADADBCF3D5E9820755') `
    'The repeated HyperBoost transcript hash changed unexpectedly.'
$repeatApply = @($hyperBoost.sanitizedEvidence |
    Where-Object kind -ceq 'RepeatApplyAndReadback')
$repeatRestore = @($hyperBoost.sanitizedEvidence |
    Where-Object kind -ceq 'RepeatRestoration')
Assert-True ($repeatApply.Count -eq 1 -and
    $repeatApply[0].candidateThermal1Hex -ceq '01010700' -and
    $repeatApply[0].candidateThermal2Hex -ceq '01020700' -and
    $repeatApply[0].candidateConfirmed -eq $true) `
    'The repeated paired mode-7 readback changed.'
Assert-True ($repeatRestore.Count -eq 1 -and
    $repeatRestore[0].restorationThermal1Hex -ceq '01010000' -and
    $repeatRestore[0].restorationThermal2Hex -ceq '01020000' -and
    $repeatRestore[0].restored -eq $true) `
    'The repeated Balanced restoration evidence changed.'
Assert-True ($hyperBoost.productionAdmission.hyperBoostWriteAdmitted -eq $true -and
    $hyperBoost.productionAdmission.padLessActivationAdmitted -eq $false -and
    $hyperBoost.productionAdmission.coolingPadFanWriteAdmitted -eq $false) `
    'The repeat evidence widened the reviewed admission boundary.'

Assert-True ($fixed.evidenceProvenance.role -ceq 'NegativeCapture' -and
    $fixed.evidenceProvenance.openBladeTypedApplyPerformed -eq $true -and
    $fixed.evidenceProvenance.openBladeReadbackConfirmed -eq $false) `
    'The Fixed-only trial must remain typed negative evidence.'
Assert-True ($fixed.capture.sha256 -ceq `
        '364FC56744ED1665937B3C033044B6D33071D6671C2B21725C4AD0D5C4BEF4B2') `
    'The Fixed-only validation transcript hash changed unexpectedly.'
$fixedApply = @($fixed.sanitizedEvidence |
    Where-Object kind -ceq 'FixedOnlyApplyNegative')
$postRecovery = @($fixed.sanitizedEvidence |
    Where-Object kind -ceq 'IndependentPostRecoveryReadback')
Assert-True ($fixedApply.Count -eq 1 -and
    $fixedApply[0].fixedSetterSemanticPayloadHex -ceq '01022C' -and
    $fixedApply[0].fixedSetterAcknowledged -eq $true -and
    $fixedApply[0].postWriteConfiguredTargetRpm -eq 1550 -and
    $fixedApply[0].openBladeAutoWriteCount -eq 0) `
    'The bounded Fixed-only negative result changed.'
Assert-True ($postRecovery.Count -eq 1 -and
    $postRecovery[0].configuredTargetResponseHex -ceq '010500' -and
    $postRecovery[0].configuredTargetRpm -eq 0 -and
    $postRecovery[0].firmwareBankResponseHex -ceq '0006' -and
    $postRecovery[0].synapseBankResponseHex -ceq '01022C' -and
    $postRecovery[0].activeModeReadbackConfirmed -eq $false) `
    'The independent Synapse-recovery readback changed.'
Assert-True ($fixed.productionAdmission.coolingPadFanWriteAdmitted -eq $false -and
    $fixed.productionAdmission.synapseAutoRecoveryConfirmed -eq $true -and
    $fixed.productionAdmission.openBladeAutoHandbackValidated -eq $false) `
    'The Fixed-only trial must not admit a production fan writer.'

$direct = $observations.fan.readback.configuredTargetGetter.directFixedWriteTrial
Assert-True ($direct.baselineConfiguredTarget -eq 1600 -and
    $direct.postWriteConfiguredTarget -eq 1550 -and
    $direct.postRecoveryConfiguredTarget -eq 0 -and
    $direct.expectedTargetConfirmed -eq $false -and
    $direct.openBladeAutoWritePerformed -eq $false -and
    $direct.synapseBootAutoOperatorConfirmed -eq $true -and
    $direct.productionWriteAdmitted -eq $false) `
    'The decoded Fixed-only trial summary changed.'

Write-Host 'Cooling-pad write-validation evidence tests passed.'
