#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputRoot = "$env:USERPROFILE\Desktop"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AosWppGuid = '{DDF06AD3-2B53-4825-B2C6-B9CAE6E680C1}'
$AosMessageGuid = '{66E62EB6-C99F-34ED-A782-B77E267F4B2D}'
$KernelPowerProvider = 'Microsoft-Windows-Kernel-Power'
$session = "A14-AOS-WPP-$PID"
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $OutputRoot "A14-AOS-WPP-Trace-$stamp"
$etl = Join-Path $output 'aos-wpp-kernel-power.etl'
$started = $false
$created = $false

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Save-CommandOutput {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )

    $path = Join-Path $output $Name
    try {
        & $Command 2>&1 | Out-File -LiteralPath $path -Encoding utf8 -Width 8192
    }
    catch {
        @(
            'status=failed'
            "exception=$($_.Exception.GetType().FullName)"
            "message=$($_.Exception.Message)"
        ) | Out-File -LiteralPath $path -Encoding utf8 -Width 8192
    }
}

function Invoke-LogmanChecked {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $logPath = Join-Path $output ("logman-{0}.txt" -f $Label)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add("command=logman.exe $($Arguments -join ' ')")
    $lines.Add("started_at=$((Get-Date).ToString('o'))")

    $result = & logman.exe @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in @($result)) { $lines.Add([string]$line) }
    $lines.Add("exit_code=$exitCode")
    $lines.Add("completed_at=$((Get-Date).ToString('o'))")
    $lines | Out-File -LiteralPath $logPath -Encoding utf8 -Width 8192

    if ($exitCode -ne 0) {
        throw "logman $Label failed with exit code $exitCode. See $logPath"
    }
}

function Initialize-MonitorPowerApi {
    if ('A14MonitorPower' -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class A14MonitorPower
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint Msg,
        IntPtr wParam,
        IntPtr lParam,
        uint fuFlags,
        uint uTimeout,
        out IntPtr lpdwResult);
}
'@
}

function Request-MonitorPowerOff {
    # This is the normal Win32 monitor-power broadcast. It asks Windows to power
    # the display off; it does not suspend/hibernate the machine or touch camera
    # devices. A keyboard/mouse/touchpad action wakes the display normally.
    Initialize-MonitorPowerApi

    $HWND_BROADCAST = [IntPtr]0xffff
    $WM_SYSCOMMAND = [uint32]0x0112
    $SC_MONITORPOWER = [IntPtr]0xF170
    $MONITOR_OFF = [IntPtr]2
    $SMTO_ABORTIFHUNG = [uint32]0x0002
    $nativeResult = [IntPtr]::Zero

    $requestedAt = Get-Date
    "display_off_requested=$($requestedAt.ToString('o'))" |
        Add-Content -LiteralPath (Join-Path $output 'ACTION-MARKERS.txt') -Encoding utf8

    $returnValue = [A14MonitorPower]::SendMessageTimeout(
        $HWND_BROADCAST,
        $WM_SYSCOMMAND,
        $SC_MONITORPOWER,
        $MONITOR_OFF,
        $SMTO_ABORTIFHUNG,
        2000,
        [ref]$nativeResult
    )
    $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    $returnedAt = Get-Date

    @(
        "display_off_returned=$($returnedAt.ToString('o'))"
        "display_off_native_return=$returnValue"
        "display_off_native_result=$nativeResult"
        "display_off_win32_error=$lastError"
    ) | Add-Content -LiteralPath (Join-Path $output 'ACTION-MARKERS.txt') -Encoding utf8

    if ($returnValue -eq [IntPtr]::Zero) {
        Write-Warning "Windows monitor-power broadcast returned zero (Win32 error $lastError). If the display did not turn off, stop and report this output."
    }
}

if (-not (Test-Administrator)) {
    throw 'Run this collector from an Administrator PowerShell window. It only controls ETW sessions and the normal Windows monitor-power state; it does not send camera/device IOCTLs.'
}

New-Item -ItemType Directory -Force -Path $output | Out-Null

