[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$annotationPath = Join-Path $repository (
    'annotations\2026-07-30-rz09-0528-cpu-tuning-driver-boundary.json')
$coveragePath = Join-Path $repository (
    'decoded\rz09-0528-pid-02c6-bios-2.02-device-coverage.json')

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$annotationText = Get-Content -Raw -LiteralPath $annotationPath
$annotation = $annotationText | ConvertFrom-Json
$coverage = Get-Content -Raw -LiteralPath $coveragePath | ConvertFrom-Json

Assert-True ($annotation.evidenceProvenance.nativeLibraryLoaded -eq $false) `
    'Static driver-boundary evidence must not load a vendor library.'
Assert-True ($annotation.evidenceProvenance.driverHandleOpened -eq $false) `
    'Static driver-boundary evidence must not open the kernel driver.'
Assert-True ($annotation.evidenceProvenance.ioctlInvoked -eq $false) `
    'Static driver-boundary evidence must not invoke an IOCTL.'
Assert-True ($annotation.evidenceProvenance.settingChanged -eq $false) `
    'Static driver-boundary evidence must not claim a setting change.'
Assert-True ($annotation.driverBoundary.serviceName -ceq
    'AMDRyzenMasterDriverV31') 'The exact driver service name changed.'
Assert-True ($annotation.driverBoundary.serviceType -ceq 'Kernel Driver') `
    'The tuning dependency must remain identified as a kernel driver.'
Assert-True ($annotation.driverBoundary.startMode -ceq 'Manual') `
    'The observed driver start mode changed.'
Assert-True ($annotation.driverBoundary.infDriverVersion -ceq '3.1.0.0') `
    'The exact inspected driver version changed.'
Assert-True ($annotation.driverBoundary.deviceName -ceq
    '\\.\AMDRyzenMasterDriverV31') 'The exact driver device name changed.'

$expectedHashes = @{
    'AMDRyzenMasterDriver.sys' =
        '7250DDCB9B04E7E00694C9D5AE3AA2B37CAAE367A4125BB84D8AC0B0DFAB8624'
    'Device.dll' =
        '70B5A3B1B2E6CFA42ECF791A8FE008453F5B5BB521EC9F228DFDBF6739C978D5'
    'Platform.dll' =
        '61584FE630DF8E819A324013B3F1C8178364E608B73A13DFF0827743BC26B5DF'
}
Assert-True (@($annotation.driverBoundary.components).Count -eq 3) `
    'The exact driver-boundary component inventory changed.'
foreach ($component in $annotation.driverBoundary.components) {
    Assert-True ($expectedHashes.ContainsKey([string]$component.fileName)) `
        "Unexpected driver-boundary component '$($component.fileName)'."
    Assert-True ($component.sha256 -ceq
        $expectedHashes[[string]$component.fileName]) `
        "Hash changed for '$($component.fileName)'."
    Assert-True ($component.signatureStatus -ceq 'Valid') `
        "Signature status changed for '$($component.fileName)'."
    Assert-True ($component.signerOrganization -ceq
        'Advanced Micro Devices') `
        "Signer changed for '$($component.fileName)'."
}

Assert-True ((@($annotation.driverBoundary.unmappedIoctlCandidates) -join ',') `
    -ceq '0x81112F24,0x81112FF8') `
    'Unmapped IOCTL candidates changed or were silently assigned semantics.'
Assert-True ($annotation.admission.advancedByThisInspection -eq $false) `
    'Static driver-boundary discovery must not advance production admission.'
Assert-True ($annotation.admission.productionAccess -ceq 'ObservedOnly') `
    'CPU tuning must remain ObservedOnly at this boundary.'
Assert-True ($coverage.capabilities.performance.ac.cpuPowerLimitWatts -ceq
    'Captured') 'CPU Power Limit coverage must remain Captured.'
Assert-True ($coverage.capabilities.performance.ac.cpuVoltageOptimizer -ceq
    'Captured') 'CPU Voltage Optimizer coverage must remain Captured.'

foreach ($forbidden in @(
        'C:\Users\',
        'C:\Program Files\',
        'S-1-5-',
        'VID_1532&PID_02C6\')) {
    Assert-True (-not $annotationText.Contains($forbidden)) `
        "Sanitized annotation contains forbidden local identifier '$forbidden'."
}

Write-Host 'RZ09-0528 CPU tuning driver-boundary evidence tests passed.'
