#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputRoot = "$env:USERPROFILE\Desktop"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Snapshot the already-running Qualcomm PEP RPMh ETW buffering session.
# This helper deliberately does NOT start, stop, update, remove, or reconfigure
# any ETW session/provider and does not touch PnP, camera, power, or hardware.
# Save-EtwTraceSession is used without -Stop.

$sessionName = 'qcpep-rpmh'
$autologgerPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\qcpep-rpmh'
$providerGuid = '{2C89C855-6301-41F9-BF56-63416DFE9CA9}'
$providerPath = Join-Path $autologgerPath $providerGuid
$bufferingModeBit = [uint32]0x400

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Save-ObjectText {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $InputObject | Format-List * | Out-File -LiteralPath $Path -Encoding utf8 -Width 8192
}

function Get-UInt32Property {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $null }
    try { return [uint32]$property.Value } catch { return $null }
}

if (-not (Test-Administrator)) {
    throw 'Run this script from an elevated PowerShell window.'
}

Import-Module EventTracingManagement -ErrorAction Stop
foreach ($cmdlet in @('Get-EtwTraceSession','Save-EtwTraceSession')) {
    if (-not (Get-Command $cmdlet -ErrorAction SilentlyContinue)) {
        throw "Required EventTracingManagement cmdlet is unavailable: $cmdlet"
    }
}

if (-not (Test-Path -LiteralPath $autologgerPath)) {
    throw "Expected Qualcomm PEP autologger registry key is absent: $autologgerPath"
}
if (-not (Test-Path -LiteralPath $providerPath)) {
    throw "Expected qcpep RPMh provider registry key is absent: $providerPath"
}

$autologger = Get-ItemProperty -LiteralPath $autologgerPath
$provider = Get-ItemProperty -LiteralPath $providerPath
$registryMode = [uint32]$autologger.LogFileMode
if (($registryMode -band $bufferingModeBit) -eq 0) {
    throw ('Refusing snapshot: qcpep-rpmh registry LogFileMode 0x{0:X} is not buffering mode.' -f $registryMode)
}
if ([uint32]$provider.Enabled -ne 1) {
    throw "Refusing snapshot: expected provider $providerGuid is not enabled in qcpep-rpmh."
}

$sessionBefore = @(Get-EtwTraceSession -Name $sessionName -ErrorAction Stop)
if ($sessionBefore.Count -ne 1) {
    throw "Expected exactly one running ETW session named $sessionName; found $($sessionBefore.Count)."
}
$sessionBefore = $sessionBefore[0]

# If this OS exposes LogFileMode on the live session, require buffering mode there
# too. Older EventTracingManagement versions may omit the property; the exact
# autologger registry mode remains a required check above.
$liveMode = Get-UInt32Property -Object $sessionBefore -Name 'LogFileMode'
if ($null -ne $liveMode -and (($liveMode -band $bufferingModeBit) -eq 0)) {
    throw ('Refusing snapshot: live qcpep-rpmh LogFileMode 0x{0:X} is not buffering mode.' -f $liveMode)
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $OutputRoot "A14-QCPEP-RPMH-Snapshot-$stamp"
New-Item -ItemType Directory -Force -Path $output | Out-Null
$etl = Join-Path $output 'qcpep-rpmh.etl'

@(
    "collected_at=$((Get-Date).ToString('o'))"
    "computer_name=$env:COMPUTERNAME"
    "powershell_version=$($PSVersionTable.PSVersion)"
    "powershell_edition=$($PSVersionTable.PSEdition)"
    "session_name=$sessionName"
    "provider_guid=$providerGuid"
    ('registry_log_file_mode=0x{0:X}' -f $registryMode)
    "registry_buffering_mode=true"
    "live_log_file_mode=$(if ($null -eq $liveMode) { 'not-exposed' } else { '0x{0:X}' -f $liveMode })"
    'operation=snapshot-existing-buffering-session'
    'session_started_by_collector=false'
    'session_stopped_by_collector=false'
    'session_reconfigured_by_collector=false'
    'provider_reconfigured_by_collector=false'
    'pnp_state_changed=false'
    'power_state_changed=false'
    'camera_state_changed=false'
    'platform_ioctl_sent=false'
    'hardware_register_access=false'
    'direct_cpas_mmio=false'
    'ssc_contacted=false'
) | Out-File -LiteralPath (Join-Path $output 'SNAPSHOT-INFO.txt') -Encoding utf8 -Width 8192

Save-ObjectText -InputObject $sessionBefore -Path (Join-Path $output 'session-before.txt')
Save-ObjectText -InputObject $autologger -Path (Join-Path $output 'autologger-registry.txt')
Save-ObjectText -InputObject $provider -Path (Join-Path $output 'provider-registry.txt')
Get-Command Save-EtwTraceSession -Syntax |
    Out-File -LiteralPath (Join-Path $output 'save-etwtracesession-syntax.txt') -Encoding utf8 -Width 8192

Write-Host ('=' * 76)
Write-Host 'ASUS Zenbook A14 qcpep RPMh buffering-session snapshot'
Write-Host ('=' * 76)
Write-Host "Session: $sessionName"
Write-Host "Output:  $output"
Write-Host 'Existing in-memory ETW session only; no stop/reconfigure/hardware operation.'
Write-Host ''

# Intentionally omit -Stop. Save-EtwTraceSession supports saving a buffering
# session while leaving it running.
$saved = Save-EtwTraceSession -Name $sessionName -OutputFile (Get-Item -LiteralPath $output).PSPath.Replace('Microsoft.PowerShell.Core\FileSystem::','')\qcpep-rpmh.etl -ErrorAction Stop

# Resolve the actual output path from the returned object where possible, with
# the requested path as the fallback.
$savedPath = $etl
if ($null -ne $saved) {
    foreach ($propertyName in @('FullName','Name')) {
        $prop = $saved.PSObject.Properties[$propertyName]
        if ($null -ne $prop -and $null -ne $prop.Value) {
            $candidate = [string]$prop.Value
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $savedPath = (Resolve-Path -LiteralPath $candidate).Path
                break
            }
        }
    }
}

