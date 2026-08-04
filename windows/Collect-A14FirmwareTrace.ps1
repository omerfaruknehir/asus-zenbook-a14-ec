param(
    [switch]$NoProcmonDownload
)

$ErrorActionPreference = "Continue"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    $argumentList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($NoProcmonDownload) {
        $argumentList += " -NoProcmonDownload"
    }
    Start-Process -FilePath "powershell.exe" -ArgumentList $argumentList -Verb RunAs
    exit
}

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$Desktop = [Environment]::GetFolderPath("Desktop")
$OutputRoot = Join-Path $Desktop "A14-Firmware-Trace-$Timestamp"
$InventoryDir = Join-Path $OutputRoot "inventory"
$StateDir = Join-Path $OutputRoot "states"
$TraceDir = Join-Path $OutputRoot "traces"
$DriverDir = Join-Path $OutputRoot "asus-driver-packages"
$BinaryDir = Join-Path $OutputRoot "asus-binaries"
$AcpiDir = Join-Path $OutputRoot "acpi-tables"
$EventDir = Join-Path $OutputRoot "event-logs"

foreach ($Dir in @(
    $OutputRoot, $InventoryDir, $StateDir, $TraceDir,
    $DriverDir, $BinaryDir, $AcpiDir, $EventDir
)) {
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
}

$TranscriptPath = Join-Path $OutputRoot "collector-transcript.txt"
Start-Transcript -Path $TranscriptPath -Force | Out-Null
$CollectionStart = Get-Date
$MarkerId = 100

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 76) -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ("=" * 76) -ForegroundColor Cyan
}

