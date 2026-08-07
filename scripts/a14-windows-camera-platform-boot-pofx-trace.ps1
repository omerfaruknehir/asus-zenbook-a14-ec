#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('Arm','Collect','Cancel')]
    [string]$Mode,

    [string]$OutputRoot = "$env:USERPROFILE\Desktop",

    [ValidateRange(0, 120)]
    [int]$PostLogonWaitSeconds = 20
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

$wpr = Get-Command wpr.exe -ErrorAction Stop
$stateRoot = Join-Path $env:ProgramData 'A14CameraBootPoFxTrace'
$stateFile = Join-Path $stateRoot 'ARMED.txt'

if ($Mode -eq 'Arm') {
    New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $armLog = Join-Path $stateRoot "wpr-addboot-$stamp.txt"

    Write-Host ('=' * 76)
    Write-Host 'ASUS Zenbook A14 camera-platform boot PoFx trace - ARM'
    Write-Host ('=' * 76)
    Write-Host ''
    Write-Host 'This configures the supported WPR Power boot autologger.'
    Write-Host 'No device is restarted and no camera/CPAS register or IOCTL operation is performed.'
    Write-Host ''
    Write-Host 'After arming, reboot Windows normally. Do not boot Linux between Arm and Collect.'
    Write-Host 'After logging back into Windows, wait for the desktop to settle, then run this script with Collect.'
    Write-Host ''

    @(
        "armed_at=$((Get-Date).ToString('o'))"
        "computer_name=$env:COMPUTERNAME"
        'profile=Power'
        'logging_mode=filemode'
        'boot_autologger=true'
        'collector_sends_platform_ioctl=false'
        'devices_restarted_by_collector=false'
        'pnp_state_changed_by_collector=false'
        'camera_register_access=false'
        'direct_cpas_mmio=false'
    ) | Out-File -LiteralPath $stateFile -Encoding utf8 -Width 8192

    try {
        Invoke-Wpr -Arguments @('-boottrace','-addboot','Power','-filemode') -LogPath $armLog
    }
    catch {
        Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
        throw
    }

    Write-Host 'Boot trace armed successfully.' -ForegroundColor Green
    Write-Host 'Reboot Windows now.'
    Write-Host ''
    Write-Host 'After login run:'
    Write-Host '  .\scripts\a14-windows-camera-platform-boot-pofx-trace.ps1 Collect'
    exit 0
}

if ($Mode -eq 'Cancel') {
    New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $cancelLog = Join-Path $stateRoot "wpr-cancelboot-$stamp.txt"
    Invoke-Wpr -Arguments @('-boottrace','-cancelboot') -LogPath $cancelLog
    Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
    Write-Host 'Boot trace configuration cancelled.'
    exit 0
}

# Collect mode.
if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
    throw "No A14 boot trace arm marker was found at $stateFile. Run Arm before rebooting."
}

if ($PostLogonWaitSeconds -gt 0) {
    Write-Host "Waiting $PostLogonWaitSeconds seconds after Collect invocation so post-logon camera/AOS services can settle..."
    Start-Sleep -Seconds $PostLogonWaitSeconds
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $OutputRoot "A14-Camera-Platform-Boot-PoFx-Trace-$stamp"
New-Item -ItemType Directory -Force -Path $output | Out-Null
$etl = Join-Path $output 'camera-platform-boot-pofx.etl'

Copy-Item -LiteralPath $stateFile -Destination (Join-Path $output 'ARMED.txt') -Force

Save-Text -Path (Join-Path $output 'qcom-camera-devices-postboot.txt') -Command {
    foreach ($id in @('QCOM0D06','QCOM0C32','QCOM06D9','QCOM0C17','QCOM0C2B','QCOM0C0C')) {
        "===== $id ====="
        pnputil.exe /enum-devices /deviceid $id /properties /drivers
        ''
    }
}

Save-Text -Path (Join-Path $output 'always-on-sensing-host-postboot.txt') -Command {
    '===== WUDFHost processes ====='
    Get-Process WUDFHost -ErrorAction SilentlyContinue | Format-List Id,ProcessName,Path,StartTime
    ''
    '===== qcAlwaysOnSensing.dll module owners ====='
    tasklist.exe /m qcAlwaysOnSensing.dll
}

Save-Text -Path (Join-Path $output 'wpr-status-before-stop.txt') -Command {
    & $wpr.Source -status
}

@(
    "collect_invoked_at=$((Get-Date).ToString('o'))"
    "post_logon_wait_seconds=$PostLogonWaitSeconds"
    'profile=Power'
    'operation=boottrace-stop-and-merge'
    'collector_sends_platform_ioctl=false'
    'devices_restarted_by_collector=false'
    'pnp_state_changed_by_collector=false'
    'camera_register_access=false'
    'direct_cpas_mmio=false'
) | Out-File -LiteralPath (Join-Path $output 'TRACE-INFO.txt') -Encoding utf8 -Width 8192

$stopLog = Join-Path $output 'wpr-stopboot.txt'
try {
    Invoke-Wpr -Arguments @('-boottrace','-stopboot',$etl,'ASUS Zenbook A14 camera platform PoFx boot trace') -LogPath $stopLog
}
catch {
    Write-Host ''
    Write-Host 'Boot-trace collection failed. The boot autologger may still be configured.' -ForegroundColor Red
    Write-Host 'Do NOT arm another trace on top of it.'
    Write-Host 'Inspect the stop log, or run Cancel only if you intentionally want to discard the boot trace.'
    throw
}

Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue

$etlExists = Test-Path -LiteralPath $etl -PathType Leaf
$etlSize = if ($etlExists) { (Get-Item -LiteralPath $etl).Length } else { 0 }
@(
    "collected_at=$((Get-Date).ToString('o'))"
    "etl=$etl"
    "etl_exists=$etlExists"
    "etl_size=$etlSize"
    'boot_autologger_removed=true'
    'collector_hardware_control=false'
    'collector_sends_platform_ioctl=false'
    'direct_cpas_mmio=false'
) | Out-File -LiteralPath (Join-Path $output 'TRACE-RESULT.txt') -Encoding utf8 -Width 8192

if (-not $etlExists -or $etlSize -le 0) {
    throw 'WPR stopboot completed without producing a non-empty ETL file.'
}

$zip = "$output.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -LiteralPath $output -DestinationPath $zip -CompressionLevel Optimal

Write-Host ''
Write-Host "Boot trace directory: $output"
Write-Host "Archive:              $zip"
Write-Host 'Upload the ZIP. Decode it with the existing Kernel-Power exporter first.'
