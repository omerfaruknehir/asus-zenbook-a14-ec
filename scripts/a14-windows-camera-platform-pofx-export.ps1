#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$TracePath,

    [string]$OutputRoot = "$env:USERPROFILE\Desktop",

    [switch]$KeepFullXml
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$kernelPepGuid = '5412704e-b2e1-4624-8ffd-55777b8f7373'
$matchPattern = '(?i)(Microsoft-Windows-Kernel-Pep|5412704e-b2e1-4624-8ffd-55777b8f7373|qccam|qcHumanPresence|QCOM0C32|CAMP|CPAS|CAMNOC|AlwaysOnSensing|AOS|presence.sensing)'

function Resolve-TraceEtl {
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)][string]$WorkingRoot
    )

    $resolved = Resolve-Path -LiteralPath $InputPath -ErrorAction Stop
    $item = Get-Item -LiteralPath $resolved.Path

    if (-not $item.PSIsContainer -and $item.Extension -ieq '.etl') {
        return [pscustomobject]@{
            Etl = $item.FullName
            ExpandedDirectory = $null
        }
    }

    if (-not $item.PSIsContainer -and $item.Extension -ieq '.zip') {
        $expanded = Join-Path $WorkingRoot 'expanded-trace'
        New-Item -ItemType Directory -Force -Path $expanded | Out-Null
        Expand-Archive -LiteralPath $item.FullName -DestinationPath $expanded -Force
        $etl = Get-ChildItem -LiteralPath $expanded -File -Recurse -Filter 'camera-platform-pofx.etl' |
            Select-Object -First 1
        if (-not $etl) {
            $etl = Get-ChildItem -LiteralPath $expanded -File -Recurse -Filter '*.etl' |
                Sort-Object Length -Descending |
                Select-Object -First 1
        }
        if (-not $etl) {
            throw "No ETL file was found inside $($item.FullName)."
        }
        return [pscustomobject]@{
            Etl = $etl.FullName
            ExpandedDirectory = $expanded
        }
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
        return [pscustomobject]@{
            Etl = $etl.FullName
            ExpandedDirectory = $null
        }
    }

    throw 'TracePath must point to the trace ZIP, its directory, or an ETL file.'
}

function Get-EventIdFromXml {
    param([Parameter(Mandatory = $true)][string]$Xml)

    foreach ($pattern in @(
        '(?is)<EventID[^>]*>\s*(\d+)\s*</EventID>',
        '(?is)EventID\s*=\s*["''](\d+)["'']',
        '(?is)Id\s*=\s*["''](\d+)["'']'
    )) {
        $match = [regex]::Match($Xml, $pattern)
        if ($match.Success) {
            return $match.Groups[1].Value
        }
    }

    return 'unknown'
}

$tracerpt = Get-Command tracerpt.exe -ErrorAction Stop
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $OutputRoot "A14-Camera-Platform-PoFx-Export-$stamp"
$working = Join-Path $output 'working'
New-Item -ItemType Directory -Force -Path @($output, $working) | Out-Null

$resolvedTrace = Resolve-TraceEtl -InputPath $TracePath -WorkingRoot $working
$etl = $resolvedTrace.Etl
$fullXml = Join-Path $working 'trace-full.xml'
$summary = Join-Path $output 'tracerpt-summary.txt'
$schema = Join-Path $output 'trace-schema.man'
$tracerptLog = Join-Path $output 'tracerpt-output.txt'

Write-Host ('=' * 76)
Write-Host 'ASUS Zenbook A14 offline Windows PoFx trace exporter'
Write-Host ('=' * 76)
Write-Host "Input ETL: $etl"
Write-Host "Output:    $output"
Write-Host 'This is offline trace decoding. It performs no hardware or device operation.'
Write-Host ''

$arguments = @(
    $etl,
    '-o', $fullXml,
    '-of', 'XML',
    '-lr',
    '-rts',
    '-summary', $summary,
    '-export', $schema,
    '-y'
)

$tracerptOutput = & $tracerpt.Source @arguments 2>&1
$tracerptStatus = $LASTEXITCODE
$tracerptOutput | Out-File -LiteralPath $tracerptLog -Encoding utf8 -Width 8192
if ($tracerptStatus -ne 0) {
    throw "tracerpt.exe failed with exit code $tracerptStatus. See $tracerptLog"
}
if (-not (Test-Path -LiteralPath $fullXml -PathType Leaf)) {
    throw 'tracerpt.exe returned success but did not create the XML dump.'
}

