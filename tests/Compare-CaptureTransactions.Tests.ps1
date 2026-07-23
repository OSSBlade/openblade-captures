[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$comparer = Join-Path $repository 'tools\Compare-CaptureTransactions.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('OpenBlade.CaptureComparison.Tests.' + [Guid]::NewGuid().ToString('N'))

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Convert-BytesToHex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return -join ($Bytes | ForEach-Object { $_.ToString('X2') })
}

function New-RazerEnvelope {
    param(
        [Parameter(Mandatory)][ValidateSet(90, 374)][int]$EnvelopeLength,
        [Parameter(Mandatory)][byte]$TransactionId,
        [Parameter(Mandatory)][byte]$CommandClass,
        [Parameter(Mandatory)][byte]$CommandId,
        [Parameter(Mandatory)][byte[]]$Payload,
        [byte]$Status = 0
    )

    if ($Payload.Length -gt ($EnvelopeLength - 10)) {
        throw 'Synthetic payload exceeds the envelope capacity.'
    }

    $envelope = [byte[]]::new($EnvelopeLength)
    $envelope[0] = $Status
    $envelope[1] = $TransactionId
    $envelope[4] = [byte](($Payload.Length -shr 8) -band 0xFF)
    $envelope[5] = [byte]($Payload.Length -band 0xFF)
    $envelope[6] = $CommandClass
    $envelope[7] = $CommandId
    [Array]::Copy($Payload, 0, $envelope, 8, $Payload.Length)
    $checksumOffset = $EnvelopeLength - 2
    $checksum = [byte]0
    for ($index = 2; $index -lt $checksumOffset; $index++) {
        $checksum = $checksum -bxor $envelope[$index]
    }
    $envelope[$checksumOffset] = $checksum
    return ,$envelope
}

function Add-ReportId {
    param(
        [Parameter(Mandatory)][byte]$ReportId,
        [Parameter(Mandatory)][byte[]]$Envelope
    )

    $buffer = [byte[]]::new($Envelope.Length + 1)
    $buffer[0] = $ReportId
    [Array]::Copy($Envelope, 0, $buffer, 1, $Envelope.Length)
    return ,$buffer
}

function New-Transaction {
    param([Parameter(Mandatory)][string]$PayloadHex)

    return [ordered]@{
        frame = 1
        relativeSeconds = 0.1
        transferType = 'URB_CONTROL'
        direction = 'OUT'
        endpoint = '0x00'
        setup = [ordered]@{
            requestType = '0x21'
            request = '0x09'
            value = '0x0300'
            index = '0x0000'
        }
        reportedDataLength = $PayloadHex.Length / 2
        payloadHex = $PayloadHex
        payloadTruncated = $false
    }
}

function Write-DecodedCapture {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CaptureHash,
        [Parameter(Mandatory)][string]$PayloadHex
    )

    $document = [ordered]@{
        schemaVersion = 1
        capture = [ordered]@{
            sha256 = $CaptureHash
            byteLength = 1
        }
        transactionCount = 1
        transactions = @(
            (New-Transaction -PayloadHex $PayloadHex)
        )
    }
    [IO.File]::WriteAllText(
        $Path,
        ($document | ConvertTo-Json -Depth 12),
        [Text.UTF8Encoding]::new($false))
}

