[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$templatePath = Join-Path $repository 'templates\device-coverage.template.json'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-JsonPathValue {
    param(
        [Parameter(Mandatory)][object]$Root,
        [Parameter(Mandatory)][string]$Path
    )

    $value = $Root
    foreach ($segment in $Path -split '\.') {
        $property = $value.PSObject.Properties[$segment]
        if ($null -eq $property) {
            return $null
        }
        $value = $property.Value
    }
    return $value
}

function Get-LeafStatuses {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path
    )

    foreach ($property in $Value.PSObject.Properties) {
        $propertyPath = if ([string]::IsNullOrWhiteSpace($Path)) {
            $property.Name
        } else {
            "$Path.$($property.Name)"
        }
        if ($property.Value -is [pscustomobject]) {
            Get-LeafStatuses -Value $property.Value -Path $propertyPath
        }
        else {
            [pscustomobject]@{
                Path = $propertyPath
                Status = [string]$property.Value
            }
        }
    }
}

$template = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json
Assert-True ($template.schemaVersion -eq 2) `
    'The exhaustive coverage template must use schema version 2.'
Assert-True ($template.device.modelNumber -ceq 'RZ09-XXXX') `
    'The coverage template lost its unsupported-model placeholder.'

$requiredPaths = @(
    'identityAndFirmware.usbDescriptors',
    'identityAndFirmware.biosVersion',
    'identityAndFirmware.ecVersion',
    'identityAndFirmware.mcuVersion',
    'performance.ac.presets',
    'performance.ac.customCpuLevels',
    'performance.usbC.powerClasses',
    'performance.usbC.presetsByPowerClass',
    'performance.battery.presets',
    'fans.fixedMinimum',
    'fans.fixedMaximum',
    'fans.fixedStep',
    'fans.manualCurveWrites',
    'fans.rpmQuery',
    'sensors.cpuTemperature',
    'battery.protectionOff',
    'battery.advertisedLimits',
    'battery.temporaryFullChargeQuery',
    'keyboardLighting.off',
    'keyboardLighting.brightnessRange',
    'keyboardLighting.effectGetter',
    'keyboardLighting.matrixInterfaceDiscovery',
    'keyboardLighting.lampArrayInterfaceDiscovery',
    'keyboardLighting.effects.ambientAwareness.screenRegions',
    'keyboardLighting.effects.ambientAwareness.frameCadence',
    'keyboardLighting.effects.breathing.singleColor',
    'keyboardLighting.effects.breathing.dualColor',
    'keyboardLighting.effects.breathing.randomColor',
    'keyboardLighting.effects.breathing.durations',
    'keyboardLighting.effects.reactive.colors',
    'keyboardLighting.effects.reactive.durations',
    'keyboardLighting.effects.reactive.keyMap',
    'keyboardLighting.effects.ripple.colors',
    'keyboardLighting.effects.ripple.keyMap',
    'keyboardLighting.effects.starlight.singleColor',
    'keyboardLighting.effects.starlight.dualColor',
    'keyboardLighting.effects.starlight.randomColor',
    'keyboardLighting.effects.starlight.durations',
    'keyboardLighting.effects.static.colors',
    'keyboardLighting.effects.tidal.primaryColor',
    'keyboardLighting.effects.tidal.secondaryColor',
    'keyboardLighting.effects.tidal.randomColor',
    'keyboardLighting.effects.tidal.inwardDirection',
    'keyboardLighting.effects.tidal.outwardDirection',
    'keyboardLighting.effects.wave.leftDirection',
    'keyboardLighting.effects.wave.rightDirection',
    'keyboardLighting.effects.wheel.leftDirection',
    'keyboardLighting.effects.wheel.rightDirection',
    'logoLighting.getter',
    'keyboardBehavior.functionKeyPrimaryGetter',
    'keyboardBehavior.gamingModeGetter',
    'keyboardBehavior.startupAnimationGetter',
    'keyboardBehavior.normalDeviceMode',
    'keyboardBehavior.driverDeviceMode',
    'specialKeys.functionLayerReports',
    'specialKeys.performanceKey',
    'specialKeys.m1PageUp',
    'specialKeys.m5MicrophoneMute',
    'display.windowsVisibleModes',
    'display.dynamicRefreshRate',
    'display.hdr',
    'display.colorProfilesSdr',
    'display.colorProfilesHdr',
    'lifecycle.coldBoot',
    'lifecycle.sleepResume',
    'lifecycle.deviceReconnect',
    'power.fullAc',
    'power.usbCPowerClasses',
    'power.battery',
    'power.acToUsbC',
    'power.usbCToBattery',
    'power.batteryToUsbC',
    'conflicts.defaultZeroWritePolicy',
    'conflicts.explicitReclaim',
    'failures.timeout',
    'failures.malformedResponse',
    'failures.checksumMismatch',
    'failures.transactionMismatch',
    'failures.commandClassMismatch',
    'failures.commandIdMismatch',
    'failures.statusFailure',
    'failures.unsupportedPid',
    'failures.unsupportedFirmware',
    'failures.disconnectMidTransaction'
)

foreach ($path in $requiredPaths) {
    $value = Get-JsonPathValue -Root $template.capabilities -Path $path
    Assert-True ($null -ne $value) "Coverage template is missing $path."
}

$allowedStatuses = @($template.statusValues)
$leafStatuses = @(Get-LeafStatuses -Value $template.capabilities -Path '')
Assert-True ($leafStatuses.Count -ge 100) `
    "Coverage template is unexpectedly coarse: only $($leafStatuses.Count) leaves."
foreach ($leaf in $leafStatuses) {
    Assert-True ([string]$leaf.Status -cin $allowedStatuses) `
        "$($leaf.Path) contains an unsupported coverage status."
    Assert-True ([string]$leaf.Status -ceq 'NotInvestigated') `
        "$($leaf.Path) must default to NotInvestigated for a new model."
}

$decodedPath = Join-Path $repository 'decoded'
$coverageDocuments = @(Get-ChildItem -LiteralPath $decodedPath `
    -Filter '*-device-coverage.json' -File)
Assert-True ($coverageDocuments.Count -gt 0) `
    'The repository must retain at least one concrete device-coverage document.'
foreach ($coverageDocument in $coverageDocuments) {
    $coverage = Get-Content -LiteralPath $coverageDocument.FullName -Raw |
        ConvertFrom-Json
    Assert-True ($coverage.schemaVersion -eq $template.schemaVersion) `
        "$($coverageDocument.Name) does not use the current coverage schema."
    foreach ($leaf in @(Get-LeafStatuses -Value $coverage.capabilities -Path '')) {
        Assert-True ([string]$leaf.Status -cin $allowedStatuses) `
            "$($coverageDocument.Name): $($leaf.Path) contains unsupported status '$($leaf.Status)'."
    }
}

Write-Host 'Device-coverage template regression tests passed.'
