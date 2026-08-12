[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$annotationPath = Join-Path $repository `
    'annotations\2026-08-09-rz09-0581-cooling-pad-fixed-auto-oracle.json'
$rapidOraclePath = Join-Path $repository `
    'annotations\2026-08-09-rz09-0581-cooling-pad-auto-fixed-oracle.json'
$observationsPath = Join-Path $repository `
    'decoded\rz09-0581-pid-02e0-bios-4.00-cooling-pad-protocol-observations.json'
$padIndependentPath = Join-Path $repository `
    'annotations\2026-08-09-rz09-0581-hyperboost-pad-independent-readback.json'
$activeReadbackPath = Join-Path $repository `
    'annotations\2026-08-09-rz09-0581-hyperboost-active-readback.json'
$validator = Join-Path $repository 'tools\Test-CaptureEvidence.ps1'
$annotation = Get-Content -LiteralPath $annotationPath -Raw | ConvertFrom-Json
$rapidOracle = Get-Content -LiteralPath $rapidOraclePath -Raw | ConvertFrom-Json
$observations = Get-Content -LiteralPath $observationsPath -Raw | ConvertFrom-Json
$padIndependent = Get-Content -LiteralPath $padIndependentPath -Raw | ConvertFrom-Json
$activeReadback = Get-Content -LiteralPath $activeReadbackPath -Raw | ConvertFrom-Json

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

Assert-True ($annotation.evidenceProvenance.role -ceq 'OracleCapture') `
    'The Fixed/Auto evidence must remain a vendor-oracle capture.'
Assert-True ($annotation.evidenceProvenance.openBladeTypedApplyPerformed -eq $false) `
    'The annotation must not claim an OpenBlade apply.'
Assert-True ($annotation.capture.sha256 -ceq `
        '5957D8808D30247214C23C65A32A6CC2E08148BB982E5296E79755D605DF8E98') `
    'The Fixed/Auto raw-capture hash changed unexpectedly.'
Assert-True ($annotation.capture.rawCaptureCommitted -eq $false) `
    'The raw Fixed/Auto capture must remain uncommitted.'
Assert-True ($annotation.capture.stopMode -ceq 'Graceful') `
    'The Fixed/Auto capture must retain its graceful stop result.'
Assert-True ($rapidOracle.limitations[2] -ceq `
        'Synapse exposes no fan-speed readback. The 0D/81 getter returns an opaque byte with no assigned target, mode, ownership, physical-speed, or tachometer semantics, and the candidate current-speed getter fails protocol validation.') `
    'The vendor oracle must not assign configured-target semantics to 0D/81.'
& $validator -AnnotationPath $rapidOraclePath -SchemaOnly | Out-Null
& $validator -AnnotationPath $padIndependentPath -SchemaOnly | Out-Null
& $validator -AnnotationPath $activeReadbackPath -SchemaOnly | Out-Null

$fixed = @($annotation.sanitizedEvidence | Where-Object kind -ceq 'CoolingPadFixed2200')
$automatic = @($annotation.sanitizedEvidence | Where-Object kind -ceq 'CoolingPadAutoRestore')
Assert-True ($fixed.Count -eq 1 -and $fixed[0].requestPayloadHex -ceq '01022C') `
    'The exact vendor Fixed 2200 request payload is missing.'
Assert-True ($fixed[0].responseStatusHex -ceq '02' -and
    $fixed[0].responsePayloadHex -ceq '01022C') `
    'The exact vendor Fixed 2200 acknowledgement is missing.'
Assert-True ($automatic.Count -eq 1 -and
    $automatic[0].requestPayloadHex -ceq '000600') `
    'The exact vendor Auto request payload is missing.'
Assert-True ($automatic[0].responseStatusHex -ceq '02' -and
    $automatic[0].responsePayloadHex -ceq '000600') `
    'The exact vendor Auto acknowledgement is missing.'

$mode = $observations.fan.modeOrFixedTarget
Assert-True (@($mode.observedPayloadHex) -contains '01022C') `
    'The decoded observations lost the Fixed 2200 payload.'
Assert-True (@($mode.observedPayloadHex) -contains '000600') `
    'The decoded observations lost the Auto payload.'
Assert-True ($mode.fixed2200.independentActiveModeReadbackConfirmed -eq $false) `
    'The Fixed 2200 observation must not claim active-mode readback.'
Assert-True ($mode.automatic.independentActiveModeReadbackConfirmed -eq $false) `
    'The Auto observation must not claim active-mode readback.'
$opaque = $observations.fan.readback.opaqueFanObservationGetter
Assert-True ($null -eq $observations.fan.readback.PSObject.Properties[
        'configuredTargetGetter']) `
    'The opaque observation must not be exposed as a configured-target getter.'
