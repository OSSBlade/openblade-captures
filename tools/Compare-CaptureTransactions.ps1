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
        $Transaction.payloadHex
    ) -join '|'
}

function Get-Counts {
    param([Parameter(Mandatory)][object[]]$Transactions)
    $counts = @{}
    foreach ($transaction in $Transactions) {
        $fingerprint = Get-Fingerprint -Transaction $transaction
        $counts[$fingerprint] = 1 + [int]$counts[$fingerprint]
    }
    $counts
}

$baselineCounts = Get-Counts -Transactions @($baseline.transactions)
$actionCounts = Get-Counts -Transactions @($action.transactions)
$differences = [Collections.Generic.List[object]]::new()
foreach ($fingerprint in @($baselineCounts.Keys + $actionCounts.Keys | Sort-Object -Unique)) {
    $baselineCount = [int]$baselineCounts[$fingerprint]
    $actionCount = [int]$actionCounts[$fingerprint]
    if ($baselineCount -eq $actionCount) {
        continue
    }
    $representative = @($action.transactions | Where-Object {
        (Get-Fingerprint -Transaction $_) -eq $fingerprint
    } | Select-Object -First 1)
    if ($representative.Count -eq 0) {
        $representative = @($baseline.transactions | Where-Object {
            (Get-Fingerprint -Transaction $_) -eq $fingerprint
        } | Select-Object -First 1)
    }
    [void]$differences.Add([ordered]@{
        fingerprint = $fingerprint
        baselineCount = $baselineCount
        actionCount = $actionCount
        delta = $actionCount - $baselineCount
        representative = $representative[0]
    })
}

$document = [ordered]@{
    schemaVersion = 1
    comparedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    baselineCaptureSha256 = [string]$baseline.capture.sha256
    actionCaptureSha256 = [string]$action.capture.sha256
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
