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
New-Item -ItemType Directory -Force -Path @($output, $payload) | Out-Null

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
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object]$Value,
        [int]$Depth = 10
    )

    $path = Join-Path $output $Name
    try {
        ConvertTo-Json -InputObject $Value -Depth $Depth |
            Out-File -LiteralPath $path -Encoding utf8 -Width 8192
    }
    catch {
        ConvertTo-Json -InputObject ([pscustomobject]@{
            collection_status = 'failed'
            exception = $_.Exception.GetType().FullName
            message = $_.Exception.Message
        }) | Out-File -LiteralPath $path -Encoding utf8 -Width 8192
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
        }
        else {
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
            if ($builder.Length -eq 0) {
                $start = $index
            }
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
            if ($builder.Length -eq 0) {
                $start = $index
            }
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

    if ($lines.Count -gt 0) {
        $lines | Sort-Object | Out-File -LiteralPath $Destination -Encoding utf8 -Width 8192
    }
    else {
        '' | Out-File -LiteralPath $Destination -Encoding utf8
    }
}

function Get-SelectedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$OutputName
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        [pscustomobject]@{
            source = Get-Item -LiteralPath $Path
            output_name = $OutputName
        }
    }
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
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
$extensionPackage = Get-ChildItem -LiteralPath $repository -Directory \
    -Filter 'qccamplatform_ext8380.inf_*' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1

if (-not $platformPackage) {
    throw 'qccamplatform8380 DriverStore package was not found.'
}
if (-not $extensionPackage) {
    throw 'qccamplatform_ext8380 DriverStore package was not found.'
}