@(
    "generated_at=$((Get-Date).ToString('o'))"
    "computer_name=$env:COMPUTERNAME"
    "powershell_version=$($PSVersionTable.PSVersion)"
    "session_name=$session"
    "aos_wpp_control_guid=$AosWppGuid"
    "aos_wpp_message_guid=$AosMessageGuid"
    "kernel_power_provider=$KernelPowerProvider"
    'operation=targeted-etw-capture-only'
    'display_transition=collector_requests_monitor_power_off_via_wm_syscommand'
    'machine_sleep_requested=false'
    'collector_sends_platform_ioctl=false'
    'devices_restarted=false'
    'pnp_state_modified=false'
    'camera_register_access=false'
    'direct_cpas_mmio=false'
    'ssc_contact=false'
) | Out-File -LiteralPath (Join-Path $output 'TRACE-INFO.txt') -Encoding utf8 -Width 8192

Save-CommandOutput -Name 'wpp-provider-query.txt' -Command {
    "Target control GUID: $AosWppGuid"
    logman.exe query providers 2>&1 | Select-String -Pattern ([Regex]::Escape($AosWppGuid.Trim('{}'))) -CaseSensitive:$false
}

Save-CommandOutput -Name 'aos-process-inventory-before.txt' -Command {
    Get-CimInstance Win32_Process -Filter "Name='WUDFHost.exe'" |
        Select-Object ProcessId, ParentProcessId, CreationDate, ExecutablePath, CommandLine |
        Format-List

    Get-Process -Name WUDFHost -ErrorAction SilentlyContinue | ForEach-Object {
        $process = $_
        try {
            $matches = @($process.Modules | Where-Object {
                $_.ModuleName -ieq 'qcAlwaysOnSensing.dll' -or
                $_.FileName -match 'qcAlwaysOnSensing\.dll$'
            })
            if ($matches.Count -gt 0) {
                "PID=$($process.Id) process=$($process.ProcessName)"
                $matches | Select-Object ModuleName, FileName, FileVersionInfo | Format-List
            }
        }
        catch {
            "PID=$($process.Id) module_enumeration_failed=$($_.Exception.Message)"
        }
    }
}

