#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputRoot = "$env:USERPROFILE\Desktop",
    [switch]$OpenPresenceSettings,
    [switch]$UsePresenceSensorSample,
    [switch]$UseBuiltInPresenceMonitor,
    [ValidateRange(5, 300)][int]$MonitorSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Invoke-Wpr {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $output = & wpr.exe @Arguments 2>&1
    $status = $LASTEXITCODE
    $output | Out-File -LiteralPath $LogPath -Encoding utf8 -Width 8192
    if ($status -ne 0) {
        throw "wpr.exe failed with exit code $status. See $LogPath"
    }
}

function Save-QcomCameraDevices {
    param([Parameter(Mandatory = $true)][string]$Path)

    Save-Text -Path $Path -Command {
        foreach ($id in @('QCOM0D06', 'QCOM0C32', 'QCOM0C17', 'QCOM0C2B', 'QCOM0C0C')) {
            "===== $id ====="
            pnputil.exe /enum-devices /deviceid $id /properties /drivers
            ''
        }
    }
}

function Save-AosHostState {
    param([Parameter(Mandatory = $true)][string]$Path)

    Save-Text -Path $Path -Command {
        '===== WUDFHost processes ====='
        Get-Process WUDFHost -ErrorAction SilentlyContinue |
            Format-List Id, ProcessName, Path, StartTime
        ''
        '===== qcAlwaysOnSensing.dll module owners ====='
        tasklist.exe /m qcAlwaysOnSensing.dll
    }
}

function Add-Marker {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    "$Name=$((Get-Date).ToString('o'))" |
        Add-Content -LiteralPath $Path -Encoding utf8
}

function Invoke-BuiltInPresenceMonitor {
    param(
        [Parameter(Mandatory = $true)][int]$Seconds,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter(Mandatory = $true)][string]$MarkerPath
    )

    $sensor = $null
    $sawReading = $false

    @(
        "monitor_started=$((Get-Date).ToString('o'))"
        "requested_duration_seconds=$Seconds"
        'api=Windows.Devices.Sensors.HumanPresenceSensor'
        'method_get_default=GetDefault'
        'method_read=GetCurrentReading'
    ) | Out-File -LiteralPath $LogPath -Encoding utf8 -Width 8192

    try {
        [void][Windows.Devices.Sensors.HumanPresenceSensor, Windows.Devices.Sensors, ContentType=WindowsRuntime]

        Add-Marker -Path $MarkerPath -Name 'builtin_monitor_acquire_requested'
        $sensor = [Windows.Devices.Sensors.HumanPresenceSensor]::GetDefault()
        Add-Marker -Path $MarkerPath -Name 'builtin_monitor_acquire_returned'

        if ($null -eq $sensor) {
            'monitor_result=no-default-presence-sensor' |
                Add-Content -LiteralPath $LogPath -Encoding utf8
            Write-Host ''
            Write-Host 'NO DEFAULT PRESENCE SENSOR WAS RETURNED.' -ForegroundColor Red
            Write-Host 'Check Settings > Privacy & security > Presence sensing and ensure app access is enabled.'
            return $false
        }

        @(
            "device_id=$($sensor.DeviceId)"
            "presence_supported=$($sensor.IsPresenceSupported)"
            "engagement_supported=$($sensor.IsEngagementSupported)"
            "max_detectable_persons=$($sensor.MaxDetectablePersons)"
            "min_distance_mm=$($sensor.MinDetectableDistanceInMillimeters)"
            "max_distance_mm=$($sensor.MaxDetectableDistanceInMillimeters)"
        ) | Add-Content -LiteralPath $LogPath -Encoding utf8

        Write-Host ''
        Write-Host 'BUILT-IN PRESENCE MONITOR ACTIVE.' -ForegroundColor Green
        Write-Host "Device: $($sensor.DeviceId)"
        Write-Host "Monitoring for $Seconds seconds. Move away from the laptop, then return."
        Write-Host 'Live readings will appear below.'
        Write-Host ''

        $deadline = (Get-Date).AddSeconds($Seconds)
        while ((Get-Date) -lt $deadline) {
            try {
                $reading = $sensor.GetCurrentReading()
                if ($null -eq $reading) {
                    "host_time=$((Get-Date).ToString('o')) reading=null" |
                        Add-Content -LiteralPath $LogPath -Encoding utf8
                }
                else {
                    if (-not $sawReading) {
                        Add-Marker -Path $MarkerPath -Name 'builtin_monitor_first_reading'
                        $sawReading = $true
                    }

                    $distance = if ($null -eq $reading.DistanceInMillimeters) {
                        'unavailable'
                    }
                    else {
                        [string]$reading.DistanceInMillimeters
                    }

                    $line = @(
                        "host_time=$((Get-Date).ToString('o'))"
                        "sensor_time=$($reading.Timestamp.ToString('o'))"
                        "presence=$($reading.Presence)"
                        "engagement=$($reading.Engagement)"
                        "distance_mm=$distance"
                    ) -join ' '

                    $line | Add-Content -LiteralPath $LogPath -Encoding utf8
                    Write-Host $line
                }
            }
            catch {
                $line = "host_time=$((Get-Date).ToString('o')) reading_error=$($_.Exception.Message)"
                $line | Add-Content -LiteralPath $LogPath -Encoding utf8
                Write-Host $line -ForegroundColor Yellow
            }

            Start-Sleep -Milliseconds 500
        }

        if ($sawReading) {
            'monitor_result=live-readings-observed' |
                Add-Content -LiteralPath $LogPath -Encoding utf8
        }
        else {
            'monitor_result=no-live-reading-observed' |
                Add-Content -LiteralPath $LogPath -Encoding utf8
            Write-Host ''
            Write-Host 'The sensor object opened, but no live reading was returned.' -ForegroundColor Yellow
        }
    }
    catch [System.UnauthorizedAccessException] {
        "monitor_result=unauthorized message=$($_.Exception.Message)" |
            Add-Content -LiteralPath $LogPath -Encoding utf8
        Write-Host ''
        Write-Host 'PRESENCE SENSOR ACCESS WAS DENIED.' -ForegroundColor Red
        Write-Host 'Enable Presence sensing app access in Windows Settings and rerun the trace.'
        $sawReading = $false
    }
    catch {
        @(
            'monitor_result=failed'
            "exception=$($_.Exception.GetType().FullName)"
            "message=$($_.Exception.Message)"
        ) | Add-Content -LiteralPath $LogPath -Encoding utf8
        Write-Host ''
        Write-Host "Presence monitor failed: $($_.Exception.Message)" -ForegroundColor Red
        $sawReading = $false
    }
    finally {
        Add-Marker -Path $MarkerPath -Name 'builtin_monitor_release_requested'
        $sensor = $null
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [GC]::Collect()
        Add-Marker -Path $MarkerPath -Name 'builtin_monitor_release_completed'
    }

    return $sawReading
}

