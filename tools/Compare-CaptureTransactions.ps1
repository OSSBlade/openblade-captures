[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaselinePath,
    [Parameter(Mandatory)][string]$ActionPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$baseline = Get-Content -LiteralPath $BaselinePath -Raw | ConvertFrom-Json
$action = Get-Content -LiteralPath $ActionPath -Raw | ConvertFrom-Json
if ($baseline.schemaVersion -ne 1 -or $action.schemaVersion -ne 1) {
    throw 'Only decoded transaction schema 1 is supported.'
}

function Convert-HexToByteArray {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Hex)

    if (($Hex.Length % 2) -ne 0 -or $Hex -notmatch '^[0-9A-Fa-f]*$') {
        return $null
    }

    $bytes = [byte[]]::new($Hex.Length / 2)
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        $bytes[$index] = [Convert]::ToByte($Hex.Substring($index * 2, 2), 16)
    }
    return ,$bytes
}

function Convert-BytesToHex {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    return -join ($Bytes | ForEach-Object { $_.ToString('X2') })
}

function Get-RazerEnvelopeSemanticFingerprint {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$PayloadHex)

    $bytes = Convert-HexToByteArray -Hex $PayloadHex
    if ($null -eq $bytes) {
        return $null
    }

    $offset = 0
    $reportId = 'None'
    $envelopeLength = $bytes.Length
    if ($envelopeLength -notin @(90, 374)) {
        if (($bytes.Length - 1) -notin @(90, 374)) {
            return $null
        }

        $offset = 1
        $reportId = $bytes[0].ToString('X2')
        $envelopeLength = $bytes.Length - 1
    }

    $envelope = [byte[]]::new($envelopeLength)
    [Array]::Copy($bytes, $offset, $envelope, 0, $envelopeLength)
    if ($envelope[2] -ne 0 -or $envelope[3] -ne 0 -or
        $envelope[$envelopeLength - 1] -ne 0) {
        return $null
    }

    $checksumOffset = $envelopeLength - 2
    $checksum = [byte]0
    for ($index = 2; $index -lt $checksumOffset; $index++) {
        $checksum = $checksum -bxor $envelope[$index]
    }
    if ($envelope[$checksumOffset] -ne $checksum) {
        return $null
    }

    $payloadLength = ([int]$envelope[4] -shl 8) -bor [int]$envelope[5]
    $maximumPayloadLength = $envelopeLength - 10
    if ($payloadLength -lt 0 -or $payloadLength -gt $maximumPayloadLength) {
        return $null
    }

    $semanticPayload = [byte[]]::new($payloadLength)
    if ($payloadLength -gt 0) {
        [Array]::Copy($envelope, 8, $semanticPayload, 0, $payloadLength)
    }

    return @(
        'RAZER_ENVELOPE_V1',
        "REPORT_ID=$reportId",
        "LENGTH=$envelopeLength",
        "STATUS=$($envelope[0].ToString('X2'))",
        "PAYLOAD_LENGTH=$payloadLength",
        "CLASS=$($envelope[6].ToString('X2'))",
        "COMMAND=$($envelope[7].ToString('X2'))",
        "PAYLOAD=$(Convert-BytesToHex -Bytes $semanticPayload)"
    ) -join ';'
}

function Get-PayloadFingerprint {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$PayloadHex)

    $normalized = Get-RazerEnvelopeSemanticFingerprint -PayloadHex $PayloadHex
    if ($null -ne $normalized) {
        return $normalized
    }

    return "RAW=$($PayloadHex.ToUpperInvariant())"
}

function Get-Fingerprint {
    param([Parameter(Mandatory)][object]$Transaction)
    @(
        $Transaction.transferType,
        $Transaction.direction,
        $Transaction.endpoint,
        $Transaction.setup.requestType,
        $Transaction.setup.request,
        $Transaction.setup.value,
        $Transaction.setup.index,
        (Get-PayloadFingerprint -PayloadHex ([string]$Transaction.payloadHex))
    ) -join '|'
}

function Get-TransactionIndex {
    param([Parameter(Mandatory)][object[]]$Transactions)

    $counts = @{}
    $representatives = @{}
    foreach ($transaction in $Transactions) {
        $fingerprint = Get-Fingerprint -Transaction $transaction
        $counts[$fingerprint] = 1 + [int]$counts[$fingerprint]
        if (-not $representatives.ContainsKey($fingerprint)) {
            $representatives[$fingerprint] = $transaction
        }
    }

    # Keep one representative while counting. Searching the complete capture again
    # for every distinct fingerprint makes noisy lighting captures quadratic.
    [pscustomobject]@{
        Counts = $counts
        Representatives = $representatives
    }
}

$baselineIndex = Get-TransactionIndex -Transactions @($baseline.transactions)
$actionIndex = Get-TransactionIndex -Transactions @($action.transactions)
$baselineCounts = $baselineIndex.Counts
$actionCounts = $actionIndex.Counts
$differences = [Collections.Generic.List[object]]::new()
foreach ($fingerprint in @($baselineCounts.Keys + $actionCounts.Keys | Sort-Object -Unique)) {
    $baselineCount = [int]$baselineCounts[$fingerprint]
    $actionCount = [int]$actionCounts[$fingerprint]
    if ($baselineCount -eq $actionCount) {
        continue
    }
    $representative = $actionIndex.Representatives[$fingerprint]
    if ($null -eq $representative) {
        $representative = $baselineIndex.Representatives[$fingerprint]
    }
    [void]$differences.Add([ordered]@{
        fingerprint = $fingerprint
        baselineCount = $baselineCount
        actionCount = $actionCount
        delta = $actionCount - $baselineCount
        representative = $representative
    })
}

$document = [ordered]@{
    schemaVersion = 1
    comparedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    baselineCaptureSha256 = [string]$baseline.capture.sha256
    actionCaptureSha256 = [string]$action.capture.sha256
    fingerprintNormalization = [ordered]@{
        name = 'RazerEnvelopeSemanticV1'
        supportedEnvelopeLengths = @(90, 374)
        optionalReportIdPrefix = $true
        ignoredFields = @(
            'transactionId',
            'checksum',
            'reservedBytes',
            'unusedPadding'
        )
        preservedFields = @(
            'reportId',
            'envelopeLength',
            'status',
            'payloadLength',
            'commandClass',
            'commandId',
            'semanticPayload'
        )
        fallback = 'FullPayloadHex'
    }
    differenceCount = $differences.Count
    differences = @($differences | Sort-Object -Property @{ Expression = 'delta'; Descending = $true })
}

$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
if ((Test-Path -LiteralPath $resolvedOutput) -and -not $Force) {
    throw "Refusing to overwrite comparison: $resolvedOutput"
}
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($resolvedOutput)) | Out-Null
[IO.File]::WriteAllText(
    $resolvedOutput,
    ($document | ConvertTo-Json -Depth 12),
    [Text.UTF8Encoding]::new($false))
Get-Item -LiteralPath $resolvedOutput
