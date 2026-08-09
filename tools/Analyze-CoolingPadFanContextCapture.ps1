[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DecodedTransactionsPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$MarkersPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$CaptureStatePath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$resolvedTransactions = (Resolve-Path -LiteralPath $DecodedTransactionsPath `
    -ErrorAction Stop).Path
$resolvedMarkers = (Resolve-Path -LiteralPath $MarkersPath -ErrorAction Stop).Path
$resolvedState = (Resolve-Path -LiteralPath $CaptureStatePath -ErrorAction Stop).Path
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $resolvedOutput) {
    throw "Refusing to overwrite existing analysis: $resolvedOutput"
}

$decoded = Get-Content -LiteralPath $resolvedTransactions -Raw |
    ConvertFrom-Json
$captureState = Get-Content -LiteralPath $resolvedState -Raw |
    ConvertFrom-Json
$markers = @(Get-Content -LiteralPath $resolvedMarkers |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_ | ConvertFrom-Json })

function Get-EpochSeconds {
    param([Parameter(Mandatory)][string]$Timestamp)

    $value = [DateTimeOffset]::Parse(
        $Timestamp,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
    $epoch = [DateTimeOffset]::UnixEpoch
    return [decimal]($value.Ticks - $epoch.Ticks) / [TimeSpan]::TicksPerSecond
}

function Get-OnlyMarker {
    param([Parameter(Mandatory)][string]$Name)

    $matches = @($markers | Where-Object { [string]$_.name -ceq $Name })
    if ($matches.Count -ne 1) {
        throw "Expected exactly one marker named $Name; found $($matches.Count)."
    }
    return $matches[0]
}

function Test-RazerReport {
    param(
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)][string]$StatusHex,
        [Parameter(Mandatory)][string]$ClassHex,
        [Parameter(Mandatory)][string]$CommandHex,
        [AllowEmptyString()][string]$PayloadPrefixHex = ''
    )

    $hex = [Text.RegularExpressions.Regex]::Replace(
        [string]$Transaction.payloadHex,
        '[^0-9A-Fa-f]',
        '').ToUpperInvariant()
    if ($hex.Length -lt 16 -or
        $hex.Substring(0, 2) -cne $StatusHex -or
        $hex.Substring(12, 2) -cne $ClassHex -or
        $hex.Substring(14, 2) -cne $CommandHex) {
        return $false
    }
    if ($PayloadPrefixHex.Length -eq 0) {
        return $true
    }
    return $hex.Length -ge 16 + $PayloadPrefixHex.Length -and
        $hex.Substring(16, $PayloadPrefixHex.Length) -ceq $PayloadPrefixHex
}

function Get-WindowSummary {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$StartMarker,
        [Parameter(Mandatory)][string]$EndMarker
    )

    $start = Get-EpochSeconds ([string](Get-OnlyMarker $StartMarker).atUtc)
    $end = Get-EpochSeconds ([string](Get-OnlyMarker $EndMarker).atUtc)
    if ($end -le $start) {
        throw "Marker window $Name is not strictly ordered."
    }
    $transactions = @($decoded.transactions | Where-Object {
        $epoch = [decimal]::Parse(
            [string]$_.absoluteTimeEpoch,
            [Globalization.CultureInfo]::InvariantCulture)
        $epoch -ge $start -and $epoch -lt $end
    })

    [pscustomobject][ordered]@{
        name = $Name
        transactionCount = $transactions.Count
        lightingFrameRequestCount = @($transactions | Where-Object {
            Test-RazerReport $_ '00' '0F' '03'
        }).Count
        fixed2200RequestCount = @($transactions | Where-Object {
            Test-RazerReport $_ '00' '0D' '10' '01022C'
        }).Count
        fixed2200AcknowledgementCount = @($transactions | Where-Object {
            Test-RazerReport $_ '02' '0D' '10' '01022C'
        }).Count
        autoRequestCount = @($transactions | Where-Object {
            Test-RazerReport $_ '00' '0D' '10' '000600'
        }).Count
        autoAcknowledgementCount = @($transactions | Where-Object {
            Test-RazerReport $_ '02' '0D' '10' '000600'
        }).Count
    }
}

$orderedMarkers = @(
    'PreflightConfirmed',
    'UsbPcapReady',
    'SynapsePadReady',
    'LightingBaselineSaved',
    'RetainedSynapseProcessConfirmed',
    'RetainedLitBaselineConfirmed',
    'RetainedLitFixedStarting',
    'RetainedLitFixedConfirmed',
    'RetainedLitAutoStarting',
    'RetainedLitAutoConfirmed',
    'RetainedSessionContinuityConfirmed',
    'DarkLightingConfirmed',
    'DarkFixedStarting',
    'DarkFixedConfirmed',
    'DarkAutoStarting',
    'DarkAutoConfirmed',
    'DarkContextSameSessionConfirmed',
    'OriginalLightingRestoredBeforeRestart',
    'SynapseExitStarting',
    'SynapseFullyExited',
    'FreshSynapseLaunchStarting',
    'FreshSynapseProcessConfirmed',
    'FreshLitBaselineConfirmed',
    'FreshLitFixedStarting',
    'FreshLitFixedConfirmed',
    'FreshLitAutoStarting',
    'FreshLitAutoConfirmed',
    'FinalSynapseExited',
    'StopRequested',
    'CaptureCompleted'
)
$previousMarkerTime = [decimal]::MinValue
foreach ($requiredMarker in $orderedMarkers) {
    $markerTime = Get-EpochSeconds ([string](Get-OnlyMarker $requiredMarker).atUtc)
    if ($markerTime -le $previousMarkerTime) {
        throw "Marker $requiredMarker is not in strict sequence order."
    }
    $previousMarkerTime = $markerTime
}
if ([string]$captureState.status -cne 'Completed' -or
    [string]$captureState.stopMode -cne 'Graceful' -or
    $captureState.service.managementSkipped -ne $true -or
    $captureState.service.restarted -ne $false -or
    @($captureState.errors).Count -ne 0) {
    throw 'The capture state does not prove graceful, error-free, service-skipped cleanup.'
}

$windows = @(
    Get-WindowSummary `
        'RetainedLitIdle' `
        'RetainedLitBaselineConfirmed' `
        'RetainedLitFixedStarting'
    Get-WindowSummary `
        'RetainedLitFixed' `
        'RetainedLitFixedStarting' `
        'RetainedLitFixedConfirmed'
    Get-WindowSummary `
        'RetainedLitAuto' `
        'RetainedLitAutoStarting' `
        'RetainedLitAutoConfirmed'
    Get-WindowSummary 'DarkIdle' 'DarkLightingConfirmed' 'DarkFixedStarting'
    Get-WindowSummary 'DarkFixed' 'DarkFixedStarting' 'DarkFixedConfirmed'
    Get-WindowSummary 'DarkAuto' 'DarkAutoStarting' 'DarkAutoConfirmed'
    Get-WindowSummary `
        'FreshLitIdle' `
        'FreshLitBaselineConfirmed' `
        'FreshLitFixedStarting'
    Get-WindowSummary `
        'FreshLitFixed' `
        'FreshLitFixedStarting' `
        'FreshLitFixedConfirmed'
    Get-WindowSummary `
        'FreshLitAuto' `
        'FreshLitAutoStarting' `
        'FreshLitAutoConfirmed'
)

$darkWindows = @($windows | Where-Object { $_.name -clike 'Dark*' })
$retainedLitWindows = @($windows | Where-Object {
    $_.name -clike 'RetainedLit*'
})
$freshLitWindows = @($windows | Where-Object {
    $_.name -clike 'FreshLit*'
})
$darkFixed = $windows | Where-Object name -ceq 'DarkFixed'
$darkAuto = $windows | Where-Object name -ceq 'DarkAuto'
$retainedLitFixed = $windows | Where-Object name -ceq 'RetainedLitFixed'
$retainedLitAuto = $windows | Where-Object name -ceq 'RetainedLitAuto'
$freshLitFixed = $windows | Where-Object name -ceq 'FreshLitFixed'
$freshLitAuto = $windows | Where-Object name -ceq 'FreshLitAuto'
$darkFrames = ($darkWindows | Measure-Object lightingFrameRequestCount -Sum).Sum
$retainedLitFrames = ($retainedLitWindows |
    Measure-Object lightingFrameRequestCount -Sum).Sum
$freshLitFrames = ($freshLitWindows |
    Measure-Object lightingFrameRequestCount -Sum).Sum
$darkFanSequenceExact =
    $darkFixed.fixed2200RequestCount -eq 1 -and
    $darkFixed.fixed2200AcknowledgementCount -eq 1 -and
    $darkAuto.autoRequestCount -eq 1 -and
    $darkAuto.autoAcknowledgementCount -eq 1
$retainedLitFanSequenceExact =
    $retainedLitFixed.fixed2200RequestCount -eq 1 -and
    $retainedLitFixed.fixed2200AcknowledgementCount -eq 1 -and
    $retainedLitAuto.autoRequestCount -eq 1 -and
    $retainedLitAuto.autoAcknowledgementCount -eq 1
$freshLitFanSequenceExact =
    $freshLitFixed.fixed2200RequestCount -eq 1 -and
    $freshLitFixed.fixed2200AcknowledgementCount -eq 1 -and
    $freshLitAuto.autoRequestCount -eq 1 -and
    $freshLitAuto.autoAcknowledgementCount -eq 1
$allTransactions = @($decoded.transactions)
$allFanRequests = @($allTransactions | Where-Object {
    Test-RazerReport $_ '00' '0D' '10'
}).Count
$allFanAcknowledgements = @($allTransactions | Where-Object {
    Test-RazerReport $_ '02' '0D' '10'
}).Count
$noUnmarkedFanCommands =
    $allFanRequests -eq 6 -and $allFanAcknowledgements -eq 6

$analysis = [ordered]@{
    schemaVersion = 1
    analyzedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    source = [ordered]@{
        captureSha256 = [string]$decoded.capture.sha256
        captureByteLength = [long]$decoded.capture.byteLength
        decodedTransactionCount = [int]$decoded.transactionCount
        markerCount = $markers.Count
        captureStateCompleted = $true
        captureStopMode = 'Graceful'
        rawPathsIncluded = $false
    }
    windows = $windows
    conclusions = [ordered]@{
        darkLightingFrameStreamAbsent = $darkFrames -eq 0
        retainedLitFrameStreamObserved = $retainedLitFrames -gt 0
        freshLitFrameStreamObserved = $freshLitFrames -gt 0
        retainedLitFanSequenceExactlyObserved = $retainedLitFanSequenceExact
        darkFanSequenceExactlyObserved = $darkFanSequenceExact
        freshLitFanSequenceExactlyObserved = $freshLitFanSequenceExact
        noFanCommandsOutsideMarkedActions = $noUnmarkedFanCommands
        fanSequenceObservedWithoutLightingFrames =
            $darkFrames -eq 0 -and $darkFanSequenceExact
        continuousLightingFramesProvenRequired = if (
            $darkFrames -eq 0 -and $darkFanSequenceExact) {
            $false
        }
        else {
            $null
        }
        priorSynapseProcessSessionProvenRequired = if (
            $freshLitFrames -gt 0 -and $freshLitFanSequenceExact) {
            $false
        }
        else {
            $null
        }
        sameSynapseProcessSetRetainedAcrossLitAndDark = $true
        freshSynapseProcessSetConfirmed = $true
        hidHandleRetentionRequired = $null
        retainedSynapseSessionStillConfounds = $true
        activeModeReadbackConfirmed = $false
        tachometerReadbackConfirmed = $false
        productionWriteAdmitted = $false
    }
}

[IO.Directory]::CreateDirectory(
    [IO.Path]::GetDirectoryName($resolvedOutput)) | Out-Null
[IO.File]::WriteAllText(
    $resolvedOutput,
    ($analysis | ConvertTo-Json -Depth 10),
    [Text.UTF8Encoding]::new($false))

[pscustomobject]@{
    OutputPath = $resolvedOutput
    DarkLightingFrameStreamAbsent = $analysis.conclusions.darkLightingFrameStreamAbsent
    RetainedLitFrameStreamObserved =
        $analysis.conclusions.retainedLitFrameStreamObserved
    FreshLitFrameStreamObserved =
        $analysis.conclusions.freshLitFrameStreamObserved
    FanSequenceObservedWithoutLightingFrames =
        $analysis.conclusions.fanSequenceObservedWithoutLightingFrames
    ProductionWriteAdmitted = $false
}
