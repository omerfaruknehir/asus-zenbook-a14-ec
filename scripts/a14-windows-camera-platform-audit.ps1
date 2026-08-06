#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputRoot = "$env:USERPROFILE\Desktop",
    [switch]$IncludeDriverBinaries
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $OutputRoot "A14-Camera-Platform-Audit-$stamp"
$files = Join-Path $output 'files'
New-Item -ItemType Directory -Force -Path $output, $files | Out-Null

function Write-Heading {
    param([Parameter(Mandatory = $true)][string]$Text)
    Write-Host ''
    Write-Host ('=' * 76)
    Write-Host $Text
    Write-Host ('=' * 76)
}

function Save-Command {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )

    $path = Join-Path $output $Name
    try {
        & $Command 2>&1 | Out-File -LiteralPath $path -Encoding utf8 -Width 4096
    }
    catch {
        @(
            "collection_status=failed"
            "exception=$($_.Exception.GetType().FullName)"
            "message=$($_.Exception.Message)"
        ) | Out-File -LiteralPath $path -Encoding utf8 -Width 4096
    }
}

function Save-Json {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 8
    )

    $path = Join-Path $output $Name
    try {
        $Value | ConvertTo-Json -Depth $Depth | Out-File -LiteralPath $path -Encoding utf8 -Width 4096
    }
    catch {
        @{
            collection_status = 'failed'
            exception = $_.Exception.GetType().FullName
            message = $_.Exception.Message
        } | ConvertTo-Json | Out-File -LiteralPath $path -Encoding utf8
    }
}

function Get-PrintableStrings {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MinimumLength = 5
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $results = New-Object 'System.Collections.Generic.List[string]'
    $builder = New-Object System.Text.StringBuilder

    foreach ($byte in $bytes) {
        if ($byte -ge 0x20 -and $byte -le 0x7e) {
            [void]$builder.Append([char]$byte)
        }
        else {
            if ($builder.Length -ge $MinimumLength) {
                $results.Add($builder.ToString())
            }
            [void]$builder.Clear()
        }
    }
    if ($builder.Length -ge $MinimumLength) {
        $results.Add($builder.ToString())
    }

    [void]$builder.Clear()
    for ($index = 0; $index -lt ($bytes.Length - 1); $index += 2) {
        $low = $bytes[$index]
        $high = $bytes[$index + 1]
        if ($high -eq 0 -and $low -ge 0x20 -and $low -le 0x7e) {
            [void]$builder.Append([char]$low)
        }
        else {
            if ($builder.Length -ge $MinimumLength) {
                $results.Add($builder.ToString())
            }
            [void]$builder.Clear()
        }
    }
    if ($builder.Length -ge $MinimumLength) {
        $results.Add($builder.ToString())
    }

    return $results | Sort-Object -Unique
}

function Get-DriverMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path
    $signature = Get-AuthenticodeSignature -FilePath $Path
    $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256

    [pscustomobject]@{
        path = $item.FullName
        length = $item.Length
        creation_time_utc = $item.CreationTimeUtc
        last_write_time_utc = $item.LastWriteTimeUtc
        sha256 = $hash.Hash
        signature_status = [string]$signature.Status
        signer_subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null }
        signer_issuer = if ($signature.SignerCertificate) { $signature.SignerCertificate.Issuer } else { $null }
        file_version = $item.VersionInfo.FileVersion
        product_version = $item.VersionInfo.ProductVersion
        company_name = $item.VersionInfo.CompanyName
        product_name = $item.VersionInfo.ProductName
        original_filename = $item.VersionInfo.OriginalFilename
    }
}

Write-Heading 'ASUS Zenbook A14 Windows camera-platform audit'
Write-Host "Output: $output"
Write-Host 'This collector performs read-only inventory. It sends no camera IOCTLs.'
Write-Host 'Review the ZIP before sharing; it can contain device IDs and driver paths.'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

@(
    "generated_at=$((Get-Date).ToString('o'))"
    "computer_name=$env:COMPUTERNAME"
    "user_name=$env:USERNAME"
    "powershell_version=$($PSVersionTable.PSVersion)"
    "is_administrator=$isAdmin"
    "include_driver_binaries=$([bool]$IncludeDriverBinaries)"
    'hardware_writes=false'
    'camera_ioctls_sent=false'
) | Out-File -LiteralPath (Join-Path $output 'AUDIT-INFO.txt') -Encoding utf8

