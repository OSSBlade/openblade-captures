[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$inventoryPath = Join-Path $repository 'tools\Get-CoolingPadCaptureInventory.ps1'
$source = Get-Content -LiteralPath $inventoryPath -Raw

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

Assert-True ($source.Contains('$vendorId = [uint16]0x1532')) `
    'The cooling-pad inventory lost its exact vendor identity.'
Assert-True ($source.Contains('$productId = [uint16]0x0F43')) `
    'The cooling-pad inventory lost its exact product identity.'
Assert-True ($source.Contains("featureReportBytes'] -eq 91")) `
    'The cooling-pad inventory no longer identifies the 91-byte control collection.'
Assert-True ($source.Contains("deviceInterfacePathsIncluded = `$false")) `
    'The cooling-pad inventory no longer declares device-path redaction.'
Assert-True (-not $source.Contains('HidD_SetFeature')) `
    'The read-only cooling-pad inventory must never include a feature-report setter.'
Assert-True (-not $source.Contains('HidD_GetFeature')) `
    'The identity inventory must not issue feature-report queries.'
Assert-True ($source.Contains("path,`r`n                            0,")) `
    'The HID handle must be opened with zero desired access.'
Assert-True (-not $source.Contains('serialNumber =')) `
    'The cooling-pad inventory must not serialize a serial number.'
Assert-True (-not $source.Contains('deviceInterfacePath =')) `
    'The cooling-pad inventory must not serialize a device-interface path.'
Assert-True (-not $source.Contains('instanceId =')) `
    'The cooling-pad inventory must not serialize a full PnP instance ID.'

Write-Host 'Cooling-pad capture-inventory regression tests passed.'
