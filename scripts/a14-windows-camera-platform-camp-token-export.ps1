#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$TracePath,

    [string]$OutputRoot = "$env:USERPROFILE\Desktop"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$providerName = 'Microsoft-Windows-Kernel-Power'
$providerGuid = '{331C3B3A-2005-44C2-AC5E-77220C37D6B4}'
$cameraPattern = '(?i)(\\_SB\.CAMP|QCOM0C32|qcCameraPlatform|Camera Platform Device)'
$working = Join-Path ([IO.Path]::GetTempPath()) ("A14-CAMP-Token-Export-{0}" -f ([Guid]::NewGuid().ToString('N')))
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

function Get-EventDataMap {
    param([Parameter(Mandatory = $true)][string]$EventXml)

    $map = @{}
    [xml]$document = $EventXml
    $nodes = $document.SelectNodes('/*[local-name()="Event"]/*[local-name()="EventData"]/*[local-name()="Data"]')
    foreach ($node in @($nodes)) {
        $name = [string]$node.GetAttribute('Name')
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if (-not $map.ContainsKey($name)) { $map[$name] = New-Object 'System.Collections.Generic.List[string]' }
        $map[$name].Add([string]$node.InnerText)
    }
    return $map
}

function Get-NamedPayload {
    param([Parameter(Mandatory = $true)][string]$EventXml)

    try {
        $map = Get-EventDataMap -EventXml $EventXml
        $pairs = New-Object 'System.Collections.Generic.List[string]'
        foreach ($key in $map.Keys) {
            foreach ($value in $map[$key]) { $pairs.Add("$key=$value") }
        }
        return ($pairs -join ' | ')
    }
    catch { return '' }
}

New-Item -ItemType Directory -Force -Path $working | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $OutputRoot "A14-CAMP-Token-Kernel-Power-Export-$stamp"
New-Item -ItemType Directory -Force -Path $output | Out-Null

