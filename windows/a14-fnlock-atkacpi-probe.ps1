param(
    [ValidateSet('diag','status','on','off','interactive','fnesc')]
    [string]$Action = 'status'
)

$ErrorActionPreference = 'Stop'

# ASUS firmware Fn-lock endpoint used by current G-Helper.
$FnLockDeviceId = [uint32]0x00100023
$IoctlAsusAcpi  = [uint32]0x0022240C
$MethodDsts     = [uint32]0x53545344 # 'DSTS'
$MethodDevs     = [uint32]0x53564544 # 'DEVS'

$source = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class A14AtkAcpiNative
{
    public const uint GENERIC_READ  = 0x80000000;
    public const uint GENERIC_WRITE = 0x40000000;
    public const uint FILE_SHARE_READ  = 0x00000001;
    public const uint FILE_SHARE_WRITE = 0x00000002;
    public const uint OPEN_EXISTING = 3;
    public const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
    public static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateFile(
        string lpFileName,
        uint dwDesiredAccess,
        uint dwShareMode,
        IntPtr lpSecurityAttributes,
        uint dwCreationDisposition,
        uint dwFlagsAndAttributes,
        IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DeviceIoControl(
        IntPtr hDevice,
        uint dwIoControlCode,
        byte[] lpInBuffer,
        uint nInBufferSize,
        byte[] lpOutBuffer,
        uint nOutBufferSize,
        out uint lpBytesReturned,
        IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CloseHandle(IntPtr hObject);

    public static IntPtr OpenAtkAcpi()
    {
        IntPtr handle = CreateFile(
            @"\\.\ATKACPI",
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            IntPtr.Zero);

        if (handle == INVALID_HANDLE_VALUE)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to open \\.\\ATKACPI");

        return handle;
    }
}
'@

if (-not ('A14AtkAcpiNative' -as [type])) {
    Add-Type -TypeDefinition $source -Language CSharp
}

function Format-Hex {
    param([byte[]]$Bytes)
    return (($Bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
}

function Format-Win32Error {
    param([int]$Code)
    $e = [ComponentModel.Win32Exception]::new($Code)
    return ('{0} (0x{0:X8}): {1}' -f $Code, $e.Message)
}

function Invoke-AtkMethodRaw {
    param(
        [IntPtr]$Handle,
        [uint32]$Method,
        [byte[]]$Parameters
    )

    # IMPORTANT: this is the exact ATKACPI ABI used by G-Helper:
    #   [4-byte method][raw parameters]
    # There is NO parameter-length dword between them.
    # DSTS input = 8 bytes:  method + device_id
    # DEVS input = 12 bytes: method + device_id + control_status
    $input = New-Object byte[] (4 + $Parameters.Length)
    [BitConverter]::GetBytes($Method).CopyTo($input, 0)
    if ($Parameters.Length -gt 0) {
        $Parameters.CopyTo($input, 4)
    }

    $output = New-Object byte[] 16
    [uint32]$returned = 0
    $ok = [A14AtkAcpiNative]::DeviceIoControl(
        $Handle,
        $IoctlAsusAcpi,
        $input,
        [uint32]$input.Length,
        $output,
        [uint32]$output.Length,
        [ref]$returned,
        [IntPtr]::Zero)

    $result = if ($output.Length -ge 4) { [BitConverter]::ToInt32($output, 0) } else { 0 }
    if (-not $ok) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        return [pscustomobject]@{
            Success       = $false
            ErrorCode     = $code
            ErrorText     = (Format-Win32Error $code)
            Method        = ('0x{0:X8}' -f $Method)
            InputHex      = (Format-Hex $input)
            BytesReturned = $returned
            Output        = $output
            OutputHex     = (Format-Hex $output)
            ResultInt32   = $result
        }
    }

    return [pscustomobject]@{
        Success       = $true
        ErrorCode     = 0
        ErrorText     = ''
        Method        = ('0x{0:X8}' -f $Method)
        InputHex      = (Format-Hex $input)
        BytesReturned = $returned
        Output        = $output
        OutputHex     = (Format-Hex $output)
        ResultInt32   = $result
    }
}

function Get-AsusWmiInstance {
    try {
        return @(Get-CimInstance -Namespace root/wmi -ClassName AsusAtkWmi_WMNB -ErrorAction Stop)[0]
    }
    catch {
        return $null
    }
}

function Invoke-WmiDsts {
    param([object]$Instance)
    $r = Invoke-CimMethod -InputObject $Instance -MethodName DSTS -Arguments @{
        Device_ID = [uint32]$FnLockDeviceId
    } -ErrorAction Stop

    [pscustomobject]@{
        Success   = $true
        Transport = 'WMI'
        Raw       = [uint32]$r.device_status
        RawObject = $r
    }
}

function Invoke-WmiDevs {
    param([object]$Instance, [ValidateSet(0,1)][int]$State)
    $r = Invoke-CimMethod -InputObject $Instance -MethodName DEVS -Arguments @{
        Device_ID      = [uint32]$FnLockDeviceId
        Control_status = [uint32]$State
    } -ErrorAction Stop

    [pscustomobject]@{
        Success        = ([int]$r.result -eq 1)
        Transport      = 'WMI'
        Requested      = $State
        FirmwareResult = [int]$r.result
        RawObject      = $r
    }
}

function Convert-DstsResult {
    param([uint32]$Raw, [string]$Transport)

    # Match G-Helper DeviceGet(): positive DSTS values are returned minus
    # 0x10000. Do NOT interpret the resulting value as a boolean Fn-lock state.
    # G-Helper uses DeviceGet(FnLock) >= 0 only to decide that hardware Fn-lock
    # is supported. On this A14 the observed value is 2 both before and after
    # DEVS writes, so it is capability/status data, not an ON/OFF readback.
    $decoded = if ($Raw -gt 0) { [int64]$Raw - 65536 } else { [int64]$Raw }
    [pscustomobject]@{
        DeviceId       = ('0x{0:X8}' -f $FnLockDeviceId)
        Transport      = $Transport
        RawUInt32      = $Raw
        RawHex         = ('0x{0:X8}' -f $Raw)
        PresenceBit16  = (($Raw -band 0x00010000) -ne 0)
        DecodedValue   = $decoded
        BooleanState   = 'NOT_EXPOSED_BY_DSTS'
    }
}

$atkHandle = [IntPtr]::Zero
$atkOpenError = $null
try {
    $atkHandle = [A14AtkAcpiNative]::OpenAtkAcpi()
}
catch {
    $atkOpenError = $_.Exception.Message
}
$wmi = Get-AsusWmiInstance

function New-DstsParameters {
    $parameters = New-Object byte[] 4
    [BitConverter]::GetBytes($FnLockDeviceId).CopyTo($parameters, 0)
    return $parameters
}

function New-DevsParameters {
    param([ValidateSet(0,1)][int]$State)
    $parameters = New-Object byte[] 8
    [BitConverter]::GetBytes($FnLockDeviceId).CopyTo($parameters, 0)
    [BitConverter]::GetBytes([uint32]$State).CopyTo($parameters, 4)
    return $parameters
}

function Get-FnLockFirmware {
    if ($atkHandle -ne [IntPtr]::Zero) {
        $r = Invoke-AtkMethodRaw -Handle $atkHandle -Method $MethodDsts -Parameters (New-DstsParameters)
        if ($r.Success) {
            return Convert-DstsResult -Raw ([uint32]$r.ResultInt32) -Transport 'ATKACPI-IOCTL'
        }
        $script:lastAtkError = $r
    }

    if ($null -ne $wmi) {
        $r = Invoke-WmiDsts -Instance $wmi
        return Convert-DstsResult -Raw $r.Raw -Transport 'AsusAtkWmi_WMNB'
    }

    throw 'Neither ATKACPI IOCTL nor AsusAtkWmi_WMNB DSTS is usable.'
}

function Set-FnLockFirmware {
    param([ValidateSet(0,1)][int]$State)

    if ($atkHandle -ne [IntPtr]::Zero) {
        $r = Invoke-AtkMethodRaw -Handle $atkHandle -Method $MethodDevs -Parameters (New-DevsParameters -State $State)
        if ($r.Success) {
            return [pscustomobject]@{
                DeviceId       = ('0x{0:X8}' -f $FnLockDeviceId)
                Transport      = 'ATKACPI-IOCTL'
                Requested      = $State
                FirmwareResult = $r.ResultInt32
                Success        = ($r.ResultInt32 -eq 1)
                BytesReturned  = $r.BytesReturned
                OutputHex      = $r.OutputHex
            }
        }
        $script:lastAtkError = $r
    }

    if ($null -ne $wmi) {
        $r = Invoke-WmiDevs -Instance $wmi -State $State
        return [pscustomobject]@{
            DeviceId       = ('0x{0:X8}' -f $FnLockDeviceId)
            Transport      = 'AsusAtkWmi_WMNB'
            Requested      = $State
            FirmwareResult = $r.FirmwareResult
            Success        = $r.Success
        }
    }

    throw 'Neither ATKACPI IOCTL nor AsusAtkWmi_WMNB DEVS is usable.'
}

function Show-Diagnostics {
    Write-Host "`n===== TRANSPORT DIAGNOSTICS ====="
    Write-Host ('ATKACPI_OPEN=' + $(if ($atkHandle -ne [IntPtr]::Zero) { 'YES' } else { 'NO' }))
    if ($atkOpenError) { Write-Host ('ATKACPI_OPEN_ERROR=' + $atkOpenError) }
    Write-Host ('ASUS_WMI_CLASS=' + $(if ($null -ne $wmi) { 'YES' } else { 'NO' }))

    if ($atkHandle -ne [IntPtr]::Zero) {
        $r = Invoke-AtkMethodRaw -Handle $atkHandle -Method $MethodDsts -Parameters (New-DstsParameters)
        Write-Host ('ATKACPI_DSTS_SUCCESS=' + $r.Success)
        Write-Host ('ATKACPI_DSTS_INPUT=' + $r.InputHex)
        if (-not $r.Success) {
            Write-Host ('ATKACPI_DSTS_ERROR=' + $r.ErrorText)
            Write-Host ('ATKACPI_DSTS_BYTES_RETURNED=' + $r.BytesReturned)
            Write-Host ('ATKACPI_DSTS_OUTPUT=' + $r.OutputHex)
        } else {
            Write-Host ('ATKACPI_DSTS_BYTES_RETURNED=' + $r.BytesReturned)
            Write-Host ('ATKACPI_DSTS_OUTPUT=' + $r.OutputHex)
            Write-Host ('ATKACPI_DSTS_RESULT=0x{0:X8}' -f ([uint32]$r.ResultInt32))
        }
    }

    if ($null -ne $wmi) {
        try {
            $r = Invoke-WmiDsts -Instance $wmi
            Write-Host 'WMI_DSTS_SUCCESS=True'
            Write-Host ('WMI_DSTS_RAW=0x{0:X8}' -f $r.Raw)
        }
        catch {
            Write-Host 'WMI_DSTS_SUCCESS=False'
            Write-Host ('WMI_DSTS_ERROR=' + $_.Exception.Message)
        }
    }
}

function Show-Status {
    param([string]$Label)
    Write-Host "`n===== $Label ====="
    (Get-FnLockFirmware) | Format-List
}

Write-Host '===== ASUS ZENBOOK A14 FIRMWARE FN-LOCK PROBE ====='
Write-Host ('action=' + $Action)
Write-Host ('device_id=0x{0:X8}' -f $FnLockDeviceId)
Write-Host 'transport=auto: ATKACPI IOCTL -> AsusAtkWmi_WMNB fallback'
Write-Host 'This tool does not touch any other ASUS firmware endpoint.'

try {
    Show-Diagnostics

    if ($Action -eq 'diag') {
        Write-Host "`nA14_FNLOCK_ATKACPI_PROBE=DIAG_COMPLETE"
        return
    }

    Show-Status -Label 'BEFORE'

    switch ($Action) {
        'status' { }
        'on' {
            Write-Host "`n===== SEND DEVS VALUE 1 ====="
            Set-FnLockFirmware -State 1 | Format-List
            Start-Sleep -Milliseconds 250
            Show-Status -Label 'DSTS AFTER DEVS=1'
        }
        'off' {
            Write-Host "`n===== SEND DEVS VALUE 0 ====="
            Set-FnLockFirmware -State 0 | Format-List
            Start-Sleep -Milliseconds 250
            Show-Status -Label 'DSTS AFTER DEVS=0'
        }
        'interactive' {
            Write-Host "`n===== TEST DEVS=0 ====="
            Set-FnLockFirmware -State 0 | Format-List
            Start-Sleep -Milliseconds 250
            Show-Status -Label 'DSTS AFTER DEVS=0'
            Write-Host 'Test F1-F12 and Fn+F1-F12 now. There is NO time limit.'
            $result0 = Read-Host 'Describe what changed with DEVS=0 (or type no-change)'

            Write-Host "`n===== TEST DEVS=1 ====="
            Set-FnLockFirmware -State 1 | Format-List
            Start-Sleep -Milliseconds 250
            Show-Status -Label 'DSTS AFTER DEVS=1'
            Write-Host 'Test F1-F12 and Fn+F1-F12 now. There is NO time limit.'
            $result1 = Read-Host 'Describe what changed with DEVS=1 (or type no-change)'

            Write-Host "`n===== OBSERVATION ====="
            Write-Host ('DEVS_0_OBSERVATION=' + $result0)
            Write-Host ('DEVS_1_OBSERVATION=' + $result1)
            Write-Warning 'DSTS does not expose the boolean Fn-lock state on this A14, so this probe does not guess an automatic restore value.'
        }
        'fnesc' {
            $before = Get-FnLockFirmware
            Write-Host "`nPress Fn+Esc ONCE in Windows, test one F-row key, then press Enter here."
            Write-Host 'Do not toggle anything in MyASUS/Armoury Crate/G-Helper during this step.'
            $behavior = Read-Host 'After Fn+Esc, describe the F-row change (or type no-change)'
            $after = Get-FnLockFirmware
            Write-Host "`n===== PHYSICAL Fn+Esc OBSERVATION ====="
            Write-Host ('BEHAVIOR=' + $behavior)
            Write-Host ('DSTS_BEFORE=0x{0:X8}' -f [uint32]$before.RawUInt32)
            Write-Host ('DSTS_AFTER=0x{0:X8}' -f [uint32]$after.RawUInt32)
            $after | Format-List
        }
    }
}
finally {
    if ($atkHandle -ne [IntPtr]::Zero) {
        [void][A14AtkAcpiNative]::CloseHandle($atkHandle)
    }
}
