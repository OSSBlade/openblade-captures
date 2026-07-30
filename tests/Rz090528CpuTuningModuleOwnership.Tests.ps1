$ErrorActionPreference = 'Stop'

$repository = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $repository (
    'tools\Get-Rz090528CpuTuningModuleOwnership.ps1')
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
    'The module-ownership inventory must parse in Windows PowerShell 5.1.'
Assert-True ($source -match 'WindowsBuiltInRole\]::Administrator') `
    'The module inventory must require an elevated token.'
Assert-True (
    $source -match [regex]::Escape(
        "Model -cne 'Blade 16 - RZ09-0528'") -and
    $source -match [regex]::Escape("SMBIOSBIOSVersion -cne '2.02'")) `
    'The module inventory must be gated to the exact host and BIOS.'
Assert-True ($source -match 'Get-AuthenticodeSignature') `
    'The module inventory must verify the Synapse executable signature.'
Assert-True ($source -match '\$process\.Modules') `
    'The module inventory must inspect loaded modules rather than infer ownership.'
foreach ($component in @(
        'RzAMDOverClock_v1.1.15.0.dll',
        'RzAMDOverClockDLL_v1.1.15.0.dll',
        'RzDLLService_v1.0.29.0.exe')) {
    Assert-True ($source -match [regex]::Escape($component)) `
        "The module inventory dropped exact component '$component'."
}
Assert-True (
    ([regex]::Matches($source, '[0-9A-F]{64}')).Count -eq 3) `
    'The module inventory must pin all three exact component hashes.'
Assert-True ($source -match '--razer-page-name=') `
    'The module inventory must correlate modules with a sanitized Synapse role.'
Assert-True ($source -match 'Get-FileHash\s+`?\s*-Algorithm SHA256') `
    'The module inventory must verify component and private-output hashes.'
Assert-True ($source -match 'ConvertTo-Json') `
    'The module inventory must emit structured private evidence.'
Assert-True (
    $source -match 'finished success=false error=' -and
    $source -match 'Set-Content -LiteralPath \$stateFile') `
    'The module inventory must preserve a private failure state.'
Assert-True ($source -match 'settingChanged = \$false') `
    'The module inventory must state its non-mutating boundary.'
Assert-True ($source -notmatch 'Stop-Process|Start-Process') `
    'The module inventory must not change process state.'
Assert-True ($source -notmatch 'Stop-Service|Start-Service') `
    'The module inventory must not change service state.'
Assert-True ($source -notmatch 'Serial|UUID|IdentifyingNumber') `
    'The module inventory must not collect unique device identifiers.'

Write-Host 'RZ09-0528 CPU tuning module-ownership tests passed.'
