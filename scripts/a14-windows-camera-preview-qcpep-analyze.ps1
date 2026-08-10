#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$BundlePath,

    [ValidateRange(1, 30)][int]$BaselineSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Offline-only marker correlation for an already-captured camera-preview/qcpep
# bundle. This script reads CORRELATION-MARKERS.txt and the raw qcpep WPP TSV.
# It performs no ETW/WPR control and no camera/hardware operation.

function Parse-Markers {
    param([Parameter(Mandatory = $true)][string]$Path)

    $result = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -notmatch '^([^=]+)=(.+)$') { continue }
        $name = $Matches[1].Trim()
        $text = $Matches[2].Trim()
        $dto = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AllowWhiteSpaces, [ref]$dto)) {
            $result[$name] = $dto.ToUniversalTime()
        }
    }
    return $result
}

function Require-Marker {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Markers,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if (-not $Markers.ContainsKey($Name)) {
        throw "Required correlation marker is missing: $Name"
    }
    return [DateTimeOffset]$Markers[$Name]
}

function Convert-HexAsciiPrefix {
    param([AllowEmptyString()][string]$Hex)
    if ([string]::IsNullOrWhiteSpace($Hex) -or $Hex.Length -lt 8) { return '' }
    try {
        $bytes = New-Object byte[] ([Math]::Min(16, [int]($Hex.Length / 2)))
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16)
        }
        $chars = foreach ($b in $bytes) {
            if ($b -ge 0x20 -and $b -le 0x7e) { [char]$b } elseif ($b -eq 0) { [char]0 } else { '.' }
        }
        return -join $chars
    }
    catch { return '' }
}

function Get-RowsInWindow {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][DateTimeOffset]$Start,
        [Parameter(Mandatory = $true)][DateTimeOffset]$End
    )
    return @($Rows | Where-Object {
        $_._Timestamp -ge $Start -and $_._Timestamp -lt $End
    })
}

function Add-SegmentSummary {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[object]]$Output,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][DateTimeOffset]$Start,
        [Parameter(Mandatory = $true)][DateTimeOffset]$End,
        [Parameter(Mandatory = $true)][object[]]$Rows
    )

    $segmentRows = @(Get-RowsInWindow -Rows $Rows -Start $Start -End $End)
    $icbRows = @($segmentRows | Where-Object { $_.UserDataHex -like '49434200*' })
    $rpmh = @($segmentRows | Where-Object { $_.ProviderGuid -ieq '4e3aeace-0120-3f12-a3b8-b0f231c22453' })
    $aux = @($segmentRows | Where-Object { $_.ProviderGuid -ieq 'b844d345-3584-316e-f5dd-a946e820b3eb' })
    [long]$userDataBytes = 0
    foreach ($segmentRow in $segmentRows) {
        $userDataBytes += [long]$segmentRow.UserDataLength
    }

    $Output.Add([pscustomobject]@{
        Segment = $Name
        StartUtc = $Start.ToString('o')
        EndUtc = $End.ToString('o')
        DurationMs = [Math]::Round(($End - $Start).TotalMilliseconds, 3)
        Events = $segmentRows.Count
        EventsPerSecond = if (($End - $Start).TotalSeconds -gt 0) { [Math]::Round($segmentRows.Count / ($End - $Start).TotalSeconds, 3) } else { 0 }
        IcbEvents = $icbRows.Count
        RpmhProviderEvents = $rpmh.Count
        AuxProviderEvents = $aux.Count
        UserDataBytes = $userDataBytes
    })
}

$bundle = (Resolve-Path -LiteralPath $BundlePath -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $bundle -PathType Container)) {
    throw 'BundlePath must point to the recovered correlation directory.'
}

$markersPath = Join-Path $bundle 'CORRELATION-MARKERS.txt'
if (-not (Test-Path -LiteralPath $markersPath -PathType Leaf)) {
    throw "Correlation markers not found: $markersPath"
}

$rawDirectory = Get-ChildItem -LiteralPath $bundle -Directory -Filter 'A14-QCPEP-RPMH-Raw-*' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
if ($null -eq $rawDirectory) {
    throw 'No recovered qcpep raw-dump directory was found in the bundle.'
}

$rawTsv = Join-Path $rawDirectory.FullName 'qcpep-wpp-raw-events.tsv'
if (-not (Test-Path -LiteralPath $rawTsv -PathType Leaf)) {
    throw "Raw qcpep TSV not found: $rawTsv"
}

