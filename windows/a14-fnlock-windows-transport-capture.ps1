param(
    [string]$OutputRoot = "$env:USERPROFILE\Downloads\a14-fnlock-windows-transport-capture"
)

$ErrorActionPreference = 'Stop'
$Collector = Join-Path $PSScriptRoot 'a14-collect-qtec-hidi2c-transport.ps1'
$Trace = Join-Path $PSScriptRoot 'a14-fnlock-hidi2c-trace.ps1'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this capture from an Administrator PowerShell.'
}
if (-not (Test-Path -LiteralPath $Collector)) { throw "Missing collector: $Collector" }
if (-not (Test-Path -LiteralPath $Trace)) { throw "Missing trace helper: $Trace" }

if (Test-Path -LiteralPath $OutputRoot) {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

$stackDir = Join-Path $OutputRoot 'stack'
$traceDir = Join-Path $OutputRoot 'trace'

Write-Host '===== A14 FN-LOCK WINDOWS TRANSPORT CAPTURE ====='
Write-Host 'Phase 1/2: collect exact QTEC0001/HIDI2C/SPB stack and binaries.'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Collector -OutputDir $stackDir
if ($LASTEXITCODE -ne 0) { throw "Transport collector failed with exit code $LASTEXITCODE" }

Write-Host
Write-Host 'Phase 2/2: trace the already-proven working direct Fn-switch request.'
Write-Host 'You will be asked to verify state=0 and state=1 exactly as before.'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Trace -OutputDir $traceDir
if ($LASTEXITCODE -ne 0) { throw "HIDI2C trace failed with exit code $LASTEXITCODE" }

$hashPath = Join-Path $OutputRoot 'SHA256SUMS.txt'
Get-ChildItem -LiteralPath $OutputRoot -File -Recurse |
    Where-Object { $_.FullName -ne $hashPath } |
    Sort-Object FullName |
    ForEach-Object {
        $h = Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName
        $rel = $_.FullName.Substring($OutputRoot.Length).TrimStart('\')
        "$($h.Hash.ToLowerInvariant())  $rel"
    } | Set-Content -Encoding ASCII $hashPath

$zip = "$OutputRoot.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $OutputRoot '*') -DestinationPath $zip -CompressionLevel Optimal

Write-Host
Write-Host "FINAL_ZIP=$zip"
Write-Host 'A14_FNLOCK_WINDOWS_TRANSPORT_CAPTURE=PASS'
