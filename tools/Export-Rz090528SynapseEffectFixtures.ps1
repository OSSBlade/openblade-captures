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
    [string] $TidalOutputPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $WaveWheelOutputPath,

    [ValidateNotNullOrEmpty()]
    [string] $TsharkPath = 'C:\Program Files\Wireshark\tshark.exe'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$slotCount = 102
$holeSlots = [int[]]@(
    0, 17, 31, 34, 48, 51, 64, 65, 68, 70, 81, 82, 85, 89, 92, 93)
$sourceEvidenceId = 'RZ09-0528-SYNAPSE-QUICK-EFFECTS-ORACLE-20260730'

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

function Get-Action {
    param([Parameter(Mandatory)][string] $Id)

    $matches = @($actions.actions | Where-Object { $_.id -ceq $Id })
    if ($matches.Count -ne 1) {
        throw "Expected one exact operator action '$Id'."
    }
    return $matches[0]
}

function Get-WindowFrames {
    param([Parameter(Mandatory)][string] $ActionId)

    $action = Get-Action $ActionId
    $start = ConvertTo-RelativeSeconds $action.confirmedAtUtc $captureStart
    $end = ConvertTo-RelativeSeconds $action.holdCompletedAtUtc $captureStart
    $selected = @($frames | Where-Object {
        $_.Seconds -ge $start -and $_.Seconds -le $end
    })
    if ($selected.Count -lt 50) {
        throw "Operator action '$ActionId' did not contain enough complete frames."
    }

    return [pscustomobject]@{
        ActionId = $ActionId
        Start = $start
        End = $end
        Frames = $selected
    }
}

function Get-CircularDistance {
    param(
        [Parameter(Mandatory)][double] $Left,
        [Parameter(Mandatory)][double] $Right,
        [Parameter(Mandatory)][double] $CycleSeconds
    )

    $distance = [Math]::Abs($Left - $Right)
    return [Math]::Min($distance, $CycleSeconds - $distance)
}

