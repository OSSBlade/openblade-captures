[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$helperPath = Join-Path $repository 'tools\Invoke-HyperBoostTransportCapture.ps1'
$ignorePath = Join-Path $repository '.gitignore'
$source = Get-Content -LiteralPath $helperPath -Raw
$ignore = Get-Content -LiteralPath $ignorePath -Raw

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

Assert-True ($source.Contains("-cne 'Blade 16 - RZ09-0581'")) `
    'The HyperBoost capture helper lost its exact model gate.'
Assert-True ($source.Contains("-cne '4.00'")) `
    'The HyperBoost capture helper lost its exact BIOS gate.'
Assert-True ($source.Contains('-AllDevices')) `
    'The HyperBoost transport capture must include the complete USB root.'
Assert-True ($source.Contains("'/BackingFile', `$pmlPath")) `
    'The HyperBoost transport capture no longer retains a private Procmon PML.'
Assert-True ($source.Contains("'/Terminate'")) `
    'The HyperBoost transport capture no longer finalizes Procmon normally.'
Assert-True (-not $source.Contains('Stop-Process')) `
    'The helper must not force-terminate either capture process.'
Assert-True (-not $source.Contains('GenerateConsoleCtrlEvent')) `
    'The wrapper must delegate USBPcap shutdown to the reviewed targeted helper.'
Assert-True ($source.Contains("service.restarted -ne `$true")) `
    'The helper must verify that OpenBlade service ownership was restored.'
Assert-True ($ignore -match '(?m)^\*\.pml\r?$') `
    'Private Procmon PML files are not ignored.'

Write-Host 'HyperBoost transport-capture regression tests passed.'
