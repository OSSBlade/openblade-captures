[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$hyperBoostPath = Join-Path $repository `
    'annotations\2026-08-09-rz09-0581-hyperboost-write-validation-repeat.json'
$fixedPath = Join-Path $repository `
    'annotations\2026-08-09-rz09-0581-cooling-pad-fixed-write-synapse-recovery.json'
$fixedPhysicalPath = Join-Path $repository `
    'annotations\2026-08-09-rz09-0581-cooling-pad-fixed-write-physical-positive.json'
$hostControlPath = Join-Path $repository `
    'annotations\2026-08-09-rz09-0581-cooling-pad-host-control-physical-positive.json'
$observationsPath = Join-Path $repository `
    'decoded\rz09-0581-pid-02e0-bios-4.00-cooling-pad-protocol-observations.json'
$validator = Join-Path $repository 'tools\Test-CaptureEvidence.ps1'
$hyperBoost = Get-Content -LiteralPath $hyperBoostPath -Raw | ConvertFrom-Json
$fixed = Get-Content -LiteralPath $fixedPath -Raw | ConvertFrom-Json
$fixedPhysical = Get-Content -LiteralPath $fixedPhysicalPath -Raw | ConvertFrom-Json
$hostControl = Get-Content -LiteralPath $hostControlPath -Raw | ConvertFrom-Json
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
& $validator -AnnotationPath $fixedPhysicalPath -SchemaOnly | Out-Null
& $validator -AnnotationPath $hostControlPath -SchemaOnly | Out-Null

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

Assert-True ($fixedPhysical.evidenceProvenance.controller -ceq `
        'OpenBlade.Capture 0.5.0+1c9a4dcdb4d0b627f7b9d05dbb2e59aa889d1d85' -and
    $fixedPhysical.evidenceProvenance.role -ceq 'NegativeCapture' -and
    $fixedPhysical.evidenceProvenance.openBladeTypedApplyPerformed -eq $true -and
    $fixedPhysical.evidenceProvenance.openBladeReadbackConfirmed -eq $false) `
    'The physical-positive Fixed validation lost its exact negative-readback provenance.'
Assert-True ($fixedPhysical.capture.sha256 -ceq `
        '46445B67DF76688EB0D058124B690C35D25EC8E704AD42098BB46379ACC5E2F6' -and
    $fixedPhysical.capture.byteLength -eq 658) `
    'The physical-positive Fixed validation transcript identity changed.'
$physicalApply = @($fixedPhysical.sanitizedEvidence |
    Where-Object kind -ceq 'Fixed2200PhysicalApplyPositive')
$getterNegative = @($fixedPhysical.sanitizedEvidence |
    Where-Object kind -ceq 'ConfiguredTargetGetterNegative')
$managedRecovery = @($fixedPhysical.sanitizedEvidence |
    Where-Object kind -ceq 'SynapseManagedAutoRecovery')
Assert-True ($physicalApply.Count -eq 1 -and
    $physicalApply[0].fixedSetterSemanticPayloadHex -ceq '01022C' -and
    $physicalApply[0].fixedSetterAcknowledged -eq $true -and
    $physicalApply[0].operatorPhysicalApplyConfirmed -eq $true -and
    $physicalApply[0].fixedWriteCount -eq 1 -and
    $physicalApply[0].openBladeAutomaticControlWriteCount -eq 0) `
    'The physically confirmed Fixed 2200 apply evidence changed.'
Assert-True ($getterNegative.Count -eq 1 -and
    $getterNegative[0].postWriteConfiguredTargetNormalizedNull -eq $true -and
    $getterNegative[0].postWriteFailureClassification -ceq 'post-read-zero' -and
    $getterNegative[0].targetReadbackConfirmed -eq $false -and
    $getterNegative[0].activeModeReadbackConfirmed -eq $false -and
    $getterNegative[0].tachometerReadbackConfirmed -eq $false) `
    'The configured-target negative result must remain distinct from physical success.'
Assert-True ($managedRecovery.Count -eq 1 -and
    $managedRecovery[0].operatorConfirmedSynapseManagedAuto -eq $true -and
    $managedRecovery[0].synapseRecoveryRequired -eq $true -and
    $managedRecovery[0].openBladeRecoveryWritePerformed -eq $false -and
    $managedRecovery[0].independentRestorationReadbackConfirmed -eq $false) `
    'The vendor-managed recovery must not be represented as an OpenBlade restore.'