function Get-NearestPhaseFrame {
    param(
        [Parameter(Mandatory)] $Window,
        [Parameter(Mandatory)][double] $TargetPhase,
        [Parameter(Mandatory)][double] $CycleSeconds,
        [Parameter(Mandatory)][double] $MaximumDistance
    )

    $nearest = $null
    $nearestDistance = [double]::PositiveInfinity
    foreach ($frame in $Window.Frames) {
        $phase = ($frame.Seconds - $Window.Start) % $CycleSeconds
        if ($phase -lt 0) {
            $phase += $CycleSeconds
        }
        $distance = Get-CircularDistance $phase $TargetPhase $CycleSeconds
        if ($distance -lt $nearestDistance) {
            $nearest = $frame
            $nearestDistance = $distance
        }
    }

    if ($null -eq $nearest -or $nearestDistance -gt $MaximumDistance) {
        throw "Action '$($Window.ActionId)' has no frame near phase $TargetPhase."
    }
    return $nearest
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

function Export-TidalTemplate {
    param(
        [Parameter(Mandatory)][string] $ActionId,
        [Parameter(Mandatory)][string] $Direction
    )

    $window = Get-WindowFrames $ActionId
    [byte[]] $template = New-Object byte[] (100 * $slotCount * 2)
    $sourceFrames = New-Object Collections.Generic.List[int]
    for ($sample = 0; $sample -lt 100; $sample++) {
        $frame = Get-NearestPhaseFrame `
            -Window $window `
            -TargetPhase ($sample * 0.05) `
            -CycleSeconds 5.0 `
            -MaximumDistance 0.06
        [void]$sourceFrames.Add($frame.Frame)
        for ($slot = 0; $slot -lt $slotCount; $slot++) {
            $source = $slot * 3
            $red = $frame.Rgb[$source]
            $green = $frame.Rgb[$source + 1]
            $blue = $frame.Rgb[$source + 2]
            $isHole = $holeSlots -contains $slot
            if ($isHole -and ($red -ne 0 -or $green -ne 0 -or $blue -ne 0)) {
                throw "Tidal action '$ActionId' lights layout-hole slot $slot."
            }
            if ($red -ne 0 -or ($green -ne 0 -and $blue -ne 0)) {
                throw "Tidal action '$ActionId' is not the fixed green/blue oracle."
            }

            [int16] $value = if ($green -ne 0) {
                $green
            }
            else {
                -[int]$blue
            }
            [byte[]] $encoded = [BitConverter]::GetBytes($value)
            $destination = (($sample * $slotCount) + $slot) * 2
            $template[$destination] = $encoded[0]
            $template[$destination + 1] = $encoded[1]
        }
    }

    return [ordered]@{
        direction = $Direction
        sourceActionId = $ActionId
        startSeconds = [Math]::Round($window.Start, 6)
        firstSourceFrame = ($sourceFrames | Measure-Object -Minimum).Minimum
        lastSourceFrame = ($sourceFrames | Measure-Object -Maximum).Maximum
        encoding = 'deflate-base64-signed-int16-color1-positive-color2-negative'
        uncompressedBytes = $template.Length
        data = Compress-Bytes $template
    }
}

function Export-WaveWheelTemplate {
    param(
        [Parameter(Mandatory)][string] $ActionId,
        [Parameter(Mandatory)][string] $Effect,
        [Parameter(Mandatory)][string] $Direction
    )

    $window = Get-WindowFrames $ActionId
    [byte[]] $template = New-Object byte[] (25 * $slotCount * 3)
    $sourceFrames = New-Object Collections.Generic.List[int]
    for ($sample = 0; $sample -lt 25; $sample++) {
        $frame = Get-NearestPhaseFrame `
            -Window $window `
            -TargetPhase ($sample * 0.04) `
            -CycleSeconds 1.0 `
            -MaximumDistance 0.06
        [void]$sourceFrames.Add($frame.Frame)
        for ($slot = 0; $slot -lt $slotCount; $slot++) {
            $source = $slot * 3
            $destination = (($sample * $slotCount) + $slot) * 3
            $template[$destination] = $frame.Rgb[$source]
            $template[$destination + 1] = $frame.Rgb[$source + 1]
            $template[$destination + 2] = $frame.Rgb[$source + 2]
            $isBlack = $template[$destination] -eq 0 -and
                $template[$destination + 1] -eq 0 -and
                $template[$destination + 2] -eq 0
            if (($holeSlots -contains $slot) -ne $isBlack) {
                throw "$Effect $Direction has an invalid exact-device slot mask."
            }
        }
    }

    return [ordered]@{
        effect = $Effect
        direction = $Direction
        sourceActionId = $ActionId
        startSeconds = [Math]::Round($window.Start, 6)
        firstSourceFrame = ($sourceFrames | Measure-Object -Minimum).Minimum
        lastSourceFrame = ($sourceFrames | Measure-Object -Maximum).Maximum
        encoding = 'deflate-base64-rgb24'
        uncompressedBytes = $template.Length
        data = Compress-Bytes $template
    }
}

function Write-Fixture {
    param(
        [Parameter(Mandatory)] $Document,
        [Parameter(Mandatory)][string] $LiteralPath
    )

    $fullPath = [IO.Path]::GetFullPath($LiteralPath)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath)) |
        Out-Null
    $temporary = "$fullPath.$PID.tmp"
    [IO.File]::WriteAllText(
        $temporary,
        ($Document | ConvertTo-Json -Depth 8),
        (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $fullPath -Force
    return $fullPath
}

$resolvedCapture = (Resolve-Path -LiteralPath $CapturePath).Path
$resolvedTshark = (Resolve-Path -LiteralPath $TsharkPath).Path
$actions = Get-Content -Raw -LiteralPath $OperatorActionsPath | ConvertFrom-Json
$state = Get-Content -Raw -LiteralPath $CaptureStatePath | ConvertFrom-Json
if ($actions.target.model -cne 'RZ09-0528' -or
    $actions.target.vendorIdHex -cne '1532' -or
    $actions.target.productIdHex -cne '02C6' -or
    $actions.target.usbPcapController -cne '\\.\USBPcap2' -or
    [int]$actions.target.capturePlaneDeviceAddress -ne 3 -or
    $state.status -cne 'Completed' -or
    $state.stopMode -cne 'Graceful' -or
    @($state.errors).Count -ne 0) {
    throw 'The fixture source is not the clean exact-device oracle capture.'
}
if ($actions.finalUiState.keyboardEffect -cne 'Static' -or
    $actions.finalUiState.keyboardColor -cne 'green' -or
    [int]$actions.finalUiState.brightnessPercent -ne 50 -or
    $actions.finalUiState.logoMode -cne 'Static') {
    throw 'The fixture source does not confirm final user-visible restoration.'
}

$captureStart = [DateTimeOffset]::Parse(
    $state.startedAtUtc,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal)
$firstAction = Get-Action 'tidal-green-blue-reverse'
$lastAction = Get-Action 'wheel-button-left'
$minimum = (ConvertTo-RelativeSeconds $firstAction.confirmedAtUtc $captureStart) - 0.1
$maximum = (ConvertTo-RelativeSeconds $lastAction.holdCompletedAtUtc $captureStart) + 0.1
$filter = 'usb.device_address == 3 && usb.data_len == 98 && ' +
    'usb.data_fragment && ' +
    "frame.time_relative >= $minimum && frame.time_relative <= $maximum"
$lines = @(& $resolvedTshark `
    -r $resolvedCapture `
    -Y $filter `
    -T fields `
    -e frame.number `
    -e frame.time_relative `
    -e usb.data_fragment)
if ($LASTEXITCODE -ne 0 -or $lines.Count -lt 1000) {
    throw 'tshark did not return the exact-device effect windows.'
}

$pending = @{}
$frames = New-Object Collections.Generic.List[object]
foreach ($line in $lines) {
    $fields = $line -split "`t"
    if ($fields.Count -ne 3) {
        throw "Unexpected tshark row: $line"
    }
    $hex = $fields[2].Replace(':', '').ToUpperInvariant()
    if ($hex.Length -ne 180) {
        throw "Frame $($fields[0]) is not a 90-byte Razer report."
    }
    $class = $hex.Substring(12, 2)
    $command = $hex.Substring(14, 2)
    if ($class -ceq '03' -and $command -ceq '0B') {
        $row = [Convert]::ToInt32($hex.Substring(18, 2), 16)
        if ($row -eq 0 -and $pending.Count -ne 0) {
            $pending.Clear()
        }
        $pending[$row] = $hex.Substring(24, 102)
    }
    elseif ($class -ceq '03' -and
        $command -ceq '0A' -and
        $hex.Substring(16, 4) -ceq '0500') {
        if ($pending.Count -eq 6) {
            $rgbHex = -join (0..5 | ForEach-Object { $pending[$_] })
            [void]$frames.Add([pscustomobject]@{
                Frame = [int]$fields[0]
                Seconds = [double]::Parse(
                    $fields[1],
                    [Globalization.CultureInfo]::InvariantCulture)
                Rgb = ConvertFrom-Hex $rgbHex
            })
        }
        $pending.Clear()
    }
}
if ($frames.Count -lt 1000) {
    throw 'Too few complete exact-device frames were reconstructed.'
}

$target = [ordered]@{
    modelNumber = 'RZ09-0528'
    vendorIdHex = '1532'
    productIdHex = '02C6'
    bios = '2.02'
}
$tidal = [ordered]@{
    schemaVersion = 1
    evidenceRole = 'SanitizedRz090528TidalMatrixOracle'
    sourceEvidenceId = $sourceEvidenceId
    target = $target
    cycleMilliseconds = 5000
    frameIntervalMilliseconds = 50
    frameCount = 100
    slotCount = $slotCount
    capturedColor1RgbHex = '00FF00'
    capturedColor2RgbHex = '0000FF'
    templates = @(
        Export-TidalTemplate 'tidal-green-blue-reverse' 'Leftward'
        Export-TidalTemplate 'tidal-green-blue-forward' 'Rightward'
    )
}
$waveWheel = [ordered]@{
    schemaVersion = 1
    evidenceRole = 'SanitizedRz090528WaveWheelMatrixOracle'
    sourceEvidenceId = $sourceEvidenceId
    target = $target
    cycleMilliseconds = 1000
    frameIntervalMilliseconds = 40
    frameCount = 25
    slotCount = $slotCount
    templates = @(
        Export-WaveWheelTemplate 'wave-left' 'Wave' 'Leftward'
        Export-WaveWheelTemplate 'wave-right' 'Wave' 'Rightward'
        Export-WaveWheelTemplate 'wheel-button-right' 'Wheel' 'Clockwise'
        Export-WaveWheelTemplate 'wheel-button-left' 'Wheel' 'Counterclockwise'
    )
}

$tidalPath = Write-Fixture $tidal $TidalOutputPath
$waveWheelPath = Write-Fixture $waveWheel $WaveWheelOutputPath
[pscustomobject]@{
    TidalOutputPath = $tidalPath
    WaveWheelOutputPath = $waveWheelPath
    CompleteSourceFrames = $frames.Count
    SourceEvidenceId = $sourceEvidenceId
    RawCaptureHashPersisted = $false
}