function Write-Marker {
    param([string]$Message)
    $script:MarkerId++
    $Stamp = Get-Date -Format "o"
    "$Stamp`t$Message" | Add-Content -Path (Join-Path $TraceDir "markers.tsv")
    try {
        & eventcreate.exe /T INFORMATION /ID $script:MarkerId /L APPLICATION `
            /SO A14FirmwareTrace /D $Message 2>&1 | Out-Null
    } catch {
    }
}

function Invoke-TextCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$OutputPath
    )
    try {
        & $FilePath @Arguments 2>&1 | Out-File -FilePath $OutputPath -Width 500 -Encoding utf8
    } catch {
        "FAILED: $($_.Exception.Message)" | Out-File -FilePath $OutputPath -Encoding utf8
    }
}

function Resolve-BinaryPath {
    param([string]$RawPath)

    if ([string]::IsNullOrWhiteSpace($RawPath)) {
        return $null
    }

    $Expanded = [Environment]::ExpandEnvironmentVariables($RawPath.Trim())
    if ($Expanded.StartsWith("\SystemRoot\", [StringComparison]::OrdinalIgnoreCase)) {
        $Expanded = Join-Path $env:SystemRoot $Expanded.Substring(12)
    }

    if ($Expanded.StartsWith('"')) {
        $ClosingQuote = $Expanded.IndexOf('"', 1)
        if ($ClosingQuote -gt 1) {
            return $Expanded.Substring(1, $ClosingQuote - 1)
        }
    }

    $Match = [regex]::Match(
        $Expanded,
        '^(.*?\.(?:exe|sys|dll))(?=\s|$)',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($Match.Success) {
        return $Match.Groups[1].Value.Trim('"')
    }

    return $Expanded.Trim('"')
}

function Get-AsusServicesAndDrivers {
    $Pattern = 'ASUS|ATK|ROG|MyASUS|System Control Interface|Hotkey'

    $Services = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match $Pattern -or
            $_.DisplayName -match $Pattern -or
            $_.PathName -match $Pattern
        }

    $SystemDrivers = Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match $Pattern -or
            $_.DisplayName -match $Pattern -or
            $_.PathName -match $Pattern
        }

    [PSCustomObject]@{
        Services = @($Services)
        SystemDrivers = @($SystemDrivers)
    }
}

function Save-AsusBinaries {
    param($ServiceData)

    $Rows = @()
    $Items = @($ServiceData.Services) + @($ServiceData.SystemDrivers)

    foreach ($Item in $Items) {
        $Resolved = Resolve-BinaryPath $Item.PathName
        if (-not $Resolved -or -not (Test-Path -LiteralPath $Resolved)) {
            $Rows += [PSCustomObject]@{
                Name = $Item.Name
                DisplayName = $Item.DisplayName
                OriginalPath = $Item.PathName
                ResolvedPath = $Resolved
                CopiedPath = $null
                SHA256 = $null
                SignatureStatus = $null
                Signer = $null
            }
            continue
        }

        $SafeName = ($Item.Name -replace '[^A-Za-z0-9._-]', '_')
        $Destination = Join-Path $BinaryDir "$SafeName-$(Split-Path $Resolved -Leaf)"
        try {
            Copy-Item -LiteralPath $Resolved -Destination $Destination -Force
            $Hash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
            $Signature = Get-AuthenticodeSignature -FilePath $Destination
            $Rows += [PSCustomObject]@{
                Name = $Item.Name
                DisplayName = $Item.DisplayName
                OriginalPath = $Item.PathName
                ResolvedPath = $Resolved
                CopiedPath = $Destination
                SHA256 = $Hash
                SignatureStatus = $Signature.Status
                Signer = if ($Signature.SignerCertificate) {
                    $Signature.SignerCertificate.Subject
                } else {
                    $null
                }
            }
        } catch {
            $Rows += [PSCustomObject]@{
                Name = $Item.Name
                DisplayName = $Item.DisplayName
                OriginalPath = $Item.PathName
                ResolvedPath = $Resolved
                CopiedPath = $null
                SHA256 = $null
                SignatureStatus = "Copy failed"
                Signer = $_.Exception.Message
            }
        }
    }

    $Rows | Export-Csv -Path (Join-Path $InventoryDir "asus-binary-manifest.csv") `
        -NoTypeInformation -Encoding utf8
}

function Export-AsusDriverPackages {
    $Pattern = 'ASUS|ATK|ROG|System Control Interface|Hotkey'
    $SignedDrivers = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Manufacturer -match $Pattern -or
            $_.DriverProviderName -match $Pattern -or
            $_.DeviceName -match $Pattern -or
            $_.Description -match $Pattern
        }

    $SignedDrivers |
        Select-Object DeviceName, Description, Manufacturer, DriverProviderName,
            DriverVersion, DriverDate, InfName, DeviceID, DriverName |
        Export-Csv -Path (Join-Path $InventoryDir "asus-pnp-signed-drivers.csv") `
            -NoTypeInformation -Encoding utf8

    $Log = Join-Path $InventoryDir "pnputil-export-driver.txt"
    foreach ($Inf in @($SignedDrivers.InfName | Where-Object { $_ } | Sort-Object -Unique)) {
        "Exporting $Inf" | Add-Content $Log
        try {
            & pnputil.exe /export-driver $Inf $DriverDir 2>&1 | Add-Content $Log
        } catch {
            "FAILED: $($_.Exception.Message)" | Add-Content $Log
        }
    }
}

function Save-RegistrySnapshot {
    param(
        [string]$Destination,
        [string]$Label
    )

    $RegistryDir = Join-Path $Destination "registry"
    New-Item -ItemType Directory -Path $RegistryDir -Force | Out-Null

    $Queries = [ordered]@{
        "hklm-software-asus" = "HKLM\SOFTWARE\ASUS"
        "hklm-software-wow6432-asus" = "HKLM\SOFTWARE\WOW6432Node\ASUS"
        "hkcu-software-asus" = "HKCU\SOFTWARE\ASUS"
        "hklm-software-microsoft-input" = "HKLM\SOFTWARE\Microsoft\Input"
        "hkcu-software-microsoft-input" = "HKCU\SOFTWARE\Microsoft\Input"
    }

    foreach ($Name in $Queries.Keys) {
        Invoke-TextCommand -FilePath "reg.exe" `
            -Arguments @("query", $Queries[$Name], "/s") `
            -OutputPath (Join-Path $RegistryDir "$Name.txt")
    }

    $ServiceKeys = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PSChildName -match 'ASUS|ATK|ROG|Hotkey|MyASUS|ControlInterface'
        }

    foreach ($Key in $ServiceKeys) {
        $SafeName = $Key.PSChildName -replace '[^A-Za-z0-9._-]', '_'
        $RegPath = "HKLM\SYSTEM\CurrentControlSet\Services\$($Key.PSChildName)"
        try {
            & reg.exe export $RegPath (Join-Path $RegistryDir "service-$SafeName.reg") /y `
                2>&1 | Out-Null
        } catch {
        }
    }

    "$((Get-Date).ToString('o'))`t$Label" |
        Out-File -Path (Join-Path $Destination "snapshot-time.txt") -Encoding utf8
}

