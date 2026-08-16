param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('prepare','after-reboot','restore')]
    [string]$Action,
    [string]$StatePath = "$env:ProgramData\A14FnLockColdServiceState.json",
    [string]$OutputDir = "$env:USERPROFILE\Downloads\a14-fnlock-cold-service-ab"
)

$ErrorActionPreference = 'Stop'
$ServiceName = 'ASUSOptimization'
$ServiceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
$KeyboardKey = 'HKLM:\SOFTWARE\ASUS\ASUS System Control Interface\AsusOptimization\ASUS Keyboard Hotkeys'
$Probe = Join-Path $PSScriptRoot 'a14-fnlock-direct-hid-probe.ps1'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run from an Administrator PowerShell.'
}
if (-not (Test-Path -LiteralPath $Probe)) {
    throw "Missing direct HID probe: $Probe"
}

function Get-ServiceRegistryState {
    $p = Get-ItemProperty -LiteralPath $ServiceKey -ErrorAction Stop
    $delayed = 0
    if ($null -ne $p.DelayedAutoStart) { $delayed = [int]$p.DelayedAutoStart }
    return [pscustomobject]@{
        Start = [int]$p.Start
        DelayedAutoStart = $delayed
    }
}

function Set-ServiceConfiguration([int]$Start, [int]$DelayedAutoStart) {
    # Do not write HKLM\...\Services\<name>\Start directly here. The Service
    # Control Manager keeps a live service database; after a boot in which the
    # service was disabled, a registry-only change back to Start=2/3 can leave
    # SCM still treating it as SERVICE_DISABLED until reboot. sc.exe config is
    # backed by ChangeServiceConfig and updates both SCM and the registry.
    $mode = switch ($Start) {
        2 { if ($DelayedAutoStart -ne 0) { 'delayed-auto' } else { 'auto' } }
        3 { 'demand' }
        4 { 'disabled' }
        default { throw "Unsupported ASUSOptimization Start value for this user-mode service: $Start" }
    }

    $text = & sc.exe config $ServiceName 'start=' $mode 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "sc.exe config $ServiceName start= $mode failed with exit code $LASTEXITCODE`r`n$($text -join "`r`n")"
    }

    $actual = Get-ServiceRegistryState
    if ($actual.Start -ne $Start) {
        throw "SCM configuration did not persist expected Start=$Start (actual=$($actual.Start))"
    }
    if ($Start -eq 2 -and (($actual.DelayedAutoStart -ne 0) -ne ($DelayedAutoStart -ne 0))) {
        throw "SCM configuration did not persist expected DelayedAutoStart=$DelayedAutoStart (actual=$($actual.DelayedAutoStart))"
    }
}

