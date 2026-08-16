param(
    [string]$OutputDir = "$env:USERPROFILE\Downloads\a14-qtec-hidi2c-transport"
)

$ErrorActionPreference = 'Stop'

function Write-TextFile {
    param([string]$Path, [object]$Value)
    $Value | Out-String -Width 600 | Set-Content -Encoding UTF8 $Path
}

function Get-DevicePropertyValue {
    param([string]$InstanceId, [string]$KeyName)
    try {
        $p = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $KeyName -ErrorAction Stop
        return $p.Data
    }
    catch {
        return $null
    }
}

function Add-UniqueString {
    param(
        [System.Collections.Generic.HashSet[string]]$Set,
        [object]$Value
    )
    if ($null -eq $Value) { return }
    foreach ($item in @($Value)) {
        if ($null -ne $item) {
            $text = [string]$item
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                [void]$Set.Add($text.Trim())
            }
        }
    }
}

function Resolve-ServiceImagePath {
    param([string]$ImagePath)
    if ([string]::IsNullOrWhiteSpace($ImagePath)) { return $null }

    $value = $ImagePath.Trim().Trim('"')
    if ($value -match '^\\SystemRoot\\') {
        $value = Join-Path $env:windir $value.Substring('\SystemRoot\'.Length)
    }
    elseif ($value -match '^System32\\') {
        $value = Join-Path $env:windir $value
    }
    else {
        $value = [Environment]::ExpandEnvironmentVariables($value)
    }

    # Service ImagePath can contain command-line arguments. Kernel drivers do
    # not normally do so, but trim them without damaging a quoted path.
    if (-not (Test-Path -LiteralPath $value)) {
        $m = [regex]::Match($value, '^(.*?\.sys)(?:\s+.*)?$', 'IgnoreCase')
        if ($m.Success) { $value = $m.Groups[1].Value }
    }
    return $value
}

function Copy-WithMetadata {
    param(
        [string]$Source,
        [string]$DestinationDir,
        [string]$Label,
        [System.Collections.Generic.List[string]]$Manifest
    )
    if ([string]::IsNullOrWhiteSpace($Source) -or -not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        $Manifest.Add("MISSING`t$Label`t$Source")
        return
    }

    New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null
    $name = Split-Path -Leaf $Source
    $dest = Join-Path $DestinationDir $name
    Copy-Item -LiteralPath $Source -Destination $dest -Force

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $dest).Hash.ToLowerInvariant()
    $item = Get-Item -LiteralPath $dest
    $version = $item.VersionInfo.FileVersion
    $product = $item.VersionInfo.ProductVersion
    $Manifest.Add("FILE`t$Label`t$Source`t$($item.Length)`t$hash`tFileVersion=$version`tProductVersion=$product")
}

function Collect-Service {
    param(
        [string]$ServiceName,
        [string]$ServicesDir,
        [string]$BinariesDir,
        [System.Collections.Generic.List[string]]$Manifest
    )
    if ([string]::IsNullOrWhiteSpace($ServiceName)) { return }
    $safe = $ServiceName -replace '[^A-Za-z0-9_.-]', '_'
    $serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    $txt = Join-Path $ServicesDir "$safe.txt"

    try {
        $props = Get-ItemProperty -LiteralPath $serviceKey -ErrorAction Stop
        $props | Format-List * | Out-String -Width 600 | Set-Content -Encoding UTF8 $txt
        $image = Resolve-ServiceImagePath ([string]$props.ImagePath)
        if ($image) {
            Copy-WithMetadata -Source $image -DestinationDir $BinariesDir -Label "service:$ServiceName" -Manifest $Manifest
        }
    }
    catch {
        "SERVICE=$ServiceName`r`nERROR=$($_.Exception.Message)" | Set-Content -Encoding UTF8 $txt
    }

    try {
        (& sc.exe qc $ServiceName 2>&1) | Set-Content -Encoding UTF8 (Join-Path $ServicesDir "$safe-sc-qc.txt")
    }
    catch {}
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw 'Run this collector from an Administrator PowerShell. It does not modify drivers or services, but DriverStore/service metadata access may otherwise be incomplete.'
}

