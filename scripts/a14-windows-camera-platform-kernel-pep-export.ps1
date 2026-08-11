#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$TracePath,

    [string]$OutputRoot = "$env:USERPROFILE\Desktop"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$providerName = 'Microsoft-Windows-Kernel-Pep'
$providerGuid = [Guid]'5412704E-B2E1-4624-8FFD-55777B8F7373'
$cameraPattern = '(?i)(QCOM0C32|ACPI\\QCOM0C32|\\_SB\.CAMP|CAMP|qcCameraPlatform|qccamplatform8380|CPAS|CAMNOC|cam_cc_|cci|icp|gdsc|mmcx|camera|aos|presence)'
$working = Join-Path ([IO.Path]::GetTempPath()) ("A14-Kernel-Pep-Export-{0}" -f ([Guid]::NewGuid().ToString('N')))
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

    throw 'TracePath must point to a trace ZIP, directory, or ETL file.'
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
        $eventData = $document.SelectSingleNode('/*[local-name()="Event"]/*[local-name()="EventData"]')
        if ($null -ne $eventData) {
            foreach ($node in @($eventData.ChildNodes)) {
                $name = ''
                try {
                    $attribute = $node.Attributes['Name']
                    if ($null -ne $attribute) { $name = [string]$attribute.Value }
                } catch {}
                if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$node.LocalName }
                $pairs.Add(("{0}={1}" -f $name, [string]$node.InnerText))
            }
        }
    } catch { return '' }
    return ($pairs -join ' | ')
}

function Get-ProviderEvents {
    param([Parameter(Mandatory = $true)][string]$EtlPath)

    try {
        Get-WinEvent -FilterHashtable @{ Path = $EtlPath; ProviderName = $providerName } -Oldest -ErrorAction Stop
        return
    } catch {
        $nameError = $_.Exception.Message
    }

    $guidText = $providerGuid.ToString('B')
    $xpath = "*[System[Provider[@Guid='$guidText']]]"
    try {
        Get-WinEvent -Path $EtlPath -FilterXPath $xpath -Oldest -ErrorAction Stop
        return
    } catch {
        throw "Could not query $providerName. Provider-name error: $nameError Provider-GUID error: $($_.Exception.Message)"
    }
}

New-Item -ItemType Directory -Force -Path $working | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $OutputRoot "A14-Camera-Platform-Kernel-Pep-Export-$stamp"
New-Item -ItemType Directory -Force -Path $output | Out-Null

