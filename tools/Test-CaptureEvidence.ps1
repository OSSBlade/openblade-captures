[CmdletBinding(DefaultParameterSetName = 'LocalCapture')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AnnotationPath,

    [Parameter(Mandatory, ParameterSetName = 'LocalCapture')]
    [ValidateNotNullOrEmpty()]
    [string]$PcapPath,

    [Parameter(Mandatory, ParameterSetName = 'SchemaOnly')]
    [switch]$SchemaOnly
)

$ErrorActionPreference = 'Stop'
$resolvedAnnotation = (Resolve-Path -LiteralPath $AnnotationPath -ErrorAction Stop).Path
$rawText = Get-Content -LiteralPath $resolvedAnnotation -Raw
$annotation = $rawText | ConvertFrom-Json
$errors = [Collections.Generic.List[string]]::new()

function Add-Error([string]$Message) {
    [void]$errors.Add($Message)
}

function Test-HasProperty {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    return $null -ne $Value -and
        $null -ne $Value.PSObject.Properties[$Name]
}

function Test-NonPlaceholderText {
    param([AllowNull()][object]$Value)

    $text = [string]$Value
    return -not [string]::IsNullOrWhiteSpace($text) -and
        $text -notmatch '(?i)\bTODO\b'
}

function Test-SuccessOutcome {
    param([AllowNull()][object]$Value)

    return [string]$Value -match
        '(?i)\b(pass(?:ed)?|success(?:ful(?:ly)?)?|confirmed|match(?:ed)?|restor(?:e|ed)|unchanged)\b'
}

function Test-HexFields {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    if ($null -eq $Value) {
        return
    }

    if ($Value -is [array]) {
        for ($index = 0; $index -lt $Value.Count; $index++) {
            Test-HexFields -Value $Value[$index] -Path "$Path[$index]"
        }
        return
    }

    if ($Value -isnot [pscustomobject]) {
        return
    }

    foreach ($property in $Value.PSObject.Properties) {
        $propertyPath = "$Path.$($property.Name)"
        if ($property.Name -match '(?i)Hex$' -and $property.Value -is [string]) {
            $hex = [string]$property.Value
            if ($hex.Length -eq 0 -or $hex.Length -gt 8192 -or
                ($hex.Length % 2) -ne 0 -or $hex -notmatch '^[0-9A-Fa-f]+$') {
                Add-Error "$propertyPath must contain between 1 and 4096 bytes of hexadecimal evidence."
            }
        }

        Test-HexFields -Value $property.Value -Path $propertyPath
    }
}

if ($annotation.schemaVersion -isnot [int] -or $annotation.schemaVersion -ne 2) {
    Add-Error 'Only annotation schema 2 is supported.'
}
if ([Text.Encoding]::UTF8.GetByteCount($rawText) -gt 262144) {
    Add-Error 'The complete annotation exceeds the 256 KiB commit-safety limit.'
}

$provenance = $annotation.evidenceProvenance
$allowedRoles = @(
    'OracleCapture',
    'ReadOnlyQueryCapture',
    'NegativeCapture',
    'ExactDeviceInteractiveValidation',
    'OpenBladeTypedValidation'
)
if (-not (Test-NonPlaceholderText $provenance.controller)) {
    Add-Error 'evidenceProvenance.controller must identify the oracle or typed controller.'
}
elseif ([string]$provenance.controller -notmatch '\d') {
    Add-Error 'evidenceProvenance.controller must include the controller name and version.'
}
if ([string]$provenance.role -cnotin $allowedRoles) {
    Add-Error "evidenceProvenance.role must be one of: $($allowedRoles -join ', ')."
}
foreach ($booleanProperty in @('openBladeTypedApplyPerformed', 'openBladeReadbackConfirmed')) {
    if (-not (Test-HasProperty -Value $provenance -Name $booleanProperty) -or
        $provenance.$booleanProperty -isnot [bool]) {
        Add-Error "evidenceProvenance.$booleanProperty must be a JSON boolean."
    }
}

