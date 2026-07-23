[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$tests = @(
    'Test-CaptureEvidence.Tests.ps1',
    'Compare-CaptureTransactions.Tests.ps1',
    'DeviceCoverageTemplate.Tests.ps1'
)

foreach ($test in $tests) {
    $path = Join-Path $PSScriptRoot $test
    Write-Host "Running $test"
    & $path
}

Write-Host 'All capture-toolkit regression tests passed.'