function Save-DeviceSnapshot {
    param([string]$Destination)

    $Pattern = 'ASUS|ATK|0B05|0220|System Control Interface|Hotkey|Keyboard|Camera|Microphone'
    try {
        $Devices = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FriendlyName -match $Pattern -or
                $_.InstanceId -match $Pattern -or
                $_.Class -match 'Keyboard|HIDClass|Camera|AudioEndpoint|MEDIA|System'
            }

        $Devices |
            Select-Object Status, Class, FriendlyName, InstanceId, Problem, ConfigManagerErrorCode |
            Export-Csv -Path (Join-Path $Destination "pnp-devices.csv") `
                -NoTypeInformation -Encoding utf8

        $Properties = foreach ($Device in $Devices) {
            try {
                Get-PnpDeviceProperty -InstanceId $Device.InstanceId -ErrorAction Stop |
                    Select-Object @{Name="InstanceId";Expression={$Device.InstanceId}},
                        KeyName, Type, Data
            } catch {
                [PSCustomObject]@{
                    InstanceId = $Device.InstanceId
                    KeyName = "ERROR"
                    Type = ""
                    Data = $_.Exception.Message
                }
            }
        }

        $Properties |
            ConvertTo-Json -Depth 6 |
            Out-File -Path (Join-Path $Destination "pnp-device-properties.json") `
                -Width 500 -Encoding utf8
    } catch {
        "FAILED: $($_.Exception.Message)" |
            Out-File -Path (Join-Path $Destination "pnp-devices-error.txt") -Encoding utf8
    }
}

function Save-State {
    param([string]$Label)

    $SafeLabel = $Label -replace '[^A-Za-z0-9._-]', '_'
    $Destination = Join-Path $StateDir $SafeLabel
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    Write-Marker "Snapshot: $Label"
    Save-RegistrySnapshot -Destination $Destination -Label $Label
    Save-DeviceSnapshot -Destination $Destination

    Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessName -match 'ASUS|MyASUS|ROG|ATK|Hotkey|ControlInterface'
        } |
        Select-Object ProcessName, Id, Path, StartTime |
        Export-Csv -Path (Join-Path $Destination "asus-processes.csv") `
            -NoTypeInformation -Encoding utf8

    Get-Service -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match 'ASUS|ATK|ROG|Hotkey' -or
            $_.DisplayName -match 'ASUS|ATK|ROG|Hotkey|System Control Interface'
        } |
        Select-Object Name, DisplayName, Status, StartType |
        Export-Csv -Path (Join-Path $Destination "asus-services.csv") `
            -NoTypeInformation -Encoding utf8

    try {
        Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -match 'MyASUS|ASUS' -or
                $_.PackageFullName -match 'MyASUS|ASUS'
            } |
            Select-Object Name, PackageFullName, Version, Architecture,
                InstallLocation, Publisher |
            Export-Csv -Path (Join-Path $Destination "asus-appx-packages.csv") `
                -NoTypeInformation -Encoding utf8
    } catch {
    }
}

function Save-WmiInventory {
    $Pattern = 'ASUS|ATK|Hotkey|Function|FnLock|Keyboard|Camera|Microphone'
    $Rows = @()

    foreach ($Namespace in @("root\wmi", "root\cimv2")) {
        try {
            $Classes = Get-CimClass -Namespace $Namespace -ErrorAction Stop |
                Where-Object { $_.CimClassName -match $Pattern }

            foreach ($Class in $Classes) {
                $Rows += [PSCustomObject]@{
                    Namespace = $Namespace
                    ClassName = $Class.CimClassName
                }

                try {
                    Get-CimInstance -Namespace $Namespace `
                        -ClassName $Class.CimClassName -ErrorAction Stop |
                        ConvertTo-Json -Depth 6 |
                        Out-File -Path (
                            Join-Path $InventoryDir (
                                "wmi-{0}-{1}.json" -f
                                ($Namespace -replace '\\', '_'),
                                ($Class.CimClassName -replace '[^A-Za-z0-9._-]', '_')
                            )
                        ) -Width 500 -Encoding utf8
                } catch {
                }
            }
        } catch {
            [PSCustomObject]@{
                Namespace = $Namespace
                ClassName = "ERROR: $($_.Exception.Message)"
            } | Export-Csv -Path (Join-Path $InventoryDir "wmi-errors.csv") `
                -Append -NoTypeInformation -Encoding utf8
        }
    }

    $Rows | Export-Csv -Path (Join-Path $InventoryDir "matching-wmi-classes.csv") `
        -NoTypeInformation -Encoding utf8
}

