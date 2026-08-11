#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputRoot = "$env:USERPROFILE\Desktop"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Static/read-only exporter for the Qualcomm Power Engine Plug-in device used as
# a dependency provider by CAMP/QCOM0C32. The only mutations are creation of the
# report directory and pnputil /export-driver copying the already-installed
# driver package. No PnP state, power state, camera state, or hardware register
# is changed.

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Save-Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )
    try {
        & $Command 2>&1 | Out-File -LiteralPath $Path -Encoding utf8 -Width 8192
    }
    catch {
        @(
            'collection_status=failed'
            "exception=$($_.Exception.GetType().FullName)"
            "message=$($_.Exception.Message)"
        ) | Out-File -LiteralPath $Path -Encoding utf8 -Width 8192
    }
}

if (-not (Test-Administrator)) {
    throw 'Run this script from an elevated Windows PowerShell window.'
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $OutputRoot "A14-QCOM0C17-PEP-Export-$stamp"
New-Item -ItemType Directory -Force -Path $output | Out-Null

@(
    "collected_at=$((Get-Date).ToString('o'))"
    "computer_name=$env:COMPUTERNAME"
    'target=ACPI\VEN_QCOM&DEV_0C17*'
    'operation=static-read-only-driver-export'
    'pnp_state_changed=false'
    'device_restarted=false'
    'power_state_changed=false'
    'camera_state_changed=false'
    'platform_ioctl_sent=false'
    'hardware_register_access=false'
    'direct_cpas_mmio=false'
    'ssc_contacted=false'
) | Out-File -LiteralPath (Join-Path $output 'EXPORT-INFO.txt') -Encoding utf8 -Width 8192

$devices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object {
    $_.InstanceId -like 'ACPI\VEN_QCOM&DEV_0C17*'
})
if ($devices.Count -ne 1) {
    throw "Expected exactly one present QCOM0C17 PEP device, found $($devices.Count)."
}
$device = $devices[0]
$instance = [string]$device.InstanceId

$device | Format-List * | Out-File -LiteralPath (Join-Path $output 'qcom0c17-device.txt') -Encoding utf8 -Width 8192
Save-Text -Path (Join-Path $output 'qcom0c17-pnp-properties.txt') -Command {
    Get-PnpDeviceProperty -InstanceId $instance | Sort-Object KeyName | Format-List KeyName,Type,Data
}
Save-Text -Path (Join-Path $output 'qcom0c17-pnputil.txt') -Command {
    pnputil.exe /enum-devices /instanceid $instance /properties /drivers
}

$pnpEntity = Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -eq $instance } | Select-Object -First 1
if ($null -ne $pnpEntity) {
    $pnpEntity | Format-List * | Out-File -LiteralPath (Join-Path $output 'qcom0c17-cim-pnpentity.txt') -Encoding utf8 -Width 8192
}

$infProperty = Get-PnpDeviceProperty -InstanceId $instance -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction Stop
$publishedInf = [string]$infProperty.Data
if ([string]::IsNullOrWhiteSpace($publishedInf)) {
    throw 'QCOM0C17 has no DEVPKEY_Device_DriverInfPath.'
}

$serviceName = ''
if ($null -ne $pnpEntity -and $null -ne $pnpEntity.Service) {
    $serviceName = [string]$pnpEntity.Service
}
if ([string]::IsNullOrWhiteSpace($serviceName)) {
    try {
        $serviceProp = Get-PnpDeviceProperty -InstanceId $instance -KeyName 'DEVPKEY_Device_Service' -ErrorAction Stop
        if ($null -ne $serviceProp.Data) { $serviceName = [string]$serviceProp.Data }
    }
    catch { }
}

@(
    "instance_id=$instance"
    "published_inf=$publishedInf"
    "service=$serviceName"
) | Out-File -LiteralPath (Join-Path $output 'qcom0c17-identity.txt') -Encoding utf8 -Width 8192

$windowsInf = Join-Path $env:windir (Join-Path 'INF' $publishedInf)
if (Test-Path -LiteralPath $windowsInf -PathType Leaf) {
    Copy-Item -LiteralPath $windowsInf -Destination (Join-Path $output $publishedInf) -Force
}

