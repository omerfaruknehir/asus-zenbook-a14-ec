param(
    [string]$InstanceId = 'ACPI\QTEC0001\2',
    [string]$OutputDir = "$env:USERPROFILE\Downloads\a14-qtec-acpi-resource-capture"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

function Write-TextFile([string]$Name, [scriptblock]$Body) {
    $path = Join-Path $OutputDir $Name
    try {
        (& $Body 2>&1 | Out-String -Width 1000).TrimEnd() |
            Set-Content -Encoding UTF8 -LiteralPath $path
    }
    catch {
        ("ERROR: " + ($_ | Out-String -Width 1000)) |
            Set-Content -Encoding UTF8 -LiteralPath $path
        throw
    }
}

Write-Host '===== A14 QTEC0001 ACPI / RESOURCE CAPTURE ====='
Write-Host "INSTANCE_ID=$InstanceId"
Write-Host "OUTPUT_DIR=$OutputDir"

$pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
if (-not (Test-Path -LiteralPath $pnputil)) {
    throw "pnputil.exe not found: $pnputil"
}

Write-Host 'Collecting PnP resources, properties, stack and relations...'
Write-TextFile 'qtec0001-pnputil.txt' {
    & $pnputil /enum-devices /instanceid $InstanceId `
        /deviceids /relations /services /stack /drivers /interfaces /properties /resources
}

Write-TextFile 'qtec0001-devicetree.txt' {
    & $pnputil /enum-devicetree $InstanceId /connected /services /stack /drivers /interfaces
}

Write-TextFile 'qtec0001-pnp-device.txt' {
    Get-PnpDevice -InstanceId $InstanceId | Format-List *
}

Write-TextFile 'qtec0001-pnp-properties.txt' {
    Get-PnpDeviceProperty -InstanceId $InstanceId | Format-List *
}

$enumSubkey = $InstanceId -replace '^ACPI\\', 'ACPI\'
$enumNative = "HKLM\SYSTEM\CurrentControlSet\Enum\$enumSubkey"
$regOut = Join-Path $OutputDir 'qtec0001-enum.reg'
$regText = & reg.exe export $enumNative $regOut /y 2>&1
$regText | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $OutputDir 'qtec0001-reg-export.txt')
if ($LASTEXITCODE -ne 0) {
    Write-Warning "reg.exe export failed with exit code $LASTEXITCODE"
}

# GetSystemFirmwareTable/EnumSystemFirmwareTables are the documented user-mode
# interfaces for ACPI firmware tables. Multi-character IDs are passed in the
# DWORD form expected by Win32. For DSDT the table identifier is reversed
# ('TDSD') as required by GetSystemFirmwareTable's ACPI provider.
$native = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class A14FirmwareTables
{
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern uint GetSystemFirmwareTable(
        uint FirmwareTableProviderSignature,
        uint FirmwareTableID,
        IntPtr pFirmwareTableBuffer,
        uint BufferSize);

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern uint EnumSystemFirmwareTables(
        uint FirmwareTableProviderSignature,
        IntPtr pFirmwareTableEnumBuffer,
        uint BufferSize);

    public static byte[] Get(uint provider, uint tableId)
    {
        uint size = GetSystemFirmwareTable(provider, tableId, IntPtr.Zero, 0);
        if (size == 0)
            throw new Win32Exception(Marshal.GetLastWin32Error());

        IntPtr buffer = Marshal.AllocHGlobal(checked((int)size));
        try {
            uint written = GetSystemFirmwareTable(provider, tableId, buffer, size);
            if (written == 0)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            byte[] result = new byte[written];
            Marshal.Copy(buffer, result, 0, checked((int)written));
            return result;
        }
        finally {
            Marshal.FreeHGlobal(buffer);
        }
    }

    public static byte[] Enumerate(uint provider)
    {
        uint size = EnumSystemFirmwareTables(provider, IntPtr.Zero, 0);
        if (size == 0)
            throw new Win32Exception(Marshal.GetLastWin32Error());

        IntPtr buffer = Marshal.AllocHGlobal(checked((int)size));
        try {
            uint written = EnumSystemFirmwareTables(provider, buffer, size);
            if (written == 0)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            byte[] result = new byte[written];
            Marshal.Copy(buffer, result, 0, checked((int)written));
            return result;
        }
        finally {
            Marshal.FreeHGlobal(buffer);
        }
    }
}
'@

if (-not ('A14FirmwareTables' -as [type])) {
    Add-Type -TypeDefinition $native -Language CSharp
}

$AcpiProvider = [uint32]0x41435049  # 'ACPI'
$DsdtId = [uint32]0x54445344        # 'TDSD' -> DSDT for ACPI provider

Write-Host 'Enumerating ACPI table signatures...'
$idsRaw = [A14FirmwareTables]::Enumerate($AcpiProvider)
$ids = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i + 3 -lt $idsRaw.Length; $i += 4) {
    $ids.Add([Text.Encoding]::ASCII.GetString($idsRaw, $i, 4))
}
$ids | Set-Content -Encoding ASCII -LiteralPath (Join-Path $OutputDir 'acpi-table-signatures.txt')

Write-Host 'Retrieving DSDT from Windows ACPI provider...'
$dsdt = [A14FirmwareTables]::Get($AcpiProvider, $DsdtId)
if ($dsdt.Length -lt 36) {
    throw "DSDT is implausibly short: $($dsdt.Length) bytes"
}
$signature = [Text.Encoding]::ASCII.GetString($dsdt, 0, 4)
if ($signature -ne 'DSDT') {
    throw "GetSystemFirmwareTable returned unexpected signature '$signature'"
}
$dsdtPath = Join-Path $OutputDir 'DSDT.aml'
[IO.File]::WriteAllBytes($dsdtPath, $dsdt)
Write-Host "DSDT_BYTES=$($dsdt.Length)"
Write-Host "DSDT_PATH=$dsdtPath"

Write-TextFile 'system-summary.txt' {
    Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion, OsBuildNumber, BiosManufacturer, BiosVersion, BiosFirmwareType
}

$hashPath = Join-Path $OutputDir 'SHA256SUMS.txt'
Get-ChildItem -LiteralPath $OutputDir -File |
    Where-Object { $_.FullName -ne $hashPath } |
    Sort-Object Name |
    ForEach-Object {
        $h = Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName
        "$($h.Hash.ToLowerInvariant())  $($_.Name)"
    } | Set-Content -Encoding ASCII -LiteralPath $hashPath

$zipPath = "$OutputDir.zip"
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -Path (Join-Path $OutputDir '*') -DestinationPath $zipPath -Force

Write-Host "RESULT_DIR=$OutputDir"
Write-Host "RESULT_ZIP=$zipPath"
Write-Host 'A14_QTEC_ACPI_RESOURCE_CAPTURE=PASS'
