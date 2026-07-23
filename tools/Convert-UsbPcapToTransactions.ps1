[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PcapPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [string]$TsharkPath,

    [ValidateRange(16, 4096)]
    [int]$MaximumPayloadBytes = 256,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$resolvedPcap = (Resolve-Path -LiteralPath $PcapPath -ErrorAction Stop).Path
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
if ((Test-Path -LiteralPath $resolvedOutput) -and -not $Force) {
    throw "Refusing to overwrite decoded transactions: $resolvedOutput"
}

if ([string]::IsNullOrWhiteSpace($TsharkPath)) {
    $command = Get-Command tshark.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        $TsharkPath = $command.Source
    }
    else {
        $TsharkPath = 'C:\Program Files\Wireshark\tshark.exe'
    }
}
$resolvedTshark = (Resolve-Path -LiteralPath $TsharkPath -ErrorAction Stop).Path
if ([IO.Path]::GetFileName($resolvedTshark) -ine 'tshark.exe') {
    throw "Refusing to run an unexpected decoder: $resolvedTshark"
}

$fields = @(
    'frame.number',
    'frame.time_relative',
    'usb.transfer_type',
    'usb.endpoint_address.direction',
    'usb.endpoint_address',
    'usb.setup.bmRequestType',
    'usb.setup.bRequest',
    'usb.setup.wValue',
    'usb.setup.wIndex',
    'usb.data_len',
    'usb.capdata'
)
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $resolvedTshark
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.ArgumentList.Add('-r')
$startInfo.ArgumentList.Add($resolvedPcap)
$startInfo.ArgumentList.Add('-Y')
$startInfo.ArgumentList.Add('usb.capdata || usb.setup.bRequest')
$startInfo.ArgumentList.Add('-T')
$startInfo.ArgumentList.Add('fields')
$startInfo.ArgumentList.Add('-E')
$startInfo.ArgumentList.Add('separator=/t')
$startInfo.ArgumentList.Add('-E')
$startInfo.ArgumentList.Add('occurrence=f')
foreach ($field in $fields) {
    $startInfo.ArgumentList.Add('-e')
    $startInfo.ArgumentList.Add($field)
}

$process = [Diagnostics.Process]::Start($startInfo)
if ($null -eq $process) {
    throw 'Could not start tshark.'
}
try {
    $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
    $standardErrorTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $standardOutput = $standardOutputTask.GetAwaiter().GetResult()
    $standardError = $standardErrorTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
        throw "tshark failed with exit code $($process.ExitCode): $standardError"
    }
}
finally {
    $process.Dispose()
}

$transactions = [Collections.Generic.List[object]]::new()
foreach ($line in $standardOutput -split "`r?`n") {
    if ([string]::IsNullOrWhiteSpace($line)) {
        continue
    }
    $columns = $line -split "`t", -1
    if ($columns.Count -lt $fields.Count) {
        continue
    }

    $payload = [Text.RegularExpressions.Regex]::Replace(
        [string]$columns[10],
        '[^0-9A-Fa-f]',
        '').ToUpperInvariant()
    $maximumHexLength = $MaximumPayloadBytes * 2
    $truncated = $payload.Length -gt $maximumHexLength
    if ($truncated) {
        $payload = $payload.Substring(0, $maximumHexLength)
    }

    [void]$transactions.Add([ordered]@{
        frame = [int]$columns[0]
        relativeSeconds = [double]::Parse(
            $columns[1],
            [Globalization.CultureInfo]::InvariantCulture)
        transferType = [string]$columns[2]
        direction = [string]$columns[3]
        endpoint = [string]$columns[4]
        setup = [ordered]@{
            requestType = [string]$columns[5]
            request = [string]$columns[6]
            value = [string]$columns[7]
            index = [string]$columns[8]
        }
        reportedDataLength = if ([string]::IsNullOrWhiteSpace($columns[9])) {
            $null
        } else {
            [int]$columns[9]
        }
        payloadHex = $payload
        payloadTruncated = $truncated
    })
}

$document = [ordered]@{
    schemaVersion = 1
    decodedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    decoder = [ordered]@{
        name = 'tshark'
        pathIncluded = $false
        maximumPayloadBytes = $MaximumPayloadBytes
    }
    capture = [ordered]@{
        sha256 = (Get-FileHash -LiteralPath $resolvedPcap -Algorithm SHA256).Hash
        byteLength = (Get-Item -LiteralPath $resolvedPcap).Length
    }
    transactionCount = $transactions.Count
    transactions = @($transactions)
}

[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($resolvedOutput)) | Out-Null
$temporary = "$resolvedOutput.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
$backup = "$resolvedOutput.$PID.$([Guid]::NewGuid().ToString('N')).bak"
try {
    [IO.File]::WriteAllText(
        $temporary,
        ($document | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $resolvedOutput) {
        [IO.File]::Replace($temporary, $resolvedOutput, $backup, $true)
        Remove-Item -LiteralPath $backup -Force
    }
    else {
        [IO.File]::Move($temporary, $resolvedOutput)
    }
}
finally {
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Force
    }
    if (Test-Path -LiteralPath $backup) {
        Remove-Item -LiteralPath $backup -Force
    }
}

[pscustomobject]@{
    OutputPath = $resolvedOutput
    TransactionCount = $transactions.Count
    CaptureSha256 = $document.capture.sha256
}
