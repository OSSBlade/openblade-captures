[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$validator = Join-Path $repository 'tools\Test-CaptureEvidence.ps1'
$generator = Join-Path $repository 'tools\New-SanitizedCaptureAnnotation.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('OpenBlade.CaptureEvidence.Tests.' + [Guid]::NewGuid().ToString('N'))

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Write-Json {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value
    )

    [IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth 20),
        [Text.UTF8Encoding]::new($false))
}

function New-ValidAnnotation {
    param(
        [Parameter(Mandatory)][string]$CaptureHash,
        [Parameter(Mandatory)][long]$CaptureLength
    )

    return [ordered]@{
        schemaVersion = 2
        evidenceProvenance = [ordered]@{
            controller = 'OpenBlade typed validation 1.0'
            role = 'ExactDeviceInteractiveValidation'
            openBladeTypedApplyPerformed = $true
            openBladeReadbackConfirmed = $true
        }
        capturedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        device = [ordered]@{
            modelNumber = 'RZ09-9999'
            vendorIdHex = '1532'
            productIdHex = 'FFFF'
            bios = '1.00'
            ec = $null
            mcu = $null
        }
        capture = [ordered]@{
            sha256 = $CaptureHash
            byteLength = $CaptureLength
            rawCaptureCommitted = $false
            captureMode = 'DeviceAddress'
            selectedDeviceCount = 0
            stopMode = 'Graceful'
            forcedShutdownDataLossDisclosed = $false
            decodable = $true
        }
        action = [ordered]@{
            kind = 'SettingChange'
            subsystem = 'Battery'
            name = 'Charge limit'
            value = '80 percent'
            operatorConfirmed = $true
        }
        validation = [ordered]@{
            priorStateSaved = $true
            applyResult = 'Applied successfully'
            readbackResult = 'Readback matched'
            restorationResult = 'Restored successfully'
            restorationReadbackResult = 'Restoration readback matched'
        }
        sanitizedEvidence = @(
            [ordered]@{
                kind = 'FeatureReportExchange'
                summary = 'One bounded request and response for the exact action'
                requestEnvelopeHex = '00010203'
                responseEnvelopeHex = '02010201'
            }
        )
        limitations = @(
            'This synthetic fixture proves only the schema validation behavior'
        )
        notes = @()
    }
}

