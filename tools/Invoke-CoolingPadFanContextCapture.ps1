[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [Parameter(Mandatory)]
    [ValidateRange(1, 127)]
    [int]$CoolingPadDeviceAddress,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$CapturePlaneAddressVerifiedAtUtc,

    [ValidateNotNullOrEmpty()]
    [string]$UsbPcapDevice = '\\.\USBPcap3',

    [ValidateNotNullOrEmpty()]
    [string]$ProcmonExecutablePath = 'C:\tmp\openblade-procmon\Procmon64.exe',

    [ValidateRange(120, 900)]
    [int]$TimeoutSeconds = 420,

    [switch]$FreshSessionOnly
)

$ErrorActionPreference = 'Stop'
$captureRunner = Join-Path $PSScriptRoot 'Invoke-InteractiveUsbPcapCapture.ps1'
$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
$markersPath = Join-Path $resolvedOutput 'operator-markers.jsonl'
$readyPath = Join-Path $resolvedOutput 'capture.ready.json'
$captureStatePath = Join-Path $resolvedOutput 'capture.state.json'
$stopPath = Join-Path $resolvedOutput 'capture.stop'
$pmlPath = Join-Path $resolvedOutput 'cooling-pad-fan-context.pml'
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

function Read-Exact {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Expected
    )

    $actual = Read-Host $Prompt
    if ([string]$actual -cne $Expected) {
        throw "Expected '$Expected'; received '$actual'."
    }
}

function Get-SynapseProcessFingerprint {
    $processes = @(Get-Process -Name RazerAppEngine -ErrorAction SilentlyContinue |
        Sort-Object Id)
    if ($processes.Count -eq 0) {
        return [pscustomobject]@{
            Count = 0
            Hash = $null
            AnchorHash = $null
        }
    }

    $identities = [Collections.Generic.List[string]]::new()
    $anchors = [Collections.Generic.List[object]]::new()
    foreach ($process in $processes) {
        try {
            $path = $process.Path
            if ([string]::IsNullOrWhiteSpace($path)) {
                throw 'RazerAppEngine process path is unavailable.'
            }
            $signature = Get-AuthenticodeSignature -LiteralPath $path
            if ($signature.Status -ne
                    [Management.Automation.SignatureStatus]::Valid -or
                [string]$signature.SignerCertificate.Subject -notmatch 'O=Razer') {
                throw 'RazerAppEngine does not have a valid Razer signature.'
            }
            $startTicks = $process.StartTime.ToUniversalTime().Ticks
            $identity = "$($process.Id):$startTicks"
            [void]$identities.Add($identity)
            [void]$anchors.Add([pscustomobject]@{
                Identity = $identity
                StartTicks = $startTicks
            })
        }
        finally {
            $process.Dispose()
        }
    }

    $material = [Text.Encoding]::UTF8.GetBytes(($identities -join '|'))
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = [BitConverter]::ToString($sha.ComputeHash($material)).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }
    $anchor = $anchors |
        Sort-Object StartTicks, Identity |
        Select-Object -First 1
    $anchorMaterial = [Text.Encoding]::UTF8.GetBytes([string]$anchor.Identity)
    $anchorSha = [Security.Cryptography.SHA256]::Create()
    try {
        $anchorHash = [BitConverter]::ToString(
            $anchorSha.ComputeHash($anchorMaterial)).Replace('-', '')
    }
    finally {
        $anchorSha.Dispose()
    }
    return [pscustomobject]@{
        Count = $identities.Count
        Hash = $hash
        AnchorHash = $anchorHash
    }
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

