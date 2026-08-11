#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$TracePath,

    [string]$OutputRoot = "$env:USERPROFILE\Desktop",

    [switch]$CompileOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Offline-only ETL consumer for the two WPP provider GUIDs observed in the
# qcpep-rpmh buffering-session snapshot and embedded in qcpep8380.sys.
#
# This script uses only the ETW *consumer* APIs OpenTraceW / ProcessTrace /
# CloseTrace against a supplied ETL file. It never starts, stops, flushes,
# updates, enables, disables, or otherwise controls any ETW session/provider.
# It performs no PnP, power, camera, CPAS, MMIO, or SSC operation.

$providerRpmh = [Guid]'4E3AEACE-0120-3F12-A3B8-B0F231C22453'
$providerAux  = [Guid]'B844D345-3584-316E-F5DD-A946E820B3EB'
$working = Join-Path ([IO.Path]::GetTempPath()) ("A14-QCPEP-Raw-{0}" -f ([Guid]::NewGuid().ToString('N')))
$expandedDirectory = $null

function Resolve-TraceEtl {
    param([Parameter(Mandatory = $true)][string]$InputPath)

    $resolved = Resolve-Path -LiteralPath $InputPath -ErrorAction Stop
    $item = Get-Item -LiteralPath $resolved.Path

    if (-not $item.PSIsContainer -and $item.Extension -ieq '.etl') {
        return $item.FullName
    }

    if (-not $item.PSIsContainer -and $item.Extension -ieq '.zip') {
        $script:expandedDirectory = Join-Path $working 'expanded-trace'
        New-Item -ItemType Directory -Force -Path $script:expandedDirectory | Out-Null
        Expand-Archive -LiteralPath $item.FullName -DestinationPath $script:expandedDirectory -Force
        $etl = Get-ChildItem -LiteralPath $script:expandedDirectory -File -Recurse -Filter '*.etl' |
            Sort-Object Length -Descending |
            Select-Object -First 1
        if (-not $etl) { throw "No ETL file was found inside $($item.FullName)." }
        return $etl.FullName
    }

    if ($item.PSIsContainer) {
        $etl = Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Filter '*.etl' |
            Sort-Object Length -Descending |
            Select-Object -First 1
        if (-not $etl) { throw "No ETL file was found under $($item.FullName)." }
        return $etl.FullName
    }

    throw 'TracePath must point to a qcpep RPMh trace ZIP, directory, or ETL file.'
}