Write-Heading 'Collecting operating-system and driver inventory'
Save-Json 'computer.json' ([pscustomobject]@{
    operating_system = Get-CimInstance Win32_OperatingSystem
    computer_system = Get-CimInstance Win32_ComputerSystem
    bios = Get-CimInstance Win32_BIOS
}) 6
Save-Command 'driverquery.txt' { driverquery.exe /v /fo list }
Save-Json 'camera-system-drivers.json' @(
    Get-CimInstance Win32_SystemDriver |
        Where-Object {
            $_.Name -match 'camera|camplatform|qccam|qcisp' -or
            $_.DisplayName -match 'camera|camplatform|qccam|qcisp' -or
            $_.PathName -match 'camera|camplatform|qccam|qcisp'
        } |
        Sort-Object Name
) 6

Write-Heading 'Collecting CAMP/QCOM0C32 and camera PnP properties'
$pnpMatches = @()
if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
    $pnpMatches = @(
        Get-PnpDevice |
            Where-Object {
                $_.InstanceId -match 'QCOM0C32|CAMERA|QCCAM' -or
                $_.FriendlyName -match 'camera platform|Qualcomm.*camera|CAMP'
            } |
            Sort-Object InstanceId
    )
    Save-Json 'camera-pnp-devices.json' $pnpMatches 8

    $propertyRecords = New-Object 'System.Collections.Generic.List[object]'
    foreach ($device in $pnpMatches) {
        try {
            $properties = @(Get-PnpDeviceProperty -InstanceId $device.InstanceId -ErrorAction Stop)
            $propertyRecords.Add([pscustomobject]@{
                instance_id = $device.InstanceId
                friendly_name = $device.FriendlyName
                class = $device.Class
                status = $device.Status
                properties = $properties
            })
        }
        catch {
            $propertyRecords.Add([pscustomobject]@{
                instance_id = $device.InstanceId
                collection_status = 'failed'
                message = $_.Exception.Message
            })
        }
    }
    Save-Json 'camera-pnp-properties.json' $propertyRecords 12
}
else {
    'Get-PnpDevice is unavailable.' | Out-File -LiteralPath (Join-Path $output 'camera-pnp-devices.txt') -Encoding utf8
}

Save-Command 'pnputil-qcom0c32.txt' {
    $instances = @($pnpMatches | Where-Object { $_.InstanceId -match 'QCOM0C32' })
    if ($instances.Count -eq 0) {
        'No QCOM0C32 PnP instance was returned by Get-PnpDevice.'
    }
    foreach ($device in $instances) {
        "===== $($device.InstanceId) ====="
        pnputil.exe /enum-devices /instanceid $device.InstanceId /properties /drivers
    }
}

Write-Heading 'Collecting camera-platform service and registry state'
Save-Command 'service-qcCameraPlatform.txt' { sc.exe qc qcCameraPlatform }
Save-Command 'service-qccamplatform.txt' { sc.exe qc qccamplatform }
Save-Command 'registry-camera-services.txt' {
    reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Services' /s /f qccamplatform
    reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Services' /s /f qcCameraPlatform
}
Save-Command 'registry-acpi-camp.txt' {
    reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Enum\ACPI' /s /f QCOM0C32
}
Save-Command 'registry-acpi-tables.txt' {
    reg.exe query 'HKLM\HARDWARE\ACPI' /s
}

Write-Heading 'Locating camera-platform driver packages'
$repository = Join-Path $env:windir 'System32\DriverStore\FileRepository'
$patterns = @(
    'qccamplatform*.inf_*',
    'qccamfrontsensor*.inf_*',
    'qccamisp*.inf_*',
    'qccamsecureisp*.inf_*',
    'surfacecamfrontsensor*.inf_*'
)
$packageDirectories = New-Object 'System.Collections.Generic.List[System.IO.DirectoryInfo]'
foreach ($pattern in $patterns) {
    Get-ChildItem -LiteralPath $repository -Directory -Filter $pattern -ErrorAction SilentlyContinue |
        ForEach-Object { $packageDirectories.Add($_) }
}
$packageDirectories = @($packageDirectories | Sort-Object FullName -Unique)
Save-Json 'driver-packages.json' @(
    $packageDirectories | ForEach-Object {
        [pscustomobject]@{
            path = $_.FullName
            files = @(Get-ChildItem -LiteralPath $_.FullName -File | Select-Object Name, Length, LastWriteTimeUtc)
        }
    }
) 8

