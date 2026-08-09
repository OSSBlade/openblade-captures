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
            ($Value | ConvertTo-Json -Depth 10),
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

if (-not ('OpenBlade.Capture.CoolingPadHidInventory' -as [type])) {
    Add-Type -TypeDefinition @'
using Microsoft.Win32.SafeHandles;
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace OpenBlade.Capture
{
    public sealed class CoolingPadHidCollection
    {
        public ushort VendorId { get; set; }
        public ushort ProductId { get; set; }
        public ushort Revision { get; set; }
        public string InterfaceNumber { get; set; }
        public string CollectionNumber { get; set; }
        public ushort UsagePage { get; set; }
        public ushort Usage { get; set; }
        public ushort InputReportBytes { get; set; }
        public ushort OutputReportBytes { get; set; }
        public ushort FeatureReportBytes { get; set; }
        public ushort InputButtonCaps { get; set; }
        public ushort InputValueCaps { get; set; }
        public ushort OutputButtonCaps { get; set; }
        public ushort OutputValueCaps { get; set; }
        public ushort FeatureButtonCaps { get; set; }
        public ushort FeatureValueCaps { get; set; }
    }

    public static class CoolingPadHidInventory
    {
        private const uint DigcfPresent = 0x00000002;
        private const uint DigcfDeviceInterface = 0x00000010;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint OpenExisting = 3;
        private const int ErrorNoMoreItems = 259;

        [StructLayout(LayoutKind.Sequential)]
        private struct SpDeviceInterfaceData
        {
            public int Size;
            public Guid InterfaceClassGuid;
            public int Flags;
            public UIntPtr Reserved;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct HiddAttributes
        {
            public int Size;
            public ushort VendorId;
            public ushort ProductId;
            public ushort VersionNumber;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct HidpCaps
        {
            public ushort Usage;
            public ushort UsagePage;
            public ushort InputReportByteLength;
            public ushort OutputReportByteLength;
            public ushort FeatureReportByteLength;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)]
            public ushort[] Reserved;
            public ushort NumberLinkCollectionNodes;
            public ushort NumberInputButtonCaps;
            public ushort NumberInputValueCaps;
            public ushort NumberInputDataIndices;
            public ushort NumberOutputButtonCaps;
            public ushort NumberOutputValueCaps;
            public ushort NumberOutputDataIndices;
            public ushort NumberFeatureButtonCaps;
            public ushort NumberFeatureValueCaps;
            public ushort NumberFeatureDataIndices;
        }

        [DllImport("hid.dll")]
        private static extern void HidD_GetHidGuid(out Guid hidGuid);

        [DllImport("hid.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool HidD_GetAttributes(
            SafeFileHandle device,
            ref HiddAttributes attributes);

        [DllImport("hid.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool HidD_GetPreparsedData(
            SafeFileHandle device,
            out IntPtr preparsedData);

        [DllImport("hid.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool HidD_FreePreparsedData(IntPtr preparsedData);

        [DllImport("hid.dll")]
        private static extern int HidP_GetCaps(IntPtr preparsedData, out HidpCaps capabilities);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr SetupDiGetClassDevsW(
            ref Guid classGuid,
            IntPtr enumerator,
            IntPtr parent,
            uint flags);

        [DllImport("setupapi.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetupDiEnumDeviceInterfaces(
            IntPtr deviceInfoSet,
            IntPtr deviceInfoData,
            ref Guid interfaceClassGuid,
            uint memberIndex,
            ref SpDeviceInterfaceData interfaceData);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetupDiGetDeviceInterfaceDetailW(
            IntPtr deviceInfoSet,
            ref SpDeviceInterfaceData interfaceData,
            IntPtr detailData,
            uint detailDataSize,
            out uint requiredSize,
            IntPtr deviceInfoData);

        [DllImport("setupapi.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetupDiDestroyDeviceInfoList(IntPtr deviceInfoSet);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        public static CoolingPadHidCollection[] Enumerate(ushort vendorId, ushort productId)
        {
            Guid hidGuid;
            HidD_GetHidGuid(out hidGuid);
            IntPtr deviceInfoSet = SetupDiGetClassDevsW(
                ref hidGuid,
                IntPtr.Zero,
                IntPtr.Zero,
                DigcfPresent | DigcfDeviceInterface);
            if (deviceInfoSet == new IntPtr(-1))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not enumerate HID interfaces.");
            }

            List<CoolingPadHidCollection> results = new List<CoolingPadHidCollection>();
            try
            {
                for (uint index = 0; ; index++)
                {
                    SpDeviceInterfaceData interfaceData = new SpDeviceInterfaceData
                    {
                        Size = Marshal.SizeOf(typeof(SpDeviceInterfaceData))
                    };
                    if (!SetupDiEnumDeviceInterfaces(
                        deviceInfoSet,
                        IntPtr.Zero,
                        ref hidGuid,
                        index,
                        ref interfaceData))
                    {
                        int error = Marshal.GetLastWin32Error();
                        if (error == ErrorNoMoreItems)
                        {
                            break;
                        }
                        throw new Win32Exception(error, "Could not enumerate a HID interface.");
                    }

                    uint requiredSize;
                    SetupDiGetDeviceInterfaceDetailW(
                        deviceInfoSet,
                        ref interfaceData,
                        IntPtr.Zero,
                        0,
                        out requiredSize,
                        IntPtr.Zero);
                    IntPtr detailData = Marshal.AllocHGlobal((int)requiredSize);
                    try
                    {
                        Marshal.WriteInt32(detailData, IntPtr.Size == 8 ? 8 : 6);
                        if (!SetupDiGetDeviceInterfaceDetailW(
                            deviceInfoSet,
                            ref interfaceData,
                            detailData,
                            requiredSize,
                            out requiredSize,
                            IntPtr.Zero))
                        {
                            throw new Win32Exception(
                                Marshal.GetLastWin32Error(),
                                "Could not inspect a HID interface.");
                        }

                        string path = Marshal.PtrToStringUni(IntPtr.Add(detailData, 4));
                        if (String.IsNullOrWhiteSpace(path))
                        {
                            continue;
                        }
                        if (!path.StartsWith(@"\\?\hid#", StringComparison.OrdinalIgnoreCase))
                        {
                            continue;
                        }

                        using (SafeFileHandle device = CreateFileW(
                            path,
                            0,
                            FileShareRead | FileShareWrite,
                            IntPtr.Zero,
                            OpenExisting,
                            0,
                            IntPtr.Zero))
                        {
                            if (device.IsInvalid)
                            {
                                continue;
                            }

                            HiddAttributes attributes = new HiddAttributes
                            {
                                Size = Marshal.SizeOf(typeof(HiddAttributes))
                            };
                            if (!HidD_GetAttributes(device, ref attributes) ||
                                attributes.VendorId != vendorId ||
                                attributes.ProductId != productId)
                            {
                                continue;
                            }

                            IntPtr preparsedData;
                            if (!HidD_GetPreparsedData(device, out preparsedData))
                            {
                                throw new Win32Exception(
                                    Marshal.GetLastWin32Error(),
                                    "Could not read cooling-pad HID capabilities.");
                            }
                            try
                            {
                                HidpCaps capabilities;
                                int status = HidP_GetCaps(preparsedData, out capabilities);
                                if (status < 0)
                                {
                                    throw new InvalidOperationException(
                                        String.Format("HidP_GetCaps failed with status 0x{0:X8}.", status));
                                }

                                Match interfaceMatch = Regex.Match(
                                    path,
                                    "&mi_([0-9a-f]{2})",
                                    RegexOptions.IgnoreCase);
                                Match collectionMatch = Regex.Match(
                                    path,
                                    "&col([0-9a-f]{2})",
                                    RegexOptions.IgnoreCase);
                                results.Add(new CoolingPadHidCollection
                                {
                                    VendorId = attributes.VendorId,
                                    ProductId = attributes.ProductId,
                                    Revision = attributes.VersionNumber,
                                    InterfaceNumber = interfaceMatch.Success
                                        ? interfaceMatch.Groups[1].Value.ToUpperInvariant()
                                        : null,
                                    CollectionNumber = collectionMatch.Success
                                        ? collectionMatch.Groups[1].Value.ToUpperInvariant()
                                        : null,
                                    UsagePage = capabilities.UsagePage,
                                    Usage = capabilities.Usage,
                                    InputReportBytes = capabilities.InputReportByteLength,
                                    OutputReportBytes = capabilities.OutputReportByteLength,
                                    FeatureReportBytes = capabilities.FeatureReportByteLength,
                                    InputButtonCaps = capabilities.NumberInputButtonCaps,
                                    InputValueCaps = capabilities.NumberInputValueCaps,
                                    OutputButtonCaps = capabilities.NumberOutputButtonCaps,
                                    OutputValueCaps = capabilities.NumberOutputValueCaps,
                                    FeatureButtonCaps = capabilities.NumberFeatureButtonCaps,
                                    FeatureValueCaps = capabilities.NumberFeatureValueCaps
                                });
                            }
                            finally
                            {
                                HidD_FreePreparsedData(preparsedData);
                            }
                        }
                    }
                    finally
                    {
                        Marshal.FreeHGlobal(detailData);
                    }
                }
            }
            finally
            {
                SetupDiDestroyDeviceInfoList(deviceInfoSet);
            }

            return results.ToArray();
        }
    }
}
'@
}

$vendorId = [uint16]0x1532
$productId = [uint16]0x0F43
$identityPattern = 'VID_1532&PID_0F43'
$nodes = @(
    Get-CimInstance -ClassName Win32_PnPEntity |
        Where-Object { [string]$_.PNPDeviceID -match $identityPattern }
)
if ($nodes.Count -eq 0) {
    throw 'The Razer Laptop Cooling Pad (1532:0F43) is not present.'
}

$usbInterfaces = @(
    foreach ($node in $nodes) {
        $interfaceMatch = [Text.RegularExpressions.Regex]::Match(
            [string]$node.PNPDeviceID,
            '^USB\\.*&MI_([0-9A-F]{2})',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $interfaceMatch.Success) {
            continue
        }

        $interfaceNumber = $interfaceMatch.Groups[1].Value.ToUpperInvariant()
        $properties = @{}
        foreach ($property in @(Get-PnpDeviceProperty -InstanceId $node.PNPDeviceID -ErrorAction Stop)) {
            $properties[$property.KeyName] = $property.Data
        }
        [ordered]@{
            interfaceNumber = $interfaceNumber
            class = [string]$node.PNPClass
            friendlyName = [string]$node.Name
            busDescription = [string]$properties['DEVPKEY_Device_BusReportedDeviceDesc']
            service = [string]$node.Service
            classGuid = ([string]$node.ClassGuid).ToUpperInvariant()
            driverProvider = [string]$properties['DEVPKEY_Device_DriverProvider']
            driverVersion = [string]$properties['DEVPKEY_Device_DriverVersion']
        }
    }
)
$usbInterfaces = @($usbInterfaces | Sort-Object { $_['interfaceNumber'] })
$usbInterfaceNumbers = @($usbInterfaces | ForEach-Object { $_['interfaceNumber'] })
if ($usbInterfaceNumbers -notcontains '00' -or
    $usbInterfaceNumbers -notcontains '01') {
    throw 'The cooling pad does not expose the expected MI_00 and MI_01 USB HID interfaces.'
}

$hidCollections = @(
    [OpenBlade.Capture.CoolingPadHidInventory]::Enumerate($vendorId, $productId) |
        Where-Object { $_.Revision -eq 0x0200 } |
        Sort-Object InterfaceNumber, CollectionNumber |
        ForEach-Object {
            [ordered]@{
                interfaceNumber = $_.InterfaceNumber
                collectionNumber = $_.CollectionNumber
                hidVersionHex = '0x{0:X4}' -f $_.Revision
                usagePageHex = '0x{0:X4}' -f $_.UsagePage
                usageHex = '0x{0:X4}' -f $_.Usage
                inputReportBytes = [int]$_.InputReportBytes
                outputReportBytes = [int]$_.OutputReportBytes
                featureReportBytes = [int]$_.FeatureReportBytes
                inputButtonCaps = [int]$_.InputButtonCaps
                inputValueCaps = [int]$_.InputValueCaps
                outputButtonCaps = [int]$_.OutputButtonCaps
                outputValueCaps = [int]$_.OutputValueCaps
                featureButtonCaps = [int]$_.FeatureButtonCaps
                featureValueCaps = [int]$_.FeatureValueCaps
            }
        }
)
if ($hidCollections.Count -eq 0) {
    throw 'The cooling pad is present, but no user-mode HID collection could be inspected.'
}
$controlCollections = @(
    $hidCollections |
        Where-Object { $_['featureReportBytes'] -eq 91 }
)
if ($controlCollections.Count -ne 1) {
    throw "Expected one 91-byte cooling-pad feature-report collection; found $($controlCollections.Count)."
}

$computer = Get-CimInstance -ClassName Win32_ComputerSystemProduct
$bios = Get-CimInstance -ClassName Win32_BIOS
$operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
$inventory = [ordered]@{
    schemaVersion = 1
    capturedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    privacy = [ordered]@{
        serialNumberIncluded = $false
        fullDeviceInstanceIdsIncluded = $false
        deviceInterfacePathsIncluded = $false
        containerIdsIncluded = $false
        locationPathsIncluded = $false
        systemUuidIncluded = $false
    }
    host = [ordered]@{
        productName = [string]$computer.Name
        bios = [string]$bios.SMBIOSBIOSVersion
    }
    target = [ordered]@{
        productName = 'Razer Laptop Cooling Pad'
        vendorIdHex = '1532'
        productIdHex = '0F43'
        revisionHex = '0200'
    }
    windows = [ordered]@{
        version = [string]$operatingSystem.Version
        build = [string]$operatingSystem.BuildNumber
        architecture = [string]$operatingSystem.OSArchitecture
    }
    transport = [ordered]@{
        usbComposite = $true
        usbInterfaceCount = $usbInterfaces.Count
        hidCollectionCount = $hidCollections.Count
        controlCollection = [ordered]@{
            interfaceNumber = $controlCollections[0]['interfaceNumber']
            collectionNumber = $controlCollections[0]['collectionNumber']
            featureReportBytes = $controlCollections[0]['featureReportBytes']
        }
        usbInterfaces = $usbInterfaces
        hidCollections = $hidCollections
    }
}

Write-AtomicJson -Path $OutputPath -Value $inventory -Overwrite:$Force
Get-Item -LiteralPath ([IO.Path]::GetFullPath($OutputPath))
