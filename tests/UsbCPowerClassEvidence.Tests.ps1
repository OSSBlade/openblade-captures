[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$annotationPath = Join-Path $repository `
    'annotations\2026-08-18-rz09-0581-usb-c-power-classes.json'
$fixturePath = Join-Path $repository `
    'decoded\rz09-0581-pid-02e0-bios-4.00-usb-c-power-classes.json'

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
$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json
$annotationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $annotationPath).Hash

Assert-True ($annotation.schemaVersion -eq 2) `
    'The USB-C adapter-class annotation must retain schema 2.'
Assert-True ($annotation.evidenceProvenance.role -ceq 'ReadOnlyQueryCapture') `
    'The USB-C adapter-class evidence must remain read-only.'
Assert-True ($annotation.evidenceProvenance.openBladeTypedApplyPerformed -eq $false) `
    'The USB-C adapter-class evidence must not claim a typed write.'
Assert-True ($annotation.device.modelNumber -ceq 'RZ09-0581') `
    'The USB-C adapter-class evidence must remain scoped to RZ09-0581.'
Assert-True ($annotation.device.productIdHex -ceq '02E0') `
    'The USB-C adapter-class evidence must remain scoped to PID 02E0.'
Assert-True ($annotation.device.bios -ceq '4.00') `
    'The USB-C adapter-class evidence must remain scoped to BIOS 4.00.'

$measurements = @($annotation.sanitizedEvidence |
    Where-Object kind -ceq 'AdapterPowerClassMeasurements')
Assert-True ($measurements.Count -eq 1) `
    'The adapter-class measurements are missing or duplicated.'
Assert-True ($measurements[0].requestPayloadHex -ceq '0000') `
    'The exact read-only 07/8C request changed.'
Assert-True (@($measurements[0].measurements).Count -eq 6) `
    'All six operator-confirmed read-only measurements must remain recorded.'
Assert-True ((@($measurements[0].measurements.configuredChargerWatts) -join ',') `
        -ceq '45,55,65,75,90,99') `
    'The configured charger settings changed.'
Assert-True ((@($measurements[0].measurements.responsePayloadHex) -join ',') `
        -ceq '0211,0211,0411,0411,0411,0411') `
    'The exact adapter response sequence changed.'
Assert-True ($measurements[0].allQueriesReadOnly -eq $true) `
    'Every retained adapter-class query must remain read-only.'

$synapse = @($annotation.sanitizedEvidence |
    Where-Object kind -ceq 'SynapseStaticCorrelation')
Assert-True ($synapse.Count -eq 1) `
    'The Synapse parser correlation is missing or duplicated.'
Assert-True ($synapse[0].commandBytesHex -ceq '02078C') `
    'The Synapse query command changed.'
Assert-True ($synapse[0].response0211.currentWatts -eq 45) `
    'Synapse enum 02 must remain mapped to 45 W.'
Assert-True ($synapse[0].response0311.currentWatts -eq 60) `
    'Synapse enum 03 must remain mapped to 60 W.'
Assert-True ($synapse[0].response0411.currentWatts -eq 65) `
    'Synapse enum 04 must remain mapped to 65 W.'
Assert-True ($synapse[0].response0511.currentWatts -eq 80) `
    'Synapse enum 05 must remain mapped to 80 W.'
Assert-True ($synapse[0].response0611.currentWatts -eq 90) `
    'Synapse enum 06 must remain mapped to 90 W.'
Assert-True ($synapse[0].response0211.recommendedWatts -eq 280) `
    'Response byte 11 must remain mapped to the 280 W recommendation.'

Assert-True ($annotation.productionAdmission.adapterPowerResponse0211 -ceq
    'UsbCPower45W') `
    'The admitted 0211 classification changed.'
Assert-True ($annotation.productionAdmission.adapterPowerResponse0311 -ceq
    'UsbCPower60W') `
    'The admitted 0311 classification changed.'
Assert-True ($annotation.productionAdmission.adapterPowerResponse0411 -ceq
    'UsbCPower65W') `
    'The admitted 0411 classification changed.'
Assert-True ($annotation.productionAdmission.adapterPowerResponse0511 -ceq
    'UsbCPower80W') `
    'The admitted 0511 classification changed.'
Assert-True ($annotation.productionAdmission.adapterPowerResponse0611 -ceq
    'UsbCPower90W') `
    'The admitted 0611 classification changed.'
Assert-True (@($annotation.productionAdmission.admittedBiosVersions).Count -eq 1) `
    'The lower USB-C classes must remain scoped to one captured BIOS version.'
Assert-True ($annotation.productionAdmission.admittedBiosVersions[0] -ceq '4.00') `
    'The lower USB-C classes must remain scoped to BIOS 4.00.'
Assert-True ($annotation.productionAdmission.notGeneralizedToOtherModels -eq $true) `
    'The lower USB-C classes must not be generalized to another Blade model.'
Assert-True ((@($annotation.productionAdmission.authoritativeSynapseOnlyResponses) `
        -join ',') -ceq '0311,0511,0611') `
    'The authoritative Synapse-only admission set changed.'
Assert-True ($annotation.productionAdmission.otherUncapturedSynapseEnumsAdmitted `
        -eq $false) `
    'Other uncaptured Synapse adapter enums must remain fail-closed.'

Assert-True ($fixture.sourceEvidence.annotationSha256 -ceq $annotationHash) `
    'The decoded fixture must remain bound to the reviewed annotation bytes.'
Assert-True ($fixture.responseFormat.byte0 -ceq 'CurrentAdapterWattageLevel') `
    'The first adapter response byte semantic changed.'
Assert-True ($fixture.responseFormat.byte1 -ceq 'RecommendedAdapterWattageLevel') `
    'The second adapter response byte semantic changed.'
Assert-True ((@($fixture.mappings.responsePayloadHex) -join ',') -ceq '0211,0411') `
    'The exact lower USB-C response mappings changed.'
Assert-True ((@($fixture.mappings.classification) -join ',') -ceq
    'UsbCPower45W,UsbCPower65W') `
    'The typed lower USB-C classifications changed.'
Assert-True ((@($fixture.authoritativeSynapseMappings.responsePayloadHex) -join ',') `
        -ceq '0311,0511,0611') `
    'The Synapse-only response set changed.'
Assert-True ((@($fixture.authoritativeSynapseMappings.classification) -join ',') `
        -ceq 'UsbCPower60W,UsbCPower80W,UsbCPower90W') `
    'The Synapse-only typed classifications changed.'
Assert-True (@($fixture.authoritativeSynapseMappings |
        Where-Object physicalSampleCaptured -ne $false).Count -eq 0) `
    'The Synapse-only mappings must not claim physical samples.'
Assert-True ($fixture.productionAdmission.biosVersion -ceq '4.00') `
    'The decoded production admission must remain scoped to BIOS 4.00.'
Assert-True ($fixture.productionAdmission.otherValuesFailClosed -eq $true) `
    'Other adapter values must remain fail-closed.'

& (Join-Path $repository 'tools\Test-CaptureEvidence.ps1') `
    -AnnotationPath $annotationPath `
    -SchemaOnly | Out-Null

Write-Host 'USB-C adapter-class evidence tests passed.'
