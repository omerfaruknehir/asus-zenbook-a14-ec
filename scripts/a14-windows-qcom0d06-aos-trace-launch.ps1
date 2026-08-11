#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputRoot = "$env:USERPROFILE\Desktop",
    [switch]$OpenPresenceSettings,
    [switch]$UsePresenceSensorSample,
    [switch]$UseBuiltInPresenceMonitor,
    [ValidateRange(5, 300)][int]$MonitorSeconds = 30,
    [switch]$RelaunchedInWindowsPowerShell
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$mainScript = Join-Path $PSScriptRoot 'a14-windows-qcom0d06-aos-trace.ps1'

if (-not (Test-Path -LiteralPath $mainScript -PathType Leaf)) {
    throw "Trace script not found: $mainScript"
}

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    if ($RelaunchedInWindowsPowerShell) {
        throw 'Relaunch loop detected while trying to enter Windows PowerShell 5.1.'
    }
    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
        throw "Windows PowerShell 5.1 was not found at $windowsPowerShell"
    }

    Write-Host "Current host: PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    Write-Host 'Relaunching under Windows PowerShell 5.1 for WinRT projection support...'

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath,
        '-RelaunchedInWindowsPowerShell',
        '-OutputRoot', $OutputRoot,
        '-MonitorSeconds', [string]$MonitorSeconds
    )
    if ($OpenPresenceSettings) { $arguments += '-OpenPresenceSettings' }
    if ($UsePresenceSensorSample) { $arguments += '-UsePresenceSensorSample' }
    if ($UseBuiltInPresenceMonitor) { $arguments += '-UseBuiltInPresenceMonitor' }

    & $windowsPowerShell @arguments
    exit $LASTEXITCODE
}

Write-Host "Host preflight: Windows PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

if ($UseBuiltInPresenceMonitor) {
    try {
        [Windows.Devices.Sensors.HumanPresenceSensor,Windows.Devices.Sensors,ContentType=WindowsRuntime] | Out-Null
        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
        Write-Host 'WinRT preflight: HumanPresenceSensor type available.' -ForegroundColor Green
    }
    catch {
        throw @"
HumanPresenceSensor WinRT preflight failed BEFORE WPR was started.
Host: Windows PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))
Error: $($_.Exception.Message)

Confirm this is Windows 11 with the HumanPresenceSensor API and that the OS is fully updated.
"@
    }
}

$invokeArgs = @{
    OutputRoot = $OutputRoot
    MonitorSeconds = $MonitorSeconds
}
if ($OpenPresenceSettings) { $invokeArgs.OpenPresenceSettings = $true }
if ($UsePresenceSensorSample) { $invokeArgs.UsePresenceSensorSample = $true }
if ($UseBuiltInPresenceMonitor) { $invokeArgs.UseBuiltInPresenceMonitor = $true }

& $mainScript @invokeArgs
exit $LASTEXITCODE
