$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
$path = Join-Path $repository 'tools\Start-Rz090528FullMenuOracleCapture.ps1'
$source = Get-Content -Raw -LiteralPath $path

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) {
        throw $Message
    }
}

foreach ($required in @(
        '$usbPcapDevice = ''\\.\USBPcap2''',
        '$expectedAddress = 3',
        'usb.idVendor == 0x1532 && usb.idProduct == 0x02c6',
        '-A',
        '--inject-descriptors',
        '-DeviceAddress $expectedAddress',
        '-SkipServiceManagement',
        '-SkipAdministratorCheck',
        'elevatedChildLaunchedUserProcesses = $false')) {
    Assert-True ($source.Contains($required)) `
        "The full-menu capture wrapper dropped '$required'."
}
Assert-True (
    $source.IndexOf('& $startCapture', [StringComparison]::Ordinal) -lt
    $source.IndexOf('& $interactive', [StringComparison]::Ordinal)) `
    'Descriptor verification must run before the targeted capture.'

Write-Host 'RZ09-0528 full-menu oracle capture wrapper tests passed.'
