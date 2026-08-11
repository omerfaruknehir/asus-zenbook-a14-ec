#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$TracePath,

    [int]$AosProcessId = 8288,

    [string]$OutputRoot = "$env:USERPROFILE\Desktop",

    [switch]$NoDesktopRelaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $NoDesktopRelaunch -and $PSVersionTable.PSEdition -ne 'Desktop') {
    $desktopPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $desktopPowerShell -PathType Leaf)) {
        throw "Windows PowerShell 5.1 was not found at $desktopPowerShell."
    }

    $argsDesktop = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
        '-TracePath', $TracePath,
        '-AosProcessId', [string]$AosProcessId,
        '-OutputRoot', $OutputRoot,
        '-NoDesktopRelaunch'
    )
    Write-Host 'Relaunching offline ETL decode under Windows PowerShell 5.1...'
    & $desktopPowerShell @argsDesktop
    exit $LASTEXITCODE
}

# These values are already established from the targeted Kernel-Power and
# process-identity exports of A14-Camera-Platform-Boot-PoFx-Trace-20260807-231205.
# This helper deliberately skips rediscovering them from the 2.7 GB ETL.
$campToken = '0xffffd30c46ce4b20'
$knownWindows = @(
    [pscustomobject]@{
        Request = [DateTimeOffset]::Parse('2026-08-07T23:11:14.2672870+03:00')
        Release = [DateTimeOffset]::Parse('2026-08-07T23:11:14.2890930+03:00')
        RequestProcessId = 8288
        ReleaseProcessId = 8288
    },
    [pscustomobject]@{
        Request = [DateTimeOffset]::Parse('2026-08-07T23:11:16.1216700+03:00')
        Release = [DateTimeOffset]::Parse('2026-08-07T23:11:16.1454720+03:00')
        RequestProcessId = 8288
        ReleaseProcessId = 8288
    },
    [pscustomobject]@{
        Request = [DateTimeOffset]::Parse('2026-08-07T23:11:20.2234110+03:00')
        Release = [DateTimeOffset]::Parse('2026-08-07T23:11:21.2513340+03:00')
        RequestProcessId = 8288
        ReleaseProcessId = 4
    }
)

function Resolve-TraceEtl {
    param([Parameter(Mandatory = $true)][string]$InputPath)

    $resolved = Resolve-Path -LiteralPath $InputPath -ErrorAction Stop
    $item = Get-Item -LiteralPath $resolved.Path
    if (-not $item.PSIsContainer -and $item.Extension -ieq '.etl') { return $item.FullName }
    if ($item.PSIsContainer) {
        $etl = Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Filter '*.etl' |
            Sort-Object Length -Descending | Select-Object -First 1
        if (-not $etl) { throw "No ETL file was found under $($item.FullName)." }
        return $etl.FullName
    }
    throw 'For the fast extractor, TracePath must point to the raw trace directory or ETL.'
}

