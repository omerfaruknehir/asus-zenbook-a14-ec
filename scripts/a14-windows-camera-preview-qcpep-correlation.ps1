#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputRoot = "$env:USERPROFILE\Desktop",
    [ValidateRange(2, 30)][int]$PreviewHoldSeconds = 5,
    [ValidateRange(1, 15)][int]$PostCloseHoldSeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Correlate a normal user-driven Windows camera preview with CAMP PoFx and the
# already-running qcpep-rpmh buffering session. The collector does NOT launch,
# open, configure, or control a camera itself. The user manually opens/closes a
# normal Windows camera application while WPR Power records framework events.
# The qcpep buffer is snapshotted BEFORE WPR stop so a slow ETL save cannot
# overwrite or contaminate the target private-WPP window.

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Add-Marker {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    "$Name=$((Get-Date).ToString('o'))" | Add-Content -LiteralPath $Path -Encoding utf8
}

function Invoke-Wpr {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    # Windows PowerShell 5.1 can surface native stderr as NativeCommandError.
    # Do not let the script-wide ErrorActionPreference=Stop terminate before we
    # inspect the actual native process exit code.
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & wpr.exe @Arguments 2>&1
        $status = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }

    @($output | ForEach-Object { [string]$_ }) |
        Out-File -LiteralPath $LogPath -Encoding utf8 -Width 8192
    if ($status -ne 0) {
        $hex = ('0x{0:X8}' -f ([uint32]$status))
        throw "wpr.exe failed with exit code $status ($hex). See $LogPath"
    }
}

function Invoke-WprBestEffort {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & wpr.exe @Arguments 2>&1
        $status = $LASTEXITCODE
    }
    catch {
        $output = @($_.Exception.Message)
        $status = -1
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }

    @($output | ForEach-Object { [string]$_ }) |
        Out-File -LiteralPath $LogPath -Encoding utf8 -Width 8192
    return $status
}

function Get-NewestDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Filter
    )
    return Get-ChildItem -LiteralPath $Root -Directory -Filter $Filter -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Remove-RedundantChildArchive {
    param([AllowNull()]$Directory)
    if ($null -eq $Directory) { return }
    $archive = "$($Directory.FullName).zip"
    if (Test-Path -LiteralPath $archive -PathType Leaf) {
        Remove-Item -LiteralPath $archive -Force
    }
}

if (-not (Test-Administrator)) {
    throw 'Run this script from an elevated PowerShell window.'
}

$snapshotScript = Join-Path $PSScriptRoot 'a14-windows-qcpep-rpmh-snapshot.ps1'
$kernelPowerExporter = Join-Path $PSScriptRoot 'a14-windows-camera-platform-kernel-power-export.ps1'
$rawDumper = Join-Path $PSScriptRoot 'a14-windows-qcpep-rpmh-raw-dump.ps1'
foreach ($requiredScript in @($snapshotScript, $kernelPowerExporter, $rawDumper)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "Required correlation helper is missing: $requiredScript"
    }
}

$wpr = Get-Command wpr.exe -ErrorAction Stop
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bundle = Join-Path $OutputRoot "A14-Camera-Preview-QCPEP-Correlation-$stamp"
New-Item -ItemType Directory -Force -Path $bundle | Out-Null
$etl = Join-Path $bundle 'camera-preview-power.etl'
$markers = Join-Path $bundle 'CORRELATION-MARKERS.txt'
$resultPath = Join-Path $bundle 'CORRELATION-RESULT.txt'
$failurePath = Join-Path $bundle 'CORRELATION-FAILED.txt'

$traceStarted = $false
$traceStopped = $false
$snapshotSucceeded = $false
$kernelPowerDecodeSucceeded = $false
$rawDecodeSucceeded = $false
$failureMessage = $null
$snapshotDirectory = $null
$kernelPowerDirectory = $null
$rawDirectory = $null
$traceStart = $null
$traceEnd = $null

@(
    "generated_at=$((Get-Date).ToString('o'))"
    'operation=windows-camera-preview-qcpep-correlation'
    'trigger=user-manual-standard-windows-camera-preview'
    'camera_opened_by_collector=false'
    'camera_ioctls_sent_by_collector=false'
    'camera_platform_ioctl_sent_by_collector=false'
    'camera_register_access=false'
    'devices_restarted=false'
    'pnp_state_changed=false'
    'qcpep_source=existing-qcpep-rpmh-buffering-session'
    'qcpep_snapshot_order=before-wpr-stop'
    'qcpep_snapshot_helper=native-query-flush-no-stop-no-update'
    'kernel_power_decode=offline-only'
    'qcpep_raw_decode=offline-only'
    'direct_cpas_mmio=false'
    'ssc_contacted=false'
) | Out-File -LiteralPath (Join-Path $bundle 'CORRELATION-INFO.txt') -Encoding utf8 -Width 8192

