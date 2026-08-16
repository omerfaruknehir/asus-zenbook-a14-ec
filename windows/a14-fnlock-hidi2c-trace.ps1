param(
    [string]$OutputDir = "$env:USERPROFILE\Downloads\a14-fnlock-hidi2c-trace"
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Probe = Join-Path $PSScriptRoot 'a14-fnlock-direct-hid-probe.ps1'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this trace from an Administrator PowerShell.'
}
if (-not (Test-Path -LiteralPath $Probe)) {
    throw "Missing direct HID probe: $Probe"
}

if (Test-Path -LiteralPath $OutputDir) {
    Remove-Item -LiteralPath $OutputDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$WppName = 'A14_HIDI2C_WPP'
$Hidi2cEtwName = 'A14_HIDI2C_ETW'
$HidclassEtwName = 'A14_HIDCLASS_ETW'
$WppFile = Join-Path $OutputDir 'HIDI2C-WPP.etl'
$Hidi2cEtwFile = Join-Path $OutputDir 'HIDI2C-ETW.etl'
$HidclassEtwFile = Join-Path $OutputDir 'HIDCLASS-ETW.etl'

function Run-Logman {
    param([string[]]$Args)
    $text = & logman.exe @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "logman $($Args -join ' ') failed with exit code $LASTEXITCODE`r`n$($text -join "`r`n")"
    }
    return $text
}

function Remove-TraceSession {
    param([string]$Name)
    & logman.exe stop -n $Name 2>$null | Out-Null
    & logman.exe delete -n $Name 2>$null | Out-Null
}

function Stop-AllTraceSessions {
    foreach ($name in @($WppName,$Hidi2cEtwName,$HidclassEtwName)) {
        try { & logman.exe stop -n $name 2>$null | Out-Null } catch {}
    }
}

function Delete-AllTraceSessions {
    foreach ($name in @($WppName,$Hidi2cEtwName,$HidclassEtwName)) {
        try { & logman.exe delete -n $name 2>$null | Out-Null } catch {}
    }
}

Write-Host '===== A14 WORKING WINDOWS FN-SWITCH HIDI2C TRACE ====='
Write-Host "output=$OutputDir"
Write-Host 'This traces the exact Windows HIDI2C/HIDCLASS path while the already-proven'
Write-Host 'direct 64-byte Fn-switch feature report is exercised with ASUSOptimization stopped.'
Write-Host 'The direct probe restores ASUSOptimization automatically.'
Write-Host

# Save provider metadata so the ETL can be decoded even if provider manifests
# differ across Windows releases.
foreach ($provider in @('Microsoft-Windows-SPB-HIDI2C','Microsoft-Windows-Input-HIDCLASS')) {
    $safe = $provider -replace '[^A-Za-z0-9_.-]', '_'
    try {
        (& wevtutil.exe gp $provider /ge:true 2>&1) |
            Set-Content -Encoding UTF8 (Join-Path $OutputDir "$safe-provider.txt")
    }
    catch {}
}

# Microsoft documents this WPP control GUID for HIDI2C.SYS. Full flags/verbose
# level are intentional: the goal is to recover the actual SPB write path for
# the working SetFeature, not just high-level HIDCLASS success.
foreach ($name in @($WppName,$Hidi2cEtwName,$HidclassEtwName)) {
    Remove-TraceSession $name
}

Run-Logman @('create','trace','-n',$WppName,'-o',$WppFile,'-nb','128','640','-bs','128') | Out-Null
Run-Logman @('update','trace','-n',$WppName,'-p','{E742C27D-29B1-4E4B-94EE-074D3AD72836}','0x7FFFFFFF','255') | Out-Null

Run-Logman @('create','trace','-n',$Hidi2cEtwName,'-o',$Hidi2cEtwFile,'-nb','128','640','-bs','128') | Out-Null
Run-Logman @('update','trace','-n',$Hidi2cEtwName,'-p','Microsoft-Windows-SPB-HIDI2C','0xFFFFFFFF','255') | Out-Null

