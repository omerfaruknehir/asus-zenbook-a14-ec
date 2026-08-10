#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$BundlePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Offline-only recovery for a camera-preview/qcpep correlation bundle whose
# capture already ran. This script performs NO WPR/ETW control operation and NO
# hardware/device operation. It only inspects existing files, runs the existing
# offline decoders, and repackages the bundle.

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

$resolved = Resolve-Path -LiteralPath $BundlePath -ErrorAction Stop
$bundle = Get-Item -LiteralPath $resolved.Path -ErrorAction Stop
if (-not $bundle.PSIsContainer) {
    throw 'BundlePath must point to the existing A14-Camera-Preview-QCPEP-Correlation-* directory.'
}

$kernelPowerExporter = Join-Path $PSScriptRoot 'a14-windows-camera-platform-kernel-power-export.ps1'
$rawDumper = Join-Path $PSScriptRoot 'a14-windows-qcpep-rpmh-raw-dump.ps1'
foreach ($requiredScript in @($kernelPowerExporter, $rawDumper)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "Required offline decoder is missing: $requiredScript"
    }
}

$snapshotDirectory = Get-NewestDirectory -Root $bundle.FullName -Filter 'A14-QCPEP-RPMH-Snapshot-*'
if ($null -eq $snapshotDirectory) {
    throw 'No existing qcpep snapshot directory was found in the bundle.'
}
$snapshotEtl = Get-ChildItem -LiteralPath $snapshotDirectory.FullName -File -Filter 'qcpep-rpmh.etl' |
    Select-Object -First 1
if ($null -eq $snapshotEtl -or $snapshotEtl.Length -le 0) {
    throw 'The existing qcpep snapshot ETL is missing or empty.'
}

$wprCandidates = @(
    Get-ChildItem -LiteralPath $bundle.FullName -File -Filter 'camera-preview-power*.etl' -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $bundle.FullName -File -Filter '*recovery*.etl' -ErrorAction SilentlyContinue
) | Where-Object { $_.Length -gt 0 } | Sort-Object Length -Descending
$wprEtl = $wprCandidates | Select-Object -First 1

$markers = Join-Path $bundle.FullName 'CORRELATION-MARKERS.txt'
$resultPath = Join-Path $bundle.FullName 'RECOVERY-RESULT.txt'
$kernelPowerSucceeded = $false
$rawSucceeded = $false
$kernelPowerDirectory = $null
$rawDirectory = $null
$failure = $null

Write-Host ('=' * 76)
Write-Host 'ASUS Zenbook A14 camera-preview/qcpep offline recovery'
Write-Host ('=' * 76)
Write-Host "Bundle:          $($bundle.FullName)"
Write-Host "qcpep ETL:       $($snapshotEtl.FullName)"
Write-Host "qcpep ETL bytes: $($snapshotEtl.Length)"
if ($null -ne $wprEtl) {
    Write-Host "WPR ETL:         $($wprEtl.FullName)"
    Write-Host "WPR ETL bytes:   $($wprEtl.Length)"
}
else {
    Write-Host 'WPR ETL:         not found'
}
Write-Host 'Offline decode/package only; no WPR/ETW control or hardware operation.'
Write-Host ''

try {
    & $rawDumper -TracePath $snapshotDirectory.FullName -OutputRoot $bundle.FullName
    $rawSucceeded = $true
    $rawDirectory = Get-NewestDirectory -Root $bundle.FullName -Filter 'A14-QCPEP-RPMH-Raw-*'
    Remove-RedundantChildArchive -Directory $rawDirectory
}
catch {
    $failure = "qcpep raw decode failed: $($_.Exception.Message)"
}

if ($null -ne $wprEtl) {
    try {
        & $kernelPowerExporter -TracePath $wprEtl.FullName -OutputRoot $bundle.FullName
        $kernelPowerSucceeded = $true
        $kernelPowerDirectory = Get-NewestDirectory -Root $bundle.FullName -Filter 'A14-Camera-Platform-Kernel-Power-Export-*'
        Remove-RedundantChildArchive -Directory $kernelPowerDirectory
    }
    catch {
        $message = "Kernel-Power decode failed: $($_.Exception.Message)"
        $failure = if ($failure) { "$failure; $message" } else { $message }
    }
}
else {
    $message = 'No completed WPR ETL was found. qcpep/marker evidence is still preserved, but CAMP PoFx correlation cannot be proven from this bundle alone.'
    $failure = if ($failure) { "$failure; $message" } else { $message }
}

@(
    "recovered_at=$((Get-Date).ToString('o'))"
    "bundle=$($bundle.FullName)"
    "markers_exist=$(Test-Path -LiteralPath $markers -PathType Leaf)"
    "qcpep_snapshot_directory=$($snapshotDirectory.FullName)"
    "qcpep_etl=$($snapshotEtl.FullName)"
    "qcpep_etl_bytes=$($snapshotEtl.Length)"
    "wpr_etl=$(if ($wprEtl) { $wprEtl.FullName } else { '' })"
    "wpr_etl_bytes=$(if ($wprEtl) { $wprEtl.Length } else { 0 })"
    "qcpep_raw_decode_succeeded=$rawSucceeded"
    "kernel_power_decode_succeeded=$kernelPowerSucceeded"
    "qcpep_raw_directory=$(if ($rawDirectory) { $rawDirectory.FullName } else { '' })"
    "kernel_power_directory=$(if ($kernelPowerDirectory) { $kernelPowerDirectory.FullName } else { '' })"
    "failure=$failure"
    'recovery_live_etw_control=false'
    'recovery_wpr_control=false'
    'camera_opened_by_recovery=false'
    'camera_ioctls_sent_by_recovery=false'
    'devices_restarted=false'
    'pnp_state_changed=false'
    'direct_cpas_mmio=false'
    'camera_register_access=false'
    'ssc_contacted=false'
) | Out-File -LiteralPath $resultPath -Encoding utf8 -Width 8192

# Child snapshot helper created an archive before the parent failed. Remove only
# redundant child ZIPs; the underlying directories/ETLs remain untouched.
Remove-RedundantChildArchive -Directory $snapshotDirectory

$zip = "$($bundle.FullName).zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -LiteralPath $bundle.FullName -DestinationPath $zip -CompressionLevel Optimal

Write-Host ''
Write-Host "qcpep raw decode:     $rawSucceeded"
Write-Host "Kernel-Power decode:  $kernelPowerSucceeded"
Write-Host "Recovered archive:    $zip"
if ($failure) {
    Write-Host "Recovery note:         $failure" -ForegroundColor Yellow
}
Write-Host 'Upload the recovered ZIP. No live ETW/WPR or hardware state was changed.'
