[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$fixturePath = Join-Path $repository 'decoded\rz09-0528-pid-02c6-bios-2.02-power-source-matrix.json'
$annotationPath = Join-Path $repository 'annotations\2026-07-29-rz09-0528-power-source-matrix.json'
$acRecheckPath = Join-Path $repository 'annotations\2026-07-30-rz09-0528-ac-power-readback-recheck.json'
$readbackPath = Join-Path $repository (
    'annotations\2026-07-30-rz09-0528-power-source-readback-admission.json')
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
$acRecheck = Get-Content -LiteralPath $acRecheckPath -Raw | ConvertFrom-Json
$readback = Get-Content -LiteralPath $readbackPath -Raw | ConvertFrom-Json
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
Assert-True ($fixture.transport.sourceInputReports.endpoint -ceq '0x82') `
    'The exact source-event candidate endpoint changed.'
Assert-True ($fixture.transport.sourceInputReports.byteLength -eq 16) `
    'The exact source-event candidate report length changed.'
Assert-True ($fixture.transport.sourceInputReports.batteryCandidate -ceq
    '05/33:0011') `
    'The battery source-event candidate changed.'
Assert-True ($fixture.transport.sourceInputReports.usbCOnlyCandidate -ceq
    '05/33:0711') `
    'The USB-C source-event candidate changed.'
Assert-True ($fixture.transport.sourceInputReports.barrelAcCandidate -ceq
    '05/33:1111') `
    'The barrel-AC source-event candidate changed.'

Assert-True (@($fixture.sessions).Count -eq 9) `
    'The exact-device power matrix must retain all nine successful sessions.'
Assert-True (@($fixture.sessions | Where-Object transition -ceq 'UsbCStableBaseline').Count -eq 1) `
    'The stable USB-C no-action baseline was lost or relabeled.'
Assert-True (@($fixture.sessions | Where-Object transition -ceq 'BatteryStableBaseline').Count -eq 1) `
    'The stable battery no-action baseline was lost.'
Assert-True ((@($fixture.sessions |
    Where-Object transition -ceq 'UsbCStableBaseline' |
    ForEach-Object sourceInputReportValues) -join ',') -ceq '1111') `
    'The quiet USB-C 1111 anomaly must remain explicit and block inference.'
Assert-True ((@($fixture.sessions |
    Where-Object transition -ceq 'BatteryToUsbC' |
    ForEach-Object sourceInputReportValues) -join ',') -ceq '0711') `
    'The exact battery-to-USB-C input report was lost.'
Assert-True ((@($fixture.sessions |
    Where-Object transition -ceq 'UsbCToBattery' |
    ForEach-Object sourceInputReportValues) -join ',') -ceq '0011') `
    'The exact USB-C-to-battery input report was lost.'
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
Assert-True ($fixture.negativeEvidence.sourceInputReportsIndependentlyReadBack -eq $false) `
    'Source-event input reports must not be promoted to typed readback.'
Assert-True ($fixture.negativeEvidence.independentThermalReadbackCaptured -eq $false) `
    'The fixture must not infer independent thermal readback from visible UI.'
Assert-True ($fixture.negativeEvidence.productionWired -eq $false) `
    'Captured power transitions must not silently become production writes.'
Assert-True ($annotation.evidenceProvenance.openBladeReadbackConfirmed -eq $false) `
    'The annotation must preserve the no-independent-readback boundary.'
Assert-True ($annotation.productionAdmission.exactUsbCPowerClassReadback -eq $false) `
    'Exact PID 02C6 USB-C readback must remain unadmitted.'
Assert-True (@($acRecheck.attempts).Count -eq 3) `
    'The barrel-AC readback recheck must retain all three attempts.'
Assert-True (@($acRecheck.attempts | Where-Object {
        $_.success -ne $true -or
        $_.adapterPowerHex -cne '1111' -or
        $_.thermal1Hex -cne '01010200' -or
        $_.thermal2Hex -cne '01020200' -or
        $_.sha256 -cne '07683820A140192D209AA1494EB53F4DF4BBBE1E2375528F7418DB35106E9AA6' -or
        $_.byteLength -ne 822
    }).Count -eq 0) `
    'The repeated barrel-AC readbacks must remain identical and successful.'
Assert-True ($acRecheck.readOnly -eq $true) `
    'The barrel-AC recheck must remain read-only.'
Assert-True ($acRecheck.interpretation.settingChanged -eq $false) `
    'The barrel-AC recheck must not imply a setting change.'
Assert-True ($acRecheck.admission.advancedByThisSession -eq $false) `
    'The repeated AC query must not silently advance another capability.'
Assert-True ($acRecheck.admission.usbCReadback -ceq 'NotInvestigated') `
    'The AC query must not advance USB-C readback.'
Assert-True ($acRecheck.admission.batteryReadback -ceq 'NotInvestigated') `
    'The AC query must not advance battery readback.'
Assert-True ($acRecheck.privacy.rawOutputCommitted -eq $false) `
    'The transient readback output must remain uncommitted.'

Assert-True ($readback.privateEvidence.successfulSummary.sha256 -ceq
    '3C2113C1C3AAE82D5EF578B964D167989CE4E506339331F467AE41DCDF2810D0') `
    'The successful exact-device matrix summary hash changed.'
Assert-True ($readback.privateEvidence.successfulSummary.byteLength -eq 10799) `
    'The successful exact-device matrix summary length changed.'
Assert-True (@($readback.privateEvidence.failedAttempts).Count -eq 2) `
    'Both failed direct-readback attempts must remain preserved.'
Assert-True (@($readback.matrix | Where-Object {
        $_.samplesIdentical -ne $true
    }).Count -eq 0) `
    'Every direct readback state must retain three identical samples.'
Assert-True ((@($readback.matrix | ForEach-Object {
        "$($_.label):$($_.windowsPowerLineStatus):" +
            "$($_.adapterPowerPayloadHex):" +
            "$($_.thermal1PayloadHex):$($_.thermal2PayloadHex)"
    }) -join ',') -ceq (
        'full-ac-baseline:Online:1111:01010200:01020200,' +
        'battery:Offline:0011:01010300:01020300,' +
        'usb-c:Online:0711:01010000:01020000,' +
        'full-ac-restored:Online:1111:01010200:01020200')) `
    'The exact source and thermal readback matrix changed.'
Assert-True ($readback.evidenceProvenance.openBladeServiceRestored -eq $true) `
    'The successful matrix must preserve exact service restoration.'
Assert-True ($readback.admission.adapterUsbCReadback -ceq
    'ProductionAdmitted') `
    'Exact PID 02C6 USB-C adapter readback must remain admitted.'
Assert-True ($readback.admission.batterySourceReadback -ceq
    'ProductionAdmitted') `
    'Exact battery source readback must remain admitted.'

foreach ($status in @(
    $coverage.capabilities.performance.usbC.presetsByPowerClass,
    $coverage.capabilities.performance.battery.presets,
    $coverage.capabilities.power.acToUsbC,
    $coverage.capabilities.power.batteryToAc,
    $coverage.capabilities.power.usbCToBattery
)) {
    Assert-True ([string]$status -ceq 'Captured') `
        'Unvalidated source setters and transitions must remain Captured.'
}

foreach ($status in @(
    $coverage.capabilities.performance.usbC.powerClasses,
    $coverage.capabilities.power.usbCPowerClasses,
    $coverage.capabilities.power.battery
)) {
    Assert-True ([string]$status -ceq 'ProductionAdmitted') `
        'Exact adapter and battery-source readback must remain admitted.'
}

foreach ($status in @(
    $coverage.capabilities.performance.usbC.readback,
    $coverage.capabilities.performance.battery.readback,
    $coverage.capabilities.power.usbCToAc,
    $coverage.capabilities.power.acToBattery,
    $coverage.capabilities.power.batteryToUsbC
)) {
    Assert-True ([string]$status -ceq 'QueryValidated') `
        'Directly read source states and transitions must remain query-validated.'
}

Write-Host 'RZ09-0528 power-source matrix evidence tests passed.'
