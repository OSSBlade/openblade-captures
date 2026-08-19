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

foreach ($entry in $paths.GetEnumerator()) {
    $raw = Get-Content -LiteralPath (Join-Path $repository $entry.Value) -Raw
    Assert-True ($raw -notmatch `
            '(?i)C:\\Users\\|devicePath|serialNumber|serialHex|processId|userName|machineName') `
        "$($entry.Key) evidence contains a local identity or path."
}

Write-Host 'HyperBoost padless validation evidence tests passed.'
