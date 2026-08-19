[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$annotationPath = Join-Path $repository `
    'annotations\2026-08-20-rz09-0581-touchpad-hid-version.json'
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
    'Touchpad HID evidence must retain the direct-metadata schema.'
Assert-True ($annotation.device.modelNumber -ceq 'RZ09-0581') `
    'Touchpad admission must remain exact-model scoped.'
Assert-True ($annotation.device.bios -ceq '4.00' -and $annotation.device.ec -ceq '1.04') `
    'Touchpad admission must remain on the captured BIOS and EC baseline.'
Assert-True ($annotation.hidIdentity.api -ceq 'HidD_GetAttributes' -and `
    $annotation.hidIdentity.desiredAccess -eq 0) `
    'Touchpad discovery must remain a zero-access HID descriptor read.'
Assert-True ($annotation.hidIdentity.vendorIdHex -ceq '093A' -and `
    $annotation.hidIdentity.productIdHex -ceq '3001' -and `
    $annotation.hidIdentity.usagePageHex -ceq '000D' -and `
    $annotation.hidIdentity.usageHex -ceq '0005') `
    'The exact PixArt Precision Touchpad identity changed.'
Assert-True ($annotation.hidIdentity.presentVidPidCollectionCount -eq 4 -and `
    $annotation.hidIdentity.exactSemanticMatchCount -eq 1) `
    'Touchpad admission must retain the collection ambiguity and one semantic match.'
Assert-True ($annotation.hidIdentity.versionNumberHex -ceq '0107' -and `
    $annotation.hidIdentity.versionEncoding -ceq 'packed BCD major/minor' -and `
    $annotation.hidIdentity.displayVersion -ceq '1.07') `
    'The observed touchpad descriptor version or encoding changed.'
Assert-True ($annotation.productionAdmission.access -ceq 'ReadOnly' -and `
    $annotation.productionAdmission.requiredVersionSource -ceq `
        'HidD_GetAttributes.VersionNumber' -and `
    $annotation.productionAdmission.requiresExactlyOneSemanticMatch -eq $true -and `
    $annotation.productionAdmission.firmwareWritesAdmitted -eq $false -and `
    $annotation.productionAdmission.otherModelsAdmitted -eq $false) `
    'Touchpad admission must remain read-only, unambiguous, and model-scoped.'
Assert-True ($annotation.evidenceProvenance.packetCapturePerformed -eq $false -and `
    $annotation.evidenceProvenance.deviceWritePerformed -eq $false -and `
    $annotation.evidenceProvenance.featureReportPerformed -eq $false) `
    'Touchpad evidence must not claim packets, feature reports, or writes.'

foreach ($property in $annotation.privacy.PSObject.Properties) {
    Assert-True ($property.Value -eq $false) `
        "Touchpad privacy flag $($property.Name) must remain false."
}

Assert-True ($raw -notmatch 'HID#|ACPI\\|DeviceInformation\.Id|BLADE-16-J') `
    'Touchpad evidence contains a local device identifier.'

Write-Host 'RZ09-0581 touchpad HID version evidence tests passed.'