try {
    # A unique persistent collector set is used so each provider can be added
    # explicitly and the session can always be stopped/deleted in finally.
    Invoke-LogmanChecked -Label 'create' -Arguments @(
        'create', 'trace', '-n', $session,
        '-o', $etl,
        '-f', 'bincirc',
        '-max', '128',
        '-nb', '16', '128',
        '-bs', '64',
        '-ow'
    )
    $created = $true

    # qcAlwaysOnSensing.dll is a classic RegisterTraceGuids/TraceMessage WPP
    # provider. Use all 32 WPP flags and verbose level.
    Invoke-LogmanChecked -Label 'add-aos-wpp' -Arguments @(
        'update', 'trace', '-n', $session,
        '-p', $AosWppGuid, '0xffffffff', '0xff'
    )

    # Keep Kernel-Power in the same ETL so WPP message numbers can be correlated
    # against CAMP PoFx timestamps without cross-session clock conversion.
    Invoke-LogmanChecked -Label 'add-kernel-power' -Arguments @(
        'update', 'trace', '-n', $session,
        '-p', $KernelPowerProvider, '0xffffffffffffffff', '0xff'
    )

    Invoke-LogmanChecked -Label 'start' -Arguments @('start', '-n', $session)
    $started = $true

    $traceStarted = Get-Date
    @(
        "trace_started=$($traceStarted.ToString('o'))"
        'action=collector requests exactly one Windows display OFF transition; user wakes display normally'
        'note=no camera IOCTL or PnP/device operation is performed by this collector'
    ) | Out-File -LiteralPath (Join-Path $output 'ACTION-MARKERS.txt') -Encoding utf8

    Write-Host ('=' * 76)
    Write-Host 'ASUS Zenbook A14 targeted AOS WPP + CAMP PoFx trace'
    Write-Host ('=' * 76)
    Write-Host "Output:          $output"
    Write-Host "AOS WPP GUID:    $AosWppGuid"
    Write-Host "WPP message GUID:$AosMessageGuid"
    Write-Host ''
    Write-Host 'TRACE IS RUNNING.'
    Write-Host ''
    Write-Host 'Next:'
    Write-Host '  1. Press Enter below.'
    Write-Host '  2. The collector waits briefly, then asks Windows to turn the display OFF.'
    Write-Host '  3. Leave it off for about 3-5 seconds, then wake it using the touchpad,'
    Write-Host '     mouse, or keyboard. The machine itself does NOT sleep.'
    Write-Host '  4. When this terminal is visible again, press Enter once more to stop.'
    Write-Host ''

    [void](Read-Host 'Press Enter to request display OFF')
    $beforeAction = Get-Date
    "action_before=$($beforeAction.ToString('o'))" |
        Add-Content -LiteralPath (Join-Path $output 'ACTION-MARKERS.txt') -Encoding utf8

    # Avoid the Enter key-up event immediately waking the panel again.
    Start-Sleep -Milliseconds 1000
    Request-MonitorPowerOff

    [void](Read-Host 'After waking the display and returning here, press Enter to stop')
    $afterAction = Get-Date
    "action_after=$($afterAction.ToString('o'))" |
        Add-Content -LiteralPath (Join-Path $output 'ACTION-MARKERS.txt') -Encoding utf8

    Invoke-LogmanChecked -Label 'stop' -Arguments @('stop', '-n', $session)
    $started = $false

    $traceStopped = Get-Date
    "trace_stopped=$($traceStopped.ToString('o'))" |
        Add-Content -LiteralPath (Join-Path $output 'ACTION-MARKERS.txt') -Encoding utf8

    Save-CommandOutput -Name 'aos-process-inventory-after.txt' -Command {
        Get-Process -Name WUDFHost -ErrorAction SilentlyContinue | ForEach-Object {
            $process = $_
            try {
                $matches = @($process.Modules | Where-Object {
                    $_.ModuleName -ieq 'qcAlwaysOnSensing.dll' -or
                    $_.FileName -match 'qcAlwaysOnSensing\.dll$'
                })
                if ($matches.Count -gt 0) {
                    "PID=$($process.Id) process=$($process.ProcessName)"
                    $matches | Select-Object ModuleName, FileName, FileVersionInfo | Format-List
                }
            }
            catch {
                "PID=$($process.Id) module_enumeration_failed=$($_.Exception.Message)"
            }
        }
    }

    if (-not (Test-Path -LiteralPath $etl -PathType Leaf)) {
        throw "Trace stopped but ETL was not found at $etl"
    }

    $etlItem = Get-Item -LiteralPath $etl
    @(
        "completed_at=$((Get-Date).ToString('o'))"
        "etl=$etl"
        "etl_bytes=$($etlItem.Length)"
        "aos_wpp_control_guid=$AosWppGuid"
        "aos_wpp_message_guid=$AosMessageGuid"
        'expected_route_aos_success_message=273'
        'expected_main_restore_ap_success_message=337'
        'teardown_restore_message_range=278-284'
        'operation=targeted-etw-capture-only'
        'display_transition=collector_requests_monitor_power_off_via_wm_syscommand'
        'machine_sleep_requested=false'
        'collector_sends_platform_ioctl=false'
        'direct_cpas_mmio=false'
        'ssc_contact=false'
    ) | Out-File -LiteralPath (Join-Path $output 'TRACE-RESULT.txt') -Encoding utf8 -Width 8192

    $zip = "$output.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -LiteralPath $output -DestinationPath $zip -CompressionLevel Optimal

    Write-Host ''
    Write-Host "ETL size: $([Math]::Round($etlItem.Length / 1MB, 2)) MiB"
    Write-Host "Archive:  $zip"
    Write-Host 'Upload this ZIP. No additional broad/boot trace is needed.'
}
finally {
    if ($started) {
        try { & logman.exe stop -n $session 2>&1 | Out-Null } catch {}
    }
    if ($created) {
        try { & logman.exe delete -n $session 2>&1 | Out-Null } catch {}
    }
}
