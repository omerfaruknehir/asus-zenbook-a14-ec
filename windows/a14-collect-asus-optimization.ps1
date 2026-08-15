param(
    [string]$OutputDir = "$env:USERPROFILE\Downloads\a14-asus-optimization"
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Write-Host '===== A14 ASUS OPTIMIZATION / FN-SWITCH CAPTURE ====='
Write-Host "output=$OutputDir"

function Strip-ExePath([string]$PathName) {
    if ([string]::IsNullOrWhiteSpace($PathName)) { return $null }
    $p = $PathName.Trim()
    if ($p.StartsWith('"')) {
        $end = $p.IndexOf('"', 1)
        if ($end -gt 1) { return $p.Substring(1, $end - 1) }
    }
    $m = [regex]::Match($p, '^(.*?\.exe)(?:\s|$)', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value }
    return $p
}

$services = @(Get-CimInstance Win32_Service | Where-Object {
    $_.Name -match 'ASUSOptimization|ASUS|ATK' -or
    $_.DisplayName -match 'ASUS|ATK' -or
    $_.PathName -match 'ASUSOptimization|ASUS|ATK'
})
$servicePath = Join-Path $OutputDir 'asus-user-services.txt'
$services | Select-Object Name, DisplayName, State, StartMode, ProcessId, PathName |
    Sort-Object Name | Format-List | Out-String -Width 500 |
    Set-Content -Encoding UTF8 $servicePath
Write-Host "SERVICES=$servicePath"

$processPath = Join-Path $OutputDir 'asus-processes.txt'
Get-CimInstance Win32_Process | Where-Object {
    $_.Name -match 'Asus|ATK' -or $_.ExecutablePath -match 'Asus|ATK'
} | Select-Object Name, ProcessId, ParentProcessId, ExecutablePath, CommandLine |
    Sort-Object Name,ProcessId | Format-List | Out-String -Width 600 |
    Set-Content -Encoding UTF8 $processPath
Write-Host "PROCESSES=$processPath"

# Locate the exact currently installed ASUS System Control Interface package by
# the running ATKWMIACPIIO kernel service. Its path normally points inside:
#   ...\FileRepository\asussci2.inf_*\ASUSOptimization\AsusWmiAcpi.sys
$atk = @(Get-CimInstance Win32_SystemDriver | Where-Object {
    $_.Name -eq 'ATKWMIACPIIO' -or $_.PathName -match 'AsusWmiAcpi\.sys'
}) | Select-Object -First 1

$packageRoot = $null
$optimizationDir = $null
if ($null -ne $atk) {
    $driverPath = [Environment]::ExpandEnvironmentVariables(([string]$atk.PathName).Trim('"'))
    if (Test-Path $driverPath) {
        $optimizationDir = Split-Path -Parent $driverPath
        $packageRoot = Split-Path -Parent $optimizationDir
    }
}

# Fallback: derive from a user-mode ASUSOptimization service executable.
if ($null -eq $optimizationDir) {
    foreach ($svc in $services) {
        $exe = Strip-ExePath ([string]$svc.PathName)
        if ($exe -and $exe -match 'AsusOptimization\.exe$' -and (Test-Path $exe)) {
            $optimizationDir = Split-Path -Parent $exe
            $packageRoot = Split-Path -Parent $optimizationDir
            break
        }
    }
}

Write-Host "PACKAGE_ROOT=$packageRoot"
Write-Host "ASUS_OPTIMIZATION_SOURCE=$optimizationDir"
if ($null -eq $optimizationDir -or -not (Test-Path $optimizationDir)) {
    throw 'Could not locate the installed ASUSOptimization directory safely.'
}

$payload = Join-Path $OutputDir 'ASUSOptimization'
if (Test-Path $payload) { Remove-Item -Force -Recurse $payload }
Copy-Item -Recurse -Force $optimizationDir $payload
Write-Host "ASUS_OPTIMIZATION_COPY=$payload"

# Preserve the package INF/CAT metadata adjacent to ASUSOptimization too.
$packageMeta = Join-Path $OutputDir 'package-metadata'
New-Item -ItemType Directory -Force -Path $packageMeta | Out-Null
if ($packageRoot -and (Test-Path $packageRoot)) {
    Get-ChildItem -File $packageRoot -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension -in '.inf','.cat','.pnf'
    } | Copy-Item -Destination $packageMeta -Force
}

$fileInfoPath = Join-Path $OutputDir 'file-info.txt'
$infoLines = New-Object System.Collections.Generic.List[string]
Get-ChildItem -File -Recurse $payload | ForEach-Object {
    $v = $_.VersionInfo
    $infoLines.Add("===== $($_.FullName.Substring($OutputDir.Length).TrimStart('\')) =====")
    $infoLines.Add("Length=$($_.Length)")
    $infoLines.Add("FileVersion=$($v.FileVersion)")
    $infoLines.Add("ProductVersion=$($v.ProductVersion)")
    $infoLines.Add("CompanyName=$($v.CompanyName)")
    $infoLines.Add("FileDescription=$($v.FileDescription)")
    $infoLines.Add('')
}
$infoLines | Set-Content -Encoding UTF8 $fileInfoPath
Write-Host "FILE_INFO=$fileInfoPath"

# Extract printable strings around the exact implementation hints while still
# preserving the original signed binaries for offline ARM64 disassembly.
$stringsPath = Join-Path $OutputDir 'fn-switch-printable-strings.txt'
$stringLines = New-Object System.Collections.Generic.List[string]
foreach ($file in Get-ChildItem -File -Recurse $payload | Where-Object { $_.Extension -in '.exe','.dll','.sys' }) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $ascii = [Text.Encoding]::ASCII.GetString($bytes)
    $unicode = [Text.Encoding]::Unicode.GetString($bytes)
    $matches = @()
    foreach ($text in @($ascii,$unicode)) {
        $matches += [regex]::Matches($text, '[ -~]{4,}') | ForEach-Object { $_.Value } | Where-Object {
            $_ -match 'Fn.?switch|Fn.?Lock|SetFeature|GetFeature|HidD_|Keyboard|Hotkey|KPICDO|DeviceIoControl'
        }
    }
    if ($matches.Count -gt 0) {
        $stringLines.Add("===== $($file.FullName.Substring($OutputDir.Length).TrimStart('\')) =====")
        foreach ($line in ($matches | Select-Object -Unique)) { $stringLines.Add($line) }
        $stringLines.Add('')
    }
}
$stringLines | Set-Content -Encoding UTF8 $stringsPath
Write-Host "FN_SWITCH_STRINGS=$stringsPath"

$hashPath = Join-Path $OutputDir 'SHA256SUMS.txt'
Get-ChildItem -File -Recurse $OutputDir |
    Where-Object FullName -ne $hashPath |
    ForEach-Object {
        $h = Get-FileHash -Algorithm SHA256 $_.FullName
        $rel = $_.FullName.Substring($OutputDir.Length).TrimStart('\')
        "$($h.Hash.ToLowerInvariant())  $rel"
    } | Set-Content -Encoding ASCII $hashPath
Write-Host "HASHES=$hashPath"

$zip = "$OutputDir.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $OutputDir '*') -DestinationPath $zip
Write-Host "ZIP=$zip"
Write-Host 'A14_ASUS_OPTIMIZATION_CAPTURE=PASS'
