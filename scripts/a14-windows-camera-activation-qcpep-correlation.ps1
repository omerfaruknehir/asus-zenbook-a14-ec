#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputRoot = "$env:USERPROFILE\Desktop",
    [ValidateRange(0, 5)][int]$PreviewHoldSeconds = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Focused Stage-D correlation of one normal user-driven Windows camera bring-up.
# The collector never opens/configures the camera and never sends camera IOCTLs.
# qcpep-rpmh is snapshotted while the live preview remains active, before WPR
# stop, so the private PEP window is preserved without teardown contamination.

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

    # Windows PowerShell 5.1 surfaces native stderr as NativeCommandError when
    # ErrorActionPreference=Stop. Capture stderr as data and judge success only
    # from the native process exit code.
    $savedPreference = $ErrorActionPreference
    $output = @()
    $status = -1
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& wpr.exe @Arguments 2>&1)
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
    $output = @()
    $status = -1
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& wpr.exe @Arguments 2>&1)
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

function Remove-ChildZip {
    param([AllowNull()]$Directory)
    if ($null -eq $Directory) { return }
    $zip = "$($Directory.FullName).zip"
    if (Test-Path -LiteralPath $zip -PathType Leaf) {
        Remove-Item -LiteralPath $zip -Force
    }
}

if (-not (Test-Administrator)) {
    throw 'Run this script from an elevated Windows PowerShell window.'
}

$snapshotScript = Join-Path $PSScriptRoot 'a14-windows-qcpep-rpmh-snapshot.ps1'
$kernelPowerExporter = Join-Path $PSScriptRoot 'a14-windows-camera-platform-kernel-power-export.ps1'
$rawDumper = Join-Path $PSScriptRoot 'a14-windows-qcpep-rpmh-raw-dump.ps1'
foreach ($required in @($snapshotScript, $kernelPowerExporter, $rawDumper)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required helper is missing: $required"
    }
}

$wpr = Get-Command wpr.exe -ErrorAction Stop
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bundle = Join-Path $OutputRoot "A14-Camera-Activation-QCPEP-Correlation-$stamp"
New-Item -ItemType Directory -Force -Path $bundle | Out-Null
$markers = Join-Path $bundle 'CORRELATION-MARKERS.txt'
$etl = Join-Path $bundle 'camera-activation-power.etl'
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

@(
    "generated_at=$((Get-Date).ToString('o'))"
    'operation=windows-camera-activation-qcpep-correlation'
    'scope=camera-bring-up-only'
    'trigger=user-manual-standard-windows-camera-preview'
    'camera_opened_by_collector=false'
    'camera_ioctls_sent_by_collector=false'
    'camera_platform_ioctl_sent_by_collector=false'
    'qcpep_snapshot_while_preview_active=true'
    'qcpep_snapshot_order=before-wpr-stop'
    'devices_restarted=false'
    'pnp_state_changed=false'
    'direct_cpas_mmio=false'
    'camera_register_access=false'
    'ssc_contacted=false'
) | Out-File -LiteralPath (Join-Path $bundle 'CORRELATION-INFO.txt') -Encoding utf8 -Width 8192

Write-Host ('=' * 76)
Write-Host 'ASUS Zenbook A14 camera activation + qcpep RPMh correlation'
Write-Host ('=' * 76)
Write-Host "Bundle: $bundle"
Write-Host ''
Write-Host 'This collector does not open or control a camera.'
Write-Host 'Close Camera and every other app using a camera before starting.'
Write-Host 'Leave normal camera devices enabled; do not use Device Manager or custom camera tools.'
Write-Host ''
Read-Host 'Press ENTER when all camera preview applications are closed' | Out-Null

Add-Marker -Path $markers -Name 'correlation_started'

try {
    Add-Marker -Path $markers -Name 'wpr_start_requested'
    Invoke-Wpr -Arguments @('-start', 'Power', '-filemode') -LogPath (Join-Path $bundle 'wpr-start.txt')
    $traceStarted = $true
    Add-Marker -Path $markers -Name 'wpr_started'

    Write-Host ''
    Write-Host 'WPR IS RUNNING.' -ForegroundColor Green
    Read-Host 'Press ENTER immediately before manually opening the normal Windows Camera app' | Out-Null
    Add-Marker -Path $markers -Name 'camera_open_window_started'

    Write-Host 'Open Camera now. Wait until the live preview is visibly updating.'
    Read-Host 'Press ENTER immediately once live preview is definitely visible' | Out-Null
    Add-Marker -Path $markers -Name 'camera_preview_visible'

    if ($PreviewHoldSeconds -gt 0) {
        Start-Sleep -Seconds $PreviewHoldSeconds
    }
    Add-Marker -Path $markers -Name 'activation_hold_complete'

    Write-Host ''
    Write-Host 'KEEP CAMERA OPEN until this script says the WPR trace is saved.' -ForegroundColor Yellow
    Write-Host 'Capturing the private qcpep buffer now...'
    Add-Marker -Path $markers -Name 'qcpep_snapshot_requested'
    & $snapshotScript -OutputRoot $bundle
    $snapshotSucceeded = $true
    Add-Marker -Path $markers -Name 'qcpep_snapshot_returned'

    $snapshotDirectory = Get-NewestDirectory -Root $bundle -Filter 'A14-QCPEP-RPMH-Snapshot-*'
    if ($null -eq $snapshotDirectory) {
        throw 'qcpep snapshot completed without a snapshot directory.'
    }
    Remove-ChildZip -Directory $snapshotDirectory

    Add-Marker -Path $markers -Name 'wpr_stop_requested'
    Invoke-Wpr -Arguments @('-stop', $etl) -LogPath (Join-Path $bundle 'wpr-stop.txt')
    $traceStopped = $true
    Add-Marker -Path $markers -Name 'wpr_stop_returned'
    Write-Host 'WPR trace saved. You may close Camera now.' -ForegroundColor Green
}
catch {
    $failureMessage = $_.Exception.Message
    Add-Marker -Path $markers -Name 'capture_failed'
}
finally {
    if ($traceStarted -and -not $traceStopped) {
        $recoveryEtl = Join-Path $bundle 'camera-activation-power-recovery.etl'
        try {
            Add-Marker -Path $markers -Name 'wpr_recovery_stop_requested'
            Invoke-Wpr -Arguments @('-stop', $recoveryEtl) -LogPath (Join-Path $bundle 'wpr-recovery-stop.txt')
            $traceStopped = $true
            Add-Marker -Path $markers -Name 'wpr_recovery_stop_returned'
            if (-not (Test-Path -LiteralPath $etl -PathType Leaf) -and (Test-Path -LiteralPath $recoveryEtl -PathType Leaf)) {
                $etl = $recoveryEtl
            }
        }
        catch {
            "recovery_stop_failed=$($_.Exception.Message)" |
                Add-Content -LiteralPath $failurePath -Encoding utf8
            [void](Invoke-WprBestEffort -Arguments @('-cancel') -LogPath (Join-Path $bundle 'wpr-cancel.txt'))
        }
    }
}

