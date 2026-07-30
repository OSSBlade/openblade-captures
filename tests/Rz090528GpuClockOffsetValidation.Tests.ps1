$ErrorActionPreference = 'Stop'

$repository = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $repository (
    'tools\Invoke-Rz090528GpuClockOffsetValidation.ps1')
$source = Get-Content -Raw -LiteralPath $scriptPath

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$errors)
Assert-True ($errors.Count -eq 0) `
    'The GPU validation wrapper must parse in Windows PowerShell 5.1.'
Assert-True ($source -match 'WindowsBuiltInRole\]::Administrator') `
    'The GPU validation wrapper must require an elevated token.'
Assert-True (
    $source -match [regex]::Escape(
        'RZ09-0528:1532:02C6:GPU-OFFSETS:RESTORE')) `
    'The wrapper must pass the exact GPU validation confirmation.'
foreach ($service in @(
        'OpenBlade',
        'Razer Elevation Service',
        'Razer Game Manager Service 3')) {
    Assert-True ($source -match [regex]::Escape($service)) `
        "The wrapper must isolate and restore '$service'."
}
Assert-True ($source -match 'Assert-ServicePath') `
    'The wrapper must verify every service executable before stopping it.'
Assert-True ($source -match 'Get-AuthenticodeSignature') `
    'The wrapper must verify the Synapse executable signature.'
Assert-True ($source -match 'Stop-Process -Id \$synapseProcessIds') `
    'The wrapper must stop only the preverified Synapse process IDs.'
Assert-True ($source -notmatch 'Stop-Process\s+-Name') `
    'The wrapper must not stop an unverified process by name.'
Assert-True ($source -match 'finally\s*\{') `
    'The wrapper must restore external state from a finally block.'
Assert-True ($source -match 'Start-Service -Name \$name') `
    'The wrapper must restore every service that started as running.'
Assert-True ($source -match 'Start-Process') `
    'The wrapper must relaunch Synapse when it started as running.'
Assert-True ($source -match 'Get-FileHash -Algorithm SHA256') `
    'The wrapper must hash the private validation output.'
Assert-True (
    $source -match 'exit 3' -and
    $source -match 'restoration-failed') `
    'External-state restoration failure must override validation success.'

Write-Host 'RZ09-0528 GPU clock-offset validation wrapper tests passed.'
