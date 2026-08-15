param(
    [string]$OutputDir = "$env:USERPROFILE\Downloads\a14-windows-firmware-dump"
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$source = @'
using System;
using System.Runtime.InteropServices;

public static class A14FirmwareTables
{
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint GetSystemFirmwareTable(
        uint FirmwareTableProviderSignature,
        uint FirmwareTableID,
        byte[] pFirmwareTableBuffer,
        uint BufferSize);

    public static uint FourCC(string s)
    {
        if (s == null || s.Length != 4)
            throw new ArgumentException("FourCC must be exactly four characters");
        return ((uint)(byte)s[0]) |
               ((uint)(byte)s[1] << 8) |
               ((uint)(byte)s[2] << 16) |
               ((uint)(byte)s[3] << 24);
    }

    public static byte[] GetAcpiTable(string signature)
    {
        uint provider = FourCC("ACPI");
        uint table = FourCC(signature);
        uint size = GetSystemFirmwareTable(provider, table, null, 0);
        if (size == 0)
            throw new System.ComponentModel.Win32Exception(
                Marshal.GetLastWin32Error(), "Unable to query ACPI table " + signature);

        byte[] data = new byte[size];
        uint actual = GetSystemFirmwareTable(provider, table, data, size);
        if (actual == 0)
            throw new System.ComponentModel.Win32Exception(
                Marshal.GetLastWin32Error(), "Unable to read ACPI table " + signature);
        if (actual != size)
            Array.Resize(ref data, (int)actual);
        return data;
    }
}
'@

if (-not ('A14FirmwareTables' -as [type])) {
    Add-Type -TypeDefinition $source -Language CSharp
}

Write-Host '===== A14 WINDOWS FIRMWARE / ASUS SCI DUMP ====='
Write-Host "output=$OutputDir"

$dsdtPath = Join-Path $OutputDir 'DSDT.aml'
$dsdt = [A14FirmwareTables]::GetAcpiTable('DSDT')
[IO.File]::WriteAllBytes($dsdtPath, $dsdt)
Write-Host "DSDT=$dsdtPath bytes=$($dsdt.Length)"

# Record the exact Windows ASUS System Control Interface device and driver.
$driverPath = Join-Path $OutputDir 'asus-system-control-interface.txt'
$drivers = Get-CimInstance Win32_PnPSignedDriver |
    Where-Object {
        $_.DeviceID -match 'ASUS2018|ATKACPI' -or
        $_.DeviceName -match 'ASUS System Control Interface|ATK'
    } |
    Select-Object DeviceName, DeviceID, Manufacturer, DriverProviderName,
                  DriverVersion, DriverDate, InfName, IsSigned
$drivers | Format-List | Out-String -Width 300 | Set-Content -Encoding UTF8 $driverPath
Write-Host "ASUS_SCI=$driverPath"

$pnpPath = Join-Path $OutputDir 'asus-pnp-devices.txt'
Get-CimInstance Win32_PnPEntity |
    Where-Object {
        $_.PNPDeviceID -match '^ACPI\\ASUS|^HID\\VID_0B05|^ACPI\\VEN_ASUS' -or
        $_.Name -match 'ASUS System Control|ASUS.*Keyboard|ASUS.*Hotkey'
    } |
    Select-Object Name, PNPDeviceID, Status, Service |
    Format-List | Out-String -Width 300 |
    Set-Content -Encoding UTF8 $pnpPath
Write-Host "ASUS_PNP=$pnpPath"

$systemPath = Join-Path $OutputDir 'system.txt'
@(
    "timestamp=$(Get-Date -Format o)"
    "computer=$env:COMPUTERNAME"
    "product=$((Get-CimInstance Win32_ComputerSystemProduct).Name)"
    "version=$((Get-CimInstance Win32_ComputerSystemProduct).Version)"
    "bios=$((Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion)"
    "windows=$([Environment]::OSVersion.VersionString)"
    "arch=$env:PROCESSOR_ARCHITECTURE"
) | Set-Content -Encoding UTF8 $systemPath
Write-Host "SYSTEM=$systemPath"

$hashPath = Join-Path $OutputDir 'SHA256SUMS.txt'
Get-ChildItem -File $OutputDir |
    Where-Object Name -ne 'SHA256SUMS.txt' |
    ForEach-Object {
        $h = Get-FileHash -Algorithm SHA256 $_.FullName
        "$($h.Hash.ToLowerInvariant())  $($_.Name)"
    } | Set-Content -Encoding ASCII $hashPath
Write-Host "HASHES=$hashPath"

$zip = "$OutputDir.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $OutputDir '*') -DestinationPath $zip
Write-Host "ZIP=$zip"
Write-Host 'A14_WINDOWS_FIRMWARE_DUMP=PASS'
