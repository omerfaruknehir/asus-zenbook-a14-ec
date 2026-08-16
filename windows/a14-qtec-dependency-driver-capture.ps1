param(
    [string]$OutputDir = "$env:USERPROFILE\Downloads\a14-qtec-dependency-driver-capture"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$targets = @(
    [pscustomobject]@{
        Name = 'PEP0'
        InstanceId = 'ACPI\VEN_QCOM&DEV_0C17&SUBSYS_CRD08380&REV_0086\2&daba3ff&0'
    },
    [pscustomobject]@{
        Name = 'GIO0'
        InstanceId = 'ACPI\QCOM0C0C\0'
    },
    [pscustomobject]@{
        Name = 'I2C9'
        InstanceId = 'ACPI\QCOM0C10\9'
    }
)

function Write-TextFile([string]$Path, [scriptblock]$Body) {
    try {
        (& $Body 2>&1 | Out-String -Width 1200).TrimEnd() |
            Set-Content -Encoding UTF8 -LiteralPath $Path
    }
    catch {
        ("ERROR: " + ($_ | Out-String -Width 1200)) |
            Set-Content -Encoding UTF8 -LiteralPath $Path
        throw
    }
}

function Get-PnpServiceName([string]$InstanceId) {
    $p = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_Service' -ErrorAction Stop
    if ($null -eq $p.Data) { return $null }
    return [string]$p.Data
}

function Convert-ServiceImagePath([string]$ImagePath) {
    if ([string]::IsNullOrWhiteSpace($ImagePath)) { return $null }

    $s = [Environment]::ExpandEnvironmentVariables($ImagePath.Trim())
    if ($s.StartsWith('\SystemRoot\', [StringComparison]::OrdinalIgnoreCase)) {
        $s = Join-Path $env:SystemRoot $s.Substring('\SystemRoot\'.Length)
    }
    elseif ($s.StartsWith('SystemRoot\', [StringComparison]::OrdinalIgnoreCase)) {
        $s = Join-Path $env:SystemRoot $s.Substring('SystemRoot\'.Length)
    }
    elseif ($s.StartsWith('system32\', [StringComparison]::OrdinalIgnoreCase)) {
        $s = Join-Path $env:SystemRoot $s
    }
    elseif ($s.StartsWith('\??\', [StringComparison]::OrdinalIgnoreCase)) {
        $s = $s.Substring('\??\'.Length)
    }

    $m = [regex]::Match($s, '(?i)^\s*"([^"]+\.sys)"')
    if ($m.Success) { return $m.Groups[1].Value }
    $m = [regex]::Match($s, '(?i)^\s*([^\s]+\.sys)')
    if ($m.Success) { return $m.Groups[1].Value }
    return $s.Trim('"')
}

function Copy-WithMetadata([string]$SourcePath, [string]$DestinationDir, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($SourcePath)) { return }
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        "NOT_FOUND=$SourcePath" | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $DestinationDir "$Label-not-found.txt")
        return
    }

    $dest = Join-Path $DestinationDir ([IO.Path]::GetFileName($SourcePath))
    Copy-Item -LiteralPath $SourcePath -Destination $dest -Force
    $item = Get-Item -LiteralPath $SourcePath
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $SourcePath
    @(
        "SOURCE=$SourcePath"
        "DEST=$dest"
        "SIZE=$($item.Length)"
        "SHA256=$($hash.Hash.ToLowerInvariant())"
        "FILE_VERSION=$($item.VersionInfo.FileVersion)"
        "PRODUCT_VERSION=$($item.VersionInfo.ProductVersion)"
        "COMPANY=$($item.VersionInfo.CompanyName)"
        "DESCRIPTION=$($item.VersionInfo.FileDescription)"
        "ORIGINAL_FILENAME=$($item.VersionInfo.OriginalFilename)"
    ) | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $DestinationDir "$Label-metadata.txt")
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an Administrator PowerShell.'
}

if (Test-Path -LiteralPath $OutputDir) {
    Remove-Item -LiteralPath $OutputDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
if (-not (Test-Path -LiteralPath $pnputil)) {
    throw "pnputil.exe not found: $pnputil"
}

Write-Host '===== A14 QTEC0001 DEPENDENCY DRIVER CAPTURE ====='
Write-Host "OUTPUT_DIR=$OutputDir"
Write-Host 'Read-only capture: no device/service state is changed.'

# Cache the signed-driver inventory once; querying it repeatedly is needlessly slow.
$signedDrivers = @(Get-CimInstance Win32_PnPSignedDriver)

$summary = New-Object System.Collections.Generic.List[string]
$summary.Add('A14 QTEC0001 Windows dependency-driver capture')
$summary.Add("CapturedAt=$([DateTimeOffset]::Now.ToString('o'))")
$summary.Add('')

foreach ($target in $targets) {
    $name = $target.Name
    $id = $target.InstanceId
    $dir = Join-Path $OutputDir $name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    Write-Host "===== $name ====="
    Write-Host "INSTANCE_ID=$id"

    $dev = Get-PnpDevice -InstanceId $id -ErrorAction Stop
    $serviceName = Get-PnpServiceName $id
    $summary.Add("[$name]")
    $summary.Add("InstanceId=$id")
    $summary.Add("Status=$($dev.Status)")
    $summary.Add("Class=$($dev.Class)")
    $summary.Add("FriendlyName=$($dev.FriendlyName)")
    $summary.Add("Service=$serviceName")

    Write-TextFile (Join-Path $dir 'pnputil.txt') {
        & $pnputil /enum-devices /instanceid $id `
            /deviceids /relations /services /stack /drivers /interfaces /properties /resources
    }
    Write-TextFile (Join-Path $dir 'devicetree.txt') {
        & $pnputil /enum-devicetree $id /connected /services /stack /drivers /interfaces
    }
    Write-TextFile (Join-Path $dir 'pnp-device.txt') {
        $dev | Format-List *
    }
    Write-TextFile (Join-Path $dir 'pnp-properties.txt') {
        Get-PnpDeviceProperty -InstanceId $id | Sort-Object KeyName | Format-List *
    }

    $signed = @($signedDrivers | Where-Object { $_.DeviceID -eq $id })
    Write-TextFile (Join-Path $dir 'signed-driver.txt') {
        $signed | Format-List *
    }

    $enumNative = "HKLM\SYSTEM\CurrentControlSet\Enum\$id"
    $enumReg = Join-Path $dir 'enum.reg'
    & reg.exe export $enumNative $enumReg /y *> (Join-Path $dir 'enum-reg-export.txt')

    if (-not [string]::IsNullOrWhiteSpace($serviceName)) {
        $svcNative = "HKLM\SYSTEM\CurrentControlSet\Services\$serviceName"
        $svcReg = Join-Path $dir 'service.reg'
        & reg.exe export $svcNative $svcReg /y *> (Join-Path $dir 'service-reg-export.txt')

        $svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"
        $svcProps = Get-ItemProperty -LiteralPath $svcKey -ErrorAction Stop
        Write-TextFile (Join-Path $dir 'service-registry.txt') {
            $svcProps | Format-List *
        }

        Write-TextFile (Join-Path $dir 'system-driver.txt') {
            Get-CimInstance Win32_SystemDriver -Filter "Name='$serviceName'" | Format-List *
        }

        $driverPath = $null
        if ($svcProps.PSObject.Properties.Name -contains 'ImagePath') {
            $driverPath = Convert-ServiceImagePath ([string]$svcProps.ImagePath)
        }
        $summary.Add("ImagePath=$driverPath")
        Copy-WithMetadata $driverPath $dir 'service-driver'
    }

    foreach ($sd in $signed) {
        if (-not [string]::IsNullOrWhiteSpace([string]$sd.InfName)) {
            $inf = Join-Path (Join-Path $env:SystemRoot 'INF') ([string]$sd.InfName)
            Copy-WithMetadata $inf $dir 'inf'
            $pnf = [IO.Path]::ChangeExtension($inf, '.pnf')
            if (Test-Path -LiteralPath $pnf -PathType Leaf) {
                Copy-WithMetadata $pnf $dir 'pnf'
            }
            $summary.Add("InfName=$($sd.InfName)")
            $summary.Add("DriverVersion=$($sd.DriverVersion)")
            $summary.Add("DriverProviderName=$($sd.DriverProviderName)")
        }
    }

    $summary.Add('')
}

# System-level context useful when matching PEP/QUP driver versions.
Write-TextFile (Join-Path $OutputDir 'system-summary.txt') {
    Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion, OsBuildNumber,
        BiosManufacturer, BiosVersion, BiosFirmwareType
}
Write-TextFile (Join-Path $OutputDir 'system-drivers-qcom.txt') {
    Get-CimInstance Win32_SystemDriver |
        Where-Object { $_.Name -match 'qcom|qc|pep|gpio|i2c|geni|qup' -or $_.PathName -match 'qcom|qc|pep|gpio|i2c|geni|qup' } |
        Sort-Object Name | Format-List Name,DisplayName,State,StartMode,PathName,ServiceType
}

$summary | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $OutputDir 'SUMMARY.txt')

$hashPath = Join-Path $OutputDir 'SHA256SUMS.txt'
Get-ChildItem -LiteralPath $OutputDir -File -Recurse |
    Where-Object { $_.FullName -ne $hashPath } |
    Sort-Object FullName |
    ForEach-Object {
        $h = Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName
        $relative = $_.FullName.Substring($OutputDir.Length).TrimStart('\')
        "$($h.Hash.ToLowerInvariant())  $relative"
    } | Set-Content -Encoding ASCII -LiteralPath $hashPath

$zipPath = "$OutputDir.zip"
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -Path (Join-Path $OutputDir '*') -DestinationPath $zipPath -Force

Write-Host "RESULT_DIR=$OutputDir"
Write-Host "RESULT_ZIP=$zipPath"
Write-Host 'A14_QTEC_DEPENDENCY_DRIVER_CAPTURE=PASS'