if (-not (Test-Path -LiteralPath $etl -PathType Leaf)) {
    if ($savedPath -ne $etl -and (Test-Path -LiteralPath $savedPath -PathType Leaf)) {
        Copy-Item -LiteralPath $savedPath -Destination $etl -Force
    }
}
if (-not (Test-Path -LiteralPath $etl -PathType Leaf)) {
    throw "Save-EtwTraceSession returned without producing the expected ETL: $etl"
}
$etlItem = Get-Item -LiteralPath $etl
if ($etlItem.Length -le 0) {
    throw "qcpep-rpmh snapshot ETL is empty: $etl"
}

$sessionAfter = @(Get-EtwTraceSession -Name $sessionName -ErrorAction Stop)
if ($sessionAfter.Count -ne 1) {
    throw "qcpep-rpmh session is not still running after snapshot; found $($sessionAfter.Count)."
}
$sessionAfter = $sessionAfter[0]
Save-ObjectText -InputObject $sessionAfter -Path (Join-Path $output 'session-after.txt')

$afterMode = Get-UInt32Property -Object $sessionAfter -Name 'LogFileMode'
if ($null -ne $liveMode -and $null -ne $afterMode -and $liveMode -ne $afterMode) {
    throw ('qcpep-rpmh live LogFileMode changed across snapshot: before=0x{0:X} after=0x{1:X}' -f $liveMode, $afterMode)
}

@(
    "completed_at=$((Get-Date).ToString('o'))"
    "etl=$etl"
    "etl_bytes=$($etlItem.Length)"
    "session_still_running=true"
    "session_count_after=$($sessionAfter.Count)"
    "live_log_file_mode_after=$(if ($null -eq $afterMode) { 'not-exposed' } else { '0x{0:X}' -f $afterMode })"
    'session_started_by_collector=false'
    'session_stopped_by_collector=false'
    'session_reconfigured_by_collector=false'
    'provider_reconfigured_by_collector=false'
    'pnp_state_changed=false'
    'power_state_changed=false'
    'camera_state_changed=false'
    'platform_ioctl_sent=false'
    'hardware_register_access=false'
    'direct_cpas_mmio=false'
    'ssc_contacted=false'
) | Out-File -LiteralPath (Join-Path $output 'SNAPSHOT-RESULT.txt') -Encoding utf8 -Width 8192

$zip = "$output.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -LiteralPath $output -DestinationPath $zip -CompressionLevel Optimal

Write-Host "Snapshot ETL: $etl"
Write-Host "ETL bytes:    $($etlItem.Length)"
Write-Host 'Session still running: true' -ForegroundColor Green
Write-Host "Archive:      $zip"
Write-Host 'Upload the ZIP. Do not stop or reconfigure qcpep-rpmh.'
