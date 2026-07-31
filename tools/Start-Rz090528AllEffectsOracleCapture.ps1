[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $OutputDirectory,

    [ValidateRange(1, 127)]
    [int] $DeviceAddress = 3,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $CapturePlaneAddressVerifiedAtUtc,

    [switch] $ElevatedChild
)

$ErrorActionPreference = 'Stop'
$expectedModel = 'RZ09-0528'
$expectedVendorId = '1532'
$expectedProductId = '02C6'
$usbPcapDevice = '\\.\USBPcap2'
$runnerPath = Join-Path $PSScriptRoot 'Invoke-InteractiveUsbPcapCapture.ps1'
$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
$launchReport = Join-Path $resolvedOutput 'elevated-launch.json'
$addressVerificationTime = [DateTimeOffset]::MinValue
if (-not [DateTimeOffset]::TryParse(
        $CapturePlaneAddressVerifiedAtUtc,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$addressVerificationTime)) {
    throw 'CapturePlaneAddressVerifiedAtUtc must be an ISO-8601 timestamp.'
}
$addressVerificationAge = [DateTimeOffset]::UtcNow - $addressVerificationTime.ToUniversalTime()
if ($addressVerificationAge.TotalSeconds -lt -5 -or
    $addressVerificationAge.TotalMinutes -gt 15) {
    throw 'The USBPcap capture-plane address verification must be no more than 15 minutes old.'
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string] $LiteralPath,
        [Parameter(Mandatory)][string] $Content
    )

    [IO.File]::WriteAllText(
        $LiteralPath,
        $Content,
        (New-Object Text.UTF8Encoding($false)))
}

if ($ElevatedChild) {
    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'The USBPcap capture child is not elevated.'
    }

    if ((Get-Service -Name OpenBlade).Status -ne 'Stopped') {
        throw 'OpenBlade must remain stopped throughout the Synapse oracle capture.'
    }
    $synapse = @(Get-Process -Name RazerAppEngine -ErrorAction SilentlyContinue)
    if ($synapse.Count -eq 0) {
        throw 'Synapse must be running before the oracle capture starts.'
    }

    $composite = @(
        Get-PnpDevice -PresentOnly |
            Where-Object {
                $_.Class -eq 'USB' -and
                $_.InstanceId -like "USB\VID_$expectedVendorId&PID_$expectedProductId\*"
            }
    )
    if ($composite.Count -ne 1) {
        throw "Expected one present $expectedModel USB composite device."
    }
    $pnpPortAddress = (
        Get-PnpDeviceProperty `
            -InstanceId $composite[0].InstanceId `
            -KeyName 'DEVPKEY_Device_Address' `
            -ErrorAction Stop
    ).Data

    [IO.Directory]::CreateDirectory($resolvedOutput) | Out-Null
    Write-Utf8NoBom -LiteralPath $launchReport -Content (
        [pscustomobject]@{
            schemaVersion = 1
            targetModel = $expectedModel
            vendorIdHex = $expectedVendorId
            productIdHex = $expectedProductId
            usbPcapDevice = $usbPcapDevice
            verifiedCapturePlaneDeviceAddress = $DeviceAddress
            capturePlaneAddressVerificationMethod = 'USBPcap descriptor discovery'
            capturePlaneAddressVerifiedAtUtc = $addressVerificationTime.ToUniversalTime().ToString('O')
            pnpPortAddress = $pnpPortAddress
            verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
            serviceStatus = (Get-Service -Name OpenBlade).Status.ToString()
            elevatedChildLaunchedUserProcesses = $false
        } | ConvertTo-Json -Depth 5)

    & $runnerPath `
        -UsbPcapDevice $usbPcapDevice `
        -DeviceAddress $DeviceAddress `
        -OutputDirectory $resolvedOutput `
        -TimeoutSeconds 900 `
        -SkipServiceManagement `
        -SkipAdministratorCheck
    exit $LASTEXITCODE
}

if (Test-Path -LiteralPath $resolvedOutput) {
    throw "Refusing to overwrite an existing capture directory: $resolvedOutput"
}
[IO.Directory]::CreateDirectory($resolvedOutput) | Out-Null

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
        '-DeviceAddress',
        $DeviceAddress,
        '-CapturePlaneAddressVerifiedAtUtc',
        $addressVerificationTime.ToUniversalTime().ToString('O'),
        '-ElevatedChild') `
    -Verb RunAs `
    -PassThru

Write-Output "ElevatedCaptureProcessId=$($child.Id)"
Write-Output "OutputDirectory=$resolvedOutput"
Write-Output "ReadyPath=$(Join-Path $resolvedOutput 'capture.ready.json')"
Write-Output "StopPath=$(Join-Path $resolvedOutput 'capture.stop')"
