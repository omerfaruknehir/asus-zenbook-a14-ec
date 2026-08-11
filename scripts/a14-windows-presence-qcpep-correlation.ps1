#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputRoot = "$env:USERPROFILE\Desktop",
    [ValidateRange(3, 60)][int]$DisabledHoldSeconds = 8,
    [ValidateRange(3, 60)][int]$RestoredHoldSeconds = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Correlate one normal Windows Presence Sensing settings cycle with the
# already-running qcpep-rpmh circular ETW buffer. This script introduces no
# new hardware-control path: it delegates the reversible settings transition
# to the existing HumanPresenceSettings collector, then snapshots qcpep-rpmh
# through the already-validated QUERY+FLUSH helper. Decoding is offline only.

function Add-Marker {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    "$Name=$((Get-Date).ToString('o'))" | Add-Content -LiteralPath $Path -Encoding utf8
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

$presenceScript = Join-Path $PSScriptRoot 'a14-windows-human-presence-settings-cycle-trace.ps1'
$snapshotScript = Join-Path $PSScriptRoot 'a14-windows-qcpep-rpmh-snapshot.ps1'
$kernelPowerExporter = Join-Path $PSScriptRoot 'a14-windows-camera-platform-kernel-power-export.ps1'
$rawDumper = Join-Path $PSScriptRoot 'a14-windows-qcpep-rpmh-raw-dump.ps1'

foreach ($requiredScript in @($presenceScript, $snapshotScript, $kernelPowerExporter, $rawDumper)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "Required correlation helper is missing: $requiredScript"
    }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bundle = Join-Path $OutputRoot "A14-Presence-QCPEP-Correlation-$stamp"
New-Item -ItemType Directory -Force -Path $bundle | Out-Null
$markers = Join-Path $bundle 'CORRELATION-MARKERS.txt'
$resultPath = Join-Path $bundle 'CORRELATION-RESULT.txt'
$failurePath = Join-Path $bundle 'CORRELATION-FAILED.txt'

$presenceSucceeded = $false
$snapshotSucceeded = $false
$kernelPowerDecodeSucceeded = $false
$rawDecodeSucceeded = $false
$failureMessage = $null
$presenceDirectory = $null
$snapshotDirectory = $null
$kernelPowerDirectory = $null
$rawDirectory = $null

@(
    "generated_at=$((Get-Date).ToString('o'))"
    'operation=windows-managed-presence-qcpep-correlation'
    'correlation_trigger=public-HumanPresenceSettings-child'
    'presence_settings_restored_by_child=true'
    'qcpep_source=existing-qcpep-rpmh-buffering-session'
    'qcpep_snapshot_helper=native-query-flush-no-stop-no-update'
    'kernel_power_decode=offline-only'
    'qcpep_raw_decode=offline-only'
    'collector_sends_platform_ioctl=false'
    'collector_acquires_human_presence_sensor=false'
    'devices_restarted=false'
    'pnp_state_changed=false'
    'direct_cpas_mmio=false'
    'camera_register_access=false'
    'ssc_contacted=false'
) | Out-File -LiteralPath (Join-Path $bundle 'CORRELATION-INFO.txt') -Encoding utf8 -Width 8192

Write-Host ('=' * 76)
Write-Host 'ASUS Zenbook A14 Presence Sensing + qcpep RPMh correlation'
Write-Host ('=' * 76)
Write-Host "Bundle: $bundle"
Write-Host ''
Write-Host 'This run reuses the validated public HumanPresenceSettings cycle and the'
Write-Host 'existing qcpep-rpmh buffering-session snapshot helper. No direct camera'
Write-Host 'platform IOCTL, PnP restart, CPAS MMIO, register access, or SSC operation.'
Write-Host ''

Add-Marker -Path $markers -Name 'correlation_started'

try {
    Add-Marker -Path $markers -Name 'presence_cycle_started'
    & $presenceScript `
        -OutputRoot $bundle `
        -DisabledHoldSeconds $DisabledHoldSeconds `
        -RestoredHoldSeconds $RestoredHoldSeconds
    $presenceSucceeded = $true
    Add-Marker -Path $markers -Name 'presence_cycle_returned'

    $presenceDirectory = Get-NewestDirectory -Root $bundle -Filter 'A14-Human-Presence-Settings-Cycle-Trace-*'
    if ($null -eq $presenceDirectory) {
        throw 'Presence settings cycle returned without a trace directory.'
    }
    Remove-RedundantChildArchive -Directory $presenceDirectory

    # Snapshot immediately after the reversible Windows-managed transition.
    # The child helper verifies the qcpep-rpmh session remains running and uses
    # ETW QUERY + FLUSH only; no STOP or UPDATE control code exists in it.
    Add-Marker -Path $markers -Name 'qcpep_snapshot_requested'
    & $snapshotScript -OutputRoot $bundle
    $snapshotSucceeded = $true
    Add-Marker -Path $markers -Name 'qcpep_snapshot_returned'

    $snapshotDirectory = Get-NewestDirectory -Root $bundle -Filter 'A14-QCPEP-RPMH-Snapshot-*'
    if ($null -eq $snapshotDirectory) {
        throw 'qcpep snapshot returned without a snapshot directory.'
    }
    Remove-RedundantChildArchive -Directory $snapshotDirectory

    Add-Marker -Path $markers -Name 'kernel_power_decode_started'
    & $kernelPowerExporter -TracePath $presenceDirectory.FullName -OutputRoot $bundle
    $kernelPowerDecodeSucceeded = $true
    Add-Marker -Path $markers -Name 'kernel_power_decode_returned'
    $kernelPowerDirectory = Get-NewestDirectory -Root $bundle -Filter 'A14-Camera-Platform-Kernel-Power-Export-*'
    Remove-RedundantChildArchive -Directory $kernelPowerDirectory

    Add-Marker -Path $markers -Name 'qcpep_raw_decode_started'
    & $rawDumper -TracePath $snapshotDirectory.FullName -OutputRoot $bundle
    $rawDecodeSucceeded = $true
    Add-Marker -Path $markers -Name 'qcpep_raw_decode_returned'
    $rawDirectory = Get-NewestDirectory -Root $bundle -Filter 'A14-QCPEP-RPMH-Raw-*'
    Remove-RedundantChildArchive -Directory $rawDirectory

    Add-Marker -Path $markers -Name 'correlation_completed'
}
catch {
    $failureMessage = $_.Exception.Message
    Add-Marker -Path $markers -Name 'correlation_failed'
    @(
        "failed_at=$((Get-Date).ToString('o'))"
        "message=$failureMessage"
        "presence_succeeded=$presenceSucceeded"
        "qcpep_snapshot_succeeded=$snapshotSucceeded"
        "kernel_power_decode_succeeded=$kernelPowerDecodeSucceeded"
        "qcpep_raw_decode_succeeded=$rawDecodeSucceeded"
        'collector_sends_platform_ioctl=false'
        'devices_restarted=false'
        'pnp_state_changed=false'
        'direct_cpas_mmio=false'
        'ssc_contacted=false'
    ) | Out-File -LiteralPath $failurePath -Encoding utf8 -Width 8192
}

@(
    "completed_at=$((Get-Date).ToString('o'))"
    "presence_succeeded=$presenceSucceeded"
    "qcpep_snapshot_succeeded=$snapshotSucceeded"
    "kernel_power_decode_succeeded=$kernelPowerDecodeSucceeded"
    "qcpep_raw_decode_succeeded=$rawDecodeSucceeded"
    "presence_directory=$(if ($presenceDirectory) { $presenceDirectory.FullName } else { '' })"
    "qcpep_snapshot_directory=$(if ($snapshotDirectory) { $snapshotDirectory.FullName } else { '' })"
    "kernel_power_directory=$(if ($kernelPowerDirectory) { $kernelPowerDirectory.FullName } else { '' })"
    "qcpep_raw_directory=$(if ($rawDirectory) { $rawDirectory.FullName } else { '' })"
    "failure=$(if ($failureMessage) { $failureMessage } else { '' })"
    'settings_transition=public-Windows-API-child-only'
    'qcpep_snapshot=existing-session-query-flush-child-only'
    'live_etw_provider_reconfigured=false'
    'collector_sends_platform_ioctl=false'
    'collector_acquires_human_presence_sensor=false'
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
Write-Host "Presence cycle:       $presenceSucceeded"
Write-Host "qcpep snapshot:       $snapshotSucceeded"
Write-Host "Kernel-Power decode:  $kernelPowerDecodeSucceeded"
Write-Host "qcpep raw decode:     $rawDecodeSucceeded"
Write-Host "Correlation archive:  $zip"

if ($failureMessage) {
    throw "Correlation run was only partially completed: $failureMessage. Upload the archive for recovery analysis."
}

Write-Host 'Upload the correlation ZIP. No direct AOS/CPAS/SSC operation was performed.'
