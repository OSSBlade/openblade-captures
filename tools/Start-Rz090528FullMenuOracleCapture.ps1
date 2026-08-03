[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $OutputDirectory,

    [switch] $ElevatedChild
)

$ErrorActionPreference = 'Stop'
$usbPcapDevice = '\\.\USBPcap2'
$expectedAddress = 3
$usbPcap = 'C:\Program Files\USBPcap\USBPcapCMD.exe'
$tshark = 'C:\Program Files\Wireshark\tshark.exe'
$startCapture = Join-Path $PSScriptRoot 'Start-UsbPcapCapture.ps1'
$stopCapture = Join-Path $PSScriptRoot 'Stop-UsbPcapCapture.ps1'
$interactive = Join-Path $PSScriptRoot 'Invoke-InteractiveUsbPcapCapture.ps1'
$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string] $LiteralPath,
        [Parameter(Mandatory)][object] $Value
    )
    [IO.File]::WriteAllText(
        $LiteralPath,
        ($Value | ConvertTo-Json -Depth 8),
        (New-Object Text.UTF8Encoding($false)))
}

if ($ElevatedChild) {
    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'The full-menu oracle child is not elevated.'
    }
    if ((Get-Service -Name OpenBlade).Status -ne 'Stopped') {
        throw 'OpenBlade must remain stopped throughout the Synapse oracle capture.'
    }
    if (@(Get-Process -Name RazerAppEngine -ErrorAction SilentlyContinue).Count -eq 0) {
        throw 'Synapse must be running before the full-menu oracle capture.'
    }
    if (Test-Path -LiteralPath $resolvedOutput) {
        throw "Refusing to overwrite an existing capture directory: $resolvedOutput"
    }

    [IO.Directory]::CreateDirectory($resolvedOutput) | Out-Null
    $verificationPcap = Join-Path $resolvedOutput 'address-verification.pcap'
    $verificationSession = Join-Path $resolvedOutput 'address-verification.session.json'
    & $startCapture `
        -ExecutablePath $usbPcap `
        -ArgumentList @(
            '-d', $usbPcapDevice,
            '-A',
            '--inject-descriptors',
            '-s', '65535',
            '-o', $verificationPcap) `
        -OutputPath $verificationPcap `
        -SessionPath $verificationSession
    Start-Sleep -Seconds 2
    & $stopCapture -SessionPath $verificationSession

    $addresses = @(
        & $tshark `
            -r $verificationPcap `
            -Y 'usb.idVendor == 0x1532 && usb.idProduct == 0x02c6' `
            -T fields `
            -e usb.device_address |
            Where-Object { $_ -match '^\d+$' } |
            Sort-Object -Unique
    )
    if ($LASTEXITCODE -ne 0 -or
        $addresses.Count -ne 1 -or
        [int]$addresses[0] -ne $expectedAddress) {
        throw "Descriptor verification did not resolve exact address $expectedAddress."
    }
    $verifiedAt = [DateTimeOffset]::UtcNow
    Write-Utf8NoBom `
        -LiteralPath (Join-Path $resolvedOutput 'address-verification.json') `
        -Value ([ordered]@{
            schemaVersion = 1
            targetModel = 'RZ09-0528'
            vendorIdHex = '1532'
            productIdHex = '02C6'
            usbPcapDevice = $usbPcapDevice
            capturePlaneDeviceAddress = $expectedAddress
            verifiedAtUtc = $verifiedAt.ToString('O')
            verificationPcapCommitted = $false
        })
    Write-Utf8NoBom `
        -LiteralPath (Join-Path $resolvedOutput 'elevated-launch.json') `
        -Value ([ordered]@{
            schemaVersion = 1
            targetModel = 'RZ09-0528'
            vendorIdHex = '1532'
            productIdHex = '02C6'
            usbPcapDevice = $usbPcapDevice
            verifiedCapturePlaneDeviceAddress = $expectedAddress
            capturePlaneAddressVerifiedAtUtc = $verifiedAt.ToString('O')
            serviceStatus = (Get-Service -Name OpenBlade).Status.ToString()
            elevatedChildLaunchedUserProcesses = $false
        })

    & $interactive `
        -UsbPcapDevice $usbPcapDevice `
        -DeviceAddress $expectedAddress `
        -OutputDirectory $resolvedOutput `
        -TimeoutSeconds 900 `
        -SkipServiceManagement `
        -SkipAdministratorCheck
    exit $LASTEXITCODE
}

if (Test-Path -LiteralPath $resolvedOutput) {
    throw "Refusing to overwrite an existing capture directory: $resolvedOutput"
}

$child = Start-Process `
    -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
    -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $PSCommandPath,
        '-OutputDirectory',
        $resolvedOutput,
        '-ElevatedChild') `
    -Verb RunAs `
    -PassThru

Write-Output "ElevatedCaptureProcessId=$($child.Id)"
Write-Output "OutputDirectory=$resolvedOutput"
Write-Output "AddressVerificationPath=$(Join-Path $resolvedOutput 'address-verification.json')"
Write-Output "ReadyPath=$(Join-Path $resolvedOutput 'capture.ready.json')"
Write-Output "StopPath=$(Join-Path $resolvedOutput 'capture.stop')"
