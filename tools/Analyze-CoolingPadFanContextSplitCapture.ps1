[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RetainedDecodedTransactionsPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RetainedMarkersPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RetainedCaptureStatePath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$FreshDecodedTransactionsPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$FreshMarkersPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$FreshCaptureStatePath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$unixEpoch = [DateTimeOffset]::new(
    1970,
    1,
    1,
    0,
    0,
    0,
    [TimeSpan]::Zero)
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $resolvedOutput) {
    throw "Refusing to overwrite existing analysis: $resolvedOutput"
}

$retainedMarkerNames = @(
    'PreflightConfirmed',
    'ProcmonReady',
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
    'DarkAutoConfirmed'
)
$freshMarkerNames = @(
    'PreflightConfirmed',
    'ProcmonReady',
    'UsbPcapReady',
    'FreshSynapseLaunchStarting',
    'FreshSynapseProcessConfirmed',
    'LightingBaselineSaved',
    'FreshLitBaselineConfirmed',
    'FreshLitFixedStarting',
    'FreshLitFixedConfirmed',
    'FreshLitAutoStarting',
    'FreshLitAutoConfirmed',
    'FinalSynapseExited',
    'StopRequested',
    'CaptureCompleted'
)

function Get-EpochSeconds {
    param([Parameter(Mandatory)][string]$Timestamp)

    $value = [DateTimeOffset]::Parse(
        $Timestamp,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
    return [decimal]($value.Ticks - $script:unixEpoch.Ticks) /
        [TimeSpan]::TicksPerSecond
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    return Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
}

function Read-Markers {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$ExpectedNames,
        [Parameter(Mandatory)][string]$Role
    )

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $markers = @(Get-Content -LiteralPath $resolved |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_ | ConvertFrom-Json })
    if ($markers.Count -ne $ExpectedNames.Count) {
        throw "$Role markers did not match the exact completed subset. " +
            "Expected $($ExpectedNames.Count); found $($markers.Count)."
    }

    $byName = @{}
    $previousTime = [decimal]::MinValue
    for ($index = 0; $index -lt $ExpectedNames.Count; $index++) {
        $marker = $markers[$index]
        $expected = $ExpectedNames[$index]
        if ([string]$marker.name -cne $expected) {
            throw "$Role marker $index must be $expected; found $($marker.name)."
        }
        if ($byName.ContainsKey($expected)) {
            throw "$Role marker $expected appeared more than once."
        }

        $time = Get-EpochSeconds ([string]$marker.atUtc)
        if ($time -lt $previousTime) {
            throw "$Role marker $expected is out of timestamp order."
        }
        $previousTime = $time
        $byName[$expected] = $marker
    }

    return [pscustomobject]@{
        Items = $markers
        ByName = $byName
    }
}

function Assert-CaptureState {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$Role
    )

    if ([string]$State.status -cne 'Completed' -or
        [string]$State.stopMode -cne 'Graceful' -or
        [string]$State.terminationReason -cne 'StopSentinel' -or
        [string]$State.captureMode -cne 'DeviceAddress' -or
        $State.service.managementSkipped -ne $true -or
        $State.service.restarted -ne $false -or
        @($State.errors).Count -ne 0) {
        throw "$Role capture state is not a graceful, error-free, " +
            'service-skipped targeted capture.'
    }
}

