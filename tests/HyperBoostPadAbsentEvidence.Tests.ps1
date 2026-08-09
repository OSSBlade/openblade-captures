[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$annotationPath = Join-Path $repository `
    'annotations\2026-08-09-rz09-0581-hyperboost-pad-absent-validation.json'
$validator = Join-Path $repository 'tools\Test-CaptureEvidence.ps1'
$annotation = Get-Content -LiteralPath $annotationPath -Raw | ConvertFrom-Json

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

& $validator -AnnotationPath $annotationPath -SchemaOnly | Out-Null

Assert-True ($annotation.evidenceProvenance.controller -ceq `
        'OpenBlade.Capture 0.5.0+7316548ca840ea07a7941d4b07b7b78f07fbdf75') `
    'The pad-absent validation lost its exact controller revision.'
Assert-True ($annotation.capture.sha256 -ceq `
        '68F5BCDFA47400DA9ACC427BAD875815F41BDF617D19A366B65781B3A87C7001' -and
    $annotation.capture.byteLength -eq 1336) `
    'The private semantic transcript identity changed unexpectedly.'

$preflight = @($annotation.sanitizedEvidence |
    Where-Object kind -ceq 'PadAbsentPreflight')
$safetyGate = @($annotation.sanitizedEvidence |
    Where-Object kind -ceq 'FinalPreApplySafetyGate')
$applyRestore = @($annotation.sanitizedEvidence |
    Where-Object kind -ceq 'ImmediateApplyReadbackAndRestoration')
$wrapper = @($annotation.sanitizedEvidence |
    Where-Object kind -ceq 'WrapperIntegrityAndCleanup')

Assert-True ($preflight.Count -eq 1 -and
    $preflight[0].firstAbsenceConfirmed -eq $true -and
    $preflight[0].secondAbsenceConfirmed -eq $true -and
    $preflight[0].baselineBalancedConfirmed -eq $true -and
    $preflight[0].fullPowerAdapterConfirmed -eq $true -and
    $preflight[0].interactiveApprovalConfirmed -eq $true -and
    $preflight[0].operatorConfirmedUsbAndExternalPowerDisconnected -eq $true) `
    'The pad-absent preflight evidence changed.'
Assert-True ($safetyGate.Count -eq 1 -and
    $safetyGate[0].preApplyAbsenceObservationCount -eq 3 -and
    $safetyGate[0].preApplyPadAbsenceConfirmed -eq $true -and
    $safetyGate[0].continuousAbsenceConfirmed -eq $false -and
    $safetyGate[0].postRestorationPadAbsenceConfirmed -eq $false) `
    'The final pre-apply pad-absence boundary changed.'
Assert-True ($applyRestore.Count -eq 1 -and
    $applyRestore[0].applyAcknowledged -eq $true -and
    $applyRestore[0].candidateConfirmed -eq $true -and
    $applyRestore[0].indeterminatePartialWrite -eq $false) `
    'The pad-absent paired mode-7 readback changed.'
Assert-True ($applyRestore[0].restoreAcknowledged -eq $true -and
    $applyRestore[0].restored -eq $true -and
    $applyRestore[0].manualRecoveryRequired -eq $false) `
    'The pad-absent Balanced restoration evidence changed.'
Assert-True ($wrapper.Count -eq 1 -and
    $wrapper[0].wrapperSha256 -ceq `
        'FDDDA6D4649A943812951F8F3E8523692B91DEC90A2B3B6C252E3C886F0EFBB3' -and
    $wrapper[0].wrapperByteLength -eq 2081 -and
    $wrapper[0].captureExecutableSha256 -ceq `
        '9F46A160FE90E14ADBE451BA23B2406BC3301836D85069E92FE301DF9A85BC84' -and
    $wrapper[0].validatorExitCode -eq 0 -and
    $wrapper[0].stderrEmpty -eq $true -and
    $wrapper[0].wrapperFailure -eq $false -and
    $wrapper[0].servicesRestored -eq $true) `
    'The elevated wrapper integrity or cleanup evidence changed.'

Assert-True ($annotation.productionAdmission.padLessImmediateTransitionObserved -eq $true -and
    $annotation.productionAdmission.padLessImmediateReversibleNoLoadValidationConfirmed -eq $true -and
    $annotation.productionAdmission.padLessActivationAdmitted -eq $false -and
    $annotation.productionAdmission.coolingPadRequired -eq $true -and
    $annotation.productionAdmission.coolingPadFanWriteAdmitted -eq $false) `
    'The no-load run widened the reviewed production boundary.'
Assert-True ((@($annotation.limitations) -join ' ') -match
    '(?i)sustained pad-less thermal safety remains unvalidated|does not establish.*thermally safe') `
    'The annotation no longer discloses the missing pad-less thermal validation.'

$raw = Get-Content -LiteralPath $annotationPath -Raw
Assert-True ($raw -notmatch '(?i)C:\\Users\\|devicePath|serialNumber|serialHex') `
    'The sanitized annotation contains a local path or device identity field.'

Write-Host 'HyperBoost pad-absent evidence tests passed.'
