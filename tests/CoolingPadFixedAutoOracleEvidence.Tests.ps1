[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$annotationPath = Join-Path $repository `
    'annotations\2026-08-09-rz09-0581-cooling-pad-fixed-auto-oracle.json'
$observationsPath = Join-Path $repository `
    'decoded\rz09-0581-pid-02e0-bios-4.00-cooling-pad-protocol-observations.json'
$annotation = Get-Content -LiteralPath $annotationPath -Raw | ConvertFrom-Json
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
Assert-True ($observations.fan.readback.productionWriteAdmitted -eq $false) `
    'Vendor request/ACK evidence alone must not admit pad fan writes.'

Write-Host 'Cooling-pad Fixed/Auto oracle evidence tests passed.'
