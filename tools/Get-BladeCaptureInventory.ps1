[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-AtomicJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value,
        [switch]$Overwrite
    )

    $resolved = [IO.Path]::GetFullPath($Path)
    if ((Test-Path -LiteralPath $resolved) -and -not $Overwrite) {
        throw "Refusing to overwrite inventory: $resolved"
    }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($resolved)) | Out-Null
    $temporary = "$resolved.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
    $backup = "$resolved.$PID.$([Guid]::NewGuid().ToString('N')).bak"
    try {
        [IO.File]::WriteAllText(
            $temporary,
            ($Value | ConvertTo-Json -Depth 8),
            [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $resolved) {
            [IO.File]::Replace($temporary, $resolved, $backup, $true)
            Remove-Item -LiteralPath $backup -Force
        }
        else {
            [IO.File]::Move($temporary, $resolved)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
        if (Test-Path -LiteralPath $backup) {
            Remove-Item -LiteralPath $backup -Force
        }
    }
}

$product = Get-CimInstance -ClassName Win32_ComputerSystemProduct
$computer = Get-CimInstance -ClassName Win32_ComputerSystem
$bios = Get-CimInstance -ClassName Win32_BIOS
$operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
$razerIdentities = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase)

Get-CimInstance -ClassName Win32_PnPEntity |
    ForEach-Object {
        foreach ($hardwareId in @($_.HardwareID)) {
            foreach ($match in [Text.RegularExpressions.Regex]::Matches(
                [string]$hardwareId,
                'VID_[0-9A-F]{4}&PID_[0-9A-F]{4}',
                [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                if ($match.Value.StartsWith('VID_1532', [StringComparison]::OrdinalIgnoreCase)) {
                    [void]$razerIdentities.Add($match.Value.ToUpperInvariant())
                }
            }
        }
    }

$modelCandidate = @(
    [string]$computer.Model,
    [string]$product.Name,
    [string]$product.Version
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$modelNumberMatch = [Text.RegularExpressions.Regex]::Match(
    ($modelCandidate -join ' '),
    'RZ09-[0-9]{4}',
    [Text.RegularExpressions.RegexOptions]::IgnoreCase)

$inventory = [ordered]@{
    schemaVersion = 1
    capturedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    privacy = [ordered]@{
        serialNumberIncluded = $false
        systemUuidIncluded = $false
        fullDeviceInstanceIdsIncluded = $false
    }
    system = [ordered]@{
        manufacturer = [string]$computer.Manufacturer
        model = [string]$computer.Model
        productVendor = [string]$product.Vendor
        productName = [string]$product.Name
        productVersion = [string]$product.Version
        modelNumber = if ($modelNumberMatch.Success) {
            $modelNumberMatch.Value.ToUpperInvariant()
        } else {
            $null
        }
    }
    firmware = [ordered]@{
        bios = [string]$bios.SMBIOSBIOSVersion
        biosReleaseDate = if ($null -eq $bios.ReleaseDate) {
            $null
        } else {
            ([DateTime]$bios.ReleaseDate).ToUniversalTime().ToString('yyyy-MM-dd')
        }
        ec = $null
        mcu = $null
    }
    windows = [ordered]@{
        caption = [string]$operatingSystem.Caption
        version = [string]$operatingSystem.Version
        build = [string]$operatingSystem.BuildNumber
        architecture = [string]$operatingSystem.OSArchitecture
    }
    razerUsbIdentities = @($razerIdentities | Sort-Object)
}

Write-AtomicJson -Path $OutputPath -Value $inventory -Overwrite:$Force
Get-Item -LiteralPath ([IO.Path]::GetFullPath($OutputPath))
