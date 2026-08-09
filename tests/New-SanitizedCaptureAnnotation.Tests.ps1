[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$generator = Join-Path $repository 'tools\New-SanitizedCaptureAnnotation.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('OpenBlade.SanitizedAnnotation.Tests.' + [Guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $planPath = Join-Path $testRoot 'capture-plan.json'
    $pcapPath = Join-Path $testRoot 'capture.pcapng'
    [IO.File]::WriteAllText(
        $planPath,
        (@{
            schemaVersion = 1
            device = @{
                modelNumber = 'RZ09-TEST'
                vendorIdHex = '1532'
                productIdHex = '0000'
                bios = '1.00'
                ec = $null
                mcu = $null
            }
            scope = @{
                queryOnly = $false
                subsystem = 'Test'
                action = 'Test annotation generation'
                value = 'One bounded test value'
            }
            validation = @{
                apply = 'Test apply'
                readback = 'Test readback'
                restoration = 'Test restoration'
                restorationReadback = 'Test restoration readback'
            }
        } | ConvertTo-Json -Depth 8),
        $utf8)
    [IO.File]::WriteAllBytes($pcapPath, [byte[]](1, 2, 3))

    $cases = @(
        @{
            Name = 'single'
            CaptureMode = 'DeviceAddress'
            DeviceAddresses = @(2)
            ExpectedCount = 0
        },
        @{
            Name = 'paired'
            CaptureMode = 'DeviceAddresses'
            DeviceAddresses = @(2, 5)
            ExpectedCount = 2
        },
        @{
            Name = 'all'
            CaptureMode = 'AllDevices'
            DeviceAddresses = @()
            ExpectedCount = 0
        }
    )

    foreach ($case in $cases) {
        $statePath = Join-Path $testRoot "$($case.Name)-state.json"
        $outputPath = Join-Path $testRoot "$($case.Name)-annotation.json"
        [IO.File]::WriteAllText(
            $statePath,
            (@{
                schemaVersion = 1
                status = 'Completed'
                startedAtUtc = '2026-08-09T00:00:00Z'
                captureMode = $case.CaptureMode
                deviceAddresses = @($case.DeviceAddresses)
                stopMode = 'Graceful'
            } | ConvertTo-Json -Depth 8),
            $utf8)

        $parameters = @{
            PlanPath = $planPath
            StatePath = $statePath
            PcapPath = $pcapPath
            OutputPath = $outputPath
        }
        & $generator @parameters | Out-Null
        $annotation = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

        Assert-True ($annotation.capture.selectedDeviceCount -eq $case.ExpectedCount) "$($case.Name) capture emitted selectedDeviceCount=$($annotation.capture.selectedDeviceCount); expected $($case.ExpectedCount)."
    }

    Write-Host 'Sanitized capture-annotation generator regression tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
        $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolvedTestRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean unexpected test path $resolvedTestRoot."
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
