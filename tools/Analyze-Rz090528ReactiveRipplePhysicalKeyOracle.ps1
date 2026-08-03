[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $TransactionsPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $OperatorActionsPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $CaptureStatePath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$expectedModel = 'RZ09-0528'
$expectedVidPid = '1532:02C6'
$expectedBios = '2.02'
$expectedController = '\\.\USBPcap2'
$expectedAddress = 3
$expectedJSlot = 59
$holeSlots = [int[]]@(
    0, 17, 31, 34, 48, 51, 64, 65, 68, 70, 81, 82, 85, 89, 92, 93)
$activeSlots = [int[]]@(
    0..101 | Where-Object { $holeSlots -notcontains $_ })

function ConvertFrom-HexString {
    param([Parameter(Mandatory)][string] $Value)

    if (($Value.Length % 2) -ne 0) {
        throw 'A decoded report contained an odd-length hexadecimal payload.'
    }

    $bytes = [byte[]]::new($Value.Length / 2)
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        $bytes[$index] = [Convert]::ToByte($Value.Substring($index * 2, 2), 16)
    }
    return ,$bytes
}

function Test-ReportChecksum {
    param([Parameter(Mandatory)][byte[]] $Report)

    if ($Report.Length -ne 90) {
        return $false
    }

    [byte] $checksum = 0
    for ($index = 2; $index -lt 88; $index++) {
        $checksum = $checksum -bxor $Report[$index]
    }
    return $Report[88] -eq $checksum -and $Report[89] -eq 0
}

function ConvertTo-RelativeSeconds {
    param(
        [Parameter(Mandatory)][string] $Timestamp,
        [Parameter(Mandatory)][DateTimeOffset] $CaptureStart)

    $parsed = [DateTimeOffset]::Parse(
        $Timestamp,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal)
    return ($parsed.ToUniversalTime() - $CaptureStart.ToUniversalTime()).TotalSeconds
}

