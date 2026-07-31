$ErrorActionPreference = 'Stop'

$repository = Split-Path $PSScriptRoot -Parent
$exporterPath = Join-Path $repository (
    'tools\Export-Rz090528SynapseEffectFixtures.ps1')
$tidalPath = Join-Path $repository (
    'decoded\rz09-0528-pid-02c6-bios-2.02-tidal-oracle.json')
$waveWheelPath = Join-Path $repository (
    'decoded\rz09-0528-pid-02c6-bios-2.02-wave-wheel-oracle.json')

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) {
        throw $Message
    }
}

$exporter = Get-Content -Raw -LiteralPath $exporterPath
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

$tidal = Get-Content -Raw -LiteralPath $tidalPath | ConvertFrom-Json
$waveWheel = Get-Content -Raw -LiteralPath $waveWheelPath | ConvertFrom-Json
foreach ($document in @($tidal, $waveWheel)) {
    Assert-True ($document.target.modelNumber -ceq 'RZ09-0528') `
        'Fixture model changed.'
    Assert-True ($document.target.vendorIdHex -ceq '1532') `
        'Fixture VID changed.'
    Assert-True ($document.target.productIdHex -ceq '02C6') `
        'Fixture PID changed.'
    Assert-True ($document.target.bios -ceq '2.02') `
        'Fixture BIOS changed.'
    Assert-True (
        $document.sourceEvidenceId -ceq
            'RZ09-0528-SYNAPSE-QUICK-EFFECTS-ORACLE-20260730') `
        'Fixture evidence ID changed.'
    Assert-True (
        $document.PSObject.Properties.Name -notcontains
            'sourceCaptureSha256') `
        'A sanitized fixture exposed the private capture hash.'
}

Assert-True ($tidal.templates.Count -eq 2) `
    'Tidal must retain both directions.'
Assert-True ($tidal.frameCount -eq 100) `
    'Tidal frame count changed.'
Assert-True ($waveWheel.templates.Count -eq 4) `
    'Wave/Wheel must retain all four variants.'
Assert-True ($waveWheel.frameCount -eq 25) `
    'Wave/Wheel frame count changed.'

$tidalHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $tidalPath).Hash
$waveWheelHash = (
    Get-FileHash -Algorithm SHA256 -LiteralPath $waveWheelPath).Hash
Assert-True (
    $tidalHash -ceq
        '492994A0A037AF449F8D834BF5E4D536498291499731BE6117F8DCE9BA2AD452') `
    'Tidal sanitized fixture hash changed.'
Assert-True (
    $waveWheelHash -ceq
        '1193D6CC36BFF24706E19A2E5584A04760C68990D3CD194970F83C92988145BD') `
    'Wave/Wheel sanitized fixture hash changed.'

Write-Host 'RZ09-0528 Synapse effect fixture tests passed.'
