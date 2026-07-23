[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AnnotationPath,
    [string]$PcapPath
)

$ErrorActionPreference = 'Stop'
$resolvedAnnotation = (Resolve-Path -LiteralPath $AnnotationPath -ErrorAction Stop).Path
$rawText = Get-Content -LiteralPath $resolvedAnnotation -Raw
$annotation = $rawText | ConvertFrom-Json
$errors = [Collections.Generic.List[string]]::new()

function Add-Error([string]$Message) {
    [void]$errors.Add($Message)
}

if ($annotation.schemaVersion -ne 2) {
    Add-Error 'Only annotation schema 2 is supported.'
}
if ($annotation.device.modelNumber -notmatch '^RZ09-[0-9]{4}$') {
    Add-Error 'device.modelNumber must use RZ09-XXXX format.'
}
if ($annotation.device.vendorIdHex -notmatch '^[0-9A-Fa-f]{4}$' -or
    $annotation.device.productIdHex -notmatch '^[0-9A-Fa-f]{4}$') {
    Add-Error 'device VID and PID must each contain four hexadecimal characters.'
}
if ($annotation.capture.sha256 -notmatch '^[0-9A-Fa-f]{64}$') {
    Add-Error 'capture.sha256 must contain 64 hexadecimal characters.'
}
if ([long]$annotation.capture.byteLength -le 0) {
    Add-Error 'capture.byteLength must be positive.'
}
if ($annotation.capture.rawCaptureCommitted -ne $false) {
    Add-Error 'Raw captures must not be committed.'
}
if ($annotation.capture.captureMode -eq 'AllDevices' -and
    @($annotation.limitations) -notmatch '(?i)all.devices|unrelated') {
    Add-Error 'All-device capture use must be disclosed in limitations.'
}
if ($annotation.capture.stopMode -eq 'Forced' -and
    $annotation.capture.forcedShutdownDataLossDisclosed -ne $true) {
    Add-Error 'Forced shutdown must disclose possible buffered data loss.'
}
if ($annotation.capture.decodable -ne $true) {
    Add-Error 'The annotation must confirm that the capture is decodable.'
}
if ([string]::IsNullOrWhiteSpace([string]$annotation.evidenceProvenance.controller) -or
    [string]$annotation.evidenceProvenance.controller -match '(?i)\bTODO\b') {
    Add-Error 'evidenceProvenance.controller must identify the oracle.'
}
if ([string]::IsNullOrWhiteSpace([string]$annotation.action.subsystem) -or
    [string]$annotation.action.subsystem -match '(?i)\bTODO\b' -or
    [string]::IsNullOrWhiteSpace([string]$annotation.action.name) -or
    [string]$annotation.action.name -match '(?i)\bTODO\b') {
    Add-Error 'The exact subsystem and action are required.'
}
if ($annotation.action.operatorConfirmed -ne $true) {
    Add-Error 'Operator confirmation must be recorded.'
}

$typedApply = $annotation.evidenceProvenance.openBladeTypedApplyPerformed -eq $true
if ($typedApply) {
    foreach ($property in @(
        'priorStateSaved',
        'applyResult',
        'readbackResult',
        'restorationResult',
        'restorationReadbackResult')) {
        $value = $annotation.validation.$property
        if ($property -eq 'priorStateSaved') {
            if ($value -ne $true) {
                Add-Error 'A typed write requires a saved prior state.'
            }
        }
        elseif ([string]$value -notmatch '(?i)\b(pass|passed|success|confirmed|match|restored)\b') {
            Add-Error "A typed write requires a successful validation.$property outcome."
        }
    }
}

$forbiddenPatterns = [ordered]@{
    'local filesystem path' = '(?i)[A-Z]:\\+[^"\r\n]+'
    'raw capture file extension' = '(?i)\.(pcap|pcapng)(?:["\s,}]|$)'
    'serial-number property' = '(?i)"serial(?:number)?"\s*:'
    'system UUID property' = '(?i)"(?:system)?uuid"\s*:'
    'device-instance property' = '(?i)"deviceinstanceid"\s*:'
    'device instance suffix' = '(?i)VID_[0-9A-F]{4}&PID_[0-9A-F]{4}\\+[^"\\\s]+'
    'unfinished placeholder' = '(?i)\bTODO\b'
}
foreach ($entry in $forbiddenPatterns.GetEnumerator()) {
    if ($rawText -match $entry.Value) {
        Add-Error "Annotation contains $($entry.Key)."
    }
}

if (-not [string]::IsNullOrWhiteSpace($PcapPath)) {
    $resolvedPcap = (Resolve-Path -LiteralPath $PcapPath -ErrorAction Stop).Path
    $actualHash = (Get-FileHash -LiteralPath $resolvedPcap -Algorithm SHA256).Hash
    $actualLength = (Get-Item -LiteralPath $resolvedPcap).Length
    if ($actualHash -ine [string]$annotation.capture.sha256) {
        Add-Error 'The capture hash does not match the supplied PCAP.'
    }
    if ($actualLength -ne [long]$annotation.capture.byteLength) {
        Add-Error 'The capture length does not match the supplied PCAP.'
    }
}

if ($errors.Count -gt 0) {
    throw "Capture evidence validation failed:`n- $($errors -join "`n- ")"
}

[pscustomobject]@{
    AnnotationPath = $resolvedAnnotation
    Valid = $true
    SchemaVersion = 2
}
