[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$capturePath = Join-Path $repository `
    'tools\Invoke-CoolingPadFanContextCapture.ps1'
$analyzerPath = Join-Path $repository `
    'tools\Analyze-CoolingPadFanContextCapture.ps1'
$captureSource = Get-Content -LiteralPath $capturePath -Raw
$analyzerSource = Get-Content -LiteralPath $analyzerPath -Raw

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

foreach ($path in @($capturePath, $analyzerPath)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$tokens,
        [ref]$errors)
    Assert-True ($errors.Count -eq 0) `
        "$path did not parse cleanly in Windows PowerShell."
}

Assert-True ($captureSource.Contains("-cne 'Blade 16 - RZ09-0581'")) `
    'The context capture lost its exact model gate.'
Assert-True ($captureSource.Contains("-cne 'RZ09-05819EN4'")) `
    'The context capture lost its exact SKU gate.'
Assert-True ($captureSource.Contains("-cne '4.00'")) `
    'The context capture lost its exact BIOS gate.'
Assert-True ($captureSource.Contains("PID_0F43&REV_0200")) `
    'The context capture lost its exact cooling-pad revision gate.'
Assert-True ($captureSource.Contains('Invoke-InteractiveUsbPcapCapture.ps1')) `
    'The context capture must use the reviewed USBPcap wrapper.'
Assert-True (-not $captureSource.Contains('USBPcapCMD.exe')) `
    'The context capture must not invoke USBPcapCMD directly.'
Assert-True (-not $captureSource.Contains('GenerateConsoleCtrlEvent')) `
    'The context capture must delegate targeted USBPcap shutdown.'
Assert-True (-not $captureSource.Contains('Stop-Process')) `
    'The context capture must not force-stop capture or vendor processes.'
Assert-True ($captureSource.Contains("'/Terminate'")) `
    'The context capture must finalize Procmon normally.'
Assert-True ($captureSource.Contains('-SkipServiceManagement')) `
    'OpenBlade service management must remain disabled for this capture.'
Assert-True ($captureSource.Contains("Get-Service -Name OpenBlade")) `
    'The context capture must require OpenBlade to remain stopped.'
Assert-True ($captureSource.Contains('RetainedLitFixedStarting')) `
    'The retained lit positive-control context is missing.'
Assert-True ($captureSource.Contains('DarkFixedStarting')) `
    'The retained lighting-off context is missing.'
Assert-True ($captureSource.Contains('FreshLitFixedStarting')) `
    'The fresh Synapse process context is missing.'
Assert-True ($captureSource.Contains('ProcessSetHash')) `
    'The private marker log lost process-session continuity evidence.'
Assert-True ($captureSource.Contains('does not have a valid Razer signature')) `
    'The vendor-process signature gate is missing.'
Assert-True ($captureSource.Contains('RESTORED AND CLOSED')) `
    'Final Auto, brightness, and Synapse-exit confirmation is missing.'
Assert-True (-not $captureSource.Contains('OpenBlade.Capture')) `
    'The vendor-owned capture must not invoke an OpenBlade HID command.'

$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    "openblade-cooling-pad-context-$([Guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
try {
    $decodedPath = Join-Path $testRoot 'decoded.json'
    $markersPath = Join-Path $testRoot 'markers.jsonl'
    $statePath = Join-Path $testRoot 'state.json'
    $analysisPath = Join-Path $testRoot 'analysis.json'
    $analysisWithDarkFramePath = Join-Path $testRoot 'analysis-dark-frame.json'
    $base = [DateTimeOffset]::Parse('2026-08-09T20:00:00Z')
    $markerNames = @(
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
    $markerTimes = @{}
    $markerLines = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $markerNames.Count; $index++) {
        $time = $base.AddSeconds($index * 10)
        $markerTimes[$markerNames[$index]] = $time
        [void]$markerLines.Add((([ordered]@{
            atUtc = $time.ToString('O')
            name = $markerNames[$index]
            note = ''
        } | ConvertTo-Json -Compress)))
    }
    [IO.File]::WriteAllLines(
        $markersPath,
        $markerLines,
        [Text.UTF8Encoding]::new($false))

    function New-ReportHex {
        param(
            [byte]$Status,
            [byte]$TransactionId,
            [byte]$Class,
            [byte]$Command,
            [byte[]]$Payload
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

    $transactions = [Collections.Generic.List[object]]::new()
    $nextTransaction = 1
    function Add-Transaction {
        param(
            [string]$AfterMarker,
            [byte]$Status,
            [byte]$Class,
            [byte]$Command,
            [byte[]]$Payload
        )

        $time = $markerTimes[$AfterMarker].AddSeconds(1)
        $epoch = [decimal]($time.UtcTicks - [DateTimeOffset]::UnixEpoch.Ticks) /
            [TimeSpan]::TicksPerSecond
        [void]$transactions.Add([ordered]@{
            absoluteTimeEpoch = $epoch.ToString(
                [Globalization.CultureInfo]::InvariantCulture)
            payloadHex = New-ReportHex `
                -Status $Status `
                -TransactionId ([byte]$script:nextTransaction) `
                -Class $Class `
                -Command $Command `
                -Payload $Payload
        })
        $script:nextTransaction++
    }

    Add-Transaction 'RetainedLitBaselineConfirmed' 0 0x0F 0x03 `
        (New-Object byte[] 59)
    Add-Transaction 'RetainedLitFixedStarting' 0 0x0D 0x10 ([byte[]](1, 2, 0x2C))
    Add-Transaction 'RetainedLitFixedStarting' 2 0x0D 0x10 ([byte[]](1, 2, 0x2C))
    Add-Transaction 'RetainedLitAutoStarting' 0 0x0D 0x10 ([byte[]](0, 6, 0))
    Add-Transaction 'RetainedLitAutoStarting' 2 0x0D 0x10 ([byte[]](0, 6, 0))
    Add-Transaction 'DarkFixedStarting' 0 0x0D 0x10 ([byte[]](1, 2, 0x2C))
    Add-Transaction 'DarkFixedStarting' 2 0x0D 0x10 ([byte[]](1, 2, 0x2C))
    Add-Transaction 'DarkAutoStarting' 0 0x0D 0x10 ([byte[]](0, 6, 0))
    Add-Transaction 'DarkAutoStarting' 2 0x0D 0x10 ([byte[]](0, 6, 0))
    Add-Transaction 'FreshLitBaselineConfirmed' 0 0x0F 0x03 `
        (New-Object byte[] 59)
    Add-Transaction 'FreshLitFixedStarting' 0 0x0D 0x10 ([byte[]](1, 2, 0x2C))
    Add-Transaction 'FreshLitFixedStarting' 2 0x0D 0x10 ([byte[]](1, 2, 0x2C))
    Add-Transaction 'FreshLitAutoStarting' 0 0x0D 0x10 ([byte[]](0, 6, 0))
    Add-Transaction 'FreshLitAutoStarting' 2 0x0D 0x10 ([byte[]](0, 6, 0))

    $decoded = [ordered]@{
        schemaVersion = 1
        capture = [ordered]@{
            sha256 = ('A' * 64)
            byteLength = 1234
        }
        transactionCount = $transactions.Count
        transactions = @($transactions)
    }
    [IO.File]::WriteAllText(
        $decodedPath,
        ($decoded | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        $statePath,
        ([ordered]@{
            status = 'Completed'
            stopMode = 'Graceful'
            service = [ordered]@{
                managementSkipped = $true
                restarted = $false
            }
            errors = @()
        } | ConvertTo-Json -Depth 5),
        [Text.UTF8Encoding]::new($false))

    & $analyzerPath `
        -DecodedTransactionsPath $decodedPath `
        -MarkersPath $markersPath `
        -CaptureStatePath $statePath `
        -OutputPath $analysisPath | Out-Null
    $analysis = Get-Content -LiteralPath $analysisPath -Raw |
        ConvertFrom-Json
    Assert-True ($analysis.conclusions.darkLightingFrameStreamAbsent -eq $true) `
        'The analyzer did not recognize the zero-frame dark context.'
    Assert-True ($analysis.conclusions.retainedLitFrameStreamObserved -eq $true) `
        'The retained lit positive control lost its frame.'
    Assert-True ($analysis.conclusions.freshLitFrameStreamObserved -eq $true) `
        'The fresh lit positive control lost its frame.'
    Assert-True ($analysis.conclusions.darkFanSequenceExactlyObserved -eq $true) `
        'The dark Fixed/Auto sequence was not matched exactly.'
    Assert-True ($analysis.conclusions.noFanCommandsOutsideMarkedActions -eq $true) `
        'The analyzer did not prove all fan commands were marker-bounded.'
    Assert-True ($analysis.conclusions.fanSequenceObservedWithoutLightingFrames -eq $true) `
        'The analyzer did not isolate fan control from lighting frames.'
    Assert-True ($analysis.conclusions.continuousLightingFramesProvenRequired -eq $false) `
        'A zero-frame successful sequence must disprove continuous-frame necessity.'
    Assert-True ($analysis.conclusions.priorSynapseProcessSessionProvenRequired -eq $false) `
        'A fresh-session successful sequence must disprove prior-process necessity.'
    Assert-True ($null -eq $analysis.conclusions.hidHandleRetentionRequired) `
        'USBPcap analysis must not infer literal HID-handle retention.'
    Assert-True ($analysis.conclusions.activeModeReadbackConfirmed -eq $false) `
        'The analyzer must not invent active-mode readback.'
    Assert-True ($analysis.conclusions.productionWriteAdmitted -eq $false) `
        'Vendor context isolation must not admit OpenBlade writes.'

    Add-Transaction 'DarkLightingConfirmed' 0 0x0F 0x03 `
        (New-Object byte[] 59)
    $decoded.transactionCount = $transactions.Count
    $decoded.transactions = @($transactions)
    [IO.File]::WriteAllText(
        $decodedPath,
        ($decoded | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
    & $analyzerPath `
        -DecodedTransactionsPath $decodedPath `
        -MarkersPath $markersPath `
        -CaptureStatePath $statePath `
        -OutputPath $analysisWithDarkFramePath | Out-Null
    $withDarkFrame = Get-Content -LiteralPath $analysisWithDarkFramePath -Raw |
        ConvertFrom-Json
    Assert-True (
        $withDarkFrame.conclusions.darkLightingFrameStreamAbsent -eq $false) `
        'A dark-window frame must invalidate the zero-frame conclusion.'
    Assert-True (
        $withDarkFrame.conclusions.fanSequenceObservedWithoutLightingFrames -eq $false) `
        'A dark-window frame must block the isolation claim.'
    Assert-True (
        $null -eq $withDarkFrame.conclusions.continuousLightingFramesProvenRequired) `
        'A non-isolating run must not claim that lighting frames are required.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'Cooling-pad fan-context capture tests passed.'
