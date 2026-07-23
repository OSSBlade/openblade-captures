[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RootDirectory,

    [Parameter(Mandatory)]
    [ValidatePattern('^RZ09-[0-9]{4}$')]
    [string]$ModelNumber,

    [ValidatePattern('^[0-9A-Fa-f]{4}$')]
    [string]$VendorId = '1532',

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9A-Fa-f]{4}$')]
    [string]$ProductId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$BiosVersion,

    [string]$EcVersion,

    [string]$McuVersion,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Purpose
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($RootDirectory)
[IO.Directory]::CreateDirectory($root) | Out-Null
$slug = ([Text.RegularExpressions.Regex]::Replace(
    $Purpose.ToLowerInvariant(),
    '[^a-z0-9]+',
    '-')).Trim('-')
if ([string]::IsNullOrWhiteSpace($slug)) {
    $slug = 'capture'
}
if ($slug.Length -gt 48) {
    $slug = $slug.Substring(0, 48).TrimEnd('-')
}

$sessionName = '{0}-{1}' -f ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss')), $slug
$sessionRoot = Join-Path $root $sessionName
if (Test-Path -LiteralPath $sessionRoot) {
    throw "Capture workspace already exists: $sessionRoot"
}

$baselineDirectory = Join-Path $sessionRoot 'baseline'
$actionDirectory = Join-Path $sessionRoot 'action'
[IO.Directory]::CreateDirectory($baselineDirectory) | Out-Null
[IO.Directory]::CreateDirectory($actionDirectory) | Out-Null

$plan = [ordered]@{
    schemaVersion = 1
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    purpose = $Purpose
    device = [ordered]@{
        modelNumber = $ModelNumber.ToUpperInvariant()
        vendorIdHex = $VendorId.ToUpperInvariant()
        productIdHex = $ProductId.ToUpperInvariant()
        bios = $BiosVersion
        ec = if ([string]::IsNullOrWhiteSpace($EcVersion)) { $null } else { $EcVersion }
        mcu = if ([string]::IsNullOrWhiteSpace($McuVersion)) { $null } else { $McuVersion }
    }
    scope = [ordered]@{
        subsystem = 'TODO'
        action = 'TODO: exactly one operator action'
        value = 'TODO'
        queryOnly = $true
    }
    preconditions = @(
        'TODO: power source',
        'TODO: vendor application version and page',
        'OpenBlade service state will be managed by the capture runner'
    )
    expectedObservation = 'TODO'
    priorState = [ordered]@{
        query = 'TODO'
        confirmedValue = 'TODO'
    }
    validation = [ordered]@{
        operatorConfirmationRequired = $true
        apply = 'Not started'
        readback = 'Not started'
        restoration = 'Not started'
        restorationReadback = 'Not started'
    }
    privacy = [ordered]@{
        rawCaptureCommitted = $false
        serialNumbersAllowed = $false
        fullLocalPathsAllowed = $false
    }
}

$planPath = Join-Path $sessionRoot 'capture-plan.json'
[IO.File]::WriteAllText(
    $planPath,
    ($plan | ConvertTo-Json -Depth 10),
    [Text.UTF8Encoding]::new($false))
$logPath = Join-Path $sessionRoot 'operator-log.md'
[IO.File]::WriteAllText(
    $logPath,
    "# Operator log`r`n`r`n- $([DateTimeOffset]::UtcNow.ToString('O')) Workspace created.`r`n",
    [Text.UTF8Encoding]::new($false))

[pscustomobject]@{
    Root = $sessionRoot
    PlanPath = $planPath
    OperatorLogPath = $logPath
    BaselineDirectory = $baselineDirectory
    BaselinePcap = Join-Path $baselineDirectory 'capture.pcap'
    ActionDirectory = $actionDirectory
    ActionPcap = Join-Path $actionDirectory 'capture.pcap'
}
