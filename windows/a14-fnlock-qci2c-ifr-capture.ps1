param(
    [string]$OutDir = "$(Join-Path $PSScriptRoot 'a14-fnlock-qci2c-ifr-capture')"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Require-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated PowerShell window.'
    }
}

function Invoke-Checked([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "$Exe exited with code $LASTEXITCODE: $($Arguments -join ' ')"
    }
}

function Snapshot-Qci2cIfr([string]$Tag, [string]$TraceGuid, [string]$Root) {
    # This mirrors Microsoft WDF Tools/GetIfr.ps1. WppRecorder.sys exposes the
    # already-existing circular IFR through a short ETW session; it does not
    # enable a new qci2c trace provider or change controller configuration.
    $recorderProvider = '{772013fb-617e-4269-a691-66a6847d2856}'
    $session = "A14Qci2cIfr_$PID`_$Tag"
    $etl = Join-Path $Root "qci2c-$Tag.etl"
    $xml = Join-Path $Root "qci2c-$Tag.xml"
    $csv = Join-Path $Root "qci2c-$Tag.csv"

    Remove-Item -LiteralPath $etl,$xml,$csv -Force -ErrorAction SilentlyContinue

    try {
        Invoke-Checked logman.exe @('create','trace',$session,'-o',$etl,'-ets')
        Invoke-Checked logman.exe @('update',$session,'-p',$recorderProvider,'0xff','0xff','-ets')
        Invoke-Checked logman.exe @('update',$session,'-p',$TraceGuid,'0x40000000','0xff','-ets')
    }
    finally {
        & logman.exe stop $session -ets 2>$null | Out-Null
    }

    if (-not (Test-Path -LiteralPath $etl)) {
        throw "IFR snapshot was not created: $etl"
    }

    # Best-effort generic ETL projections. WPP message text may still require
    # the exact driver PDB/TMF, so the raw ETL is always retained.
    if (Get-Command tracerpt.exe -ErrorAction SilentlyContinue) {
        & tracerpt.exe $etl -o $xml -of XML -y *> (Join-Path $Root "tracerpt-$Tag-xml.txt")
        & tracerpt.exe $etl -o $csv -of CSV -y *> (Join-Path $Root "tracerpt-$Tag-csv.txt")
    }

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $etl).Hash.ToLowerInvariant()
    Add-Content -LiteralPath (Join-Path $Root 'timeline.txt') -Value (
        "{0:o} IFR tag={1} file={2} sha256={3}" -f [DateTimeOffset]::Now, $Tag, [IO.Path]::GetFileName($etl), $hash)
    Write-Host "IFR[$Tag]=$etl"
    Write-Host "IFR[$Tag]_SHA256=$hash"
}

function Read-Observation([string]$Prompt) {
    while ($true) {
        $v = (Read-Host $Prompt).Trim()
        if ($v.Length -gt 0) { return $v }
        Write-Host 'Please type what F3 and Fn+F3 do; blank is ambiguous.' -ForegroundColor Yellow
    }
}

Require-Administrator