$capturedAt = [DateTimeOffset]::MinValue
$capturedAtValid = [DateTimeOffset]::TryParse(
    [string]$annotation.capturedAtUtc,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind,
    [ref]$capturedAt)
if (-not $capturedAtValid -or $capturedAt.Offset -ne [TimeSpan]::Zero) {
    Add-Error 'capturedAtUtc must be a valid UTC ISO-8601 timestamp.'
}

if ($annotation.device.modelNumber -notmatch '^RZ09-[0-9]{4}$') {
    Add-Error 'device.modelNumber must use RZ09-XXXX format.'
}
if ($annotation.device.vendorIdHex -notmatch '^[0-9A-Fa-f]{4}$' -or
    $annotation.device.productIdHex -notmatch '^[0-9A-Fa-f]{4}$') {
    Add-Error 'device VID and PID must each contain four hexadecimal characters.'
}
if (-not (Test-NonPlaceholderText $annotation.device.bios)) {
    Add-Error 'device.bios is required and cannot contain a placeholder.'
}
foreach ($optionalFirmwareProperty in @('ec', 'mcu')) {
    $value = $annotation.device.$optionalFirmwareProperty
    if ($null -ne $value -and -not (Test-NonPlaceholderText $value)) {
        Add-Error "device.$optionalFirmwareProperty must be null or a non-placeholder value."
    }
}

if ($annotation.capture.sha256 -notmatch '^[0-9A-Fa-f]{64}$') {
    Add-Error 'capture.sha256 must contain 64 hexadecimal characters.'
}
if (($annotation.capture.byteLength -isnot [int] -and
    $annotation.capture.byteLength -isnot [long]) -or
    [long]$annotation.capture.byteLength -le 0) {
    Add-Error 'capture.byteLength must be positive.'
}
if ($annotation.capture.rawCaptureCommitted -isnot [bool] -or
    $annotation.capture.rawCaptureCommitted -ne $false) {
    Add-Error 'Raw captures must not be committed.'
}
$allowedCaptureModes = @('DeviceAddress', 'DeviceAddresses', 'AllDevices')
if ([string]$annotation.capture.captureMode -cnotin $allowedCaptureModes) {
    Add-Error "capture.captureMode must be one of: $($allowedCaptureModes -join ', ')."
}
$selectedDeviceCount = $annotation.capture.selectedDeviceCount
if ([string]$annotation.capture.captureMode -ceq 'DeviceAddresses') {
    if ($selectedDeviceCount -isnot [int] -or
        $selectedDeviceCount -lt 2 -or $selectedDeviceCount -gt 127) {
        Add-Error 'DeviceAddresses capture mode requires a selected-device count from 2 to 127.'
    }
    if ((@($annotation.limitations) -join ' ') -notmatch
        '(?i)multi(?:ple)?[ -]?device|correlat') {
        Add-Error 'Multi-device capture use must disclose its correlation limitations.'
    }
}
elseif ($null -ne $selectedDeviceCount -and $selectedDeviceCount -ne 0) {
    Add-Error 'capture.selectedDeviceCount is only valid for DeviceAddresses capture mode.'
}
$allowedStopModes = @('Graceful', 'Forced')
if ([string]$annotation.capture.stopMode -cnotin $allowedStopModes) {
    Add-Error "capture.stopMode must be one of: $($allowedStopModes -join ', ')."
}
if ($annotation.capture.captureMode -ceq 'AllDevices' -and
    (@($annotation.limitations) -join ' ') -notmatch '(?i)all.devices|unrelated') {
    Add-Error 'All-device capture use must be disclosed in limitations.'
}
if ($annotation.capture.stopMode -ceq 'Forced') {
    if ($annotation.capture.forcedShutdownDataLossDisclosed -isnot [bool] -or
        $annotation.capture.forcedShutdownDataLossDisclosed -ne $true) {
        Add-Error 'Forced shutdown must disclose possible buffered data loss.'
    }
}
elseif ($annotation.capture.forcedShutdownDataLossDisclosed -isnot [bool] -or
    $annotation.capture.forcedShutdownDataLossDisclosed -ne $false) {
    Add-Error 'Graceful shutdown cannot claim forced-shutdown data-loss disclosure.'
}
if ($annotation.capture.decodable -isnot [bool] -or
    $annotation.capture.decodable -ne $true) {
    Add-Error 'The annotation must confirm that the capture is decodable.'
}