$range = $observations.fan.dynamicTarget.installedMiddlewareConfiguredRange
Assert-True ($range.minimum -eq 500 -and $range.maximum -eq 3200 -and
    $range.step -eq 50 -and $range.minimumOperatorUiConfirmed -eq $true) `
    'The exact Fixed RPM range or operator-confirmed minimum changed.'
Assert-True ($opaque.balancedSmartCurveResponsePayloadHex -ceq '010500' -and
    $opaque.vendorFixed2200ResponsePayloadHex -ceq '01052C' -and
    $opaque.semanticAssignmentConfirmed -eq $false) `
    'The opaque getter responses or semantic boundary changed.'
$buttonPresets = @($opaque.physicalButtonPresetSequence)
Assert-True ($buttonPresets.Count -eq 4) `
    'The physical fan-button query sequence is incomplete.'
Assert-True ($buttonPresets[0].preset -ceq 'Low' -and
    $buttonPresets[0].responsePayloadHex -ceq '010520' -and
    $buttonPresets[0].opaqueRawDecimal -eq 32) `
    'The Low physical preset opaque observation changed.'
Assert-True ($buttonPresets[1].preset -ceq 'Medium' -and
    $buttonPresets[1].responsePayloadHex -ceq '01052C' -and
    $buttonPresets[1].opaqueRawDecimal -eq 44) `
    'The Medium physical preset opaque observation changed.'
Assert-True ($buttonPresets[2].preset -ceq 'High' -and
    $buttonPresets[2].responsePayloadHex -ceq '01052C' -and
    $buttonPresets[2].opaqueRawDecimal -eq 44) `
    'The customized High physical preset opaque observation changed.'
Assert-True ($buttonPresets[3].preset -ceq 'AutomaticRestored' -and
    $buttonPresets[3].responsePayloadHex -ceq '010500' -and
    $buttonPresets[3].opaqueRawDecimal -eq 0) `
    'The post-restoration opaque observation changed.'
$coolingMode = $observations.fan.readback.coolingModeGetter
Assert-True ($coolingMode.queried -eq $true) `
    'The two cooling-mode configuration banks must remain queried.'
Assert-True ($coolingMode.firmwareBank.responsePayloadHex -ceq '0006') `
    'The firmware configuration-bank response changed.'
Assert-True ($coolingMode.synapseBank.responsePayloadHex -ceq '01022C') `
    'The Synapse configuration-bank response changed.'
Assert-True ($coolingMode.activeModeReadbackConfirmed -eq $false) `
    'Configuration-bank getters must not be promoted to active-mode readback.'
Assert-True ($observations.fan.readback.productionWriteAdmitted -eq $false) `
    'Vendor request/ACK evidence alone must not admit pad fan writes.'

$independentOpaque = @($padIndependent.sanitizedEvidence |
    Where-Object kind -ceq 'CoolingPadOpaqueFanObservation')
Assert-True ($independentOpaque.Count -eq 1 -and
    $independentOpaque[0].requestPayloadHex -ceq '010500' -and
    $independentOpaque[0].balancedResponsePayloadHex -ceq '010500' -and
    $independentOpaque[0].fixed2200ResponsePayloadHex -ceq '01052C' -and
    $independentOpaque[0].fixed2200OpaqueRawDecimal -eq 44 -and
    $independentOpaque[0].semanticAssignmentConfirmed -eq $false -and
    $null -eq $independentOpaque[0].PSObject.Properties['scale']) `
    'The independent 0D/81 observation must remain opaque correlation only.'
$smartCurveOpaque = @($activeReadback.sanitizedEvidence |
    Where-Object kind -ceq 'CoolingPadSmartCurveOpaqueObservation')
Assert-True ($smartCurveOpaque.Count -eq 1 -and
    $smartCurveOpaque[0].opaqueResponsePayloadHex -ceq '01052C' -and
    $smartCurveOpaque[0].opaqueRawDecimal -eq 44 -and
    $smartCurveOpaque[0].semanticAssignmentConfirmed -eq $false -and
    $smartCurveOpaque[0].currentSpeedGetterConfirmed -eq $false -and
    $null -eq $smartCurveOpaque[0].PSObject.Properties[
        'configuredTargetDisplayValue']) `
    'The Smart Curve 0D/81 observation must not claim target or RPM semantics.'

Write-Host 'Cooling-pad Fixed/Auto oracle evidence tests passed.'