function Save-AcpiTables {
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class A14FirmwareTables {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint EnumSystemFirmwareTables(
        uint FirmwareTableProviderSignature,
        IntPtr pFirmwareTableEnumBuffer,
        uint BufferSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint GetSystemFirmwareTable(
        uint FirmwareTableProviderSignature,
        uint FirmwareTableID,
        IntPtr pFirmwareTableBuffer,
        uint BufferSize);

    public static uint FourCC(string value) {
        if (value == null || value.Length != 4)
            throw new ArgumentException("FourCC must contain four characters.");
        return (uint)(
            ((byte)value[0]) |
            ((byte)value[1] << 8) |
            ((byte)value[2] << 16) |
            ((byte)value[3] << 24));
    }
}
"@

        $Provider = [A14FirmwareTables]::FourCC("ACPI")
        $Size = [A14FirmwareTables]::EnumSystemFirmwareTables(
            $Provider, [IntPtr]::Zero, 0
        )
        if ($Size -eq 0) {
            throw "EnumSystemFirmwareTables returned no ACPI tables."
        }

        $Pointer = [Runtime.InteropServices.Marshal]::AllocHGlobal([int]$Size)
        try {
            $Written = [A14FirmwareTables]::EnumSystemFirmwareTables(
                $Provider, $Pointer, $Size
            )
            $Bytes = New-Object byte[] $Written
            [Runtime.InteropServices.Marshal]::Copy(
                $Pointer, $Bytes, 0, [int]$Written
            )
        } finally {
            [Runtime.InteropServices.Marshal]::FreeHGlobal($Pointer)
        }

        $Manifest = @()
        $Occurrences = @{}

        for ($Offset = 0; $Offset + 3 -lt $Bytes.Length; $Offset += 4) {
            $TableId = [BitConverter]::ToUInt32($Bytes, $Offset)
            $Signature = [Text.Encoding]::ASCII.GetString(
                [BitConverter]::GetBytes($TableId)
            )
            $SafeSignature = $Signature -replace '[^A-Za-z0-9._-]', '_'

            if (-not $Occurrences.ContainsKey($SafeSignature)) {
                $Occurrences[$SafeSignature] = 0
            }
            $Occurrences[$SafeSignature]++
            $Index = $Occurrences[$SafeSignature]

            $TableSize = [A14FirmwareTables]::GetSystemFirmwareTable(
                $Provider, $TableId, [IntPtr]::Zero, 0
            )
            if ($TableSize -eq 0) {
                continue
            }

            $TablePointer = [Runtime.InteropServices.Marshal]::AllocHGlobal(
                [int]$TableSize
            )
            try {
                $Actual = [A14FirmwareTables]::GetSystemFirmwareTable(
                    $Provider, $TableId, $TablePointer, $TableSize
                )
                $TableBytes = New-Object byte[] $Actual
                [Runtime.InteropServices.Marshal]::Copy(
                    $TablePointer, $TableBytes, 0, [int]$Actual
                )
            } finally {
                [Runtime.InteropServices.Marshal]::FreeHGlobal($TablePointer)
            }

            $FileName = "{0}-{1:D2}.bin" -f $SafeSignature, $Index
            $Path = Join-Path $AcpiDir $FileName
            [IO.File]::WriteAllBytes($Path, $TableBytes)
            $Manifest += [PSCustomObject]@{
                Signature = $Signature
                TableId = ('0x{0:X8}' -f $TableId)
                Size = $Actual
                File = $FileName
                SHA256 = (Get-FileHash $Path -Algorithm SHA256).Hash
            }
        }

        $Manifest | Export-Csv -Path (Join-Path $AcpiDir "manifest.csv") `
            -NoTypeInformation -Encoding utf8

        $RsmbProvider = [A14FirmwareTables]::FourCC("RSMB")
        $RsmbSize = [A14FirmwareTables]::GetSystemFirmwareTable(
            $RsmbProvider, 0, [IntPtr]::Zero, 0
        )
        if ($RsmbSize -gt 0) {
            $RsmbPointer = [Runtime.InteropServices.Marshal]::AllocHGlobal(
                [int]$RsmbSize
            )
            try {
                $RsmbActual = [A14FirmwareTables]::GetSystemFirmwareTable(
                    $RsmbProvider, 0, $RsmbPointer, $RsmbSize
                )
                $RsmbBytes = New-Object byte[] $RsmbActual
                [Runtime.InteropServices.Marshal]::Copy(
                    $RsmbPointer, $RsmbBytes, 0, [int]$RsmbActual
                )
                [IO.File]::WriteAllBytes(
                    (Join-Path $AcpiDir "RSMB.bin"),
                    $RsmbBytes
                )
            } finally {
                [Runtime.InteropServices.Marshal]::FreeHGlobal($RsmbPointer)
            }
        }
    } catch {
        "FAILED: $($_.Exception.Message)" |
            Out-File -Path (Join-Path $AcpiDir "acpi-dump-error.txt") -Encoding utf8
    }
}

function Find-OrInstall-Procmon {
    $CandidateNames = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
        @("Procmon64a.exe", "Procmon64.exe", "Procmon.exe")
    } else {
        @("Procmon64.exe", "Procmon.exe", "Procmon64a.exe")
    }

    $CandidateRoots = @(
        $PSScriptRoot,
        (Join-Path $PSScriptRoot "Tools"),
        "C:\Program Files\Sysinternals",
        "C:\Tools\Sysinternals",
        (Join-Path $env:USERPROFILE "Downloads"),
        (Join-Path $env:LOCALAPPDATA "A14FirmwareTrace\ProcessMonitor")
    )

    foreach ($Root in $CandidateRoots) {
        foreach ($Name in $CandidateNames) {
            $Candidate = Join-Path $Root $Name
            if (Test-Path -LiteralPath $Candidate) {
                return $Candidate
            }
        }
    }

    foreach ($Name in $CandidateNames) {
        $Command = Get-Command $Name -ErrorAction SilentlyContinue
        if ($Command) {
            return $Command.Source
        }
    }

    if ($NoProcmonDownload) {
        return $null
    }

    Write-Host ""
    Write-Host "Process Monitor was not found." -ForegroundColor Yellow
    $Reply = Read-Host "Download it from Microsoft's official Sysinternals site? [Y/n]"
    if ($Reply -match '^(n|no)$') {
        return $null
    }

    $ToolRoot = Join-Path $env:LOCALAPPDATA "A14FirmwareTrace\ProcessMonitor"
    New-Item -ItemType Directory -Path $ToolRoot -Force | Out-Null
    $ZipPath = Join-Path $ToolRoot "ProcessMonitor.zip"

    try {
        Invoke-WebRequest `
            -Uri "https://download.sysinternals.com/files/ProcessMonitor.zip" `
            -OutFile $ZipPath -UseBasicParsing
        Expand-Archive -Path $ZipPath -DestinationPath $ToolRoot -Force

        foreach ($Name in $CandidateNames) {
            $Candidate = Join-Path $ToolRoot $Name
            if (Test-Path -LiteralPath $Candidate) {
                return $Candidate
            }
        }
    } catch {
        "Process Monitor download failed: $($_.Exception.Message)" |
            Add-Content (Join-Path $OutputRoot "warnings.txt")
    }

    return $null
}

function Start-ProcmonCapture {
    param([string]$ProcmonPath)

    if (-not $ProcmonPath) {
        return $false
    }

    try {
        & $ProcmonPath /AcceptEula /Terminate 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
        $PmlPath = Join-Path $TraceDir "asus-firmware-actions.pml"
        $Arguments = "/AcceptEula /Quiet /Minimized /BackingFile `"$PmlPath`""
        Start-Process -FilePath $ProcmonPath -ArgumentList $Arguments `
            -WindowStyle Hidden
        Start-Sleep -Seconds 2
        return $true
    } catch {
        "Process Monitor could not start: $($_.Exception.Message)" |
            Add-Content (Join-Path $OutputRoot "warnings.txt")
        return $false
    }
}

function Stop-ProcmonCapture {
    param([string]$ProcmonPath)

    if (-not $ProcmonPath) {
        return
    }

    try {
        & $ProcmonPath /Terminate 2>&1 | Out-Null
        Start-Sleep -Seconds 2
    } catch {
    }
}

function Start-WprCapture {
    $Wpr = Get-Command "wpr.exe" -ErrorAction SilentlyContinue
    if (-not $Wpr) {
        return $false
    }

    try {
        & $Wpr.Source -cancel 2>&1 | Out-Null
        & $Wpr.Source -start GeneralProfile -filemode 2>&1 |
            Out-File -Path (Join-Path $TraceDir "wpr-start.txt") `
                -Width 500 -Encoding utf8
        return ($LASTEXITCODE -eq 0)
    } catch {
        "WPR could not start: $($_.Exception.Message)" |
            Add-Content (Join-Path $OutputRoot "warnings.txt")
        return $false
    }
}