$driverExport = Join-Path $output 'driver-package'
New-Item -ItemType Directory -Force -Path $driverExport | Out-Null
$pnputilExportLog = Join-Path $output 'pnputil-export-driver.txt'
$pnputilOutput = & pnputil.exe /export-driver $publishedInf $driverExport 2>&1
$pnputilStatus = $LASTEXITCODE
$pnputilOutput | Out-File -LiteralPath $pnputilExportLog -Encoding utf8 -Width 8192
if ($pnputilStatus -ne 0) {
    throw "pnputil /export-driver failed with exit code $pnputilStatus."
}

Save-Text -Path (Join-Path $output 'driver-package-files.txt') -Command {
    Get-ChildItem -LiteralPath $driverExport -Recurse -File |
        Sort-Object FullName |
        Select-Object FullName,Length,LastWriteTime
}

$infFiles = @(Get-ChildItem -LiteralPath $driverExport -Recurse -File -Filter '*.inf')
foreach ($inf in $infFiles) {
    $safe = $inf.Name
    Copy-Item -LiteralPath $inf.FullName -Destination (Join-Path $output "exported-$safe") -Force
}

if (-not [string]::IsNullOrWhiteSpace($serviceName)) {
    $serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"
    Save-Text -Path (Join-Path $output 'pep-service-registry.txt') -Command {
        if (Test-Path -LiteralPath $serviceKey) {
            Get-ItemProperty -LiteralPath $serviceKey | Format-List *
        }
        else {
            "service_registry_key_missing=$serviceKey"
        }
    }
}
else {
    'service=unresolved' | Out-File -LiteralPath (Join-Path $output 'pep-service-registry.txt') -Encoding utf8
}

# Preserve and fingerprint every PE image in this one exported package. This
# avoids guessing the PEP binary name from the published INF name.
$peFiles = @(Get-ChildItem -LiteralPath $driverExport -Recurse -File | Where-Object {
    $_.Extension -in @('.sys','.dll','.exe')
})
$hashRows = @()
foreach ($file in $peFiles) {
    $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
    $sig = Get-AuthenticodeSignature -LiteralPath $file.FullName
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($file.FullName)
    $hashRows += [pscustomobject]@{
        Name = $file.Name
        Path = $file.FullName
        Length = $file.Length
        SHA256 = $hash.Hash
        SignatureStatus = $sig.Status
        Signer = if ($null -ne $sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
        FileVersion = $version.FileVersion
        ProductName = $version.ProductName
        FileDescription = $version.FileDescription
    }
}
$hashRows | Format-List * | Out-File -LiteralPath (Join-Path $output 'pep-binary-identities.txt') -Encoding utf8 -Width 8192

# Extract high-signal printable strings with PowerShell only, so the collector
# has no dependency on Sysinternals/Visual Studio. This is static file reading.
foreach ($file in $peFiles) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $ascii = [Text.Encoding]::ASCII.GetString($bytes)
    $matches = [regex]::Matches($ascii, '[ -~]{6,}') | ForEach-Object { $_.Value }
    $matches | Select-String -Pattern 'PEP|PoFx|DPM|Component|Power|F0|Idle|Active|Clock|GDSC|RPMh|SCM|GPIO|CAMP|CAM|QCOM|Resource|Work' -SimpleMatch:$false |
        ForEach-Object { $_.Line } |
        Sort-Object -Unique |
        Out-File -LiteralPath (Join-Path $output ("strings-{0}.txt" -f $file.Name)) -Encoding utf8 -Width 8192
}

@(
    "completed_at=$((Get-Date).ToString('o'))"
    "instance_id=$instance"
    "published_inf=$publishedInf"
    "service=$serviceName"
    "pe_image_count=$($peFiles.Count)"
    'driver_package_exported=true'
    'pnp_state_changed=false'
    'device_restarted=false'
    'power_state_changed=false'
    'camera_state_changed=false'
    'platform_ioctl_sent=false'
    'hardware_register_access=false'
    'direct_cpas_mmio=false'
    'ssc_contacted=false'
) | Out-File -LiteralPath (Join-Path $output 'EXPORT-RESULT.txt') -Encoding utf8 -Width 8192

$zip = "$output.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -LiteralPath $output -DestinationPath $zip -CompressionLevel Optimal

Write-Host ''
Write-Host "QCOM0C17 PEP export: $output"
Write-Host "Archive:             $zip"
Write-Host 'No device/PnP/power/camera hardware state was changed by this exporter.' -ForegroundColor Green
