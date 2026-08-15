param(
    [ValidateSet('status','on','off','interactive','fnesc')]
    [string]$Action = 'status'
)

$ErrorActionPreference = 'Stop'

# ASUS firmware Fn-lock endpoint used by ASUS System Control Interface / G-Helper.
# This deliberately touches ONLY device ID 0x00100023.
$FnLockDeviceId = [uint32]0x00100023
$IoctlAsusAcpi  = [uint32]0x0022240C
$MethodDsts     = [uint32]0x53545344 # 'DSTS'
$MethodDevs     = [uint32]0x53564544 # 'DEVS'

$source = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class A14AtkAcpiNative
{
    public const uint GENERIC_READ  = 0x80000000;
    public const uint GENERIC_WRITE = 0x40000000;
    public const uint FILE_SHARE_READ  = 0x00000001;
    public const uint FILE_SHARE_WRITE = 0x00000002;
    public const uint OPEN_EXISTING = 3;
    public const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern SafeFileHandle CreateFile(
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
        SafeFileHandle hDevice,
        uint dwIoControlCode,
        byte[] lpInBuffer,
        uint nInBufferSize,
        byte[] lpOutBuffer,
        uint nOutBufferSize,
        out uint lpBytesReturned,
        IntPtr lpOverlapped);

    public static SafeFileHandle OpenAtkAcpi()
    {
        SafeFileHandle handle = CreateFile(
            @"\\.\ATKACPI",
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            IntPtr.Zero);

        if (handle.IsInvalid)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to open \\.\\ATKACPI");

        return handle;
    }
}
'@

if (-not ('A14AtkAcpiNative' -as [type])) {
    Add-Type -TypeDefinition $source -Language CSharp
}

function Invoke-AtkMethod {
    param(
        [Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle,
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
        throw [ComponentModel.Win32Exception]::new($code, 'ATKACPI DeviceIoControl failed')
    }

    [pscustomobject]@{
        Method        = ('0x{0:X8}' -f $Method)
        BytesReturned = $returned
        Output         = $output
        ResultInt32    = [BitConverter]::ToInt32($output, 0)
        OutputHex      = (($output | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
    }
}

function Get-FnLockFirmware {
    param([Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle)

    $args = New-Object byte[] 8
    [BitConverter]::GetBytes($FnLockDeviceId).CopyTo($args, 0)
    $r = Invoke-AtkMethod -Handle $Handle -Method $MethodDsts -Args $args

    # G-Helper / ASUS SCI convention: DSTS returns status with bit 16 set.
    $decoded = $r.ResultInt32 - 65536
    [pscustomobject]@{
        DeviceId     = ('0x{0:X8}' -f $FnLockDeviceId)
        Raw          = $r.ResultInt32
        Decoded      = $decoded
        BytesReturned= $r.BytesReturned
        OutputHex    = $r.OutputHex
    }
}

function Set-FnLockFirmware {
    param(
        [Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle,
        [ValidateSet(0,1)][int]$State
    )

    $args = New-Object byte[] 8
    [BitConverter]::GetBytes($FnLockDeviceId).CopyTo($args, 0)
    [BitConverter]::GetBytes([uint32]$State).CopyTo($args, 4)
    $r = Invoke-AtkMethod -Handle $Handle -Method $MethodDevs -Args $args

    [pscustomobject]@{
        DeviceId      = ('0x{0:X8}' -f $FnLockDeviceId)
        Requested     = $State
        FirmwareResult= $r.ResultInt32
        Success       = ($r.ResultInt32 -eq 1)
        BytesReturned = $r.BytesReturned
        OutputHex     = $r.OutputHex
    }
}

function Show-Status {
    param([Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle, [string]$Label)
    Write-Host "`n===== $Label ====="
    $s = Get-FnLockFirmware -Handle $Handle
    $s | Format-List
}

Write-Host '===== ASUS ZENBOOK A14 FIRMWARE FN-LOCK PROBE ====='
Write-Host ('action=' + $Action)
Write-Host ('device_id=0x{0:X8}' -f $FnLockDeviceId)
Write-Host 'transport=\\.\ATKACPI / ASUS System Control Interface'
Write-Host 'This tool does not touch any other ASUS firmware endpoint.'

$handle = [A14AtkAcpiNative]::OpenAtkAcpi()
try {
    Show-Status -Handle $handle -Label 'BEFORE'
    $before = Get-FnLockFirmware -Handle $handle

    switch ($Action) {
        'status' {
            # Read-only.
        }
        'on' {
            Write-Host "`n===== SET FIRMWARE FN-LOCK ON ====="
            Set-FnLockFirmware -Handle $handle -State 1 | Format-List
            Start-Sleep -Milliseconds 250
            Show-Status -Handle $handle -Label 'AFTER ON'
        }
        'off' {
            Write-Host "`n===== SET FIRMWARE FN-LOCK OFF ====="
            Set-FnLockFirmware -Handle $handle -State 0 | Format-List
            Start-Sleep -Milliseconds 250
            Show-Status -Handle $handle -Label 'AFTER OFF'
        }
        'interactive' {
            Write-Host "`n===== TEST OFF ====="
            Set-FnLockFirmware -Handle $handle -State 0 | Format-List
            Start-Sleep -Milliseconds 250
            Show-Status -Handle $handle -Label 'READBACK OFF'
            Write-Host 'Test F1-F12 and Fn+F1-F12 now. There is NO time limit.'
            [void](Read-Host 'Press Enter when finished testing OFF')

            Write-Host "`n===== TEST ON ====="
            Set-FnLockFirmware -Handle $handle -State 1 | Format-List
            Start-Sleep -Milliseconds 250
            Show-Status -Handle $handle -Label 'READBACK ON'
            Write-Host 'Test F1-F12 and Fn+F1-F12 now. There is NO time limit.'
            [void](Read-Host 'Press Enter when finished testing ON')

            if ($before.Decoded -eq 0 -or $before.Decoded -eq 1) {
                Write-Host ("`nRestoring original firmware state: {0}" -f $before.Decoded)
                Set-FnLockFirmware -Handle $handle -State $before.Decoded | Format-List
                Start-Sleep -Milliseconds 250
                Show-Status -Handle $handle -Label 'RESTORED'
            } else {
                Write-Warning ('Original DSTS value was not 0/1 (' + $before.Decoded + '); not guessing a restore value.')
            }
        }
        'fnesc' {
            Write-Host "`nPress Fn+Esc ONCE in Windows, then press Enter here."
            Write-Host 'Do not toggle anything in MyASUS/Armoury Crate/G-Helper during this step.'
            [void](Read-Host 'Press Enter after Fn+Esc')
            Show-Status -Handle $handle -Label 'AFTER PHYSICAL Fn+Esc'
        }
    }
}
finally {
    $handle.Dispose()
}

Write-Host "`nA14_FNLOCK_ATKACPI_PROBE=COMPLETE"
