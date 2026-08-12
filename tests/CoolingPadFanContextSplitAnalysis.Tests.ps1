[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$analyzerPath = Join-Path $repository `
    'tools\Analyze-CoolingPadFanContextSplitCapture.ps1'
$source = Get-Content -LiteralPath $analyzerPath -Raw

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$tokens = $null
$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
    $analyzerPath,
    [ref]$tokens,
    [ref]$errors)
Assert-True ($errors.Count -eq 0) `
    'The split capture analyzer must parse in Windows PowerShell 5.1.'
Assert-True ($source.Contains('1970,') -and $source.Contains('1,') -and
    -not $source.Contains('[DateTimeOffset]::UnixEpoch')) `
    'The analyzer must use an explicit Unix epoch supported by Windows PowerShell 5.1.'
Assert-True ($source.Contains('Synapse-managed Auto')) `
    'The analyzer lost the Synapse-managed Auto semantic boundary.'
Assert-True ($source.Contains('hidHandleRetentionRequired = $null')) `
    'The analyzer must not infer literal HID-handle retention from split USB captures.'
Assert-True ($source.Contains('productionWriteAdmitted = $false')) `
    'The analyzer must not admit a production writer.'

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
$base = [DateTimeOffset]::Parse('2026-08-09T22:00:00Z')
$baseEpoch = [decimal]1786312800
$privateRetainedHash = 'A' * 64
$privateFreshHash = 'B' * 64
$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    "openblade-cooling-pad-split-$([Guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($testRoot) | Out-Null

function Write-MarkerSubset {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][hashtable]$Offsets,
        [Parameter(Mandatory)][bool]$Fresh
    )

    $lines = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $Names.Count; $index++) {
        $name = $Names[$index]
        $offset = $index * 10
        $Offsets[$name] = $offset
        $note = switch ($name) {
            'RetainedSynapseProcessConfirmed' {
                "ProcessCount=14;ProcessSetHash=$privateRetainedHash"
            }
            'RetainedSessionContinuityConfirmed' {
                "ProcessCount=14;ProcessSetHash=$privateRetainedHash"
            }
            'FreshSynapseLaunchStarting' {
                'Preflight observed zero RazerAppEngine processes'
            }
            'FreshSynapseProcessConfirmed' {
                "ProcessCount=14;ProcessSetHash=$privateFreshHash;" +
                    "ProcessAnchorHash=$privateFreshHash"
            }
            'FinalSynapseExited' {
                'SynapseManagedAuto=True;BrightnessPercent=100;ProcessCount=0'
            }
            default { '' }
        }
        [void]$lines.Add((([ordered]@{
            atUtc = $base.AddSeconds($offset).ToString('O')
            name = $name
            note = $note
        } | ConvertTo-Json -Compress)))
    }
    [IO.File]::WriteAllLines(
        $Path,
        $lines,
        [Text.UTF8Encoding]::new($false))
}

function New-ReportHex {
    param(
        [Parameter(Mandatory)][byte]$Status,
        [Parameter(Mandatory)][byte]$TransactionId,
        [Parameter(Mandatory)][byte]$Class,
        [Parameter(Mandatory)][byte]$Command,
        [Parameter(Mandatory)][byte[]]$Payload
    )

    $bytes = New-Object byte[] 90
    $bytes[0] = $Status
    $bytes[1] = $TransactionId
    $bytes[5] = [byte]$Payload.Length
    $bytes[6] = $Class
    $bytes[7] = $Command
    [Array]::Copy($Payload, 0, $bytes, 8, $Payload.Length)
    return [BitConverter]::ToString($bytes).Replace('-', '')
}

