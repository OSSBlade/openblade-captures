[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$startPath = Join-Path $PSScriptRoot 'Start-UsbPcapCapture.ps1'
$stopPath = Join-Path $PSScriptRoot 'Stop-UsbPcapCapture.ps1'
$startSource = Get-Content -LiteralPath $startPath -Raw
$stopSource = Get-Content -LiteralPath $stopPath -Raw
$errors = [Collections.Generic.List[string]]::new()

if ($startSource -notmatch 'CREATE_NEW_PROCESS_GROUP\s*=\s*0x00000200' -or
    $startSource -notmatch '(?s)CreateProcessW\(.+?CREATE_NEW_PROCESS_GROUP,\s*\r?\n\s*IntPtr\.Zero') {
    [void]$errors.Add('The launcher must use CREATE_NEW_PROCESS_GROUP.')
}
if ($stopSource -notmatch 'CTRL_BREAK_EVENT\s*=\s*1') {
    [void]$errors.Add('The stop helper must target CTRL_BREAK_EVENT.')
}
if ($stopSource -match 'CTRL_C_EVENT' -or
    $stopSource -match 'GenerateConsoleCtrlEvent\s*\(\s*(?:0|CTRL_C_EVENT)\s*,') {
    [void]$errors.Add('The stop helper must never generate CTRL_C_EVENT.')
}
if ($stopSource -match 'GenerateConsoleCtrlEvent\s*\([^,]+,\s*0\s*\)') {
    [void]$errors.Add('The stop helper must never signal process group 0.')
}
if ($stopSource -notmatch 'processGroupId\s*==\s*0' -or
    $stopSource -notmatch 'processGroupId\s*!=\s*processId') {
    [void]$errors.Add('The signal worker must reject zero and non-owned process groups.')
}
if ($stopSource -notmatch 'SetConsoleCtrlHandler\(IgnoreControlEvent,\s*true\)' -or
    $stopSource -notmatch 'FreeConsole\(\);\s*\r?\n\s*GC\.KeepAlive') {
    [void]$errors.Add('The signal worker must protect itself and detach in cleanup.')
}
if ($stopSource -notmatch 'Stop-Process\s+-Id\s+\$ownership\.ProcessId\s+-Force' -or
    $stopSource -notmatch 'may lose buffered capture data') {
    [void]$errors.Add('Forced termination must remain an explicit, disclosed fallback.')
}

if ($errors.Count -gt 0) {
    throw "USBPcap shutdown safety regression:`n- $($errors -join "`n- ")"
}

[pscustomobject]@{
    Valid = $true
    LaunchIsolation = 'CREATE_NEW_PROCESS_GROUP'
    Signal = 'CTRL_BREAK_EVENT'
    TargetGroup = 'Nonzero owned USBPcap PID'
    BroadcastCtrlC = $false
}