$allowedActionKinds = @('ReadOnlyQuery', 'SettingChange', 'Observation', 'NegativeControl')
if ([string]$annotation.action.kind -cnotin $allowedActionKinds) {
    Add-Error "action.kind must be one of: $($allowedActionKinds -join ', ')."
}
foreach ($actionProperty in @('subsystem', 'name', 'value')) {
    if (-not (Test-NonPlaceholderText $annotation.action.$actionProperty)) {
        Add-Error "action.$actionProperty is required and cannot contain a placeholder."
    }
}
if ($annotation.action.operatorConfirmed -isnot [bool] -or
    $annotation.action.operatorConfirmed -ne $true) {
    Add-Error 'Operator confirmation must be recorded.'
}

$typedApply = $provenance.openBladeTypedApplyPerformed -eq $true
$negativeCapture = [string]$provenance.role -ceq 'NegativeCapture'
$writeValidation = $typedApply -or
    [string]$annotation.action.kind -ceq 'SettingChange' -or
    [string]$provenance.role -cin @(
        'ExactDeviceInteractiveValidation',
        'OpenBladeTypedValidation')
if ($annotation.validation.priorStateSaved -isnot [bool]) {
    Add-Error 'validation.priorStateSaved must be a JSON boolean.'
}
if ($writeValidation) {
    if (-not $negativeCapture -and
        $annotation.validation.priorStateSaved -ne $true) {
        Add-Error 'A setting change requires a saved prior state.'
    }
    if (-not $negativeCapture) {
        foreach ($property in @(
            'applyResult',
            'readbackResult',
            'restorationResult',
            'restorationReadbackResult')) {
            if (-not (Test-SuccessOutcome $annotation.validation.$property)) {
                Add-Error "A setting change requires a successful validation.$property outcome."
            }
        }
    }
}
if ($typedApply -and -not $negativeCapture -and
    $provenance.openBladeReadbackConfirmed -ne $true) {
    Add-Error 'A typed OpenBlade apply requires openBladeReadbackConfirmed=true.'
}

$sanitizedEvidence = @($annotation.sanitizedEvidence)
if ($sanitizedEvidence.Count -lt 1 -or $sanitizedEvidence.Count -gt 64) {
    Add-Error 'sanitizedEvidence must contain between 1 and 64 bounded evidence items.'
}
for ($index = 0; $index -lt $sanitizedEvidence.Count; $index++) {
    $item = $sanitizedEvidence[$index]
    if ($item -isnot [pscustomobject]) {
        Add-Error "sanitizedEvidence[$index] must be a JSON object."
        continue
    }
    if (-not (Test-NonPlaceholderText $item.kind)) {
        Add-Error "sanitizedEvidence[$index].kind is required."
    }
    if (-not (Test-NonPlaceholderText $item.summary)) {
        Add-Error "sanitizedEvidence[$index].summary is required."
    }
    $serializedItem = $item | ConvertTo-Json -Depth 20 -Compress
    if ($serializedItem.Length -gt 16384) {
        Add-Error "sanitizedEvidence[$index] exceeds the 16 KiB bounded-evidence limit."
    }
    Test-HexFields -Value $item -Path "sanitizedEvidence[$index]"
}