try {
    $etl = Resolve-TraceEtl -InputPath $TracePath
    $etlItem = Get-Item -LiteralPath $etl

    Write-Host ('=' * 76)
    Write-Host 'ASUS Zenbook A14 offline Kernel-PEP exporter'
    Write-Host ('=' * 76)
    Write-Host "Input ETL: $etl"
    Write-Host "Output:    $output"
    Write-Host 'Offline decode only: no hardware, device, IOCTL, PnP, or register operation.'
    Write-Host ''

    $providerMetadata = Get-WinEvent -ListProvider $providerName -ErrorAction Stop
    $providerMetadata | Format-List * |
        Out-File -LiteralPath (Join-Path $output 'kernel-pep-provider-metadata.txt') -Encoding utf8 -Width 8192

    $metadataRows = foreach ($eventMetadata in @($providerMetadata.Events)) {
        [pscustomobject]@{
            Id = [int]$eventMetadata.Id
            Version = [int]$eventMetadata.Version
            Description = [string]$eventMetadata.Description
            Template = [string]$eventMetadata.Template
        }
    }
    $metadataRows | Sort-Object Id, Version |
        Export-Csv -LiteralPath (Join-Path $output 'kernel-pep-event-metadata.csv') -NoTypeInformation -Encoding utf8

    $allXmlPath = Join-Path $output 'kernel-pep-events.xml'
    $cameraXmlPath = Join-Path $output 'camera-matching-kernel-pep-events.xml'
    $tablePath = Join-Path $output 'kernel-pep-events.tsv'
    $cameraTablePath = Join-Path $output 'camera-matching-kernel-pep-events.tsv'

    $utf8 = [Text.UTF8Encoding]::new($false)
    $allWriter = [IO.StreamWriter]::new($allXmlPath, $false, $utf8)
    $cameraWriter = [IO.StreamWriter]::new($cameraXmlPath, $false, $utf8)
    $tableWriter = [IO.StreamWriter]::new($tablePath, $false, $utf8)
    $cameraTableWriter = [IO.StreamWriter]::new($cameraTablePath, $false, $utf8)

    $allWriter.WriteLine('<?xml version="1.0" encoding="utf-8"?>')
    $allWriter.WriteLine('<Events provider="Microsoft-Windows-Kernel-Pep">')
    $cameraWriter.WriteLine('<?xml version="1.0" encoding="utf-8"?>')
    $cameraWriter.WriteLine('<Events provider="Microsoft-Windows-Kernel-Pep" selection="camera-text-match">')
    $header = "TimeCreated`tId`tVersion`tProcessId`tThreadId`tRecordId`tNamedPayload`tMessage"
    $tableWriter.WriteLine($header)
    $cameraTableWriter.WriteLine($header)

    $totalCount = 0L
    $cameraCount = 0L
    $eventIdCounts = @{}
    $firstTime = $null
    $lastTime = $null

    try {
        Get-ProviderEvents -EtlPath $etl | ForEach-Object {
            $event = $_
            $totalCount++
            if ($null -eq $firstTime) { $firstTime = $event.TimeCreated }
            $lastTime = $event.TimeCreated

            $idKey = [string]$event.Id
            if (-not $eventIdCounts.ContainsKey($idKey)) { $eventIdCounts[$idKey] = 0L }
            $eventIdCounts[$idKey]++

            $xml = $event.ToXml()
            $message = ''
            try { $message = [string]$event.FormatDescription() } catch {}
            $payload = Get-NamedPayload -EventXml $xml
            $row = (@(
                Convert-ToTsvField -Value ($event.TimeCreated.ToString('o'))
                Convert-ToTsvField -Value $event.Id
                Convert-ToTsvField -Value $event.Version
                Convert-ToTsvField -Value $event.ProcessId
                Convert-ToTsvField -Value $event.ThreadId
                Convert-ToTsvField -Value $event.RecordId
                Convert-ToTsvField -Value $payload
                Convert-ToTsvField -Value $message
            ) -join "`t")

            $allWriter.WriteLine($xml)
            $tableWriter.WriteLine($row)

            $searchText = "$xml $message $payload"
            if ($searchText -match $cameraPattern) {
                $cameraCount++
                $cameraWriter.WriteLine($xml)
                $cameraTableWriter.WriteLine($row)
            }

            if (($totalCount % 50000) -eq 0) {
                Write-Host ("Scanned {0:N0} Kernel-PEP events; camera matches {1:N0}..." -f $totalCount, $cameraCount)
            }
        }
    }
    finally {
        $allWriter.WriteLine('</Events>')
        $cameraWriter.WriteLine('</Events>')
        $allWriter.Dispose()
        $cameraWriter.Dispose()
        $tableWriter.Dispose()
        $cameraTableWriter.Dispose()
    }

    if ($totalCount -eq 0) { throw "No $providerName events were decoded from the ETL." }

    $eventIdLines = @(
        $eventIdCounts.GetEnumerator() |
            Sort-Object { [int]$_.Key } |
            ForEach-Object { "kernel_pep_event_id_$($_.Key)=$($_.Value)" }
    )

    @(
        "generated_at=$((Get-Date).ToString('o'))"
        "source_trace=$etl"
        "source_trace_bytes=$($etlItem.Length)"
        "kernel_pep_provider=$providerName"
        "kernel_pep_guid=$($providerGuid.ToString('D'))"
        "kernel_pep_event_count=$totalCount"
        "camera_matching_kernel_pep_event_count=$cameraCount"
        "first_event_time=$(if ($firstTime) { $firstTime.ToString('o') } else { '' })"
        "last_event_time=$(if ($lastTime) { $lastTime.ToString('o') } else { '' })"
        $eventIdLines
        'decoder=Get-WinEvent'
        'operation=offline-decode-only'
        'camera_ioctls_sent=false'
        'devices_restarted=false'
        'pnp_state_changed=false'
        'camera_register_writes=false'
        'direct_cpas_mmio=false'
    ) | Out-File -LiteralPath (Join-Path $output 'EXPORT-RESULT.txt') -Encoding utf8 -Width 8192

    $zip = "$output.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -LiteralPath $output -DestinationPath $zip -CompressionLevel Optimal

    Write-Host ''
    Write-Host "Kernel-PEP events:      $totalCount"
    Write-Host "Camera text matches:    $cameraCount"
    Write-Host "Export directory:       $output"
    Write-Host "Archive:                $zip"
    Write-Host 'Upload the export ZIP. No new hardware trace was recorded.'
}
finally {
    if (Test-Path -LiteralPath $working) {
        Remove-Item -LiteralPath $working -Recurse -Force -ErrorAction SilentlyContinue
    }
}