if (-not (Test-Administrator)) {
    throw 'Run this script from an elevated Windows PowerShell window.'
}

if ($UsePresenceSensorSample -and $UseBuiltInPresenceMonitor) {
    throw 'Choose only one trigger mode: -UsePresenceSensorSample or -UseBuiltInPresenceMonitor.'
}

$wpr = Get-Command wpr.exe -ErrorAction Stop
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $OutputRoot "A14-QCOM0D06-AOS-Trace-$stamp"
New-Item -ItemType Directory -Force -Path $output | Out-Null
$etl = Join-Path $output 'qcom0d06-aos-power.etl'
$markers = Join-Path $output 'USER-MARKERS.txt'
$monitorLog = Join-Path $output 'presence-monitor.txt'
$traceStarted = $false
$traceStopped = $false
$traceStart = $null
$traceEnd = $null
$presenceMonitorResult = 'not-run'

$triggerMode = if ($UseBuiltInPresenceMonitor) {
    'builtin-powershell-human-presence-monitor'
}
elseif ($UsePresenceSensorSample) {
    'microsoft-presence-sensor-sample'
}
else {
    'windows-presence-sensing-settings'
}

$readsPresenceSensor = if ($UseBuiltInPresenceMonitor) { 'true' } else { 'false' }

Write-Host ('=' * 76)
Write-Host 'ASUS Zenbook A14 QCOM0D06 / Windows Presence Sensing AOS trace'
Write-Host ('=' * 76)
Write-Host "Output: $output"
Write-Host "Trigger mode: $triggerMode"
Write-Host ''
Write-Host 'Safety:'
Write-Host '  This script sends NO camera-platform IOCTL directly, restarts NO device,'
Write-Host '  changes NO PnP state, and performs NO camera/CPAS register access.'
if ($UseBuiltInPresenceMonitor) {
    Write-Host '  Built-in monitor mode DOES use the public Windows HumanPresenceSensor API'
    Write-Host '  to acquire the default sensor and poll GetCurrentReading().'
}
Write-Host ''