function Convert-TransactionsToReports {
    param(
        [Parameter(Mandatory)][object]$Decoded,
        [Parameter(Mandatory)][string]$Role
    )

    $transactions = @($Decoded.transactions)
    if ([int]$Decoded.transactionCount -ne $transactions.Count) {
        throw "$Role decoded transaction count is inconsistent."
    }
    if ([string]$Decoded.capture.sha256 -notmatch '^[0-9A-F]{64}$' -or
        [long]$Decoded.capture.byteLength -le 0) {
        throw "$Role decoded capture provenance is malformed."
    }

    $reports = [Collections.Generic.List[object]]::new()
    foreach ($transaction in $transactions) {
        $hex = [Text.RegularExpressions.Regex]::Replace(
            [string]$transaction.payloadHex,
            '[^0-9A-Fa-f]',
            '').ToUpperInvariant()
        if ($hex.Length -lt 16) {
            continue
        }

        $payloadBytes = [Convert]::ToInt32($hex.Substring(10, 2), 16)
        $semanticHexLength = $payloadBytes * 2
        if ($hex.Length -lt 16 + $semanticHexLength) {
            continue
        }

        $epoch = [decimal]::Parse(
            [string]$transaction.absoluteTimeEpoch,
            [Globalization.CultureInfo]::InvariantCulture)
        [void]$reports.Add([pscustomobject][ordered]@{
            frame = [int]$transaction.frame
            epoch = $epoch
            statusHex = $hex.Substring(0, 2)
            transactionIdHex = $hex.Substring(2, 2)
            commandClassHex = $hex.Substring(12, 2)
            commandIdHex = $hex.Substring(14, 2)
            payloadHex = $hex.Substring(16, $semanticHexLength)
        })
    }
    return @($reports)
}

function Get-WindowReports {
    param(
        [Parameter(Mandatory)][object[]]$Reports,
        [Parameter(Mandatory)][object]$Markers,
        [Parameter(Mandatory)][string]$StartMarker,
        [Parameter(Mandatory)][string]$EndMarker,
        [Parameter(Mandatory)][string]$Name
    )

    $start = Get-EpochSeconds ([string]$Markers.ByName[$StartMarker].atUtc)
    $end = Get-EpochSeconds ([string]$Markers.ByName[$EndMarker].atUtc)
    if ($end -le $start) {
        throw "$Name marker window is not strictly ordered."
    }
    return @($Reports | Where-Object {
        $_.epoch -ge $start -and $_.epoch -lt $end
    })
}

function Test-Report {
    param(
        [Parameter(Mandatory)][object]$Report,
        [Parameter(Mandatory)][string]$StatusHex,
        [Parameter(Mandatory)][string]$ClassHex,
        [Parameter(Mandatory)][string]$CommandHex,
        [Parameter(Mandatory)][string]$PayloadHex
    )

    return [string]$Report.statusHex -ceq $StatusHex -and
        [string]$Report.commandClassHex -ceq $ClassHex -and
        [string]$Report.commandIdHex -ceq $CommandHex -and
        [string]$Report.payloadHex -ceq $PayloadHex
}

function Get-LightingFrameCount {
    param([Parameter(Mandatory)][object[]]$Reports)

    return @($Reports | Where-Object {
        [string]$_.statusHex -ceq '00' -and
        [string]$_.commandClassHex -ceq '0F' -and
        [string]$_.commandIdHex -ceq '03' -and
        ([string]$_.payloadHex).Length -eq 118
    }).Count
}

