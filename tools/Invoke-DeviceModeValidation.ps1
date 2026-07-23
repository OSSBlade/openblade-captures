param(
    [string]$OutputDirectory = 'C:\tmp\openblade-device-mode-validation'
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$capture = Join-Path $repositoryRoot (
    'src\OpenBlade.Capture\bin\Release\net10.0-windows\OpenBlade.Capture.exe')
$stateFile = Join-Path $OutputDirectory 'state.txt'
$outputFile = Join-Path $OutputDirectory 'validation-output.txt'
$controllerServices = @(
    'Razer Elevation Service',
    'Razer Game Manager Service 3'
)
$controllerProcesses = @(
    'GameManagerService3',
    'razer_elevation_service'
)
$servicesToRestore = [System.Collections.Generic.List[string]]::new()
$validationExitCode = $null
$failure = $null

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
"elevated-started $([DateTimeOffset]::Now.ToString('O')) pid=$PID" |
    Set-Content -LiteralPath $stateFile -Encoding utf8

try {
    if (-not (Test-Path -LiteralPath $capture -PathType Leaf)) {
        throw "Capture executable was not found at '$capture'."
    }

    $openBlade = Get-Service -Name 'OpenBlade' -ErrorAction SilentlyContinue
    if ($null -ne $openBlade -and
        $openBlade.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
        throw 'OpenBlade must remain stopped for the isolated validation.'
    }

    foreach ($name in $controllerServices) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -ne $service -and
            $service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
            $servicesToRestore.Add($name)
            Stop-Service -Name $name -Force
            (Get-Service -Name $name).WaitForStatus(
                [System.ServiceProcess.ServiceControllerStatus]::Stopped,
                [TimeSpan]::FromSeconds(15))
        }
    }

    $drainDeadline = [DateTimeOffset]::Now.AddSeconds(15)
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
    Write-Host 'OpenBlade isolated Driver Mode validation'
    Write-Host 'The normal keyboard effect may temporarily turn off.'
    Write-Host 'Normal Mode and the stopped Razer services will be restored afterward.'
    Write-Host ''

    & $capture `
        'validate-device-mode' `
        '--confirm-target' `
        'RZ09-0581:1532:02E0:3.01' 2>&1 |
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
                [TimeSpan]::FromSeconds(15))
        }
        catch {
            if ($null -eq $failure) {
                $failure = $_
            }
        }
    }

    $serviceSummary = $controllerServices |
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