function Complete-Capture {
    Write-Marker -Name 'StopRequested'
    [IO.File]::WriteAllText($stopPath, '', [Text.UTF8Encoding]::new($false))
    if (-not $script:captureProcess.WaitForExit(30000)) {
        throw 'USBPcap did not exit within 30 seconds. It was not force-terminated.'
    }
    $script:captureProcess.Dispose()
    $script:captureProcess = $null

    $captureState = Get-Content -LiteralPath $captureStatePath -Raw |
        ConvertFrom-Json
    if ([string]$captureState.status -cne 'Completed' -or
        [string]$captureState.stopMode -cne 'Graceful' -or
        $captureState.service.managementSkipped -ne $true -or
        $captureState.service.restarted -ne $false) {
        throw "USBPcap did not finish cleanly: $(Get-Content -LiteralPath $captureStatePath -Raw)"
    }

    Stop-ProcmonCapture
    Write-Marker -Name 'CaptureCompleted' `
        -Note 'USBPcap graceful; Procmon finalized; OpenBlade remained stopped'
    Write-Host ''
    Write-Host 'Capture completed. OpenBlade remains stopped.' -ForegroundColor Green
    Write-Host "Private output: $resolvedOutput"
}

if (-not (Test-IsAdministrator)) {
    throw 'The cooling-pad fan-context capture must run from elevated PowerShell.'
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
if ((Get-Service -Name OpenBlade -ErrorAction Stop).Status -ne 'Stopped') {
    throw 'OpenBlade must remain stopped throughout this Synapse-owned capture.'
}
if (Get-Process -Name RazerAppEngine -ErrorAction SilentlyContinue) {
    throw 'Start with Synapse fully closed; the capture must include its handle lifetime.'
}

$addressVerifiedAt = [DateTimeOffset]::MinValue
if (-not [DateTimeOffset]::TryParse(
    $CapturePlaneAddressVerifiedAtUtc,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal,
    [ref]$addressVerifiedAt)) {
    throw 'CapturePlaneAddressVerifiedAtUtc must be an ISO-8601 timestamp.'
}
$verificationAge = [DateTimeOffset]::UtcNow - $addressVerifiedAt.ToUniversalTime()
if ($verificationAge.TotalSeconds -lt -5 -or
    $verificationAge.TotalMinutes -gt 15) {
    throw 'The USBPcap address verification must be no more than 15 minutes old.'
}

$biosIdentity = Get-ItemProperty `
    -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' `
    -ErrorAction Stop
$systemIdentity = Get-ItemProperty `
    -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\SystemInformation' `
    -ErrorAction Stop
if ([string]$biosIdentity.SystemManufacturer -cne 'Razer' -or
    [string]$biosIdentity.SystemProductName -cne 'Blade 16 - RZ09-0581' -or
    [string]$biosIdentity.SystemSKU -cne 'RZ09-05819EN4' -or
    [string]$biosIdentity.BIOSVersion -cne '4.00' -or
    [string]$systemIdentity.SystemManufacturer -cne
        [string]$biosIdentity.SystemManufacturer -or
    [string]$systemIdentity.SystemProductName -cne
        [string]$biosIdentity.SystemProductName -or
    [string]$systemIdentity.BIOSVersion -cne
        [string]$biosIdentity.BIOSVersion) {
    throw 'Unexpected capture host identity.'
}

$padDevices = @(Get-PnpDevice -PresentOnly | Where-Object {
    $_.Class -eq 'USB' -and
    $_.InstanceId -match '^USB\\VID_1532&PID_0F43\\'
})
if ($padDevices.Count -ne 1) {
    throw 'Expected exactly one present cooling-pad USB composite.'
}
$padHardwareIds = @((Get-PnpDeviceProperty `
    -InstanceId $padDevices[0].InstanceId `
    -KeyName 'DEVPKEY_Device_HardwareIds' `
    -ErrorAction Stop).Data)
if (-not ($padHardwareIds -ccontains 'USB\VID_1532&PID_0F43&REV_0200')) {
    throw 'The present cooling-pad composite is not revision 0200.'
}
$pnpAddress = [int](Get-PnpDeviceProperty `
    -InstanceId $padDevices[0].InstanceId `
    -KeyName 'DEVPKEY_Device_Address' `
    -ErrorAction Stop).Data
if ($pnpAddress -lt 1 -or $pnpAddress -gt 127) {
    throw "Cooling-pad PnP address is invalid: $pnpAddress."
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

[IO.Directory]::CreateDirectory($resolvedOutput) | Out-Null
Write-Marker -Name 'PreflightConfirmed' `
    -Note "RZ09-0581 exact SKU; BIOS 4.00; PID 0F43 REV 0200; PnPAddress=$pnpAddress; CaptureAddress=$CoolingPadDeviceAddress; OpenBlade stopped; Synapse closed"

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
& '$captureRunner' -UsbPcapDevice '$UsbPcapDevice' -DeviceAddress $CoolingPadDeviceAddress -OutputDirectory '$resolvedOutput' -TimeoutSeconds $TimeoutSeconds -SkipAdministratorCheck -SkipServiceManagement
"@
    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($childCommand))
    $captureProcess = Start-Process `
        -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
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
    Write-Host 'COOLING-PAD FAN CONTEXT CAPTURE IS RUNNING.' -ForegroundColor Green
    Write-Host 'Raw USB and Procmon output is private and must not be committed.' `
        -ForegroundColor Yellow
    Write-Host 'This is a Synapse-owned oracle capture; OpenBlade sends no HID command.' `
        -ForegroundColor Cyan
    Write-Host ''

    if ($FreshSessionOnly) {
        Write-Marker -Name 'FreshSynapseLaunchStarting' `
            -Note 'Preflight observed zero RazerAppEngine processes'
        Read-Exact `
            -Prompt '1. Launch Synapse, wait for the cooling pad to become ready in Auto, then type FRESH PAD READY' `
            -Expected 'FRESH PAD READY'
        $freshProcess = Get-SynapseProcessFingerprint
        if ($freshProcess.Count -eq 0) {
            throw 'RazerAppEngine was not running after the fresh pad-ready confirmation.'
        }
        Write-Marker -Name 'FreshSynapseProcessConfirmed' `
            -Note "ProcessCount=$($freshProcess.Count);ProcessSetHash=$($freshProcess.Hash);ProcessAnchorHash=$($freshProcess.AnchorHash)"

        $baselineBrightnessText = Read-Host `
            '2. Enter the restored cooling-pad lighting brightness percent (1-100)'
        $baselineBrightness = 0
        if (-not [int]::TryParse(
                $baselineBrightnessText,
                [ref]$baselineBrightness) -or
            $baselineBrightness -lt 1 -or $baselineBrightness -gt 100) {
            throw 'The restored brightness must be an integer from 1 through 100.'
        }
        Write-Marker -Name 'LightingBaselineSaved' `
            -Note "BrightnessPercent=$baselineBrightness"
        Write-Marker -Name 'FreshLitBaselineConfirmed' `
            -Note "BrightnessPercent=$baselineBrightness;Auto=True"
        Start-Sleep -Seconds 5

        Read-Host '3. Press Enter immediately BEFORE selecting Fixed, High preset, 2200 RPM' | Out-Null
        Write-Marker -Name 'FreshLitFixedStarting'
        Read-Exact `
            -Prompt 'Select Fixed / High / 2200 now, wait five seconds, confirm the UI and pad indicator, then type FRESH LIT FIXED 2200 CONFIRMED' `
            -Expected 'FRESH LIT FIXED 2200 CONFIRMED'
        Write-Marker -Name 'FreshLitFixedConfirmed' `
            -Note 'Operator UI and indicator confirmation only'

        Read-Host '4. Press Enter immediately BEFORE selecting Auto' | Out-Null
        Write-Marker -Name 'FreshLitAutoStarting'
        Read-Exact `
            -Prompt 'Select Auto now, wait five seconds, confirm the UI and pad indicator, then type FRESH LIT AUTO CONFIRMED' `
            -Expected 'FRESH LIT AUTO CONFIRMED'
        Write-Marker -Name 'FreshLitAutoConfirmed' `
            -Note 'Operator UI and indicator confirmation only'

        Read-Exact `
            -Prompt "5. Confirm Auto and brightness $baselineBrightness are restored, fully exit Synapse, wait for it to close, then type RESTORED AND CLOSED" `
            -Expected 'RESTORED AND CLOSED'
        $synapseDeadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
        while (Get-Process -Name RazerAppEngine -ErrorAction SilentlyContinue) {
            if ([DateTimeOffset]::UtcNow -ge $synapseDeadline) {
                throw 'RazerAppEngine remained active after the final operator confirmation.'
            }
            Start-Sleep -Milliseconds 250
        }
        Write-Marker -Name 'FinalSynapseExited' `
            -Note "Auto=True;BrightnessPercent=$baselineBrightness;ProcessCount=0"
        Start-Sleep -Seconds 3
        Complete-Capture
        return
    }

    Read-Exact `
        -Prompt '1. Launch Synapse, wait for the cooling pad to become ready in Auto, then type PAD READY' `
        -Expected 'PAD READY'
    Write-Marker -Name 'SynapsePadReady' -Note 'Operator-confirmed Auto baseline'

    $baselineBrightnessText = Read-Host `
        '2. Enter the current cooling-pad lighting brightness percent (1-100)'
    $baselineBrightness = 0
    if (-not [int]::TryParse($baselineBrightnessText, [ref]$baselineBrightness) -or
        $baselineBrightness -lt 1 -or $baselineBrightness -gt 100) {
        throw 'The saved brightness must be an integer from 1 through 100.'
    }
    Write-Marker -Name 'LightingBaselineSaved' `
        -Note "BrightnessPercent=$baselineBrightness"

    $retainedProcess = Get-SynapseProcessFingerprint
    if ($retainedProcess.Count -eq 0) {
        throw 'RazerAppEngine was not running after the pad-ready confirmation.'
    }
    Write-Marker -Name 'RetainedSynapseProcessConfirmed' `
        -Note "ProcessCount=$($retainedProcess.Count);ProcessSetHash=$($retainedProcess.Hash);ProcessAnchorHash=$($retainedProcess.AnchorHash)"

    Write-Marker -Name 'RetainedLitBaselineConfirmed' `
        -Note "BrightnessPercent=$baselineBrightness;Auto=True"
    Start-Sleep -Seconds 5

    Read-Host '3. Press Enter immediately BEFORE selecting Fixed, High preset, 2200 RPM' | Out-Null
    Write-Marker -Name 'RetainedLitFixedStarting'
    Read-Exact `
        -Prompt 'Select Fixed / High / 2200 now, wait five seconds, confirm the UI and pad indicator, then type RETAINED LIT FIXED 2200 CONFIRMED' `
        -Expected 'RETAINED LIT FIXED 2200 CONFIRMED'
    Write-Marker -Name 'RetainedLitFixedConfirmed' `
        -Note 'Operator UI and indicator confirmation only'

    Read-Host '4. Press Enter immediately BEFORE selecting Auto' | Out-Null
    Write-Marker -Name 'RetainedLitAutoStarting'
    Read-Exact `
        -Prompt 'Select Auto now, wait five seconds, confirm the UI and pad indicator, then type RETAINED LIT AUTO CONFIRMED' `
        -Expected 'RETAINED LIT AUTO CONFIRMED'
    Write-Marker -Name 'RetainedLitAutoConfirmed' `
        -Note 'Operator UI and indicator confirmation only'

    $beforeDark = Get-SynapseProcessFingerprint
    if ($beforeDark.Count -eq 0 -or
        [string]$beforeDark.AnchorHash -cne
            [string]$retainedProcess.AnchorHash) {
        throw 'The stable Synapse process anchor changed before the lighting-off context.'
    }
    Write-Marker -Name 'RetainedSessionContinuityConfirmed' `
        -Note "ProcessCount=$($beforeDark.Count);ProcessSetHash=$($beforeDark.Hash);ProcessAnchorHash=$($beforeDark.AnchorHash)"

    Read-Exact `
        -Prompt '5. Set cooling-pad lighting brightness to 0, confirm the strip is dark, then type DARK' `
        -Expected 'DARK'
    Write-Marker -Name 'DarkLightingConfirmed'
    Start-Sleep -Seconds 5

    Read-Host '6. Press Enter immediately BEFORE selecting Fixed, High preset, 2200 RPM' | Out-Null
    Write-Marker -Name 'DarkFixedStarting'
    Read-Exact `
        -Prompt 'Select Fixed / High / 2200 now, wait five seconds, confirm the UI and pad indicator, then type DARK FIXED 2200 CONFIRMED' `
        -Expected 'DARK FIXED 2200 CONFIRMED'
    Write-Marker -Name 'DarkFixedConfirmed' -Note 'Operator UI and indicator confirmation only'

    Read-Host '7. Press Enter immediately BEFORE selecting Auto' | Out-Null
    Write-Marker -Name 'DarkAutoStarting'
    Read-Exact `
        -Prompt 'Select Auto now, wait five seconds, confirm the UI and pad indicator, then type DARK AUTO CONFIRMED' `
        -Expected 'DARK AUTO CONFIRMED'
    Write-Marker -Name 'DarkAutoConfirmed' -Note 'Operator UI and indicator confirmation only'

    $afterDark = Get-SynapseProcessFingerprint
    if ($afterDark.Count -eq 0 -or
        [string]$afterDark.AnchorHash -cne
            [string]$retainedProcess.AnchorHash) {
        throw 'The stable Synapse process anchor changed during the lighting-off context.'
    }
    Write-Marker -Name 'DarkContextSameSessionConfirmed' `
        -Note "ProcessCount=$($afterDark.Count);ProcessSetHash=$($afterDark.Hash);ProcessAnchorHash=$($afterDark.AnchorHash)"

    Read-Exact `
        -Prompt "8. Restore lighting brightness to $baselineBrightness, confirm the strip is lit and Auto remains selected, then type LIT RESTORED" `
        -Expected 'LIT RESTORED'
    Write-Marker -Name 'OriginalLightingRestoredBeforeRestart' `
        -Note "BrightnessPercent=$baselineBrightness;Auto=True"

    Write-Marker -Name 'SynapseExitStarting'
    Read-Exact `
        -Prompt '9. Fully exit Synapse, wait for it to close, then type SYNAPSE EXITED' `
        -Expected 'SYNAPSE EXITED'
    $synapseDeadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
    while (Get-Process -Name RazerAppEngine -ErrorAction SilentlyContinue) {
        if ([DateTimeOffset]::UtcNow -ge $synapseDeadline) {
            throw 'RazerAppEngine remained active after the operator confirmed closure.'
        }
        Start-Sleep -Milliseconds 250
    }
    Write-Marker -Name 'SynapseFullyExited' -Note 'ProcessCount=0'
    Start-Sleep -Seconds 3

    Write-Marker -Name 'FreshSynapseLaunchStarting'
    Read-Exact `
        -Prompt '10. Launch Synapse again, wait for the cooling pad to become ready in Auto with its original lighting, then type FRESH PAD READY' `
        -Expected 'FRESH PAD READY'
    $freshProcess = Get-SynapseProcessFingerprint
    if ($freshProcess.Count -eq 0 -or
        [string]$freshProcess.AnchorHash -ceq
            [string]$retainedProcess.AnchorHash) {
        throw 'Synapse did not establish a disjoint fresh process anchor.'
    }
    Write-Marker -Name 'FreshSynapseProcessConfirmed' `
        -Note "ProcessCount=$($freshProcess.Count);ProcessSetHash=$($freshProcess.Hash);ProcessAnchorHash=$($freshProcess.AnchorHash)"
    Write-Marker -Name 'FreshLitBaselineConfirmed' `
        -Note "BrightnessPercent=$baselineBrightness;Auto=True"
    Start-Sleep -Seconds 5

    Read-Host '11. Press Enter immediately BEFORE selecting Fixed, High preset, 2200 RPM in the fresh session' | Out-Null
    Write-Marker -Name 'FreshLitFixedStarting'
    Read-Exact `
        -Prompt 'Select Fixed / High / 2200 now, wait five seconds, confirm the UI and pad indicator, then type FRESH LIT FIXED 2200 CONFIRMED' `
        -Expected 'FRESH LIT FIXED 2200 CONFIRMED'
    Write-Marker -Name 'FreshLitFixedConfirmed' `
        -Note 'Operator UI and indicator confirmation only'

    Read-Host '12. Press Enter immediately BEFORE selecting Auto in the fresh session' | Out-Null
    Write-Marker -Name 'FreshLitAutoStarting'
    Read-Exact `
        -Prompt 'Select Auto now, wait five seconds, confirm the UI and pad indicator, then type FRESH LIT AUTO CONFIRMED' `
        -Expected 'FRESH LIT AUTO CONFIRMED'
    Write-Marker -Name 'FreshLitAutoConfirmed' `
        -Note 'Operator UI and indicator confirmation only'

    Read-Exact `
        -Prompt "13. Confirm Auto and brightness $baselineBrightness are restored, fully exit Synapse, wait for it to close, then type RESTORED AND CLOSED" `
        -Expected 'RESTORED AND CLOSED'
    $synapseDeadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
    while (Get-Process -Name RazerAppEngine -ErrorAction SilentlyContinue) {
        if ([DateTimeOffset]::UtcNow -ge $synapseDeadline) {
            throw 'RazerAppEngine remained active after the final operator confirmation.'
        }
        Start-Sleep -Milliseconds 250
    }
    Write-Marker -Name 'FinalSynapseExited' `
        -Note "Auto=True;BrightnessPercent=$baselineBrightness;ProcessCount=0"
    Start-Sleep -Seconds 3

    # The two signed-process hashes are retained only in the private marker
    # log. Sanitized evidence may report same/disjoint booleans, never process
    # IDs, start times, or paths.

    Complete-Capture
}
finally {
    if ($null -ne $captureProcess) {
        if (-not $captureProcess.HasExited -and
            -not (Test-Path -LiteralPath $stopPath -PathType Leaf)) {
            [IO.File]::WriteAllText(
                $stopPath,
                '',
                [Text.UTF8Encoding]::new($false))
        }
        [void]$captureProcess.WaitForExit(30000)
        $captureProcess.Dispose()
        $captureProcess = $null
    }
    if ($null -ne $procmonProcess) {
        Stop-ProcmonCapture
    }
}
