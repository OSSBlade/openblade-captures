[CmdletBinding()]
param(
    [string]$OutputDirectory = (
        'C:\OpenBlade\openblade-captures\raw\RZ09-0528\' +
        ('{0}-power-source-readback-matrix' -f (
            Get-Date -Format 'yyyyMMdd-HHmmss')))
)

$ErrorActionPreference = 'Stop'

$workspace = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$capture = Join-Path $workspace (
    'openblade-core\src\OpenBlade.Capture\bin\Release\' +
    'net10.0-windows10.0.26100.0\OpenBlade.Capture.exe')
$stateFile = Join-Path $OutputDirectory 'state.txt'
$summaryFile = Join-Path $OutputDirectory 'matrix-summary.json'
$failure = $null
$completedStates = @()

function Get-PowerLineStatus {
    Add-Type -AssemblyName System.Windows.Forms
    return [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus.ToString()
}

function Confirm-PhysicalState {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Instructions,
        [Parameter(Mandatory)][string]$Confirmation,
        [Parameter(Mandatory)][string]$ExpectedPowerLineStatus
    )

    Write-Host ''
    Write-Host "Prepare $Label."
    Write-Host $Instructions
    $entered = Read-Host "Type $Confirmation when the physical state is stable"
    if ($entered -cne $Confirmation) {
        throw "The operator confirmation for '$Label' did not match."
    }

    $deadline = [DateTimeOffset]::Now.AddSeconds(10)
    do {
        $powerLineStatus = Get-PowerLineStatus
        if ($powerLineStatus -ceq $ExpectedPowerLineStatus) {
            return $powerLineStatus
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTimeOffset]::Now -lt $deadline)

    throw (
        "Windows power-line status for '$Label' was '$powerLineStatus'; " +
        "expected '$ExpectedPowerLineStatus'. Do not capture while between plugs.")
}

function Invoke-ReadOnlyQuery {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][int]$Sample
    )

    $outputFile = Join-Path $OutputDirectory (
        '{0}-sample-{1}-output.txt' -f $Label, $Sample)
    $errorFile = Join-Path $OutputDirectory (
        '{0}-sample-{1}-error.txt' -f $Label, $Sample)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $capture
    $startInfo.Arguments = 'query-rz09-0528-02c6-power-source'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        throw "The read-only query process did not start for '$Label' sample $Sample."
    }

    try {
        if (-not $process.WaitForExit(15000)) {
            $process.Kill()
            throw "The read-only query timed out for '$Label' sample $Sample."
        }
        $standardOutput = $process.StandardOutput.ReadToEnd()
        $standardError = $process.StandardError.ReadToEnd()
        $standardOutput | Set-Content -LiteralPath $outputFile -Encoding utf8
        $standardError | Set-Content -LiteralPath $errorFile -Encoding utf8
        if ($process.ExitCode -ne 0) {
            throw (
                "The read-only query failed for '$Label' sample $Sample " +
                "with exit code $($process.ExitCode).")
        }
    }
    finally {
        $process.Dispose()
    }

    $jsonStart = $standardOutput.IndexOf('{')
    if ($jsonStart -lt 0) {
        throw "The read-only query returned no JSON for '$Label' sample $Sample."
    }
    $document = $standardOutput.Substring($jsonStart) | ConvertFrom-Json
    if ($document.readOnly -ne $true -or
        $document.success -ne $true -or
        $document.device.model -cne 'RZ09-0528' -or
        $document.device.productId -cne '02C6' -or
        $document.device.biosVersion -cne '2.02') {
        throw "The read-only query identity or success gate failed for '$Label' sample $Sample."
    }

    $adapter = @($document.responses | Where-Object {
        $_.operation -ceq '07/8C adapter power'
    })
    $thermal1 = @($document.responses | Where-Object {
        $_.operation -ceq '0D/82 class1 thermal1'
    })
    $thermal2 = @($document.responses | Where-Object {
        $_.operation -ceq '0D/82 class1 thermal2'
    })
    if ($adapter.Count -ne 1 -or $thermal1.Count -ne 1 -or $thermal2.Count -ne 1) {
        throw "The read-only query response set changed for '$Label' sample $Sample."
    }

    return [pscustomobject]@{
        sample = $Sample
        adapterPowerPayloadHex = [string]$adapter[0].responsePayloadHex
        thermal1PayloadHex = [string]$thermal1[0].responsePayloadHex
        thermal2PayloadHex = [string]$thermal2[0].responsePayloadHex
        outputSha256 = (
            Get-FileHash -Algorithm SHA256 -LiteralPath $outputFile).Hash
        outputBytes = (Get-Item -LiteralPath $outputFile).Length
        errorSha256 = (
            Get-FileHash -Algorithm SHA256 -LiteralPath $errorFile).Hash
        errorBytes = (Get-Item -LiteralPath $errorFile).Length
    }
}