if (Test-Path -LiteralPath $OutputDir) {
    Remove-Item -LiteralPath $OutputDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$DevicesDir = Join-Path $OutputDir 'devices'
$ServicesDir = Join-Path $OutputDir 'services'
$BinariesDir = Join-Path $OutputDir 'binaries'
$InfDir = Join-Path $OutputDir 'inf'
$ExportsDir = Join-Path $OutputDir 'driver-exports'
New-Item -ItemType Directory -Force -Path $DevicesDir,$ServicesDir,$BinariesDir,$InfDir,$ExportsDir | Out-Null

$manifest = New-Object 'System.Collections.Generic.List[string]'
$services = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$infs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$deviceIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

Write-Host '===== A14 QTEC0001 HID-over-I2C TRANSPORT CAPTURE ====='
Write-Host "output=$OutputDir"
Write-Host 'MODE=READ_ONLY (no service stop/start, no device disable/rebind, no registry writes)'

# OS / firmware identity. This lets us tie the exact inbox hidi2c.sys binary to
# the Windows build on which Fn-switch is known to work.
$os = Get-CimInstance Win32_OperatingSystem
$bios = Get-CimInstance Win32_BIOS
$cs = Get-CimInstance Win32_ComputerSystem
$base = Get-CimInstance Win32_BaseBoard
Write-TextFile (Join-Path $OutputDir 'system.txt') @(
    $os | Select-Object Caption,Version,BuildNumber,OSArchitecture,InstallDate,LastBootUpTime
    $bios | Select-Object Manufacturer,SMBIOSBIOSVersion,Version,ReleaseDate
    $cs | Select-Object Manufacturer,Model,SystemType
    $base | Select-Object Manufacturer,Product,Version,SerialNumber
)
try { (& cmd.exe /c ver 2>&1) | Set-Content -Encoding UTF8 (Join-Path $OutputDir 'cmd-ver.txt') } catch {}

# Capture every present ACPI/HID node whose instance ID contains QTEC0001. The
# physical node is normally ACPI\QTEC0001\2; HID top-level collections appear
# below it and are useful for comparing the exact Windows stack to Linux.
$allPresent = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)
$qtec = @($allPresent | Where-Object { $_.InstanceId -match 'QTEC0001' })
if ($qtec.Count -eq 0) {
    throw 'No present PnP device containing QTEC0001 was found. Run this on the A14 Windows installation where Fn+Esc works.'
}

foreach ($dev in $qtec) { [void]$deviceIds.Add($dev.InstanceId) }

# Walk parent links from every QTEC node so the SPB/I2C host controller and its
# driver are captured too. This avoids assuming a Qualcomm controller service
# name that can change between ASUS driver releases.
$frontier = New-Object 'System.Collections.Generic.Queue[string]'
foreach ($id in @($deviceIds)) { $frontier.Enqueue($id) }
$depth = @{}
foreach ($id in @($deviceIds)) { $depth[$id] = 0 }
while ($frontier.Count -gt 0) {
    $id = $frontier.Dequeue()
    $d = [int]$depth[$id]
    if ($d -ge 8) { continue }
    $parent = Get-DevicePropertyValue -InstanceId $id -KeyName 'DEVPKEY_Device_Parent'
    if ($parent -and -not $deviceIds.Contains([string]$parent)) {
        [void]$deviceIds.Add([string]$parent)
        $depth[[string]$parent] = $d + 1
        $frontier.Enqueue([string]$parent)
    }
}