try {
    $etl = Resolve-TraceEtl -InputPath $TracePath
    $etlItem = Get-Item -LiteralPath $etl

    Write-Host ('=' * 76)
    Write-Host 'ASUS Zenbook A14 targeted CAMP Kernel-Power exporter'
    Write-Host ('=' * 76)
    Write-Host "Input ETL: $etl"
    Write-Host "Output:    $output"
    Write-Host 'Offline decode only: no hardware, device, IOCTL, PnP, sensor, or register operation.'
    Write-Host ''
    Write-Host 'Pass 1/2: resolving the CAMP DeviceNode/Token from identity+rundown events...'

    $tokens = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $identityEvents = New-Object 'System.Collections.Generic.List[string]'
    $identityCount = 0L

    Get-WinEvent -FilterHashtable @{
        Path = $etl
        ProviderName = $providerName
        Id = @(136, 304, 320)
    } -Oldest -ErrorAction Stop | ForEach-Object {
        $xml = $_.ToXml()
        if ($xml -notmatch $cameraPattern) { return }
        $identityCount++
        $identityEvents.Add($xml)
        try {
            $map = Get-EventDataMap -EventXml $xml
            foreach ($name in @('Token','DeviceNode')) {
                if ($map.ContainsKey($name)) {
                    foreach ($value in $map[$name]) {
                        if ($value -match '^0x[0-9a-fA-F]+$') { [void]$tokens.Add($value) }
                    }
                }
            }
        }
        catch {}
    }

    if ($tokens.Count -eq 0) {
        throw 'No CAMP Token/DeviceNode value was resolved from Kernel-Power identity/rundown events.'
    }

    $tokenList = @($tokens | Sort-Object)
    $tokenList | Out-File -LiteralPath (Join-Path $output 'camp-tokens.txt') -Encoding ascii
    @(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<Events provider="Microsoft-Windows-Kernel-Power" selection="CAMP-identity">'
        $identityEvents
        '</Events>'
    ) | Out-File -LiteralPath (Join-Path $output 'camp-identity-events.xml') -Encoding utf8 -Width 65535

    Write-Host ("Resolved CAMP token(s): {0}" -f ($tokenList -join ', '))
    Write-Host 'Pass 2/2: asking Windows Event Log to return only events with those exact CAMP token value(s)...'

    $xmlPath = Join-Path $output 'camp-token-events.xml'
    $tsvPath = Join-Path $output 'camp-token-events.tsv'
    $queryPath = Join-Path $output 'camp-token-xpath-queries.txt'
    $utf8 = [Text.UTF8Encoding]::new($false)
    $xmlWriter = [IO.StreamWriter]::new($xmlPath, $false, $utf8)
    $tsvWriter = [IO.StreamWriter]::new($tsvPath, $false, $utf8)
    $xmlWriter.WriteLine('<?xml version="1.0" encoding="utf-8"?>')
    $xmlWriter.WriteLine('<Events provider="Microsoft-Windows-Kernel-Power" selection="CAMP-token-exact-XPath">')
    $tsvWriter.WriteLine("TimeCreated`tId`tVersion`tProcessId`tThreadId`tRecordId`tNamedPayload")

    $returned = 0L
    $matched = 0L
    $idCounts = @{}
    $firstMatch = $null
    $lastMatch = $null
    $seenRecordIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $queries = New-Object 'System.Collections.Generic.List[string]'

    try {
        foreach ($token in $tokenList) {
            # Query the ETL itself by exact EventData value. This avoids reading every
            # Kernel-Power event into PowerShell and avoids the unreliable nested Id
            # filter that failed on the boot trace.
            $xpath = "*[System[Provider[@Guid='$providerGuid']] and EventData[Data='$token']]"
            $queries.Add($xpath)
            Write-Host "  token $token"

            try {
                Get-WinEvent -Path $etl -FilterXPath $xpath -Oldest -ErrorAction Stop | ForEach-Object {
                    $event = $_
                    $returned++
                    $recordKey = [string]$event.RecordId
                    if ([string]::IsNullOrWhiteSpace($recordKey)) {
                        $recordKey = '{0}|{1}|{2}|{3}' -f $event.TimeCreated.ToString('o'), $event.Id, $event.ProcessId, $event.ThreadId
                    }
                    if (-not $seenRecordIds.Add($recordKey)) { return }

                    $xml = $event.ToXml()
                    # Keep an exact-value check after XPath as a defensive validation.
                    $map = Get-EventDataMap -EventXml $xml
                    $hasExactToken = $false
                    foreach ($values in $map.Values) {
                        foreach ($value in $values) {
                            if ($tokenList -contains $value) {
                                $hasExactToken = $true
                                break
                            }
                        }
                        if ($hasExactToken) { break }
                    }
                    if (-not $hasExactToken) { return }

                    $matched++
                    if ($null -eq $firstMatch) { $firstMatch = $event.TimeCreated }
                    $lastMatch = $event.TimeCreated
                    $idKey = [string]$event.Id
                    if (-not $idCounts.ContainsKey($idKey)) { $idCounts[$idKey] = 0L }
                    $idCounts[$idKey]++

                    $xmlWriter.WriteLine($xml)
                    $payload = (Get-NamedPayload -EventXml $xml).Replace("`t",' ').Replace("`r",' ').Replace("`n",' ')
                    $tsvWriter.WriteLine((@(
                        $event.TimeCreated.ToString('o')
                        $event.Id
                        $event.Version
                        $event.ProcessId
                        $event.ThreadId
                        $event.RecordId
                        $payload
                    ) -join "`t"))
                }
            }
            catch [System.Exception] {
                # Some Event Log query paths throw when a particular token has zero
                # matches. That is not fatal as long as at least one CAMP token query
                # returns data overall.
                if ($_.Exception.Message -notmatch '(?i)No events were found') { throw }
            }
        }
    }
    finally {
        $queries | Out-File -LiteralPath $queryPath -Encoding utf8 -Width 8192
        $xmlWriter.WriteLine('</Events>')
        $xmlWriter.Dispose()
        $tsvWriter.Dispose()
    }

    if ($matched -eq 0) {
        throw 'The exact CAMP token XPath query returned no Kernel-Power events. Keep the trace; the exporter needs another query-path fix, not another recording.'
    }

    $countLines = @($idCounts.GetEnumerator() | Sort-Object { [int]$_.Key } | ForEach-Object { "camp_event_id_$($_.Key)=$($_.Value)" })
    @(
        "generated_at=$((Get-Date).ToString('o'))"
        "source_trace=$etl"
        "source_trace_bytes=$($etlItem.Length)"
        "identity_camera_matches=$identityCount"
        "camp_tokens=$($tokenList -join ',')"
        "xpath_events_returned=$returned"
        "camp_token_events=$matched"
        "first_camp_event=$(if ($firstMatch) { $firstMatch.ToString('o') } else { '' })"
        "last_camp_event=$(if ($lastMatch) { $lastMatch.ToString('o') } else { '' })"
        $countLines
        'query_mode=exact-eventdata-token-xpath'
        'operation=offline-decode-only'
        'collector_sends_platform_ioctl=false'
        'devices_restarted=false'
        'camera_register_access=false'
        'direct_cpas_mmio=false'
    ) | Out-File -LiteralPath (Join-Path $output 'EXPORT-RESULT.txt') -Encoding utf8 -Width 8192

    $zip = "$output.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -LiteralPath $output -DestinationPath $zip -CompressionLevel Optimal

    Write-Host ''
    Write-Host "XPath events returned:  $returned"
    Write-Host "CAMP-token events:       $matched"
    Write-Host "Archive:                 $zip"
    Write-Host 'Upload this small targeted export ZIP.'
}
finally {
    if ($expandedDirectory -and (Test-Path -LiteralPath $expandedDirectory)) {
        Remove-Item -LiteralPath $working -Recurse -Force -ErrorAction SilentlyContinue
    }
}