function Stop-WprCapture {
    param([bool]$WasStarted)

    if (-not $WasStarted) {
        return
    }

    try {
        & wpr.exe -stop (Join-Path $TraceDir "asus-firmware-actions.etl") `
            "ASUS Zenbook A14 MyASUS Fn-lock, microphone and camera trace" `
            2>&1 |
            Out-File -Path (Join-Path $TraceDir "wpr-stop.txt") `
                -Width 500 -Encoding utf8
    } catch {
        "WPR could not stop cleanly: $($_.Exception.Message)" |
            Add-Content (Join-Path $OutputRoot "warnings.txt")
        try {
            & wpr.exe -cancel 2>&1 | Out-Null
        } catch {
        }
    }
}

function Invoke-ActionStep {
    param(
        [string]$Label,
        [string[]]$Instructions
    )

    Write-Host ""
    Write-Host "STEP: $Label" -ForegroundColor Green
    foreach ($Line in $Instructions) {
        Write-Host "  $Line"
    }

    Write-Marker "BEGIN $Label"
    $Response = Read-Host "Press Enter when complete, or type SKIP"
    if ($Response -match '^(skip|s)$') {
        Write-Marker "SKIPPED $Label"
        return
    }

    Start-Sleep -Seconds 1
    Write-Marker "END $Label"
    Save-State $Label
}

function Save-EventLogs {
    $End = Get-Date
    $Logs = @(
        "System",
        "Application",
        "Microsoft-Windows-WMI-Activity/Operational",
        "Microsoft-Windows-DriverFrameworks-UserMode/Operational",
        "Microsoft-Windows-DeviceSetupManager/Admin",
        "Microsoft-Windows-Kernel-PnP/Configuration"
    )

    foreach ($LogName in $Logs) {
        $SafeName = $LogName -replace '[^A-Za-z0-9._-]', '_'
        try {
            Get-WinEvent -FilterHashtable @{
                LogName = $LogName
                StartTime = $CollectionStart.AddMinutes(-1)
                EndTime = $End.AddMinutes(1)
            } -ErrorAction Stop |
                Select-Object TimeCreated, Id, LevelDisplayName,
                    ProviderName, MachineName, Message |
                Export-Csv -Path (Join-Path $EventDir "$SafeName.csv") `
                    -NoTypeInformation -Encoding utf8
        } catch {
            "FAILED: $($_.Exception.Message)" |
                Out-File -Path (Join-Path $EventDir "$SafeName-error.txt") `
                    -Encoding utf8
        }
    }
}

try {
    Write-Section "ASUS Zenbook A14 Windows firmware trace collector"
    Write-Host "Output: $OutputRoot"
    Write-Host ""
    Write-Host "Privacy notice:" -ForegroundColor Yellow
    Write-Host "The trace can contain process names, file paths, registry values,"
    Write-Host "device identifiers, and signed ASUS driver binaries. It is not"
    Write-Host "uploaded automatically. Review the ZIP before sharing it."

    Write-Section "Collecting static inventory"

    Get-ComputerInfo -ErrorAction SilentlyContinue |
        Format-List * |
        Out-File -Path (Join-Path $InventoryDir "computer-info.txt") `
            -Width 500 -Encoding utf8

    Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue |
        Format-List * |
        Out-File -Path (Join-Path $InventoryDir "bios.txt") `
            -Width 500 -Encoding utf8

    Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue |
        Format-List * |
        Out-File -Path (Join-Path $InventoryDir "computer-system.txt") `
            -Width 500 -Encoding utf8

    Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue |
        Format-List * |
        Out-File -Path (Join-Path $InventoryDir "operating-system.txt") `
            -Width 500 -Encoding utf8

    Invoke-TextCommand -FilePath "msinfo32.exe" `
        -Arguments @("/report", (Join-Path $InventoryDir "msinfo32.txt")) `
        -OutputPath (Join-Path $InventoryDir "msinfo32-command.txt")

    Invoke-TextCommand -FilePath "driverquery.exe" `
        -Arguments @("/v", "/fo", "csv") `
        -OutputPath (Join-Path $InventoryDir "driverquery.csv")

    Invoke-TextCommand -FilePath "pnputil.exe" `
        -Arguments @("/enum-drivers", "/files") `
        -OutputPath (Join-Path $InventoryDir "pnputil-enum-drivers.txt")

    Invoke-TextCommand -FilePath "pnputil.exe" `
        -Arguments @("/enum-devices", "/connected") `
        -OutputPath (Join-Path $InventoryDir "pnputil-connected-devices.txt")

    Invoke-TextCommand -FilePath "logman.exe" `
        -Arguments @("query", "providers") `
        -OutputPath (Join-Path $InventoryDir "etw-providers-all.txt")

    try {
        Select-String -Path (Join-Path $InventoryDir "etw-providers-all.txt") `
            -Pattern 'ASUS|ATK|HID|Keyboard|WMI|ACPI|Camera|Audio|Microphone' |
            ForEach-Object { $_.Line } |
            Out-File -Path (Join-Path $InventoryDir "etw-providers-relevant.txt") `
                -Width 500 -Encoding utf8
    } catch {
    }

    $ServiceData = Get-AsusServicesAndDrivers
    $ServiceData.Services |
        Select-Object Name, DisplayName, State, StartMode, StartName,
            PathName, ProcessId |
        Export-Csv -Path (Join-Path $InventoryDir "asus-services-full.csv") `
            -NoTypeInformation -Encoding utf8

    $ServiceData.SystemDrivers |
        Select-Object Name, DisplayName, State, StartMode, PathName,
            ServiceType, ErrorControl |
        Export-Csv -Path (Join-Path $InventoryDir "asus-system-drivers.csv") `
            -NoTypeInformation -Encoding utf8

    Save-AsusBinaries -ServiceData $ServiceData
    Export-AsusDriverPackages
    Save-WmiInventory
    Save-AcpiTables
    Save-State "00-baseline"

    Write-Section "Starting short action trace"
    $ProcmonPath = Find-OrInstall-Procmon
    if ($ProcmonPath) {
        "Process Monitor: $ProcmonPath" |
            Out-File -Path (Join-Path $TraceDir "procmon-path.txt") -Encoding utf8
    } else {
        "Process Monitor unavailable; WPR and state snapshots will still be collected." |
            Add-Content (Join-Path $OutputRoot "warnings.txt")
    }

    $ProcmonStarted = Start-ProcmonCapture -ProcmonPath $ProcmonPath
    $WprStarted = Start-WprCapture
    Write-Marker "TRACE START"

    Invoke-ActionStep -Label "01-myasus-normal-fn" -Instructions @(
        "Open MyASUS.",
        "Go to Device Settings > Input Device Settings > Function Key Lock.",
        "Select Normal Fn key.",
        "Wait three seconds."
    )

    Invoke-ActionStep -Label "02-myasus-locked-fn" -Instructions @(
        "In the same MyASUS setting, select Locked Fn key.",
        "Wait three seconds.",
        "Press F5 and F6 once each to confirm the behavior changed."
    )

    Invoke-ActionStep -Label "03-fn-esc-toggle" -Instructions @(
        "Press Fn+Esc once.",
        "Wait three seconds.",
        "Press F5 and F6 once each.",
        "Do not repeatedly spam the key."
    )

    Invoke-ActionStep -Label "04-microphone-mute" -Instructions @(
        "Press the microphone-mute key once.",
        "Wait two seconds.",
        "Press it once again.",
        "Confirm whether the physical indicator follows the state."
    )

    Invoke-ActionStep -Label "05-camera-privacy" -Instructions @(
        "Open the Windows Camera app so camera behavior is visible.",
        "Press the camera-privacy key once.",
        "Wait two seconds.",
        "Press it once again.",
        "Note whether both the camera stream and physical light change."
    )

    Write-Marker "TRACE STOP"
    Stop-WprCapture -WasStarted $WprStarted
    Stop-ProcmonCapture -ProcmonPath $ProcmonPath
    Save-State "99-final"
    Save-EventLogs

    Write-Section "Creating archive"

    $Summary = @"
ASUS Zenbook A14 Windows firmware trace
Started: $($CollectionStart.ToString("o"))
Finished: $((Get-Date).ToString("o"))
Computer: $env:COMPUTERNAME
Architecture: $env:PROCESSOR_ARCHITECTURE
Process Monitor used: $ProcmonStarted
WPR used: $WprStarted

Primary files:
- traces\asus-firmware-actions.pml
- traces\asus-firmware-actions.etl
- traces\markers.tsv
- states\*
- asus-driver-packages\*
- asus-binaries\*
- acpi-tables\*
"@
    $Summary | Out-File -Path (Join-Path $OutputRoot "SUMMARY.txt") -Encoding utf8

    Stop-Transcript | Out-Null

    $ZipPath = "$OutputRoot.zip"
    if (Test-Path $ZipPath) {
        Remove-Item $ZipPath -Force
    }
    Compress-Archive -Path (Join-Path $OutputRoot "*") `
        -DestinationPath $ZipPath -CompressionLevel Optimal

    Write-Host ""
    Write-Host "Collection complete." -ForegroundColor Green
    Write-Host "ZIP: $ZipPath" -ForegroundColor Green
    Write-Host ""
    Write-Host "Review the archive before sharing it."
    Read-Host "Press Enter to close"
} catch {
    try {
        Stop-WprCapture -WasStarted $WprStarted
        Stop-ProcmonCapture -ProcmonPath $ProcmonPath
    } catch {
    }

    "FATAL: $($_.Exception.ToString())" |
        Out-File -Path (Join-Path $OutputRoot "fatal-error.txt") -Encoding utf8

    try {
        Stop-Transcript | Out-Null
    } catch {
    }

    Write-Host ""
    Write-Host "Collector failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Partial output remains at: $OutputRoot"
    Read-Host "Press Enter to close"
    exit 1
}
