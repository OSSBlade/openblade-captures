$ErrorActionPreference = 'Stop'

$repository = Split-Path $PSScriptRoot -Parent
$exporterPath = Join-Path $repository (
    'tools\Export-Rz090528SynapseEffectFixtures.ps1')
$tidalPath = Join-Path $repository (
    'decoded\rz09-0528-pid-02c6-bios-2.02-tidal-oracle.json')
$waveWheelPath = Join-Path $repository (
    'decoded\rz09-0528-pid-02c6-bios-2.02-wave-wheel-oracle.json')
$fireExporterPath = Join-Path $repository (
    'tools\Export-Rz090528FireOracleFixture.ps1')
$firePath = Join-Path $repository (
    'decoded\rz09-0528-pid-02c6-bios-2.02-fire-oracle.json')
$upperAnnotationPath = Join-Path $repository (
    'annotations\2026-07-30-rz09-0528-full-menu-upper-effects-oracle.json')
$coveragePath = Join-Path $repository (
    'decoded\rz09-0528-pid-02c6-bios-2.02-device-coverage.json')

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) {
        throw $Message
    }
}

$exporter = Get-Content -Raw -LiteralPath $exporterPath
$fireExporter = Get-Content -Raw -LiteralPath $fireExporterPath
foreach ($required in @(
        'RZ09-0528',
        '02C6',
        '2.02',
        'RZ09-0528-SYNAPSE-QUICK-EFFECTS-ORACLE-20260730',
        'deflate-base64-signed-int16-color1-positive-color2-negative',
        'deflate-base64-rgb24')) {
    Assert-True ($exporter.Contains($required)) `
        "The fixture exporter dropped '$required'."
}
Assert-True (-not $exporter.Contains('sourceCaptureSha256')) `
    'The exporter must not publish the private capture hash.'
foreach ($required in @(
        'RZ09-0528',
        '02C6',
        '2.02',
        'RZ09-0528-SYNAPSE-FULL-MENU-UPPER-ORACLE-20260730',
        'deflate-base64-rgb24',
        'startupFadeMilliseconds')) {
    Assert-True ($fireExporter.Contains($required)) `
        "The Fire fixture exporter dropped '$required'."
}
Assert-True (-not $fireExporter.Contains('sourceCaptureSha256')) `
    'The Fire exporter must not publish the private capture hash.'

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $fireExporterPath,
    [ref]$tokens,
    [ref]$errors)
Assert-True ($errors.Count -eq 0) `
    'The Fire exporter must parse in Windows PowerShell 5.1.'

$tidal = Get-Content -Raw -LiteralPath $tidalPath | ConvertFrom-Json
$waveWheel = Get-Content -Raw -LiteralPath $waveWheelPath | ConvertFrom-Json
$fire = Get-Content -Raw -LiteralPath $firePath | ConvertFrom-Json
$upperAnnotation =
    Get-Content -Raw -LiteralPath $upperAnnotationPath | ConvertFrom-Json
$coverage = Get-Content -Raw -LiteralPath $coveragePath | ConvertFrom-Json
foreach ($document in @($tidal, $waveWheel, $fire)) {
    Assert-True ($document.target.modelNumber -ceq 'RZ09-0528') `
        'Fixture model changed.'
    Assert-True ($document.target.vendorIdHex -ceq '1532') `
        'Fixture VID changed.'
    Assert-True ($document.target.productIdHex -ceq '02C6') `
        'Fixture PID changed.'
    Assert-True ($document.target.bios -ceq '2.02') `
        'Fixture BIOS changed.'
    Assert-True (
        $document.PSObject.Properties.Name -notcontains
            'sourceCaptureSha256') `
        'A sanitized fixture exposed the private capture hash.'
}
foreach ($document in @($tidal, $waveWheel)) {
    Assert-True (
        $document.sourceEvidenceId -ceq
            'RZ09-0528-SYNAPSE-QUICK-EFFECTS-ORACLE-20260730') `
        'Lower-effect fixture evidence ID changed.'
}

Assert-True ($tidal.templates.Count -eq 2) `
    'Tidal must retain both directions.'
Assert-True ($tidal.frameCount -eq 100) `
    'Tidal frame count changed.'
Assert-True ($waveWheel.templates.Count -eq 4) `
    'Wave/Wheel must retain all four variants.'
Assert-True ($waveWheel.frameCount -eq 25) `
    'Wave/Wheel frame count changed.'
Assert-True ($fire.evidenceRole -ceq 'SanitizedRz090528FireMatrixOracle') `
    'Fire evidence role changed.'
Assert-True (
    $fire.sourceEvidenceId -ceq
        'RZ09-0528-SYNAPSE-FULL-MENU-UPPER-ORACLE-20260730') `
    'Fire evidence ID changed.'
Assert-True ($fire.startupFadeMilliseconds -eq 3500) `
    'Fire startup fade changed.'
Assert-True ($fire.frameIntervalMilliseconds -eq 50) `
    'Fire frame interval changed.'
Assert-True ($fire.frameCount -eq 171 -and $fire.cycleMilliseconds -eq 8550) `
    'Fire captured steady-state loop changed.'
Assert-True ($fire.uncompressedBytes -eq 52326) `
    'Fire oracle byte count changed.'

$tidalHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $tidalPath).Hash
$waveWheelHash = (
    Get-FileHash -Algorithm SHA256 -LiteralPath $waveWheelPath).Hash
$fireHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $firePath).Hash
Assert-True (
    $tidalHash -ceq
        '492994A0A037AF449F8D834BF5E4D536498291499731BE6117F8DCE9BA2AD452') `
    'Tidal sanitized fixture hash changed.'
Assert-True (
    $waveWheelHash -ceq
        '1193D6CC36BFF24706E19A2E5584A04760C68990D3CD194970F83C92988145BD') `
    'Wave/Wheel sanitized fixture hash changed.'
Assert-True (
    $fireHash -ceq
        '874C99039C8204950D233EA7ECE6560985CDC6325D576F82D9F12FA841B25128') `
    'Fire sanitized fixture hash changed.'
Assert-True ($upperAnnotation.capture.rawArtifactsCommitted -eq $false) `
    'The upper-effect annotation must keep raw artifacts private.'
Assert-True ($upperAnnotation.capture.rawHashesPersistedHere -eq $false) `
    'The upper-effect annotation must not expose private evidence hashes.'
Assert-True ($upperAnnotation.protocol.completeFrameCount -eq 2425) `
    'The upper-effect complete-frame count changed.'
Assert-True ($upperAnnotation.protocol.checksumFailureCount -eq 0) `
    'The upper-effect capture must remain checksum-clean.'
Assert-True (
    $upperAnnotation.parameterFindings.audioMeterColorBoost.minimum -eq 1 -and
    $upperAnnotation.parameterFindings.audioMeterColorBoost.maximum -eq 4 -and
    $upperAnnotation.parameterFindings.audioMeterColorBoost.step -eq 0.25) `
    'The exact Synapse Audio Meter Color Boost range changed.'
Assert-True (
    $upperAnnotation.admission.reactiveKeyMap -ceq 'NotInvestigated') `
    'The no-input Reactive control must not admit a physical key map.'
Assert-True (
    $upperAnnotation.sanitizedFixture.sha256 -ceq $fireHash) `
    'The annotation and sanitized Fire fixture hashes diverged.'
$ambientCoverage =
    $coverage.capabilities.keyboardLighting.effects.ambientAwareness
Assert-True (
    $ambientCoverage.matrixFormat -ceq 'Captured' -and
    $ambientCoverage.frameCadence -ceq 'Captured') `
    'The clean Ambient Awareness matrix evidence was not recorded in coverage.'
Assert-True (
    $coverage.capabilities.keyboardLighting.effects.reactive.keyMap -ceq 'Captured') `
    'The later physical-key oracle must advance Reactive key-map coverage without rewriting the earlier no-input control.'

Write-Host 'RZ09-0528 Synapse effect fixture tests passed.'
