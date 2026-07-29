[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$fixturePath = Join-Path $repository 'decoded\rz09-0528-pid-02c6-bios-2.02-power-source-matrix.json'
$annotationPath = Join-Path $repository 'annotations\2026-07-29-rz09-0528-power-source-matrix.json'
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

$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json
$annotation = Get-Content -LiteralPath $annotationPath -Raw | ConvertFrom-Json
$coverage = Get-Content -LiteralPath $coveragePath -Raw | ConvertFrom-Json

Assert-True ($fixture.status -ceq 'CapturedNotAdmitted') `
    'Power-source evidence must remain captured-but-unadmitted.'
Assert-True ($fixture.transport.adapterPowerQuery -ceq '07/8C:0000') `
    'The exact adapter-power query form changed.'
Assert-True ((@($fixture.transport.batterySaverAutomatic) -join ',') -ceq
    '0D/02:01010300,0D/02:01020300') `
    'The captured battery Battery Saver/Automatic pair changed.'
Assert-True ((@($fixture.transport.balancedAutomatic) -join ',') -ceq
    '0D/02:01010000,0D/02:01020000') `
    'The captured external-power Balanced/Automatic pair changed.'

Assert-True (@($fixture.sessions).Count -eq 9) `
    'The exact-device power matrix must retain all nine successful sessions.'
Assert-True (@($fixture.sessions | Where-Object transition -ceq 'UsbCStableBaseline').Count -eq 1) `
    'The stable USB-C no-action baseline was lost or relabeled.'
Assert-True (@($fixture.sessions | Where-Object transition -ceq 'BatteryStableBaseline').Count -eq 1) `
    'The stable battery no-action baseline was lost.'
Assert-True (@($fixture.sessions | Where-Object {
        $_.captureSha256 -notmatch '^[0-9A-F]{64}$' -or
        $_.transactionsSha256 -notmatch '^[0-9A-F]{64}$' -or
        $_.byteLength -le 0 -or
        $_.transactionCount -le 0
    }).Count -eq 0) `
    'Every matrix session must retain capture and decoded-transaction hashes and counts.'

Assert-True ($fixture.visibleCapabilities.usbCOnly.customAvailable -eq $false) `
    'USB-C-only Custom availability must reflect the observed disabled state.'
Assert-True ($fixture.visibleCapabilities.usbCOnly.performanceAvailable -eq $false) `
    'USB-C-only Performance availability must reflect the observed disabled state.'
Assert-True ($fixture.visibleCapabilities.usbCOnly.inadequatePowerWarningVisible -eq $true) `
    'The observed USB-C inadequate-power warning was lost.'
Assert-True ($fixture.visibleCapabilities.barrelAc.customAvailable -eq $true) `
    'Full-power Custom availability must remain recorded.'
Assert-True ($fixture.visibleCapabilities.battery.fixedFanAvailable -eq $false) `
    'The observed battery fixed-fan restriction was lost.'

Assert-True ($fixture.negativeEvidence.exactUsbCPowerClassResponseCaptured -eq $false) `
    'The fixture must not infer an exact USB-C response from outgoing queries.'
Assert-True ($fixture.negativeEvidence.independentThermalReadbackCaptured -eq $false) `
    'The fixture must not infer independent thermal readback from visible UI.'
Assert-True ($fixture.negativeEvidence.productionWired -eq $false) `
    'Captured power transitions must not silently become production writes.'
Assert-True ($annotation.evidenceProvenance.openBladeReadbackConfirmed -eq $false) `
    'The annotation must preserve the no-independent-readback boundary.'
Assert-True ($annotation.productionAdmission.exactUsbCPowerClassReadback -eq $false) `
    'Exact PID 02C6 USB-C readback must remain unadmitted.'

foreach ($status in @(
    $coverage.capabilities.performance.usbC.powerClasses,
    $coverage.capabilities.performance.usbC.presetsByPowerClass,
    $coverage.capabilities.performance.battery.presets,
    $coverage.capabilities.power.usbCPowerClasses,
    $coverage.capabilities.power.battery,
    $coverage.capabilities.power.acToUsbC,
    $coverage.capabilities.power.usbCToAc,
    $coverage.capabilities.power.acToBattery,
    $coverage.capabilities.power.batteryToAc,
    $coverage.capabilities.power.usbCToBattery,
    $coverage.capabilities.power.batteryToUsbC
)) {
    Assert-True ([string]$status -ceq 'Captured') `
        'Every observed power-source coverage leaf must be Captured.'
}

Assert-True ($coverage.capabilities.performance.usbC.readback -ceq 'NotInvestigated') `
    'USB-C readback must stay NotInvestigated until an exact reply is captured.'
Assert-True ($coverage.capabilities.performance.battery.readback -ceq 'NotInvestigated') `
    'Battery thermal readback must stay NotInvestigated until independently validated.'

Write-Host 'RZ09-0528 power-source matrix evidence tests passed.'
