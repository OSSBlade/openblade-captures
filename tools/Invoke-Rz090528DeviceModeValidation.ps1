param(
    [string]$OutputDirectory = (
        'C:\OpenBlade\openblade-captures\raw\RZ09-0528\' +
        ('{0}-device-mode-round-trip' -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

$ErrorActionPreference = 'Stop'

$workspace = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$capture = Join-Path $workspace (
    'openblade-core\src\OpenBlade.Capture\bin\Release\' +
    'net10.0-windows10.0.26100.0\OpenBlade.Capture.exe')
$stateFile = Join-Path $OutputDirectory 'state.txt'
$outputFile = Join-Path $OutputDirectory 'validation-output.txt'
$serviceNames = @(
    'OpenBlade',
    'Razer Elevation Service',
    'Razer Game Manager Service 3'
)
$controllerProcesses = @(
    'OpenBlade.Service',
    'GameManagerService3',
    'razer_elevation_service',
    'RazerAppEngine'
)
$servicesToRestore = [System.Collections.Generic.List[string]]::new()
$validationExitCode = $null
$failure = $null

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This exact-device validation must run from an elevated PowerShell 5.1 process.'
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
"elevated-started $([DateTimeOffset]::Now.ToString('O'))" |
    Set-Content -LiteralPath $stateFile -Encoding utf8

try {
    if (-not (Test-Path -LiteralPath $capture -PathType Leaf)) {
        throw "Capture executable was not found at '$capture'."
    }

    foreach ($name in $serviceNames) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -ne $service -and
            $service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
            $servicesToRestore.Add($name)
            Stop-Service -Name $name -Force
            (Get-Service -Name $name).WaitForStatus(
                [System.ServiceProcess.ServiceControllerStatus]::Stopped,
                [TimeSpan]::FromSeconds(20))
        }
    }

    Get-Process -Name 'RazerAppEngine' -ErrorAction SilentlyContinue |
        Stop-Process -Force

    $drainDeadline = [DateTimeOffset]::Now.AddSeconds(20)
    do {
        $remainingControllers = @(
            Get-Process -Name $controllerProcesses -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty ProcessName -Unique)
        if ($remainingControllers.Count -eq 0) {
            break
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTimeOffset]::Now -lt $drainDeadline)

    if ($remainingControllers.Count -ne 0) {
        throw "Controller processes did not exit: $($remainingControllers -join ', ')."
    }

    Write-Host ''
    Write-Host 'OpenBlade isolated RZ09-0528 / PID 02C6 device-mode validation'
    Write-Host 'The keyboard effect may temporarily turn off.'
    Write-Host 'The validator applies the mode opposite the exact starting baseline.'
    Write-Host 'When prompted, hold Fn and verify the expected function-layer behavior.'
    Write-Host 'Type YES only when the behavior is correct.'
    Write-Host 'The exact starting mode and all stopped services are restored before exit.'
    Write-Host ''

    & $capture `
        'validate-rz09-0528-02c6-device-mode' `
        '--confirm-target' `
        'RZ09-0528:1532:02C6:2.02' 2>&1 |
        Tee-Object -FilePath $outputFile
    $validationExitCode = $LASTEXITCODE
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
            if ($null -eq $failure) {
                $failure = $_
            }
        }
    }

    $serviceSummary = $serviceNames |
        ForEach-Object {
            $service = Get-Service -Name $_ -ErrorAction SilentlyContinue
            if ($null -eq $service) {
                "$_=Absent"
            }
            else {
                "$_=$($service.Status)"
            }
        }
    if ($null -ne $failure) {
        "failed $([DateTimeOffset]::Now.ToString('O')) " +
            "services=$($serviceSummary -join ',') " +
            "$($failure.Exception.GetType().FullName): $($failure.Exception.Message)" |
            Set-Content -LiteralPath $stateFile -Encoding utf8
    }
    else {
        "finished $([DateTimeOffset]::Now.ToString('O')) exit=$validationExitCode " +
            "services=$($serviceSummary -join ',')" |
            Set-Content -LiteralPath $stateFile -Encoding utf8
    }
}

if ($null -ne $failure) {
    Write-Error $failure
    exit 1
}

exit $validationExitCode
