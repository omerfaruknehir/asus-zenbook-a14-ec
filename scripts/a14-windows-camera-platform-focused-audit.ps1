#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputRoot = "$env:USERPROFILE\Desktop"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $OutputRoot "A14-Camera-Platform-Focused-Audit-$stamp"
$payload = Join-Path $output 'payload'
New-Item -ItemType Directory -Force -Path $output, $payload | Out-Null

function Save-Text {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )

    $path = Join-Path $output $Name
    try {
        & $Command 2>&1 | Out-File -LiteralPath $path -Encoding utf8 -Width 8192
    }
    catch {
        @(
            'collection_status=failed'
            "exception=$($_.Exception.GetType().FullName)"
            "message=$($_.Exception.Message)"
        ) | Out-File -LiteralPath $path -Encoding utf8 -Width 8192
    }
}

function Save-Json {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 10
    )

    $path = Join-Path $output $Name
    try {
        $Value | ConvertTo-Json -Depth $Depth |
            Out-File -LiteralPath $path -Encoding utf8 -Width 8192
    }
    catch {
        [pscustomobject]@{
            collection_status = 'failed'
            exception = $_.Exception.GetType().FullName
            message = $_.Exception.Message
        } | ConvertTo-Json |
            Out-File -LiteralPath $path -Encoding utf8 -Width 8192
    }
}

function Get-FileMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path
    $signature = Get-AuthenticodeSignature -FilePath $Path
    $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256

    [pscustomobject]@{
        name = $item.Name
        source_path = $item.FullName
        length = $item.Length
        sha256 = $hash.Hash
        signature_status = [string]$signature.Status
        signer_subject = if ($signature.SignerCertificate) {
            $signature.SignerCertificate.Subject
        } else {
            $null
        }
        file_version = $item.VersionInfo.FileVersion
        product_version = $item.VersionInfo.ProductVersion
        original_filename = $item.VersionInfo.OriginalFilename
        last_write_time_utc = $item.LastWriteTimeUtc
    }
}

function Write-OffsetStrings {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Destination,
        [int]$MinimumLength = 5
    )

    $bytes = [IO.File]::ReadAllBytes($Path)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $builder = New-Object Text.StringBuilder
    $start = 0

    for ($index = 0; $index -lt $bytes.Length; $index++) {
        $value = $bytes[$index]
        if ($value -ge 0x20 -and $value -le 0x7e) {
            if ($builder.Length -eq 0) { $start = $index }
            [void]$builder.Append([char]$value)
        }
        else {
            if ($builder.Length -ge $MinimumLength) {
                $lines.Add(('{0:X8}`tASCII`t{1}' -f $start, $builder.ToString()))
            }
            [void]$builder.Clear()
        }
    }
    if ($builder.Length -ge $MinimumLength) {
        $lines.Add(('{0:X8}`tASCII`t{1}' -f $start, $builder.ToString()))
    }

    [void]$builder.Clear()
    $start = 0
    for ($index = 0; $index -lt ($bytes.Length - 1); $index += 2) {
        $low = $bytes[$index]
        $high = $bytes[$index + 1]
        if ($high -eq 0 -and $low -ge 0x20 -and $low -le 0x7e) {
            if ($builder.Length -eq 0) { $start = $index }
            [void]$builder.Append([char]$low)
        }
        else {
            if ($builder.Length -ge $MinimumLength) {
                $lines.Add(('{0:X8}`tUTF16LE`t{1}' -f $start, $builder.ToString()))
            }
            [void]$builder.Clear()
        }
    }
    if ($builder.Length -ge $MinimumLength) {
        $lines.Add(('{0:X8}`tUTF16LE`t{1}' -f $start, $builder.ToString()))
    }

    $lines | Sort-Object |
        Out-File -LiteralPath $Destination -Encoding utf8 -Width 8192
}

Write-Host ('=' * 76)
Write-Host 'ASUS Zenbook A14 focused Windows camera-platform audit'
Write-Host ('=' * 76)
Write-Host "Output: $output"
Write-Host 'Read-only collection: no camera IOCTL, device restart, or hardware write.'

@(
    "generated_at=$((Get-Date).ToString('o'))"
    "computer_name=$env:COMPUTERNAME"
    "user_name=$env:USERNAME"
    "powershell_version=$($PSVersionTable.PSVersion)"
    'focused_payload_included=true'
    'hardware_writes=false'
    'camera_ioctls_sent=false'
    'devices_restarted=false'
) | Out-File -LiteralPath (Join-Path $output 'AUDIT-INFO.txt') -Encoding utf8

$repository = Join-Path $env:windir 'System32\DriverStore\FileRepository'
$platformPackage = Get-ChildItem -LiteralPath $repository -Directory \
    -Filter 'qccamplatform8380.inf_*' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$extensionPackage = Get-ChildItem -LiteralPath $repository -Directory \
    -Filter 'qccamplatform_ext8380.inf_*' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1

if (-not $platformPackage) {
    throw 'qccamplatform8380 DriverStore package was not found.'
}
if (-not $extensionPackage) {
    throw 'qccamplatform_ext8380 DriverStore package was not found.'
}

