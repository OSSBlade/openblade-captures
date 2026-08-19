[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$validator = Join-Path $repository 'tools\Test-CaptureEvidence.ps1'
$paths = [ordered]@{
    Immediate = 'annotations\2026-08-19-rz09-0581-hyperboost-padless-immediate.json'
    NoLoad = 'annotations\2026-08-19-rz09-0581-hyperboost-padless-sustained-no-load.json'
    Load = 'annotations\2026-08-19-rz09-0581-hyperboost-padless-steel-nomad.json'
    Adapter = 'annotations\2026-08-19-rz09-0581-hyperboost-padless-adapter-transition.json'
    LowPowerNegative = 'annotations\2026-08-19-rz09-0581-hyperboost-padless-low-power-negative.json'
    LowPower = 'annotations\2026-08-19-rz09-0581-hyperboost-padless-low-power-recovery.json'
    Crash = 'annotations\2026-08-19-rz09-0581-hyperboost-padless-crash-recovery.json'
}

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$evidence = @{}
foreach ($entry in $paths.GetEnumerator()) {
    $path = Join-Path $repository $entry.Value
    & $validator -AnnotationPath $path -SchemaOnly | Out-Null
    $evidence[$entry.Key] = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

$immediate = $evidence.Immediate
Assert-True ($immediate.evidenceProvenance.controller -ceq `
        'OpenBlade.Capture 0.17.0+0f56b0c1ef6049430848e191249cbaaae3d2ef14') `
    'The immediate run lost its exact controller revision.'
Assert-True ($immediate.productionAdmission.padLessImmediateApplyReadbackRestoreValidated -eq $true -and
    $immediate.productionAdmission.postRestorationAbsenceValidated -eq $true -and
    $immediate.productionAdmission.padLessActivationAdmitted -eq $false) `
    'The immediate validation boundary changed.'

$noLoad = $evidence.NoLoad
$noLoadObservation = @($noLoad.sanitizedEvidence |
    Where-Object kind -ceq 'ContinuousSafetyObservation')
Assert-True ($noLoadObservation.Count -eq 1 -and
    $noLoadObservation[0].continuousPadAbsenceConfirmed -eq $true -and
    $noLoadObservation[0].fullPowerAdapterMaintained -eq $true -and
    $noLoadObservation[0].hyperBoostStateMaintained -eq $true -and
    $noLoadObservation[0].requiredSensorsMaintained -eq $true -and
    $noLoadObservation[0].gpuPositivelyInactive -eq $true -and
    $noLoad.productionAdmission.sustainedNoLoadExecutionValidated -eq $true -and
    $noLoad.productionAdmission.padLessActivationAdmitted -eq $false) `
    'The sustained no-load evidence changed.'

$load = $evidence.Load
$workload = @($load.sanitizedEvidence |
    Where-Object kind -ceq 'ReviewedExternalWorkload')
$loadObservation = @($load.sanitizedEvidence |
    Where-Object kind -ceq 'SustainedSafetyObservation')
Assert-True ($load.evidenceProvenance.controller -ceq `
        'OpenBlade.Capture 0.17.0+18bd0017ce315c6801cff79cc7b2b1160d76d570' -and
    $workload.Count -eq 1 -and
    $workload[0].workloadName -ceq '3DMarkSteelNomad.exe' -and
    $workload[0].workloadSha256 -ceq `
        '8C690B613734D680268727B9A73475709593D606125C2B73234171C5BB3D312E' -and
    $workload[0].externalWorkloadMaintained -eq $true) `
    'The reviewed external workload binding changed.'
Assert-True ($loadObservation.Count -eq 1 -and
    $loadObservation[0].completedSampleCount -eq 30 -and
    $loadObservation[0].gpuMaximumCelsius -eq 83 -and
    $loadObservation[0].gpuLimitCelsius -eq 85 -and
    $loadObservation[0].fan1MinimumRpm -eq 4200 -and
    $loadObservation[0].fan2MinimumRpm -eq 4000 -and
    $load.productionAdmission.reviewedLoadValidated -eq $true -and
    $load.productionAdmission.padLessActivationAdmitted -eq $false) `
    'The reviewed-load safety evidence changed.'

$adapter = $evidence.Adapter
$transition = @($adapter.sanitizedEvidence |
    Where-Object kind -ceq 'TypedAdapterTransition')
$absence = @($adapter.sanitizedEvidence |
    Where-Object kind -ceq 'PadAbsenceAndRestoration')
Assert-True ($transition.Count -eq 1 -and
    $transition[0].initialAdapterState -ceq 'fullPower330W' -and
    $transition[0].observedAdapterState -ceq 'usbCPower100W' -and
    $transition[0].reviewedAdapterTransitionConfirmed -eq $true -and
    $absence.Count -eq 1 -and
    $absence[0].transitionTimePadAbsenceConfirmed -eq $true -and
    $absence[0].postRestorationPadAbsenceConfirmed -eq $true -and
    $adapter.productionAdmission.adapterTransitionValidated -eq $true -and
    $adapter.productionAdmission.padLessActivationAdmitted -eq $false) `
    'The reviewed adapter-transition evidence changed.'

$lowPowerNegative = $evidence.LowPowerNegative
$lowPowerBoundary = @($lowPowerNegative.sanitizedEvidence |
    Where-Object kind -ceq 'LowPowerBoundaryNegative')
$lowPowerCleanup = @($lowPowerNegative.sanitizedEvidence |
    Where-Object kind -ceq 'SeparateSafeCleanup')
Assert-True ($lowPowerNegative.evidenceProvenance.role -ceq 'NegativeCapture' -and
    $lowPowerBoundary.Count -eq 1 -and
    $lowPowerBoundary[0].recoveryAttemptsObserved -eq 0 -and
    $lowPowerBoundary[0].recoveryCompletionsObserved -eq 0 -and
    $lowPowerBoundary[0].lowPowerLifecycleValidated -eq $false -and
    $lowPowerCleanup.Count -eq 1 -and
    $lowPowerCleanup[0].cleanupAttemptCount -eq 1 -and
    $lowPowerCleanup[0].balancedAndAutomaticConfirmed -eq $true -and
    $lowPowerNegative.productionAdmission.lowPowerLifecycleValidated -eq $false -and
    $lowPowerNegative.productionAdmission.padLessActivationAdmitted -eq $false) `
    'The installed low-power negative evidence changed.'

$lowPower = $evidence.LowPower
$lowPowerArm = @($lowPower.sanitizedEvidence |
    Where-Object kind -ceq 'OwnedLifecycleArm')
$modernStandby = @($lowPower.sanitizedEvidence |
    Where-Object kind -ceq 'ObservedModernStandbyBoundary')
$lowPowerRecovery = @($lowPower.sanitizedEvidence |
    Where-Object kind -ceq 'InstalledRecoveryVerification')
Assert-True ($lowPower.evidenceProvenance.controller -ceq `
        'OpenBlade installed Service 0.17.0+f52440583dbdf7f20bca0564cb37e01603f68d4e verified by OpenBlade.FirmwareSmoke 0.17.0+f52440583dbdf7f20bca0564cb37e01603f68d4e' -and
    $lowPowerArm.Count -eq 1 -and
    $lowPowerArm[0].hyperBoostConfirmed -eq $true -and
    $lowPowerArm[0].durableOwnershipConfirmed -eq $true -and
    $modernStandby.Count -eq 1 -and
    $modernStandby[0].entryEventId -eq 506 -and
    $modernStandby[0].exitEventId -eq 507 -and
    $modernStandby[0].orderedEntryAndExitConfirmed -eq $true -and
    $lowPowerRecovery.Count -eq 1 -and
    $lowPowerRecovery[0].exactInstalledGeneration -eq $true -and
    $lowPowerRecovery[0].expectedServiceBoundary -eq $true -and
    $lowPowerRecovery[0].exactBaseAndAutomaticConfirmed -eq $true -and
    $lowPowerRecovery[0].journalRetired -eq $true -and
    $lowPowerRecovery[0].recoveryAttemptsObserved -eq 1 -and
    $lowPowerRecovery[0].recoveryCompletionsObserved -eq 1 -and
    $lowPowerRecovery[0].stableSecondObservation -eq $true -and
    $lowPower.productionAdmission.lowPowerLifecycleValidated -eq $true -and
    $lowPower.productionAdmission.padLessActivationAdmitted -eq $true) `
    'The installed low-power recovery evidence changed.'

$crash = $evidence.Crash
$crashBoundary = @($crash.sanitizedEvidence |
    Where-Object kind -ceq 'ExactUnexpectedExitBoundary')
$crashRecovery = @($crash.sanitizedEvidence |
    Where-Object kind -ceq 'InstalledRecoveryVerification')
$verifierCorrection = @($crash.sanitizedEvidence |
    Where-Object kind -ceq 'VerifierCorrection')
Assert-True ($crashBoundary.Count -eq 1 -and
    $crashBoundary[0].oldServiceExited -eq $true -and
    $crashBoundary[0].serviceInstanceReplaced -eq $true -and
    $crashRecovery.Count -eq 1 -and
    $crashRecovery[0].exactInstalledGeneration -eq $true -and
    $crashRecovery[0].exactBaseAndAutomaticConfirmed -eq $true -and
    $crashRecovery[0].journalRetired -eq $true -and
    $crashRecovery[0].recoveryAttemptsObserved -eq 1 -and
    $crashRecovery[0].recoveryCompletionsObserved -eq 1 -and
    $crashRecovery[0].stableSecondObservation -eq $true -and
    $verifierCorrection.Count -eq 1 -and
    $verifierCorrection[0].additionalHyperBoostWriteCount -eq 0 -and
    $crash.productionAdmission.crashRecoveryValidated -eq $true -and
    $crash.productionAdmission.lowPowerLifecycleValidated -eq $false -and
    $crash.productionAdmission.padLessActivationAdmitted -eq $false) `
    'The installed unexpected-exit recovery evidence changed.'

foreach ($entry in $paths.GetEnumerator()) {
    $raw = Get-Content -LiteralPath (Join-Path $repository $entry.Value) -Raw
    Assert-True ($raw -notmatch `
            '(?i)C:\\Users\\|devicePath|serialNumber|serialHex|processId|userName|machineName') `
        "$($entry.Key) evidence contains a local identity or path."
}

Write-Host 'HyperBoost padless validation evidence tests passed.'
