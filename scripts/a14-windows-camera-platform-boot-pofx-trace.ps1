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

# Compress-Archive uses System.IO.Compression.ZipArchive and cannot package an
# individual file larger than 2 GiB. Boot Power traces can exceed that easily.
# Preserve the raw trace directory in that case; the offline exporters accept
# a directory or ETL directly, so no trace data needs to be discarded/re-recorded.
$compressArchiveMaxFileBytes = [int64]2GB - 1
$largestFile = Get-ChildItem -LiteralPath $output -File -Recurse |
    Sort-Object Length -Descending |
    Select-Object -First 1
$zip = "$output.zip"
$archiveCreated = $false
$archiveReason = ''

if ($null -ne $largestFile -and [int64]$largestFile.Length -gt $compressArchiveMaxFileBytes) {
    if (Test-Path -LiteralPath $zip) {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
    $archiveReason = 'skipped-compress-archive-2gb-per-file-limit'
    @(
        "archive_created=false"
        "archive_reason=$archiveReason"
        "largest_file=$($largestFile.FullName)"
        "largest_file_bytes=$($largestFile.Length)"
        "trace_directory=$output"
        "etl=$etl"
        'next_step=run-kernel-power-exporter-directly-on-trace-directory'
    ) | Out-File -LiteralPath (Join-Path $output 'PACKAGING.txt') -Encoding utf8 -Width 8192
}
else {
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -LiteralPath $output -DestinationPath $zip -CompressionLevel Optimal
    $archiveCreated = $true
    $archiveReason = 'created-with-compress-archive'
}

@(
    "archive_created=$archiveCreated"
    "archive_reason=$archiveReason"
    "archive_path=$(if ($archiveCreated) { $zip } else { '' })"
) | Add-Content -LiteralPath (Join-Path $output 'TRACE-RESULT.txt') -Encoding utf8

Write-Host ''
Write-Host "Boot trace directory: $output"
if ($archiveCreated) {
    Write-Host "Archive:              $zip"
    Write-Host 'Upload the ZIP. Decode it with the existing Kernel-Power exporter first.'
}
else {
    Write-Host 'Archive:              skipped (ETL exceeds Compress-Archive 2 GiB per-file limit)' -ForegroundColor Yellow
    Write-Host "ETL size:             $etlSize bytes"
    Write-Host 'Do NOT record the trace again.' -ForegroundColor Green
    Write-Host 'Run the existing Kernel-Power exporter directly on the trace directory.'
}
