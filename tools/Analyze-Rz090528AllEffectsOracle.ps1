[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $CapturePath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $OperatorActionsPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $CaptureStatePath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $OutputPath,

    [ValidateNotNullOrEmpty()]
    [string] $TsharkPath = 'C:\Program Files\Wireshark\tshark.exe'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$expectedModel = 'RZ09-0528'
$expectedVendorId = '1532'
$expectedProductId = '02C6'
$expectedController = '\\.\USBPcap2'
$expectedDeviceAddress = 3
$holeSlots = [int[]]@(
    0, 17, 31, 34, 48, 51, 64, 65, 68, 70, 81, 82, 85, 89, 92, 93)

function Get-Sha256Hex {
    param([Parameter(Mandatory)][string] $LiteralPath)

    $stream = [IO.File]::OpenRead($LiteralPath)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha256.ComputeHash($stream) |
            ForEach-Object { $_.ToString('X2') })
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Get-TextSha256Hex {
    param([Parameter(Mandatory)][string] $Value)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        return -join ($sha256.ComputeHash($bytes) |
            ForEach-Object { $_.ToString('X2') })
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-Median {
    param([Parameter(Mandatory)][AllowEmptyCollection()][double[]] $Values)

    if ($Values.Count -eq 0) {
        return $null
    }

    [double[]] $sorted = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) {
        return $sorted[$middle]
    }

    return ($sorted[$middle - 1] + $sorted[$middle]) / 2.0
}

function Test-ReportChecksum {
    param([Parameter(Mandatory)][string] $Hex)

    [byte] $checksum = 0
    for ($index = 2; $index -lt 88; $index++) {
        $checksum = $checksum -bxor
            [Convert]::ToByte($Hex.Substring($index * 2, 2), 16)
    }

    return (
        [Convert]::ToByte($Hex.Substring(176, 2), 16) -eq $checksum -and
        $Hex.Substring(178, 2) -ceq '00')
}

function ConvertTo-FrameSummary {
    param(
        [Parameter(Mandatory)][hashtable] $Rows,
        [Parameter(Mandatory)][int] $LatchFrame,
        [Parameter(Mandatory)][double] $LatchSeconds
    )

    $rgb = -join (0..5 | ForEach-Object { [string]$Rows[$_] })
    if ($rgb.Length -ne 102 * 6) {
        throw "Frame $LatchFrame did not reconstruct to 102 RGB slots."
    }

    $unique = @{}
    $litSlots = 0
    for ($slot = 0; $slot -lt 102; $slot++) {
        $color = $rgb.Substring($slot * 6, 6)
        if ($holeSlots -contains $slot) {
            if ($color -cne '000000') {
                throw "Frame $LatchFrame lights captured layout-hole slot $slot."
            }
            continue
        }

        if ($color -cne '000000') {
            $litSlots++
            $unique[$color] = $true
        }
    }

    return [pscustomobject]@{
        LatchFrame = $LatchFrame
        LatchSeconds = $LatchSeconds
        Fingerprint = Get-TextSha256Hex $rgb
        LitSlots = $litSlots
        UniqueLitColors = $unique.Count
    }
}

function ConvertTo-RelativeSeconds {
    param(
        [Parameter(Mandatory)][string] $Timestamp,
        [Parameter(Mandatory)][DateTimeOffset] $CaptureStart
    )

    $parsed = [DateTimeOffset]::Parse(
        $Timestamp,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal)
    return ($parsed.ToUniversalTime() - $CaptureStart.ToUniversalTime()).TotalSeconds
}

function Get-ActionWindowSummary {
    param(
        [Parameter(Mandatory)] $Action,
        [Parameter(Mandatory)][int] $ActionIndex,
        [Parameter(Mandatory)] $Actions,
        [Parameter(Mandatory)][DateTimeOffset] $CaptureStart,
        [Parameter(Mandatory)][DateTimeOffset] $CaptureEnd,
        [Parameter(Mandatory)] $Frames
    )

    $completed = ConvertTo-RelativeSeconds $Action.completedAtUtc $CaptureStart
    $confirmedProperty = $Action.PSObject.Properties['confirmedAtUtc']
    $confirmed = if ($null -ne $confirmedProperty -and
        $null -ne $confirmedProperty.Value) {
        ConvertTo-RelativeSeconds ([string]$confirmedProperty.Value) $CaptureStart
    }
    else {
        $null
    }
    $holdCompletedProperty = $Action.PSObject.Properties['holdCompletedAtUtc']
    $holdCompleted = if ($null -ne $holdCompletedProperty -and
        $null -ne $holdCompletedProperty.Value) {
        ConvertTo-RelativeSeconds ([string]$holdCompletedProperty.Value) $CaptureStart
    }
    else {
        $null
    }

    if ($null -ne $holdCompleted) {
        $windowStart = if ($null -ne $confirmed) { $confirmed } else { $completed }
        $windowEnd = $holdCompleted
    }
    elseif ($null -ne $confirmed -and $confirmed -gt $completed) {
        $windowStart = $completed
        $windowEnd = $confirmed
    }
    else {
        $windowStart = $completed
        $windowEnd = if ($ActionIndex + 1 -lt $Actions.Count) {
            ConvertTo-RelativeSeconds $Actions[$ActionIndex + 1].startedAtUtc $CaptureStart
        }
        else {
            ($CaptureEnd.ToUniversalTime() - $CaptureStart.ToUniversalTime()).TotalSeconds
        }
    }

    $selected = @($Frames | Where-Object {
        $_.LatchSeconds -ge $windowStart -and $_.LatchSeconds -le $windowEnd
    })
    [double[]] $intervals = @(
        for ($index = 1; $index -lt $selected.Count; $index++) {
            ($selected[$index].LatchSeconds - $selected[$index - 1].LatchSeconds) * 1000
        })
    $duration = [Math]::Max(0, $windowEnd - $windowStart)

    return [ordered]@{
        id = [string]$Action.id
        startSeconds = [Math]::Round($windowStart, 6)
        endSeconds = [Math]::Round($windowEnd, 6)
        durationSeconds = [Math]::Round($duration, 6)
        completeFrameCount = $selected.Count
        frameRateHz = if ($duration -gt 0) {
            [Math]::Round($selected.Count / $duration, 3)
        }
        else {
            $null
        }
        medianFrameIntervalMilliseconds = if ($intervals.Count -gt 0) {
            [Math]::Round([double](Get-Median $intervals), 3)
        }
        else {
            $null
        }
        minimumFrameIntervalMilliseconds = if ($intervals.Count -gt 0) {
            [Math]::Round([double]($intervals | Measure-Object -Minimum).Minimum, 3)
        }
        else {
            $null
        }
        maximumFrameIntervalMilliseconds = if ($intervals.Count -gt 0) {
            [Math]::Round([double]($intervals | Measure-Object -Maximum).Maximum, 3)
        }
        else {
            $null
        }
        uniqueFrameFingerprints = if ($selected.Count -gt 0) {
            @($selected |
                ForEach-Object { $_.Fingerprint } |
                Sort-Object -Unique).Count
        }
        else {
            0
        }
        minimumLitSlots = if ($selected.Count -gt 0) {
            [int](($selected |
                ForEach-Object { $_.LitSlots } |
                Measure-Object -Minimum).Minimum)
        }
        else {
            $null
        }
        maximumLitSlots = if ($selected.Count -gt 0) {
            [int](($selected |
                ForEach-Object { $_.LitSlots } |
                Measure-Object -Maximum).Maximum)
        }
        else {
            $null
        }
        maximumUniqueLitColors = if ($selected.Count -gt 0) {
            [int](($selected |
                ForEach-Object { $_.UniqueLitColors } |
                Measure-Object -Maximum).Maximum)
        }
        else {
            $null
        }
    }
}

$resolvedCapture = (Resolve-Path -LiteralPath $CapturePath).Path
$resolvedActions = (Resolve-Path -LiteralPath $OperatorActionsPath).Path
$resolvedState = (Resolve-Path -LiteralPath $CaptureStatePath).Path
$resolvedTshark = (Resolve-Path -LiteralPath $TsharkPath).Path
$actionsDocument = Get-Content -Raw -LiteralPath $resolvedActions | ConvertFrom-Json
$state = Get-Content -Raw -LiteralPath $resolvedState | ConvertFrom-Json

if ($actionsDocument.target.model -cne $expectedModel -or
    $actionsDocument.target.vendorIdHex -cne $expectedVendorId -or
    $actionsDocument.target.productIdHex -cne $expectedProductId -or
    $actionsDocument.target.usbPcapController -cne $expectedController -or
    [int]$actionsDocument.target.capturePlaneDeviceAddress -ne $expectedDeviceAddress) {
    throw 'The operator log is not scoped to the approved exact target.'
}
if ($state.status -cne 'Completed' -or
    $state.stopMode -cne 'Graceful' -or
    $state.usbPcapDevice -cne $expectedController -or
    [int]$state.deviceAddress -ne $expectedDeviceAddress -or
    @($state.errors).Count -ne 0) {
    throw 'The capture state is not a clean exact-device completion.'
}
if ($actionsDocument.finalUiState.keyboardEffect -cne 'Static' -or
    $actionsDocument.finalUiState.keyboardColor -cne 'green' -or
    [int]$actionsDocument.finalUiState.brightnessPercent -ne 50 -or
    $actionsDocument.finalUiState.logoMode -cne 'Static') {
    throw 'The operator log does not confirm the required final restoration.'
}

$rows = @(& $resolvedTshark `
    -r $resolvedCapture `
    -Y 'usb.device_address == 3 && usb.data_len == 98 && usb.data_fragment' `
    -T fields `
    -e frame.number `
    -e frame.time_relative `
    -e usb.data_fragment)
if ($LASTEXITCODE -ne 0 -or $rows.Count -eq 0) {
    throw 'tshark did not return exact-device 90-byte feature reports.'
}

$pendingRows = @{}
$frames = New-Object Collections.Generic.List[object]
$rowReportCount = 0
$latchReportCount = 0
$otherReportCount = 0
$checksumFailureCount = 0
$discardedIncompleteRowSets = 0

foreach ($row in $rows) {
    $fields = $row -split "`t"
    if ($fields.Count -ne 3) {
        throw "Unexpected tshark row: $row"
    }

    $hex = $fields[2].Replace(':', '').ToUpperInvariant()
    if ($hex.Length -ne 180) {
        throw "Frame $($fields[0]) is not a 90-byte Razer report."
    }
    if (-not (Test-ReportChecksum $hex)) {
        $checksumFailureCount++
        continue
    }

    $commandClass = $hex.Substring(12, 2)
    $commandId = $hex.Substring(14, 2)
    if ($commandClass -ceq '03' -and $commandId -ceq '0B') {
        $rowReportCount++
        if ($hex.Substring(10, 2) -cne '37' -or
            $hex.Substring(16, 2) -cne 'FF' -or
            $hex.Substring(20, 4) -cne '0010') {
            throw "Frame $($fields[0]) has an invalid PID 02C6 row envelope."
        }

        $rowIndex = [Convert]::ToByte($hex.Substring(18, 2), 16)
        if ($rowIndex -gt 5) {
            throw "Frame $($fields[0]) has invalid matrix row $rowIndex."
        }
        if ($rowIndex -eq 0 -and $pendingRows.Count -ne 0) {
            $discardedIncompleteRowSets++
            $pendingRows.Clear()
        }
        if ($pendingRows.ContainsKey([int]$rowIndex)) {
            throw "Frame $($fields[0]) repeats matrix row $rowIndex."
        }

        $pendingRows[[int]$rowIndex] = $hex.Substring(24, 102)
        continue
    }

    if ($commandClass -ceq '03' -and $commandId -ceq '0A') {
        $latchReportCount++
        if ($hex.Substring(10, 2) -cne '02' -or
            $hex.Substring(16, 4) -cne '0500') {
            throw "Frame $($fields[0]) has an invalid PID 02C6 latch envelope."
        }

        if ($pendingRows.Count -ne 6) {
            $discardedIncompleteRowSets++
            $pendingRows.Clear()
            continue
        }
        for ($expectedRow = 0; $expectedRow -lt 6; $expectedRow++) {
            if (-not $pendingRows.ContainsKey($expectedRow)) {
                throw "Latch frame $($fields[0]) is missing row $expectedRow."
            }
        }

        [void]$frames.Add((ConvertTo-FrameSummary `
            -Rows $pendingRows `
            -LatchFrame ([int]$fields[0]) `
            -LatchSeconds ([double]::Parse(
                $fields[1],
                [Globalization.CultureInfo]::InvariantCulture))))
        $pendingRows.Clear()
        continue
    }

    $otherReportCount++
}

$captureStart = [DateTimeOffset]::Parse(
    $state.startedAtUtc,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal)
$captureEnd = [DateTimeOffset]::Parse(
    $state.completedAtUtc,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal)
$actionSummaries = @(
    for ($index = 0; $index -lt $actionsDocument.actions.Count; $index++) {
        Get-ActionWindowSummary `
            -Action $actionsDocument.actions[$index] `
            -ActionIndex $index `
            -Actions $actionsDocument.actions `
            -CaptureStart $captureStart `
            -CaptureEnd $captureEnd `
            -Frames $frames
    })

$analysis = [ordered]@{
    schemaVersion = 1
    evidenceRole = 'PrivateRz090528AllEffectsOracleAnalysis'
    target = [ordered]@{
        modelNumber = $expectedModel
        vendorIdHex = $expectedVendorId
        productIdHex = $expectedProductId
        bios = '2.02'
        usbPcapController = $expectedController
        capturePlaneDeviceAddress = $expectedDeviceAddress
    }
    capture = [ordered]@{
        sha256 = Get-Sha256Hex $resolvedCapture
        byteLength = (Get-Item -LiteralPath $resolvedCapture).Length
        startedAtUtc = $captureStart.ToUniversalTime().ToString('O')
        completedAtUtc = $captureEnd.ToUniversalTime().ToString('O')
        status = $state.status
        terminationReason = $state.terminationReason
        stopMode = $state.stopMode
    }
    operatorActions = [ordered]@{
        sha256 = Get-Sha256Hex $resolvedActions
        actionCount = $actionsDocument.actions.Count
        finalRestoration = $actionsDocument.finalUiState
    }
    protocol = [ordered]@{
        capturedFeatureReportCount = $rows.Count
        rowReportCount = $rowReportCount
        latchReportCount = $latchReportCount
        completeFrameCount = $frames.Count
        checksumFailureCount = $checksumFailureCount
        otherReportCount = $otherReportCount
        discardedIncompleteRowSets = $discardedIncompleteRowSets
        incompleteTailRowCount = $pendingRows.Count
        rowCommand = '03/0B'
        rowArguments = 'FF <row:00-05> 00 10 <17 RGB slots>'
        latchCommand = '03/0A'
        latchArguments = '0500'
        rowsPerFrame = 6
        slotsPerFrame = 102
        activeSlots = 86
        holeSlots = $holeSlots
    }
    actionWindows = $actionSummaries
}

$json = $analysis | ConvertTo-Json -Depth 10
$fullOutput = [IO.Path]::GetFullPath($OutputPath)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullOutput)) | Out-Null
$temporary = "$fullOutput.$PID.tmp"
[IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
Move-Item -LiteralPath $temporary -Destination $fullOutput -Force

[pscustomobject]@{
    OutputPath = $fullOutput
    FeatureReports = $rows.Count
    CompleteFrames = $frames.Count
    ChecksumFailures = $checksumFailureCount
    OtherReports = $otherReportCount
    FinalRestorationConfirmed = $true
}