$deviceSummary = New-Object 'System.Collections.Generic.List[string]'
$index = 0
foreach ($id in @($deviceIds)) {
    $index++
    $safe = ('{0:D2}-' -f $index) + ($id -replace '[\\/:*?"<>|&]', '_')
    $dir = Join-Path $DevicesDir $safe
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $pnp = Get-PnpDevice -InstanceId $id -ErrorAction SilentlyContinue
    $parent = Get-DevicePropertyValue -InstanceId $id -KeyName 'DEVPKEY_Device_Parent'
    $service = Get-DevicePropertyValue -InstanceId $id -KeyName 'DEVPKEY_Device_Service'
    $upper = Get-DevicePropertyValue -InstanceId $id -KeyName 'DEVPKEY_Device_UpperFilters'
    $lower = Get-DevicePropertyValue -InstanceId $id -KeyName 'DEVPKEY_Device_LowerFilters'
    $inf = Get-DevicePropertyValue -InstanceId $id -KeyName 'DEVPKEY_Device_InfPath'
    $driverKey = Get-DevicePropertyValue -InstanceId $id -KeyName 'DEVPKEY_Device_Driver'
    $hardwareIds = Get-DevicePropertyValue -InstanceId $id -KeyName 'DEVPKEY_Device_HardwareIds'
    $compatibleIds = Get-DevicePropertyValue -InstanceId $id -KeyName 'DEVPKEY_Device_CompatibleIds'

    $deviceSummary.Add("===== $id =====")
    $deviceSummary.Add("Class=$($pnp.Class)")
    $deviceSummary.Add("FriendlyName=$($pnp.FriendlyName)")
    $deviceSummary.Add("Status=$($pnp.Status)")
    $deviceSummary.Add("Parent=$parent")
    $deviceSummary.Add("Service=$service")
    $deviceSummary.Add("UpperFilters=$(@($upper) -join ',')")
    $deviceSummary.Add("LowerFilters=$(@($lower) -join ',')")
    $deviceSummary.Add("InfPath=$inf")
    $deviceSummary.Add("DriverKey=$driverKey")
    $deviceSummary.Add("HardwareIds=$(@($hardwareIds) -join ';')")
    $deviceSummary.Add("CompatibleIds=$(@($compatibleIds) -join ';')")
    $deviceSummary.Add('')

    Add-UniqueString -Set $services -Value $service
    Add-UniqueString -Set $services -Value $upper
    Add-UniqueString -Set $services -Value $lower
    Add-UniqueString -Set $infs -Value $inf

    try {
        Get-PnpDeviceProperty -InstanceId $id -ErrorAction Stop |
            Select-Object KeyName,Type,Data |
            Format-List | Out-String -Width 700 |
            Set-Content -Encoding UTF8 (Join-Path $dir 'properties.txt')
    }
    catch {
        "ERROR=$($_.Exception.Message)" | Set-Content -Encoding UTF8 (Join-Path $dir 'properties.txt')
    }

    try {
        (& pnputil.exe /enum-devices /instanceid $id /drivers /stack /properties 2>&1) |
            Set-Content -Encoding UTF8 (Join-Path $dir 'pnputil.txt')
    }
    catch {}

    try {
        $escaped = $id.Replace("'", "''")
        $signed = @(Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceID='$escaped'" -ErrorAction Stop)
        $signed | Select-Object DeviceName,DeviceID,Manufacturer,DriverProviderName,DriverVersion,DriverDate,
            InfName,DriverName,IsSigned,Signer,HardWareID,CompatID |
            Format-List | Out-String -Width 700 |
            Set-Content -Encoding UTF8 (Join-Path $dir 'signed-driver.txt')
        foreach ($s in $signed) {
            Add-UniqueString -Set $infs -Value $s.InfName
        }
    }
    catch {}

    try {
        (& reg.exe query "HKLM\SYSTEM\CurrentControlSet\Enum\$id" /s 2>&1) |
            Set-Content -Encoding UTF8 (Join-Path $dir 'enum-registry.txt')
    }
    catch {}
}
$deviceSummary | Set-Content -Encoding UTF8 (Join-Path $OutputDir 'device-chain-summary.txt')

# Also capture the complete set of present HID class nodes and their parent IDs.
# This makes it possible to identify the exact FF31:0076 top-level collection
# without relying on a friendly name.
$hidSummary = New-Object 'System.Collections.Generic.List[string]'
foreach ($dev in @($allPresent | Where-Object { $_.InstanceId -match '^HID\\' })) {
    $parent = Get-DevicePropertyValue -InstanceId $dev.InstanceId -KeyName 'DEVPKEY_Device_Parent'
    $service = Get-DevicePropertyValue -InstanceId $dev.InstanceId -KeyName 'DEVPKEY_Device_Service'
    $hardware = Get-DevicePropertyValue -InstanceId $dev.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds'
    if ($dev.InstanceId -match 'QTEC0001' -or $parent -match 'QTEC0001' -or (@($hardware) -join ';') -match '0B05|QTEC0001') {
        $hidSummary.Add("InstanceId=$($dev.InstanceId)")
        $hidSummary.Add("FriendlyName=$($dev.FriendlyName)")
        $hidSummary.Add("Class=$($dev.Class)")
        $hidSummary.Add("Parent=$parent")
        $hidSummary.Add("Service=$service")
        $hidSummary.Add("HardwareIds=$(@($hardware) -join ';')")
        $hidSummary.Add('')
        Add-UniqueString -Set $services -Value $service
    }
}
$hidSummary | Set-Content -Encoding UTF8 (Join-Path $OutputDir 'related-hid-nodes.txt')

# Always include the known Windows inbox HID-over-I2C transport and adjacent HID
# class binaries even if a PnP property reports a different service alias.
$knownBinaries = @(
    'hidi2c.sys',
    'hidclass.sys',
    'hidparse.sys',
    'mshidkmdf.sys',
    'kbdhid.sys',
    'kbdclass.sys',
    'SpbCx.sys',
    'Wdf01000.sys'
)
foreach ($name in $knownBinaries) {
    Copy-WithMetadata -Source (Join-Path $env:windir "System32\drivers\$name") -DestinationDir $BinariesDir -Label 'known-inbox' -Manifest $manifest
}

# Enumerated device services/filters include the physical HIDI2C service and the
# I2C/SPB host-controller service. Capture their complete service registry keys
# and exact loaded .sys images.
foreach ($service in @($services)) {
    Collect-Service -ServiceName $service -ServicesDir $ServicesDir -BinariesDir $BinariesDir -Manifest $manifest
}

# Explicitly capture common service names in case the PnP property surface does
# not expose an inbox lower transport service on this Windows build.
foreach ($service in @('hidi2c','HidUsb','HidIr','HidBth','mshidkmdf','kbdhid','SpbCx')) {
    if (-not $services.Contains($service)) {
        Collect-Service -ServiceName $service -ServicesDir $ServicesDir -BinariesDir $BinariesDir -Manifest $manifest
    }
}

# Collect INF files and export every package identified by the physical node,
# HID collections, and parent controller. hidi2c.inf is included explicitly.
Add-UniqueString -Set $infs -Value 'hidi2c.inf'
foreach ($inf in @($infs)) {
    $leaf = Split-Path -Leaf $inf
    if ([string]::IsNullOrWhiteSpace($leaf)) { continue }
    $src = Join-Path $env:windir "INF\$leaf"
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $InfDir $leaf) -Force
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $src).Hash.ToLowerInvariant()
        $manifest.Add("INF`t$src`t$hash")
    }

    $dest = Join-Path $ExportsDir ([IO.Path]::GetFileNameWithoutExtension($leaf))
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    try {
        (& pnputil.exe /export-driver $leaf $dest 2>&1) |
            Set-Content -Encoding UTF8 (Join-Path $dest 'export-log.txt')
    }
    catch {
        "ERROR=$($_.Exception.Message)" | Set-Content -Encoding UTF8 (Join-Path $dest 'export-log.txt')
    }
}

