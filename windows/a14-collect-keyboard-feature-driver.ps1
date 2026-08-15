param(
    [string]$OutputDir = "$env:USERPROFILE\Downloads\a14-keyboard-feature-driver"
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Write-Host '===== A14 WINDOWS KEYBOARD FEATURE DRIVER CAPTURE ====='
Write-Host "output=$OutputDir"

$targets = @(Get-CimInstance Win32_PnPSignedDriver | Where-Object {
    $_.DeviceID -match 'ASUH2024' -or
    $_.DeviceName -match 'ASUS Keyboard Feature|ASUS Consumer'
})

$targetsPath = Join-Path $OutputDir 'signed-drivers.txt'
$targets |
    Select-Object DeviceName, DeviceID, Manufacturer, DriverProviderName,
                  DriverVersion, DriverDate, InfName, IsSigned |
    Format-List | Out-String -Width 400 |
    Set-Content -Encoding UTF8 $targetsPath
Write-Host "SIGNED_DRIVERS=$targetsPath count=$($targets.Count)"

$pnpTargets = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
    $_.InstanceId -match 'ASUH2024' -or
    $_.FriendlyName -match 'ASUS Keyboard Feature|ASUS Consumer'
})

$pnpPath = Join-Path $OutputDir 'pnp-devices.txt'
$pnpTargets |
    Select-Object Status, Class, FriendlyName, InstanceId |
    Format-List | Out-String -Width 400 |
    Set-Content -Encoding UTF8 $pnpPath
Write-Host "PNP=$pnpPath count=$($pnpTargets.Count)"

$propsPath = Join-Path $OutputDir 'pnp-properties.txt'
$propLines = New-Object System.Collections.Generic.List[string]
foreach ($dev in $pnpTargets) {
    $propLines.Add("===== $($dev.InstanceId) =====")
    try {
        $props = Get-PnpDeviceProperty -InstanceId $dev.InstanceId -ErrorAction Stop
        $propLines.Add(($props | Select-Object KeyName, Type, Data | Format-List | Out-String -Width 500))
    }
    catch {
        $propLines.Add("ERROR=$($_.Exception.Message)")
    }
}
$propLines | Set-Content -Encoding UTF8 $propsPath
Write-Host "PNP_PROPERTIES=$propsPath"

$enumPath = Join-Path $OutputDir 'pnputil-enum.txt'
$enumLines = New-Object System.Collections.Generic.List[string]
foreach ($dev in $pnpTargets) {
    $enumLines.Add("===== $($dev.InstanceId) =====")
    try {
        $text = & pnputil.exe /enum-devices /instanceid "$($dev.InstanceId)" /drivers /stack /properties 2>&1
        $enumLines.Add(($text -join "`r`n"))
    }
    catch {
        $enumLines.Add("ERROR=$($_.Exception.Message)")
    }
}
$enumLines | Set-Content -Encoding UTF8 $enumPath
Write-Host "PNPUTIL_ENUM=$enumPath"

$driverStore = Join-Path $OutputDir 'driver-packages'
New-Item -ItemType Directory -Force -Path $driverStore | Out-Null
$infs = @($targets | Where-Object { $_.InfName } | Select-Object -ExpandProperty InfName -Unique)
$exportPath = Join-Path $OutputDir 'pnputil-export.txt'
$exportLines = New-Object System.Collections.Generic.List[string]
foreach ($inf in $infs) {
    $dest = Join-Path $driverStore ([IO.Path]::GetFileNameWithoutExtension($inf))
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $exportLines.Add("===== EXPORT $inf =====")
    try {
        $text = & pnputil.exe /export-driver $inf $dest 2>&1
        $exportLines.Add(($text -join "`r`n"))
    }
    catch {
        $exportLines.Add("ERROR=$($_.Exception.Message)")
    }
}
$exportLines | Set-Content -Encoding UTF8 $exportPath
Write-Host "DRIVER_EXPORT_LOG=$exportPath"

$servicesPath = Join-Path $OutputDir 'asus-input-services.txt'
Get-CimInstance Win32_SystemDriver |
    Where-Object {
        $_.Name -match 'asus|atk' -or
        $_.DisplayName -match 'ASUS|ATK' -or
        $_.PathName -match 'asus|atk'
    } |
    Select-Object Name, DisplayName, State, StartMode, PathName |
    Sort-Object Name |
    Format-List | Out-String -Width 500 |
    Set-Content -Encoding UTF8 $servicesPath
Write-Host "ASUS_SERVICES=$servicesPath"

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
Write-Host 'A14_KEYBOARD_FEATURE_DRIVER_CAPTURE=PASS'