Write-Host ('=' * 76)
Write-Host 'ASUS Zenbook A14 camera preview + qcpep RPMh correlation'
Write-Host ('=' * 76)
Write-Host "Bundle: $bundle"
Write-Host ''
Write-Host 'This collector does not open or control the camera.'
Write-Host 'You will manually open a normal Windows camera application while the'
Write-Host 'built-in WPR Power profile records CAMP/PoFx framework activity.'
Write-Host ''
Write-Host 'Before continuing:'
Write-Host '  - close the Windows Camera app and any other application using a camera;'
Write-Host '  - leave the normal camera devices enabled;'
Write-Host '  - do not use Device Manager or any custom camera/IOCTL utility.'
Write-Host ''
Read-Host 'Press ENTER when all camera preview applications are closed' | Out-Null

Add-Marker -Path $markers -Name 'correlation_started'

try {
    Add-Marker -Path $markers -Name 'wpr_start_requested'
    Invoke-Wpr -Arguments @('-start', 'Power', '-filemode') -LogPath (Join-Path $bundle 'wpr-start.txt')
    $traceStarted = $true
    $traceStart = Get-Date
    Add-Marker -Path $markers -Name 'wpr_started'

    Write-Host ''
    Write-Host 'WPR IS RUNNING.' -ForegroundColor Green
    Write-Host 'After the next ENTER, immediately open the normal Windows Camera app.'
    Write-Host 'Do not take a photo or change camera settings; just wait for live preview.'
    Read-Host 'Press ENTER immediately before opening Camera' | Out-Null
    Add-Marker -Path $markers -Name 'camera_open_window_started'

    Write-Host ''
    Write-Host 'Open Camera now and wait until a live preview is visibly updating.'
    Read-Host 'Press ENTER once the live preview is definitely running' | Out-Null
    Add-Marker -Path $markers -Name 'camera_preview_visible'

    Start-Sleep -Seconds $PreviewHoldSeconds
    Add-Marker -Path $markers -Name 'camera_preview_hold_complete'

    Write-Host ''
    Write-Host 'Close the Camera app completely now.'
    Read-Host 'Press ENTER after the live preview is closed' | Out-Null
    Add-Marker -Path $markers -Name 'camera_preview_closed_confirmed'

    Start-Sleep -Seconds $PostCloseHoldSeconds
    Add-Marker -Path $markers -Name 'post_close_hold_complete'

    # IMPORTANT: preserve the private qcpep window before WPR stop. WPR saving
    # can take minutes and generates unrelated platform activity.
    Add-Marker -Path $markers -Name 'qcpep_snapshot_requested'
    & $snapshotScript -OutputRoot $bundle
    $snapshotSucceeded = $true
    Add-Marker -Path $markers -Name 'qcpep_snapshot_returned'

    $snapshotDirectory = Get-NewestDirectory -Root $bundle -Filter 'A14-QCPEP-RPMH-Snapshot-*'
    if ($null -eq $snapshotDirectory) {
        throw 'qcpep snapshot returned without a snapshot directory.'
    }
    Remove-RedundantChildArchive -Directory $snapshotDirectory

    Add-Marker -Path $markers -Name 'wpr_stop_requested'
    $traceEnd = Get-Date
    Invoke-Wpr -Arguments @('-stop', $etl) -LogPath (Join-Path $bundle 'wpr-stop.txt')
    $traceStopped = $true
    Add-Marker -Path $markers -Name 'wpr_stop_returned'
}
catch {
    $failureMessage = $_.Exception.Message
    Add-Marker -Path $markers -Name 'correlation_capture_failed'
}
finally {
    if ($traceStarted -and -not $traceStopped) {
        $recoveryEtl = Join-Path $bundle 'camera-preview-power-recovery.etl'
        try {
            Add-Marker -Path $markers -Name 'wpr_recovery_stop_requested'
            Invoke-Wpr -Arguments @('-stop', $recoveryEtl) -LogPath (Join-Path $bundle 'wpr-recovery-stop.txt')
            $traceStopped = $true
            if (-not $traceEnd) { $traceEnd = Get-Date }
            Add-Marker -Path $markers -Name 'wpr_recovery_stop_returned'
            if (-not (Test-Path -LiteralPath $etl -PathType Leaf) -and (Test-Path -LiteralPath $recoveryEtl -PathType Leaf)) {
                $etl = $recoveryEtl
            }
        }
        catch {
            "recovery_stop_failed=$($_.Exception.Message)" |
                Add-Content -LiteralPath $failurePath -Encoding utf8
            $cancelStatus = Invoke-WprBestEffort -Arguments @('-cancel') -LogPath (Join-Path $bundle 'wpr-cancel.txt')
            "wpr_cancel_exit_code=$cancelStatus" |
                Add-Content -LiteralPath $failurePath -Encoding utf8
        }
    }
}

$etlExists = Test-Path -LiteralPath $etl -PathType Leaf
$etlSize = if ($etlExists) { (Get-Item -LiteralPath $etl).Length } else { 0 }