$metadata = New-Object 'System.Collections.Generic.List[object]'
$relevantPattern = '(?i)AOS|CPAS|CAM_SEL|CAMNOC|XPU|SCM|SECURE|IOCTL|POWER|CLOCK|AHB|GDSC|RPMH|QCOM0C32|CAMP|HANDSHAKE|OWNERSHIP'
foreach ($directory in $packageDirectories) {
    $destination = Join-Path $files $directory.Name
    New-Item -ItemType Directory -Force -Path $destination | Out-Null

    Get-ChildItem -LiteralPath $directory.FullName -File -Filter '*.inf' |
        Copy-Item -Destination $destination -Force

    foreach ($binary in Get-ChildItem -LiteralPath $directory.FullName -File -Include '*.sys', '*.dll') {
        try {
            $metadata.Add((Get-DriverMetadata -Path $binary.FullName))

            $base = [IO.Path]::GetFileNameWithoutExtension($binary.Name)
            $allStringsPath = Join-Path $destination "$base.strings.txt"
            $relevantStringsPath = Join-Path $destination "$base.relevant-strings.txt"
            $strings = @(Get-PrintableStrings -Path $binary.FullName)
            $strings | Out-File -LiteralPath $allStringsPath -Encoding utf8 -Width 4096
            $strings | Where-Object { $_ -match $relevantPattern } |
                Out-File -LiteralPath $relevantStringsPath -Encoding utf8 -Width 4096

            if ($IncludeDriverBinaries) {
                Copy-Item -LiteralPath $binary.FullName -Destination $destination -Force
            }

            $dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
            $llvmReadObj = Get-Command llvm-readobj.exe -ErrorAction SilentlyContinue
            if ($dumpbin) {
                & $dumpbin.Source /headers /imports $binary.FullName 2>&1 |
                    Out-File -LiteralPath (Join-Path $destination "$base.pe.txt") -Encoding utf8 -Width 4096
            }
            elseif ($llvmReadObj) {
                & $llvmReadObj.Source --file-headers --coff-imports $binary.FullName 2>&1 |
                    Out-File -LiteralPath (Join-Path $destination "$base.pe.txt") -Encoding utf8 -Width 4096
            }
            else {
                'Neither dumpbin.exe nor llvm-readobj.exe is installed.' |
                    Out-File -LiteralPath (Join-Path $destination "$base.pe.txt") -Encoding utf8
            }
        }
        catch {
            [pscustomobject]@{
                path = $binary.FullName
                collection_status = 'failed'
                message = $_.Exception.Message
            } | ConvertTo-Json |
                Out-File -LiteralPath (Join-Path $destination "$($binary.Name).error.json") -Encoding utf8
        }
    }
}
Save-Json 'driver-file-metadata.json' $metadata 6

Write-Heading 'Collecting ETW and event-log provider inventory'
Save-Command 'etw-providers.txt' { logman.exe query providers }
Save-Command 'etw-camera-qcom-providers.txt' {
    logman.exe query providers |
        Select-String -Pattern 'camera|qcom|qualcomm|cpas|camnoc|aos|sensor' -CaseSensitive:$false
}
Save-Command 'event-log-channels.txt' {
    wevtutil.exe el |
        Select-String -Pattern 'camera|qcom|qualcomm|sensor|device' -CaseSensitive:$false
}

Write-Heading 'Creating archive'
$zip = "$output.zip"
if (Test-Path -LiteralPath $zip) {
    Remove-Item -LiteralPath $zip -Force
}
Compress-Archive -LiteralPath $output -DestinationPath $zip -CompressionLevel Optimal

Write-Host ''
Write-Host "Audit directory: $output"
Write-Host "Archive:         $zip"
Write-Host 'Collection complete. No camera IOCTL or hardware write was issued.'
