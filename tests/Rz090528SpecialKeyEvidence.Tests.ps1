$ErrorActionPreference = 'Stop'

$repository = Split-Path $PSScriptRoot -Parent
$fixturePath = Join-Path $repository (
    'decoded\rz09-0528-pid-02c6-bios-2.02-special-keys.json')
$annotationPath = Join-Path $repository (
    'annotations\2026-07-29-rz09-0528-special-key-reports.json')
$coveragePath = Join-Path $repository (
    'decoded\rz09-0528-pid-02c6-bios-2.02-device-coverage.json')

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

$fixture = Get-Content -Raw -LiteralPath $fixturePath | ConvertFrom-Json
$annotation = Get-Content -Raw -LiteralPath $annotationPath | ConvertFrom-Json
$coverage = Get-Content -Raw -LiteralPath $coveragePath | ConvertFrom-Json

Assert-True ($fixture.schemaVersion -eq 1) 'Special-key fixture schema changed.'
Assert-True ($fixture.status -ceq 'CapturedNotAdmitted') `
    'Special-key evidence must remain captured but unadmitted.'
Assert-True ($fixture.device.modelNumber -ceq 'RZ09-0528') `
    'Special-key fixture model changed.'
Assert-True ($fixture.device.productIdHex -ceq '02C6') `
    'Special-key fixture PID changed.'
Assert-True ($fixture.device.inputEndpointHex -ceq '82') `
    'Special-key endpoint changed.'
Assert-True ($fixture.captures.Count -eq 7) `
    'The negative control and six exact actions must all remain hashed.'
Assert-True (
    @($fixture.captures | Where-Object {
        $_.sha256 -notmatch '^[0-9A-F]{64}$' -or $_.byteLength -le 0
    }).Count -eq 0) 'Capture hashes or lengths are malformed.'

$expectedPrefixes = @{
    PageUpNegativeControl = @('01004B00', '01000000')
    M1 = @('040A0000', '01004B00', '01000000', '04000000')
    M2 = @('040A0000', '01004E00', '01000000', '04000000')
    M3 = @('040A0000', '040A0300', '040A0000', '04000000')
    M4 = @('040A0000', '040AD300', '040A0000', '04000000')
    M5 = @('040A0000', '040AD400', '040A0000', '04000000')
    FnP = @('040A0000', '01001300', '01000000', '04000000')
}
foreach ($action in $fixture.actions) {
    Assert-True ($expectedPrefixes.ContainsKey([string]$action.function)) `
        "Unexpected action '$($action.function)'."
    $actual = @($action.reports | ForEach-Object { [string]$_.prefixHex })
    $expected = @($expectedPrefixes[[string]$action.function])
    Assert-True (
        [string]::Join('|', $actual) -ceq [string]::Join('|', $expected)) `
        "Report sequence changed for '$($action.function)'."
}
Assert-True ($fixture.actions.Count -eq $expectedPrefixes.Count) `
    'A required special-key action is missing.'
Assert-True (
    $fixture.interpretation.m4Collision -match 'Do not copy') `
    'The PID 02C6 M4/D3 collision warning must remain explicit.'
Assert-True ($fixture.privacy.rawCapturesCommitted -eq $false) `
    'Raw special-key captures must remain private.'
Assert-True ($fixture.privacy.operatorReplyReportsExcluded -eq $true) `
    'Operator reply noise must remain excluded.'

Assert-True (
    $annotation.decodedEvidence -ceq (
        'decoded/rz09-0528-pid-02c6-bios-2.02-special-keys.json')) `
    'Annotation no longer points to the canonical fixture.'
Assert-True ($annotation.admission.productionAccess -ceq 'ObservedOnly') `
    'Special keys must remain observed-only before exact live decoder validation.'
Assert-True ($annotation.privacy.serialNumbersRetained -eq $false) `
    'Sanitized annotation must not retain serial numbers.'
Assert-True ($annotation.privacy.devicePathsRetained -eq $false) `
    'Sanitized annotation must not retain device paths.'
Assert-True (
    $annotation.liveDecoderValidation.hidInputAccessProbe.status -ceq (
        'ReadOnlyNegativeControl')) `
    'The direct HID access result must remain an explicit negative control.'
Assert-True (
    $annotation.liveDecoderValidation.hidInputAccessProbe.collectionCount -eq 10) `
    'The exact HID access probe must retain all ten collections.'
Assert-True (
    $annotation.liveDecoderValidation.hidInputAccessProbe.readHandleOpenCount -eq 7) `
    'The exact HID access probe shared-read count changed.'
$keyboardCollections = @(
    $annotation.liveDecoderValidation.hidInputAccessProbe.collections |
        Where-Object { $_.usage -ceq '0001:0006' })
Assert-True ($keyboardCollections.Count -eq 2) `
    'Both exact keyboard top-level collections must remain represented.'
Assert-True (
    @($keyboardCollections | Where-Object {
        $_.readHandleOpened -ne $false -or $_.win32Error -ne 5
    }).Count -eq 0) `
    'Both exact keyboard collections must retain the access-denied result.'
Assert-True (
    $annotation.liveDecoderValidation.hidInputAccessProbe.privacy.devicePathsRetained `
        -eq $false) `
    'The HID access probe must not retain device paths.'
Assert-True (
    $annotation.liveDecoderValidation.hidInputAccessProbe.privacy.uniqueIdentifiersRetained `
        -eq $false) `
    'The HID access probe must not retain unique identifiers.'
Assert-True (
    $annotation.liveDecoderValidation.combinedIsolationAttempt.status -ceq (
        'FailedZeroInput')) `
    'The combined isolation retry must remain a failed zero-input session.'
Assert-True (
    $annotation.liveDecoderValidation.combinedIsolationAttempt.durationSeconds -eq 60) `
    'The combined isolation retry must remain time bounded.'
foreach ($controller in @(
        'synapseInactive',
        'razerElevationServiceInactive',
        'razerGameManagerServiceInactive',
        'openBladeServiceInactive')) {
    Assert-True (
        $annotation.liveDecoderValidation.combinedIsolationAttempt.$controller `
            -eq $true) `
        "Combined isolation state '$controller' changed."
}
Assert-True (
    $annotation.liveDecoderValidation.combinedIsolationAttempt.rawInputMessages -eq 0) `
    'The combined zero-input retry must not acquire synthetic input evidence.'
Assert-True (
    $annotation.liveDecoderValidation.combinedIsolationAttempt.targetInputMessages -eq 0) `
    'The combined retry must not claim target input.'
Assert-True (
    $annotation.liveDecoderValidation.combinedIsolationAttempt.externalStateRestored `
        -eq $true) `
    'The combined retry must retain external-state restoration.'
Assert-True (
    $annotation.liveDecoderValidation.combinedIsolationAttempt.privateOutput.sha256 `
        -match '^[0-9A-F]{64}$') `
    'The combined retry hash is malformed.'
Assert-True (
    $annotation.liveDecoderValidation.combinedIsolationAttempt.privateOutput.committed `
        -eq $false) `
    'The combined retry output must remain private.'

foreach ($leaf in @(
        'functionLayerReports',
        'performanceKey',
        'm1PageUp',
        'm2PageDown',
        'm3GamingMode',
        'm4PerformanceMode',
        'm5MicrophoneMute')) {
    Assert-True ($coverage.capabilities.specialKeys.$leaf -ceq 'Captured') `
        "Coverage leaf specialKeys.$leaf must remain Captured."
}

Write-Host 'RZ09-0528 special-key evidence tests passed.'
