#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$TracePath,

    [int[]]$ProcessId = @(8288, 10252, 5560),

    [string]$OutputRoot = "$env:USERPROFILE\Desktop"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$kernelProcessName = 'Microsoft-Windows-Kernel-Process'
$kernelProcessGuid = [Guid]'22FB2CD6-0E7B-422B-A0C7-2FAD1FD0E716'
$working = Join-Path ([IO.Path]::GetTempPath()) ("A14-Boot-Process-Identity-{0}" -f ([Guid]::NewGuid().ToString('N')))
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
            Sort-Object Length -Descending |
            Select-Object -First 1
        if (-not $etl) { throw "No ETL file was found inside $($item.FullName)." }
        return $etl.FullName
    }

    if ($item.PSIsContainer) {
        $etl = Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Filter '*.etl' |
            Sort-Object Length -Descending |
            Select-Object -First 1
        if (-not $etl) { throw "No ETL file was found under $($item.FullName)." }
        return $etl.FullName
    }

    throw 'TracePath must point to a trace directory, ETL, or ZIP.'
}

function Get-NamedPayload {
    param([Parameter(Mandatory = $true)][string]$EventXml)

    $pairs = New-Object 'System.Collections.Generic.List[string]'
    try {
        [xml]$document = $EventXml
        $nodes = $document.SelectNodes('/*[local-name()="Event"]/*[local-name()="EventData"]/*[local-name()="Data"]')
        foreach ($node in @($nodes)) {
            $name = [string]$node.GetAttribute('Name')
            if ([string]::IsNullOrWhiteSpace($name)) { $name = 'Value' }
            $pairs.Add(("{0}={1}" -f $name, [string]$node.InnerText))
        }
    }
    catch {}
    return ($pairs -join ' | ')
}

function Get-ProviderIdentity {
    param([Parameter(Mandatory = $true)][string]$EventXml)
    try {
        [xml]$document = $EventXml
        $provider = $document.SelectSingleNode('/*[local-name()="Event"]/*[local-name()="System"]/*[local-name()="Provider"]')
        if ($null -eq $provider) { return '' }
        $name = [string]$provider.GetAttribute('Name')
        $guid = [string]$provider.GetAttribute('Guid')
        return "$name $guid"
    }
    catch { return '' }
}

function Test-TargetPidPayload {
    param(
        [Parameter(Mandatory = $true)][string]$EventXml,
        [Parameter(Mandatory = $true)][int[]]$Pids
    )

    foreach ($pidValue in $Pids) {
        $decimal = [string]$pidValue
        $hex = ('0x{0:x}' -f $pidValue)
        $hex8 = ('0x{0:x8}' -f $pidValue)
        if ($EventXml -match ('(?i)(>|=|\b)(' + [Regex]::Escape($decimal) + '|' + [Regex]::Escape($hex) + '|' + [Regex]::Escape($hex8) + ')(<|\b)')) {
            return $true
        }
    }
    return $false
}

New-Item -ItemType Directory -Force -Path $working | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $OutputRoot "A14-Boot-Process-Identity-Export-$stamp"
New-Item -ItemType Directory -Force -Path $output | Out-Null

