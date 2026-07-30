param(
    [string]$OutputDirectory = (
        'C:\OpenBlade\openblade-captures\raw\RZ09-0528\' +
        ('{0}-cpu-tuning-preconnect-lifecycle' -f (
            Get-Date -Format 'yyyyMMdd-HHmmss')))
)

$ErrorActionPreference = 'Stop'

$workspace = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$capture = Join-Path $workspace (
    'openblade-core\src\OpenBlade.Capture\bin\Release\' +
    'net10.0-windows10.0.26100.0\OpenBlade.Capture.exe')
$stateFile = Join-Path $OutputDirectory 'state.txt'
$outputFile = Join-Path $OutputDirectory 'validation-output.txt'
$errorFile = Join-Path $OutputDirectory 'validation-error.txt'
$synapseExecutable = $null
$synapseProcessIds = @()
$synapseWasRunning = $false
$probe = $null
$readyEvent = $null
$isolatedEvent = $null
$validationExitCode = $null
$failure = $null
$restorationFailure = $null

function Wait-ForNoProcess {
    param(
        [string]$Name,
        [TimeSpan]$Timeout
    )

    $deadline = [DateTimeOffset]::Now.Add($Timeout)
    do {
        $remaining = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
        foreach ($process in $remaining) {
            $process.Dispose()
        }
        if ($remaining.Count -eq 0) {
            return
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTimeOffset]::Now -lt $deadline)

    throw "The verified '$Name' controller processes did not exit."
}

