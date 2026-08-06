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
$providerGuid = [Guid]'5412704e-b2e1-4624-8ffd-55777b8f7373'
$cameraPattern = '(?i)(QCOM0C32|CAMP|CPAS|CAMNOC|qccam|qcHumanPresence|AlwaysOnSensing|AOS|presence.sensing|camera)'
$working = Join-Path ([IO.Path]::GetTempPath()) ("A14-PoFx-Export-{0}" -f ([Guid]::NewGuid().ToString('N')))
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

function Get-KernelPepEvents {
    param([Parameter(Mandatory = $true)][string]$EtlPath)

    try {
        Get-WinEvent -FilterHashtable @{
            Path = $EtlPath
            ProviderName = $providerName
        } -Oldest -ErrorAction Stop
        return
    }
    catch {
        $filterFailure = $_
    }

    $guidText = $providerGuid.ToString('B')
    $xpath = "*[System[Provider[@Guid='$guidText']]]"
    try {
        Get-WinEvent -Path $EtlPath -FilterXPath $xpath -Oldest -ErrorAction Stop
        return
    }
    catch {
        throw "Get-WinEvent could not filter the Kernel-PEP provider. FilterHashtable error: $($filterFailure.Exception.Message) XPath error: $($_.Exception.Message)"
    }
}

New-Item -ItemType Directory -Force -Path $working | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $OutputRoot "A14-Camera-Platform-PoFx-Export-$stamp"
New-Item -ItemType Directory -Force -Path $output | Out-Null

try {
    $etl = Resolve-TraceEtl -InputPath $TracePath
    $etlItem = Get-Item -LiteralPath $etl

    Write-Host ('=' * 76)
    Write-Host 'ASUS Zenbook A14 offline Windows PoFx trace exporter'
    Write-Host ('=' * 76)
    Write-Host "Input ETL: $etl"
    Write-Host "Output:    $output"
    Write-Host 'This is offline trace decoding. It performs no hardware or device operation.'
    Write-Host ''

    try {
        Get-WinEvent -ListProvider $providerName -ErrorAction Stop |
            Format-List * |
            Out-File -LiteralPath (Join-Path $output 'kernel-pep-provider-metadata.txt') -Encoding utf8 -Width 8192
    }
    catch {
        @(
            'provider_metadata_status=unavailable'
            "message=$($_.Exception.Message)"
        ) | Out-File -LiteralPath (Join-Path $output 'kernel-pep-provider-metadata.txt') -Encoding utf8 -Width 8192
    }

    $pepXmlPath = Join-Path $output 'kernel-pep-events.xml'
    $cameraXmlPath = Join-Path $output 'camera-matching-kernel-pep-events.xml'
    $tablePath = Join-Path $output 'kernel-pep-events.tsv'

    $utf8 = [Text.UTF8Encoding]::new($false)
    $pepWriter = [IO.StreamWriter]::new($pepXmlPath, $false, $utf8)
    $cameraWriter = [IO.StreamWriter]::new($cameraXmlPath, $false, $utf8)
    $tableWriter = [IO.StreamWriter]::new($tablePath, $false, $utf8)

    $pepCount = 0L
    $cameraMatchCount = 0L
    $eventIdCounts = @{}
    $firstTime = $null
    $lastTime = $null

    $pepWriter.WriteLine('<?xml version="1.0" encoding="utf-8"?>')
    $pepWriter.WriteLine('<Events provider="Microsoft-Windows-Kernel-Pep" guid="{5412704e-b2e1-4624-8ffd-55777b8f7373}">')
    $cameraWriter.WriteLine('<?xml version="1.0" encoding="utf-8"?>')
    $cameraWriter.WriteLine('<Events filter="camera-related-kernel-pep">')
    $tableWriter.WriteLine("TimeCreated`tId`tVersion`tLevel`tTask`tOpcode`tKeywords`tProcessId`tThreadId`tRecordId`tPayload`tMessage")

    try {
        Get-KernelPepEvents -EtlPath $etl | ForEach-Object {
            $event = $_
            $xml = $event.ToXml()
            $payloadValues = @($event.Properties | ForEach-Object {
                if ($null -eq $_.Value) { '' } else { [string]$_.Value }
            })
            $payload = $payloadValues -join ' | '
            $message = ''
            try {
                $message = $event.FormatDescription()
            }
            catch {
                $message = ''
            }

            if ($null -eq $firstTime) {
                $firstTime = $event.TimeCreated
            }
            $lastTime = $event.TimeCreated
            $pepCount++

            $idKey = [string]$event.Id
            if (-not $eventIdCounts.ContainsKey($idKey)) {
                $eventIdCounts[$idKey] = 0L
            }
            $eventIdCounts[$idKey]++

            $pepWriter.WriteLine($xml)
            $tableWriter.WriteLine((@(
                Convert-ToTsvField $event.TimeCreated.ToString('o')
                Convert-ToTsvField $event.Id
                Convert-ToTsvField $event.Version
                Convert-ToTsvField $event.Level
                Convert-ToTsvField $event.Task
                Convert-ToTsvField $event.Opcode
                Convert-ToTsvField $event.Keywords
                Convert-ToTsvField $event.ProcessId
                Convert-ToTsvField $event.ThreadId
                Convert-ToTsvField $event.RecordId
                Convert-ToTsvField $payload
                Convert-ToTsvField $message
            ) -join "`t"))

            if ($xml -match $cameraPattern -or $payload -match $cameraPattern -or $message -match $cameraPattern) {
                $cameraWriter.WriteLine($xml)
                $cameraMatchCount++
            }

            if (($pepCount % 10000) -eq 0) {
                Write-Host ("Decoded {0:N0} Kernel-PEP events..." -f $pepCount)
            }
        }
    }
    finally {
        $pepWriter.WriteLine('</Events>')
        $pepWriter.Dispose()
        $cameraWriter.WriteLine('</Events>')
        $cameraWriter.Dispose()
        $tableWriter.Dispose()
    }

    if ($pepCount -eq 0) {
        throw 'No Microsoft-Windows-Kernel-Pep events were decoded from the ETL.'
    }

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
        "kernel_pep_event_count=$pepCount"
        "camera_matching_kernel_pep_event_count=$cameraMatchCount"
        "first_event_time=$(if ($firstTime) { $firstTime.ToString('o') } else { '' })"
        "last_event_time=$(if ($lastTime) { $lastTime.ToString('o') } else { '' })"
        $eventIdLines
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
    Write-Host "Kernel-PEP events:      $pepCount"
    Write-Host "Camera-matching events: $cameraMatchCount"
    Write-Host "Export directory:       $output"
    Write-Host "Archive:                $zip"
    Write-Host 'Upload the export ZIP. No new hardware trace was recorded.'
}
finally {
    if (Test-Path -LiteralPath $working) {
        Remove-Item -LiteralPath $working -Recurse -Force -ErrorAction SilentlyContinue
    }
}
