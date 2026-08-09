[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory)][string]$StatePath,
    [Parameter(Mandatory)][string]$PcapPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
$state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
$resolvedPcap = (Resolve-Path -LiteralPath $PcapPath -ErrorAction Stop).Path
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
if ((Test-Path -LiteralPath $resolvedOutput) -and -not $Force) {
    throw "Refusing to overwrite annotation: $resolvedOutput"
}
if ($plan.schemaVersion -ne 1 -or $state.schemaVersion -ne 1) {
    throw 'Only capture plan and state schema 1 are supported.'
}
if ($state.status -notin @('Completed', 'TimedOut')) {
    throw "Capture state is not final: $($state.status)"
}
$selectedDeviceCount = if ([string]$state.captureMode -ceq 'DeviceAddresses') {
    @($state.deviceAddresses).Count
}
else {
    0
}

$annotation = [ordered]@{
    schemaVersion = 2
    evidenceProvenance = [ordered]@{
        controller = 'TODO: vendor application name and version'
        role = 'OracleCapture'
        openBladeTypedApplyPerformed = $false
        openBladeReadbackConfirmed = $false
    }
    capturedAtUtc = [string]$state.startedAtUtc
    device = [ordered]@{
        modelNumber = [string]$plan.device.modelNumber
        vendorIdHex = [string]$plan.device.vendorIdHex
        productIdHex = [string]$plan.device.productIdHex
        bios = [string]$plan.device.bios
        ec = $plan.device.ec
        mcu = $plan.device.mcu
    }
    capture = [ordered]@{
        sha256 = (Get-FileHash -LiteralPath $resolvedPcap -Algorithm SHA256).Hash
        byteLength = (Get-Item -LiteralPath $resolvedPcap).Length
        rawCaptureCommitted = $false
        captureMode = [string]$state.captureMode
        selectedDeviceCount = $selectedDeviceCount
        stopMode = [string]$state.stopMode
        forcedShutdownDataLossDisclosed = $false
        decodable = $null
    }
    action = [ordered]@{
        kind = if ($plan.scope.queryOnly -eq $true) {
            'ReadOnlyQuery'
        } else {
            'SettingChange'
        }
        subsystem = [string]$plan.scope.subsystem
        name = [string]$plan.scope.action
        value = [string]$plan.scope.value
        operatorConfirmed = $null
    }
    validation = [ordered]@{
        priorStateSaved = $null
        applyResult = [string]$plan.validation.apply
        readbackResult = [string]$plan.validation.readback
        restorationResult = [string]$plan.validation.restoration
        restorationReadbackResult = [string]$plan.validation.restorationReadback
    }
    sanitizedEvidence = @(
        [ordered]@{
            kind = 'TODO: bounded evidence kind'
            summary = 'TODO: what the sanitized evidence proves'
        }
    )
    limitations = @('TODO: state what this capture does not prove')
    notes = @()
}

[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($resolvedOutput)) | Out-Null
$temporary = "$resolvedOutput.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
$backup = "$resolvedOutput.$PID.$([Guid]::NewGuid().ToString('N')).bak"
try {
    [IO.File]::WriteAllText(
        $temporary,
        ($annotation | ConvertTo-Json -Depth 12),
        [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $resolvedOutput) {
        [IO.File]::Replace($temporary, $resolvedOutput, $backup, $true)
        Remove-Item -LiteralPath $backup -Force
    }
    else {
        [IO.File]::Move($temporary, $resolvedOutput)
    }
}
finally {
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Force
    }
    if (Test-Path -LiteralPath $backup) {
        Remove-Item -LiteralPath $backup -Force
    }
}
Get-Item -LiteralPath $resolvedOutput