function Add-Transaction {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[object]]$Transactions,
        [Parameter(Mandatory)][hashtable]$Offsets,
        [Parameter(Mandatory)][string]$AfterMarker,
        [Parameter(Mandatory)][decimal]$SecondsAfterMarker,
        [Parameter(Mandatory)][byte]$Status,
        [Parameter(Mandatory)][byte]$TransactionId,
        [Parameter(Mandatory)][byte]$Class,
        [Parameter(Mandatory)][byte]$Command,
        [Parameter(Mandatory)][byte[]]$Payload
    )

    $epoch = $baseEpoch + [decimal]$Offsets[$AfterMarker] +
        $SecondsAfterMarker
    [void]$Transactions.Add([ordered]@{
        frame = $Transactions.Count + 1
        absoluteTimeEpoch = $epoch.ToString(
            [Globalization.CultureInfo]::InvariantCulture)
        payloadHex = New-ReportHex `
            $Status `
            $TransactionId `
            $Class `
            $Command `
            $Payload
    })
}

function Add-Pair {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[object]]$Transactions,
        [Parameter(Mandatory)][hashtable]$Offsets,
        [Parameter(Mandatory)][string]$AfterMarker,
        [Parameter(Mandatory)][byte]$TransactionId,
        [Parameter(Mandatory)][byte[]]$Payload
    )

    Add-Transaction $Transactions $Offsets $AfterMarker 1 `
        0 $TransactionId 0x0D 0x10 $Payload
    Add-Transaction $Transactions $Offsets $AfterMarker 2 `
        2 $TransactionId 0x0D 0x10 $Payload
}

function Write-Decoded {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[object]]$Transactions,
        [Parameter(Mandatory)][string]$Hash
    )

    [IO.File]::WriteAllText(
        $Path,
        ([ordered]@{
            schemaVersion = 1
            capture = [ordered]@{
                sha256 = $Hash
                byteLength = 1234
            }
            transactionCount = $Transactions.Count
            transactions = @($Transactions)
        } | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
}

function Write-State {
    param([Parameter(Mandatory)][string]$Path)

    [IO.File]::WriteAllText(
        $Path,
        ([ordered]@{
            status = 'Completed'
            terminationReason = 'StopSentinel'
            stopMode = 'Graceful'
            captureMode = 'DeviceAddress'
            service = [ordered]@{
                managementSkipped = $true
                restarted = $false
            }
            errors = @()
        } | ConvertTo-Json -Depth 5),
        [Text.UTF8Encoding]::new($false))
}

function Invoke-Analyzer {
    param(
        [Parameter(Mandatory)][string]$RetainedDecoded,
        [Parameter(Mandatory)][string]$RetainedMarkers,
        [Parameter(Mandatory)][string]$RetainedState,
        [Parameter(Mandatory)][string]$FreshDecoded,
        [Parameter(Mandatory)][string]$FreshMarkers,
        [Parameter(Mandatory)][string]$FreshState,
        [Parameter(Mandatory)][string]$Output
    )

    & $analyzerPath `
        -RetainedDecodedTransactionsPath $RetainedDecoded `
        -RetainedMarkersPath $RetainedMarkers `
        -RetainedCaptureStatePath $RetainedState `
        -FreshDecodedTransactionsPath $FreshDecoded `
        -FreshMarkersPath $FreshMarkers `
        -FreshCaptureStatePath $FreshState `
        -OutputPath $Output | Out-Null
}

try {
    $retainedMarkersPath = Join-Path $testRoot 'retained-markers.jsonl'
    $freshMarkersPath = Join-Path $testRoot 'fresh-markers.jsonl'
    $retainedDecodedPath = Join-Path $testRoot 'retained-decoded.json'
    $freshDecodedPath = Join-Path $testRoot 'fresh-decoded.json'
    $retainedStatePath = Join-Path $testRoot 'retained-state.json'
    $freshStatePath = Join-Path $testRoot 'fresh-state.json'
    $analysisPath = Join-Path $testRoot 'analysis.json'
    $retainedOffsets = @{}
    $freshOffsets = @{}
    Write-MarkerSubset `
        $retainedMarkersPath `
        $retainedMarkerNames `
        $retainedOffsets `
        $false
    Write-MarkerSubset `
        $freshMarkersPath `
        $freshMarkerNames `
        $freshOffsets `
        $true
    Write-State $retainedStatePath
    Write-State $freshStatePath

    $retainedTransactions = [Collections.Generic.List[object]]::new()
    Add-Transaction $retainedTransactions $retainedOffsets `
        'RetainedLitBaselineConfirmed' 1 0 1 0x0F 0x03 `
        (New-Object byte[] 59)
    Add-Pair $retainedTransactions $retainedOffsets `
        'RetainedLitFixedStarting' 2 ([byte[]](1, 0, 0x20))
    Add-Pair $retainedTransactions $retainedOffsets `
        'RetainedLitFixedStarting' 3 ([byte[]](1, 2, 0x2C))
    Add-Pair $retainedTransactions $retainedOffsets `
        'RetainedLitAutoStarting' 4 ([byte[]](0, 6, 0))
    Add-Pair $retainedTransactions $retainedOffsets `
        'DarkFixedStarting' 5 ([byte[]](1, 2, 0x2C))
    Add-Pair $retainedTransactions $retainedOffsets `
        'DarkAutoStarting' 6 ([byte[]](0, 6, 0))
    Write-Decoded $retainedDecodedPath $retainedTransactions ('C' * 64)

    $freshTransactions = [Collections.Generic.List[object]]::new()
    Add-Transaction $freshTransactions $freshOffsets `
        'FreshLitBaselineConfirmed' 1 0 7 0x0F 0x03 `
        (New-Object byte[] 59)
    Add-Pair $freshTransactions $freshOffsets `
        'FreshLitFixedStarting' 8 ([byte[]](1, 2, 0x2C))
    Add-Pair $freshTransactions $freshOffsets `
        'FreshLitAutoStarting' 9 ([byte[]](0, 6, 0))
    Write-Decoded $freshDecodedPath $freshTransactions ('D' * 64)

    Invoke-Analyzer `
        $retainedDecodedPath `
        $retainedMarkersPath `
        $retainedStatePath `
        $freshDecodedPath `
        $freshMarkersPath `
        $freshStatePath `
        $analysisPath
    $analysisText = Get-Content -LiteralPath $analysisPath -Raw
    $analysis = $analysisText | ConvertFrom-Json
    Assert-True (
        $analysis.conclusions.physicallyDarkWindowHadZeroLightingFrames -eq
            $true) `
        'The split analyzer did not confirm the zero-frame dark window.'
    Assert-True (
        $analysis.conclusions.retainedLitFrameStreamObserved -eq $true -and
        $analysis.conclusions.freshSessionLitFrameStreamObserved -eq $true) `
        'The split analyzer lost a lit positive-control frame stream.'
    Assert-True (
        $analysis.contexts.retainedPhysicallyDark.fixed2200.requestCount -eq 1 -and
        $analysis.contexts.retainedPhysicallyDark.synapseManagedAuto.requestCount -eq 1 -and
        $analysis.contexts.freshSessionLit.fixed2200.acknowledgementCount -eq 1 -and
        $analysis.contexts.freshSessionLit.synapseManagedAuto.acknowledgementCount -eq 1) `
        'The split analyzer did not retain exactly one Fixed and Synapse-managed Auto pair per context.'
    Assert-True (
        $analysis.contexts.retainedLit.fixed2200.otherAcknowledgedVendorCommandPairCount -eq 1) `
        'The analyzer must disclose, but not confuse, acknowledged vendor choreography around Fixed.'
    Assert-True (
        $analysis.conclusions.continuousLightingFramesRequiredForVendorUiTransitions -eq
            $false) `
        'The successful zero-frame context must disprove continuous-frame necessity.'
    Assert-True (
        $analysis.conclusions.priorSynapseProcessSessionRequiredForVendorUiTransitions -eq
            $false) `
        'The successful fresh vendor process session must disprove prior-session necessity.'
    Assert-True (
        $analysis.conclusions.darkContextSameProcessSessionConfirmedAfterTransitions -eq
            $false -and
        $analysis.conclusions.hidHandleRetentionDetermined -eq $false -and
        $null -eq $analysis.conclusions.hidHandleRetentionRequired) `
        'The split artifacts must not overclaim dark-session or HID-handle continuity.'
    Assert-True (
        $analysis.conclusions.synapseManagedAutoFirmwareOwnershipConfirmed -eq
            $false -and
        $analysis.conclusions.activeModeReadbackConfirmed -eq $false -and
        $analysis.conclusions.productionWriteAdmitted -eq $false) `
        'The semantic analyzer widened the vendor UI evidence boundary.'
    Assert-True (
        $analysisText.Contains('synapseManagedAuto') -and
        $analysisText.Contains('Synapse-managed Auto')) `
        'The sanitized output must use Synapse-managed Auto terminology.'
    Assert-True (-not $analysisText.Contains($testRoot) -and
        -not $analysisText.Contains('ProcessAnchorHash') -and
        -not $analysisText.Contains('ProcessSetHash')) `
        'The sanitized output leaked a private path or process hash.'

    $darkFrameDecodedPath = Join-Path $testRoot 'dark-frame-decoded.json'
    $darkFrameOutputPath = Join-Path $testRoot 'dark-frame-analysis.json'
    Add-Transaction $retainedTransactions $retainedOffsets `
        'DarkLightingConfirmed' 1 0 10 0x0F 0x03 `
        (New-Object byte[] 59)
    Write-Decoded $darkFrameDecodedPath $retainedTransactions ('E' * 64)
    $darkFrameRejected = $false
    try {
        Invoke-Analyzer `
            $darkFrameDecodedPath `
            $retainedMarkersPath `
            $retainedStatePath `
            $freshDecodedPath `
            $freshMarkersPath `
            $freshStatePath `
            $darkFrameOutputPath
    }
    catch {
        $darkFrameRejected = $_.Exception.Message -match 'physically dark'
    }
    Assert-True ($darkFrameRejected -and
        -not (Test-Path -LiteralPath $darkFrameOutputPath)) `
        'A 0F/03 frame in the physically dark window must fail closed.'

    $extraMarkerPath = Join-Path $testRoot 'fresh-extra-marker.jsonl'
    [IO.File]::WriteAllText(
        $extraMarkerPath,
        (Get-Content -LiteralPath $freshMarkersPath -Raw) +
            (([ordered]@{
                atUtc = $base.AddSeconds(999).ToString('O')
                name = 'UnexpectedMarker'
                note = ''
            } | ConvertTo-Json -Compress) + "`r`n"),
        [Text.UTF8Encoding]::new($false))
    $extraMarkerOutputPath = Join-Path $testRoot 'extra-marker-analysis.json'
    $extraMarkerRejected = $false
    try {
        Invoke-Analyzer `
            $retainedDecodedPath `
            $retainedMarkersPath `
            $retainedStatePath `
            $freshDecodedPath `
            $extraMarkerPath `
            $freshStatePath `
            $extraMarkerOutputPath
    }
    catch {
        $extraMarkerRejected = $_.Exception.Message -match 'exact completed subset'
    }
    Assert-True ($extraMarkerRejected -and
        -not (Test-Path -LiteralPath $extraMarkerOutputPath)) `
        'The analyzer accepted an artifact outside the exact marker subset.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'Cooling-pad split fan-context analyzer tests passed.'