function Get-ActionWindow {
    param(
        [Parameter(Mandatory)] $Action,
        [Parameter(Mandatory)][DateTimeOffset] $CaptureStart)

    return [pscustomobject]@{
        Start = ConvertTo-RelativeSeconds ([string]$Action.armedUtc) $CaptureStart
        End = ConvertTo-RelativeSeconds `
            ([string]$Action.operatorReplyReceivedUtc) $CaptureStart
    }
}

function Get-SlotColor {
    param(
        [Parameter(Mandatory)] $Frame,
        [Parameter(Mandatory)][int] $Slot)

    return @($Frame.Lit | Where-Object { $_.Slot -eq $Slot }) |
        Select-Object -First 1
}

function Get-RiseEvents {
    param([Parameter(Mandatory)] $Frames)

    $events = [Collections.Generic.List[object]]::new()
    $previous = [Collections.Generic.HashSet[int]]::new()
    foreach ($frame in $Frames) {
        $current = [Collections.Generic.HashSet[int]]::new()
        foreach ($color in @($frame.Lit)) {
            [void]$current.Add([int]$color.Slot)
        }
        foreach ($slot in $current) {
            if (-not $previous.Contains($slot)) {
                $events.Add([pscustomobject]@{
                    Time = [double]$frame.Time
                    Slot = [int]$slot
                })
            }
        }
        $previous = $current
    }
    return ,$events.ToArray()
}

function Find-ResponseSequence {
    param(
        [Parameter(Mandatory)] $Events,
        [Parameter(Mandatory)][int[]] $ExpectedSlots)

    foreach ($candidate in @($Events | Where-Object {
        $_.Slot -eq $ExpectedSlots[0]
    })) {
        $matched = [Collections.Generic.List[object]]::new()
        $matched.Add($candidate)
        $cursor = [double]$candidate.Time
        $limit = $cursor + 5.0
        $valid = $true
        for ($index = 1; $index -lt $ExpectedSlots.Count; $index++) {
            $next = @($Events | Where-Object {
                $_.Time -gt $cursor -and
                $_.Time -le $limit -and
                $_.Slot -eq $ExpectedSlots[$index]
            }) | Select-Object -First 1
            if ($null -eq $next) {
                $valid = $false
                break
            }
            $matched.Add($next)
            $cursor = [double]$next.Time
        }
        if ($valid) {
            return ,$matched.ToArray()
        }
    }
    return $null
}

function Measure-ReactivePulse {
    param(
        [Parameter(Mandatory)] $Frames,
        [Parameter(Mandatory)][double] $OnsetSeconds,
        [Parameter(Mandatory)][string] $DurationName)

    $samples = [Collections.Generic.List[object]]::new()
    $started = $false
    foreach ($frame in @($Frames | Where-Object {
        $_.Time -ge $OnsetSeconds -and $_.Time -le ($OnsetSeconds + 4.0)
    })) {
        $color = Get-SlotColor $frame $expectedJSlot
        if ($null -ne $color) {
            $started = $true
            if ([int]$color.R -ne 0 -or [int]$color.B -ne 0) {
                throw "$DurationName Reactive J pulse was not green-only."
            }
            $samples.Add([pscustomobject]@{
                Time = [double]$frame.Time
                Green = [int]$color.G
            })
        }
        elseif ($started) {
            break
        }
    }
    if ($samples.Count -lt 2) {
        throw "$DurationName Reactive J pulse did not contain enough samples."
    }

    $first = $samples[0]
    $last = $samples[$samples.Count - 1]
    $activeMilliseconds = ([double]$last.Time - [double]$first.Time) * 1000
    $limits = switch ($DurationName) {
        'Short' { @(300, 700) }
        'Medium' { @(1200, 1650) }
        'Long' { @(1700, 2300) }
        default { throw "Unexpected Reactive duration '$DurationName'." }
    }
    if ($activeMilliseconds -lt $limits[0] -or
        $activeMilliseconds -gt $limits[1]) {
        throw (
            "$DurationName Reactive J pulse duration " +
            "$([Math]::Round($activeMilliseconds, 3)) ms was outside " +
            "the expected captured range $($limits[0])-$($limits[1]) ms.")
    }

    return [ordered]@{
        duration = $DurationName
        onsetSeconds = [Math]::Round([double]$first.Time, 6)
        activeMilliseconds = [Math]::Round($activeMilliseconds, 3)
        frameCount = $samples.Count
        peakGreen = [int](($samples.Green | Measure-Object -Maximum).Maximum)
        finalGreen = [int]$last.Green
        matrixSlot = $expectedJSlot
    }
}

$resolvedTransactions = (Resolve-Path -LiteralPath $TransactionsPath).Path
$resolvedActions = (Resolve-Path -LiteralPath $OperatorActionsPath).Path
$resolvedState = (Resolve-Path -LiteralPath $CaptureStatePath).Path
$transactions = Get-Content -Raw -LiteralPath $resolvedTransactions |
    ConvertFrom-Json
$actionsDocument = Get-Content -Raw -LiteralPath $resolvedActions |
    ConvertFrom-Json
$state = Get-Content -Raw -LiteralPath $resolvedState | ConvertFrom-Json

if ($actionsDocument.device.model -cne $expectedModel -or
    $actionsDocument.device.usbVidPid -cne $expectedVidPid -or
    $actionsDocument.device.bios -cne $expectedBios) {
    throw 'The operator log is not scoped to the exact approved device.'
}
if ($state.status -cne 'Completed' -or
    $state.stopMode -cne 'Graceful' -or
    $state.terminationReason -cne 'StopSentinel' -or
    $state.usbPcapDevice -cne $expectedController -or
    [int]$state.deviceAddress -ne $expectedAddress -or
    @($state.errors).Count -ne 0) {
    throw 'The capture state is not a clean exact-device completion.'
}
if ($actionsDocument.restoration.effect -cne 'Static' -or
    $actionsDocument.restoration.color -cne '00FF00' -or
    [int]$actionsDocument.restoration.brightnessPercent -ne 50 -or
    $actionsDocument.restoration.logoMode -cne 'Static') {
    throw 'The operator log does not confirm the required final restoration.'
}
if ([int]$transactions.transactionCount -ne @($transactions.transactions).Count) {
    throw 'The decoded transaction count does not match the transaction array.'
}

$frames = [Collections.Generic.List[object]]::new()
$rows = @{}
$rowReports = 0
$latches = 0
$checksumFailures = 0
$discardedIncompleteSets = 0
foreach ($transaction in @($transactions.transactions)) {
    $hex = [string]$transaction.payloadHex
    if ($hex.Length -ne 180) {
        continue
    }
    [byte[]] $report = ConvertFrom-HexString $hex
    if ($report[6] -eq 0x03 -and $report[7] -eq 0x0B) {
        $rowReports++
        if (-not (Test-ReportChecksum $report)) {
            $checksumFailures++
            continue
        }
        if ($report[8] -ne 0xFF -or
            $report[9] -gt 5 -or
            $report[10] -ne 0 -or
            $report[11] -ne 0x10) {
            throw "Frame $($transaction.frame) contained an invalid PID 02C6 row."
        }
        $rows[[int]$report[9]] = [byte[]]$report[12..62]
        continue
    }
    if ($report[6] -ne 0x03 -or $report[7] -ne 0x0A) {
        continue
    }

    $latches++
    if (-not (Test-ReportChecksum $report)) {
        $checksumFailures++
        $rows.Clear()
        continue
    }
    if ($report[8] -ne 0x05 -or $report[9] -ne 0x00) {
        throw "Frame $($transaction.frame) contained an invalid PID 02C6 latch."
    }
    if ($rows.Count -ne 6) {
        $discardedIncompleteSets++
        $rows.Clear()
        continue
    }

    $rgb = [Collections.Generic.List[byte]]::new(306)
    foreach ($row in 0..5) {
        $rgb.AddRange([byte[]]$rows[$row])
    }
    $rows.Clear()
    $lit = [Collections.Generic.List[object]]::new()
    for ($slot = 0; $slot -lt 102; $slot++) {
        $offset = $slot * 3
        $red = [int]$rgb[$offset]
        $green = [int]$rgb[$offset + 1]
        $blue = [int]$rgb[$offset + 2]
        if ($holeSlots -contains $slot) {
            if ($red -ne 0 -or $green -ne 0 -or $blue -ne 0) {
                throw "Frame $($transaction.frame) lit layout-hole slot $slot."
            }
            continue
        }
        if ($red -ne 0 -or $green -ne 0 -or $blue -ne 0) {
            $lit.Add([pscustomobject]@{
                Slot = $slot
                R = $red
                G = $green
                B = $blue
            })
        }
    }
    $frames.Add([pscustomobject]@{
        Frame = [int]$transaction.frame
        Time = [double]$transaction.relativeSeconds
        Lit = $lit.ToArray()
    })
}

if ($checksumFailures -ne 0) {
    throw "The capture contained $checksumFailures checksum failures."
}
if ($frames.Count -eq 0) {
    throw 'The capture contained no complete PID 02C6 matrix frames.'
}

$captureStart = [DateTimeOffset]::Parse([string]$state.startedAtUtc)
$reactiveResults = [Collections.Generic.List[object]]::new()
$responseSequence = [int[]]@(59, 55, 44, 76, 38, 66)
foreach ($action in @($actionsDocument.operatorActions | Where-Object {
    $_.effect -ceq 'Reactive'
})) {
    $window = Get-ActionWindow $action $captureStart
    $windowFrames = @($frames | Where-Object {
        $_.Time -ge $window.Start -and $_.Time -le $window.End
    })
    $events = Get-RiseEvents $windowFrames
    $matched = Find-ResponseSequence $events $responseSequence
    if ($null -eq $matched) {
        throw (
            "Reactive $($action.parameters.duration) did not contain the " +
            'operator-correlated J,D,O,N,E,Enter response sequence.')
    }
    $reactiveResults.Add(
        (Measure-ReactivePulse `
            $windowFrames `
            ([double]$matched[0].Time) `
            ([string]$action.parameters.duration)))
}
if ($reactiveResults.Count -ne 3) {
    throw 'Expected exactly three Reactive duration samples.'
}
if (-not (
    $reactiveResults[0].activeMilliseconds -lt
        $reactiveResults[1].activeMilliseconds -and
    $reactiveResults[1].activeMilliseconds -lt
        $reactiveResults[2].activeMilliseconds)) {
    throw 'Reactive Short, Medium, and Long did not have increasing durations.'
}

