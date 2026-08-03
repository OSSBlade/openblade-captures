[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$annotationPath = Join-Path $repository `
    'annotations\2026-07-29-rz09-0528-cpu-thermal-zone.json'
$coveragePath = Join-Path $repository `
    'decoded\rz09-0528-pid-02c6-bios-2.02-device-coverage.json'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$annotationRaw = Get-Content -LiteralPath $annotationPath -Raw
$annotation = $annotationRaw | ConvertFrom-Json
$coverage = Get-Content -LiteralPath $coveragePath -Raw | ConvertFrom-Json

Assert-True ($annotation.source.readOnly -eq $true) `
    'CPU thermal-zone discovery must remain read-only.'
Assert-True ($annotation.source.uniqueIdentifiersIncluded -eq $false) `
    'CPU thermal-zone evidence must not retain unique identifiers.'
Assert-True ($annotation.discovery.exactInstance -ceq '\_SB.PCI0.SBRG.EC0.TZRZ') `
    'The exact RZ09-0528 Razer EC thermal-zone instance changed.'
Assert-True ($annotation.discovery.olderModelInstanceRetained -ceq `
    '\_SB.PC00.LPCB.EC0.TZRZ') `
    'The older exact Razer EC path must remain an explicit candidate.'
Assert-True ($annotation.discovery.unrelatedInstanceRejected -ceq '\_TZ.TZ01') `
    'The unrelated Windows thermal zone must remain explicitly rejected.'
Assert-True ($annotation.discovery.rawTenthsKelvin -eq 3182) `
    'The sanitized high-precision thermal sample changed.'
Assert-True ($annotation.discovery.convertedCelsius -eq 45) `
    'The sanitized thermal conversion changed.'
Assert-True ($annotation.productionValidation.publishedCpuTemperatureCelsius -eq 45) `
    'Installed-service CPU temperature validation regressed.'
Assert-True ($annotation.productionValidation.trayDisplayedCpuTemperatureCelsius -eq 45) `
    'Tray CPU temperature validation regressed.'
Assert-True ($coverage.capabilities.sensors.cpuTemperature -ceq `
    'ProductionAdmitted') `
    'Exact CPU temperature coverage must remain production-admitted.'
Assert-True ($annotationRaw -notmatch 'HID#|DeviceInformation\.Id|BLADE-16-J') `
    'CPU thermal-zone evidence contains a local device identifier.'

Write-Host 'RZ09-0528 CPU thermal-zone evidence tests passed.'