function Assert-FanAction {
    param(
        [Parameter(Mandatory)][object[]]$Reports,
        [Parameter(Mandatory)][string]$PayloadHex,
        [Parameter(Mandatory)][string]$Name
    )

    $fanReports = @($Reports | Where-Object {
        [string]$_.commandClassHex -ceq '0D' -and
        [string]$_.commandIdHex -ceq '10'
    })
    $requests = @($fanReports | Where-Object {
        Test-Report $_ '00' '0D' '10' $PayloadHex
    })
    $acknowledgements = @($fanReports | Where-Object {
        Test-Report $_ '02' '0D' '10' $PayloadHex
    })
    if ($requests.Count -ne 1 -or
        $acknowledgements.Count -ne 1) {
        throw "$Name must contain exactly one request and one status-02 " +
            'acknowledgement with the expected semantic payload.'
    }

    $request = $requests[0]
    $acknowledgement = $acknowledgements[0]
    if ([string]$request.transactionIdHex -cne
            [string]$acknowledgement.transactionIdHex -or
        $acknowledgement.epoch -lt $request.epoch -or
        $acknowledgement.frame -le $request.frame) {
        throw "$Name request and acknowledgement are not an ordered, " +
            'transaction-matched pair.'
    }

    $allRequests = @($fanReports | Where-Object {
        [string]$_.statusHex -ceq '00'
    })
    $allAcknowledgements = @($fanReports | Where-Object {
        [string]$_.statusHex -ceq '02'
    })
    if ($fanReports.Count -ne $allRequests.Count + $allAcknowledgements.Count -or
        $allRequests.Count -ne $allAcknowledgements.Count) {
        throw "$Name contains an unrecognized or unpaired 0D/10 report."
    }
    foreach ($candidateRequest in $allRequests) {
        $candidateAcknowledgements = @($allAcknowledgements | Where-Object {
            [string]$_.transactionIdHex -ceq
                [string]$candidateRequest.transactionIdHex -and
            [string]$_.payloadHex -ceq [string]$candidateRequest.payloadHex -and
            $_.frame -gt $candidateRequest.frame -and
            $_.epoch -ge $candidateRequest.epoch
        })
        if ($candidateAcknowledgements.Count -ne 1) {
            throw "$Name contains an unmatched 0D/10 vendor request."
        }
    }

    return [pscustomobject][ordered]@{
        requestCount = 1
        acknowledgementCount = 1
        statusHex = '02'
        semanticPayloadHex = $PayloadHex
        transactionMatched = $true
        otherAcknowledgedVendorCommandPairCount = $allRequests.Count - 1
    }
}

function Get-PrivateProcessHash {
    param(
        [Parameter(Mandatory)][object]$Marker,
        [Parameter(Mandatory)][string]$Name
    )

    $anchorMatch = [Text.RegularExpressions.Regex]::Match(
        [string]$Marker.note,
        '(?:^|;)ProcessAnchorHash=([0-9A-F]{64})(?:;|$)')
    if ($anchorMatch.Success) {
        return [pscustomobject]@{
            Kind = 'ProcessAnchorHash'
            Value = $anchorMatch.Groups[1].Value
        }
    }

    $setMatch = [Text.RegularExpressions.Regex]::Match(
        [string]$Marker.note,
        '(?:^|;)ProcessSetHash=([0-9A-F]{64})(?:;|$)')
    if ($setMatch.Success) {
        return [pscustomobject]@{
            Kind = 'ProcessSetHash'
            Value = $setMatch.Groups[1].Value
        }
    }
    throw "$Name does not contain private process-session hash evidence."
}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value
    )

    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) |
        Out-Null
    $temporary = "$Path.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText(
            $temporary,
            ($Value | ConvertTo-Json -Depth 10),
            [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

$retainedDecoded = Read-JsonFile $RetainedDecodedTransactionsPath
$retainedState = Read-JsonFile $RetainedCaptureStatePath
$retainedMarkers = Read-Markers `
    $RetainedMarkersPath `
    $retainedMarkerNames `
    'Retained/dark'
$freshDecoded = Read-JsonFile $FreshDecodedTransactionsPath
$freshState = Read-JsonFile $FreshCaptureStatePath
$freshMarkers = Read-Markers $FreshMarkersPath $freshMarkerNames 'Fresh-session'
Assert-CaptureState $retainedState 'Retained/dark'
Assert-CaptureState $freshState 'Fresh-session'

$retainedReports = @(Convert-TransactionsToReports $retainedDecoded 'Retained/dark')
$freshReports = @(Convert-TransactionsToReports $freshDecoded 'Fresh-session')
$retainedLitReports = @(Get-WindowReports `
    $retainedReports `
    $retainedMarkers `
    'RetainedLitBaselineConfirmed' `
    'RetainedLitAutoConfirmed' `
    'Retained lit')