function Get-VerifiedSynapse {
    $processes = @(
        Get-CimInstance Win32_Process -Filter "Name='RazerAppEngine.exe'")
    if ($processes.Count -eq 0) {
        throw 'Synapse must be running so OpenBlade can preconnect to its live CPU backend.'
    }

    $paths = @(
        $processes |
            Select-Object -ExpandProperty ExecutablePath -Unique)
    if ($paths.Count -ne 1 -or
        $paths[0] -notmatch (
            '^C:\\Program Files\\Razer\\RazerAppEngine\\' +
            'app-[^\\]+\\RazerAppEngine\.exe$')) {
        throw 'RazerAppEngine is not running from one verified installation path.'
    }

    $signature = Get-AuthenticodeSignature -FilePath $paths[0]
    if ($signature.Status -ne
            [System.Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch 'Razer') {
        throw 'RazerAppEngine does not have the expected valid Razer signature.'
    }

    return [pscustomobject]@{
        Executable = $paths[0]
        ProcessIds = @($processes | Select-Object -ExpandProperty ProcessId)
    }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This CPU lifecycle validation must run from an elevated Windows PowerShell 5.1 process.'
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
"elevated-started $([DateTimeOffset]::Now.ToString('O'))" |
    Set-Content -LiteralPath $stateFile -Encoding utf8

try {
    if (-not (Test-Path -LiteralPath $capture -PathType Leaf)) {
        throw "Capture executable was not found at '$capture'."
    }

    $synapse = Get-VerifiedSynapse
    $synapseWasRunning = $true
    $synapseExecutable = $synapse.Executable
    $synapseProcessIds = @($synapse.ProcessIds)

    $eventIdentity = [Guid]::NewGuid().ToString('N')
    $readyName = (
        'Local\OpenBlade.Rz090528.CpuPower.{0}.ready' -f $eventIdentity)
    $isolatedName = (
        'Local\OpenBlade.Rz090528.CpuPower.{0}.isolated' -f $eventIdentity)
    $readyEvent = [Threading.EventWaitHandle]::new(
        $false,
        [Threading.EventResetMode]::ManualReset,
        $readyName)
    $isolatedEvent = [Threading.EventWaitHandle]::new(
        $false,
        [Threading.EventResetMode]::ManualReset,
        $isolatedName)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $capture
    $startInfo.Arguments = (
        'query-rz09-0528-02c6-cpu-power-service-preconnected ' +
        ('"{0}" "{1}"' -f $readyName, $isolatedName))
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $probe = [Diagnostics.Process]::Start($startInfo)
    if ($null -eq $probe) {
        throw 'The CPU lifecycle probe process did not start.'
    }

    if (-not $readyEvent.WaitOne([TimeSpan]::FromSeconds(20))) {
        throw 'The CPU lifecycle probe did not preconnect before the timeout.'
    }
    if ($probe.HasExited) {
        throw "The CPU lifecycle probe exited before isolation with code $($probe.ExitCode)."
    }

    Stop-Process -Id $synapseProcessIds -Force
    Wait-ForNoProcess `
        -Name 'RazerAppEngine' `
        -Timeout ([TimeSpan]::FromSeconds(20))
    if (-not $isolatedEvent.Set()) {
        throw 'The CPU lifecycle isolation signal could not be set.'
    }

    if (-not $probe.WaitForExit(30000)) {
        $probe.Kill()
        throw 'The CPU lifecycle probe did not finish before the timeout.'
    }

    $probe.StandardOutput.ReadToEnd() |
        Set-Content -LiteralPath $outputFile -Encoding utf8
    $probe.StandardError.ReadToEnd() |
        Set-Content -LiteralPath $errorFile -Encoding utf8
    $validationExitCode = $probe.ExitCode
}
catch {
    $failure = $_
}
finally {
    if ($null -ne $probe -and -not $probe.HasExited) {
        try {
            $probe.Kill()
            $probe.WaitForExit(5000) | Out-Null
        }
        catch {
            if ($null -eq $restorationFailure) {
                $restorationFailure = $_
            }
        }
    }
    if ($null -ne $readyEvent) {
        $readyEvent.Dispose()
    }
    if ($null -ne $isolatedEvent) {
        $isolatedEvent.Dispose()
    }
    if ($null -ne $probe) {
        $probe.Dispose()
    }

    if ($synapseWasRunning -and $null -ne $synapseExecutable) {
        try {
            Start-Process `
                -FilePath $synapseExecutable `
                -ArgumentList '--url-params=apps=synapse' `
                -WindowStyle Hidden
            $deadline = [DateTimeOffset]::Now.AddSeconds(20)
            do {
                Start-Sleep -Milliseconds 250
                $restarted = @(
                    Get-CimInstance Win32_Process -Filter (
                        "Name='RazerAppEngine.exe'") |
                        Where-Object {
                            [string]::Equals(
                                $_.ExecutablePath,
                                $synapseExecutable,
                                [System.StringComparison]::OrdinalIgnoreCase)
                        })
            } while ($restarted.Count -eq 0 -and
                [DateTimeOffset]::Now -lt $deadline)
            if ($restarted.Count -eq 0) {
                throw 'The verified Synapse app engine did not restart.'
            }
        }
        catch {
            if ($null -eq $restorationFailure) {
                $restorationFailure = $_
            }
        }
    }

    $outputHash = if (Test-Path -LiteralPath $outputFile -PathType Leaf) {
        (Get-FileHash -Algorithm SHA256 -LiteralPath $outputFile).Hash
    }
    else {
        'Unavailable'
    }
    $errorHash = if (Test-Path -LiteralPath $errorFile -PathType Leaf) {
        (Get-FileHash -Algorithm SHA256 -LiteralPath $errorFile).Hash
    }
    else {
        'Unavailable'
    }
    $result = if ($null -ne $failure) {
        "failed $($failure.Exception.GetType().FullName): " +
            $failure.Exception.Message
    }
    elseif ($null -ne $restorationFailure) {
        "restoration-failed " +
            "$($restorationFailure.Exception.GetType().FullName): " +
            $restorationFailure.Exception.Message
    }
    else {
        "finished exit=$validationExitCode"
    }
    "$result outputSha256=$outputHash errorSha256=$errorHash " +
        "$([DateTimeOffset]::Now.ToString('O'))" |
        Set-Content -LiteralPath $stateFile -Encoding utf8
}

if ($null -ne $failure) {
    Write-Error $failure
    exit 1
}
if ($null -ne $restorationFailure) {
    Write-Error $restorationFailure
    exit 3
}
exit $validationExitCode
