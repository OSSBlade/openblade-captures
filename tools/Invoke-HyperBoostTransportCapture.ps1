[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [ValidateNotNullOrEmpty()]
    [string]$UsbPcapDevice = '\\.\USBPcap3',

    [ValidateNotNullOrEmpty()]
    [string]$ProcmonExecutablePath = 'C:\tmp\openblade-procmon\Procmon64.exe',

    [ValidateRange(60, 900)]
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$captureRunner = Join-Path $PSScriptRoot 'Invoke-InteractiveUsbPcapCapture.ps1'
$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
$markersPath = Join-Path $resolvedOutput 'operator-markers.jsonl'
$readyPath = Join-Path $resolvedOutput 'capture.ready.json'
$captureStatePath = Join-Path $resolvedOutput 'capture.state.json'
$stopPath = Join-Path $resolvedOutput 'capture.stop'
$pmlPath = Join-Path $resolvedOutput 'hyperboost-transport.pml'
$captureProcess = $null
$procmonProcess = $null

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    finally {
        $identity.Dispose()
    }
}

function Write-Marker {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Note = ''
    )

    $marker = [ordered]@{
        atUtc = [DateTimeOffset]::UtcNow.ToString('O')
        name = $Name
        note = $Note
    }
    [IO.File]::AppendAllText(
        $markersPath,
        (($marker | ConvertTo-Json -Compress) + "`r`n"),
        [Text.UTF8Encoding]::new($false))
}

function Stop-ProcmonCapture {
    if ($null -eq $script:procmonProcess) {
        return
    }

    $terminator = Start-Process -FilePath $resolvedProcmon `
        -ArgumentList @('/AcceptEula', '/Quiet', '/Terminate') `
        -WindowStyle Hidden -PassThru -Wait
    try {
        if ($terminator.ExitCode -ne 0) {
            throw "Procmon termination returned exit code $($terminator.ExitCode)."
        }
    }
    finally {
        $terminator.Dispose()
    }

    if (-not $script:procmonProcess.WaitForExit(30000)) {
        throw 'Procmon did not stop within 30 seconds. It was not force-terminated.'
    }
    $script:procmonProcess.Dispose()
    $script:procmonProcess = $null
    if (-not (Test-Path -LiteralPath $pmlPath -PathType Leaf) -or
        (Get-Item -LiteralPath $pmlPath).Length -eq 0) {
        throw 'Procmon stopped without finalizing a nonempty PML.'
    }
}

if (-not (Test-IsAdministrator)) {
    throw 'The HyperBoost transport capture must run from an elevated PowerShell.'
}
if (Test-Path -LiteralPath $resolvedOutput) {
    throw "Refusing to reuse capture directory: $resolvedOutput"
}
if (-not (Test-Path -LiteralPath $captureRunner -PathType Leaf)) {
    throw "USBPcap capture runner not found: $captureRunner"
}
if (Get-Process -Name USBPcapCMD, Procmon, Procmon64 -ErrorAction SilentlyContinue) {
    throw 'USBPcap or Procmon is already active.'
}

$resolvedProcmon = (Resolve-Path -LiteralPath $ProcmonExecutablePath -ErrorAction Stop).Path
if ([IO.Path]::GetFileName($resolvedProcmon) -ine 'Procmon64.exe') {
    throw "Refusing to run an unexpected Procmon executable: $resolvedProcmon"
}
$procmonSignature = Get-AuthenticodeSignature -LiteralPath $resolvedProcmon
if ($procmonSignature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
    [string]$procmonSignature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    throw 'Procmon64.exe does not have a valid Microsoft signature.'
}

$computer = Get-CimInstance -ClassName Win32_ComputerSystemProduct
$bios = Get-CimInstance -ClassName Win32_BIOS
if ([string]$computer.Name -cne 'Blade 16 - RZ09-0581' -or
    [string]$bios.SMBIOSBIOSVersion -cne '4.00') {
    throw "Unexpected capture host: $($computer.Name), BIOS $($bios.SMBIOSBIOSVersion)."
}

$compositeDevices = Get-PnpDevice -PresentOnly | Where-Object {
    $_.InstanceId -match '^USB\\VID_1532&PID_(02E0|0F43)\\'
}
$addresses = @{}
foreach ($device in $compositeDevices) {
    $address = (Get-PnpDeviceProperty -InstanceId $device.InstanceId |
        Where-Object KeyName -eq 'DEVPKEY_Device_Address').Data
    if ($device.InstanceId -match 'PID_02E0') {
        $addresses.Laptop = [int]$address
    }
    elseif ($device.InstanceId -match 'PID_0F43') {
        $addresses.CoolingPad = [int]$address
    }
}
if ($addresses.Laptop -ne 6 -or $addresses.CoolingPad -ne 4) {
    throw "USB addresses changed. Expected laptop 6 and pad 4; found laptop $($addresses.Laptop) and pad $($addresses.CoolingPad)."
}

