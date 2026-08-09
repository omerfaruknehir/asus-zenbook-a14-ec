#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$TracePath,

    [string]$OutputRoot = "$env:USERPROFILE\Desktop"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Offline decoder for the qcpep-rpmh ETW buffering-session snapshot.
# Reads only the supplied ETL/ZIP/directory. It does not touch the live ETW
# session, PnP, camera, platform power, CPAS, or SSC.

$providerGuid = [Guid]'2C89C855-6301-41F9-BF56-63416DFE9CA9'
$providerGuidBraced = '{2C89C855-6301-41F9-BF56-63416DFE9CA9}'
$cameraPattern = '(?i)(CAMP|CAMNOC|CPAS|CAM_CC|GCC_CAMERA|CCI|ICP|TITAN|MMCX|GDSC|BUSARB|ICBID_|GPIO|TLMM|RPMH|AOS|CAMERA)'
$working = Join-Path ([IO.Path]::GetTempPath()) ("A14-QCPEP-RPMH-Decode-{0}" -f ([Guid]::NewGuid().ToString('N')))
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

    throw 'TracePath must point to a qcpep RPMh trace ZIP, directory, or ETL file.'
}

function Convert-ToTsvField {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Replace("`t", ' ').Replace("`r", ' ').Replace("`n", ' ')
}

function Get-NamedPayload {
    param([Parameter(Mandatory = $true)][string]$EventXml)
    $pairs = New-Object 'System.Collections.Generic.List[string]'
    try {
        [xml]$document = $EventXml
        foreach ($containerName in @('EventData','UserData')) {
            $container = $document.SelectSingleNode(("/*[local-name()='Event']/*[local-name()='{0}']" -f $containerName))
            if ($null -eq $container) { continue }
            foreach ($node in @($container.SelectNodes('.//*'))) {
                if ($node.HasChildNodes -and @($node.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element }).Count -gt 0) {
                    continue
                }
                $name = [string]$node.LocalName
                try {
                    $attribute = $node.Attributes['Name']
                    if ($null -ne $attribute -and -not [string]::IsNullOrWhiteSpace([string]$attribute.Value)) {
                        $name = [string]$attribute.Value
                    }
                } catch { }
                $pairs.Add(("{0}={1}" -f $name, [string]$node.InnerText))
            }
        }
    } catch { return '' }
    return ($pairs -join ' | ')
}

function Get-RawBinaryPayload {
    param([Parameter(Mandatory = $true)][string]$EventXml)
    try {
        [xml]$document = $EventXml
        $binaryNodes = @($document.SelectNodes("//*[local-name()='Binary']"))
        if ($binaryNodes.Count -eq 0) { return '' }
        return (($binaryNodes | ForEach-Object { [string]$_.InnerText }) -join '')
    } catch { return '' }
}

function Get-ProviderEvents {
    param([Parameter(Mandatory = $true)][string]$EtlPath)

    $guidText = $providerGuid.ToString('B')
    $xpath = "*[System[Provider[@Guid='$guidText']]]"
    try {
        Get-WinEvent -Path $EtlPath -FilterXPath $xpath -Oldest -ErrorAction Stop
        return
    }
    catch {
        $xpathError = $_.Exception.Message
    }

    # Some ETL readers do not expose provider GUID filtering correctly for WPP
    # providers. Fall back to enumerating the supplied ETL only and selecting
    # the exact ProviderId in PowerShell. Still fully offline.
    try {
        Get-WinEvent -Path $EtlPath -Oldest -ErrorAction Stop | Where-Object {
            $_.ProviderId -eq $providerGuid
        }
        return
    }
    catch {
        throw "Could not decode provider $providerGuidBraced. XPath error: $xpathError Enumeration error: $($_.Exception.Message)"
    }
}

New-Item -ItemType Directory -Force -Path $working | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $OutputRoot "A14-QCPEP-RPMH-Decode-$stamp"
New-Item -ItemType Directory -Force -Path $output | Out-Null

