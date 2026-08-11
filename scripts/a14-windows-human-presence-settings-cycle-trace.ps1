#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputRoot = "$env:USERPROFILE\Desktop",
    [ValidateRange(3, 60)][int]$DisabledHoldSeconds = 8,
    [ValidateRange(3, 60)][int]$RestoredHoldSeconds = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Wpr {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $output = & wpr.exe @Arguments 2>&1
    $status = $LASTEXITCODE
    $output | Out-File -LiteralPath $LogPath -Encoding utf8 -Width 8192
    if ($status -ne 0) {
        $hex = ('0x{0:X8}' -f ([uint32]$status))
        throw "wpr.exe failed with exit code $status ($hex). See $LogPath"
    }
}

function Add-Marker {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    "$Name=$((Get-Date).ToString('o'))" | Add-Content -LiteralPath $Path -Encoding utf8
}

function Get-SettingPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $property = $Settings.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Set-SettingPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value
    )
    $property = $Settings.PSObject.Properties[$Name]
    if ($null -eq $property) { return $false }
    $property.Value = $Value
    return $true
}

function Save-SettingsSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$ToggleNames
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add("captured_at=$((Get-Date).ToString('o'))")
    foreach ($name in @('SensorId') + $ToggleNames + @(
        'WakeOnApproachDistanceInMillimeters',
        'LockOnLeaveDistanceInMillimeters',
        'LockOnLeaveTimeout'
    )) {
        $property = $Settings.PSObject.Properties[$name]
        if ($null -ne $property) {
            $value = $property.Value
            $lines.Add("$name=$value")
        }
    }
    $lines | Out-File -LiteralPath $Path -Encoding utf8 -Width 8192
}

function Restore-PresenceToggles {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Original,
        [Parameter(Mandatory = $true)][string[]]$ToggleNames,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $settings = [Windows.Devices.Sensors.HumanPresenceSettings]::GetCurrentSettings()
    foreach ($name in $ToggleNames) {
        if ($Original.ContainsKey($name)) {
            [void](Set-SettingPropertyValue -Settings $settings -Name $name -Value ([bool]$Original[$name]))
        }
    }
    [Windows.Devices.Sensors.HumanPresenceSettings]::UpdateSettings($settings)
    "restored_at=$((Get-Date).ToString('o'))" | Add-Content -LiteralPath $LogPath -Encoding utf8
}

