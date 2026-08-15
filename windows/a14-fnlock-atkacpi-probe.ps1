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

function Format-Win32Error {
    param([int]$Code)
    $e = [ComponentModel.Win32Exception]::new($Code)
    return ('{0} (0x{0:X8}): {1}' -f $Code, $e.Message)
}

function Invoke-AtkMethodRaw {
    param(
        [IntPtr]$Handle,
        [uint32]$Method,
        [byte[]]$Args
    )

    $input = New-Object byte[] (8 + $Args.Length)
    [BitConverter]::GetBytes($Method).CopyTo($input, 0)
    [BitConverter]::GetBytes([uint32]$Args.Length).CopyTo($input, 4)
    $Args.CopyTo($input, 8)

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

    if (-not $ok) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        return [pscustomobject]@{
            Success       = $false
            ErrorCode     = $code
            ErrorText     = (Format-Win32Error $code)
            Method        = ('0x{0:X8}' -f $Method)
            InputHex      = (($input | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
            BytesReturned = $returned
            Output        = $output
            OutputHex     = (($output | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
        }
    }

    return [pscustomobject]@{
        Success       = $true
        ErrorCode     = 0
        ErrorText     = ''
        Method        = ('0x{0:X8}' -f $Method)
        InputHex      = (($input | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
        BytesReturned = $returned
        Output        = $output
        OutputHex     = (($output | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
        ResultInt32   = [BitConverter]::ToInt32($output, 0)
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
        Success       = $true
        Transport     = 'WMI'
        Raw            = [uint32]$r.device_status
        RawObject      = $r
    }
}

function Invoke-WmiDevs {
    param([object]$Instance, [ValidateSet(0,1)][int]$State)
    $r = Invoke-CimMethod -InputObject $Instance -MethodName DEVS -Arguments @{
        Device_ID      = [uint32]$FnLockDeviceId
        Control_status = [uint32]$State
    } -ErrorAction Stop

    [pscustomobject]@{
        Success       = ([int]$r.result -eq 1)
        Transport     = 'WMI'
        Requested     = $State
        FirmwareResult= [int]$r.result
        RawObject      = $r
    }
}

function Convert-DstsResult {
    param([uint32]$Raw, [string]$Transport)

    # ASUS DSTS sets bit 16 when the endpoint is present. G-Helper decodes
    # this endpoint by subtracting 65536 from the returned dword.
    $decoded = [int64]$Raw - 65536
    [pscustomobject]@{
        DeviceId       = ('0x{0:X8}' -f $FnLockDeviceId)
        Transport      = $Transport
        RawUInt32      = $Raw
        RawHex         = ('0x{0:X8}' -f $Raw)
        PresenceBit16  = (($Raw -band 0x00010000) -ne 0)
        Decoded        = $decoded
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

function Get-FnLockFirmware {
    if ($atkHandle -ne [IntPtr]::Zero) {
        $args = New-Object byte[] 8
        [BitConverter]::GetBytes($FnLockDeviceId).CopyTo($args, 0)
        $r = Invoke-AtkMethodRaw -Handle $atkHandle -Method $MethodDsts -Args $args
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
        $args = New-Object byte[] 8
        [BitConverter]::GetBytes($FnLockDeviceId).CopyTo($args, 0)
        [BitConverter]::GetBytes([uint32]$State).CopyTo($args, 4)
        $r = Invoke-AtkMethodRaw -Handle $atkHandle -Method $MethodDevs -Args $args
        if ($r.Success) {
            return [pscustomobject]@{
                DeviceId      = ('0x{0:X8}' -f $FnLockDeviceId)
                Transport     = 'ATKACPI-IOCTL'
                Requested     = $State
                FirmwareResult= $r.ResultInt32
                Success       = ($r.ResultInt32 -eq 1)
                BytesReturned = $r.BytesReturned
                OutputHex     = $r.OutputHex
            }
        }
        $script:lastAtkError = $r
    }

    if ($null -ne $wmi) {
        $r = Invoke-WmiDevs -Instance $wmi -State $State
        return [pscustomobject]@{
            DeviceId      = ('0x{0:X8}' -f $FnLockDeviceId)
            Transport     = 'AsusAtkWmi_WMNB'
            Requested     = $State
            FirmwareResult= $r.FirmwareResult
            Success       = $r.Success
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
        $args = New-Object byte[] 8
        [BitConverter]::GetBytes($FnLockDeviceId).CopyTo($args, 0)
        $r = Invoke-AtkMethodRaw -Handle $atkHandle -Method $MethodDsts -Args $args
        Write-Host ('ATKACPI_DSTS_SUCCESS=' + $r.Success)
        if (-not $r.Success) {
            Write-Host ('ATKACPI_DSTS_ERROR=' + $r.ErrorText)
            Write-Host ('ATKACPI_DSTS_INPUT=' + $r.InputHex)
        } else {
            Write-Host ('ATKACPI_DSTS_OUTPUT=' + $r.OutputHex)
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
    $before = Get-FnLockFirmware

    switch ($Action) {
        'status' { }
        'on' {
            Write-Host "`n===== SET FIRMWARE FN-LOCK ON ====="
            Set-FnLockFirmware -State 1 | Format-List
            Start-Sleep -Milliseconds 250
            Show-Status -Label 'AFTER ON'
        }
        'off' {
            Write-Host "`n===== SET FIRMWARE FN-LOCK OFF ====="
            Set-FnLockFirmware -State 0 | Format-List
            Start-Sleep -Milliseconds 250
            Show-Status -Label 'AFTER OFF'
        }
        'interactive' {
            Write-Host "`n===== TEST OFF ====="
            Set-FnLockFirmware -State 0 | Format-List
            Start-Sleep -Milliseconds 250
            Show-Status -Label 'READBACK OFF'
            Write-Host 'Test F1-F12 and Fn+F1-F12 now. There is NO time limit.'
            [void](Read-Host 'Press Enter when finished testing OFF')

            Write-Host "`n===== TEST ON ====="
            Set-FnLockFirmware -State 1 | Format-List
            Start-Sleep -Milliseconds 250
            Show-Status -Label 'READBACK ON'
            Write-Host 'Test F1-F12 and Fn+F1-F12 now. There is NO time limit.'
            [void](Read-Host 'Press Enter when finished testing ON')

            if ($before.Decoded -eq 0 -or $before.Decoded -eq 1) {
                Write-Host ("`nRestoring original firmware state: {0}" -f $before.Decoded)
                Set-FnLockFirmware -State ([int]$before.Decoded) | Format-List
                Start-Sleep -Milliseconds 250
                Show-Status -Label 'RESTORED'
            } else {
                Write-Warning ('Original DSTS value was not 0/1 (' + $before.Decoded + '); not guessing a restore value.')
            }
        }
        'fnesc' {
            Write-Host "`nPress Fn+Esc ONCE in Windows, then press Enter here."
            Write-Host 'Do not toggle anything in MyASUS/Armoury Crate/G-Helper during this step.'
            [void](Read-Host 'Press Enter after Fn+Esc')
            Show-Status -Label 'AFTER PHYSICAL Fn+Esc'
        }
    }
}
finally {
    if ($atkHandle -ne [IntPtr]::Zero) {
        [void][A14AtkAcpiNative]::CloseHandle($atkHandle)
    }
}

Write-Host "`nA14_FNLOCK_ATKACPI_PROBE=COMPLETE"