$darkReports = @(Get-WindowReports `
    $retainedReports `
    $retainedMarkers `
    'DarkLightingConfirmed' `
    'DarkAutoConfirmed' `
    'Physically dark')
$freshLitReports = @(Get-WindowReports `
    $freshReports `
    $freshMarkers `
    'FreshLitBaselineConfirmed' `
    'FreshLitAutoConfirmed' `
    'Fresh lit')

$retainedLitFrameCount = Get-LightingFrameCount $retainedLitReports
$darkFrameCount = Get-LightingFrameCount $darkReports
$freshLitFrameCount = Get-LightingFrameCount $freshLitReports
if ($retainedLitFrameCount -le 0) {
    throw 'The retained lit positive-control window contains no 0F/03 frame.'
}
if ($darkFrameCount -ne 0) {
    throw 'The operator-confirmed physically dark window contains a 0F/03 frame.'
}
if ($freshLitFrameCount -le 0) {
    throw 'The fresh-session lit positive-control window contains no 0F/03 frame.'
}

$retainedFixed = Assert-FanAction `
    @(Get-WindowReports $retainedReports $retainedMarkers `
        'RetainedLitFixedStarting' 'RetainedLitFixedConfirmed' `
        'Retained lit Fixed') `
    '01022C' `
    'Retained lit Fixed'
$retainedVendorManagedAuto = Assert-FanAction `
    @(Get-WindowReports $retainedReports $retainedMarkers `
        'RetainedLitAutoStarting' 'RetainedLitAutoConfirmed' `
        'Retained lit Synapse-managed Auto') `
    '000600' `
    'Retained lit Synapse-managed Auto'
$darkFixed = Assert-FanAction `
    @(Get-WindowReports $retainedReports $retainedMarkers `
        'DarkFixedStarting' 'DarkFixedConfirmed' 'Dark Fixed') `
    '01022C' `
    'Dark Fixed'
