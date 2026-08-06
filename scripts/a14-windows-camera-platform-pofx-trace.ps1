#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputRoot = "$env:USERPROFILE\Desktop"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Save-Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )

    try {
        & $Command 2>&1 | Out-File -LiteralPath $Path -Encoding utf8 -Width 8192
    }
    catch {
        @(
            'collection_status=failed'
            "exception=$($_.Exception.GetType().FullName)"
            "message=$($_.Exception.Message)"
        ) | Out-File -LiteralPath $Path -Encoding utf8 -Width 8192
    }
}

function Invoke-Wpr {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $output = & wpr.exe @Arguments 2>&1
    $status = $LASTEXITCODE
    $output | Out-File -LiteralPath $LogPath -Encoding utf8 -Width 8192
    if ($status -ne 0) {
        throw "wpr.exe failed with exit code $status. See $LogPath"
    }
}

if (-not (Test-Administrator)) {
    throw 'Run this script from an elevated Windows PowerShell window.'
}

$wpr = Get-Command wpr.exe -ErrorAction Stop
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $OutputRoot "A14-Camera-Platform-PoFx-Trace-$stamp"
New-Item -ItemType Directory -Force -Path $output | Out-Null
$etl = Join-Path $output 'camera-platform-pofx.etl'
$traceStarted = $false
$traceStopped = $false
$traceStart = $null
$traceEnd = $null

Write-Host ('=' * 76)
Write-Host 'ASUS Zenbook A14 Windows camera-platform PoFx trace'
Write-Host ('=' * 76)
Write-Host "Output: $output"
Write-Host ''
Write-Host 'This collector starts the built-in Windows Performance Recorder Power profile.'
Write-Host 'It does not send camera IOCTLs, restart devices, or write camera registers.'
Write-Host 'You must manually exercise the normal Windows feature that activates AOS.'
Write-Host ''

Save-Text -Path (Join-Path $output 'wpr-status-before.txt') -Command {
    & $wpr.Source -status
}
$statusText = Get-Content -LiteralPath (Join-Path $output 'wpr-status-before.txt') -Raw
if ($statusText -notmatch '(?i)no\s+recording|not\s+recording|no\s+trace') {
    throw 'Another WPR recording may already be active. Stop it before running this collector.'
}

Save-Text -Path (Join-Path $output 'wpr-profiles.txt') -Command {
    & $wpr.Source -profiles
}
Save-Text -Path (Join-Path $output 'matching-etw-providers.txt') -Command {
    logman.exe query providers |
        Select-String -Pattern 'camera|qcom|qualcomm|cpas|camnoc|aos|sensor|pofx|pep|power|pdc' -CaseSensitive:$false
}
Save-Text -Path (Join-Path $output 'powercfg-requests-before.txt') -Command {
    powercfg.exe /requests
}
Save-Text -Path (Join-Path $output 'camera-platform-devices-before.txt') -Command {
    foreach ($id in @('QCOM0C32', 'QCOM0C17', 'QCOM0C2B', 'QCOM0C0C')) {
        "===== $id ====="
        pnputil.exe /enum-devices /deviceid $id /properties /drivers
    }
}

@(
    "generated_at=$((Get-Date).ToString('o'))"
    "computer_name=$env:COMPUTERNAME"
    "user_name=$env:USERNAME"
    "powershell_version=$($PSVersionTable.PSVersion)"
    "wpr_path=$($wpr.Source)"
    'trace_profile=Power'
    'trace_mode=filemode'
    'camera_ioctls_sent_by_collector=false'
    'devices_restarted=false'
    'camera_register_writes_by_collector=false'
    'manual_windows_feature_activation_required=true'
) | Out-File -LiteralPath (Join-Path $output 'TRACE-INFO.txt') -Encoding utf8 -Width 8192

Read-Host 'Press ENTER when ready to start the Power trace' | Out-Null

try {
    Invoke-Wpr -Arguments @('-start', 'Power', '-filemode') -LogPath (Join-Path $output 'wpr-start.txt')
    $traceStarted = $true
    $traceStart = Get-Date

    Write-Host ''
    Write-Host 'TRACE RUNNING.'
    Write-Host 'Now activate and use the normal Windows presence-sensing/AOS feature.'
    Write-Host 'After the feature has entered its active state, leave it active briefly.'
    Read-Host 'Then press ENTER to stop and save the trace' | Out-Null

    $traceEnd = Get-Date
    Invoke-Wpr -Arguments @('-stop', $etl) -LogPath (Join-Path $output 'wpr-stop.txt')
    $traceStopped = $true
}
finally {
    if ($traceStarted -and -not $traceStopped) {
        $recoveryEtl = Join-Path $output 'camera-platform-pofx-recovery.etl'
        try {
            Invoke-Wpr -Arguments @('-stop', $recoveryEtl) -LogPath (Join-Path $output 'wpr-recovery-stop.txt')
            $traceStopped = $true
            if (-not $traceEnd) { $traceEnd = Get-Date }
        }
        catch {
            & $wpr.Source -cancel 2>&1 |
                Out-File -LiteralPath (Join-Path $output 'wpr-cancel.txt') -Encoding utf8 -Width 8192
        }
    }
}

if (-not $traceStart) { throw 'The trace did not start.' }
if (-not $traceEnd) { $traceEnd = Get-Date }

Save-Text -Path (Join-Path $output 'wpr-status-after.txt') -Command {
    & $wpr.Source -status
}
Save-Text -Path (Join-Path $output 'powercfg-requests-after.txt') -Command {
    powercfg.exe /requests
}
Save-Text -Path (Join-Path $output 'camera-platform-devices-after.txt') -Command {
    foreach ($id in @('QCOM0C32', 'QCOM0C17', 'QCOM0C2B', 'QCOM0C0C')) {
        "===== $id ====="
        pnputil.exe /enum-devices /deviceid $id /properties /drivers
    }
}
Save-Text -Path (Join-Path $output 'system-events-trace-window.txt') -Command {
    Get-WinEvent -FilterHashtable @{
        LogName = 'System'
        StartTime = $traceStart.AddSeconds(-2)
        EndTime = $traceEnd.AddSeconds(2)
    } | Where-Object {
        $_.ProviderName -match 'Power|Kernel|PnP|Driver|Camera|Sensor|Qualcomm|QCOM|PDC' -or
        $_.Message -match 'PoFx|PEP|camera|sensor|QCOM|Qualcomm|power framework'
    } | Format-List TimeCreated, ProviderName, Id, LevelDisplayName, Message
}

@(
    "trace_started=$($traceStart.ToString('o'))"
    "trace_stopped=$($traceEnd.ToString('o'))"
    "trace_duration_seconds=$([math]::Round(($traceEnd - $traceStart).TotalSeconds, 3))"
    "etl=$etl"
    "etl_exists=$(Test-Path -LiteralPath $etl -PathType Leaf)"
    "etl_size=$((Get-Item -LiteralPath $etl -ErrorAction SilentlyContinue).Length)"
    'collector_hardware_control=false'
) | Out-File -LiteralPath (Join-Path $output 'TRACE-RESULT.txt') -Encoding utf8 -Width 8192

$zip = "$output.zip"
if (Test-Path -LiteralPath $zip) {
    Remove-Item -LiteralPath $zip -Force
}
Compress-Archive -LiteralPath $output -DestinationPath $zip -CompressionLevel Optimal

Write-Host ''
Write-Host "Trace directory: $output"
Write-Host "Archive:         $zip"
Write-Host 'Upload the ZIP for analysis. The collector itself issued no camera-control request.'