$selected = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
foreach ($name in @(
    'qccamplatform8380.sys',
    'qccamplatform8380.inf',
    'qccamplatform8380.cat',
    'com.qti.tuned.default.bin'
)) {
    $candidate = Join-Path $platformPackage.FullName $name
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $selected.Add((Get-Item -LiteralPath $candidate))
    }
}
foreach ($name in @(
    'qccamplatform_ext8380.inf',
    'qccamplatform_ext8380.cat',
    'CAMP_RES_QRD.bin',
    'CAMP_PERF_QRD.bin',
    'CAMP_PCFG_QRD.bin',
    'CAMP_PRLD_QRD.bin',
    'CAMP_RES_MTP.bin',
    'CAMP_PERF_MTP.bin',
    'CAMP_PCFG_MTP.bin',
    'CAMP_PCF1_MTP.bin'
)) {
    $candidate = Join-Path $extensionPackage.FullName $name
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $selected.Add((Get-Item -LiteralPath $candidate))
    }
}

$alwaysOnCandidates = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
foreach ($root in @(
    (Join-Path $env:windir 'System32'),
    $repository
)) {
    Get-ChildItem -LiteralPath $root -File -Recurse -Filter 'qcAlwaysOnSensing.dll' \
        -ErrorAction SilentlyContinue |
        ForEach-Object { $alwaysOnCandidates.Add($_) }
}
foreach ($candidate in $alwaysOnCandidates | Sort-Object FullName -Unique) {
    $selected.Add($candidate)
}

$metadata = New-Object 'System.Collections.Generic.List[object]'
$llvmReadObj = Get-Command llvm-readobj.exe -ErrorAction SilentlyContinue
$llvmObjdump = Get-Command llvm-objdump.exe -ErrorAction SilentlyContinue
$dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue

foreach ($source in $selected | Sort-Object FullName -Unique) {
    $destination = Join-Path $payload $source.Name
    Copy-Item -LiteralPath $source.FullName -Destination $destination -Force
    $metadata.Add((Get-FileMetadata -Path $source.FullName))

    Write-OffsetStrings -Path $source.FullName \
        -Destination (Join-Path $payload ($source.Name + '.offset-strings.txt'))

    if ($source.Extension -in @('.sys', '.dll')) {
        if ($llvmReadObj) {
            & $llvmReadObj.Source --file-headers --coff-imports --coff-exports \
                $source.FullName 2>&1 |
                Out-File -LiteralPath (Join-Path $payload ($source.Name + '.pe.txt')) \
                    -Encoding utf8 -Width 8192
        }
        elseif ($dumpbin) {
            & $dumpbin.Source /headers /imports /exports $source.FullName 2>&1 |
                Out-File -LiteralPath (Join-Path $payload ($source.Name + '.pe.txt')) \
                    -Encoding utf8 -Width 8192
        }

        if ($llvmObjdump) {
            & $llvmObjdump.Source --disassemble --print-imm-hex $source.FullName 2>&1 |
                Out-File -LiteralPath (Join-Path $payload ($source.Name + '.disassembly.txt')) \
                    -Encoding utf8 -Width 8192
        }
    }
}
Save-Json 'focused-file-metadata.json' $metadata 6

$pnpIds = @('QCOM0C32', 'QCOM0C17', 'QCOM0C2B', 'QCOM0C0C', 'QCOM0D06', 'QCOM0CCC')
$pnpDevices = @()
if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
    $pnpDevices = @(
        Get-PnpDevice | Where-Object {
            $instance = $_.InstanceId
            ($pnpIds | Where-Object { $instance -match $_ }).Count -gt 0
        } | Sort-Object InstanceId
    )
    Save-Json 'dependency-pnp-devices.json' $pnpDevices 8

    $records = New-Object 'System.Collections.Generic.List[object]'
    foreach ($device in $pnpDevices) {
        try {
            $records.Add([pscustomobject]@{
                instance_id = $device.InstanceId
                friendly_name = $device.FriendlyName
                class = $device.Class
                status = $device.Status
                properties = @(Get-PnpDeviceProperty -InstanceId $device.InstanceId \
                    -ErrorAction Stop)
            })
        }
        catch {
            $records.Add([pscustomobject]@{
                instance_id = $device.InstanceId
                collection_status = 'failed'
                message = $_.Exception.Message
            })
        }
    }
    Save-Json 'dependency-pnp-properties.json' $records 12
}

Save-Text 'dependency-pnputil.txt' {
    foreach ($device in $pnpDevices) {
        "===== $($device.InstanceId) ====="
        pnputil.exe /enum-devices /instanceid $device.InstanceId /properties /drivers
    }
}
Save-Text 'camera-platform-registry.txt' {
    reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\QCOM0C32' /s
    reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Services\qcCameraPlatform' /s
}
Save-Text 'camera-platform-etw-providers.txt' {
    logman.exe query providers |
        Select-String -Pattern 'camera|qcom|qualcomm|cpas|camnoc|aos|sensor|power' \
            -CaseSensitive:$false
}

$zip = "$output.zip"
if (Test-Path -LiteralPath $zip) {
    Remove-Item -LiteralPath $zip -Force
}
Compress-Archive -LiteralPath $output -DestinationPath $zip -CompressionLevel Optimal

Write-Host ''
Write-Host "Audit directory: $output"
Write-Host "Archive:         $zip"
Write-Host 'Focused payload complete. No hardware-control request was issued.'