Save-Text -Path (Join-Path $output 'wpr-status-before.txt') -Command {
    & $wpr.Source -status
}
Save-Text -Path (Join-Path $output 'matching-etw-providers.txt') -Command {
    logman.exe query providers |
        Select-String -Pattern 'camera|qcom|qualcomm|always|presence|sensor|pofx|pep|power|pdc' -CaseSensitive:$false
}
Save-QcomCameraDevices -Path (Join-Path $output 'qcom-camera-devices-before.txt')
Save-AosHostState -Path (Join-Path $output 'always-on-sensing-host-before.txt')
Save-Text -Path (Join-Path $output 'powercfg-requests-before.txt') -Command {
    powercfg.exe /requests
}

@(
    "generated_at=$((Get-Date).ToString('o'))"
    "computer_name=$env:COMPUTERNAME"
    "user_name=$env:USERNAME"
    "powershell_version=$($PSVersionTable.PSVersion)"
    "wpr_path=$($wpr.Source)"
    'trace_profile=Power'
    'trace_mode=filemode'
    'target_device=ACPI\QCOM0D06'
    'target_role=Windows-Presence-Sensing-camera-AOS-client'
    'known_client=qcAlwaysOnSensing.dll'
    'known_platform_ioctl=0x002326bb'
    "trigger_mode=$triggerMode"
    'collector_sends_platform_ioctl=false'
    "collector_reads_human_presence_sensor=$readsPresenceSensor"
    'devices_restarted=false'
    'pnp_state_changed_by_collector=false'
    'camera_register_writes_by_collector=false'
    'direct_cpas_mmio=false'
) | Out-File -LiteralPath (Join-Path $output 'TRACE-INFO.txt') -Encoding utf8 -Width 8192

if ($OpenPresenceSettings) {
    Start-Process 'ms-settings:presence'
}

if ($UseBuiltInPresenceMonitor) {
    Write-Host 'Built-in monitor mode needs no Visual Studio app or PresenceSensor sample.'
    Write-Host "After the trace starts, it will print live readings for $MonitorSeconds seconds."
    Write-Host 'Be ready to move away from the laptop and return during that interval.'
}
elseif ($UsePresenceSensorSample) {
    Write-Host 'Before starting the trace:'
    Write-Host '  1. Launch Microsoft PresenceSensor and open the Data Events scenario.'
    Write-Host '  2. DO NOT click "Get default sensor" yet.'
    Write-Host '  3. Leave the sample ready in the background.'
}
else {
    Write-Host 'Before starting the trace:'
    Write-Host '  1. Open Windows Presence sensing (Settings URI: ms-settings:presence).'
    Write-Host '  2. Ensure at least one normal OS feature is enabled, for example:'
    Write-Host '       - Lock on Leave'
    Write-Host '       - Wake on Approach'
    Write-Host '       - Adaptive Dimming'
}
Write-Host ''
Write-Host 'Do not use Device Manager, custom IOCTL tools, or camera test tools.'
Write-Host ''
Read-Host 'Press ENTER when ready to start the Power trace' | Out-Null