if ($etlExists -and $etlSize -gt 0) {
    try {
        Add-Marker -Path $markers -Name 'kernel_power_decode_started'
        & $kernelPowerExporter -TracePath $etl -OutputRoot $bundle
        $kernelPowerDecodeSucceeded = $true
        Add-Marker -Path $markers -Name 'kernel_power_decode_returned'
        $kernelPowerDirectory = Get-NewestDirectory -Root $bundle -Filter 'A14-Camera-Platform-Kernel-Power-Export-*'
        Remove-RedundantChildArchive -Directory $kernelPowerDirectory
    }
    catch {
        if (-not $failureMessage) { $failureMessage = "Kernel-Power decode failed: $($_.Exception.Message)" }
    }
}
elseif (-not $failureMessage) {
    $failureMessage = 'WPR capture did not produce a non-empty ETL.'
}

if ($null -ne $snapshotDirectory) {
    try {
        Add-Marker -Path $markers -Name 'qcpep_raw_decode_started'
        & $rawDumper -TracePath $snapshotDirectory.FullName -OutputRoot $bundle
        $rawDecodeSucceeded = $true
        Add-Marker -Path $markers -Name 'qcpep_raw_decode_returned'
        $rawDirectory = Get-NewestDirectory -Root $bundle -Filter 'A14-QCPEP-RPMH-Raw-*'
        Remove-RedundantChildArchive -Directory $rawDirectory
    }
    catch {
        if (-not $failureMessage) { $failureMessage = "qcpep raw decode failed: $($_.Exception.Message)" }
    }
}

if ($failureMessage) {
    @(
        "failed_at=$((Get-Date).ToString('o'))"
        "message=$failureMessage"
        "trace_started=$traceStarted"
        "trace_stopped=$traceStopped"
        "qcpep_snapshot_succeeded=$snapshotSucceeded"
        "kernel_power_decode_succeeded=$kernelPowerDecodeSucceeded"
        "qcpep_raw_decode_succeeded=$rawDecodeSucceeded"
        'camera_opened_by_collector=false'
        'camera_platform_ioctl_sent_by_collector=false'
        'devices_restarted=false'
        'pnp_state_changed=false'
        'direct_cpas_mmio=false'
        'ssc_contacted=false'
    ) | Out-File -LiteralPath $failurePath -Encoding utf8 -Width 8192
}
else {
    Add-Marker -Path $markers -Name 'correlation_completed'
}

@(
    "completed_at=$((Get-Date).ToString('o'))"
    "trace_started=$traceStarted"
    "trace_stopped=$traceStopped"
    "trace_start=$(if ($traceStart) { $traceStart.ToString('o') } else { '' })"
    "trace_end=$(if ($traceEnd) { $traceEnd.ToString('o') } else { '' })"
    "etl=$etl"
    "etl_exists=$etlExists"
    "etl_bytes=$etlSize"
    "qcpep_snapshot_succeeded=$snapshotSucceeded"
    "kernel_power_decode_succeeded=$kernelPowerDecodeSucceeded"
    "qcpep_raw_decode_succeeded=$rawDecodeSucceeded"
    "qcpep_snapshot_directory=$(if ($snapshotDirectory) { $snapshotDirectory.FullName } else { '' })"
    "kernel_power_directory=$(if ($kernelPowerDirectory) { $kernelPowerDirectory.FullName } else { '' })"
    "qcpep_raw_directory=$(if ($rawDirectory) { $rawDirectory.FullName } else { '' })"
    "failure=$(if ($failureMessage) { $failureMessage } else { '' })"
    'trigger=user-manual-standard-windows-camera-preview'
    'camera_opened_by_collector=false'
    'camera_ioctls_sent_by_collector=false'
    'camera_platform_ioctl_sent_by_collector=false'
    'qcpep_snapshot_order=before-wpr-stop'
    'live_etw_provider_reconfigured=false'
    'devices_restarted=false'
    'pnp_state_changed=false'
    'direct_cpas_mmio=false'
    'camera_register_access=false'
    'ssc_contacted=false'
) | Out-File -LiteralPath $resultPath -Encoding utf8 -Width 8192

$zip = "$bundle.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -LiteralPath $bundle -DestinationPath $zip -CompressionLevel Optimal

Write-Host ''
Write-Host "WPR trace:            $traceStopped"
Write-Host "qcpep snapshot:       $snapshotSucceeded"
Write-Host "Kernel-Power decode:  $kernelPowerDecodeSucceeded"
Write-Host "qcpep raw decode:     $rawDecodeSucceeded"
Write-Host "Correlation archive:  $zip"

if ($failureMessage) {
    throw "Correlation run was only partially completed: $failureMessage. Upload the archive for recovery analysis."
}

Write-Host 'Upload the correlation ZIP. The collector itself did not open/control the camera or perform AOS/CPAS/SSC access.'
