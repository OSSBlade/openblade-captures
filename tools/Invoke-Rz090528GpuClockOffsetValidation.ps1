param(
    [string]$OutputDirectory = (
        'C:\OpenBlade\openblade-captures\raw\RZ09-0528\' +
        ('{0}-gpu-clock-offset-round-trip' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),
    [switch]$IncludeSpecialKeyProbe
)

$ErrorActionPreference = 'Stop'

$workspace = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$capture = Join-Path $workspace (
    'openblade-core\src\OpenBlade.Capture\bin\Release\' +
    'net10.0-windows10.0.26100.0\OpenBlade.Capture.exe')
$stateFile = Join-Path $OutputDirectory 'state.txt'
$outputFile = Join-Path $OutputDirectory 'validation-output.txt'
$specialKeyOutputFile = Join-Path $OutputDirectory 'special-key-output.txt'
$confirmation = 'RZ09-0528:1532:02C6:GPU-OFFSETS:RESTORE'
$expectedServiceExecutables = @{
    'OpenBlade' = 'C:\Program Files\OpenBlade\OpenBlade.Service.exe'
    'Razer Elevation Service' = (
        'C:\Program Files\Razer\razer_elevation_service\' +
        'razer_elevation_service.exe')
    'Razer Game Manager Service 3' = (
        'C:\Program Files (x86)\Razer\Razer Services\GMS3\' +
        'GameManagerService3.exe')
}
$servicesToRestore = [System.Collections.Generic.List[string]]::new()
$synapseExecutable = $null
$synapseWasRunning = $false
$validationExitCode = $null
$failure = $null
$restorationFailure = $null

function Get-ServiceExecutable {
    param([string]$PathName)

    if ([string]::IsNullOrWhiteSpace($PathName)) {
        return $null
    }
    if ($PathName[0] -eq '"') {
        $closingQuote = $PathName.IndexOf('"', 1)
        if ($closingQuote -le 1) {
            return $null
        }
        return $PathName.Substring(1, $closingQuote - 1)
    }
    $separator = $PathName.IndexOf(' ')
    return if ($separator -lt 0) {
        $PathName
    }
    else {
        $PathName.Substring(0, $separator)
    }
}

function Assert-ServicePath {
    param(
        [string]$Name,
        [string]$ExpectedExecutable
    )

    $service = Get-CimInstance Win32_Service -Filter (
        "Name='$($Name.Replace("'", "''"))'")
    if ($null -eq $service) {
        throw "Required service '$Name' is not installed."
    }
    $actual = Get-ServiceExecutable -PathName $service.PathName
    if (-not [string]::Equals(
            $actual,
            $ExpectedExecutable,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Service '$Name' does not use the verified executable."
    }
}

function Wait-ForNoProcess {
    param(
        [string[]]$Names,
        [TimeSpan]$Timeout
    )

    $deadline = [DateTimeOffset]::Now.Add($Timeout)
    do {
        $remaining = @(
            Get-Process -Name $Names -ErrorAction SilentlyContinue)
        foreach ($process in $remaining) {
            $process.Dispose()
        }
        if ($remaining.Count -eq 0) {
            return
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTimeOffset]::Now -lt $deadline)

    throw 'A verified controller process did not exit before the timeout.'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This GPU validation must run from an elevated Windows PowerShell 5.1 process.'
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
"elevated-started $([DateTimeOffset]::Now.ToString('O'))" |
    Set-Content -LiteralPath $stateFile -Encoding utf8

try {
    if (-not (Test-Path -LiteralPath $capture -PathType Leaf)) {
        throw "Capture executable was not found at '$capture'."
    }

    foreach ($entry in $expectedServiceExecutables.GetEnumerator()) {
        Assert-ServicePath -Name $entry.Key -ExpectedExecutable $entry.Value
    }

    $synapseProcesses = @(
        Get-CimInstance Win32_Process -Filter "Name='RazerAppEngine.exe'")
    if ($synapseProcesses.Count -gt 0) {
        $synapseWasRunning = $true
        $paths = @(
            $synapseProcesses |
                Select-Object -ExpandProperty ExecutablePath -Unique)
        if ($paths.Count -ne 1 -or
            $paths[0] -notmatch (
                '^C:\\Program Files\\Razer\\RazerAppEngine\\' +
                'app-[^\\]+\\RazerAppEngine\.exe$')) {
            throw 'RazerAppEngine is not running from one verified installation path.'
        }
        $synapseExecutable = $paths[0]
        $signature = Get-AuthenticodeSignature -FilePath $synapseExecutable
        if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
            $null -eq $signature.SignerCertificate -or
            $signature.SignerCertificate.Subject -notmatch 'Razer') {
            throw 'RazerAppEngine does not have the expected valid Razer signature.'
        }
    }

    foreach ($name in $expectedServiceExecutables.Keys) {
        $service = Get-Service -Name $name
        if ($service.Status -eq
            [System.ServiceProcess.ServiceControllerStatus]::Running) {
            $servicesToRestore.Add($name)
            Stop-Service -Name $name -Force
            (Get-Service -Name $name).WaitForStatus(
                [System.ServiceProcess.ServiceControllerStatus]::Stopped,
                [TimeSpan]::FromSeconds(20))
        }
    }

    if ($synapseWasRunning) {
        $synapseProcessIds = @(
            $synapseProcesses | Select-Object -ExpandProperty ProcessId)
        Stop-Process -Id $synapseProcessIds -Force
    }
    Wait-ForNoProcess `
        -Names @(
            'OpenBlade.Service',
            'RazerAppEngine',
            'GameManagerService3',
            'razer_elevation_service') `
        -Timeout ([TimeSpan]::FromSeconds(20))

    & $capture `
        'validate-rz09-0528-02c6-gpu-clock-offsets' `
        $confirmation 2>&1 |
        Tee-Object -FilePath $outputFile
    $validationExitCode = $LASTEXITCODE
    if ($IncludeSpecialKeyProbe) {
        Write-Host ''
        Write-Host 'Special-key isolation probe starts now for 60 seconds.'
        Write-Host 'Press Fn+Page Up, Fn+Page Down, Fn+P, Page Up, and Page Down.'
        & $capture `
            'probe-rz09-0528-02c6-special-keys' `
            '60' `
            $specialKeyOutputFile
        if ($LASTEXITCODE -ne 0 -and $validationExitCode -eq 0) {
            $validationExitCode = $LASTEXITCODE
        }
    }
}
catch {
    $failure = $_
}
finally {
    foreach ($name in $servicesToRestore) {
        try {
            Start-Service -Name $name
            (Get-Service -Name $name).WaitForStatus(
                [System.ServiceProcess.ServiceControllerStatus]::Running,
                [TimeSpan]::FromSeconds(20))
        }
        catch {
            if ($null -eq $restorationFailure) {
                $restorationFailure = $_
            }
        }
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

    $validationHash = if (Test-Path -LiteralPath $outputFile -PathType Leaf) {
        (Get-FileHash -Algorithm SHA256 -LiteralPath $outputFile).Hash
    }
    else {
        'Unavailable'
    }
    $specialKeyHash = if (
        Test-Path -LiteralPath $specialKeyOutputFile -PathType Leaf) {
        (Get-FileHash -Algorithm SHA256 -LiteralPath $specialKeyOutputFile).Hash
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
    "$result validationSha256=$validationHash " +
        "specialKeySha256=$specialKeyHash " +
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
