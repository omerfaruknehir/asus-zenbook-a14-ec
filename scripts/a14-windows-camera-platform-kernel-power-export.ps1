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
$providerGuid = [Guid]'331c3b3a-2005-44c2-ac5e-77220c37d6b4'
$metadataPattern = '(?i)(PoFx|component|idle state|performance state|device power|required|power framework)'
$cameraPattern = '(?i)(QCOM0C32|ACPI\\QCOM0C32|\\_SB\.CAMP|CAMP|qcCameraPlatform|qccamplatform8380|CPAS|CAMNOC|AlwaysOnSensing|AOS|HumanPresence|presence)'
$working = Join-Path ([IO.Path]::GetTempPath()) ("A14-Kernel-Power-Export-{0}" -f ([Guid]::NewGuid().ToString('N')))
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
        $etl = Get-ChildItem -LiteralPath $script:expandedDirectory -File -Recurse -Filter 'camera-platform-pofx.etl' |
            Select-Object -First 1
        if (-not $etl) {
            $etl = Get-ChildItem -LiteralPath $script:expandedDirectory -File -Recurse -Filter '*.etl' |
                Sort-Object Length -Descending |
                Select-Object -First 1
        }
        if (-not $etl) {
            throw "No ETL file was found inside $($item.FullName)."
        }
        return $etl.FullName
    }

    if ($item.PSIsContainer) {
        $etl = Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Filter 'camera-platform-pofx.etl' |
            Select-Object -First 1
        if (-not $etl) {
            $etl = Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Filter '*.etl' |
                Sort-Object Length -Descending |
                Select-Object -First 1
        }
        if (-not $etl) {
            throw "No ETL file was found under $($item.FullName)."
        }
        return $etl.FullName
    }

    throw 'TracePath must point to the trace ZIP, its directory, or an ETL file.'
}

function Convert-ToTsvField {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ''
    }

    return ([string]$Value).Replace("`t", ' ').Replace("`r", ' ').Replace("`n", ' ')
}

function Get-DisplayName {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ''
    }

    try {
        if ($Value.PSObject.Properties.Name -contains 'DisplayName') {
            return [string]$Value.DisplayName
        }
    }
    catch {
    }

    return [string]$Value
}

function Resolve-ProviderQueryMode {
    param([Parameter(Mandatory = $true)][string]$EtlPath)

    $filter = @{
        Path = $EtlPath
        ProviderName = $providerName
    }

    try {
        $null = Get-WinEvent -FilterHashtable $filter -Oldest -MaxEvents 1 -ErrorAction Stop
        return 'provider-name'
    }
    catch {
        $providerNameFailure = $_.Exception.Message
    }

    $guidText = $providerGuid.ToString('B')
    $xpath = "*[System[Provider[@Guid='$guidText']]]"
    try {
        $null = Get-WinEvent -Path $EtlPath -FilterXPath $xpath -Oldest -MaxEvents 1 -ErrorAction Stop
        return 'provider-guid'
    }
    catch {
        throw "Get-WinEvent could not query $providerName. Provider-name error: $providerNameFailure Provider-GUID error: $($_.Exception.Message)"
    }
}

function Get-ProviderEvents {
    param(
        [Parameter(Mandatory = $true)][string]$EtlPath,
        [Parameter(Mandatory = $true)][ValidateSet('provider-name', 'provider-guid')][string]$Mode
    )

    if ($Mode -eq 'provider-name') {
        Get-WinEvent -FilterHashtable @{
            Path = $EtlPath
            ProviderName = $providerName
        } -Oldest -ErrorAction Stop
        return
    }

    $guidText = $providerGuid.ToString('B')
    $xpath = "*[System[Provider[@Guid='$guidText']]]"
    Get-WinEvent -Path $EtlPath -FilterXPath $xpath -Oldest -ErrorAction Stop
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
                    $nameAttribute = $node.Attributes['Name']
                    if ($null -ne $nameAttribute) {
                        $name = [string]$nameAttribute.Value
                    }
                }
                catch {
                    $name = ''
                }
                if ([string]::IsNullOrWhiteSpace($name)) {
                    try { $name = [string]$node.LocalName } catch { $name = 'Value' }
                }
                $value = [string]$node.InnerText
                $pairs.Add(("{0}={1}" -f $name, $value))
            }
        }
    }
    catch {
        return ''
    }

    return ($pairs -join ' | ')
}

New-Item -ItemType Directory -Force -Path $working | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $OutputRoot "A14-Camera-Platform-Kernel-Power-Export-$stamp"
New-Item -ItemType Directory -Force -Path $output | Out-Null