$directProbe = Join-Path $PSScriptRoot 'a14-fnlock-direct-hid-probe.ps1'
if (-not (Test-Path -LiteralPath $directProbe)) {
    throw "Missing sibling direct-HID probe: $directProbe"
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
Remove-Item -LiteralPath (Join-Path $OutDir 'timeline.txt') -Force -ErrorAction SilentlyContinue

Write-Host '===== A14 QCI2C IFR + DIRECT FN-LOCK CAPTURE ====='
Write-Host "output=$OutDir"
Write-Host "start=$([DateTimeOffset]::Now.ToString('o'))"

$svc = Get-Service -Name qci2c -ErrorAction Stop
if ($svc.Status -ne 'Running') {
    throw "qci2c service is not running (status=$($svc.Status))"
}

$sharedState = 'HKLM:\SYSTEM\CurrentControlSet\Services\qci2c\SharedState'
$paramsPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\qci2c\Parameters'
$traceGuid = (Get-ItemProperty -Path $sharedState -Name WppRecorder_TraceGuid -ErrorAction Stop).WppRecorder_TraceGuid
if (-not $traceGuid) { throw 'qci2c WppRecorder_TraceGuid is empty' }
Write-Host "qci2c_trace_guid=$traceGuid"

# Preserve all relevant configuration as evidence. These commands are read-only.
Get-ItemProperty -Path $paramsPath -ErrorAction SilentlyContinue |
    Format-List * | Out-File -Encoding utf8 (Join-Path $OutDir 'qci2c-parameters.txt')
Get-ItemProperty -Path $sharedState -ErrorAction SilentlyContinue |
    Format-List * | Out-File -Encoding utf8 (Join-Path $OutDir 'qci2c-shared-state.txt')
sc.exe qc qci2c | Out-File -Encoding utf8 (Join-Path $OutDir 'qci2c-sc-qc.txt')
sc.exe query qci2c | Out-File -Encoding utf8 (Join-Path $OutDir 'qci2c-sc-query.txt')

$driverPath = (Get-CimInstance Win32_SystemDriver -Filter "Name='qci2c'").PathName
$driverPath = [Environment]::ExpandEnvironmentVariables($driverPath)
if ($driverPath.StartsWith('\SystemRoot\', [StringComparison]::OrdinalIgnoreCase)) {
    $driverPath = Join-Path $env:SystemRoot $driverPath.Substring(12)
}
$driverPath = $driverPath.Trim('"')
if (Test-Path -LiteralPath $driverPath) {
    Get-Item -LiteralPath $driverPath | Select-Object FullName,Length,@{N='FileVersion';E={$_.VersionInfo.FileVersion}},@{N='ProductVersion';E={$_.VersionInfo.ProductVersion}} |
        Format-List | Out-File -Encoding utf8 (Join-Path $OutDir 'qci2c-driver.txt')
    Get-FileHash -Algorithm SHA256 -LiteralPath $driverPath |
        Format-List | Out-File -Encoding utf8 (Join-Path $OutDir 'qci2c-driver-sha256.txt')
}

# Reuse the exact C# HID implementation from the already-proven direct probe,
# rather than creating a second subtly different HidD_SetFeature implementation.
$probeText = Get-Content -Raw -LiteralPath $directProbe
$m = [regex]::Match($probeText, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
if (-not $m.Success) {
    throw 'Could not extract A14HidFnLock C# helper from direct-HID probe.'
}
if (-not ('A14HidFnLock' -as [type])) {
    Add-Type -TypeDefinition $m.Groups[1].Value
}

$all = @([A14HidFnLock]::Enumerate())
$matches = @($all | Where-Object {
    $_.VendorId -eq 0x0B05 -and $_.UsagePage -eq 0xFF31 -and $_.Usage -eq 0x0076
})
if ($matches.Count -ne 1) {
    throw "Expected exactly one 0B05 FF31:0076 collection; found $($matches.Count)."
}
$target = $matches[0]

@(
    "captured_at=$([DateTimeOffset]::Now.ToString('o'))",
    "path=$($target.Path)",
    "vid=0x$($target.VendorId.ToString('X4'))",
    "pid=0x$($target.ProductId.ToString('X4'))",
    "usage_page=0x$($target.UsagePage.ToString('X4'))",
    "usage=0x$($target.Usage.ToString('X4'))",
    "feature_report_length=$($target.FeatureReportLength)",
    "direct_probe_sha256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $directProbe).Hash.ToLowerInvariant())"
) | Set-Content -Encoding utf8 (Join-Path $OutDir 'target.txt')

$asusSvc = Get-Service -Name ASUSOptimization -ErrorAction SilentlyContinue
$asusWasRunning = $null -ne $asusSvc -and $asusSvc.Status -eq 'Running'
$obs0 = ''
$obs1 = ''

try {
    if ($asusWasRunning) {
        Write-Host 'Stopping ASUSOptimization so it cannot race the direct probe...'
        Stop-Service -Name ASUSOptimization -Force
        (Get-Service -Name ASUSOptimization).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15))
    }

    "{0:o} ASUSOptimization={1}" -f [DateTimeOffset]::Now, $(if ($null -eq $asusSvc) {'NOT_FOUND'} else {(Get-Service ASUSOptimization).Status}) |
        Add-Content -LiteralPath (Join-Path $OutDir 'timeline.txt')

    Snapshot-Qci2cIfr -Tag 'before' -TraceGuid $traceGuid -Root $OutDir

    Write-Host ''
    Write-Host '===== WINDOWS DIRECT STATE=0 ====='
    $t0 = [DateTimeOffset]::Now
    [A14HidFnLock]::SetFnSwitch($target.Path, $target.FeatureReportLength, $false)
    Add-Content -LiteralPath (Join-Path $OutDir 'timeline.txt') -Value ("{0:o} HidD_SetFeature state=0 SUCCESS bytes=5A-D0-4E-00 len={1}" -f $t0, $target.FeatureReportLength)
    Snapshot-Qci2cIfr -Tag 'state0' -TraceGuid $traceGuid -Root $OutDir
    $obs0 = Read-Observation 'After state=0, what do plain F3 and Fn+F3 do?'
    Add-Content -LiteralPath (Join-Path $OutDir 'timeline.txt') -Value ("{0:o} state0_observation={1}" -f [DateTimeOffset]::Now, $obs0)

    Write-Host ''
    Write-Host '===== WINDOWS DIRECT STATE=1 ====='
    $t1 = [DateTimeOffset]::Now
    [A14HidFnLock]::SetFnSwitch($target.Path, $target.FeatureReportLength, $true)
    Add-Content -LiteralPath (Join-Path $OutDir 'timeline.txt') -Value ("{0:o} HidD_SetFeature state=1 SUCCESS bytes=5A-D0-4E-01 len={1}" -f $t1, $target.FeatureReportLength)
    Snapshot-Qci2cIfr -Tag 'state1' -TraceGuid $traceGuid -Root $OutDir
    $obs1 = Read-Observation 'After state=1, what do plain F3 and Fn+F3 do?'
    Add-Content -LiteralPath (Join-Path $OutDir 'timeline.txt') -Value ("{0:o} state1_observation={1}" -f [DateTimeOffset]::Now, $obs1)
}
finally {
    if ($asusWasRunning) {
        Start-Service -Name ASUSOptimization
        (Get-Service -Name ASUSOptimization).WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
        Add-Content -LiteralPath (Join-Path $OutDir 'timeline.txt') -Value ("{0:o} ASUSOptimization restored RUNNING" -f [DateTimeOffset]::Now)
    }
}

@(
    "STATE_0_OBSERVATION=$obs0",
    "STATE_1_OBSERVATION=$obs1",
    "QCI2C_TRACE_GUID=$traceGuid",
    "CAPTURE_COMPLETE=$([DateTimeOffset]::Now.ToString('o'))"
) | Set-Content -Encoding utf8 (Join-Path $OutDir 'RESULT.txt')

Get-ChildItem -LiteralPath $OutDir -File | Sort-Object Name | ForEach-Object {
    $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
    "$h  $($_.Name)"
} | Set-Content -Encoding ascii (Join-Path $OutDir 'SHA256SUMS.txt')

$zip = "$OutDir.zip"
Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $OutDir '*') -DestinationPath $zip -CompressionLevel Optimal
Write-Host ''
Write-Host "A14_QCI2C_IFR_CAPTURE=COMPLETE"
Write-Host "ZIP=$zip"
Write-Host "ZIP_SHA256=$((Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant())"