# SetupAPI records the exact install/ranking of the physical QTEC device and its
# transport. Keep a focused context dump rather than copying an arbitrarily
# large system log.
$setupLog = Join-Path $env:windir 'INF\setupapi.dev.log'
if (Test-Path -LiteralPath $setupLog) {
    try {
        Select-String -LiteralPath $setupLog -Pattern 'QTEC0001|hidi2c|0B05.*0220' -Context 35,90 |
            Out-String -Width 700 |
            Set-Content -Encoding UTF8 (Join-Path $OutputDir 'setupapi-qtec-hidi2c.txt')
    }
    catch {}
}

try {
    (& driverquery.exe /v /fo list 2>&1) | Set-Content -Encoding UTF8 (Join-Path $OutputDir 'driverquery.txt')
}
catch {}

try {
    (& pnputil.exe /enum-devices /class HIDClass /connected /drivers /stack /properties 2>&1) |
        Set-Content -Encoding UTF8 (Join-Path $OutputDir 'pnputil-hidclass-connected.txt')
}
catch {}

# Final recursive hashes make the archive auditable after upload.
$manifest | Set-Content -Encoding UTF8 (Join-Path $OutputDir 'transport-manifest.txt')
$hashPath = Join-Path $OutputDir 'SHA256SUMS.txt'
Get-ChildItem -LiteralPath $OutputDir -File -Recurse |
    Where-Object { $_.FullName -ne $hashPath } |
    Sort-Object FullName |
    ForEach-Object {
        $h = Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName
        $rel = $_.FullName.Substring($OutputDir.Length).TrimStart('\')
        "$($h.Hash.ToLowerInvariant())  $rel"
    } | Set-Content -Encoding ASCII $hashPath

$zip = "$OutputDir.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $OutputDir '*') -DestinationPath $zip -CompressionLevel Optimal

Write-Host "QTEC_DEVICE_COUNT=$($qtec.Count)"
Write-Host "CHAIN_DEVICE_COUNT=$($deviceIds.Count)"
Write-Host "SERVICE_COUNT=$($services.Count)"
Write-Host "INF_COUNT=$($infs.Count)"
Write-Host "HASHES=$hashPath"
Write-Host "ZIP=$zip"
Write-Host 'A14_QTEC_HIDI2C_TRANSPORT_CAPTURE=PASS'
