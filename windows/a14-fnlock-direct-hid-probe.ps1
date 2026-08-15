param(
    [ValidateSet('diag','interactive')]
    [string]$Action = 'diag'
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class A14HidFnLock {
    const uint DIGCF_PRESENT = 0x00000002;
    const uint DIGCF_DEVICEINTERFACE = 0x00000010;
    const uint GENERIC_READ = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 0x00000001;
    const uint FILE_SHARE_WRITE = 0x00000002;
    const uint OPEN_EXISTING = 3;
    static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVICE_INTERFACE_DATA {
        public int cbSize;
        public Guid InterfaceClassGuid;
        public int Flags;
        public UIntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct HIDD_ATTRIBUTES {
        public int Size;
        public ushort VendorID;
        public ushort ProductID;
        public ushort VersionNumber;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct HIDP_CAPS {
        public ushort Usage;
        public ushort UsagePage;
        public ushort InputReportByteLength;
        public ushort OutputReportByteLength;
        public ushort FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)]
        public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes;
        public ushort NumberInputButtonCaps;
        public ushort NumberInputValueCaps;
        public ushort NumberInputDataIndices;
        public ushort NumberOutputButtonCaps;
        public ushort NumberOutputValueCaps;
        public ushort NumberOutputDataIndices;
        public ushort NumberFeatureButtonCaps;
        public ushort NumberFeatureValueCaps;
        public ushort NumberFeatureDataIndices;
    }

    public sealed class HidInfo {
        public string Path { get; set; }
        public ushort VendorId { get; set; }
        public ushort ProductId { get; set; }
        public ushort Version { get; set; }
        public ushort UsagePage { get; set; }
        public ushort Usage { get; set; }
        public ushort InputReportLength { get; set; }
        public ushort OutputReportLength { get; set; }
        public ushort FeatureReportLength { get; set; }
    }

    [DllImport("hid.dll")]
    static extern void HidD_GetHidGuid(out Guid HidGuid);

    [DllImport("hid.dll", SetLastError = true)]
    static extern bool HidD_GetAttributes(SafeFileHandle HidDeviceObject, ref HIDD_ATTRIBUTES Attributes);

    [DllImport("hid.dll", SetLastError = true)]
    static extern bool HidD_GetPreparsedData(SafeFileHandle HidDeviceObject, out IntPtr PreparsedData);

    [DllImport("hid.dll", SetLastError = true)]
    static extern bool HidD_FreePreparsedData(IntPtr PreparsedData);

    [DllImport("hid.dll", SetLastError = true)]
    static extern bool HidD_SetFeature(SafeFileHandle HidDeviceObject, byte[] ReportBuffer, int ReportBufferLength);

    [DllImport("hid.dll")]
    static extern int HidP_GetCaps(IntPtr PreparsedData, out HIDP_CAPS Capabilities);

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern IntPtr SetupDiGetClassDevs(ref Guid ClassGuid, IntPtr Enumerator, IntPtr hwndParent, uint Flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr DeviceInfoSet, IntPtr DeviceInfoData,
        ref Guid InterfaceClassGuid, uint MemberIndex, ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr DeviceInfoSet,
        ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData, IntPtr DeviceInterfaceDetailData,
        uint DeviceInterfaceDetailDataSize, out uint RequiredSize, IntPtr DeviceInfoData);

    [DllImport("setupapi.dll")]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFile(string lpFileName, uint dwDesiredAccess,
        uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    static SafeFileHandle Open(string path, bool write) {
        uint access = write ? (GENERIC_READ | GENERIC_WRITE) : 0;
        return CreateFile(path, access, FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
    }

    static string GetPath(IntPtr set, ref SP_DEVICE_INTERFACE_DATA ifData) {
        uint required;
        SetupDiGetDeviceInterfaceDetail(set, ref ifData, IntPtr.Zero, 0, out required, IntPtr.Zero);
        int err = Marshal.GetLastWin32Error();
        if (required == 0)
            throw new Win32Exception(err, "SetupDiGetDeviceInterfaceDetail size query failed");

        IntPtr detail = Marshal.AllocHGlobal((int)required);
        try {
            for (int i = 0; i < required; i++) Marshal.WriteByte(detail, i, 0);
            Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
            if (!SetupDiGetDeviceInterfaceDetail(set, ref ifData, detail, required, out required, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiGetDeviceInterfaceDetail failed");
            return Marshal.PtrToStringUni(IntPtr.Add(detail, 4));
        } finally {
            Marshal.FreeHGlobal(detail);
        }
    }

    public static HidInfo[] Enumerate() {
        Guid hidGuid;
        HidD_GetHidGuid(out hidGuid);
        IntPtr set = SetupDiGetClassDevs(ref hidGuid, IntPtr.Zero, IntPtr.Zero,
            DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (set == INVALID_HANDLE_VALUE)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiGetClassDevs failed");

        var result = new List<HidInfo>();
        try {
            for (uint i = 0; ; i++) {
                var ifData = new SP_DEVICE_INTERFACE_DATA();
                ifData.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref hidGuid, i, ref ifData)) {
                    int e = Marshal.GetLastWin32Error();
                    if (e == 259) break; // ERROR_NO_MORE_ITEMS
                    throw new Win32Exception(e, "SetupDiEnumDeviceInterfaces failed");
                }

                string path = GetPath(set, ref ifData);
                using (var h = Open(path, false)) {
                    if (h == null || h.IsInvalid) continue;
                    var attr = new HIDD_ATTRIBUTES();
                    attr.Size = Marshal.SizeOf(typeof(HIDD_ATTRIBUTES));
                    if (!HidD_GetAttributes(h, ref attr)) continue;
                    IntPtr prep;
                    if (!HidD_GetPreparsedData(h, out prep)) continue;
                    try {
                        HIDP_CAPS caps;
                        if (HidP_GetCaps(prep, out caps) < 0) continue;
                        result.Add(new HidInfo {
                            Path = path,
                            VendorId = attr.VendorID,
                            ProductId = attr.ProductID,
                            Version = attr.VersionNumber,
                            UsagePage = caps.UsagePage,
                            Usage = caps.Usage,
                            InputReportLength = caps.InputReportByteLength,
                            OutputReportLength = caps.OutputReportByteLength,
                            FeatureReportLength = caps.FeatureReportByteLength
                        });
                    } finally {
                        HidD_FreePreparsedData(prep);
                    }
                }
            }
        } finally {
            SetupDiDestroyDeviceInfoList(set);
        }
        return result.ToArray();
    }

    public static void SetFnSwitch(string path, int featureLength, bool state) {
        if (featureLength < 4 || featureLength > 4096)
            throw new ArgumentOutOfRangeException("featureLength");
        byte[] report = new byte[featureLength];
        report[0] = 0x5a;
        report[1] = 0xd0;
        report[2] = 0x4e;
        report[3] = state ? (byte)1 : (byte)0;
        using (var h = Open(path, true)) {
            if (h == null || h.IsInvalid)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateFile for HID write failed");
            if (!HidD_SetFeature(h, report, report.Length))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "HidD_SetFeature failed");
        }
    }
}
'@

function Read-Observation([string]$Prompt) {
    while ($true) {
        $v = (Read-Host $Prompt).Trim()
        if ($v.Length -gt 0) { return $v }
        Write-Host 'Please type works, no-change, reversed, or describe what happened; blank is ambiguous.' -ForegroundColor Yellow
    }
}

Write-Host '===== A14 ASUS-OPTIMIZATION FN-SWITCH HID MIRROR ====='
Write-Host "action=$Action"
Write-Host 'Windows AsusOptimization.exe 2.1.75.0 was reverse-engineered to select:'
Write-Host '  VendorID=0x0B05, UsagePage=0xFF31, Usage=0x0076'
Write-Host 'and to send a full HID FeatureReportByteLength buffer beginning:'
Write-Host '  5A D0 4E <state>'
Write-Host ''

$all = @([A14HidFnLock]::Enumerate())
$matches = @($all | Where-Object {
    $_.VendorId -eq 0x0B05 -and $_.UsagePage -eq 0xFF31 -and $_.Usage -eq 0x0076
})

Write-Host "HID_INTERFACE_COUNT=$($all.Count)"
Write-Host "ASUS_FN_SWITCH_MATCH_COUNT=$($matches.Count)"
$i = 0
foreach ($h in $matches) {
    Write-Host "MATCH[$i]_VID=0x$($h.VendorId.ToString('X4'))"
    Write-Host "MATCH[$i]_PID=0x$($h.ProductId.ToString('X4'))"
    Write-Host "MATCH[$i]_VERSION=0x$($h.Version.ToString('X4'))"
    Write-Host "MATCH[$i]_USAGE_PAGE=0x$($h.UsagePage.ToString('X4'))"
    Write-Host "MATCH[$i]_USAGE=0x$($h.Usage.ToString('X4'))"
    Write-Host "MATCH[$i]_INPUT_REPORT_LEN=$($h.InputReportLength)"
    Write-Host "MATCH[$i]_OUTPUT_REPORT_LEN=$($h.OutputReportLength)"
    Write-Host "MATCH[$i]_FEATURE_REPORT_LEN=$($h.FeatureReportLength)"
    Write-Host "MATCH[$i]_PATH=$($h.Path)"
    $i++
}

if ($Action -eq 'diag') {
    Write-Host 'A14_FNLOCK_DIRECT_HID=DIAG_COMPLETE'
    exit 0
}

if ($matches.Count -ne 1) {
    throw "Expected exactly one ASUS FF31:0076 HID collection; found $($matches.Count). Refusing to send anything."
}

$target = $matches[0]
$svc = Get-Service -Name ASUSOptimization -ErrorAction SilentlyContinue
$wasRunning = $null -ne $svc -and $svc.Status -eq 'Running'
$obs0 = $null
$obs1 = $null

try {
    if ($wasRunning) {
        Write-Host ''
        Write-Host 'Stopping ASUSOptimization so this test is the only Fn-switch writer...'
        Stop-Service -Name ASUSOptimization -Force
        (Get-Service -Name ASUSOptimization).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15))
    }
    Write-Host "ASUS_OPTIMIZATION_STATE=$(if ($null -eq $svc) {'NOT_FOUND'} else {(Get-Service -Name ASUSOptimization).Status})"

    Write-Host ''
    Write-Host '===== DIRECT WINDOWS HID STATE=0 ====='
    [A14HidFnLock]::SetFnSwitch($target.Path, $target.FeatureReportLength, $false)
    Write-Host "HID_SET_FEATURE=SUCCESS len=$($target.FeatureReportLength) bytes=5A D0 4E 00 ..."
    Write-Host 'Test the SAME F-row key in plain and Fn+key forms. There is NO time limit.'
    $obs0 = Read-Observation 'Describe behavior after direct state=0'

    Write-Host ''
    Write-Host '===== DIRECT WINDOWS HID STATE=1 ====='
    [A14HidFnLock]::SetFnSwitch($target.Path, $target.FeatureReportLength, $true)
    Write-Host "HID_SET_FEATURE=SUCCESS len=$($target.FeatureReportLength) bytes=5A D0 4E 01 ..."
    Write-Host 'Test the SAME F-row key in plain and Fn+key forms. There is NO time limit.'
    $obs1 = Read-Observation 'Describe behavior after direct state=1'
}
finally {
    if ($wasRunning) {
        Write-Host ''
        Write-Host 'Restoring ASUSOptimization...'
        Start-Service -Name ASUSOptimization
        (Get-Service -Name ASUSOptimization).WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
        Write-Host 'ASUS_OPTIMIZATION_RESTORE=RUNNING'
    }
}

Write-Host ''
Write-Host '===== RESULT ====='
Write-Host "STATE_0_OBSERVATION=$obs0"
Write-Host "STATE_1_OBSERVATION=$obs1"
Write-Host 'A14_FNLOCK_DIRECT_HID=COMPLETE'
