[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$annotationPath = Join-Path $repository `
    'annotations\2026-08-12-rz09-0581-slimq-330w-readback.json'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$annotation = Get-Content -LiteralPath $annotationPath -Raw | ConvertFrom-Json

Assert-True ($annotation.schemaVersion -eq 2) `
    'The SlimQ readback annotation must retain schema 2.'
Assert-True ($annotation.evidenceProvenance.role -ceq 'ReadOnlyQueryCapture') `
    'The SlimQ evidence must remain a read-only query capture.'
Assert-True ($annotation.evidenceProvenance.openBladeTypedApplyPerformed -eq $false) `
    'The SlimQ evidence must not claim a typed hardware write.'
Assert-True ($annotation.device.modelNumber -ceq 'RZ09-0581') `
    'The SlimQ readback must remain scoped to RZ09-0581.'
Assert-True ($annotation.device.bios -ceq '4.00') `
    'The SlimQ readback must remain scoped to BIOS 4.00.'

$readback = @($annotation.sanitizedEvidence |
    Where-Object kind -ceq 'RepeatedAdapterPowerReadback')
Assert-True ($readback.Count -eq 1) `
    'The repeated SlimQ adapter readback evidence is missing or duplicated.'
Assert-True ($readback[0].requestPayloadHex -ceq '0000') `
    'The exact 07/8C query payload changed.'
Assert-True ($readback[0].responsePayloadHex -ceq '1211') `
    'The exact SlimQ adapter response changed.'
Assert-True ($readback[0].successfulQueryCount -eq 10) `
    'All ten successful read-only SlimQ queries must remain recorded.'
Assert-True ($readback[0].allResponsesIdentical -eq $true) `
    'The annotation must retain the identical-response result.'
Assert-True ($readback[0].knownOem280WResponsePayloadHex -ceq '1111') `
    'The reviewed OEM 280 W comparison changed.'
Assert-True ($readback[0].knownUsbC100WResponsePayloadHex -ceq '0711') `
    'The reviewed USB-C 100 W comparison changed.'

$stability = @($annotation.sanitizedEvidence |
    Where-Object kind -ceq 'WindowsAcStabilityWindow')
Assert-True ($stability.Count -eq 1) `
    'The Windows AC stability evidence is missing or duplicated.'
Assert-True ($stability[0].sampleCount -eq 4) `
    'The four-sample AC stability window changed.'
Assert-True ($stability[0].powerOnlineThroughout -eq $true) `
    'Windows must remain AC-online throughout the stability window.'
Assert-True ($stability[0].chargingObserved -eq $false) `
    'The full battery must not be described as charging.'
Assert-True ($stability[0].dischargingObserved -eq $false) `
    'The battery must not discharge during the idle stability window.'
Assert-True ($stability[0].adapterResponsePayloadHex -ceq '1211') `
    'The AC stability samples must retain the exact SlimQ response.'

$documentation = @($annotation.sanitizedEvidence |
    Where-Object kind -ceq 'ExternalDocumentationCorrelation')
Assert-True ($documentation.Count -eq 1) `
    'The external documentation correlation is missing or duplicated.'
Assert-True ($documentation[0].firmwareSemanticAssignmentConfirmed -eq $false) `
    'Official compatibility wording must not become firmware semantic proof.'
Assert-True ($documentation[0].slimQConverterDocumentation -ceq
    'https://slimq.life/products/dc-to-razer-blade-converter') `
    'The official SlimQ converter reference changed.'

Assert-True ($annotation.productionAdmission.slimQAdapterObservation -ceq
    'QueryValidated') `
    'The exact read-only SlimQ observation must remain query-validated.'
Assert-True ($annotation.productionAdmission.slimQFullPowerClass -ceq
    'ObservedOnly') `
    'The SlimQ full-power class must remain observed-only.'
Assert-True ($annotation.productionAdmission.slimQHyperBoostWriteAdmitted -eq $false) `
    'SlimQ HyperBoost writes must remain unadmitted.'
Assert-True ($annotation.productionAdmission.padLessHyperBoostWriteAdmitted -eq $false) `
    'Pad-less HyperBoost must remain unadmitted.'

& (Join-Path $repository 'tools\Test-CaptureEvidence.ps1') `
    -AnnotationPath $annotationPath `
    -SchemaOnly | Out-Null

Write-Host 'SlimQ adapter readback evidence tests passed.'