$etlExists = Test-Path -LiteralPath $etl -PathType Leaf
$etlBytes = if ($etlExists) { (Get-Item -LiteralPath $etl).Length } else { 0 }

if ($etlExists -and $etlBytes -gt 0) {
    try {
        Add-Marker -Path $markers -Name 'kernel_power_decode_started'
        & $kernelPowerExporter -TracePath $etl -OutputRoot $bundle
        $kernelPowerDecodeSucceeded = $true
        Add-Marker -Path $markers -Name 'kernel_power_decode_returned'
        $kernelPowerDirectory = Get-NewestDirectory -Root $bundle -Filter 'A14-Camera-Platform-Kernel-Power-Export-*'
        Remove-ChildZip -Directory $kernelPowerDirectory
    }
    catch {
        if (-not $failureMessage) { $failureMessage = "Kernel-Power decode failed: $($_.Exception.Message)" }
    }
}
elseif (-not $failureMessage) {
    $failureMessage = 'WPR did not produce a non-empty ETL.'
}

if ($null -ne $snapshotDirectory) {
    try {
        Add-Marker -Path $markers -Name 'qcpep_raw_decode_started'
        & $rawDumper -TracePath $snapshotDirectory.FullName -OutputRoot $bundle
        $rawDecodeSucceeded = $true
        Add-Marker -Path $markers -Name 'qcpep_raw_decode_returned'
        $rawDirectory = Get-NewestDirectory -Root $bundle -Filter 'A14-QCPEP-RPMH-Raw-*'
        Remove-ChildZip -Directory $rawDirectory
    }
    catch {
        if (-not $failureMessage) { $failureMessage = "qcpep raw decode failed: $($_.Exception.Message)" }
    }
}

@(
    "completed_at=$((Get-Date).ToString('o'))"
    "wpr_trace_started=$traceStarted"
    "wpr_trace_stopped=$traceStopped"
    "wpr_etl=$etl"
    "wpr_etl_exists=$etlExists"
    "wpr_etl_bytes=$etlBytes"
    "qcpep_snapshot_succeeded=$snapshotSucceeded"
    "kernel_power_decode_succeeded=$kernelPowerDecodeSucceeded"
    "qcpep_raw_decode_succeeded=$rawDecodeSucceeded"
    "failure=$(if ($failureMessage) { $failureMessage } else { '' })"
    'scope=camera-bring-up-only'
    'camera_opened_by_collector=false'
    'camera_platform_ioctl_sent_by_collector=false'
    'qcpep_snapshot_while_preview_active=true'
    'qcpep_snapshot_order=before-wpr-stop'
    'devices_restarted=false'
    'pnp_state_changed=false'
    'direct_cpas_mmio=false'
    'camera_register_access=false'
    'ssc_contacted=false'
) | Out-File -LiteralPath $resultPath -Encoding utf8 -Width 8192

if ($failureMessage) {
    @(
        "failed_at=$((Get-Date).ToString('o'))"
        "message=$failureMessage"
        "wpr_trace_started=$traceStarted"
        "wpr_trace_stopped=$traceStopped"
        "qcpep_snapshot_succeeded=$snapshotSucceeded"
        "kernel_power_decode_succeeded=$kernelPowerDecodeSucceeded"
        "qcpep_raw_decode_succeeded=$rawDecodeSucceeded"
    ) | Out-File -LiteralPath $failurePath -Encoding utf8 -Width 8192
}
else {
    Add-Marker -Path $markers -Name 'correlation_completed'
}

$zip = "$bundle.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -LiteralPath $bundle -DestinationPath $zip -CompressionLevel Optimal

Write-Host ''
Write-Host "WPR trace:            $traceStopped"
Write-Host "WPR ETL bytes:        $etlBytes"
Write-Host "qcpep snapshot:       $snapshotSucceeded"
Write-Host "Kernel-Power decode:  $kernelPowerDecodeSucceeded"
Write-Host "qcpep raw decode:     $rawDecodeSucceeded"
Write-Host "Correlation archive:  $zip"

if ($failureMessage) {
    throw "Correlation was only partially completed: $failureMessage. Upload the archive for recovery analysis."
}

Write-Host 'Upload the correlation ZIP. No direct camera/AOS/CPAS/SSC operation was performed by the collector.'