function Convert-ToSystemTimeText {
    param([Parameter(Mandatory = $true)][DateTimeOffset]$Time)
    return $Time.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-NamedPayload {
    param([Parameter(Mandatory = $true)][string]$EventXml)
    try {
        [xml]$document = $EventXml
        $pairs = @()
        $nodes = $document.SelectNodes('/*[local-name()="Event"]/*[local-name()="EventData"]/*[local-name()="Data"]')
        foreach ($node in @($nodes)) {
            $name = [string]$node.GetAttribute('Name')
            if ([string]::IsNullOrWhiteSpace($name)) { $name = 'Value' }
            $pairs += ("{0}={1}" -f $name, [string]$node.InnerText)
        }
        return ($pairs -join ' | ')
    }
    catch { return '' }
}

$etl = Resolve-TraceEtl -InputPath $TracePath
$etlItem = Get-Item -LiteralPath $etl
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $OutputRoot "A14-AOS-Host-Known-Windows-Export-$stamp"
New-Item -ItemType Directory -Force -Path $output | Out-Null

Write-Host ('=' * 76)
Write-Host 'ASUS Zenbook A14 fast offline AOS-host known-window exporter'
Write-Host ('=' * 76)
Write-Host "PowerShell host: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
Write-Host "Input ETL:       $etl"
Write-Host "AOS process PID: $AosProcessId"
Write-Host "Known CAMP token: $campToken"
Write-Host 'Discovery passes: skipped (known trace evidence reused).'
Write-Host 'Offline decode only: no process, device, PnP, IOCTL, sensor, or register operation.'
Write-Host ''

$rows = @()
$xmlEvents = @()
$providerCounts = @{}
$eventsReturned = 0L

for ($i = 0; $i -lt $knownWindows.Count; $i++) {
    $window = $knownWindows[$i]
    if ($window.RequestProcessId -ne $AosProcessId) {
        throw "Known window $($i + 1) does not belong to requested AOS PID $AosProcessId."
    }

    $queryStart = $window.Request.AddMilliseconds(-100)
    $queryEnd = $window.Release.AddMilliseconds(100)
    $startUtc = Convert-ToSystemTimeText -Time $queryStart
    $endUtc = Convert-ToSystemTimeText -Time $queryEnd
    $windowNumber = $i + 1

    Write-Host ("Querying AOS window {0}/3: {1} -> {2}" -f $windowNumber, $queryStart.ToString('HH:mm:ss.fff'), $queryEnd.ToString('HH:mm:ss.fff'))
    $windowXPath = "*[System[TimeCreated[@SystemTime>='$startUtc' and @SystemTime<='$endUtc'] and Execution[@ProcessID='$AosProcessId']]]"

    $windowEvents = @()
    try {
        $windowEvents = @(Get-WinEvent -Path $etl -FilterXPath $windowXPath -Oldest -ErrorAction Stop)
    }
    catch {
        if ($_.Exception.Message -notmatch 'No events were found') { throw }
    }

    $eventsReturned += $windowEvents.Count
    Write-Host "  events returned: $($windowEvents.Count)"

    foreach ($event in $windowEvents) {
        $xml = $event.ToXml()
        $providerKey = if ([string]::IsNullOrWhiteSpace($event.ProviderName)) { '<unnamed>' } else { [string]$event.ProviderName }
        if (-not $providerCounts.ContainsKey($providerKey)) { $providerCounts[$providerKey] = 0 }
        $providerCounts[$providerKey]++

        $message = ''
        try { $message = ([string]$event.FormatDescription()).Replace("`t", ' ').Replace("`r", ' ').Replace("`n", ' ') } catch {}
        $payload = (Get-NamedPayload -EventXml $xml).Replace("`t", ' ').Replace("`r", ' ').Replace("`n", ' ')

        $rows += [pscustomobject]@{
            Window = $windowNumber
            Request = $window.Request.ToString('o')
            Release = $window.Release.ToString('o')
            TimeCreated = $event.TimeCreated.ToString('o')
            Id = $event.Id
            Version = $event.Version
            Provider = $providerKey
            ProcessId = $event.ProcessId
            ThreadId = $event.ThreadId
            RecordId = $event.RecordId
            Payload = $payload
            Message = $message
        }
        $xmlEvents += $xml
    }
}

$knownWindows | ForEach-Object {
    "request=$($_.Request.ToString('o')) request_pid=$($_.RequestProcessId) release=$($_.Release.ToString('o')) release_pid=$($_.ReleaseProcessId)"
} | Out-File -LiteralPath (Join-Path $output 'AOS-CAMP-WINDOWS.txt') -Encoding utf8 -Width 8192

$rows | Export-Csv -LiteralPath (Join-Path $output 'aos-host-window-events.csv') -NoTypeInformation -Encoding utf8
@(
    '<?xml version="1.0" encoding="utf-8"?>'
    '<Events selection="known-AOS-host-CAMP-windows">'
    $xmlEvents
    '</Events>'
) | Out-File -LiteralPath (Join-Path $output 'aos-host-window-events.xml') -Encoding utf8 -Width 65535

$providerCounts.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    "$($_.Value)`t$($_.Key)"
} | Out-File -LiteralPath (Join-Path $output 'PROVIDER-COUNTS.txt') -Encoding utf8 -Width 8192

@(
    "generated_at=$((Get-Date).ToString('o'))"
    "source_trace=$etl"
    "source_trace_bytes=$($etlItem.Length)"
    "aos_process_id=$AosProcessId"
    "camp_token=$campToken"
    'known_trace=A14-Camera-Platform-Boot-PoFx-Trace-20260807-231205'
    'aos_camp_windows=3'
    "bounded_pid_events=$eventsReturned"
    "window_events_retained=$($rows.Count)"
    'query_strategy=three-known-time-bounded-pid-xpath'
    'discovery_passes=0'
    'operation=offline-decode-only'
    'process_control=false'
    'collector_sends_platform_ioctl=false'
    'devices_restarted=false'
    'camera_register_access=false'
    'direct_cpas_mmio=false'
) | Out-File -LiteralPath (Join-Path $output 'EXPORT-RESULT.txt') -Encoding utf8 -Width 8192

$zip = "$output.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -LiteralPath $output -DestinationPath $zip -CompressionLevel Optimal

Write-Host ''
Write-Host 'AOS CAMP windows:       3'
Write-Host "Bounded PID events:     $eventsReturned"
Write-Host "Window events retained: $($rows.Count)"
Write-Host "Archive:                $zip"
Write-Host 'Upload this small offline AOS-host known-window export ZIP.'
