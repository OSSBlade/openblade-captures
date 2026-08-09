[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$decoder = Join-Path $repository 'tools\Convert-UsbPcapToTransactions.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('OpenBlade.UsbPcapDecoder.Tests.' + [Guid]::NewGuid().ToString('N'))

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function New-RazerResponse {
    $response = [byte[]]::new(90)
    $response[0] = 0x02
    $response[1] = 0x07
    $response[5] = 0x03
    $response[6] = 0x0F
    $response[7] = 0x84
    $response[8] = 0x01
    $response[9] = 0x05
    $response[10] = 0x7F
    $checksum = [byte]0
    for ($index = 2; $index -lt 88; $index++) {
        $checksum = $checksum -bxor $response[$index]
    }
    $response[88] = $checksum
    return ,$response
}

function Write-SyntheticUsbPcap {
    param([Parameter(Mandatory)][string]$Path)

    $response = New-RazerResponse
    $frame = [byte[]]::new(28 + $response.Length)
    $frame[0] = 0x1C
    $frame[2] = 0x11
    $frame[3] = 0x22
    $frame[4] = 0x33
    $frame[5] = 0x44
    $frame[14] = 0x08
    $frame[16] = 0x01
    $frame[17] = 0x03
    $frame[19] = 0x04
    $frame[21] = 0x80
    $frame[22] = 0x02
    $frame[23] = [byte]$response.Length
    $frame[27] = 0x03
    [Array]::Copy($response, 0, $frame, 28, $response.Length)

    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    try {
        $writer = [IO.BinaryWriter]::new($stream)
        try {
            $writer.Write([uint32]::Parse(
                'A1B2C3D4',
                [Globalization.NumberStyles]::HexNumber))
            $writer.Write([uint16]2)
            $writer.Write([uint16]4)
            $writer.Write([int32]0)
            $writer.Write([uint32]0)
            $writer.Write([uint32]65535)
            $writer.Write([uint32]249)
            $writer.Write([uint32]1)
            $writer.Write([uint32]0)
            $writer.Write([uint32]$frame.Length)
            $writer.Write([uint32]$frame.Length)
            $writer.Write($frame)
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

$decoderSource = Get-Content -LiteralPath $decoder -Raw
Assert-True ($decoderSource.Contains("payloadSource = 'UsbPcapFrameData'")) `
    'The decoder lost its undisected USBPcap response source marker.'
Assert-True ($decoderSource.Contains('usb.usbpcap_header_len')) `
    'The decoder no longer bounds raw response extraction by the USBPcap header.'
Assert-True (-not $decoderSource.Contains('frameRaw =')) `
    'The decoder must not serialize complete raw USBPcap frames.'

try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $pcapPath = Join-Path $testRoot 'response.pcap'
    $outputPath = Join-Path $testRoot 'transactions.json'
    Write-SyntheticUsbPcap -Path $pcapPath

    $tshark = Get-Command tshark.exe -ErrorAction SilentlyContinue
    if ($null -eq $tshark) {
        $defaultTshark = 'C:\Program Files\Wireshark\tshark.exe'
        if (Test-Path -LiteralPath $defaultTshark -PathType Leaf) {
            $tshark = Get-Item -LiteralPath $defaultTshark
        }
    }

    if ($null -ne $tshark) {
        & $decoder -PcapPath $pcapPath -OutputPath $outputPath `
            -TsharkPath $tshark.FullName | Out-Null
        $decoded = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
        Assert-True ($decoded.transactionCount -eq 1) `
            'The decoder did not retain the synthetic control-completion response.'
        $transaction = $decoded.transactions[0]
        Assert-True (-not [string]::IsNullOrWhiteSpace(
            [string]$transaction.payloadSource)) `
            'The synthetic response did not use a bounded USBPcap payload source.'
        Assert-True ($transaction.payloadHex.Length -eq 180) `
            'The synthetic response did not preserve its exact 90-byte envelope.'
        Assert-True ($transaction.payloadHex.StartsWith('0207000000030F8401057F')) `
            'The synthetic response payload was not extracted after the USBPcap header.'
    }
    else {
        Write-Host 'tshark is unavailable; decoder integration fixture skipped.'
    }

    Write-Host 'USBPcap transaction-decoder regression tests passed.'
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
