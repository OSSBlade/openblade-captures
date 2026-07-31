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

$expectedController = '\\.\USBPcap2'
$expectedAddress = 3
$frameIntervalMilliseconds = 50
$settleMilliseconds = 3500
$slotCount = 102
$holeSlots = [int[]]@(
    0, 17, 31, 34, 48, 51, 64, 65, 68, 70, 81, 82, 85, 89, 92, 93)
$sourceEvidenceId =
    'RZ09-0528-SYNAPSE-FULL-MENU-UPPER-ORACLE-20260730'

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

function ConvertFrom-Hex {
    param([Parameter(Mandatory)][string] $Value)

    if (($Value.Length % 2) -ne 0) {
        throw 'A matrix frame contained an odd-length hexadecimal value.'
    }

    [byte[]] $result = New-Object byte[] ($Value.Length / 2)
    for ($index = 0; $index -lt $result.Length; $index++) {
        $result[$index] = [Convert]::ToByte(
            $Value.Substring($index * 2, 2),
            16)
    }
    return ,$result
}

function Compress-Bytes {
    param([Parameter(Mandatory)][byte[]] $Value)

    $memory = New-Object IO.MemoryStream
    $deflate = New-Object IO.Compression.DeflateStream(
        $memory,
        [IO.Compression.CompressionLevel]::Optimal,
        $true)
    try {
        $deflate.Write($Value, 0, $Value.Length)
    }
    finally {
        $deflate.Dispose()
    }
    return [Convert]::ToBase64String($memory.ToArray())
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

$transactions = Get-Content -Raw -LiteralPath $TransactionsPath |
    ConvertFrom-Json
$actions = Get-Content -Raw -LiteralPath $OperatorActionsPath |
    ConvertFrom-Json
$state = Get-Content -Raw -LiteralPath $CaptureStatePath |
    ConvertFrom-Json

if ($actions.target.model -cne 'RZ09-0528' -or
    $actions.target.vendorIdHex -cne '1532' -or
    $actions.target.productIdHex -cne '02C6' -or
    $actions.target.bios -cne '2.02' -or
    $actions.target.usbPcapController -cne $expectedController -or
    [int]$actions.target.capturePlaneDeviceAddress -ne $expectedAddress -or
    $state.status -cne 'Completed' -or
    $state.stopMode -cne 'Graceful' -or
    $state.usbPcapDevice -cne $expectedController -or
    [int]$state.deviceAddress -ne $expectedAddress -or
    @($state.errors).Count -ne 0) {
    throw 'The fixture source is not the clean exact-device oracle capture.'
}
if ($actions.finalUiState.keyboardEffect -cne 'Static' -or
    $actions.finalUiState.keyboardColor -cne 'green' -or
    [int]$actions.finalUiState.brightnessPercent -ne 50 -or
    $actions.finalUiState.logoMode -cne 'Static') {
    throw 'The fixture source does not confirm final user-visible restoration.'
}
if ([int]$transactions.transactionCount -ne @($transactions.transactions).Count -or
    [string]$transactions.capture.sha256 -cnotmatch '^[0-9A-F]{64}$') {
    throw 'The decoded transaction document is incomplete.'
}

$fireActions = @($actions.actions | Where-Object { $_.id -ceq 'fire-select' })
if ($fireActions.Count -ne 1) {
    throw 'The operator log must contain exactly one Fire action.'
}
$fireAction = $fireActions[0]
$captureStart = [DateTimeOffset]::Parse(
    $state.startedAtUtc,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal)
$windowStart =
    (ConvertTo-RelativeSeconds $fireAction.confirmedAtUtc $captureStart) +
    ($settleMilliseconds / 1000.0)
$windowEnd =
    ConvertTo-RelativeSeconds $fireAction.holdCompletedAtUtc $captureStart
if ($windowEnd - $windowStart -lt 8) {
    throw 'The settled Fire capture window is too short.'
}

$pending = @{}
$frames = New-Object Collections.Generic.List[object]
foreach ($transaction in $transactions.transactions) {
    $hex = [string]$transaction.payloadHex
    if ($hex.Length -ne 180) {
        continue
    }
    if (-not (Test-ReportChecksum $hex)) {
        throw "Decoded frame $($transaction.frame) has an invalid checksum."
    }

    $class = $hex.Substring(12, 2)
    $command = $hex.Substring(14, 2)
    if ($class -ceq '03' -and $command -ceq '0B') {
        if ($hex.Substring(10, 2) -cne '37' -or
            $hex.Substring(16, 2) -cne 'FF' -or
            $hex.Substring(20, 4) -cne '0010') {
            throw "Decoded frame $($transaction.frame) has an invalid row envelope."
        }
        $row = [Convert]::ToInt32($hex.Substring(18, 2), 16)
        if ($row -gt 5) {
            throw "Decoded frame $($transaction.frame) has an invalid row."
        }
        if ($row -eq 0 -and $pending.Count -ne 0) {
            $pending.Clear()
        }
        $pending[$row] = $hex.Substring(24, 102)
        continue
    }

    if ($class -ceq '03' -and
        $command -ceq '0A' -and
        $hex.Substring(16, 4) -ceq '0500') {
        if ($pending.Count -eq 6) {
            $rgbHex = -join (0..5 | ForEach-Object { $pending[$_] })
            [void]$frames.Add([pscustomobject]@{
                Frame = [int]$transaction.frame
                Seconds = [double]$transaction.relativeSeconds
                Rgb = ConvertFrom-Hex $rgbHex
            })
        }
        $pending.Clear()
    }
}

$settledFrames = @($frames | Where-Object {
    $_.Seconds -ge $windowStart -and $_.Seconds -le $windowEnd
})
if ($settledFrames.Count -lt 150) {
    throw 'Too few settled Fire frames were reconstructed.'
}

$frameCount = [int][Math]::Floor(
    (($windowEnd - $windowStart) * 1000) / $frameIntervalMilliseconds)
if ($frameCount -lt 160) {
    throw 'The resampled Fire oracle would be too short.'
}

[byte[]] $template = New-Object byte[] ($frameCount * $slotCount * 3)
$sourceFrames = New-Object Collections.Generic.List[int]
for ($sample = 0; $sample -lt $frameCount; $sample++) {
    $targetSeconds =
        $windowStart + ($sample * $frameIntervalMilliseconds / 1000.0)
    $nearest = $null
    $nearestDistance = [double]::PositiveInfinity
    foreach ($frame in $settledFrames) {
        $distance = [Math]::Abs($frame.Seconds - $targetSeconds)
        if ($distance -lt $nearestDistance) {
            $nearest = $frame
            $nearestDistance = $distance
        }
    }
    if ($null -eq $nearest -or $nearestDistance -gt 0.075) {
        throw "No Fire frame is close enough to sample $sample."
    }

    [void]$sourceFrames.Add($nearest.Frame)
    for ($slot = 0; $slot -lt $slotCount; $slot++) {
        $source = $slot * 3
        $destination = (($sample * $slotCount) + $slot) * 3
        $template[$destination] = $nearest.Rgb[$source]
        $template[$destination + 1] = $nearest.Rgb[$source + 1]
        $template[$destination + 2] = $nearest.Rgb[$source + 2]
        $isBlack = $template[$destination] -eq 0 -and
            $template[$destination + 1] -eq 0 -and
            $template[$destination + 2] -eq 0
        if (($holeSlots -contains $slot) -ne $isBlack) {
            throw "Fire sample $sample has an invalid exact-device slot mask."
        }
        if ($template[$destination + 2] -ne 0) {
            throw "Settled Fire sample $sample unexpectedly uses the blue channel."
        }
    }
}

$fixture = [ordered]@{
    schemaVersion = 1
    evidenceRole = 'SanitizedRz090528FireMatrixOracle'
    sourceEvidenceId = $sourceEvidenceId
    target = [ordered]@{
        modelNumber = 'RZ09-0528'
        vendorIdHex = '1532'
        productIdHex = '02C6'
        bios = '2.02'
    }
    sourceActionId = 'fire-select'
    startupFadeMilliseconds = $settleMilliseconds
    cycleMilliseconds = $frameCount * $frameIntervalMilliseconds
    frameIntervalMilliseconds = $frameIntervalMilliseconds
    frameCount = $frameCount
    slotCount = $slotCount
    firstSourceFrame = ($sourceFrames | Measure-Object -Minimum).Minimum
    lastSourceFrame = ($sourceFrames | Measure-Object -Maximum).Maximum
    encoding = 'deflate-base64-rgb24'
    uncompressedBytes = $template.Length
    data = Compress-Bytes $template
}

$fullOutput = [IO.Path]::GetFullPath($OutputPath)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullOutput)) |
    Out-Null
$temporary = "$fullOutput.$PID.tmp"
[IO.File]::WriteAllText(
    $temporary,
    ($fixture | ConvertTo-Json -Depth 8),
    (New-Object Text.UTF8Encoding($false)))
Move-Item -LiteralPath $temporary -Destination $fullOutput -Force

[pscustomobject]@{
    OutputPath = $fullOutput
    FrameCount = $frameCount
    CycleMilliseconds = $frameCount * $frameIntervalMilliseconds
    FirstSourceFrame = $fixture.firstSourceFrame
    LastSourceFrame = $fixture.lastSourceFrame
    RawCaptureHashPersisted = $false
}
