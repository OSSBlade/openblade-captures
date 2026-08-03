$ErrorActionPreference = 'Stop'

$repository = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $repository (
    'tools\Invoke-Rz090528CpuTuningLifecycleValidation.ps1')
$source = Get-Content -Raw -LiteralPath $scriptPath

function Assert-True {
    param([bool]$Condition, [string]$Message)
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
    'The CPU lifecycle wrapper must parse in Windows PowerShell 5.1.'
Assert-True ($source -match 'WindowsBuiltInRole\]::Administrator') `
    'The CPU lifecycle wrapper must require an elevated token.'
Assert-True (
    $source -match [regex]::Escape(
        'query-rz09-0528-02c6-cpu-power-service-preconnected')) `
    'The wrapper must use the bounded preconnected CPU query.'
Assert-True ($source -match 'EventWaitHandle') `
    'The wrapper must coordinate isolation only after the client preconnects.'
Assert-True ($source -match 'readyEvent\.WaitOne') `
    'The wrapper must wait for the client preconnection signal.'
Assert-True ($source -match 'isolatedEvent\.Set') `
    'The wrapper must signal isolation before any getter runs.'
Assert-True ($source -match 'Get-AuthenticodeSignature') `
    'The wrapper must verify the Synapse executable signature.'
Assert-True ($source -match 'Stop-Process -Id \$synapseProcessIds') `
    'The wrapper must stop only the preverified Synapse process IDs.'
Assert-True ($source -notmatch 'Stop-Process\s+-Name') `
    'The wrapper must not stop an unverified process by name.'
Assert-True ($source -notmatch 'Stop-Service') `
    'The getter-only CPU lifecycle probe must not stop unrelated services.'
Assert-True ($source -match 'finally\s*\{') `
    'The wrapper must restore external state from a finally block.'
Assert-True ($source -match 'Start-Process') `
    'The wrapper must relaunch Synapse when it started as running.'
Assert-True ($source -match 'Get-FileHash -Algorithm SHA256') `
    'The wrapper must hash its private outputs.'
Assert-True (
    $source -match 'exit 3' -and
    $source -match 'restoration-failed') `
    'Restoration failure must override a successful getter.'

Write-Host 'RZ09-0528 CPU tuning lifecycle wrapper tests passed.'