$markers = Parse-Markers -Path $markersPath
$open = Require-Marker -Markers $markers -Name 'camera_open_window_started'
$visible = Require-Marker -Markers $markers -Name 'camera_preview_visible'
$holdComplete = Require-Marker -Markers $markers -Name 'camera_preview_hold_complete'
$closed = Require-Marker -Markers $markers -Name 'camera_preview_closed_confirmed'
$postClose = Require-Marker -Markers $markers -Name 'post_close_hold_complete'
$snapshotRequested = Require-Marker -Markers $markers -Name 'qcpep_snapshot_requested'

$rows = @(Import-Csv -LiteralPath $rawTsv -Delimiter "`t")
foreach ($row in $rows) {
    $dto = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($row.TimestampUtc, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dto)) {
        throw "Failed to parse qcpep TimestampUtc: $($row.TimestampUtc)"
    }
    $row | Add-Member -NotePropertyName '_Timestamp' -NotePropertyValue $dto.ToUniversalTime()
    $row.UserDataLength = [int]$row.UserDataLength
}

$analysis = Join-Path $bundle 'A14-Camera-Preview-QCPEP-Analysis'
if (Test-Path -LiteralPath $analysis) { Remove-Item -LiteralPath $analysis -Recurse -Force }
New-Item -ItemType Directory -Path $analysis | Out-Null

$segments = New-Object 'System.Collections.Generic.List[object]'
Add-SegmentSummary -Output $segments -Name 'baseline_before_open' -Start $open.AddSeconds(-$BaselineSeconds) -End $open -Rows $rows
Add-SegmentSummary -Output $segments -Name 'open_to_preview_visible' -Start $open -End $visible -Rows $rows
Add-SegmentSummary -Output $segments -Name 'preview_visible_to_hold_complete' -Start $visible -End $holdComplete -Rows $rows
Add-SegmentSummary -Output $segments -Name 'preview_hold_to_close_confirmed' -Start $holdComplete -End $closed -Rows $rows
Add-SegmentSummary -Output $segments -Name 'post_close_hold' -Start $closed -End $postClose -Rows $rows
Add-SegmentSummary -Output $segments -Name 'post_close_to_snapshot' -Start $postClose -End $snapshotRequested -Rows $rows
Add-SegmentSummary -Output $segments -Name 'entire_camera_open_window' -Start $open -End $closed -Rows $rows
$segments | Export-Csv -LiteralPath (Join-Path $analysis 'segment-summary.csv') -NoTypeInformation -Encoding utf8

# Detailed target window: baseline through snapshot request.
$targetStart = $open.AddSeconds(-$BaselineSeconds)
$targetEnd = $snapshotRequested
$targetRows = @(Get-RowsInWindow -Rows $rows -Start $targetStart -End $targetEnd)

$targetRows |
    Select-Object TimestampUtc,ProviderGuid,EventId,Version,Level,Opcode,Task,ProcessId,ThreadId,UserDataLength,UserDataHex |
    Export-Csv -LiteralPath (Join-Path $analysis 'target-window-events.csv') -NoTypeInformation -Encoding utf8

$targetRows |
    Group-Object ProviderGuid,EventId,Version,Opcode,Task,UserDataLength |
    Sort-Object Count -Descending |
    ForEach-Object {
        [pscustomobject]@{ Count = $_.Count; Signature = $_.Name }
    } | Export-Csv -LiteralPath (Join-Path $analysis 'target-window-signatures.csv') -NoTypeInformation -Encoding utf8

$targetRows |
    Group-Object UserDataHex |
    Sort-Object Count -Descending |
    Select-Object -First 100 |
    ForEach-Object {
        [pscustomobject]@{
            Count = $_.Count
            UserDataHex = $_.Name
            AsciiPrefix = Convert-HexAsciiPrefix -Hex $_.Name
        }
    } | Export-Csv -LiteralPath (Join-Path $analysis 'target-window-top-payloads.csv') -NoTypeInformation -Encoding utf8

