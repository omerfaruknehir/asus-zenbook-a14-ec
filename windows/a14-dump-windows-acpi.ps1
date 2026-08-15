param(
    [string]$OutputDir = "$env:USERPROFILE\Downloads\a14-windows-firmware-dump"
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$source = @'
using System;
using System.ComponentModel;
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

    public static byte[] TryGetAcpiTable(string signature)
    {
        uint provider = FourCC("ACPI");
        uint table = FourCC(signature);
        uint size = GetSystemFirmwareTable(provider, table, null, 0);
        if (size == 0)
            return null;

        byte[] data = new byte[size];
        uint actual = GetSystemFirmwareTable(provider, table, data, size);
        if (actual == 0)
            return null;
        if (actual != size)
            Array.Resize(ref data, (int)actual);
        return data;
    }
}
'@

if (-not ('A14FirmwareTables' -as [type])) {
    Add-Type -TypeDefinition $source -Language CSharp
}

function Get-VerifiedAcpicaTool {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$ToolsDir,
        [Parameter(Mandatory=$true)][object]$Release
    )

    $existing = Get-Command $Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "ACPICA_TOOL_${Name}=PATH:$($existing.Source)"
        return $existing.Source
    }

    $asset = @($Release.assets | Where-Object { $_.name -eq $Name })[0]
    if (-not $asset) {
        throw "Official ACPICA release $($Release.tag_name) does not contain $Name"
    }
    if (-not $asset.digest -or $asset.digest -notmatch '^sha256:([0-9a-fA-F]{64})$') {
        throw "Official ACPICA asset $Name has no SHA-256 digest in the GitHub release metadata"
    }

    $expected = $Matches[1].ToLowerInvariant()
    $path = Join-Path $ToolsDir $Name
    if (Test-Path $path) {
        $current = (Get-FileHash -Algorithm SHA256 $path).Hash.ToLowerInvariant()
        if ($current -eq $expected) {
            Write-Host "ACPICA_TOOL_${Name}=CACHED:$path"
            return $path
        }
        Remove-Item -Force $path
    }

    Write-Host "Downloading verified official ACPICA $Name release=$($Release.tag_name)"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $path -UseBasicParsing
    $actual = (Get-FileHash -Algorithm SHA256 $path).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        Remove-Item -Force $path -ErrorAction SilentlyContinue
        throw "SHA-256 mismatch for $Name expected=$expected actual=$actual"
    }
    Write-Host "ACPICA_TOOL_${Name}=DOWNLOADED:$path sha256=$actual"
    return $path
}