$darkVendorManagedAuto = Assert-FanAction `
    @(Get-WindowReports $retainedReports $retainedMarkers `
        'DarkAutoStarting' 'DarkAutoConfirmed' `
        'Dark Synapse-managed Auto') `
    '000600' `
    'Dark Synapse-managed Auto'
$freshFixed = Assert-FanAction `
    @(Get-WindowReports $freshReports $freshMarkers `
        'FreshLitFixedStarting' 'FreshLitFixedConfirmed' 'Fresh lit Fixed') `
    '01022C' `
    'Fresh lit Fixed'
$freshVendorManagedAuto = Assert-FanAction `
    @(Get-WindowReports $freshReports $freshMarkers `
        'FreshLitAutoStarting' 'FreshLitAutoConfirmed' `
        'Fresh lit Synapse-managed Auto') `
    '000600' `
    'Fresh lit Synapse-managed Auto'

$retainedProcessHash = Get-PrivateProcessHash `
    $retainedMarkers.ByName['RetainedSynapseProcessConfirmed'] `
    'RetainedSynapseProcessConfirmed'
$continuityProcessHash = Get-PrivateProcessHash `
    $retainedMarkers.ByName['RetainedSessionContinuityConfirmed'] `
    'RetainedSessionContinuityConfirmed'
if ([string]$retainedProcessHash.Kind -cne
        [string]$continuityProcessHash.Kind -or
    [string]$retainedProcessHash.Value -cne
        [string]$continuityProcessHash.Value) {
    throw 'The retained Synapse process evidence changed before the dark context.'
}
$freshLaunchNote =
    [string]$freshMarkers.ByName['FreshSynapseLaunchStarting'].note
if ($freshLaunchNote -cnotmatch 'zero RazerAppEngine processes') {
    throw 'The fresh-session artifact lacks its zero-process launch baseline.'
}
[void](Get-PrivateProcessHash `
    $freshMarkers.ByName['FreshSynapseProcessConfirmed'] `
    'FreshSynapseProcessConfirmed')
if ([string]$freshMarkers.ByName['FinalSynapseExited'].note -cnotmatch
    '(?:^|;)ProcessCount=0(?:;|$)') {
    throw 'The fresh-session artifact lacks its final zero-process marker.'
}

$analysis = [ordered]@{
    schemaVersion = 1
    analyzedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    evidenceRole = 'VendorContextIsolation'
    sources = @(
        [ordered]@{
            role = 'RetainedAndPhysicallyDarkPartial'
            captureSha256 = [string]$retainedDecoded.capture.sha256
            captureByteLength = [long]$retainedDecoded.capture.byteLength
            decodedTransactionCount = [int]$retainedDecoded.transactionCount
            markerCount = $retainedMarkers.Items.Count
            completedGracefully = $true
        },
        [ordered]@{
            role = 'FreshSynapseProcessSession'
            captureSha256 = [string]$freshDecoded.capture.sha256
            captureByteLength = [long]$freshDecoded.capture.byteLength
            decodedTransactionCount = [int]$freshDecoded.transactionCount
            markerCount = $freshMarkers.Items.Count
            completedGracefully = $true
        }
    )
    contexts = [ordered]@{
        retainedLit = [ordered]@{
            lightingFrameRequestCount = $retainedLitFrameCount
            fixed2200 = $retainedFixed
            synapseManagedAuto = $retainedVendorManagedAuto
        }
        retainedPhysicallyDark = [ordered]@{
            lightingFrameRequestCount = $darkFrameCount
            operatorConfirmedPhysicallyDark = $true
            fixed2200 = $darkFixed
            synapseManagedAuto = $darkVendorManagedAuto
        }
        freshSessionLit = [ordered]@{
            lightingFrameRequestCount = $freshLitFrameCount
            freshRazerAppEngineProcessSessionObserved = $true
            fixed2200 = $freshFixed
            synapseManagedAuto = $freshVendorManagedAuto
        }
    }
    conclusions = [ordered]@{
        retainedLitFrameStreamObserved = $true
        physicallyDarkWindowHadZeroLightingFrames = $true
        freshSessionLitFrameStreamObserved = $true
        fixedAndSynapseManagedAutoObservedWithoutLightingFrames = $true
        continuousLightingFramesRequiredForVendorUiTransitions = $false
        retainedSynapseProcessSetObservedBeforeDark = $true
        freshRazerAppEngineProcessSessionObserved = $true
        priorSynapseProcessSessionRequiredForVendorUiTransitions = $false
        darkContextSameProcessSessionConfirmedAfterTransitions = $false
        hidHandleRetentionDetermined = $false
        hidHandleRetentionRequired = $null
        synapseManagedAutoFirmwareOwnershipConfirmed = $false
        activeModeReadbackConfirmed = $false
        physicalFanSpeedReadbackConfirmed = $false
        openBladeWritePerformed = $false
        productionWriteAdmitted = $false
    }
    semanticBoundary =
        'Synapse-managed Auto means only the vendor UI action and its ' +
        'marker-correlated 0D/10 request/acknowledgement. It does not prove ' +
        'pad or firmware ownership, active mode, physical fan speed, literal ' +
        'HID-handle retention, or OpenBlade write safety.'
    privacy = [ordered]@{
        rawArtifactsModified = $false
        rawPathsIncluded = $false
        devicePathsIncluded = $false
        serialNumbersIncluded = $false
        processIdsIncluded = $false
        processAnchorHashesIncluded = $false
    }
}

Write-AtomicJson $resolvedOutput $analysis

[pscustomobject]@{
    OutputPath = $resolvedOutput
    PhysicallyDarkWindowHadZeroLightingFrames = $true
    RetainedLitFrameStreamObserved = $true
    FreshSessionLitFrameStreamObserved = $true
    FixedAndSynapseManagedAutoObservedWithoutLightingFrames = $true
    HidHandleRetentionDetermined = $false
    ProductionWriteAdmitted = $false
}