[IO.Directory]::CreateDirectory($resolvedOutput) | Out-Null
Write-Marker -Name 'PreflightConfirmed' `
    -Note 'RZ09-0581 BIOS 4.00; pad connected; full USBPcap3 root plus Procmon PML'

try {
    $procmonProcess = Start-Process -FilePath $resolvedProcmon `
        -ArgumentList @(
            '/AcceptEula',
            '/Quiet',
            '/Minimized',
            '/BackingFile', $pmlPath) `
        -WindowStyle Hidden -PassThru
    $procmonDeadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    while (-not (Test-Path -LiteralPath $pmlPath -PathType Leaf)) {
        if ($procmonProcess.HasExited) {
            throw "Procmon exited before capture readiness with code $($procmonProcess.ExitCode)."
        }
        if ([DateTimeOffset]::UtcNow -ge $procmonDeadline) {
            throw 'Procmon did not create its backing PML within 30 seconds.'
        }
        Start-Sleep -Milliseconds 100
    }
    Write-Marker -Name 'ProcmonReady'

    $childCommand = @"
& '$captureRunner' -UsbPcapDevice '$UsbPcapDevice' -AllDevices -OutputDirectory '$resolvedOutput' -TimeoutSeconds $TimeoutSeconds
"@
    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($childCommand))
    $captureProcess = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-EncodedCommand', $encodedCommand) `
        -WindowStyle Hidden -PassThru

    $readyDeadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
        if ($captureProcess.HasExited) {
            $stateText = if (Test-Path -LiteralPath $captureStatePath) {
                Get-Content -LiteralPath $captureStatePath -Raw
            }
            else {
                'No capture state was written.'
            }
            throw "USBPcap exited before readiness.`r`n$stateText"
        }
        if ([DateTimeOffset]::UtcNow -ge $readyDeadline) {
            throw 'USBPcap did not become ready within 30 seconds.'
        }
        Start-Sleep -Milliseconds 100
    }
    Write-Marker -Name 'UsbPcapReady'

    Write-Host ''
    Write-Host 'HYPERBOOST TRANSPORT CAPTURE IS RUNNING.' -ForegroundColor Green
    Write-Host 'Raw USB-root and Procmon logs are private and must not be committed.' `
        -ForegroundColor Yellow
    Write-Host 'Keep the cooling pad connected for this session.' -ForegroundColor Cyan
    Write-Host ''

    $baseline = Read-Host `
        '1. Open Blade Performance in Synapse. Type the CURRENT mode (must be Balanced)'
    if ([string]$baseline -cne 'Balanced') {
        throw "Expected the confirmed baseline 'Balanced'; received '$baseline'."
    }
    Write-Marker -Name 'BalancedBaselineConfirmed' -Note 'Balanced; pad connected'

    Read-Host '2. Press Enter immediately BEFORE selecting HyperBoost' | Out-Null
    Write-Marker -Name 'HyperBoostApplyStarting'
    Read-Host '3. Select HyperBoost now, wait ten seconds, confirm the UI still says HyperBoost, then press Enter' | Out-Null
    Write-Marker -Name 'HyperBoostApplyConfirmed' -Note 'Synapse UI confirmation only'

    Read-Host '4. Press Enter immediately BEFORE restoring Balanced' | Out-Null
    Write-Marker -Name 'BalancedRestoreStarting'
    Read-Host '5. Restore Balanced now, wait ten seconds, confirm the UI says Balanced, then press Enter' | Out-Null
    Write-Marker -Name 'BalancedRestoreConfirmed' -Note 'Synapse UI confirmation only'

    Read-Host '6. Leave Synapse idle for five seconds, then press Enter to stop both captures' | Out-Null
    Write-Marker -Name 'StopRequested'
    [IO.File]::WriteAllText($stopPath, '', [Text.UTF8Encoding]::new($false))

    if (-not $captureProcess.WaitForExit(30000)) {
        throw 'USBPcap did not exit within 30 seconds. It was not force-terminated.'
    }
    $captureProcess.Dispose()
    $captureProcess = $null

    $captureState = Get-Content -LiteralPath $captureStatePath -Raw | ConvertFrom-Json
    if ([string]$captureState.status -cne 'Completed' -or
        [string]$captureState.stopMode -cne 'Graceful' -or
        $captureState.service.restarted -ne $true) {
        throw "USBPcap did not finish cleanly: $(Get-Content -LiteralPath $captureStatePath -Raw)"
    }

    Stop-ProcmonCapture
    Write-Marker -Name 'CaptureCompleted' -Note 'USBPcap graceful; Procmon finalized'
    Write-Host ''
    Write-Host 'Capture completed and OpenBlade was restored.' -ForegroundColor Green
    Write-Host "Private output: $resolvedOutput"
}
finally {
    if ($null -ne $captureProcess) {
        if (-not $captureProcess.HasExited -and
            -not (Test-Path -LiteralPath $stopPath -PathType Leaf)) {
            [IO.File]::WriteAllText($stopPath, '', [Text.UTF8Encoding]::new($false))
        }
        [void]$captureProcess.WaitForExit(30000)
        $captureProcess.Dispose()
        $captureProcess = $null
    }
    if ($null -ne $procmonProcess) {
        Stop-ProcmonCapture
    }
}
