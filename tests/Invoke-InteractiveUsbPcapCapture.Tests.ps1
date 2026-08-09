[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $repository 'tools\Invoke-InteractiveUsbPcapCapture.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('OpenBlade.InteractiveUsbPcap.Tests.' + [Guid]::NewGuid().ToString('N'))

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $fakeExecutable = Join-Path $testRoot 'USBPcapCMD.exe'
    [IO.File]::WriteAllBytes($fakeExecutable, [byte[]](1))

    $startHelper = Join-Path $testRoot 'Start-FakeUsbPcapCapture.ps1'
    [IO.File]::WriteAllText($startHelper, @'
param(
    [string]$ExecutablePath,
    [string[]]$ArgumentList,
    [string]$OutputPath,
    [string]$SessionPath
)
[IO.File]::WriteAllBytes($OutputPath, [byte[]](1, 2, 3))
[IO.File]::WriteAllText(
    (Join-Path (Split-Path -Parent $SessionPath) 'arguments.txt'),
    ($ArgumentList -join "`r`n"),
    [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($SessionPath, '{}', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText(
    (Join-Path (Split-Path -Parent $SessionPath) 'capture.stop'),
    '',
    [Text.UTF8Encoding]::new($false))
[pscustomobject]@{
    ProcessId = [uint32]$PID
    ProcessGroupId = [uint32]$PID
    OutputPath = $OutputPath
    SessionPath = $SessionPath
}
'@, [Text.UTF8Encoding]::new($false))

    $stopHelper = Join-Path $testRoot 'Stop-FakeUsbPcapCapture.ps1'
    [IO.File]::WriteAllText($stopHelper, @'
param([string]$SessionPath)
Remove-Item -LiteralPath $SessionPath -Force
[pscustomobject]@{ StopMode = 'Graceful' }
'@, [Text.UTF8Encoding]::new($false))

    $outputDirectory = Join-Path $testRoot 'paired'
    $result = & $runner -UsbPcapDevice '\\.\USBPcap1' `
        -DeviceAddresses 2,5 -OutputDirectory $outputDirectory `
        -StartHelperPath $startHelper -StopHelperPath $stopHelper `
        -UsbPcapExecutablePath $fakeExecutable -SkipAdministratorCheck `
        -SkipServiceManagement

    Assert-True ($result.Status -ceq 'Completed') `
        'The paired-device capture runner did not complete.'
    $arguments = @(Get-Content (Join-Path $outputDirectory 'arguments.txt'))
    $devicesIndex = [Array]::IndexOf([object[]]$arguments, [object]'--devices')
    Assert-True ($devicesIndex -ge 0 -and
        $arguments[$devicesIndex + 1] -ceq '2,5') `
        "The runner did not pass the bounded paired-device filter to USBPcap: $($arguments -join '|')"
    Assert-True ($arguments -cnotcontains '-A') `
        'The paired-device runner unexpectedly selected all USB devices.'

    $state = Get-Content (Join-Path $outputDirectory 'capture.state.json') -Raw |
        ConvertFrom-Json
    Assert-True ($state.captureMode -ceq 'DeviceAddresses') `
        'The paired-device state reported the wrong capture mode.'
    Assert-True (@($state.deviceAddresses).Count -eq 2 -and
        $state.deviceAddresses[0] -eq 2 -and $state.deviceAddresses[1] -eq 5) `
        'The paired-device state did not preserve both selected addresses.'
    Assert-True ($state.service.managementSkipped -eq $true) `
        'The synthetic test unexpectedly exercised service management.'

    $duplicateRejected = $false
    try {
        & $runner -UsbPcapDevice '\\.\USBPcap1' -DeviceAddresses 2,2 `
            -OutputDirectory (Join-Path $testRoot 'duplicate') `
            -StartHelperPath $startHelper -StopHelperPath $stopHelper `
            -UsbPcapExecutablePath $fakeExecutable -SkipAdministratorCheck `
            -SkipServiceManagement | Out-Null
    }
    catch {
        $duplicateRejected = $_.Exception.Message -match 'duplicate'
    }
    Assert-True $duplicateRejected `
        'The capture runner accepted duplicate USB device addresses.'

    Write-Host 'Interactive USBPcap capture regression tests passed.'
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