try {
    $etl = Resolve-TraceEtl -InputPath $TracePath
    $etlItem = Get-Item -LiteralPath $etl

    Write-Host ('=' * 76)
    Write-Host 'ASUS Zenbook A14 offline qcpep RPMh ETL decoder'
    Write-Host ('=' * 76)
    Write-Host "Input ETL: $etl"
    Write-Host "Output:    $output"
    Write-Host 'Offline decode only; no ETW control or hardware/device operation.'
    Write-Host ''

    # Preserve any locally registered metadata, but do not require it: Qualcomm
    # may emit WPP/classic events whose payload is only recoverable from XML.
    try {
        $providerMetadata = Get-WinEvent -ListProvider * -ErrorAction Stop | Where-Object {
            $_.Id -eq $providerGuid
        } | Select-Object -First 1
        if ($null -ne $providerMetadata) {
            $providerMetadata | Format-List * |
                Out-File -LiteralPath (Join-Path $output 'provider-metadata.txt') -Encoding utf8 -Width 8192
            $metadataRows = foreach ($eventMetadata in @($providerMetadata.Events)) {
                [pscustomobject]@{
                    Id = [int]$eventMetadata.Id
                    Version = [int]$eventMetadata.Version
                    Description = [string]$eventMetadata.Description
                    Template = [string]$eventMetadata.Template
                }
            }
            $metadataRows | Sort-Object Id,Version |
                Export-Csv -LiteralPath (Join-Path $output 'provider-event-metadata.csv') -NoTypeInformation -Encoding utf8
        }
        else {
            'provider_metadata=not-registered' | Out-File -LiteralPath (Join-Path $output 'provider-metadata.txt') -Encoding utf8
        }
    }
    catch {
        @(
            'provider_metadata=unavailable'
            "message=$($_.Exception.Message)"
        ) | Out-File -LiteralPath (Join-Path $output 'provider-metadata.txt') -Encoding utf8 -Width 8192
    }

    $allXmlPath = Join-Path $output 'qcpep-rpmh-events.xml'
    $tablePath = Join-Path $output 'qcpep-rpmh-events.tsv'
    $cameraTablePath = Join-Path $output 'camera-matching-qcpep-rpmh-events.tsv'
    $binaryTablePath = Join-Path $output 'qcpep-rpmh-binary-payloads.tsv'

    $utf8 = [Text.UTF8Encoding]::new($false)
    $xmlWriter = [IO.StreamWriter]::new($allXmlPath, $false, $utf8)
    $tableWriter = [IO.StreamWriter]::new($tablePath, $false, $utf8)
    $cameraWriter = [IO.StreamWriter]::new($cameraTablePath, $false, $utf8)
    $binaryWriter = [IO.StreamWriter]::new($binaryTablePath, $false, $utf8)

    $xmlWriter.WriteLine('<?xml version="1.0" encoding="utf-8"?>')
    $xmlWriter.WriteLine(("<Events providerGuid='{0}'>" -f $providerGuidBraced))
    $header = "TimeCreated`tId`tVersion`tLevel`tOpcode`tTask`tKeywords`tProcessId`tThreadId`tRecordId`tNamedPayload`tMessage"
    $tableWriter.WriteLine($header)
    $cameraWriter.WriteLine($header)
    $binaryWriter.WriteLine("TimeCreated`tId`tVersion`tProcessId`tThreadId`tRecordId`tBinaryHex")

    $totalCount = 0L
    $cameraCount = 0L
    $binaryCount = 0L
    $eventIdCounts = @{}
    $firstTime = $null
    $lastTime = $null

    try {
        Get-ProviderEvents -EtlPath $etl | ForEach-Object {
            $event = $_
            $totalCount++
            if ($null -eq $firstTime) { $firstTime = $event.TimeCreated }
            $lastTime = $event.TimeCreated

            $idKey = "{0}/v{1}" -f $event.Id,$event.Version
            if (-not $eventIdCounts.ContainsKey($idKey)) { $eventIdCounts[$idKey] = 0L }
            $eventIdCounts[$idKey]++

            $xml = $event.ToXml()
            $message = ''
            try { $message = [string]$event.FormatDescription() } catch { }
            $payload = Get-NamedPayload -EventXml $xml
            $binary = Get-RawBinaryPayload -EventXml $xml

            $row = (@(
                Convert-ToTsvField -Value ($event.TimeCreated.ToString('o'))
                Convert-ToTsvField -Value $event.Id
                Convert-ToTsvField -Value $event.Version
                Convert-ToTsvField -Value $event.Level
                Convert-ToTsvField -Value $event.Opcode
                Convert-ToTsvField -Value $event.Task
                Convert-ToTsvField -Value $event.Keywords
                Convert-ToTsvField -Value $event.ProcessId
                Convert-ToTsvField -Value $event.ThreadId
                Convert-ToTsvField -Value $event.RecordId
                Convert-ToTsvField -Value $payload
                Convert-ToTsvField -Value $message
            ) -join "`t")

            $xmlWriter.WriteLine($xml)
            $tableWriter.WriteLine($row)

            if (-not [string]::IsNullOrWhiteSpace($binary)) {
                $binaryCount++
                $binaryWriter.WriteLine((@(
                    Convert-ToTsvField -Value ($event.TimeCreated.ToString('o'))
                    Convert-ToTsvField -Value $event.Id
                    Convert-ToTsvField -Value $event.Version
                    Convert-ToTsvField -Value $event.ProcessId
                    Convert-ToTsvField -Value $event.ThreadId
                    Convert-ToTsvField -Value $event.RecordId
                    Convert-ToTsvField -Value $binary
                ) -join "`t"))
            }

            $searchText = "$xml $payload $message"
            if ($searchText -match $cameraPattern) {
                $cameraCount++
                $cameraWriter.WriteLine($row)
            }
        }
    }
    finally {
        $xmlWriter.WriteLine('</Events>')
        $xmlWriter.Dispose()
        $tableWriter.Dispose()
        $cameraWriter.Dispose()
        $binaryWriter.Dispose()
    }

    # tracerpt is a second, independent offline decoder. It can retain classic
    # WPP/provider fields that Get-WinEvent leaves unformatted. Its failure is
    # non-fatal because the raw XML/binary export above remains authoritative.
    $tracerptStatus = 'not-run'
    $tracerpt = Get-Command tracerpt.exe -ErrorAction SilentlyContinue
    if ($null -ne $tracerpt) {
        $tracerptCsv = Join-Path $output 'tracerpt-qcpep-rpmh.csv'
        $tracerptSummary = Join-Path $output 'tracerpt-summary.txt'
        try {
            $traceOutput = @(& tracerpt.exe $etl -o $tracerptCsv -of CSV -summary $tracerptSummary -y 2>&1)
            $traceExit = $LASTEXITCODE
            $traceOutput | Out-File -LiteralPath (Join-Path $output 'tracerpt-output.txt') -Encoding utf8 -Width 8192
            if ($traceExit -eq 0) { $tracerptStatus = 'success' }
            else { $tracerptStatus = "exit-$traceExit" }
        }
        catch {
            $tracerptStatus = 'exception'
            $_ | Out-String | Out-File -LiteralPath (Join-Path $output 'tracerpt-output.txt') -Encoding utf8 -Width 8192
        }
    }

    $eventIdLines = @(
        $eventIdCounts.GetEnumerator() |
            Sort-Object Name |
            ForEach-Object { "event_$($_.Key.Replace('/','_'))=$($_.Value)" }
    )

    @(
        "generated_at=$((Get-Date).ToString('o'))"
        "source_trace=$etl"
        "source_trace_bytes=$($etlItem.Length)"
        "provider_guid=$providerGuidBraced"
        "event_count=$totalCount"
        "camera_text_match_count=$cameraCount"
        "binary_payload_event_count=$binaryCount"
        "first_event_time=$(if ($firstTime) { $firstTime.ToString('o') } else { '' })"
        "last_event_time=$(if ($lastTime) { $lastTime.ToString('o') } else { '' })"
        "tracerpt_status=$tracerptStatus"
        $eventIdLines
        'decoder=Get-WinEvent+tracerpt'
        'operation=offline-decode-only'
        'etw_control_query=false'
        'etw_control_flush=false'
        'etw_control_update=false'
        'etw_control_stop=false'
        'camera_ioctls_sent=false'
        'devices_restarted=false'
        'pnp_state_changed=false'
        'power_state_changed=false'
        'camera_register_writes=false'
        'direct_cpas_mmio=false'
        'ssc_contacted=false'
    ) | Out-File -LiteralPath (Join-Path $output 'DECODE-RESULT.txt') -Encoding utf8 -Width 8192

    if ($totalCount -eq 0) {
        Write-Host 'Warning: Get-WinEvent decoded zero matching provider events; inspect tracerpt output.' -ForegroundColor Yellow
    }

    $zip = "$output.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -LiteralPath $output -DestinationPath $zip -CompressionLevel Optimal

    Write-Host ''
    Write-Host "qcpep RPMh events:       $totalCount"
    Write-Host "Camera text matches:     $cameraCount"
    Write-Host "Binary payload events:   $binaryCount"
    Write-Host "tracerpt status:         $tracerptStatus"
    Write-Host "Export directory:        $output"
    Write-Host "Archive:                 $zip"
    Write-Host 'Upload the decode ZIP. No ETW or hardware state was changed.'
}
finally {
    if (Test-Path -LiteralPath $working) {
        Remove-Item -LiteralPath $working -Recurse -Force -ErrorAction SilentlyContinue
    }
}
