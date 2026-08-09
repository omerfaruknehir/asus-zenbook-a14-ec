#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputRoot = "$env:USERPROFILE\Desktop"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Snapshot the already-running Qualcomm PEP RPMh ETW buffering session.
# The EventTracingManagement Save-EtwTraceSession path has been observed to
# fail through its CIM/RPC Send-EtwTraceSession backend on this machine.
# Instead, use the documented native ETW ControlTraceW API with only:
#   EVENT_TRACE_CONTROL_QUERY = 0
#   EVENT_TRACE_CONTROL_FLUSH = 3
# FLUSH is the documented operation for writing a buffering-mode/in-memory
# trace to a file. This script never uses STOP or UPDATE and never touches PnP,
# camera, platform IOCTLs, CPAS, or SSC.

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
    throw 'Run this script from an elevated Windows PowerShell window.'
}

Import-Module EventTracingManagement -ErrorAction Stop
if (-not (Get-Command Get-EtwTraceSession -ErrorAction SilentlyContinue)) {
    throw 'Required EventTracingManagement cmdlet is unavailable: Get-EtwTraceSession'
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

$sessionGuid = [Guid]::Empty
$guidProperty = $autologger.PSObject.Properties['Guid']
if ($null -ne $guidProperty -and $null -ne $guidProperty.Value) {
    try { $sessionGuid = [Guid]([string]$guidProperty.Value) } catch { }
}
if ($sessionGuid -eq [Guid]::Empty) {
    throw 'Refusing snapshot: qcpep-rpmh autologger session Guid could not be resolved.'
}

$sessionBefore = @(Get-EtwTraceSession -Name $sessionName -ErrorAction Stop)
if ($sessionBefore.Count -ne 1) {
    throw "Expected exactly one running ETW session named $sessionName; found $($sessionBefore.Count)."
}
$sessionBefore = $sessionBefore[0]

$liveMode = Get-UInt32Property -Object $sessionBefore -Name 'LogFileMode'
if ($null -ne $liveMode -and (($liveMode -band $bufferingModeBit) -eq 0)) {
    throw ('Refusing snapshot: live qcpep-rpmh LogFileMode 0x{0:X} is not buffering mode.' -f $liveMode)
}

$nativeSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class A14EtwBufferSnapshot
{
    private const uint EVENT_TRACE_CONTROL_QUERY = 0;
    private const uint EVENT_TRACE_CONTROL_FLUSH = 3;
    private const uint WNODE_FLAG_TRACED_GUID = 0x00020000;

    [StructLayout(LayoutKind.Sequential)]
    private struct WNODE_HEADER
    {
        public uint BufferSize;
        public uint ProviderId;
        public ulong HistoricalContext;
        public long TimeStamp;
        public Guid Guid;
        public uint ClientContext;
        public uint Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct EVENT_TRACE_PROPERTIES
    {
        public WNODE_HEADER Wnode;
        public uint BufferSize;
        public uint MinimumBuffers;
        public uint MaximumBuffers;
        public uint MaximumFileSize;
        public uint LogFileMode;
        public uint FlushTimer;
        public uint EnableFlags;
        public int AgeLimit;
        public uint NumberOfBuffers;
        public uint FreeBuffers;
        public uint EventsLost;
        public uint BuffersWritten;
        public uint LogBuffersLost;
        public uint RealTimeBuffersLost;
        public IntPtr LoggerThreadId;
        public uint LogFileNameOffset;
        public uint LoggerNameOffset;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern uint ControlTraceW(
        ulong TraceHandle,
        string InstanceName,
        IntPtr Properties,
        uint ControlCode);

    private static IntPtr AllocateProperties(
        string sessionName,
        string logFileName,
        Guid sessionGuid,
        uint logFileMode,
        out int allocationSize)
    {
        int propsSize = Marshal.SizeOf(typeof(EVENT_TRACE_PROPERTIES));
        int loggerBytes = (sessionName.Length + 1) * 2;
        int fileBytes = (logFileName.Length + 1) * 2;
        allocationSize = checked(propsSize + loggerBytes + fileBytes);

        IntPtr buffer = Marshal.AllocHGlobal(allocationSize);
        for (int offset = 0; offset < allocationSize; offset += 8)
        {
            int remaining = allocationSize - offset;
            if (remaining >= 8) Marshal.WriteInt64(buffer, offset, 0L);
            else
            {
                for (int tail = 0; tail < remaining; tail++)
                    Marshal.WriteByte(buffer, offset + tail, 0);
            }
        }

        EVENT_TRACE_PROPERTIES props = new EVENT_TRACE_PROPERTIES();
        props.Wnode.BufferSize = (uint)allocationSize;
        props.Wnode.Guid = sessionGuid;
        props.Wnode.Flags = WNODE_FLAG_TRACED_GUID;
        props.LogFileMode = logFileMode;
        props.LoggerNameOffset = (uint)propsSize;
        props.LogFileNameOffset = (uint)(propsSize + loggerBytes);
        Marshal.StructureToPtr(props, buffer, false);

        char[] loggerChars = (sessionName + "\0").ToCharArray();
        Marshal.Copy(loggerChars, 0, IntPtr.Add(buffer, propsSize), loggerChars.Length);
        char[] fileChars = (logFileName + "\0").ToCharArray();
        Marshal.Copy(fileChars, 0, IntPtr.Add(buffer, propsSize + loggerBytes), fileChars.Length);
        return buffer;
    }

    private static EVENT_TRACE_PROPERTIES ReadProperties(IntPtr buffer)
    {
        return (EVENT_TRACE_PROPERTIES)Marshal.PtrToStructure(
            buffer, typeof(EVENT_TRACE_PROPERTIES));
    }

    public sealed class SnapshotResult
    {
        public uint QueryStatus { get; set; }
        public uint FlushStatus { get; set; }
        public uint ModeBefore { get; set; }
        public uint ModeAfter { get; set; }
        public uint EventsLostBefore { get; set; }
        public uint EventsLostAfter { get; set; }
        public uint BuffersWrittenBefore { get; set; }
        public uint BuffersWrittenAfter { get; set; }
    }

    public static SnapshotResult FlushBufferingSession(
        string sessionName,
        string outputFile,
        Guid sessionGuid,
        uint expectedMode)
    {
        int size;
        IntPtr query = AllocateProperties(
            sessionName, outputFile, sessionGuid, expectedMode, out size);
        try
        {
            uint queryStatus = ControlTraceW(
                0, sessionName, query, EVENT_TRACE_CONTROL_QUERY);
            if (queryStatus != 0)
                throw new Win32Exception((int)queryStatus,
                    "ControlTraceW QUERY failed");

            EVENT_TRACE_PROPERTIES before = ReadProperties(query);
            if ((before.LogFileMode & 0x400U) == 0)
                throw new InvalidOperationException(
                    "Live ETW session is not in EVENT_TRACE_BUFFERING_MODE.");

            // Use a freshly zeroed property block for FLUSH, preserving the
            // queried session GUID/mode and supplying only the target log file.
            int flushSize;
            IntPtr flush = AllocateProperties(
                sessionName, outputFile, before.Wnode.Guid,
                before.LogFileMode, out flushSize);
            try
            {
                uint flushStatus = ControlTraceW(
                    0, sessionName, flush, EVENT_TRACE_CONTROL_FLUSH);
                if (flushStatus != 0)
                    throw new Win32Exception((int)flushStatus,
                        "ControlTraceW FLUSH failed");

                // Query again to prove the same session still exists and its
                // logging mode did not change. QUERY is read-only.
                int afterSize;
                IntPtr afterPtr = AllocateProperties(
                    sessionName, outputFile, before.Wnode.Guid,
                    before.LogFileMode, out afterSize);
                try
                {
                    uint afterStatus = ControlTraceW(
                        0, sessionName, afterPtr, EVENT_TRACE_CONTROL_QUERY);
                    if (afterStatus != 0)
                        throw new Win32Exception((int)afterStatus,
                            "ControlTraceW post-FLUSH QUERY failed");
                    EVENT_TRACE_PROPERTIES after = ReadProperties(afterPtr);
                    if (after.LogFileMode != before.LogFileMode)
                        throw new InvalidOperationException(
                            "ETW session LogFileMode changed across FLUSH.");

                    return new SnapshotResult {
                        QueryStatus = queryStatus,
                        FlushStatus = flushStatus,
                        ModeBefore = before.LogFileMode,
                        ModeAfter = after.LogFileMode,
                        EventsLostBefore = before.EventsLost,
                        EventsLostAfter = after.EventsLost,
                        BuffersWrittenBefore = before.BuffersWritten,
                        BuffersWrittenAfter = after.BuffersWritten
                    };
                }
                finally { Marshal.FreeHGlobal(afterPtr); }
            }
            finally { Marshal.FreeHGlobal(flush); }
        }
        finally { Marshal.FreeHGlobal(query); }
    }
}
'@

if (-not ('A14EtwBufferSnapshot' -as [type])) {
    Add-Type -TypeDefinition $nativeSource -Language CSharp -ErrorAction Stop
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
    "session_guid=$sessionGuid"
    "provider_guid=$providerGuid"
    ('registry_log_file_mode=0x{0:X}' -f $registryMode)
    'registry_buffering_mode=true'
    "live_log_file_mode=$(if ($null -eq $liveMode) { 'not-exposed' } else { '0x{0:X}' -f $liveMode })"
    'operation=native-controltrace-buffer-flush'
    'etw_control_query=true'
    'etw_control_flush=true'
    'etw_control_update=false'
    'etw_control_stop=false'
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

Write-Host ('=' * 76)
Write-Host 'ASUS Zenbook A14 qcpep RPMh buffering-session snapshot'
Write-Host ('=' * 76)
Write-Host "Session: $sessionName"
Write-Host "Output:  $output"
Write-Host 'Native ETW QUERY+FLUSH only; no STOP/UPDATE/reconfigure/hardware operation.'
Write-Host ''

try {
    $nativeResult = [A14EtwBufferSnapshot]::FlushBufferingSession(
        $sessionName,
        $etl,
        $sessionGuid,
        $registryMode)
}
catch {
    @(
        "failed_at=$((Get-Date).ToString('o'))"
        'snapshot_status=failed'
        "exception=$($_.Exception.GetType().FullName)"
        "message=$($_.Exception.Message)"
        'etw_control_update=false'
        'etw_control_stop=false'
        'session_started_by_collector=false'
        'session_stopped_by_collector=false'
        'session_reconfigured_by_collector=false'
        'pnp_state_changed=false'
        'power_state_changed=false'
        'camera_state_changed=false'
        'direct_cpas_mmio=false'
        'ssc_contacted=false'
    ) | Out-File -LiteralPath (Join-Path $output 'SNAPSHOT-FAILED.txt') -Encoding utf8 -Width 8192
    throw
}

if (-not (Test-Path -LiteralPath $etl -PathType Leaf)) {
    throw "ControlTraceW FLUSH returned success without producing the expected ETL: $etl"
}
$etlItem = Get-Item -LiteralPath $etl
if ($etlItem.Length -le 0) {
    throw "qcpep-rpmh snapshot ETL is empty: $etl"
}

$sessionAfter = @(Get-EtwTraceSession -Name $sessionName -ErrorAction Stop)
if ($sessionAfter.Count -ne 1) {
    throw "qcpep-rpmh session is not still running after FLUSH; found $($sessionAfter.Count)."
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
    'snapshot_status=success'
    "native_query_status=$($nativeResult.QueryStatus)"
    "native_flush_status=$($nativeResult.FlushStatus)"
    ('native_mode_before=0x{0:X}' -f $nativeResult.ModeBefore)
    ('native_mode_after=0x{0:X}' -f $nativeResult.ModeAfter)
    "native_events_lost_before=$($nativeResult.EventsLostBefore)"
    "native_events_lost_after=$($nativeResult.EventsLostAfter)"
    "native_buffers_written_before=$($nativeResult.BuffersWrittenBefore)"
    "native_buffers_written_after=$($nativeResult.BuffersWrittenAfter)"
    'session_still_running=true'
    "session_count_after=$($sessionAfter.Count)"
    "live_log_file_mode_after=$(if ($null -eq $afterMode) { 'not-exposed' } else { '0x{0:X}' -f $afterMode })"
    'etw_control_update=false'
    'etw_control_stop=false'
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
Write-Host 'Upload the ZIP. No ETW session stop/update and no hardware operation occurred.'
