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

$kernelPowerName = 'Microsoft-Windows-Kernel-Power'
$cameraPattern = '(?i)(\\_SB\.CAMP|QCOM0C32|qcCameraPlatform|Camera Platform Device)'
$working = Join-Path ([IO.Path]::GetTempPath()) ("A14-AOS-Host-Window-{0}" -f ([Guid]::NewGuid().ToString('N')))
$expandedDirectory = $null

function Resolve-TraceEtl {
    param([Parameter(Mandatory = $true)][string]$InputPath)

    $resolved = Resolve-Path -LiteralPath $InputPath -ErrorAction Stop
    $item = Get-Item -LiteralPath $resolved.Path

    if (-not $item.PSIsContainer -and $item.Extension -ieq '.etl') {
        return $item.FullName
    }
    if (-not $item.PSIsContainer -and $item.Extension -ieq '.zip') {
        $script:expandedDirectory = Join-Path $working 'expanded-trace'
        New-Item -ItemType Directory -Force -Path $script:expandedDirectory | Out-Null
        Expand-Archive -LiteralPath $item.FullName -DestinationPath $script:expandedDirectory -Force
        $etl = Get-ChildItem -LiteralPath $script:expandedDirectory -File -Recurse -Filter '*.etl' |
            Sort-Object Length -Descending | Select-Object -First 1
        if (-not $etl) { throw "No ETL file was found inside $($item.FullName)." }
        return $etl.FullName
    }
    if ($item.PSIsContainer) {
        $etl = Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Filter '*.etl' |
            Sort-Object Length -Descending | Select-Object -First 1
        if (-not $etl) { throw "No ETL file was found under $($item.FullName)." }
        return $etl.FullName
    }
    throw 'TracePath must point to a trace directory, ETL, or ZIP.'
}

function Get-EventDataMap {
    param([Parameter(Mandatory = $true)][string]$EventXml)
    $map = @{}
    [xml]$document = $EventXml
    $nodes = $document.SelectNodes('/*[local-name()="Event"]/*[local-name()="EventData"]/*[local-name()="Data"]')
    foreach ($node in @($nodes)) {
        $name = [string]$node.GetAttribute('Name')
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if (-not $map.ContainsKey($name)) { $map[$name] = @() }
        $map[$name] += [string]$node.InnerText
    }
    return $map
}

function Get-NamedPayload {
    param([Parameter(Mandatory = $true)][string]$EventXml)
    try {
        $map = Get-EventDataMap -EventXml $EventXml
        $pairs = @()
        foreach ($key in $map.Keys) {
            foreach ($value in @($map[$key])) { $pairs += ("$key=$value") }
        }
        return ($pairs -join ' | ')
    }
    catch { return '' }
}

function Get-ProviderIdentity {
    param([Parameter(Mandatory = $true)][string]$EventXml)
    try {
        [xml]$document = $EventXml
        $provider = $document.SelectSingleNode('/*[local-name()="Event"]/*[local-name()="System"]/*[local-name()="Provider"]')
        if ($null -eq $provider) { return '' }
        return (([string]$provider.GetAttribute('Name')) + ' ' + ([string]$provider.GetAttribute('Guid'))).Trim()
    }
    catch { return '' }
}

New-Item -ItemType Directory -Force -Path $working | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $OutputRoot "A14-AOS-Host-Window-Export-$stamp"
New-Item -ItemType Directory -Force -Path $output | Out-Null