function Stop-AsusOptimization {
    $svc = Get-Service -Name $ServiceName -ErrorAction Stop
    if ($svc.Status -ne 'Stopped') {
        Stop-Service -Name $ServiceName -Force
        (Get-Service -Name $ServiceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
    }
}

function Restore-Original([object]$State) {
    Write-Host 'Restoring original ASUSOptimization service configuration...'
    Stop-AsusOptimization
    Set-ServiceConfiguration -Start ([int]$State.Start) -DelayedAutoStart ([int]$State.DelayedAutoStart)
    if ([bool]$State.WasRunning) {
        try {
            Start-Service -Name $ServiceName
            (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
        }
        catch {
            $qc = (& sc.exe qc $ServiceName 2>&1) -join "`r`n"
            throw "Original service state was restored but ASUSOptimization could not be restarted.`r`n$qc`r`n$($_.Exception.Message)"
        }
    }
    $svc = Get-Service -Name $ServiceName
    $reg = Get-ServiceRegistryState
    Write-Host "RESTORED_SERVICE_STATUS=$($svc.Status)"
    Write-Host "RESTORED_SERVICE_START=$($reg.Start)"
    Write-Host "RESTORED_DELAYED_AUTO_START=$($reg.DelayedAutoStart)"
}

function Save-KeyboardRegistry([string]$Path) {
    if (Test-Path -LiteralPath $KeyboardKey) {
        $values = Get-ItemProperty -LiteralPath $KeyboardKey
        $values | Format-List * | Out-String -Width 500 | Set-Content -Encoding UTF8 $Path
        foreach ($name in @('FnSwitch','ArrowKeySwitch')) {
            $v = $values.$name
            $label = $name.ToUpperInvariant()
            Write-Host "REGISTRY_$label=$(if ($null -eq $v) {'MISSING'} else {$v})"
        }
    }
    else {
        'KEY_NOT_FOUND' | Set-Content -Encoding ASCII $Path
        Write-Host 'REGISTRY_FNSWITCH=MISSING_KEY'
        Write-Host 'REGISTRY_ARROWKEYSWITCH=MISSING_KEY'
    }
}

function Invoke-InteractiveProbe([string]$LogPath) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Probe interactive 2>&1 |
        Tee-Object -FilePath $LogPath
    if ($LASTEXITCODE -ne 0) {
        throw "Direct HID probe failed with exit code $LASTEXITCODE"
    }
}

if ($Action -eq 'restore') {
    if (-not (Test-Path -LiteralPath $StatePath)) { throw "Missing saved state: $StatePath" }
    $state = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json
    Restore-Original $state
    Remove-Item -LiteralPath $StatePath -Force
    Write-Host 'A14_FNLOCK_COLD_SERVICE_RESTORE=PASS'
    return
}

if ($Action -eq 'prepare') {
    if (Test-Path -LiteralPath $StatePath) {
        throw "State already exists: $StatePath. Use -Action restore first if a previous test was interrupted."
    }
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $svc = Get-Service -Name $ServiceName -ErrorAction Stop
    $reg = Get-ServiceRegistryState
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $state = [pscustomobject]@{
        PreparedAt = (Get-Date).ToString('o')
        BootAtPrepare = $boot.ToString('o')
        Start = $reg.Start
        DelayedAutoStart = $reg.DelayedAutoStart
        WasRunning = ($svc.Status -eq 'Running')
    }
    $state | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath $StatePath
    Save-KeyboardRegistry (Join-Path $OutputDir 'keyboard-registry-before.txt')
    Stop-AsusOptimization
    Set-ServiceConfiguration -Start 4 -DelayedAutoStart 0
    Write-Host "STATE_SAVED=$StatePath"
    Write-Host 'ASUS_OPTIMIZATION=STOPPED_AND_DISABLED'
    Write-Host 'COLD_TEST_READY=YES'
    Write-Host 'Reboot Windows normally. Do NOT start ASUSOptimization. After reboot run:'
    Write-Host '  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\a14-fnlock-cold-service-ab.ps1 -Action after-reboot'
    Write-Host 'A14_FNLOCK_COLD_SERVICE_PREPARE=PASS'
    return
}

# after-reboot
if (-not (Test-Path -LiteralPath $StatePath)) { throw "Missing saved state: $StatePath" }
$state = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$nowBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$prepareBoot = [DateTimeOffset]::Parse([string]$state.BootAtPrepare)
if ($nowBoot -le $prepareBoot.LocalDateTime) {
    throw "Windows has not rebooted since prepare. Current boot=$nowBoot prepare boot=$($state.BootAtPrepare)"
}
$svc = Get-Service -Name $ServiceName -ErrorAction Stop
$currentReg = Get-ServiceRegistryState
Write-Host "AFTER_REBOOT_SERVICE_STATUS=$($svc.Status)"
Write-Host "AFTER_REBOOT_SERVICE_START=$($currentReg.Start)"
if ($svc.Status -ne 'Stopped' -or $currentReg.Start -ne 4) {
    throw 'Cold-boot prerequisite failed: ASUSOptimization was not stopped+disabled for this boot.'
}
Save-KeyboardRegistry (Join-Path $OutputDir 'keyboard-registry-cold.txt')

try {
    Write-Host ''
    Write-Host '===== COLD BOOT: ASUSOptimization HAS NOT RUN THIS BOOT ====='
    Invoke-InteractiveProbe (Join-Path $OutputDir 'cold-before-service.txt')

    Write-Host ''
    Write-Host '===== RUN ASUSOptimization ONCE ====='
    Set-ServiceConfiguration -Start 3 -DelayedAutoStart 0
    Start-Service -Name $ServiceName
    (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
    Start-Sleep -Seconds 5
    Write-Host 'ASUS_OPTIMIZATION_ONCE=RUNNING_FOR_5_SECONDS'
    Stop-AsusOptimization
    Write-Host 'ASUS_OPTIMIZATION_ONCE=STOPPED'
    Save-KeyboardRegistry (Join-Path $OutputDir 'keyboard-registry-after-service-once.txt')

    Write-Host ''
    Write-Host '===== SAME BOOT: AFTER ASUSOptimization RAN ONCE ====='
    Invoke-InteractiveProbe (Join-Path $OutputDir 'after-service-once.txt')
}
finally {
    Restore-Original $state
}

$hashPath = Join-Path $OutputDir 'SHA256SUMS.txt'
Get-ChildItem -LiteralPath $OutputDir -File |
    Where-Object { $_.FullName -ne $hashPath } |
    Sort-Object Name |
    ForEach-Object {
        $h = Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName
        "$($h.Hash.ToLowerInvariant())  $($_.Name)"
    } | Set-Content -Encoding ASCII $hashPath

Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
Write-Host "RESULT_DIR=$OutputDir"
Write-Host 'A14_FNLOCK_COLD_SERVICE_AB=PASS'
