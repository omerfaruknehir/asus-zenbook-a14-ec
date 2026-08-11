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
$working = Join-Path ([IO.Path]::GetTempPath()) ("A14-CAMP-Dependency-Export-{0}" -f ([Guid]::NewGuid().ToString('N')))
$expandedDirectory = $null

$targets = @(
    [pscustomobject]@{ Name='CAMP';     Pattern='(?i)(QCOM0C32|\\_SB\.CAMP|qcCameraPlatform|Camera Platform Device)' },
    [pscustomobject]@{ Name='AONC';     Pattern='(?i)(QCOM0D06|\\_SB\.AONC|Always On Sensing|AlwaysOnSensing)' },
    [pscustomobject]@{ Name='HPS';      Pattern='(?i)(QCOM06D9|Human Presence Sensor|HumanPresence)' },
    [pscustomobject]@{ Name='QCOM0C17'; Pattern='(?i)QCOM0C17' },
    [pscustomobject]@{ Name='QCOM0C2B'; Pattern='(?i)QCOM0C2B' },
    [pscustomobject]@{ Name='QCOM0C0C'; Pattern='(?i)QCOM0C0C' }
)

function Resolve-TraceEtl {
    param([Parameter(Mandatory = $true)][string]$InputPath)

    $resolved = Resolve-Path -LiteralPath $InputPath -ErrorAction Stop
    $item = Get-Item -LiteralPath $resolved.Path

    if (-not $item.PSIsContainer -and $item.Extension -ieq '.etl') {
        return [pscustomobject]@{ Etl=$item.FullName; SourceDirectory=$item.Directory.FullName }
    }

    if (-not $item.PSIsContainer -and $item.Extension -ieq '.zip') {
        $script:expandedDirectory = Join-Path $working 'expanded-trace'
        New-Item -ItemType Directory -Force -Path $script:expandedDirectory | Out-Null
        Expand-Archive -LiteralPath $item.FullName -DestinationPath $script:expandedDirectory -Force
        $etl = Get-ChildItem -LiteralPath $script:expandedDirectory -File -Recurse -Filter '*.etl' |
            Sort-Object Length -Descending |
            Select-Object -First 1
        if (-not $etl) { throw "No ETL file was found inside $($item.FullName)." }
        return [pscustomobject]@{ Etl=$etl.FullName; SourceDirectory=$etl.Directory.FullName }
    }

    if ($item.PSIsContainer) {
        $etl = Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Filter '*.etl' |
            Sort-Object Length -Descending |
            Select-Object -First 1
        if (-not $etl) { throw "No ETL file was found under $($item.FullName)." }
        return [pscustomobject]@{ Etl=$etl.FullName; SourceDirectory=$etl.Directory.FullName }
    }

    throw 'TracePath must point to a trace directory, ETL, or ZIP.'
}

function Get-EventDataMap {
    param([Parameter(Mandatory = $true)][string]$EventXml)

    $map = @{}
    [xml]$document = $EventXml
    $nodes = $document.SelectNodes('/*[local-name()="Event"]/*[local-name()="EventData"]/*')
    foreach ($node in @($nodes)) {
        $name = ''
        try { $name = [string]$node.GetAttribute('Name') } catch {}
        if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$node.LocalName }
        if (-not $map.ContainsKey($name)) { $map[$name] = New-Object 'System.Collections.Generic.List[string]' }
        $map[$name].Add([string]$node.InnerText)
    }
    return $map
}