function Invoke-Comparison {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$BaselinePayload,
        [Parameter(Mandatory)][string]$ActionPayload
    )

    $baselinePath = Join-Path $testRoot "$Name-baseline.json"
    $actionPath = Join-Path $testRoot "$Name-action.json"
    $outputPath = Join-Path $testRoot "$Name-comparison.json"
    Write-DecodedCapture -Path $baselinePath -CaptureHash ('A' * 64) `
        -PayloadHex $BaselinePayload
    Write-DecodedCapture -Path $actionPath -CaptureHash ('B' * 64) `
        -PayloadHex $ActionPayload
    & $comparer -BaselinePath $baselinePath -ActionPath $actionPath `
        -OutputPath $outputPath | Out-Null
    return Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
}

try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null

    $requestA = New-RazerEnvelope -EnvelopeLength 90 -TransactionId 1 `
        -CommandClass 3 -CommandId 10 -Payload ([byte[]](1, 2, 3))
    $requestB = New-RazerEnvelope -EnvelopeLength 90 -TransactionId 49 `
        -CommandClass 3 -CommandId 10 -Payload ([byte[]](1, 2, 3))
    $sameSemantic = Invoke-Comparison -Name 'same-semantic-90' `
        -BaselinePayload (Convert-BytesToHex $requestA) `
        -ActionPayload (Convert-BytesToHex $requestB)
    Assert-True ($sameSemantic.differenceCount -eq 0) `
        'Transaction and checksum changes were not normalized for 90-byte reports.'
    Assert-True (
        $sameSemantic.fingerprintNormalization.name -ceq 'RazerEnvelopeSemanticV1') `
        'The comparison output did not disclose its normalization policy.'

    $prefixedA = Add-ReportId -ReportId 0 -Envelope $requestA
    $prefixedB = Add-ReportId -ReportId 0 -Envelope $requestB
    $samePrefixed = Invoke-Comparison -Name 'same-prefixed-90' `
        -BaselinePayload (Convert-BytesToHex $prefixedA) `
        -ActionPayload (Convert-BytesToHex $prefixedB)
    Assert-True ($samePrefixed.differenceCount -eq 0) `
        'Transaction changes were not normalized behind a report-ID prefix.'

    $matrixA = New-RazerEnvelope -EnvelopeLength 374 -TransactionId 2 `
        -CommandClass 3 -CommandId 11 -Payload ([byte[]](0, 0, 0, 101))
    $matrixB = New-RazerEnvelope -EnvelopeLength 374 -TransactionId 63 `
        -CommandClass 3 -CommandId 11 -Payload ([byte[]](0, 0, 0, 101))
    $sameMatrix = Invoke-Comparison -Name 'same-semantic-374' `
        -BaselinePayload (Convert-BytesToHex $matrixA) `
        -ActionPayload (Convert-BytesToHex $matrixB)
    Assert-True ($sameMatrix.differenceCount -eq 0) `
        'Transaction and checksum changes were not normalized for 374-byte reports.'

    $changedPayload = New-RazerEnvelope -EnvelopeLength 90 -TransactionId 49 `
        -CommandClass 3 -CommandId 10 -Payload ([byte[]](1, 2, 4))
    $semanticPayloadDifference = Invoke-Comparison -Name 'changed-payload' `
        -BaselinePayload (Convert-BytesToHex $requestA) `
        -ActionPayload (Convert-BytesToHex $changedPayload)
    Assert-True ($semanticPayloadDifference.differenceCount -eq 2) `
        'A semantic command-payload change was incorrectly normalized away.'

    $changedCommand = New-RazerEnvelope -EnvelopeLength 90 -TransactionId 49 `
        -CommandClass 3 -CommandId 12 -Payload ([byte[]](1, 2, 3))
    $semanticCommandDifference = Invoke-Comparison -Name 'changed-command' `
        -BaselinePayload (Convert-BytesToHex $requestA) `
        -ActionPayload (Convert-BytesToHex $changedCommand)
    Assert-True ($semanticCommandDifference.differenceCount -eq 2) `
        'A command-ID change was incorrectly normalized away.'

    $rawDifference = Invoke-Comparison -Name 'raw-fallback' `
        -BaselinePayload '01020304' -ActionPayload '01020305'
    Assert-True ($rawDifference.differenceCount -eq 2) `
        'Non-envelope payloads did not retain exact full-payload comparison.'

    Write-Host 'Capture-transaction comparison regression tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
        $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolvedTestRoot.StartsWith(
            $resolvedTempRoot,
            [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean unexpected test path $resolvedTestRoot."
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