try {
    Invoke-Wpr -Arguments @('-start', 'Power', '-filemode') -LogPath (Join-Path $output 'wpr-start.txt')
    $traceStarted = $true
    $traceStart = Get-Date

    @(
        "trace_started=$($traceStart.ToString('o'))"
        "trigger_mode=$triggerMode"
    ) | Out-File -LiteralPath $markers -Encoding utf8 -Width 8192

    Write-Host ''
    Write-Host 'TRACE RUNNING.' -ForegroundColor Green

    if ($UseBuiltInPresenceMonitor) {
        $ok = Invoke-BuiltInPresenceMonitor -Seconds $MonitorSeconds -LogPath $monitorLog -MarkerPath $markers
        $presenceMonitorResult = if ($ok) { 'live-readings-observed' } else { 'failed-or-no-reading' }
    }
    elseif ($UsePresenceSensorSample) {
        Write-Host 'NOW switch to PresenceSensor -> Data Events and click "Get default sensor".'
        Write-Host 'Confirm that timestamp and Presence/Engagement values are updating.'
        Write-Host 'Move away, return, and verify the live data changes.'
        Write-Host ''
        Read-Host 'Press ENTER only after you have SEEN live sensor data' | Out-Null
        Add-Marker -Path $markers -Name 'sample_live_data_confirmed'

        Write-Host ''
        Write-Host 'Now navigate away from Data Events or close PresenceSensor to release the sensor.'
        Read-Host 'Press ENTER after the sample has released/closed the sensor' | Out-Null
        Add-Marker -Path $markers -Name 'sample_sensor_release_confirmed'
        $presenceMonitorResult = 'user-confirmed-sample-readings'
    }
    else {
        Write-Host 'Exercise the enabled Windows Presence Sensing feature naturally.'
        Write-Host 'Recommended: stay present, step away until absence reacts, then return.'
        Read-Host 'Press ENTER after the presence sequence to stop and save the trace' | Out-Null
        Add-Marker -Path $markers -Name 'windows_presence_sequence_completed'
    }

    $traceEnd = Get-Date
    Add-Marker -Path $markers -Name 'trace_stop_requested'
    Invoke-Wpr -Arguments @('-stop', $etl) -LogPath (Join-Path $output 'wpr-stop.txt')
    $traceStopped = $true
}
finally {
    if ($traceStarted -and -not $traceStopped) {
        $recoveryEtl = Join-Path $output 'qcom0d06-aos-power-recovery.etl'
        try {
            Invoke-Wpr -Arguments @('-stop', $recoveryEtl) -LogPath (Join-Path $output 'wpr-recovery-stop.txt')
            $traceStopped = $true
            if (-not $traceEnd) { $traceEnd = Get-Date }
        }
        catch {
            & $wpr.Source -cancel 2>&1 |
                Out-File -LiteralPath (Join-Path $output 'wpr-cancel.txt') -Encoding utf8 -Width 8192
        }
    }
}

if (-not $traceStart) { throw 'The trace did not start.' }
if (-not $traceEnd) { $traceEnd = Get-Date }

Save-QcomCameraDevices -Path (Join-Path $output 'qcom-camera-devices-after.txt')
Save-AosHostState -Path (Join-Path $output 'always-on-sensing-host-after.txt')
Save-Text -Path (Join-Path $output 'powercfg-requests-after.txt') -Command {
    powercfg.exe /requests
}
Save-Text -Path (Join-Path $output 'system-events-trace-window.txt') -Command {
    Get-WinEvent -FilterHashtable @{
        LogName = 'System'
        StartTime = $traceStart.AddSeconds(-2)
        EndTime = $traceEnd.AddSeconds(2)
    } | Where-Object {
        $_.ProviderName -match 'Power|Kernel|PnP|Driver|Camera|Sensor|Qualcomm|QCOM|PDC|WUDF' -or
        $_.Message -match 'PoFx|PEP|camera|sensor|presence|QCOM|Qualcomm|power framework|WUDF'
    } | Format-List TimeCreated, ProviderName, Id, LevelDisplayName, Message
}

$etlExists = Test-Path -LiteralPath $etl -PathType Leaf
$etlSize = 0
if ($etlExists) {
    $etlSize = (Get-Item -LiteralPath $etl).Length
}

@(
    "trace_started=$($traceStart.ToString('o'))"
    "trace_stopped=$($traceEnd.ToString('o'))"
    "trace_duration_seconds=$([math]::Round(($traceEnd - $traceStart).TotalSeconds, 3))"
    "etl=$etl"
    "etl_exists=$etlExists"
    "etl_size=$etlSize"
    'target_device=ACPI\QCOM0D06'
    "trigger_mode=$triggerMode"
    "presence_monitor_result=$presenceMonitorResult"
    'collector_hardware_control=false'
    'collector_sends_platform_ioctl=false'
    "collector_reads_human_presence_sensor=$readsPresenceSensor"
    'direct_cpas_mmio=false'
) | Out-File -LiteralPath (Join-Path $output 'TRACE-RESULT.txt') -Encoding utf8 -Width 8192

if (-not $etlExists -or $etlSize -le 0) {
    throw 'WPR stopped without producing a non-empty ETL file.'
}

$zip = "$output.zip"
if (Test-Path -LiteralPath $zip) {
    Remove-Item -LiteralPath $zip -Force
}
Compress-Archive -LiteralPath $output -DestinationPath $zip -CompressionLevel Optimal

Write-Host ''
Write-Host "Trace directory: $output"
Write-Host "Archive:         $zip"
Write-Host "Presence result: $presenceMonitorResult"
Write-Host 'Upload the ZIP. Decode it with the existing Kernel-Power exporter first.'
