#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputRoot = "$env:USERPROFILE\Desktop",
    [switch]$OpenPresenceSettings
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

if (-not (Test-Administrator)) {
    throw 'Run this script from an elevated Windows PowerShell window.'
}

$wpr = Get-Command wpr.exe -ErrorAction Stop
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $OutputRoot "A14-QCOM0D06-AOS-Trace-$stamp"
New-Item -ItemType Directory -Force -Path $output | Out-Null
$etl = Join-Path $output 'qcom0d06-aos-power.etl'
$traceStarted = $false
$traceStopped = $false
$traceStart = $null
$traceEnd = $null

Write-Host ('=' * 76)
Write-Host 'ASUS Zenbook A14 QCOM0D06 / Windows Presence Sensing AOS trace'
Write-Host ('=' * 76)
Write-Host "Output: $output"
Write-Host ''
Write-Host 'Purpose:'
Write-Host '  Capture a real Windows Presence Sensing activation of ACPI\QCOM0D06.'
Write-Host ''
Write-Host 'Safety:'
Write-Host '  This collector sends NO camera IOCTL, restarts NO device, changes NO'
Write-Host '  PnP state, and performs NO camera/CPAS register access.'
Write-Host '  The only state change is whatever normal Windows Presence Sensing feature'
Write-Host '  you choose to exercise in Settings.'
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
    'collector_sends_platform_ioctl=false'
    'collector_reads_human_presence_sensor=false'
    'devices_restarted=false'
    'pnp_state_changed_by_collector=false'
    'camera_register_writes_by_collector=false'
    'direct_cpas_mmio=false'
    'normal_windows_presence_feature_activation_required=true'
) | Out-File -LiteralPath (Join-Path $output 'TRACE-INFO.txt') -Encoding utf8 -Width 8192

if ($OpenPresenceSettings) {
    Start-Process 'ms-settings:presence'
}

Write-Host 'Before starting the trace:'
Write-Host '  1. Open Windows Presence sensing (Settings URI: ms-settings:presence).'
Write-Host '  2. Ensure at least one normal OS feature is enabled, for example:'
Write-Host '       - Lock on Leave'
Write-Host '       - Wake on Approach'
Write-Host '       - Adaptive Dimming'
Write-Host '  3. Do not use Device Manager, custom IOCTL tools, or camera test tools.'
Write-Host ''
Read-Host 'Press ENTER when ready to start the Power trace' | Out-Null

try {
    Invoke-Wpr -Arguments @('-start', 'Power', '-filemode') -LogPath (Join-Path $output 'wpr-start.txt')
    $traceStarted = $true
    $traceStart = Get-Date

    Write-Host ''
    Write-Host 'TRACE RUNNING.'
    Write-Host 'Exercise the enabled Windows Presence Sensing feature naturally.'
    Write-Host 'Recommended sequence:'
    Write-Host '  - remain in front of the laptop for a few seconds;'
    Write-Host '  - step away until Windows detects absence / Lock on Leave reacts;'
    Write-Host '  - return and let Wake on Approach / presence detection react;'
    Write-Host '  - leave the feature active for another few seconds.'
    Write-Host ''
    Read-Host 'Press ENTER after that sequence to stop and save the trace' | Out-Null

    $traceEnd = Get-Date
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
    'collector_hardware_control=false'
    'collector_sends_platform_ioctl=false'
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
Write-Host 'Upload the ZIP. Decode it with the existing Kernel-Power exporter first.'