$nativeSource = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class A14QcpepRawEtlConsumer
{
    private const uint PROCESS_TRACE_MODE_EVENT_RECORD = 0x10000000U;
    private const ulong INVALID_PROCESSTRACE_HANDLE = ulong.MaxValue;

    private static readonly Guid ProviderRpmh = new Guid("4E3AEACE-0120-3F12-A3B8-B0F231C22453");
    private static readonly Guid ProviderAux = new Guid("B844D345-3584-316E-F5DD-A946E820B3EB");

    [StructLayout(LayoutKind.Explicit, Size = 16)]
    private struct EVENT_DESCRIPTOR
    {
        [FieldOffset(0)] public ushort Id;
        [FieldOffset(2)] public byte Version;
        [FieldOffset(3)] public byte Channel;
        [FieldOffset(4)] public byte Level;
        [FieldOffset(5)] public byte Opcode;
        [FieldOffset(6)] public ushort Task;
        [FieldOffset(8)] public ulong Keyword;
    }

    [StructLayout(LayoutKind.Explicit, Size = 80)]
    private struct EVENT_HEADER
    {
        [FieldOffset(0)] public ushort Size;
        [FieldOffset(2)] public ushort HeaderType;
        [FieldOffset(4)] public ushort Flags;
        [FieldOffset(6)] public ushort EventProperty;
        [FieldOffset(8)] public uint ThreadId;
        [FieldOffset(12)] public uint ProcessId;
        [FieldOffset(16)] public long TimeStamp;
        [FieldOffset(24)] public Guid ProviderId;
        [FieldOffset(40)] public EVENT_DESCRIPTOR EventDescriptor;
        [FieldOffset(56)] public ulong ProcessorTime;
        [FieldOffset(64)] public Guid ActivityId;
    }

    [StructLayout(LayoutKind.Explicit, Size = 4)]
    private struct ETW_BUFFER_CONTEXT
    {
        [FieldOffset(0)] public ushort ProcessorIndex;
        [FieldOffset(2)] public ushort LoggerId;
    }

    [StructLayout(LayoutKind.Explicit, Size = 112)]
    private struct EVENT_RECORD
    {
        [FieldOffset(0)] public EVENT_HEADER EventHeader;
        [FieldOffset(80)] public ETW_BUFFER_CONTEXT BufferContext;
        [FieldOffset(84)] public ushort ExtendedDataCount;
        [FieldOffset(86)] public ushort UserDataLength;
        [FieldOffset(88)] public IntPtr ExtendedData;
        [FieldOffset(96)] public IntPtr UserData;
        [FieldOffset(104)] public IntPtr UserContext;
    }

    // EVENT_TRACE_LOGFILEW contains legacy structures that are output-only for
    // this consumer. Their documented x64 sizes are represented as opaque
    // blocks so the callback offsets remain exact without marshaling pointer-
    // bearing legacy fields we never inspect.
    [StructLayout(LayoutKind.Explicit, Size = 88)]
    private struct EVENT_TRACE_OPAQUE { }

    [StructLayout(LayoutKind.Explicit, Size = 280)]
    private struct TRACE_LOGFILE_HEADER_OPAQUE { }

    [StructLayout(LayoutKind.Explicit, Size = 448)]
    private struct EVENT_TRACE_LOGFILEW
    {
        [FieldOffset(0)] public IntPtr LogFileName;
        [FieldOffset(8)] public IntPtr LoggerName;
        [FieldOffset(16)] public long CurrentTime;
        [FieldOffset(24)] public uint BuffersRead;
        [FieldOffset(28)] public uint ProcessTraceMode;
        [FieldOffset(32)] public EVENT_TRACE_OPAQUE CurrentEvent;
        [FieldOffset(120)] public TRACE_LOGFILE_HEADER_OPAQUE LogfileHeader;
        [FieldOffset(400)] public IntPtr BufferCallback;
        [FieldOffset(408)] public uint BufferSize;
        [FieldOffset(412)] public uint Filled;
        [FieldOffset(416)] public uint EventsLost;
        [FieldOffset(424)] public IntPtr EventRecordCallback;
        [FieldOffset(432)] public uint IsKernelTrace;
        [FieldOffset(440)] public IntPtr Context;
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void EventRecordCallbackDelegate(IntPtr eventRecord);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    private static extern ulong OpenTraceW(ref EVENT_TRACE_LOGFILEW logfile);

    [DllImport("advapi32.dll", SetLastError = true, ExactSpelling = true)]
    private static extern uint ProcessTrace(
        [In] ulong[] handleArray,
        uint handleCount,
        IntPtr startTime,
        IntPtr endTime);

    [DllImport("advapi32.dll", SetLastError = true, ExactSpelling = true)]
    private static extern uint CloseTrace(ulong traceHandle);

    private static EventRecordCallbackDelegate _callback;
    private static StreamWriter _writer;
    private static readonly Dictionary<Guid, long> ProviderCounts = new Dictionary<Guid, long>();
    private static readonly Dictionary<string, long> DescriptorCounts = new Dictionary<string, long>();
    private static long _totalEvents;
    private static long _targetEvents;
    private static long _targetBytes;

    private static string Hex(byte[] bytes)
    {
        if (bytes == null || bytes.Length == 0) return String.Empty;
        char[] chars = new char[bytes.Length * 2];
        const string alphabet = "0123456789ABCDEF";
        for (int i = 0; i < bytes.Length; ++i)
        {
            chars[i * 2] = alphabet[(bytes[i] >> 4) & 0xF];
            chars[i * 2 + 1] = alphabet[bytes[i] & 0xF];
        }
        return new string(chars);
    }

    private static string FileTimeToUtc(long value)
    {
        try { return DateTime.FromFileTimeUtc(value).ToString("o", CultureInfo.InvariantCulture); }
        catch { return String.Empty; }
    }

    private static void OnEventRecord(IntPtr recordPtr)
    {
        EVENT_RECORD record = (EVENT_RECORD)Marshal.PtrToStructure(recordPtr, typeof(EVENT_RECORD));
        Guid provider = record.EventHeader.ProviderId;
        _totalEvents++;

        long providerCount;
        ProviderCounts.TryGetValue(provider, out providerCount);
        ProviderCounts[provider] = providerCount + 1;

        if (provider != ProviderRpmh && provider != ProviderAux) return;

        _targetEvents++;
        byte[] payload = new byte[record.UserDataLength];
        if (payload.Length != 0 && record.UserData != IntPtr.Zero)
            Marshal.Copy(record.UserData, payload, 0, payload.Length);
        _targetBytes += payload.Length;

        EVENT_DESCRIPTOR d = record.EventHeader.EventDescriptor;
        string descriptorKey = String.Format(CultureInfo.InvariantCulture,
            "{0}|id={1}|v={2}|ch={3}|lvl={4}|op={5}|task={6}|kw=0x{7:X16}|flags=0x{8:X4}",
            provider, d.Id, d.Version, d.Channel, d.Level, d.Opcode, d.Task,
            d.Keyword, record.EventHeader.Flags);
        long descriptorCount;
        DescriptorCounts.TryGetValue(descriptorKey, out descriptorCount);
        DescriptorCounts[descriptorKey] = descriptorCount + 1;

        _writer.Write(provider.ToString("D"));
        _writer.Write('\t'); _writer.Write(d.Id.ToString(CultureInfo.InvariantCulture));
        _writer.Write('\t'); _writer.Write(d.Version.ToString(CultureInfo.InvariantCulture));
        _writer.Write('\t'); _writer.Write(d.Channel.ToString(CultureInfo.InvariantCulture));
        _writer.Write('\t'); _writer.Write(d.Level.ToString(CultureInfo.InvariantCulture));
        _writer.Write('\t'); _writer.Write(d.Opcode.ToString(CultureInfo.InvariantCulture));
        _writer.Write('\t'); _writer.Write(d.Task.ToString(CultureInfo.InvariantCulture));
        _writer.Write('\t'); _writer.Write(String.Format(CultureInfo.InvariantCulture, "0x{0:X16}", d.Keyword));
        _writer.Write('\t'); _writer.Write(String.Format(CultureInfo.InvariantCulture, "0x{0:X4}", record.EventHeader.Flags));
        _writer.Write('\t'); _writer.Write(record.EventHeader.ProcessId.ToString(CultureInfo.InvariantCulture));
        _writer.Write('\t'); _writer.Write(record.EventHeader.ThreadId.ToString(CultureInfo.InvariantCulture));
        _writer.Write('\t'); _writer.Write(record.EventHeader.TimeStamp.ToString(CultureInfo.InvariantCulture));
        _writer.Write('\t'); _writer.Write(FileTimeToUtc(record.EventHeader.TimeStamp));
        _writer.Write('\t'); _writer.Write(record.BufferContext.ProcessorIndex.ToString(CultureInfo.InvariantCulture));
        _writer.Write('\t'); _writer.Write(record.BufferContext.LoggerId.ToString(CultureInfo.InvariantCulture));
        _writer.Write('\t'); _writer.Write(record.ExtendedDataCount.ToString(CultureInfo.InvariantCulture));
        _writer.Write('\t'); _writer.Write(record.UserDataLength.ToString(CultureInfo.InvariantCulture));
        _writer.Write('\t'); _writer.Write(Hex(payload));
        _writer.WriteLine();
    }

    public sealed class DumpResult
    {
        public long TotalEvents { get; set; }
        public long TargetEvents { get; set; }
        public long TargetUserDataBytes { get; set; }
        public uint ProcessTraceStatus { get; set; }
        public uint CloseTraceStatus { get; set; }
        public Dictionary<Guid, long> Providers { get; set; }
        public Dictionary<string, long> Descriptors { get; set; }
    }

    public static DumpResult Dump(string etlPath, string tsvPath)
    {
        if (IntPtr.Size != 8)
            throw new PlatformNotSupportedException("This decoder requires a 64-bit Windows process.");
        if (String.IsNullOrWhiteSpace(etlPath))
            throw new ArgumentException("ETL path is required.", "etlPath");

        ProviderCounts.Clear();
        DescriptorCounts.Clear();
        _totalEvents = 0;
        _targetEvents = 0;
        _targetBytes = 0;

        _callback = new EventRecordCallbackDelegate(OnEventRecord);
        IntPtr callbackPtr = Marshal.GetFunctionPointerForDelegate(_callback);
        IntPtr filePtr = Marshal.StringToHGlobalUni(etlPath);
        ulong handle = INVALID_PROCESSTRACE_HANDLE;
        uint closeStatus = 0;

        try
        {
            EVENT_TRACE_LOGFILEW log = new EVENT_TRACE_LOGFILEW();
            log.LogFileName = filePtr;
            log.LoggerName = IntPtr.Zero;
            log.ProcessTraceMode = PROCESS_TRACE_MODE_EVENT_RECORD;
            log.EventRecordCallback = callbackPtr;
            log.Context = IntPtr.Zero;

            handle = OpenTraceW(ref log);
            if (handle == INVALID_PROCESSTRACE_HANDLE)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenTraceW failed");

            using (_writer = new StreamWriter(tsvPath, false, new UTF8Encoding(false)))
            {
                _writer.WriteLine("ProviderGuid\tEventId\tVersion\tChannel\tLevel\tOpcode\tTask\tKeyword\tHeaderFlags\tProcessId\tThreadId\tTimestampFileTime\tTimestampUtc\tProcessorIndex\tLoggerId\tExtendedDataCount\tUserDataLength\tUserDataHex");
                uint processStatus = ProcessTrace(new ulong[] { handle }, 1, IntPtr.Zero, IntPtr.Zero);
                if (processStatus != 0)
                    throw new Win32Exception((int)processStatus, "ProcessTrace failed");

                return new DumpResult {
                    TotalEvents = _totalEvents,
                    TargetEvents = _targetEvents,
                    TargetUserDataBytes = _targetBytes,
                    ProcessTraceStatus = processStatus,
                    CloseTraceStatus = 0,
                    Providers = new Dictionary<Guid, long>(ProviderCounts),
                    Descriptors = new Dictionary<string, long>(DescriptorCounts)
                };
            }
        }
        finally
        {
            if (handle != INVALID_PROCESSTRACE_HANDLE)
                closeStatus = CloseTrace(handle);
            Marshal.FreeHGlobal(filePtr);
            _writer = null;
            _callback = null;
        }
    }
}
'@

if (-not ('A14QcpepRawEtlConsumer' -as [type])) {
    Add-Type -TypeDefinition $nativeSource -Language CSharp -ErrorAction Stop
}

if ($CompileOnly) {
    Write-Host 'Native offline ETL consumer compiled successfully.' -ForegroundColor Green
    exit 0
}

if ([string]::IsNullOrWhiteSpace($TracePath)) {
    throw 'TracePath is required unless -CompileOnly is used.'
}

New-Item -ItemType Directory -Force -Path $working | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $OutputRoot "A14-QCPEP-RPMH-Raw-$stamp"
New-Item -ItemType Directory -Force -Path $output | Out-Null

try {
    $etl = Resolve-TraceEtl -InputPath $TracePath
    $etlItem = Get-Item -LiteralPath $etl
    $rawTsv = Join-Path $output 'qcpep-wpp-raw-events.tsv'

    Write-Host ('=' * 76)
    Write-Host 'ASUS Zenbook A14 offline qcpep WPP raw ETL dumper'
    Write-Host ('=' * 76)
    Write-Host "Input ETL: $etl"
    Write-Host "Output:    $output"
    Write-Host 'OpenTraceW/ProcessTrace consumer only; no live ETW control or hardware operation.'
    Write-Host ''

    $result = [A14QcpepRawEtlConsumer]::Dump($etl, $rawTsv)

    $providerLines = @(
        $result.Providers.GetEnumerator() |
            Sort-Object { $_.Key.ToString('D') } |
            ForEach-Object { "provider_$($_.Key.ToString('D'))=$($_.Value)" }
    )
    $descriptorLines = @(
        $result.Descriptors.GetEnumerator() |
            Sort-Object Name |
            ForEach-Object { "descriptor=$($_.Key)|count=$($_.Value)" }
    )

    @(
        "generated_at=$((Get-Date).ToString('o'))"
        "source_trace=$etl"
        "source_trace_bytes=$($etlItem.Length)"
        "target_provider_rpmh=$($providerRpmh.ToString('D'))"
        "target_provider_aux=$($providerAux.ToString('D'))"
        "total_events=$($result.TotalEvents)"
        "target_events=$($result.TargetEvents)"
        "target_userdata_bytes=$($result.TargetUserDataBytes)"
        "process_trace_status=$($result.ProcessTraceStatus)"
        $providerLines
        $descriptorLines
        'operation=offline-etl-consume-only'
        'open_trace_source=etl-file-only'
        'live_etw_session_opened=false'
        'etw_control_query=false'
        'etw_control_flush=false'
        'etw_control_update=false'
        'etw_control_stop=false'
        'provider_enabled_or_disabled=false'
        'camera_ioctls_sent=false'
        'devices_restarted=false'
        'pnp_state_changed=false'
        'power_state_changed=false'
        'camera_register_writes=false'
        'direct_cpas_mmio=false'
        'ssc_contacted=false'
    ) | Out-File -LiteralPath (Join-Path $output 'RAW-DUMP-RESULT.txt') -Encoding utf8 -Width 16384

    # Useful frequency tables generated entirely from the offline TSV.
    $rows = @(Import-Csv -LiteralPath $rawTsv -Delimiter "`t")
    $rows |
        Group-Object ProviderGuid,EventId,Version,Opcode,Task,HeaderFlags,UserDataLength |
        Sort-Object Count -Descending |
        ForEach-Object {
            [pscustomobject]@{
                Count = $_.Count
                Signature = $_.Name
            }
        } | Export-Csv -LiteralPath (Join-Path $output 'raw-event-signatures.csv') -NoTypeInformation -Encoding utf8

    $rows |
        Group-Object UserDataLength |
        Sort-Object { [int]$_.Name } |
        ForEach-Object {
            [pscustomobject]@{
                UserDataLength = [int]$_.Name
                Count = $_.Count
            }
        } | Export-Csv -LiteralPath (Join-Path $output 'raw-payload-lengths.csv') -NoTypeInformation -Encoding utf8

    $zip = "$output.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -LiteralPath $output -DestinationPath $zip -CompressionLevel Optimal

    Write-Host "All ETL events:          $($result.TotalEvents)"
    Write-Host "Target qcpep WPP events: $($result.TargetEvents)"
    Write-Host "Raw UserData bytes:      $($result.TargetUserDataBytes)"
    Write-Host "Archive:                 $zip"
    Write-Host 'Upload the ZIP. No live ETW or hardware state was changed.'
}
finally {
    if (Test-Path -LiteralPath $working) {
        Remove-Item -LiteralPath $working -Recurse -Force -ErrorAction SilentlyContinue
    }
}
