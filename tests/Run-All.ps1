[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$tests = @(Get-ChildItem -LiteralPath $PSScriptRoot `
    -Filter '*.Tests.ps1' -File |
    Sort-Object Name)

foreach ($test in $tests) {
    Write-Host "Running $($test.Name)"
    & $test.FullName
}

Write-Host 'All capture-toolkit regression tests passed.'