$limitations = @($annotation.limitations)
if ($limitations.Count -lt 1 -or $limitations.Count -gt 32) {
    Add-Error 'limitations must contain between 1 and 32 reviewed statements.'
}
for ($index = 0; $index -lt $limitations.Count; $index++) {
    if (-not (Test-NonPlaceholderText $limitations[$index])) {
        Add-Error "limitations[$index] must be a reviewed non-placeholder statement."
    }
    elseif ([Text.Encoding]::UTF8.GetByteCount([string]$limitations[$index]) -gt 4096) {
        Add-Error "limitations[$index] exceeds the 4 KiB text limit."
    }
}

$notes = @($annotation.notes)
if ($notes.Count -gt 64) {
    Add-Error 'notes cannot contain more than 64 bounded statements.'
}
for ($index = 0; $index -lt $notes.Count; $index++) {
    if ([Text.Encoding]::UTF8.GetByteCount([string]$notes[$index]) -gt 4096) {
        Add-Error "notes[$index] exceeds the 4 KiB text limit."
    }
}

$forbiddenPatterns = [ordered]@{
    'local filesystem path' = '(?i)(?<![A-Z0-9])[A-Z]:(?:\\\\|/)[^"\r\n]+'
    'UNC filesystem path' = '(?i)(?<!:)(?:\\\\){2}[^\\\s"]+(?:\\\\)[^"\r\n]+'
    'POSIX user path' = '(?i)/(?:home|Users)/[^"\r\n]+'
    'raw capture file extension' = '(?i)\.(pcap|pcapng)(?:["\s,}]|$)'
    'serial-number property' = '(?i)"serial(?:number)?"\s*:'
    'system UUID property' = '(?i)"(?:system)?uuid"\s*:'
    'device-instance property' = '(?i)"(?:deviceInstanceId|pnpDeviceId)"\s*:'
    'local identity property' = '(?i)"(?:user(?:name)?|computerName|hostName|machineName|filePath|localPath)"\s*:'
    'Windows SID' = '(?i)\bS-1-5-(?:\d+-){1,14}\d+\b'
    'UUID value' = '(?i)\b[0-9A-F]{8}-[0-9A-F]{4}-[1-5][0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}\b'
    'Razer serial-like value' = '(?i)\b[A-Z]{2}\d{4}[A-Z]\d{7,9}\b'
    'generic serial-like value' = '(?i)\bSN[-_ ]?[A-Z0-9-]{8,}\b'
    'device instance suffix' = '(?i)VID_[0-9A-F]{4}&PID_[0-9A-F]{4}\\+[^"\\\s]+'
    'unfinished placeholder' = '(?i)\bTODO\b'
}
foreach ($entry in $forbiddenPatterns.GetEnumerator()) {
    if ($rawText -match $entry.Value) {
        Add-Error "Annotation contains $($entry.Key)."
    }
}

$pcapHashVerified = $false
if ($PSCmdlet.ParameterSetName -ceq 'LocalCapture') {
    $resolvedPcap = (Resolve-Path -LiteralPath $PcapPath -ErrorAction Stop).Path
    $actualHash = (Get-FileHash -LiteralPath $resolvedPcap -Algorithm SHA256).Hash
    $actualLength = (Get-Item -LiteralPath $resolvedPcap).Length
    if ($actualHash -ine [string]$annotation.capture.sha256) {
        Add-Error 'The capture hash does not match the supplied PCAP.'
    }
    if ($actualLength -ne [long]$annotation.capture.byteLength) {
        Add-Error 'The capture length does not match the supplied PCAP.'
    }
    $pcapHashVerified = $actualHash -ieq [string]$annotation.capture.sha256 -and
        $actualLength -eq [long]$annotation.capture.byteLength
}

if ($errors.Count -gt 0) {
    throw "Capture evidence validation failed:`n- $($errors -join "`n- ")"
}

[pscustomobject]@{
    AnnotationPath = $resolvedAnnotation
    Valid = $true
    SchemaVersion = 2
    ValidationMode = $PSCmdlet.ParameterSetName
    PcapHashVerified = $pcapHashVerified
}