$rippleAction = @($actionsDocument.operatorActions | Where-Object {
    $_.effect -ceq 'Ripple'
})
if ($rippleAction.Count -ne 1) {
    throw 'Expected exactly one Ripple physical-key action.'
}
$rippleWindow = Get-ActionWindow $rippleAction[0] $captureStart
$rippleFrames = @($frames | Where-Object {
    $_.Time -ge $rippleWindow.Start -and $_.Time -le $rippleWindow.End
})
$rippleOrigin = @($rippleFrames | Where-Object {
    @($_.Lit).Count -eq 1 -and [int]$_.Lit[0].Slot -eq $expectedJSlot
}) | Select-Object -First 1
if ($null -eq $rippleOrigin -or
    [int]$rippleOrigin.Lit[0].R -ne 0 -or
    [int]$rippleOrigin.Lit[0].G -ne 255 -or
    [int]$rippleOrigin.Lit[0].B -ne 0) {
    throw 'Ripple did not begin from one full-green J slot.'
}
$nextTypedKeyOrigin = @($rippleFrames | Where-Object {
    $_.Time -gt $rippleOrigin.Time -and
    @($_.Lit).Count -eq 1 -and
    [int]$_.Lit[0].Slot -eq 55
}) | Select-Object -First 1
if ($null -eq $nextTypedKeyOrigin) {
    throw 'Ripple did not contain the expected following D-key origin bound.'
}
$rippleEpisode = @($rippleFrames | Where-Object {
    $_.Time -ge $rippleOrigin.Time -and
    $_.Time -lt $nextTypedKeyOrigin.Time
})
$rippleUnion = @($rippleEpisode |
    ForEach-Object { $_.Lit } |
    ForEach-Object { [int]$_.Slot } |
    Sort-Object -Unique)
