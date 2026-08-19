[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$annotationPath = Join-Path $repository `
    'annotations\2026-08-20-rz09-0581-thunderbolt-firmware-pnp.json'
$raw = Get-Content -LiteralPath $annotationPath -Raw
$annotation = $raw | ConvertFrom-Json

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

Assert-True ($annotation.schemaVersion -eq 1) `
    'Thunderbolt PnP evidence must retain the direct-metadata schema.'
Assert-True ($annotation.device.modelNumber -ceq 'RZ09-0581') `
    'Thunderbolt admission must remain exact-model scoped.'
Assert-True ($annotation.device.bios -ceq '4.00' -and $annotation.device.ec -ceq '1.04') `
    'Thunderbolt admission must remain on the captured BIOS and EC baseline.'
Assert-True ($annotation.property.formatId -ceq `
    '{540B947E-8B40-45BC-A8A2-6A0B894CBDA2}') `
    'The Windows firmware-version property GUID changed.'
Assert-True ($annotation.property.propertyId -eq 18 -and `
    $annotation.property.propertyType -ceq 'DEVPROP_TYPE_STRING') `
    'The Windows firmware-version property identity changed.'

$roots = @($annotation.observations.rootRouters)
$integrated = @($roots | Where-Object { $_.role -ceq 'IntegratedUsb4RootRouter' })
$selected = @($roots | Where-Object { $_.selectedForThunderbolt5 -eq $true })
Assert-True ($annotation.observations.presentUsb4RootRouterCount -eq 2 -and $roots.Count -eq 2) `
    'The two-router ambiguity must remain explicit.'
Assert-True ($integrated.Count -eq 1 -and `
    $integrated[0].instanceIdPrefix -cmatch 'PID_E333' -and `
    $integrated[0].firmwareVersion -ceq '11.7' -and `
    $integrated[0].selectedForThunderbolt5 -eq $false) `
    'The integrated USB4 router must remain explicitly rejected.'
Assert-True ($selected.Count -eq 1 -and `
    $selected[0].instanceIdPrefix -ceq $annotation.productionAdmission.requiredInstanceIdPrefix -and `
    $selected[0].hardwareId -ceq $annotation.productionAdmission.requiredHardwareId -and `
    $selected[0].service -ceq $annotation.productionAdmission.requiredService -and `
    $selected[0].parentInstanceIdPrefix -ceq `
        $annotation.productionAdmission.requiredParentInstanceIdPrefix -and `
    $selected[0].firmwareVersion -ceq '69.1') `
    'Exactly one fully identified Thunderbolt 5 router must remain selected.'
Assert-True ($annotation.productionAdmission.access -ceq 'ReadOnly' -and `
    $annotation.productionAdmission.requiresExactlyOneMatch -eq $true -and `
    $annotation.productionAdmission.otherModelsAdmitted -eq $false) `
    'Thunderbolt admission must remain read-only, unambiguous, and model-scoped.'
Assert-True ($annotation.evidenceProvenance.packetCapturePerformed -eq $false -and `
    $annotation.evidenceProvenance.deviceWritePerformed -eq $false) `
    'Thunderbolt evidence must not claim a packet capture or device write.'

foreach ($property in $annotation.privacy.PSObject.Properties) {
    Assert-True ($property.Value -eq $false) `
        "Thunderbolt privacy flag $($property.Name) must remain false."
}

foreach ($root in $roots) {
    Assert-True ($root.instanceIdPrefix.EndsWith('\') -and `
        $root.parentInstanceIdPrefix.EndsWith('\')) `
        'Thunderbolt evidence must retain prefixes without instance suffixes.'
}

Write-Host 'RZ09-0581 Thunderbolt PnP firmware evidence tests passed.'
