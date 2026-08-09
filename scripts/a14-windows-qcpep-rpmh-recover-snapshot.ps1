#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$SnapshotDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Recovery/packaging only. This helper exists for snapshots where the native
# QUERY+FLUSH already succeeded but a later reporting step failed. It performs
# no ETW control operation and never starts/stops/updates/reconfigures a trace.

$sessionName = 'qcpep-rpmh'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    throw 'Run this script from an elevated Windows PowerShell window.'
}

$directory = (Resolve-Path -LiteralPath $SnapshotDirectory -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    throw "Snapshot directory does not exist: $directory"
}

$etl = Join-Path $directory 'qcpep-rpmh.etl'
if (-not (Test-Path -LiteralPath $etl -PathType Leaf)) {
    throw "Expected snapshot ETL is missing: $etl"
}
$etlItem = Get-Item -LiteralPath $etl
if ($etlItem.Length -le 0) {
    throw "Snapshot ETL is empty: $etl"
}

# The original helper reaches its scalar .Count reporting bug only after its
# native post-FLUSH QUERY and a successful Get-EtwTraceSession verification.
# Re-check the session here without changing it so the recovery artifact also
# records that qcpep-rpmh is still present.
Import-Module EventTracingManagement -ErrorAction Stop
$sessionObjects = @(Get-EtwTraceSession -Name $sessionName -ErrorAction Stop)
$sessionCount = @($sessionObjects).Count
if ($sessionCount -ne 1) {
    throw "Expected exactly one running ETW session named $sessionName; found $sessionCount."
}
$session = $sessionObjects[0]
$session | Format-List * |
    Out-File -LiteralPath (Join-Path $directory 'session-recovery-check.txt') -Encoding utf8 -Width 8192

$failedPath = Join-Path $directory 'SNAPSHOT-FAILED.txt'
$infoPath = Join-Path $directory 'SNAPSHOT-INFO.txt'
$beforePath = Join-Path $directory 'session-before.txt'
$afterPath = Join-Path $directory 'session-after.txt'

@(
    "recovered_at=$((Get-Date).ToString('o'))"
    "snapshot_directory=$directory"
    "etl=$etl"
    "etl_bytes=$($etlItem.Length)"
    "session_name=$sessionName"
    "session_count_recovery=$sessionCount"
    "snapshot_info_present=$(Test-Path -LiteralPath $infoPath -PathType Leaf)"
    "session_before_present=$(Test-Path -LiteralPath $beforePath -PathType Leaf)"
    "session_after_present=$(Test-Path -LiteralPath $afterPath -PathType Leaf)"
    "snapshot_failed_marker_present=$(Test-Path -LiteralPath $failedPath -PathType Leaf)"
    'recovery_reason=post-flush-reporting-scalar-count-bug'
    'native_flush_was_not_repeated=true'
    'operation=filesystem-package-and-read-only-session-check'
    'etw_control_query=false'
    'etw_control_flush=false'
    'etw_control_update=false'
    'etw_control_stop=false'
    'session_started_by_recovery=false'
    'session_stopped_by_recovery=false'
    'session_reconfigured_by_recovery=false'
    'provider_reconfigured_by_recovery=false'
    'pnp_state_changed=false'
    'power_state_changed=false'
    'camera_state_changed=false'
    'platform_ioctl_sent=false'
    'hardware_register_access=false'
    'direct_cpas_mmio=false'
    'ssc_contacted=false'
) | Out-File -LiteralPath (Join-Path $directory 'SNAPSHOT-RECOVERY-RESULT.txt') -Encoding utf8 -Width 8192

$zip = "$directory.zip"
if (Test-Path -LiteralPath $zip) {
    Remove-Item -LiteralPath $zip -Force
}
Compress-Archive -LiteralPath $directory -DestinationPath $zip -CompressionLevel Optimal

Write-Host ('=' * 76)
Write-Host 'ASUS Zenbook A14 qcpep RPMh snapshot recovery/package'
Write-Host ('=' * 76)
Write-Host "Existing ETL: $etl"
Write-Host "ETL bytes:    $($etlItem.Length)"
Write-Host "Session count: $sessionCount"
Write-Host 'Native flush repeated: false' -ForegroundColor Green
Write-Host "Archive:      $zip"
Write-Host 'Upload the ZIP. No ETW control or hardware operation was performed.'