# One-second bins make bursts visible without needing provider message metadata.
$binStart = $targetStart
$bins = New-Object 'System.Collections.Generic.List[object]'
while ($binStart -lt $targetEnd) {
    $binEnd = $binStart.AddSeconds(1)
    if ($binEnd -gt $targetEnd) { $binEnd = $targetEnd }
    $binRows = @(Get-RowsInWindow -Rows $rows -Start $binStart -End $binEnd)
    $bins.Add([pscustomobject]@{
        StartUtc = $binStart.ToString('o')
        EndUtc = $binEnd.ToString('o')
        Events = $binRows.Count
        IcbEvents = @($binRows | Where-Object { $_.UserDataHex -like '49434200*' }).Count
        RpmhProviderEvents = @($binRows | Where-Object { $_.ProviderGuid -ieq '4e3aeace-0120-3f12-a3b8-b0f231c22453' }).Count
        AuxProviderEvents = @($binRows | Where-Object { $_.ProviderGuid -ieq 'b844d345-3584-316e-f5dd-a946e820b3eb' }).Count
    })
    $binStart = $binEnd
}
$bins | Export-Csv -LiteralPath (Join-Path $analysis 'one-second-bins.csv') -NoTypeInformation -Encoding utf8

$baseline = $segments | Where-Object Segment -eq 'baseline_before_open'
$cameraWindow = $segments | Where-Object Segment -eq 'entire_camera_open_window'
$previewSegment = $segments | Where-Object Segment -eq 'preview_visible_to_hold_complete'
$postCloseSegment = $segments | Where-Object Segment -eq 'post_close_hold'

$traceFirst = if ($rows.Count -gt 0) { ($rows | Sort-Object _Timestamp | Select-Object -First 1)._Timestamp } else { $null }
$traceLast = if ($rows.Count -gt 0) { ($rows | Sort-Object _Timestamp -Descending | Select-Object -First 1)._Timestamp } else { $null }

@(
    "generated_at=$((Get-Date).ToString('o'))"
    "bundle=$bundle"
    "raw_tsv=$rawTsv"
    "raw_event_count=$($rows.Count)"
    "raw_first_utc=$(if ($traceFirst) { $traceFirst.ToString('o') } else { '' })"
    "raw_last_utc=$(if ($traceLast) { $traceLast.ToString('o') } else { '' })"
    "camera_open_window_started_utc=$($open.ToString('o'))"
    "camera_preview_visible_utc=$($visible.ToString('o'))"
    "camera_preview_hold_complete_utc=$($holdComplete.ToString('o'))"
    "camera_preview_closed_confirmed_utc=$($closed.ToString('o'))"
    "post_close_hold_complete_utc=$($postClose.ToString('o'))"
    "qcpep_snapshot_requested_utc=$($snapshotRequested.ToString('o'))"
    "baseline_events=$($baseline.Events)"
    "baseline_icb=$($baseline.IcbEvents)"
    "camera_open_window_events=$($cameraWindow.Events)"
    "camera_open_window_icb=$($cameraWindow.IcbEvents)"
    "preview_hold_events=$($previewSegment.Events)"
    "preview_hold_icb=$($previewSegment.IcbEvents)"
    "post_close_events=$($postCloseSegment.Events)"
    "post_close_icb=$($postCloseSegment.IcbEvents)"
    'operation=offline-marker-correlation-only'
    'wpr_control=false'
    'etw_control=false'
    'camera_control=false'
    'camera_ioctls=false'
    'devices_restarted=false'
    'direct_cpas_mmio=false'
    'ssc_contacted=false'
) | Out-File -LiteralPath (Join-Path $analysis 'ANALYSIS-RESULT.txt') -Encoding utf8 -Width 16384

$analysisZip = "$analysis.zip"
if (Test-Path -LiteralPath $analysisZip) { Remove-Item -LiteralPath $analysisZip -Force }
Compress-Archive -LiteralPath $analysis -DestinationPath $analysisZip -CompressionLevel Optimal

Write-Host ('=' * 76)
Write-Host 'ASUS Zenbook A14 offline camera-preview/qcpep marker analysis'
Write-Host ('=' * 76)
Write-Host "Raw qcpep events:       $($rows.Count)"
Write-Host "Baseline events / ICB:  $($baseline.Events) / $($baseline.IcbEvents)"
Write-Host "Camera window / ICB:    $($cameraWindow.Events) / $($cameraWindow.IcbEvents)"
Write-Host "Preview hold / ICB:     $($previewSegment.Events) / $($previewSegment.IcbEvents)"
Write-Host "Post-close / ICB:       $($postCloseSegment.Events) / $($postCloseSegment.IcbEvents)"
Write-Host "Analysis archive:       $analysisZip"
Write-Host 'Offline analysis only; no WPR/ETW control or hardware operation was performed.'
