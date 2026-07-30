$ErrorActionPreference = 'Stop'

$repository = Split-Path $PSScriptRoot -Parent
$annotationPath = Join-Path $repository (
    'annotations\2026-07-30-rz09-0528-cpu-tuning-preconnect-lifecycle-negative.json')
$coveragePath = Join-Path $repository (
    'decoded\rz09-0528-pid-02c6-bios-2.02-device-coverage.json')
$indexPath = Join-Path $repository (
    'decoded\rz09-0528-pid-02c6-bios-2.02-evidence.json')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

$annotation = Get-Content -Raw -LiteralPath $annotationPath | ConvertFrom-Json
$coverage = Get-Content -Raw -LiteralPath $coveragePath | ConvertFrom-Json
$index = Get-Content -Raw -LiteralPath $indexPath | ConvertFrom-Json

Assert-True ($annotation.device.modelNumber -ceq 'RZ09-0528') `
    'CPU lifecycle evidence model changed.'
Assert-True ($annotation.device.productIdHex -ceq '02C6') `
    'CPU lifecycle evidence PID changed.'
Assert-True ($annotation.evidenceProvenance.settingChanged -eq $false) `
    'The getter-only lifecycle run must not imply a setting change.'
Assert-True ($annotation.evidenceProvenance.setterExportBound -eq $false) `
    'The getter-only lifecycle run must not bind a setter.'
Assert-True ($annotation.evidenceProvenance.setterExportInvoked -eq $false) `
    'The getter-only lifecycle run must not invoke a setter.'
foreach ($guard in @(
        'exactHostVerified',
        'synapseInstallationPathVerified',
        'synapseRazerSignatureVerified',
        'clientRegisteredWhileSynapseLive',
        'readyHandshakeReceived',
        'onlyPreverifiedSynapseProcessIdsStopped',
        'synapseInactiveBeforeGetter')) {
    Assert-True ($annotation.isolation.$guard -eq $true) `
        "CPU lifecycle isolation guard '$guard' must remain true."
}
Assert-True ($annotation.isolation.serviceStopped -eq $false) `
    'The CPU lifecycle validator must not stop a service.'
Assert-True ($annotation.validation.powerLimitGetterAccepted -eq $true) `
    'The accepted power-limit getter request must remain recorded.'
Assert-True ($annotation.validation.powerLimitCallbackReceived -eq $false) `
    'The missing power-limit callback must not be represented as readback.'
Assert-True ($annotation.validation.curveOptimizerGetterIssued -eq $false) `
    'The unreached curve-optimizer getter must remain explicit.'
Assert-True ($annotation.validation.success -eq $false) `
    'The lifecycle negative control must not be represented as successful.'
Assert-True (
    $annotation.validation.classification -ceq (
        'PreconnectedIsolatedGetterCallbackTimeoutRestored')) `
    'The CPU lifecycle failure classification changed.'
Assert-True (
    $annotation.externalRestoration.synapseRelaunchedFromVerifiedPath -eq
        $true) `
    'Verified Synapse restoration must remain recorded.'
Assert-True ($annotation.externalRestoration.adapterReplyHex -ceq '1111') `
    'Post-run barrel-AC readback changed.'
Assert-True (
    $annotation.externalRestoration.keyboardBrightnessRaw -eq 129) `
    'Post-run keyboard-brightness readback changed.'

foreach ($evidence in @(
        $annotation.privateEvidence.validationOutput,
        $annotation.privateEvidence.validationError,
        $annotation.privateEvidence.wrapperState)) {
    Assert-True ($evidence.sha256 -match '^[0-9A-F]{64}$') `
        'A private CPU lifecycle evidence hash is malformed.'
    Assert-True ($evidence.byteLength -gt 0) `
        'A private CPU lifecycle evidence length is missing.'
}
Assert-True ($annotation.privateEvidence.committed -eq $false) `
    'Private CPU lifecycle outputs must remain uncommitted.'
Assert-True ($annotation.admission.cpuPowerLimit -ceq 'Captured') `
    'The failed getter must not advance CPU Power Limit admission.'
Assert-True ($annotation.admission.cpuVoltageOptimizer -ceq 'Captured') `
    'The unreached optimizer getter must not advance admission.'
Assert-True ($annotation.admission.productionAccess -ceq 'ObservedOnly') `
    'CPU tuning access must remain observed-only.'
Assert-True (
    $coverage.capabilities.performance.ac.cpuPowerLimitWatts -ceq 'Captured') `
    'CPU Power Limit coverage must remain Captured.'
Assert-True (
    $coverage.capabilities.performance.ac.cpuVoltageOptimizer -ceq 'Captured') `
    'CPU Voltage Optimizer coverage must remain Captured.'
Assert-True (
    @($index.annotations) -contains (
        '2026-07-30-rz09-0528-cpu-tuning-preconnect-lifecycle-negative.json')) `
    'The CPU lifecycle negative control must remain in the evidence index.'
Assert-True ($annotation.privacy.rawOutputsCommitted -eq $false) `
    'Raw CPU lifecycle output must remain private.'
Assert-True ($annotation.privacy.uniqueIdentifiersRetained -eq $false) `
    'Sanitized CPU lifecycle evidence must not retain unique identifiers.'

Write-Host 'RZ09-0528 CPU tuning lifecycle evidence tests passed.'