function Invoke-NativeCaptured {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string[]]$ArgumentList,
        [Parameter(Mandatory=$true)][string]$LogBase
    )

    # Windows PowerShell 5.1 turns text written by native programs to stderr
    # into ErrorRecord objects. With $ErrorActionPreference='Stop' that makes
    # normal ACPICA diagnostics (for example iasl's "File appears to be binary")
    # abort the script. Run the native tool through Start-Process instead and
    # capture stdout/stderr as ordinary files.
    $stdout = "$LogBase.stdout.log"
    $stderr = "$LogBase.stderr.log"
    Remove-Item -Force $stdout,$stderr -ErrorAction SilentlyContinue

    $quoted = @()
    foreach ($arg in $ArgumentList) {
        if ($arg -match '[\s"]') {
            $quoted += ('"' + ($arg -replace '"','\"') + '"')
        } else {
            $quoted += $arg
        }
    }

    $p = Start-Process -FilePath $FilePath `
        -ArgumentList $quoted `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr `
        -Wait -PassThru

    $lines = @()
    if (Test-Path $stdout) { $lines += @(Get-Content $stdout) }
    if (Test-Path $stderr) { $lines += @(Get-Content $stderr) }
    $combined = "$LogBase.log"
    $lines | Set-Content -Encoding UTF8 $combined
    if ($lines.Count -gt 0) { $lines | Out-Host }

    [pscustomobject]@{
        ExitCode = $p.ExitCode
        Log      = $combined
        Stdout   = $stdout
        Stderr   = $stderr
    }
}

Write-Host '===== A14 WINDOWS FIRMWARE / ASUS SCI DUMP ====='
Write-Host "output=$OutputDir"

# Record the exact Windows ASUS System Control Interface device and driver even
# if ACPI table extraction fails later.
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

$wmiPath = Join-Path $OutputDir 'asus-atk-wmi.txt'
try {
    $klass = Get-CimClass -Namespace root/wmi -ClassName AsusAtkWmi_WMNB -ErrorAction Stop
    $inst = @(Get-CimInstance -Namespace root/wmi -ClassName AsusAtkWmi_WMNB -ErrorAction Stop)
    @(
        '===== CLASS ====='
        ($klass | Format-List * | Out-String -Width 300)
        '===== METHODS ====='
        ($klass.CimClassMethods | Format-List * | Out-String -Width 300)
        '===== INSTANCES ====='
        ($inst | Format-List * | Out-String -Width 300)
    ) | Set-Content -Encoding UTF8 $wmiPath
}
catch {
    "AsusAtkWmi_WMNB unavailable: $($_.Exception.Message)" | Set-Content -Encoding UTF8 $wmiPath
}
Write-Host "ASUS_WMI=$wmiPath"

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

# First try the normal Win32 firmware-table provider. Some Windows/firmware
# combinations do not expose DSDT as a directly retrievable ACPI table even
# though the AML is loaded by Windows, so failure here is not fatal.
$dsdtPath = Join-Path $OutputDir 'DSDT.aml'
$apiDsdt = [A14FirmwareTables]::TryGetAcpiTable('DSDT')
if ($null -ne $apiDsdt -and $apiDsdt.Length -gt 36) {
    [IO.File]::WriteAllBytes($dsdtPath, $apiDsdt)
    Write-Host "DSDT_WIN32_API=$dsdtPath bytes=$($apiDsdt.Length)"
} else {
    Write-Host 'DSDT_WIN32_API=UNAVAILABLE; using ACPICA acpidump fallback'
}

$needAcpica = -not (Test-Path $dsdtPath)
if ($needAcpica) {
    $toolsDir = Join-Path $OutputDir 'tools'
    New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null

    # Pull release metadata from the official ACPICA GitHub project, then verify
    # each downloaded executable against the SHA-256 digest published in that
    # release metadata before executing it.
    $headers = @{ 'User-Agent' = 'asus-zenbook-a14-ec-windows-probe' }
    $release = Invoke-RestMethod -Headers $headers -Uri 'https://api.github.com/repos/acpica/acpica/releases/latest'
    "ACPICA_RELEASE=$($release.tag_name)" | Add-Content -Encoding UTF8 $systemPath

    $acpidump = Get-VerifiedAcpicaTool -Name 'acpidump.exe' -ToolsDir $toolsDir -Release $release
    $iasl = Get-VerifiedAcpicaTool -Name 'iasl.exe' -ToolsDir $toolsDir -Release $release

    $tablesDir = Join-Path $OutputDir 'acpi-tables'
    New-Item -ItemType Directory -Force -Path $tablesDir | Out-Null
    Push-Location $tablesDir
    try {
        Write-Host 'Dumping binary ACPI tables with ACPICA acpidump...'
        $dumpRun = Invoke-NativeCaptured -FilePath $acpidump -ArgumentList @('-b') -LogBase (Join-Path $OutputDir 'acpidump')
        if ($dumpRun.ExitCode -ne 0) {
            throw "ACPICA acpidump exited with code $($dumpRun.ExitCode); see $($dumpRun.Log)"
        }

        $dsdtDat = Get-ChildItem -File -Filter 'dsdt*.dat' | Sort-Object Name | Select-Object -First 1
        if (-not $dsdtDat) {
            throw 'ACPICA acpidump completed but no dsdt*.dat file was produced'
        }
        Copy-Item -Force $dsdtDat.FullName $dsdtPath
        Write-Host "DSDT_ACPIDUMP=$dsdtPath bytes=$((Get-Item $dsdtPath).Length)"

        # Disassemble the DSDT itself for immediate inspection. Keep all binary
        # tables in the ZIP as well so we can redo an external-table-aware
        # disassembly later if references cross into SSDTs.
        $dslBase = Join-Path $OutputDir 'DSDT'
        $iaslRun = Invoke-NativeCaptured -FilePath $iasl -ArgumentList @('-p', $dslBase, '-d', $dsdtDat.FullName) -LogBase (Join-Path $OutputDir 'iasl-dsdt')
        $dslPath = "$dslBase.dsl"
        if (Test-Path $dslPath) {
            Write-Host "DSDT_DSL=$dslPath"
            if ($iaslRun.ExitCode -ne 0) {
                Write-Warning "iasl exited with code $($iaslRun.ExitCode), but DSDT.dsl was produced; preserving it and all binary tables."
            }
        } else {
            Write-Warning "iasl did not produce DSDT.dsl (exit=$($iaslRun.ExitCode)); binary DSDT and all tables are still preserved."
        }
    }
    finally {
        Pop-Location
    }
} else {
    # A prior interrupted run may already have DSDT.aml. If DSDT.dsl is absent,
    # don't silently skip the useful disassembly; reuse verified cached tools and
    # the previously dumped dsdt*.dat when available.
    $dslPath = Join-Path $OutputDir 'DSDT.dsl'
    $tablesDir = Join-Path $OutputDir 'acpi-tables'
    $dsdtDat = if (Test-Path $tablesDir) { Get-ChildItem -Path $tablesDir -File -Filter 'dsdt*.dat' | Sort-Object Name | Select-Object -First 1 } else { $null }
    if (-not (Test-Path $dslPath) -and $dsdtDat) {
        $toolsDir = Join-Path $OutputDir 'tools'
        New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
        $headers = @{ 'User-Agent' = 'asus-zenbook-a14-ec-windows-probe' }
        $release = Invoke-RestMethod -Headers $headers -Uri 'https://api.github.com/repos/acpica/acpica/releases/latest'
        $iasl = Get-VerifiedAcpicaTool -Name 'iasl.exe' -ToolsDir $toolsDir -Release $release
        $dslBase = Join-Path $OutputDir 'DSDT'
        $iaslRun = Invoke-NativeCaptured -FilePath $iasl -ArgumentList @('-p', $dslBase, '-d', $dsdtDat.FullName) -LogBase (Join-Path $OutputDir 'iasl-dsdt')
        if (Test-Path $dslPath) {
            Write-Host "DSDT_DSL=$dslPath"
        } else {
            Write-Warning "iasl did not produce DSDT.dsl (exit=$($iaslRun.ExitCode)); continuing with binary tables."
        }
    }
}

$hashPath = Join-Path $OutputDir 'SHA256SUMS.txt'
Get-ChildItem -File -Recurse $OutputDir |
    Where-Object FullName -ne $hashPath |
    ForEach-Object {
        $h = Get-FileHash -Algorithm SHA256 $_.FullName
        $rel = $_.FullName.Substring($OutputDir.Length).TrimStart('\')
        "$($h.Hash.ToLowerInvariant())  $rel"
    } | Set-Content -Encoding ASCII $hashPath
Write-Host "HASHES=$hashPath"

$zip = "$OutputDir.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $OutputDir '*') -DestinationPath $zip
Write-Host "ZIP=$zip"
Write-Host 'A14_WINDOWS_FIRMWARE_DUMP=PASS'