if ($rippleUnion.Count -ne $activeSlots.Count -or
    @(Compare-Object $activeSlots $rippleUnion).Count -ne 0) {
    throw 'The J-origin Ripple did not traverse all 86 active PID 02C6 slots.'
}
$maximumRippleSlots = [int](($rippleEpisode |
    ForEach-Object { @($_.Lit).Count } |
    Measure-Object -Maximum).Maximum)

$result = [ordered]@{
    schemaVersion = 1
    device = [ordered]@{
        modelNumber = $expectedModel
        vendorIdHex = '1532'
        productIdHex = '02C6'
        bios = $expectedBios
    }
    source = [ordered]@{
        capturePlane = $expectedController
        transientDeviceAddress = $expectedAddress
        transactionCount = [int]$transactions.transactionCount
        rowReportCount = $rowReports
        latchCount = $latches
        completeFrameCount = $frames.Count
        discardedIncompleteFrameSets = $discardedIncompleteSets
        checksumFailures = $checksumFailures
        rawCaptureHashIncluded = $false
        uniqueIdentifiersIncluded = $false
    }
    protocol = [ordered]@{
        rowCommand = '03/0B'
        rowArguments = 'FF <row 00-05> 00 10 <17 RGB>'
        latchCommand = '03/0A'
        latchArguments = '0500'
        layoutSlots = 102
        activeSlots = 86
        holeSlots = $holeSlots
        matrixReadbackObserved = $false
    }
    reactive = [ordered]@{
        physicalKey = 'J'
        matrixSlot = $expectedJSlot
        color = '00FF00'
        operatorCorrelatedResponseSlots = $responseSequence
        durations = $reactiveResults.ToArray()
        durationOrdering = 'Short < Medium < Long'
    }
    ripple = [ordered]@{
        physicalKey = 'J'
        originMatrixSlot = $expectedJSlot
        originColor = '00FF00'
        originSeconds = [Math]::Round([double]$rippleOrigin.Time, 6)
        episodeFrameCount = $rippleEpisode.Count
        maximumSimultaneouslyLitSlots = $maximumRippleSlots
        traversedActiveSlotCount = $rippleUnion.Count
        traversedEveryActiveSlot = $true
    }
    operatorObservation = [ordered]@{
        allEffectsLookedVisuallyCorrect = $true
        finalKeyboardEffect = 'Static'
        finalKeyboardColor = '00FF00'
        finalBrightnessPercent = 50
        finalLogoMode = 'Static'
    }
    boundaries = @(
        'The operator visual observation is not a matrix GET or independent device readback.',
        'Only J received a direct physical Reactive/Ripple origin correlation in this trace.',
        'The remaining ordinary-key map is derived separately from the exact read-only PID 02C6 LampArray geometry.',
        'No PCAP hash, serial number, or other unique identifier is included.'
    )
}

$fullOutput = [IO.Path]::GetFullPath($OutputPath)
$parent = [IO.Path]::GetDirectoryName($fullOutput)
if (-not [string]::IsNullOrWhiteSpace($parent)) {
    [IO.Directory]::CreateDirectory($parent) | Out-Null
}
[IO.File]::WriteAllText(
    $fullOutput,
    (($result | ConvertTo-Json -Depth 20) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false))

[pscustomobject]@{
    OutputPath = $fullOutput
    CompleteFrames = $frames.Count
    ReactiveSamples = $reactiveResults.Count
    RippleActiveSlots = $rippleUnion.Count
}