function Assert-ValidationFails {
    param(
        [Parameter(Mandatory)][object]$Annotation,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ExpectedMessage,
        [Parameter(Mandatory)][string]$PcapPath
    )

    $path = Join-Path $testRoot "$Name.json"
    Write-Json -Path $path -Value $Annotation
    $failed = $false
    $message = ''
    try {
        & $validator -AnnotationPath $path -PcapPath $PcapPath | Out-Null
    }
    catch {
        $failed = $true
        $message = $_.Exception.Message
    }

    Assert-True $failed "$Name unexpectedly passed capture-evidence validation."
    Assert-True ($message -match $ExpectedMessage) `
        "$Name failed for the wrong reason: $message"
}

try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $pcapPath = Join-Path $testRoot 'synthetic-capture.bin'
    [IO.File]::WriteAllBytes($pcapPath, [byte[]](0..31))
    $captureHash = (Get-FileHash -LiteralPath $pcapPath -Algorithm SHA256).Hash
    $captureLength = (Get-Item -LiteralPath $pcapPath).Length

    $planPath = Join-Path $testRoot 'capture-plan.json'
    $statePath = Join-Path $testRoot 'capture-state.json'
    $generatedPath = Join-Path $testRoot 'generated-annotation.json'
    Write-Json -Path $planPath -Value ([ordered]@{
        schemaVersion = 1
        device = [ordered]@{
            modelNumber = 'RZ09-9999'
            vendorIdHex = '1532'
            productIdHex = 'FFFF'
            bios = '1.00'
            ec = $null
            mcu = $null
        }
        scope = [ordered]@{
            queryOnly = $true
            subsystem = 'Firmware'
            action = 'MCU version query'
            value = 'MCU version'
        }
        validation = [ordered]@{
            apply = 'Not performed'
            readback = 'Not performed'
            restoration = 'Not performed'
            restorationReadback = 'Not performed'
        }
    })
    Write-Json -Path $statePath -Value ([ordered]@{
        schemaVersion = 1
        status = 'Completed'
        startedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        captureMode = 'DeviceAddress'
        stopMode = 'Graceful'
    })
    & $generator -PlanPath $planPath -StatePath $statePath -PcapPath $pcapPath `
        -OutputPath $generatedPath | Out-Null
    $generated = Get-Content -LiteralPath $generatedPath -Raw | ConvertFrom-Json
    Assert-True ($generated.schemaVersion -eq 2) `
        'The annotation generator did not create schema 2.'
    Assert-True ($generated.action.kind -ceq 'ReadOnlyQuery') `
        'The annotation generator did not preserve query-only action semantics.'
    Assert-True (@($generated.sanitizedEvidence).Count -eq 1) `
        'The annotation generator did not create a bounded evidence placeholder.'
    $generatedFailed = $false
    try {
        & $validator -AnnotationPath $generatedPath -PcapPath $pcapPath | Out-Null
    }
    catch {
        $generatedFailed = $_.Exception.Message -match 'TODO|placeholder'
    }
    Assert-True $generatedFailed `
        'An unreviewed generated annotation unexpectedly passed the commit gate.'

    $validPath = Join-Path $testRoot 'valid.json'
    Write-Json -Path $validPath -Value (
        New-ValidAnnotation -CaptureHash $captureHash -CaptureLength $captureLength)

    $localResult = & $validator -AnnotationPath $validPath -PcapPath $pcapPath
    Assert-True $localResult.Valid 'A complete local annotation did not validate.'
    Assert-True $localResult.PcapHashVerified `
        'Local validation did not verify the capture hash and length.'
    Assert-True ($localResult.ValidationMode -ceq 'LocalCapture') `
        'Local validation reported the wrong mode.'

    $schemaResult = & $validator -AnnotationPath $validPath -SchemaOnly
    Assert-True $schemaResult.Valid 'A complete schema-only annotation did not validate.'
    Assert-True (-not $schemaResult.PcapHashVerified) `
        'Schema-only validation incorrectly claimed a PCAP hash match.'
    Assert-True ($schemaResult.ValidationMode -ceq 'SchemaOnly') `
        'Schema-only validation reported the wrong mode.'

    $missingModeFailed = $false
    try {
        & $validator -AnnotationPath $validPath | Out-Null
    }
    catch {
        $missingModeFailed = $true
    }
    Assert-True $missingModeFailed `
        'Validation silently skipped the explicit PCAP or schema-only mode.'

    $invalid = New-ValidAnnotation -CaptureHash $captureHash -CaptureLength $captureLength
    $invalid.capturedAtUtc = 'not-a-timestamp'
    Assert-ValidationFails $invalid 'invalid-timestamp' 'UTC ISO-8601' $pcapPath

    $invalid = New-ValidAnnotation -CaptureHash $captureHash -CaptureLength $captureLength
    $invalid.evidenceProvenance.role = 'Anything'
    Assert-ValidationFails $invalid 'invalid-role' 'role must be one of' $pcapPath

    $invalid = New-ValidAnnotation -CaptureHash $captureHash -CaptureLength $captureLength
    $invalid.evidenceProvenance.controller = 'Vendor controller'
    Assert-ValidationFails $invalid 'missing-controller-version' 'name and version' $pcapPath

    $invalid = New-ValidAnnotation -CaptureHash $captureHash -CaptureLength $captureLength
    $invalid.device.bios = ''
    Assert-ValidationFails $invalid 'missing-bios' 'device.bios' $pcapPath

    $invalid = New-ValidAnnotation -CaptureHash $captureHash -CaptureLength $captureLength
    $invalid.capture.captureMode = 'Anything'
    Assert-ValidationFails $invalid 'invalid-capture-mode' 'capture.captureMode' $pcapPath

    $paired = New-ValidAnnotation -CaptureHash $captureHash -CaptureLength $captureLength
    $paired.capture.captureMode = 'DeviceAddresses'
    $paired.capture.selectedDeviceCount = 2
    $paired.limitations = @(
        'Multi-device timing correlation is limited to the selected USB root'
    )
    $pairedPath = Join-Path $testRoot 'valid-paired.json'
    Write-Json -Path $pairedPath -Value $paired
    $pairedResult = & $validator -AnnotationPath $pairedPath -PcapPath $pcapPath
    Assert-True $pairedResult.Valid 'A valid paired-device annotation did not validate.'

    $invalid = New-ValidAnnotation -CaptureHash $captureHash -CaptureLength $captureLength
    $invalid.capture.captureMode = 'DeviceAddresses'
    $invalid.capture.selectedDeviceCount = 1
    $invalid.limitations = @('Multi-device correlation is synthetic')
    Assert-ValidationFails $invalid 'invalid-selected-device-count' `
        'selected-device count' $pcapPath

    $invalid = New-ValidAnnotation -CaptureHash $captureHash -CaptureLength $captureLength
    $invalid.capture.stopMode = 'Anything'
    Assert-ValidationFails $invalid 'invalid-stop-mode' 'capture.stopMode' $pcapPath

    $invalid = New-ValidAnnotation -CaptureHash $captureHash -CaptureLength $captureLength
    $invalid.action.value = ''
    Assert-ValidationFails $invalid 'missing-action-value' 'action.value' $pcapPath

    $invalid = New-ValidAnnotation -CaptureHash $captureHash -CaptureLength $captureLength
    $invalid.action.operatorConfirmed = 'true'
    Assert-ValidationFails $invalid 'non-boolean-confirmation' 'Operator confirmation' $pcapPath

    $invalid = New-ValidAnnotation -CaptureHash $captureHash -CaptureLength $captureLength
    $invalid.sanitizedEvidence = @()
    Assert-ValidationFails $invalid 'missing-evidence' 'sanitizedEvidence' $pcapPath

    $invalid = New-ValidAnnotation -CaptureHash $captureHash -CaptureLength $captureLength
    $invalid.validation.restorationReadbackResult = 'Not performed'
    Assert-ValidationFails $invalid 'missing-restoration' 'restorationReadbackResult' $pcapPath

    $invalid = New-ValidAnnotation -CaptureHash $captureHash -CaptureLength $captureLength
    $invalid.notes = @('Synthetic serial SN-EXAMPLE-123456789')
    Assert-ValidationFails $invalid 'serial-redaction' 'serial-like value' $pcapPath

    $invalid = New-ValidAnnotation -CaptureHash $captureHash -CaptureLength $captureLength
    $invalid.notes = @('Synthetic local path C:\Users\example\capture.bin')
    Assert-ValidationFails $invalid 'path-redaction' 'local filesystem path' $pcapPath

    $invalid = New-ValidAnnotation -CaptureHash $captureHash -CaptureLength $captureLength
    $invalid.notes = @('Synthetic UNC path \\server\share\capture.bin')
    Assert-ValidationFails $invalid 'unc-redaction' 'UNC filesystem path' $pcapPath

    $invalid = New-ValidAnnotation -CaptureHash $captureHash -CaptureLength $captureLength
    $invalid.sanitizedEvidence[0].requestEnvelopeHex = '0G'
    Assert-ValidationFails $invalid 'invalid-hex' 'requestEnvelopeHex' $pcapPath

    $invalid = New-ValidAnnotation -CaptureHash $captureHash -CaptureLength $captureLength
    $invalid.sanitizedEvidence[0].summary = ('bounded text ' * 1600)
    Assert-ValidationFails $invalid 'unbounded-evidence' '16 KiB' $pcapPath

    $invalid = New-ValidAnnotation -CaptureHash ('A' * 64) -CaptureLength $captureLength
    Assert-ValidationFails $invalid 'hash-mismatch' 'capture hash does not match' $pcapPath

    Write-Host 'Capture-evidence regression tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
        $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolvedTestRoot.StartsWith(
            $resolvedTempRoot,
            [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean unexpected test path $resolvedTestRoot."
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
