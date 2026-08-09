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

# ProcessStartInfo.ArgumentList is unavailable in Windows PowerShell 5.1's .NET Framework.
# Build Arguments explicitly using the backslash and quote escaping consumed by CommandLineToArgvW.
function ConvertTo-NativeProcessArgument {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    $charactersRequiringQuotes = [char[]]@(' ', "`t", "`n", [char]11, '"')
    if ($Value.Length -gt 0 -and
        $Value.IndexOfAny($charactersRequiringQuotes) -lt 0) {
        return $Value
    }

    $quoted = [Text.StringBuilder]::new()
    [void]$quoted.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]'\') {
            $backslashes++
            continue
        }

        if ($character -eq [char]'"') {
            [void]$quoted.Append([char]'\', (($backslashes * 2) + 1))
            [void]$quoted.Append('"')
            $backslashes = 0
            continue
        }

        [void]$quoted.Append([char]'\', $backslashes)
        $backslashes = 0
        [void]$quoted.Append($character)
    }

    [void]$quoted.Append([char]'\', ($backslashes * 2))
    [void]$quoted.Append('"')
    return $quoted.ToString()
}
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

# Wireshark 4.6 dissects USBPcap control-transfer bodies as usb.data_fragment and
# HID interrupt reports as usbhid.data. Prefer those semantic fields over usb.capdata,
# which is only leftover capture padding in current Wireshark builds.
$payloadFields = [ordered]@{
    UsbDataFragment = 'usb.data_fragment'
    UsbHidData = 'usbhid.data'
    UsbControlResponse = 'usb.control.Response'
    UsbCaptureData = 'usb.capdata'
}

# bmRequestType is exposed directly under usb; the other setup fields remain under usb.setup.
$fields = @(
    'frame.number',
    'frame.time_epoch',
    'frame.time_relative',
    'usb.bus_id',
    'usb.device_address',
    'usb.bInterfaceNumber',
    'usb.idVendor',
    'usb.idProduct',
    'usb.transfer_type',
    'usb.endpoint_address.direction',
    'usb.endpoint_address',
    'usb.bmRequestType',
    'usb.setup.bRequest',
    'usb.setup.wValue',
    'usb.setup.wIndex',
    'usb.data_len'
) + @($payloadFields.Values)
$fieldIndex = @{}
for ($index = 0; $index -lt $fields.Count; $index++) {
    $fieldIndex[$fields[$index]] = $index
}
$tsharkArguments = @(
    '-r',
    $resolvedPcap,
    '-Y',
    (($payloadFields.Values -join ' || ') + ' || usb.setup.bRequest'),
    '-T',
    'fields',
    '-E',
    'separator=/t',
    '-E',
    'occurrence=f'
)
foreach ($field in $fields) {
    $tsharkArguments += @('-e', $field)
}

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $resolvedTshark
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.Arguments = (($tsharkArguments | ForEach-Object {
    ConvertTo-NativeProcessArgument -Value $_
}) -join ' ')
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

    # String.Split preserves trailing empty tshark columns in both Windows PowerShell 5.1
    # and PowerShell 7; the negative -split limit has different semantics between hosts.
    $columns = ([string]$line).Split([char]"`t")
    if ($columns.Count -lt $fields.Count) {
        continue
    }

    $payload = ''
    $payloadSource = $null
    foreach ($sourceName in $payloadFields.Keys) {
        $fieldName = $payloadFields[$sourceName]
        $candidate = [Text.RegularExpressions.Regex]::Replace(
            [string]$columns[$fieldIndex[$fieldName]],
            '[^0-9A-Fa-f]',
            '').ToUpperInvariant()
        if ($candidate.Length -gt 0) {
            $payload = $candidate
            $payloadSource = $sourceName
            break
        }
    }

    $maximumHexLength = $MaximumPayloadBytes * 2
    $truncated = $payload.Length -gt $maximumHexLength
    if ($truncated) {
        $payload = $payload.Substring(0, $maximumHexLength)
    }

    [void]$transactions.Add([ordered]@{
        frame = [int]$columns[$fieldIndex['frame.number']]
        absoluteTimeEpoch = [string]$columns[$fieldIndex['frame.time_epoch']]
        relativeSeconds = [double]::Parse(
            $columns[$fieldIndex['frame.time_relative']],
            [Globalization.CultureInfo]::InvariantCulture)
        busId = [string]$columns[$fieldIndex['usb.bus_id']]
        deviceAddress = [string]$columns[$fieldIndex['usb.device_address']]
        descriptorInterfaceNumber = [string]$columns[$fieldIndex['usb.bInterfaceNumber']]
        vendorId = [string]$columns[$fieldIndex['usb.idVendor']]
        productId = [string]$columns[$fieldIndex['usb.idProduct']]
        transferType = [string]$columns[$fieldIndex['usb.transfer_type']]
        direction = [string]$columns[$fieldIndex['usb.endpoint_address.direction']]
        endpoint = [string]$columns[$fieldIndex['usb.endpoint_address']]
        setup = [ordered]@{
            requestType = [string]$columns[$fieldIndex['usb.bmRequestType']]
            request = [string]$columns[$fieldIndex['usb.setup.bRequest']]
            value = [string]$columns[$fieldIndex['usb.setup.wValue']]
            index = [string]$columns[$fieldIndex['usb.setup.wIndex']]
        }
        reportedDataLength = if ([string]::IsNullOrWhiteSpace(
            $columns[$fieldIndex['usb.data_len']])) {
            $null
        } else {
            [int]$columns[$fieldIndex['usb.data_len']]
        }
        payloadSource = $payloadSource
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
