[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$annotationPath = Join-Path $repository `
    'annotations\2026-08-09-rz09-0581-cooling-pad-fan-context-isolation.json'
$validator = Join-Path $repository 'tools\Test-CaptureEvidence.ps1'
$annotation = Get-Content -LiteralPath $annotationPath -Raw | ConvertFrom-Json

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

& $validator -AnnotationPath $annotationPath -SchemaOnly | Out-Null

Assert-True ($annotation.evidenceProvenance.controller -ceq `
        'Razer Synapse 4.0.698.98 with OpenBlade capture tooling 05c6aee' -and
    $annotation.evidenceProvenance.role -ceq 'OracleCapture' -and
    $annotation.evidenceProvenance.openBladeTypedApplyPerformed -eq $false) `
    'The context-isolation evidence lost its exact vendor provenance.'
Assert-True ($annotation.capture.sha256 -ceq `
        '7F3D2DDB203A65FF986518B42772B5D9A9E989791CD966110E8E9E362BCB7E1C' -and
    $annotation.capture.byteLength -eq 8046) `
    'The sanitized split-analysis identity changed.'

$sources = @($annotation.sanitizedEvidence |
    Where-Object kind -ceq 'SplitCaptureProvenance')
$retained = @($annotation.sanitizedEvidence |
    Where-Object kind -ceq 'RetainedLitVendorTransitions')
$dark = @($annotation.sanitizedEvidence |
    Where-Object kind -ceq 'PhysicallyDarkZeroFrameVendorTransitions')
$fresh = @($annotation.sanitizedEvidence |
    Where-Object kind -ceq 'FreshSynapseProcessVendorTransitions')
$conclusions = @($annotation.sanitizedEvidence |
    Where-Object kind -ceq 'ContextIsolationConclusions')

Assert-True ($sources.Count -eq 1 -and
    $sources[0].retainedAndDarkCaptureSha256 -ceq `
        '1B49C8FF1206870C03860EE8A63C8543A25FF73891371D4FA7E471A0523F3DAC' -and
    $sources[0].retainedAndDarkDecodedTransactionCount -eq 1845 -and
    $sources[0].freshSessionCaptureSha256 -ceq `
        '78CE87B3F074CDFA3D677AC8C5976154D4FE48905B44B254AD8879F1A1EBCD7C' -and
    $sources[0].freshSessionDecodedTransactionCount -eq 2270) `
    'The private source identities or bounded transaction counts changed.'
Assert-True ($retained.Count -eq 1 -and
    $retained[0].lightingFrameRequestCount -eq 745 -and
    $retained[0].fixed2200SemanticPayloadHex -ceq '01022C' -and
    $retained[0].fixed2200TransactionMatched -eq $true -and
    $retained[0].fixedWindowOtherAcknowledgedVendorPairCount -eq 1 -and
    $retained[0].synapseManagedAutoSemanticPayloadHex -ceq '000600' -and
    $retained[0].synapseManagedAutoTransactionMatched -eq $true) `
    'The retained-lit vendor context changed.'
Assert-True ($dark.Count -eq 1 -and
    $dark[0].operatorConfirmedPhysicallyDark -eq $true -and
    $dark[0].lightingFrameRequestCount -eq 0 -and
    $dark[0].fixed2200TransactionMatched -eq $true -and
    $dark[0].synapseManagedAutoTransactionMatched -eq $true) `
    'The physically dark zero-frame context changed.'
Assert-True ($fresh.Count -eq 1 -and
    $fresh[0].freshRazerAppEngineProcessSessionObserved -eq $true -and
    $fresh[0].lightingFrameRequestCount -eq 745 -and
    $fresh[0].fixed2200TransactionMatched -eq $true -and
    $fresh[0].synapseManagedAutoTransactionMatched -eq $true) `
    'The fresh Synapse process context changed.'
Assert-True ($conclusions.Count -eq 1 -and
    $conclusions[0].continuousLightingFramesRequiredForVendorUiTransitions -eq $false -and
    $conclusions[0].priorSynapseProcessSessionRequiredForVendorUiTransitions -eq $false -and
    $conclusions[0].hidHandleRetentionDetermined -eq $false -and
    $null -eq $conclusions[0].hidHandleRetentionRequired -and
    $conclusions[0].synapseManagedAutoFirmwareOwnershipConfirmed -eq $false -and
    $conclusions[0].activeModeReadbackConfirmed -eq $false -and
    $conclusions[0].physicalFanSpeedReadbackConfirmed -eq $false -and
    $conclusions[0].openBladeWritePerformed -eq $false -and
    $conclusions[0].productionWriteAdmitted -eq $false) `
    'The split-context semantic boundary changed.'
Assert-True ($annotation.productionAdmission.coolingPadFanWriteAdmitted -eq $false -and
    $annotation.productionAdmission.continuousLightingFramesRequired -eq $false -and
    $annotation.productionAdmission.priorSynapseProcessSessionRequired -eq $false -and
    $annotation.productionAdmission.hidHandleRetentionRequirementResolved -eq $false) `
    'Context isolation must not admit a production writer.'

$serialized = $annotation | ConvertTo-Json -Depth 20
foreach ($forbidden in @(
    'C:\\',
    'Users\\',
    'devicePath',
    'serialNumber',
    'processId')) {
    Assert-True ($serialized -notmatch [regex]::Escape($forbidden)) `
        "The annotation leaked forbidden local evidence: $forbidden"
}

Write-Host 'Cooling-pad fan context-isolation evidence tests passed.'
