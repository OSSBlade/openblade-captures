param(
    [string]$OutputDirectory = (
        'C:\OpenBlade\openblade-captures\raw\RZ09-0528\' +
        ('{0}-cpu-tuning-module-ownership' -f (
            Get-Date -Format 'yyyyMMdd-HHmmss')))
)

$ErrorActionPreference = 'Stop'

$outputFile = Join-Path $OutputDirectory 'module-ownership.json'
$stateFile = Join-Path $OutputDirectory 'state.txt'
trap {
    try {
        New-Item -ItemType Directory -Path $OutputDirectory -Force |
            Out-Null
        $failureMessage = $_.Exception.Message -replace '\s+', ' '
        "finished success=false error=$failureMessage " +
            "$([DateTimeOffset]::Now.ToString('O'))" |
            Set-Content -LiteralPath $stateFile -Encoding utf8
    }
    catch {
        # Preserve the original failure if even private state persistence fails.
    }
    exit 1
}

$expectedComponents = @{
    'RzAMDOverClock_v1.1.15.0.dll' = @{
        Kind = 'Client'
        Sha256 = '9F0EE89C1E003D2990880BABC7612FA76D0259A716B955FBC0A7D34D5DE8A418'
    }
    'RzAMDOverClockDLL_v1.1.15.0.dll' = @{
        Kind = 'Server'
        Sha256 = '7966CF2F6DEAF18A277ACAFED433063AFEC7DB9F5C4275729601AAB40B54EB9E'
    }
    'RzDLLService_v1.0.29.0.exe' = @{
        Kind = 'ServiceHost'
        Sha256 = 'C7D47D88CDA40EC9CC84ABBBBF4B8EBAD13F5113A2DDDADEADF8A8AD6CE87436'
    }
}

function Get-RazerPageRole {
    param([string]$CommandLine)

    if ($CommandLine -match '(?:^|\s)--razer-page-name=([^\s]+)') {
        return $Matches[1]
    }
    if ($CommandLine -match '(?:^|\s)--type=([^\s]+)') {
        return "electron-$($Matches[1])"
    }
    return 'main-or-utility'
}

function Assert-VerifiedAppEnginePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        $Path -notmatch (
            '^C:\\Program Files\\Razer\\RazerAppEngine\\' +
            'app-[^\\]+\\RazerAppEngine\.exe$')) {
        throw "RazerAppEngine path '$Path' is outside the verified installation."
    }
    $signature = Get-AuthenticodeSignature -FilePath $Path
    if ($signature.Status -ne
            [System.Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch 'Razer') {
        throw "RazerAppEngine path '$Path' lacks the expected valid Razer signature."
    }
}

function Get-ExpectedLoadedComponents {
    param([int]$ProcessId)

    $result = @()
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    try {
        foreach ($module in @($process.Modules)) {
            if (-not $expectedComponents.ContainsKey($module.ModuleName)) {
                continue
            }
            $expected = $expectedComponents[$module.ModuleName]
            $hash = (Get-FileHash `
                -Algorithm SHA256 `
                -LiteralPath $module.FileName).Hash
            if ($hash -cne $expected.Sha256) {
                throw (
                    "Loaded component '$($module.ModuleName)' has an " +
                    'unexpected SHA-256 hash.')
            }
            $result += [pscustomobject]@{
                kind = $expected.Kind
                fileName = $module.ModuleName
                sha256 = $hash
            }
        }
    }
    finally {
        $process.Dispose()
    }
    return @($result)
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This read-only module inventory must run from an elevated Windows PowerShell 5.1 process.'
}

$system = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
if ($system.Model -cne 'Blade 16 - RZ09-0528' -or
    $bios.SMBIOSBIOSVersion -cne '2.02') {
    throw 'This module inventory is restricted to RZ09-0528 BIOS 2.02.'
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
"elevated-started $([DateTimeOffset]::Now.ToString('O'))" |
    Set-Content -LiteralPath $stateFile -Encoding utf8

$records = @()
$controllers = @(
    Get-CimInstance Win32_Process -Filter "Name='RazerAppEngine.exe'")
foreach ($controller in $controllers) {
    Assert-VerifiedAppEnginePath -Path $controller.ExecutablePath
    $records += [pscustomobject]@{
        processKind = 'RazerAppEngine'
        processId = [int]$controller.ProcessId
        parentProcessId = [int]$controller.ParentProcessId
        role = Get-RazerPageRole -CommandLine $controller.CommandLine
        loadedComponents = @(
            Get-ExpectedLoadedComponents -ProcessId $controller.ProcessId)
    }
}

$backendProcesses = @(
    Get-CimInstance Win32_Process -Filter "Name='RzDLLService_v1.0.29.0.exe'")
foreach ($backend in $backendProcesses) {
    $records += [pscustomobject]@{
        processKind = 'RzDLLService'
        processId = [int]$backend.ProcessId
        parentProcessId = [int]$backend.ParentProcessId
        role = 'cpu-tuning-backend'
        loadedComponents = @(
            Get-ExpectedLoadedComponents -ProcessId $backend.ProcessId)
    }
}

$document = [ordered]@{
    schemaVersion = 1
    capturedAt = [DateTimeOffset]::Now.ToString('O')
    device = [ordered]@{
        modelNumber = 'RZ09-0528'
        productIdHex = '02C6'
        bios = '2.02'
    }
    readOnly = $true
    settingChanged = $false
    processes = @($records)
    matchedComponentProcessCount = @(
        $records |
            Where-Object { $_.loadedComponents.Count -gt 0 }).Count
}
$document |
    ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath $outputFile -Encoding utf8

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $outputFile).Hash
$length = (Get-Item -LiteralPath $outputFile).Length
"finished success=true outputSha256=$hash outputBytes=$length " +
    "$([DateTimeOffset]::Now.ToString('O'))" |
    Set-Content -LiteralPath $stateFile -Encoding utf8

Write-Output "OutputSha256=$hash"
Write-Output "OutputBytes=$length"
Write-Output "ProcessCount=$($records.Count)"
Write-Output (
    "MatchedComponentProcessCount=$($document.matchedComponentProcessCount)")