try {
    $etl = Resolve-TraceEtl -InputPath $TracePath
    $etlItem = Get-Item -LiteralPath $etl

    Write-Host ('=' * 76)
    Write-Host 'ASUS Zenbook A14 offline Kernel-Power PoFx exporter'
    Write-Host ('=' * 76)
    Write-Host "Input ETL: $etl"
    Write-Host "Output:    $output"
    Write-Host 'This is offline trace decoding. It performs no hardware or device operation.'
    Write-Host ''

    $providerMetadata = Get-WinEvent -ListProvider $providerName -ErrorAction Stop
    $providerMetadata | Format-List * |
        Out-File -LiteralPath (Join-Path $output 'kernel-power-provider-metadata.txt') -Encoding utf8 -Width 8192

    $metadataRows = @()
    foreach ($eventMetadata in @($providerMetadata.Events)) {
        $metadataRows += [pscustomobject]@{
            Id = [int]$eventMetadata.Id
            Version = [int]$eventMetadata.Version
            Level = Get-DisplayName -Value $eventMetadata.Level
            Task = Get-DisplayName -Value $eventMetadata.Task
            Opcode = Get-DisplayName -Value $eventMetadata.Opcode
            Keywords = (@($eventMetadata.Keywords | ForEach-Object { Get-DisplayName -Value $_ }) -join ', ')
            Description = [string]$eventMetadata.Description
            Template = [string]$eventMetadata.Template
        }
    }
    $metadataRows |
        Sort-Object Id, Version |
        Export-Csv -LiteralPath (Join-Path $output 'kernel-power-event-metadata.csv') -NoTypeInformation -Encoding utf8

    $candidateIds = [Collections.Generic.HashSet[int]]::new()
    foreach ($id in 300..340) {
        [void]$candidateIds.Add($id)
    }
    foreach ($row in $metadataRows) {
        $metadataText = @($row.Task, $row.Opcode, $row.Description, $row.Template) -join ' '
        if ($metadataText -match $metadataPattern) {
            [void]$candidateIds.Add([int]$row.Id)
        }
    }

    @(
        $metadataRows |
            Where-Object { $candidateIds.Contains([int]$_.Id) } |
            Sort-Object Id, Version |
            Format-Table -AutoSize Id, Version, Task, Opcode, Description |
            Out-String -Width 8192
    ) | Out-File -LiteralPath (Join-Path $output 'candidate-event-metadata.txt') -Encoding utf8 -Width 8192

    $metadataById = @{}
    foreach ($row in $metadataRows) {
        $key = [string]$row.Id
        if (-not $metadataById.ContainsKey($key)) {
            $metadataById[$key] = $row
        }
    }

    $queryMode = Resolve-ProviderQueryMode -EtlPath $etl
    Write-Host "Kernel-Power query mode: $queryMode"
    Write-Host 'Scanning Microsoft-Windows-Kernel-Power events...'

    $candidateXmlPath = Join-Path $output 'pofx-candidate-events.xml'
    $cameraXmlPath = Join-Path $output 'camera-matching-kernel-power-events.xml'
    $tablePath = Join-Path $output 'pofx-candidate-events.tsv'

    $utf8 = [Text.UTF8Encoding]::new($false)
    $candidateWriter = [IO.StreamWriter]::new($candidateXmlPath, $false, $utf8)
    $cameraWriter = [IO.StreamWriter]::new($cameraXmlPath, $false, $utf8)
    $tableWriter = [IO.StreamWriter]::new($tablePath, $false, $utf8)

    $candidateWriter.WriteLine('<?xml version="1.0" encoding="utf-8"?>')
    $candidateWriter.WriteLine('<Events provider="Microsoft-Windows-Kernel-Power" selection="PoFx-candidate">')
    $cameraWriter.WriteLine('<?xml version="1.0" encoding="utf-8"?>')
    $cameraWriter.WriteLine('<Events provider="Microsoft-Windows-Kernel-Power" selection="camera-text-match">')
    $tableWriter.WriteLine("TimeCreated`tId`tVersion`tTask`tOpcode`tProcessId`tThreadId`tRecordId`tNamedPayload`tMessage")

    $totalCount = 0L
    $candidateCount = 0L
    $cameraMatchCount = 0L
    $eventIdCounts = @{}
    $candidateIdCounts = @{}
    $firstTime = $null
    $lastTime = $null

    try {
        Get-ProviderEvents -EtlPath $etl -Mode $queryMode | ForEach-Object {
            $event = $_
            $totalCount++
            if ($null -eq $firstTime) { $firstTime = $event.TimeCreated }
            $lastTime = $event.TimeCreated

            $idKey = [string]$event.Id
            if (-not $eventIdCounts.ContainsKey($idKey)) { $eventIdCounts[$idKey] = 0L }
            $eventIdCounts[$idKey]++

            $xml = $event.ToXml()
            $isCandidate = $candidateIds.Contains([int]$event.Id)
            $isCameraMatch = $xml -match $cameraPattern

            if ($isCameraMatch) {
                $cameraWriter.WriteLine($xml)
                $cameraMatchCount++
                $isCandidate = $true
            }

            if ($isCandidate) {
                $candidateCount++
                if (-not $candidateIdCounts.ContainsKey($idKey)) { $candidateIdCounts[$idKey] = 0L }
                $candidateIdCounts[$idKey]++

                $message = ''
                try { $message = [string]$event.FormatDescription() } catch { $message = '' }
                $namedPayload = Get-NamedPayload -EventXml $xml
                $metadata = if ($metadataById.ContainsKey($idKey)) { $metadataById[$idKey] } else { $null }
                $taskName = if ($null -ne $metadata) { [string]$metadata.Task } else { [string]$event.Task }
                $opcodeName = if ($null -ne $metadata) { [string]$metadata.Opcode } else { [string]$event.Opcode }

                $candidateWriter.WriteLine($xml)
                $tableWriter.WriteLine((@(
                    Convert-ToTsvField -Value ($event.TimeCreated.ToString('o'))
                    Convert-ToTsvField -Value $event.Id
                    Convert-ToTsvField -Value $event.Version
                    Convert-ToTsvField -Value $taskName
                    Convert-ToTsvField -Value $opcodeName
                    Convert-ToTsvField -Value $event.ProcessId
                    Convert-ToTsvField -Value $event.ThreadId
                    Convert-ToTsvField -Value $event.RecordId
                    Convert-ToTsvField -Value $namedPayload
                    Convert-ToTsvField -Value $message
                ) -join "`t"))
            }

            if (($totalCount % 50000) -eq 0) {
                Write-Host ("Scanned {0:N0} Kernel-Power events; retained {1:N0} candidates..." -f $totalCount, $candidateCount)
            }
        }
    }
    finally {
        $candidateWriter.WriteLine('</Events>')
        $candidateWriter.Dispose()
        $cameraWriter.WriteLine('</Events>')
        $cameraWriter.Dispose()
        $tableWriter.Dispose()
    }

    if ($totalCount -eq 0) {
        throw "No $providerName events were decoded from the ETL."
    }

    $eventIdLines = @(
        $eventIdCounts.GetEnumerator() |
            Sort-Object { [int]$_.Key } |
            ForEach-Object { "kernel_power_event_id_$($_.Key)=$($_.Value)" }
    )
    $candidateIdLines = @(
        $candidateIdCounts.GetEnumerator() |
            Sort-Object { [int]$_.Key } |
            ForEach-Object { "candidate_event_id_$($_.Key)=$($_.Value)" }
    )

    @(
        "generated_at=$((Get-Date).ToString('o'))"
        "source_trace=$etl"
        "source_trace_bytes=$($etlItem.Length)"
        "kernel_power_provider=$providerName"
        "kernel_power_guid=$($providerGuid.ToString('D'))"
        "query_mode=$queryMode"
        "kernel_power_event_count=$totalCount"
        "pofx_candidate_event_count=$candidateCount"
        "camera_matching_kernel_power_event_count=$cameraMatchCount"
        "first_event_time=$(if ($firstTime) { $firstTime.ToString('o') } else { '' })"
        "last_event_time=$(if ($lastTime) { $lastTime.ToString('o') } else { '' })"
        $eventIdLines
        $candidateIdLines
        'decoder=Get-WinEvent'
        'operation=offline-decode-only'
        'camera_ioctls_sent=false'
        'devices_restarted=false'
        'camera_register_writes=false'
    ) | Out-File -LiteralPath (Join-Path $output 'EXPORT-RESULT.txt') -Encoding utf8 -Width 8192

    $zip = "$output.zip"
    if (Test-Path -LiteralPath $zip) {
        Remove-Item -LiteralPath $zip -Force
    }
    Compress-Archive -LiteralPath $output -DestinationPath $zip -CompressionLevel Optimal

    Write-Host ''
    Write-Host "Kernel-Power events:    $totalCount"
    Write-Host "PoFx candidates:        $candidateCount"
    Write-Host "Camera text matches:    $cameraMatchCount"
    Write-Host "Export directory:       $output"
    Write-Host "Archive:                $zip"
    Write-Host 'Upload the export ZIP. No new hardware trace was recorded.'
}
finally {
    if (Test-Path -LiteralPath $working) {
        Remove-Item -LiteralPath $working -Recurse -Force -ErrorAction SilentlyContinue
    }
}
