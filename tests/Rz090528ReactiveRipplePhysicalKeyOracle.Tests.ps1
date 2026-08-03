$ErrorActionPreference = 'Stop'

$repository = Split-Path $PSScriptRoot -Parent
$analyzerPath = Join-Path $repository (
    'tools\Analyze-Rz090528ReactiveRipplePhysicalKeyOracle.ps1')
$evidencePath = Join-Path $repository (
    'decoded\rz09-0528-pid-02c6-bios-2.02-reactive-ripple-physical-j.json')
$lampArrayPath = Join-Path $repository (
    'decoded\rz09-0528-pid-02c6-bios-2.02-lamp-array.json')
$annotationPath = Join-Path $repository (
    'annotations\2026-07-30-rz09-0528-reactive-ripple-physical-j-oracle.json')
$analyzerSource = Get-Content -Raw -LiteralPath $analyzerPath
$evidence = Get-Content -Raw -LiteralPath $evidencePath | ConvertFrom-Json
$lampArray = Get-Content -Raw -LiteralPath $lampArrayPath | ConvertFrom-Json
$annotation = Get-Content -Raw -LiteralPath $annotationPath | ConvertFrom-Json

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $analyzerPath,
    [ref]$tokens,
    [ref]$errors)
Assert-True ($errors.Count -eq 0) `
    'The physical-key analyzer must parse in Windows PowerShell 5.1.'

foreach ($required in @(
        '$expectedModel = ''RZ09-0528''',
        '$expectedVidPid = ''1532:02C6''',
        '$expectedBios = ''2.02''',
        '$expectedController = ''\\.\USBPcap2''',
        '$expectedAddress = 3',
        '$expectedJSlot = 59')) {
    Assert-True ($analyzerSource -match [regex]::Escape($required)) `
        "The physical-key analyzer dropped exact-target gate '$required'."
}
Assert-True (
    $analyzerSource -match "state.status -cne 'Completed'" -and
    $analyzerSource -match "state.stopMode -cne 'Graceful'" -and
    $analyzerSource -match "state.terminationReason -cne 'StopSentinel'" -and
    $analyzerSource -match '@\(\$state.errors\)\.Count -ne 0') `
    'The analyzer must reject failed, incomplete, or non-graceful captures.'
Assert-True (
    $analyzerSource -match "restoration.effect -cne 'Static'" -and
    $analyzerSource -match "restoration.color -cne '00FF00'" -and
    $analyzerSource -match 'brightnessPercent -ne 50' -and
    $analyzerSource -match "restoration.logoMode -cne 'Static'") `
    'The analyzer must require Static green 50% and Static-logo restoration.'
Assert-True (
    $analyzerSource -match '\$responseSequence = \[int\[\]\]@\(59, 55, 44, 76, 38, 66\)' -and
    $analyzerSource -match "'Short' \{ @\(300, 700\) \}" -and
    $analyzerSource -match "'Medium' \{ @\(1200, 1650\) \}" -and
    $analyzerSource -match "'Long' \{ @\(1700, 2300\) \}") `
    'The analyzer must preserve the operator-correlated J/D/O/N/E/Enter sequence and captured duration bounds.'
Assert-True (
    $analyzerSource -match 'rippleUnion.Count -ne \$activeSlots.Count' -and
    $analyzerSource -match 'traversedEveryActiveSlot = \$true') `
    'The analyzer must require the J-origin Ripple to traverse all active slots.'
Assert-True ($analyzerSource -notmatch 'Get-FileHash') `
    'The analyzer must remain compatible with Windows PowerShell 5.1.'

Assert-True (
    $evidence.device.modelNumber -ceq 'RZ09-0528' -and
    $evidence.device.productIdHex -ceq '02C6' -and
    $evidence.device.bios -ceq '2.02') `
    'The sanitized physical-key evidence changed exact-device identity.'
Assert-True (
    [int]$evidence.source.completeFrameCount -eq 816 -and
    [int]$evidence.source.checksumFailures -eq 0 -and
    -not [bool]$evidence.source.rawCaptureHashIncluded -and
    -not [bool]$evidence.source.uniqueIdentifiersIncluded) `
    'The sanitized evidence must retain clean frame counts without raw hashes or identifiers.'
Assert-True (
    [int]$evidence.reactive.matrixSlot -eq 59 -and
    @($evidence.reactive.durations).Count -eq 3 -and
    [double]$evidence.reactive.durations[0].activeMilliseconds -lt
        [double]$evidence.reactive.durations[1].activeMilliseconds -and
    [double]$evidence.reactive.durations[1].activeMilliseconds -lt
        [double]$evidence.reactive.durations[2].activeMilliseconds) `
    'Reactive J must remain slot 59 with increasing Short, Medium, and Long durations.'
Assert-True (
    [int]$evidence.ripple.originMatrixSlot -eq 59 -and
    [int]$evidence.ripple.traversedActiveSlotCount -eq 86 -and
    [bool]$evidence.ripple.traversedEveryActiveSlot) `
    'Ripple must remain a slot-59 origin that traverses all 86 active slots.'
Assert-True (
    [bool]$evidence.operatorObservation.allEffectsLookedVisuallyCorrect -and
    -not [bool]$evidence.protocol.matrixReadbackObserved) `
    'Operator visual confirmation must remain recorded without being promoted to matrix readback.'

$bottomRow = @($lampArray.lampArray.matrixSlotProjectionByRow)[5]
Assert-True (
    @($bottomRow.lampIndices)[4] -eq 77 -and
    @($bottomRow.matrixSlots)[4] -eq 91 -and
    @($lampArray.lampArray.unmappedLampIndices) -contains 78 -and
    [int]$lampArray.lampArray.selectedVirtualKeyLampIndices.rightAlt -eq 77 -and
    [int]$lampArray.lampArray.physicalOracleCrossCheck.matrixSlot -eq 59) `
    'The exact LampArray projection must keep Right Alt at slot 91, slot 94 unmapped, and J cross-checked at slot 59.'
Assert-True (
    $annotation.capture.rawArtifactsCommitted -eq $false -and
    $annotation.capture.rawHashesPersistedHere -eq $false -and
    $annotation.protocol.matrixGetterObserved -eq $false -and
    $annotation.operatorObservation.evidenceRole -ceq 'VisualConfirmationOnly') `
    'The sanitized annotation must keep raw artifacts private and visual confirmation separate from readback.'

Write-Host 'RZ09-0528 Reactive/Ripple physical-key oracle tests passed.'