function Capture-State {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Instructions,
        [Parameter(Mandatory)][string]$Confirmation,
        [Parameter(Mandatory)][string]$ExpectedPowerLineStatus,
        [string]$ExpectedAdapterPayload
    )

    $powerLineStatus = Confirm-PhysicalState `
        -Label $Label `
        -Instructions $Instructions `
        -Confirmation $Confirmation `
        -ExpectedPowerLineStatus $ExpectedPowerLineStatus
    $samples = @()
    for ($sample = 1; $sample -le 3; $sample++) {
        $samples += Invoke-ReadOnlyQuery -Label $Label -Sample $sample
        if ($sample -lt 3) {
            Start-Sleep -Milliseconds 500
        }
    }

    $signatures = @(
        $samples |
            ForEach-Object {
                '{0}|{1}|{2}' -f
                    $_.adapterPowerPayloadHex,
                    $_.thermal1PayloadHex,
                    $_.thermal2PayloadHex
            } |
            Select-Object -Unique)
    if ($signatures.Count -ne 1) {
        throw "The three read-only responses were not identical for '$Label'."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedAdapterPayload) -and
        $samples[0].adapterPowerPayloadHex -cne $ExpectedAdapterPayload) {
        throw (
            "The adapter payload for '$Label' was " +
            "'$($samples[0].adapterPowerPayloadHex)'; expected " +
            "'$ExpectedAdapterPayload'.")
    }

    $result = [pscustomobject]@{
        label = $Label
        capturedAt = [DateTimeOffset]::Now.ToString('O')
        windowsPowerLineStatus = $powerLineStatus
        samples = @($samples)
    }
    $script:completedStates += $result
    return $result
}

$system = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
if ($system.Model -cne 'Blade 16 - RZ09-0528' -or
    $bios.SMBIOSBIOSVersion -cne '2.02') {
    throw 'This read-only matrix is restricted to RZ09-0528 BIOS 2.02.'
}
if (-not (Test-Path -LiteralPath $capture -PathType Leaf)) {
    throw "Capture executable was not found at '$capture'. Build Release first."
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
"started $([DateTimeOffset]::Now.ToString('O'))" |
    Set-Content -LiteralPath $stateFile -Encoding utf8

try {
    $states = @()
    $states += Capture-State `
        -Label 'full-ac-baseline' `
        -Instructions 'Connect the full-power barrel adapter. Do not leave USB-C power connected.' `
        -Confirmation 'AC-BASELINE' `
        -ExpectedPowerLineStatus 'Online' `
        -ExpectedAdapterPayload '1111'
    $states += Capture-State `
        -Label 'battery' `
        -Instructions 'Disconnect the barrel adapter and every USB-C power source.' `
        -Confirmation 'BATTERY' `
        -ExpectedPowerLineStatus 'Offline'
    $states += Capture-State `
        -Label 'usb-c' `
        -Instructions 'Connect USB-C power only. Keep the barrel adapter disconnected.' `
        -Confirmation 'USBC' `
        -ExpectedPowerLineStatus 'Online'
    $states += Capture-State `
        -Label 'full-ac-restored' `
        -Instructions 'Disconnect USB-C power and reconnect the full-power barrel adapter.' `
        -Confirmation 'AC-RESTORED' `
        -ExpectedPowerLineStatus 'Online' `
        -ExpectedAdapterPayload '1111'

    $baseline = $states[0].samples[0]
    $restored = $states[3].samples[0]
    if ($baseline.adapterPowerPayloadHex -cne $restored.adapterPowerPayloadHex -or
        $baseline.thermal1PayloadHex -cne $restored.thermal1PayloadHex -or
        $baseline.thermal2PayloadHex -cne $restored.thermal2PayloadHex) {
        throw 'The final full-AC response did not restore the baseline response.'
    }

    $summary = [ordered]@{
        schemaVersion = 1
        capturedAt = [DateTimeOffset]::Now.ToString('O')
        device = [ordered]@{
            modelNumber = 'RZ09-0528'
            productIdHex = '02C6'
            bios = '2.02'
        }
        readOnly = $true
        settingChanged = $false
        physicalStateRestored = $true
        sampleCountPerState = 3
        states = @($states)
    }
    $summary |
        ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $summaryFile -Encoding utf8
}
catch {
    $failure = $_
}
finally {
    $summaryHash = if (Test-Path -LiteralPath $summaryFile -PathType Leaf) {
        (Get-FileHash -Algorithm SHA256 -LiteralPath $summaryFile).Hash
    }
    else {
        'Unavailable'
    }
    $summaryBytes = if (Test-Path -LiteralPath $summaryFile -PathType Leaf) {
        (Get-Item -LiteralPath $summaryFile).Length
    }
    else {
        0
    }
    $result = if ($null -eq $failure) {
        'finished success=true physicalStateRestored=true'
    }
    else {
        "failed completedStates=$($completedStates.Count) " +
            "$($failure.Exception.GetType().FullName): $($failure.Exception.Message)"
    }
    "$result summarySha256=$summaryHash summaryBytes=$summaryBytes " +
        "$([DateTimeOffset]::Now.ToString('O'))" |
        Set-Content -LiteralPath $stateFile -Encoding utf8
}

if ($null -ne $failure) {
    Write-Error $failure
    exit 1
}

Write-Output (
    "SummarySha256=" +
    (Get-FileHash -Algorithm SHA256 -LiteralPath $summaryFile).Hash)
Write-Output "SummaryBytes=$((Get-Item -LiteralPath $summaryFile).Length)"
Write-Output 'PhysicalStateRestored=True'