$selected = @()
foreach ($name in @(
    'qccamplatform8380.sys',
    'qccamplatform8380.inf',
    'qccamplatform8380.cat',
    'com.qti.tuned.default.bin'
)) {
    $entry = Get-SelectedFile \
        -Path (Join-Path $platformPackage.FullName $name) \
        -OutputName $name
    if ($null -ne $entry) {
        $selected += $entry
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
    $entry = Get-SelectedFile \
        -Path (Join-Path $extensionPackage.FullName $name) \
        -OutputName $name
    if ($null -ne $entry) {
        $selected += $entry
    }
}

$alwaysOnCandidates = @()
$system32 = Join-Path $env:windir 'System32'
$alwaysOnCandidates += @(
    Get-ChildItem -LiteralPath $system32 -File \
        -Filter 'qcAlwaysOnSensing.dll' -ErrorAction SilentlyContinue
)
$alwaysOnCandidates += @(
    Get-ChildItem -LiteralPath $repository -File -Recurse \
        -Filter 'qcAlwaysOnSensing.dll' -ErrorAction SilentlyContinue
)
$alwaysOnIndex = 0
foreach ($candidate in @($alwaysOnCandidates | Sort-Object FullName -Unique)) {
    $alwaysOnIndex++
    $entry = Get-SelectedFile \
        -Path $candidate.FullName \
        -OutputName ("qcAlwaysOnSensing-{0}.dll" -f $alwaysOnIndex)
    if ($null -ne $entry) {
        $selected += $entry
    }
}

if ($selected.Count -eq 0) {
    throw 'No focused camera-platform files were selected.'
}

$metadata = @()
$llvmReadObj = Get-Command llvm-readobj.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1
$llvmObjdump = Get-Command llvm-objdump.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1
$dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1

foreach ($entry in @($selected | Sort-Object output_name -Unique)) {
    $source = $entry.source
    $outputName = [string]$entry.output_name
    $destination = Join-Path $payload $outputName
    Copy-Item -LiteralPath $source.FullName -Destination $destination -Force

    $fileMetadata = Get-FileMetadata -Path $source.FullName
    $fileMetadata | Add-Member \
        -NotePropertyName output_name \
        -NotePropertyValue $outputName
    $metadata += $fileMetadata

    if ($source.Extension -in @('.sys', '.dll', '.bin')) {
        Write-OffsetStrings \
            -Path $source.FullName \
            -Destination (Join-Path $payload ($outputName + '.offset-strings.txt'))
    }

    if ($source.Extension -in @('.sys', '.dll')) {
        $peOutput = Join-Path $payload ($outputName + '.pe.txt')
        if ($llvmReadObj) {
            & $llvmReadObj.Source \
                --file-headers --coff-imports --coff-exports \
                $source.FullName 2>&1 |
                Out-File -LiteralPath $peOutput -Encoding utf8 -Width 8192
        }
        elseif ($dumpbin) {
            & $dumpbin.Source /headers /imports /exports \
                $source.FullName 2>&1 |
                Out-File -LiteralPath $peOutput -Encoding utf8 -Width 8192
        }
        else {
            'Neither llvm-readobj.exe nor dumpbin.exe is installed.' |
                Out-File -LiteralPath $peOutput -Encoding utf8
        }

        if ($llvmObjdump) {
            & $llvmObjdump.Source --disassemble --print-imm-hex \
                $source.FullName 2>&1 |
                Out-File \
                    -LiteralPath (Join-Path $payload ($outputName + '.disassembly.txt')) \
                    -Encoding utf8 -Width 8192
        }
    }
}
Save-Json -Name 'focused-file-metadata.json' -Value @($metadata) -Depth 6

$pnpIds = @(
    'QCOM0C32',
    'QCOM0C17',
    'QCOM0C2B',
    'QCOM0C0C',
    'QCOM0D06',
    'QCOM0CCC'
)
$pnpDevices = @()
$pnpRecords = @()
if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
    $pnpDevices = @(
        Get-PnpDevice |
            Where-Object {
                $instance = $_.InstanceId
                @(
                    $pnpIds |
                        Where-Object { $instance -match [regex]::Escape($_) }
                ).Count -gt 0
            } |
            Sort-Object InstanceId
    )

    foreach ($device in $pnpDevices) {
        try {
            $properties = @(
                Get-PnpDeviceProperty \
                    -InstanceId $device.InstanceId \
                    -ErrorAction Stop
            )
            $pnpRecords += [pscustomobject]@{
                instance_id = $device.InstanceId
                friendly_name = $device.FriendlyName
                class = $device.Class
                status = $device.Status
                properties = $properties
            }
        }
        catch {
            $pnpRecords += [pscustomobject]@{
                instance_id = $device.InstanceId
                collection_status = 'failed'
                message = $_.Exception.Message
            }
        }
    }
}
Save-Json -Name 'dependency-pnp-devices.json' -Value @($pnpDevices) -Depth 8
Save-Json -Name 'dependency-pnp-properties.json' -Value @($pnpRecords) -Depth 12

Save-Text -Name 'dependency-pnputil.txt' -Command {
    if ($pnpDevices.Count -eq 0) {
        'No matching dependency devices were returned by Get-PnpDevice.'
    }
    foreach ($device in $pnpDevices) {
        "===== $($device.InstanceId) ====="
        pnputil.exe /enum-devices /instanceid $device.InstanceId /properties /drivers
    }
}
Save-Text -Name 'camera-platform-registry.txt' -Command {
    reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\QCOM0C32' /s
    reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Services\qcCameraPlatform' /s
}
Save-Text -Name 'camera-platform-etw-providers.txt' -Command {
    logman.exe query providers |
        Select-String \
            -Pattern 'camera|qcom|qualcomm|cpas|camnoc|aos|sensor|power' \
            -CaseSensitive:$false
}

$zip = "$output.zip"
if (Test-Path -LiteralPath $zip) {
    Remove-Item -LiteralPath $zip -Force
}
Compress-Archive \
    -LiteralPath $output \
    -DestinationPath $zip \
    -CompressionLevel Optimal

Write-Host ''
Write-Host "Audit directory: $output"
Write-Host "Archive:         $zip"
Write-Host 'Focused payload complete. No hardware-control request was issued.'