$pepEventsPath = Join-Path $output 'kernel-pep-events.xml'
$contextEventsPath = Join-Path $output 'camera-context-events.xml'
$pepWriter = New-Object IO.StreamWriter($pepEventsPath, $false, [Text.UTF8Encoding]::new($false))
$contextWriter = New-Object IO.StreamWriter($contextEventsPath, $false, [Text.UTF8Encoding]::new($false))
$pepWriter.WriteLine('<?xml version="1.0" encoding="utf-8"?>')
$pepWriter.WriteLine('<Events provider="Microsoft-Windows-Kernel-Pep" guid="{0}">' -f $kernelPepGuid)
$contextWriter.WriteLine('<?xml version="1.0" encoding="utf-8"?>')
$contextWriter.WriteLine('<Events filter="camera-platform-context">')

$settings = New-Object Xml.XmlReaderSettings
$settings.IgnoreComments = $true
$settings.IgnoreProcessingInstructions = $true
$settings.IgnoreWhitespace = $true
$reader = [Xml.XmlReader]::Create($fullXml, $settings)
$pepCount = 0L
$contextCount = 0L
$eventIdCounts = @{}

try {
    while ($reader.Read()) {
        if ($reader.NodeType -ne [Xml.XmlNodeType]::Element -or $reader.LocalName -ne 'Event') {
            continue
        }

        $eventXml = $reader.ReadOuterXml()
        if ([string]::IsNullOrWhiteSpace($eventXml)) {
            continue
        }

        $isPep = $eventXml -match '(?i)(Microsoft-Windows-Kernel-Pep|5412704e-b2e1-4624-8ffd-55777b8f7373)'
        $isContext = $eventXml -match $matchPattern

        if ($isPep) {
            $pepWriter.WriteLine($eventXml)
            $pepCount++
            $eventId = Get-EventIdFromXml -Xml $eventXml
            if (-not $eventIdCounts.ContainsKey($eventId)) {
                $eventIdCounts[$eventId] = 0L
            }
            $eventIdCounts[$eventId]++
        }

        if ($isContext) {
            $contextWriter.WriteLine($eventXml)
            $contextCount++
        }
    }
}
finally {
    $reader.Dispose()
    $pepWriter.WriteLine('</Events>')
    $pepWriter.Dispose()
    $contextWriter.WriteLine('</Events>')
    $contextWriter.Dispose()
}

$eventIdLines = @(
    $eventIdCounts.GetEnumerator() |
        Sort-Object {
            $parsed = 0
            if ([int]::TryParse([string]$_.Key, [ref]$parsed)) { $parsed } else { [int]::MaxValue }
        } |
        ForEach-Object { "kernel_pep_event_id_$($_.Key)=$($_.Value)" }
)

@(
    "generated_at=$((Get-Date).ToString('o'))"
    "source_trace=$etl"
    "source_trace_bytes=$((Get-Item -LiteralPath $etl).Length)"
    "tracerpt_exit_code=$tracerptStatus"
    "kernel_pep_guid=$kernelPepGuid"
    "kernel_pep_event_count=$pepCount"
    "camera_context_event_count=$contextCount"
    $eventIdLines
    "full_xml_retained=$([bool]$KeepFullXml)"
    'operation=offline-decode-only'
    'camera_ioctls_sent=false'
    'devices_restarted=false'
    'camera_register_writes=false'
) | Out-File -LiteralPath (Join-Path $output 'EXPORT-RESULT.txt') -Encoding utf8 -Width 8192

if ($KeepFullXml) {
    Move-Item -LiteralPath $fullXml -Destination (Join-Path $output 'trace-full.xml') -Force
}

if ($resolvedTrace.ExpandedDirectory -and (Test-Path -LiteralPath $resolvedTrace.ExpandedDirectory)) {
    Remove-Item -LiteralPath $resolvedTrace.ExpandedDirectory -Recurse -Force
}
if (Test-Path -LiteralPath $working) {
    Remove-Item -LiteralPath $working -Recurse -Force
}

$zip = "$output.zip"
if (Test-Path -LiteralPath $zip) {
    Remove-Item -LiteralPath $zip -Force
}
Compress-Archive -LiteralPath $output -DestinationPath $zip -CompressionLevel Optimal

Write-Host ''
Write-Host "Kernel-PEP events:      $pepCount"
Write-Host "Camera-context events:  $contextCount"
Write-Host "Export directory:       $output"
Write-Host "Archive:                $zip"
Write-Host 'Upload the export ZIP. No new hardware trace was recorded.'