try {
    $etl = Resolve-TraceEtl -InputPath $TracePath
    $etlItem = Get-Item -LiteralPath $etl

    Write-Host ('=' * 76)
    Write-Host 'ASUS Zenbook A14 offline boot process identity exporter'
    Write-Host ('=' * 76)
    Write-Host "Input ETL: $etl"
    Write-Host "Target PID(s): $($ProcessId -join ', ')"
    Write-Host 'Offline decode only: no process, device, PnP, IOCTL, sensor, or register operation.'
    Write-Host ''

    $predicateParts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($pidValue in $ProcessId) {
        $decimal = [string]$pidValue
        $hex = ('0x{0:x}' -f $pidValue)
        $hex8 = ('0x{0:x8}' -f $pidValue)
        $predicateParts.Add("Data='$decimal'")
        $predicateParts.Add("Data='$hex'")
        $predicateParts.Add("Data='$hex8'")
    }
    $xpath = "*[EventData[" + ($predicateParts -join ' or ') + ']]'

    $rows = New-Object 'System.Collections.Generic.List[object]'
    $xmlEvents = New-Object 'System.Collections.Generic.List[string]'
    $queryMode = 'payload-xpath'
    $events = @()

    try {
        $events = @(Get-WinEvent -Path $etl -FilterXPath $xpath -Oldest -ErrorAction Stop)
    }
    catch {
        $queryMode = 'provider-fallback'
        Write-Host 'Exact PID XPath query was unavailable; falling back to Kernel-Process provider scan.'
        try {
            $events = @(Get-WinEvent -FilterHashtable @{
                Path = $etl
                ProviderName = $kernelProcessName
            } -Oldest -ErrorAction Stop)
        }
        catch {
            $guidText = $kernelProcessGuid.ToString('B')
            $providerXPath = "*[System[Provider[@Guid='$guidText']]]"
            $events = @(Get-WinEvent -Path $etl -FilterXPath $providerXPath -Oldest -ErrorAction Stop)
        }
    }

    $scanned = 0L
    foreach ($event in $events) {
        $scanned++
        $xml = $event.ToXml()
        $providerIdentity = Get-ProviderIdentity -EventXml $xml

        $isKernelProcess = ($providerIdentity -match [Regex]::Escape($kernelProcessName)) -or
            ($providerIdentity -match [Regex]::Escape($kernelProcessGuid.ToString('D')))

        if (-not $isKernelProcess) { continue }
        if (-not (Test-TargetPidPayload -EventXml $xml -Pids $ProcessId)) { continue }

        $xmlEvents.Add($xml)
        $payload = Get-NamedPayload -EventXml $xml
        $message = ''
        try { $message = [string]$event.FormatDescription() } catch {}

        $rows.Add([pscustomobject]@{
            TimeCreated = $event.TimeCreated.ToString('o')
            Id = $event.Id
            Version = $event.Version
            ProcessId = $event.ProcessId
            ThreadId = $event.ThreadId
            RecordId = $event.RecordId
            Provider = $providerIdentity
            Payload = $payload
            Message = $message
        })
    }

    $csv = Join-Path $output 'target-process-events.csv'
    @($rows) | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding utf8

    @(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<Events selection="target-process-identity">'
        $xmlEvents
        '</Events>'
    ) | Out-File -LiteralPath (Join-Path $output 'target-process-events.xml') -Encoding utf8 -Width 65535

    $summary = New-Object 'System.Collections.Generic.List[string]'
    foreach ($pidValue in $ProcessId) {
        $matches = @($rows | Where-Object {
            $_.Payload -match ('(?i)(>|=|\b)(' + [Regex]::Escape([string]$pidValue) + '|' + [Regex]::Escape(('0x{0:x}' -f $pidValue)) + '|' + [Regex]::Escape(('0x{0:x8}' -f $pidValue)) + ')(<|\b)')
        })
        $summary.Add("PID $pidValue")
        $summary.Add("  matched_events=$($matches.Count)")
        foreach ($match in $matches | Select-Object -First 20) {
            $summary.Add("  $($match.TimeCreated) id=$($match.Id) payload=$($match.Payload)")
        }
        $summary.Add('')
    }
    $summary | Out-File -LiteralPath (Join-Path $output 'PROCESS-SUMMARY.txt') -Encoding utf8 -Width 8192

    @(
        "generated_at=$((Get-Date).ToString('o'))"
        "source_trace=$etl"
        "source_trace_bytes=$($etlItem.Length)"
        "target_pids=$($ProcessId -join ',')"
        "query_mode=$queryMode"
        "events_returned_by_query=$($events.Count)"
        "kernel_process_target_events=$($rows.Count)"
        "kernel_process_provider=$kernelProcessName"
        "kernel_process_guid=$($kernelProcessGuid.ToString('D'))"
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
    Write-Host "Query events returned:       $($events.Count)"
    Write-Host "Target process events kept:  $($rows.Count)"
    Write-Host "Archive:                     $zip"
    Write-Host 'Upload this small process-identity export ZIP.'
}
finally {
    if ($expandedDirectory -and (Test-Path -LiteralPath $expandedDirectory)) {
        Remove-Item -LiteralPath $working -Recurse -Force -ErrorAction SilentlyContinue
    }
}
