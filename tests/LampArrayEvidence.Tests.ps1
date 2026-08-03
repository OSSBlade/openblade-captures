[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$fixturePath = Join-Path $repository 'decoded\rz09-0528-pid-02c6-bios-2.02-lamp-array.json'
$annotationPath = Join-Path $repository 'annotations\2026-07-29-rz09-0528-lamp-array-discovery.json'
$coveragePath = Join-Path $repository 'decoded\rz09-0528-pid-02c6-bios-2.02-device-coverage.json'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$fixtureRaw = Get-Content -LiteralPath $fixturePath -Raw
$annotationRaw = Get-Content -LiteralPath $annotationPath -Raw
$fixture = $fixtureRaw | ConvertFrom-Json
$annotation = $annotationRaw | ConvertFrom-Json
$coverage = Get-Content -LiteralPath $coveragePath -Raw | ConvertFrom-Json

Assert-True ($fixture.source.readOnly -eq $true) `
    'LampArray evidence must remain read-only.'
Assert-True ($fixture.source.uniqueIdentifiersIncluded -eq $false) `
    'LampArray evidence must not contain unique identifiers.'
Assert-True ($fixture.lampArray.kind -ceq 'Keyboard') `
    'The exact LampArray kind changed.'
Assert-True ($fixture.lampArray.lampCount -eq 85) `
    'The exact keyboard lamp count changed.'
Assert-True ($fixture.lampArray.supportsVirtualKeys -eq $true) `
    'The exact keyboard must retain virtual-key support.'
Assert-True ($fixture.lampArray.minimumUpdateIntervalMicroseconds -eq 33333) `
    'The exact LampArray minimum update interval changed.'
Assert-True ($fixture.lampArray.geometryAndVirtualKeysSha256 -cmatch '^[0-9A-F]{64}$') `
    'The sanitized geometry fingerprint is missing or malformed.'
Assert-True ((@($fixture.lampArray.unmappedLampIndices) -join ',') -ceq
    '15,59,72,74,78,84') `
    'The exact unmapped-lamp set changed.'
Assert-True ($fixture.lampArray.availableToUnpackagedBackgroundProbe -eq $false) `
    'The unpackaged background availability boundary must remain explicit.'
Assert-True ($fixture.admission.productionControlAdmitted -eq $false) `
    'Read-only LampArray discovery must not silently admit writes.'
Assert-True ($coverage.capabilities.keyboardLighting.lampArrayInterfaceDiscovery -ceq
    'QueryValidated') `
    'LampArray discovery coverage must remain QueryValidated.'
Assert-True ($coverage.capabilities.keyboardLighting.matrixInterfaceDiscovery -ceq
    'Absent') `
    'The absent PID 02E0-style raw matrix interface must remain explicit.'
Assert-True ($annotation.productionAdmission.lightingWrites -eq $false) `
    'The annotation must preserve the no-write boundary.'

foreach ($raw in @($fixtureRaw, $annotationRaw)) {
    Assert-True ($raw -notmatch 'HID#|DeviceInformation\\.Id|BLADE-16-J|3585b90f') `
        'LampArray evidence contains a local device identifier.'
}

Write-Host 'RZ09-0528 LampArray evidence tests passed.'