function Get-Payload {
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

function Get-HexIdentifiers {
    param([Parameter(Mandatory = $true)][string]$EventXml)
    $result = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    try {
        $map = Get-EventDataMap -EventXml $EventXml
        foreach ($name in @('Token','DeviceNode')) {
            if (-not $map.ContainsKey($name)) { continue }
            foreach ($value in $map[$name]) {
                if ($value -match '^0x[0-9a-fA-F]+$') { [void]$result.Add($value) }
            }
        }
    }
    catch {}
    return @($result)
}

New-Item -ItemType Directory -Force -Path $working | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $OutputRoot "A14-CAMP-Dependency-Kernel-Power-Export-$stamp"
New-Item -ItemType Directory -Force -Path $output | Out-Null

try {
    $resolvedTrace = Resolve-TraceEtl -InputPath $TracePath
    $etl = [string]$resolvedTrace.Etl
    $sourceDirectory = [string]$resolvedTrace.SourceDirectory
    $etlItem = Get-Item -LiteralPath $etl

    Write-Host ('=' * 76)
    Write-Host 'ASUS Zenbook A14 targeted CAMP dependency Kernel-Power exporter'
    Write-Host ('=' * 76)
    Write-Host "Input ETL: $etl"
    Write-Host "Output:    $output"
    Write-Host 'Offline decode only: no hardware, device, IOCTL, PnP, sensor, or register operation.'
    Write-Host ''

    # Carry the small companion files produced by the boot collector. These can
    # map the user-mode WUDF host PID without touching any live device.
    foreach ($name in @(
        'ARMED.txt',
        'TRACE-INFO.txt',
        'TRACE-RESULT.txt',
        'always-on-sensing-host-postboot.txt',
        'qcom-camera-devices-postboot.txt',
        'wpr-status-before-stop.txt',
        'wpr-stopboot.txt'
    )) {
        $candidate = Join-Path $sourceDirectory $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            Copy-Item -LiteralPath $candidate -Destination (Join-Path $output $name) -Force
        }
    }

    Write-Host 'Pass 1/2: resolving runtime tokens/DeviceNodes for CAMP and known dependencies...'

    $tokenOwners = @{}
    $identityRows = New-Object 'System.Collections.Generic.List[object]'
    [int[]]$identityIds = @(136,302,303,304,320)

    Get-WinEvent -FilterHashtable @{
        Path = $etl
        ProviderName = $providerName
        Id = $identityIds
    } -Oldest -ErrorAction Stop | ForEach-Object {
        $event = $_
        $xml = $event.ToXml()
        foreach ($target in $targets) {
            if ($xml -notmatch $target.Pattern) { continue }
            $ids = @(Get-HexIdentifiers -EventXml $xml)
            foreach ($identifier in $ids) {
                if (-not $tokenOwners.ContainsKey($identifier)) {
                    $tokenOwners[$identifier] = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                }
                [void]$tokenOwners[$identifier].Add($target.Name)
            }
            $identityRows.Add([pscustomobject]@{
                Target=$target.Name
                TimeCreated=$event.TimeCreated.ToString('o')
                Id=$event.Id
                ProcessId=$event.ProcessId
                ThreadId=$event.ThreadId
                Identifiers=($ids -join ',')
                Payload=(Get-Payload -EventXml $xml)
            })
        }
    }

    $identityRows | Export-Csv -LiteralPath (Join-Path $output 'dependency-identities.csv') -NoTypeInformation -Encoding utf8

    $mapLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($target in $targets) {
        $owned = @(
            $tokenOwners.GetEnumerator() |
                Where-Object { $_.Value.Contains($target.Name) } |
                ForEach-Object { $_.Key } |
                Sort-Object
        )
        $mapLines.Add(("{0}={1}" -f $target.Name, ($owned -join ',')))
        Write-Host ("  {0,-9} {1}" -f $target.Name, $(if ($owned.Count) { $owned -join ', ' } else { '<not resolved>' }))
    }
    $mapLines | Out-File -LiteralPath (Join-Path $output 'dependency-token-map.txt') -Encoding ascii

    if ($tokenOwners.Count -eq 0) {
        throw 'No target dependency token/DeviceNode was resolved.'
    }

    Write-Host ''
    Write-Host 'Pass 2/2: scanning only RuntimeFx/PoFx event IDs and retaining resolved dependency tokens...'

    $allTokens = @($tokenOwners.Keys)
    $tokenRegex = '(?i)(' + (($allTokens | ForEach-Object { [Regex]::Escape($_) }) -join '|') + ')'
    [int[]]$candidateIds = @(
        136,302,303,304,306,307,308,309,310,311,312,313,314,315,317,
        320,321,322,323,324,325,326,327,328,330,331,604
    )

    $eventRows = New-Object 'System.Collections.Generic.List[object]'
    $candidateCount = 0L
    $matchedCount = 0L

    try {
        $events = Get-WinEvent -FilterHashtable @{
            Path = $etl
            ProviderName = $providerName
            Id = $candidateIds
        } -Oldest -ErrorAction Stop
    }
    catch {
        Write-Host 'Filtered RuntimeFx ID query was unavailable; falling back to provider-only offline scan.' -ForegroundColor Yellow
        $events = Get-WinEvent -FilterHashtable @{
            Path = $etl
            ProviderName = $providerName
        } -Oldest -ErrorAction Stop
    }

    $events | ForEach-Object {
        $event = $_
        $candidateCount++
        $xml = $event.ToXml()
        if ($xml -notmatch $tokenRegex) {
            if (($candidateCount % 50000) -eq 0) {
                Write-Host ("Scanned {0:N0} candidate events; retained {1:N0} dependency events..." -f $candidateCount,$matchedCount)
            }
            return
        }

        $matchingTokens = @($allTokens | Where-Object { $xml -match [Regex]::Escape($_) })
        foreach ($token in $matchingTokens) {
            $owners = @($tokenOwners[$token]) -join ','
            $eventRows.Add([pscustomobject]@{
                Target=$owners
                Token=$token
                TimeCreated=$event.TimeCreated.ToString('o')
                Id=$event.Id
                Version=$event.Version
                ProcessId=$event.ProcessId
                ThreadId=$event.ThreadId
                RecordId=$event.RecordId
                Payload=(Get-Payload -EventXml $xml)
            })
            $matchedCount++
        }

        if (($candidateCount % 50000) -eq 0) {
            Write-Host ("Scanned {0:N0} candidate events; retained {1:N0} dependency events..." -f $candidateCount,$matchedCount)
        }
    }

    $eventRows |
        Sort-Object TimeCreated, Target, Id |
        Export-Csv -LiteralPath (Join-Path $output 'dependency-token-events.csv') -NoTypeInformation -Encoding utf8

    $counts = @(
        $eventRows |
            Group-Object Target,Id |
            Sort-Object Name |
            ForEach-Object { "dependency_event_$($_.Name -replace ', ','_')=$($_.Count)" }
    )

    @(
        "generated_at=$((Get-Date).ToString('o'))"
        "source_trace=$etl"
        "source_trace_bytes=$($etlItem.Length)"
        "resolved_identifier_count=$($tokenOwners.Count)"
        "candidate_events_scanned=$candidateCount"
        "dependency_events_retained=$matchedCount"
        $mapLines
        $counts
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
    Write-Host "Candidate events scanned:   $candidateCount"
    Write-Host "Dependency events retained: $matchedCount"
    Write-Host "Archive:                    $zip"
    Write-Host 'Upload this small dependency export ZIP.'
}
finally {
    if ($expandedDirectory -and (Test-Path -LiteralPath $expandedDirectory)) {
        Remove-Item -LiteralPath $working -Recurse -Force -ErrorAction SilentlyContinue
    }
}
