$ErrorActionPreference = 'Stop'

$repository = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $repository (
    'tools\Invoke-Rz090528PowerSourceReadbackMatrix.ps1')
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
    'The power-source matrix wrapper must parse in Windows PowerShell 5.1.'
Assert-True (
    $source -match [regex]::Escape(
        "Model -cne 'Blade 16 - RZ09-0528'") -and
    $source -match [regex]::Escape("SMBIOSBIOSVersion -cne '2.02'")) `
    'The power-source matrix must be gated to the exact host and BIOS.'
Assert-True (
    $source -match 'query-rz09-0528-02c6-power-source') `
    'The matrix must use the exact read-only production query.'
Assert-True (
    $source -match '\$sample -le 3') `
    'The matrix must take three samples per physical state.'
foreach ($confirmation in @(
        'AC-BASELINE',
        'BATTERY',
        'USBC',
        'AC-RESTORED')) {
    Assert-True ($source -match [regex]::Escape($confirmation)) `
        "The matrix dropped operator confirmation '$confirmation'."
}
Assert-True (
    $source -match "ExpectedPowerLineStatus 'Offline'" -and
    ([regex]::Matches(
        $source,
        "ExpectedPowerLineStatus 'Online'")).Count -eq 3) `
    'The matrix must distinguish unplugged battery from USB-C and barrel AC.'
Assert-True (
    $source -match [regex]::Escape(
        'Do not capture while between plugs.')) `
    'The matrix must reject the operator transition interval.'
Assert-True (
    ([regex]::Matches(
        $source,
        "ExpectedAdapterPayload '1111'")).Count -eq 2) `
    'Both full-AC endpoints must require the admitted 1111 payload.'
Assert-True (
    $source -match 'The three read-only responses were not identical') `
    'Every state must require three identical query responses.'
Assert-True (
    $source -match 'physicalStateRestored = \$true') `
    'The successful summary must require restored barrel AC.'
Assert-True (
    $source -match '\[Security\.Cryptography\.SHA256\]::Create\(\)' -and
    $source -notmatch 'Get-FileHash') `
    'The matrix must use its PowerShell 5.1-safe in-process SHA-256 helper.'
Assert-True (
    $source -match 'settingChanged = \$false') `
    'The matrix must state that it never changes a setting.'
Assert-True ($source -notmatch 'Stop-Process|Start-Process') `
    'The read-only matrix must not change process state.'
Assert-True ($source -notmatch 'Stop-Service|Start-Service') `
    'The read-only matrix must not change service state.'
Assert-True ($source -notmatch 'Serial|UUID|IdentifyingNumber') `
    'The matrix must not collect unique device identifiers.'

Write-Host 'RZ09-0528 power-source readback matrix wrapper tests passed.'