# HumanPresenceSettings WinRT projection is intentionally executed in Windows PowerShell 5.1.
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
        throw "Windows PowerShell 5.1 was not found at $windowsPowerShell"
    }

    Write-Host "Current host: PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    Write-Host 'Relaunching under Windows PowerShell 5.1 for WinRT projection support...'
    & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath `
        -OutputRoot $OutputRoot `
        -DisabledHoldSeconds $DisabledHoldSeconds `
        -RestoredHoldSeconds $RestoredHoldSeconds
    exit $LASTEXITCODE
}

if (-not (Test-Administrator)) {
    throw 'Run this script from an elevated PowerShell window.'
}

[void][Windows.Devices.Sensors.HumanPresenceSettings, Windows.Devices.Sensors, ContentType=WindowsRuntime]
Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop

$toggleNames = @(
    'IsWakeOnApproachEnabled',
    'IsLockOnLeaveEnabled',
    'IsAdaptiveDimmingEnabled',
    'IsOnlookerDetectionEnabled'
)

$initialSettings = [Windows.Devices.Sensors.HumanPresenceSettings]::GetCurrentSettings()
$original = @{}
$availableToggles = New-Object 'System.Collections.Generic.List[string]'
$enabledToggles = New-Object 'System.Collections.Generic.List[string]'

foreach ($name in $toggleNames) {
    $property = $initialSettings.PSObject.Properties[$name]
    if ($null -ne $property) {
        $value = [bool]$property.Value
        $original[$name] = $value
        $availableToggles.Add($name)
        if ($value) { $enabledToggles.Add($name) }
    }
}

if ($availableToggles.Count -eq 0) {
    throw 'HumanPresenceSettings is available, but none of the expected Presence Sensing feature toggles are exposed.'
}
if ($enabledToggles.Count -eq 0) {
    throw 'All exposed Presence Sensing features are already disabled. Enable at least one normal Windows Presence Sensing feature first; no WPR trace was started.'
}

$wpr = Get-Command wpr.exe -ErrorAction Stop
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $OutputRoot "A14-Human-Presence-Settings-Cycle-Trace-$stamp"
New-Item -ItemType Directory -Force -Path $output | Out-Null
$etl = Join-Path $output 'presence-settings-cycle-power.etl'
$markers = Join-Path $output 'MARKERS.txt'
$settingsLog = Join-Path $output 'SETTINGS-TRANSITIONS.txt'
$traceStarted = $false
$traceStopped = $false
$settingsChanged = $false
$settingsRestored = $false
$traceStart = $null
$traceEnd = $null

Save-SettingsSnapshot -Settings $initialSettings -Path (Join-Path $output 'settings-before.txt') -ToggleNames $availableToggles.ToArray()
@(
    "generated_at=$((Get-Date).ToString('o'))"
    "powershell_version=$($PSVersionTable.PSVersion)"
    "powershell_edition=$($PSVersionTable.PSEdition)"
    "available_toggles=$($availableToggles -join ',')"
    "enabled_toggles=$($enabledToggles -join ',')"
    'public_api=Windows.Devices.Sensors.HumanPresenceSettings'
    'settings_changed_by_collector=true'
    'restore_in_finally=true'
    'collector_sends_platform_ioctl=false'
    'collector_acquires_human_presence_sensor=false'
    'devices_restarted=false'
    'pnp_state_changed=false'
    'direct_cpas_mmio=false'
    'camera_register_access=false'
) | Out-File -LiteralPath (Join-Path $output 'TRACE-INFO.txt') -Encoding utf8 -Width 8192

Write-Host ('=' * 76)
Write-Host 'ASUS Zenbook A14 Windows Presence Sensing settings-cycle trace'
Write-Host ('=' * 76)
Write-Host "Output: $output"
Write-Host ''
Write-Host 'Current enabled Presence Sensing features:'
foreach ($name in $enabledToggles) { Write-Host "  - $name" }
Write-Host ''
Write-Host 'This test uses the public Windows HumanPresenceSettings API only.'
Write-Host 'It will temporarily disable the enabled Presence Sensing feature toggles,'
Write-Host "hold for $DisabledHoldSeconds seconds, then restore their exact original values and hold for $RestoredHoldSeconds seconds."
Write-Host ''
Write-Host 'Safety boundary:'
Write-Host '  - no camera-platform IOCTL is sent directly;'
Write-Host '  - no Device Manager/PnP restart;'
Write-Host '  - no camera/CPAS register or MMIO access;'
Write-Host '  - original feature toggles are restored in a finally block if the trace fails.'
Write-Host ''
Write-Host 'Close A14 Presence Monitor or any other app actively holding HumanPresenceSensor before continuing.'
Read-Host 'Press ENTER when ready' | Out-Null

try {
    Invoke-Wpr -Arguments @('-start', 'Power', '-filemode') -LogPath (Join-Path $output 'wpr-start.txt')
    $traceStarted = $true
    $traceStart = Get-Date
    Add-Marker -Path $markers -Name 'trace_started'

    $disabledSettings = [Windows.Devices.Sensors.HumanPresenceSettings]::GetCurrentSettings()
    foreach ($name in $availableToggles) {
        [void](Set-SettingPropertyValue -Settings $disabledSettings -Name $name -Value $false)
    }
    Add-Marker -Path $markers -Name 'disable_update_requested'
    [Windows.Devices.Sensors.HumanPresenceSettings]::UpdateSettings($disabledSettings)
    $settingsChanged = $true
    Add-Marker -Path $markers -Name 'disable_update_returned'
    "disabled_toggles=$($availableToggles -join ',')" | Out-File -LiteralPath $settingsLog -Encoding utf8 -Width 8192

    Start-Sleep -Seconds $DisabledHoldSeconds
    $afterDisable = [Windows.Devices.Sensors.HumanPresenceSettings]::GetCurrentSettings()
    Save-SettingsSnapshot -Settings $afterDisable -Path (Join-Path $output 'settings-disabled.txt') -ToggleNames $availableToggles.ToArray()
    Add-Marker -Path $markers -Name 'disabled_hold_complete'

    Add-Marker -Path $markers -Name 'restore_update_requested'
    Restore-PresenceToggles -Original $original -ToggleNames $availableToggles.ToArray() -LogPath $settingsLog
    $settingsRestored = $true
    Add-Marker -Path $markers -Name 'restore_update_returned'

    Start-Sleep -Seconds $RestoredHoldSeconds
    $afterRestore = [Windows.Devices.Sensors.HumanPresenceSettings]::GetCurrentSettings()
    Save-SettingsSnapshot -Settings $afterRestore -Path (Join-Path $output 'settings-restored.txt') -ToggleNames $availableToggles.ToArray()
    Add-Marker -Path $markers -Name 'restored_hold_complete'

    $traceEnd = Get-Date
    Invoke-Wpr -Arguments @('-stop', $etl) -LogPath (Join-Path $output 'wpr-stop.txt')
    $traceStopped = $true
}
finally {
    if ($settingsChanged -and -not $settingsRestored) {
        try {
            Restore-PresenceToggles -Original $original -ToggleNames $availableToggles.ToArray() -LogPath $settingsLog
            $settingsRestored = $true
            Add-Marker -Path $markers -Name 'emergency_restore_completed'
        }
        catch {
            "emergency_restore_failed=$($_.Exception.Message)" | Add-Content -LiteralPath $settingsLog -Encoding utf8
        }
    }

    if ($traceStarted -and -not $traceStopped) {
        $recoveryEtl = Join-Path $output 'presence-settings-cycle-power-recovery.etl'
        try {
            Invoke-Wpr -Arguments @('-stop', $recoveryEtl) -LogPath (Join-Path $output 'wpr-recovery-stop.txt')
            $traceStopped = $true
            if (-not $traceEnd) { $traceEnd = Get-Date }
        }
        catch {
            & $wpr.Source -cancel 2>&1 | Out-File -LiteralPath (Join-Path $output 'wpr-cancel.txt') -Encoding utf8 -Width 8192
        }
    }
}

if (-not $traceStart) { throw 'The WPR trace did not start.' }
if (-not $traceEnd) { $traceEnd = Get-Date }

$finalSettings = [Windows.Devices.Sensors.HumanPresenceSettings]::GetCurrentSettings()
Save-SettingsSnapshot -Settings $finalSettings -Path (Join-Path $output 'settings-final.txt') -ToggleNames $availableToggles.ToArray()

$restoreVerified = $true
foreach ($name in $availableToggles) {
    $actual = [bool](Get-SettingPropertyValue -Settings $finalSettings -Name $name)
    if ($actual -ne [bool]$original[$name]) { $restoreVerified = $false }
}

$etlExists = Test-Path -LiteralPath $etl -PathType Leaf
$etlSize = if ($etlExists) { (Get-Item -LiteralPath $etl).Length } else { 0 }
@(
    "trace_started=$($traceStart.ToString('o'))"
    "trace_stopped=$($traceEnd.ToString('o'))"
    "trace_duration_seconds=$([math]::Round(($traceEnd - $traceStart).TotalSeconds, 3))"
    "etl_exists=$etlExists"
    "etl_size=$etlSize"
    "settings_changed=$settingsChanged"
    "settings_restored=$settingsRestored"
    "restore_verified=$restoreVerified"
    "original_enabled_toggles=$($enabledToggles -join ',')"
    'collector_sends_platform_ioctl=false'
    'collector_acquires_human_presence_sensor=false'
    'devices_restarted=false'
    'pnp_state_changed=false'
    'direct_cpas_mmio=false'
) | Out-File -LiteralPath (Join-Path $output 'TRACE-RESULT.txt') -Encoding utf8 -Width 8192

if (-not $restoreVerified) {
    throw "Presence Sensing settings did not verify back to their original values. Check $output\settings-final.txt and restore them in ms-settings:presence before continuing."
}
if (-not $etlExists -or $etlSize -le 0) {
    throw 'WPR stopped without producing a non-empty ETL file.'
}

$zip = "$output.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -LiteralPath $output -DestinationPath $zip -CompressionLevel Optimal

Write-Host ''
Write-Host "Settings restored: $restoreVerified"
Write-Host "Trace directory:  $output"
Write-Host "Archive:          $zip"
Write-Host 'Upload the ZIP. Decode Kernel-Power first; no additional hardware trace is needed before analysis.'