Assert-True ($fixedPhysical.productionAdmission.fixed2200PhysicalApplyValidated -eq $true -and
    $fixedPhysical.productionAdmission.fixed2200ConfiguredTargetReadbackConfirmed -eq $false -and
    $fixedPhysical.productionAdmission.synapseManagedAutoRecoveryConfirmed -eq $true -and
    $fixedPhysical.productionAdmission.openBladeAutomaticControlHandbackValidated -eq $false -and
    $fixedPhysical.productionAdmission.coolingPadFanWriteAdmitted -eq $false) `
    'Physical Fixed validation must not admit production fan mutation.'
Assert-True ((@($fixedPhysical.limitations) -join ' ') -match 'active controller' -and
    (@($fixedPhysical.limitations) -join ' ') -match 'not an OpenBlade restoration') `
    'The evidence must preserve the Synapse-managed Auto control boundary.'

Assert-True ($hostControl.evidenceProvenance.controller -ceq `
        'OpenBlade.Capture 0.5.0+4bbb3b3445e42ba50f2e73104b96804eeeebb2b1' -and
    $hostControl.evidenceProvenance.role -ceq 'NegativeCapture' -and
    $hostControl.evidenceProvenance.openBladeTypedApplyPerformed -eq $true -and
    $hostControl.evidenceProvenance.openBladeReadbackConfirmed -eq $false) `
    'The host-control physical validation lost its exact provenance boundary.'
Assert-True ($hostControl.capture.sha256 -ceq `
        'A456A3CFD300840E5B385163BBF6EEAD4AD5FD6FE6E1F5A1650DAC036E22CEC7' -and
    $hostControl.capture.byteLength -eq 745) `
    'The host-control validation transcript identity changed.'
$sequence = @($hostControl.sanitizedEvidence |
    Where-Object kind -ceq 'BoundedHostControlSequence')
$physicalResponse = @($hostControl.sanitizedEvidence |
    Where-Object kind -ceq 'OperatorPhysicalResponse')
$hostRecovery = @($hostControl.sanitizedEvidence |
    Where-Object kind -ceq 'SynapseUiRecovery')
Assert-True ($sequence.Count -eq 1 -and
    $sequence[0].automaticStateSemanticPayloadHex -ceq '000600' -and
    $sequence[0].automaticStateWriteCount -eq 1 -and
    $sequence[0].automaticStateAcknowledged -eq $true -and
    $sequence[0].hostDemandSemanticPayloadHex -ceq '01052C' -and
    $sequence[0].hostDemandTargetRpm -eq 2200 -and
    $sequence[0].hostDemandWriteCount -eq 1 -and
    $sequence[0].hostDemandAcknowledged -eq $true -and
    $sequence[0].retryCount -eq 0 -and
    $sequence[0].openBladeCleanupWriteCount -eq 0) `
    'The exact two-command host-control sequence changed.'
Assert-True ($physicalResponse.Count -eq 1 -and
    $physicalResponse[0].operatorPhysicalFanResponseConfirmed -eq $true -and
    $physicalResponse[0].activeModeReadbackConfirmed -eq $false -and
    $physicalResponse[0].hostDemandReadbackConfirmed -eq $false -and
    $physicalResponse[0].tachometerReadbackConfirmed -eq $false) `
    'The physical response must remain distinct from typed readback.'
Assert-True ($hostRecovery.Count -eq 1 -and
    $hostRecovery[0].razerServicesRestored -eq $true -and
    $hostRecovery[0].operatorConfirmedSynapseAutoUi -eq $true -and
    $hostRecovery[0].openBladeRestorationWritePerformed -eq $false) `
    'Vendor UI recovery must not be represented as OpenBlade restoration.'
Assert-True ($hostControl.productionAdmission.coolingPadFanWriteAdmitted -eq $false -and
    $hostControl.productionAdmission.standaloneAutomaticStateWriteAdmitted -eq $false -and
    $hostControl.productionAdmission.automaticStatePlusHostDemandSequenceObserved -eq $true -and
    $hostControl.productionAdmission.hostDemand2200PhysicalApplyValidated -eq $true -and
    $hostControl.productionAdmission.hostDemandRangeValidated -eq $false -and
    $hostControl.productionAdmission.smartCurveCadenceValidated -eq $false -and
    $hostControl.productionAdmission.openBladeRestorationValidated -eq $false) `
    'The host-control trial must not admit a production writer.'

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
