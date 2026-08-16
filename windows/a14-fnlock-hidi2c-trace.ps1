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

function Get-ActualEtlFiles {
    # logman can suffix a configured base name on some systems. Do not assume
    # the requested literal path is the only valid filename; discover all ETLs
    # produced inside this capture directory and require real non-empty files.
    return @(Get-ChildItem -LiteralPath $OutputDir -File -Filter '*.etl' -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 0 } |
        Sort-Object FullName)
}

Write-Host '===== A14 WORKING WINDOWS FN-SWITCH HIDI2C TRACE ====='
Write-Host "output=$OutputDir"
Write-Host 'This traces the exact Windows HIDI2C/HIDCLASS path while the already-proven'
Write-Host 'direct 64-byte Fn-switch feature report is exercised with ASUSOptimization stopped.'
Write-Host 'The direct probe restores ASUSOptimization automatically.'
Write-Host

foreach ($provider in @('Microsoft-Windows-SPB-HIDI2C','Microsoft-Windows-Input-HIDCLASS')) {
    $safe = $provider -replace '[^A-Za-z0-9_.-]', '_'
    try {
        (& wevtutil.exe gp $provider /ge:true 2>&1) |
            Set-Content -Encoding UTF8 (Join-Path $OutputDir "$safe-provider.txt")
    }
    catch {}
}

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
    try {
        (& logman.exe query -ets 2>&1) | Set-Content -Encoding UTF8 (Join-Path $OutputDir 'trace-sessions-running.txt')
    }
    catch {}
    Write-Host 'TRACE=RUNNING'
    Write-Host

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
        # ETW buffers are flushed asynchronously by the logging stack on some
        # builds. Give the files a bounded chance to materialize before deleting
        # session definitions or declaring the capture complete.
        for ($i = 0; $i -lt 20; $i++) {
            if ((Get-ActualEtlFiles).Count -gt 0) { break }
            Start-Sleep -Milliseconds 250
        }
    }
    "TRACE_STOP=$(Get-Date -Format o)" | Add-Content -Encoding ASCII (Join-Path $OutputDir 'trace-times.txt')
    try {
        (& logman.exe query -ets 2>&1) | Set-Content -Encoding UTF8 (Join-Path $OutputDir 'trace-sessions-after-stop.txt')
    }
    catch {}
    Delete-AllTraceSessions
}

$etlFiles = Get-ActualEtlFiles
$etlManifest = Join-Path $OutputDir 'etl-files.txt'
if ($etlFiles.Count -gt 0) {
    $etlFiles | ForEach-Object { "$($_.Length)`t$($_.FullName)" } | Set-Content -Encoding UTF8 $etlManifest
}
else {
    'NO_NONEMPTY_ETL_FILES' | Set-Content -Encoding ASCII $etlManifest
}

foreach ($etl in $etlFiles) {
    $base = [IO.Path]::GetFileNameWithoutExtension($etl.Name)
    try {
        & tracerpt.exe $etl.FullName -of CSV -o (Join-Path $OutputDir "$base.csv") -y 2>&1 |
            Set-Content -Encoding UTF8 (Join-Path $OutputDir "$base-tracerpt.txt")
    }
    catch {}
    try {
        & tracerpt.exe $etl.FullName -of XML -o (Join-Path $OutputDir "$base.xml") -y 2>&1 |
            Set-Content -Encoding UTF8 (Join-Path $OutputDir "$base-tracerpt-xml.txt")
    }
    catch {}
}

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
Write-Host "ETL_COUNT=$($etlFiles.Count)"
Write-Host "HASHES=$hashPath"
Write-Host "ZIP=$zip"
if ($etlFiles.Count -eq 0) {
    Write-Host 'A14_FNLOCK_HIDI2C_TRACE=INCOMPLETE_NO_ETL'
    throw 'The probe succeeded, but no non-empty ETL was produced. Refusing to label the transport trace PASS.'
}
Write-Host 'A14_FNLOCK_HIDI2C_TRACE=PASS'