try {
    $etl = Resolve-TraceEtl -InputPath $TracePath
    $etlItem = Get-Item -LiteralPath $etl

    Write-Host ('=' * 76)
    Write-Host 'ASUS Zenbook A14 offline AOS-host window exporter'
    Write-Host ('=' * 76)
    Write-Host "PowerShell host: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
    Write-Host "Input ETL:       $etl"
    Write-Host "AOS process PID: $AosProcessId"
    Write-Host 'Offline decode only: no process, device, PnP, IOCTL, sensor, or register operation.'
    Write-Host ''

    Write-Host 'Resolving CAMP token and PID-owned PowerRequired windows...'
    $tokens = @()
    Get-WinEvent -FilterHashtable @{
        Path = $etl
        ProviderName = $kernelPowerName
        Id = @(136, 304, 320)
    } -Oldest -ErrorAction Stop | ForEach-Object {
        $xml = $_.ToXml()
        if ($xml -notmatch $cameraPattern) { return }
        $map = Get-EventDataMap -EventXml $xml
        foreach ($name in @('Token','DeviceNode')) {
            if ($map.ContainsKey($name)) {
                foreach ($value in @($map[$name])) {
                    if ($value -match '^0x[0-9a-fA-F]+$' -and $tokens -notcontains $value) { $tokens += $value }
                }
            }
        }
    }
    if ($tokens.Count -eq 0) { throw 'Could not resolve the CAMP token from Kernel-Power identity/rundown events.' }
    $campToken = [string]$tokens[0]
    Write-Host "CAMP token:      $campToken"

    $tokenXPath = "*[EventData[Data='$campToken']]"
    $campEvents = @(Get-WinEvent -Path $etl -FilterXPath $tokenXPath -Oldest -ErrorAction Stop |
        Where-Object { $_.ProviderName -eq $kernelPowerName })

    $requests = @($campEvents | Where-Object {
        $_.ProcessId -eq $AosProcessId -and
        $_.Id -eq 317 -and
        $_.ToXml() -match 'PowerRequired[^<]*true|<Data Name="PowerRequired">true</Data>'
    })
    if ($requests.Count -eq 0) { throw "No CAMP PowerRequired=true request owned by PID $AosProcessId was found." }

    $windows = @()
    foreach ($request in $requests) {
        $release = $campEvents | Where-Object {
            $_.ProcessId -eq $AosProcessId -and
            $_.Id -eq 317 -and
            $_.TimeCreated -gt $request.TimeCreated -and
            $_.ToXml() -match 'PowerRequired[^<]*false|<Data Name="PowerRequired">false</Data>'
        } | Select-Object -First 1
        if ($null -eq $release) { continue }
        $windows += [pscustomobject]@{
            Request = $request.TimeCreated
            Release = $release.TimeCreated
            Start = $request.TimeCreated.AddMilliseconds(-100)
            End = $release.TimeCreated.AddMilliseconds(100)
        }
    }
    if ($windows.Count -eq 0) { throw 'No complete PID-owned CAMP PowerRequired window was found.' }

    $windows | ForEach-Object {
        "request=$($_.Request.ToString('o')) release=$($_.Release.ToString('o')) query_start=$($_.Start.ToString('o')) query_end=$($_.End.ToString('o'))"
    } | Out-File -LiteralPath (Join-Path $output 'AOS-CAMP-WINDOWS.txt') -Encoding utf8 -Width 8192

    Write-Host "Resolved $($windows.Count) AOS-host CAMP window(s)."
    Write-Host 'Querying ETL events whose System/Execution ProcessID is the AOS host...'

    $pidXPath = "*[System[Execution[@ProcessID='$AosProcessId']]]"
    $pidEvents = @(Get-WinEvent -Path $etl -FilterXPath $pidXPath -Oldest -ErrorAction Stop)
    Write-Host "PID-executed events returned: $($pidEvents.Count)"

    $rows = @()
    $xmlEvents = @()
    $providerCounts = @{}
    foreach ($event in $pidEvents) {
        $inside = $false
        $windowNumber = 0
        for ($i = 0; $i -lt $windows.Count; $i++) {
            if ($event.TimeCreated -ge $windows[$i].Start -and $event.TimeCreated -le $windows[$i].End) {
                $inside = $true
                $windowNumber = $i + 1
                break
            }
        }
        if (-not $inside) { continue }

        $xml = $event.ToXml()
        $provider = Get-ProviderIdentity -EventXml $xml
        $providerKey = if ([string]::IsNullOrWhiteSpace($event.ProviderName)) { $provider } else { [string]$event.ProviderName }
        if (-not $providerCounts.ContainsKey($providerKey)) { $providerCounts[$providerKey] = 0 }
        $providerCounts[$providerKey]++

        $payload = (Get-NamedPayload -EventXml $xml).Replace("`t", ' ').Replace("`r", ' ').Replace("`n", ' ')
        $message = ''
        try { $message = ([string]$event.FormatDescription()).Replace("`t", ' ').Replace("`r", ' ').Replace("`n", ' ') } catch {}
        $rows += [pscustomobject]@{
            Window = $windowNumber
            TimeCreated = $event.TimeCreated.ToString('o')
            Id = $event.Id
            Version = $event.Version
            Provider = $provider
            ProcessId = $event.ProcessId
            ThreadId = $event.ThreadId
            RecordId = $event.RecordId
            Payload = $payload
            Message = $message
        }
        $xmlEvents += $xml
    }

    $rows | Export-Csv -LiteralPath (Join-Path $output 'aos-host-window-events.csv') -NoTypeInformation -Encoding utf8
    @(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<Events selection="AOS-host-CAMP-windows">'
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
        "aos_camp_windows=$($windows.Count)"
        "pid_executed_events=$($pidEvents.Count)"
        "window_events_retained=$($rows.Count)"
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
    Write-Host "AOS CAMP windows:       $($windows.Count)"
    Write-Host "Window events retained: $($rows.Count)"
    Write-Host "Archive:                $zip"
    Write-Host 'Upload this small offline AOS-host window export ZIP.'
}
finally {
    if ($expandedDirectory -and (Test-Path -LiteralPath $expandedDirectory)) {
        Remove-Item -LiteralPath $working -Recurse -Force -ErrorAction SilentlyContinue
    }
}