Run-Logman @('create','trace','-n',$HidclassEtwName,'-o',$HidclassEtwFile,'-nb','128','640','-bs','128') | Out-Null
Run-Logman @('update','trace','-n',$HidclassEtwName,'-p','Microsoft-Windows-Input-HIDCLASS','0xFFFFFFFF','255') | Out-Null

$started = $false
try {
    Run-Logman @('start','-n',$WppName) | Out-Null
    Run-Logman @('start','-n',$Hidi2cEtwName) | Out-Null
    Run-Logman @('start','-n',$HidclassEtwName) | Out-Null
    $started = $true

    "TRACE_START=$(Get-Date -Format o)" | Set-Content -Encoding ASCII (Join-Path $OutputDir 'trace-times.txt')
    Write-Host 'TRACE=RUNNING'
    Write-Host

    # The existing probe is the already-validated Windows reproducer: it finds
    # exactly VID 0B05 / UsagePage FF31 / Usage 0076, stops ASUSOptimization,
    # sends state 0 and state 1 through HidD_SetFeature using the collection's
    # full 64-byte FeatureReportByteLength, waits for the user after each state,
    # and restores ASUSOptimization in a finally block.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Probe interactive 2>&1 |
        Tee-Object -FilePath (Join-Path $OutputDir 'direct-hid-probe.txt')
    $probeExit = $LASTEXITCODE
    "DIRECT_PROBE_EXIT=$probeExit" | Add-Content -Encoding ASCII (Join-Path $OutputDir 'trace-times.txt')
    if ($probeExit -ne 0) {
        throw "Direct HID probe failed with exit code $probeExit"
    }
}
finally {
    if ($started) {
        Stop-AllTraceSessions
    }
    "TRACE_STOP=$(Get-Date -Format o)" | Add-Content -Encoding ASCII (Join-Path $OutputDir 'trace-times.txt')
    Delete-AllTraceSessions
}

# Manifest ETW can usually be rendered immediately. WPP text may remain partly
# undecoded without matching symbols/TMF; preserve the raw ETL regardless.
foreach ($etl in @($Hidi2cEtwFile,$HidclassEtwFile,$WppFile)) {
    if (Test-Path -LiteralPath $etl) {
        $base = [IO.Path]::GetFileNameWithoutExtension($etl)
        try {
            & tracerpt.exe $etl -of CSV -o (Join-Path $OutputDir "$base.csv") -y 2>&1 |
                Set-Content -Encoding UTF8 (Join-Path $OutputDir "$base-tracerpt.txt")
        }
        catch {}
        try {
            & tracerpt.exe $etl -of XML -o (Join-Path $OutputDir "$base.xml") -y 2>&1 |
                Set-Content -Encoding UTF8 (Join-Path $OutputDir "$base-tracerpt-xml.txt")
        }
        catch {}
    }
}

# Capture exact versions of the two Windows layers whose behavior we are
# comparing against Linux. The transport collector captures the wider PnP/SPB
# stack; keeping these here makes the trace self-identifying too.
$binDir = Join-Path $OutputDir 'binaries'
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
foreach ($name in @('hidi2c.sys','hidclass.sys','hidparse.sys','SpbCx.sys')) {
    $src = Join-Path $env:windir "System32\drivers\$name"
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $binDir $name) -Force
    }
}

$hashPath = Join-Path $OutputDir 'SHA256SUMS.txt'
Get-ChildItem -LiteralPath $OutputDir -File -Recurse |
    Where-Object { $_.FullName -ne $hashPath } |
    Sort-Object FullName |
    ForEach-Object {
        $h = Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName
        $rel = $_.FullName.Substring($OutputDir.Length).TrimStart('\')
        "$($h.Hash.ToLowerInvariant())  $rel"
    } | Set-Content -Encoding ASCII $hashPath

$zip = "$OutputDir.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $OutputDir '*') -DestinationPath $zip -CompressionLevel Optimal

Write-Host
Write-Host "HASHES=$hashPath"
Write-Host "ZIP=$zip"
Write-Host 'A14_FNLOCK_HIDI2C_TRACE=PASS'
