param()

$ErrorActionPreference = 'Stop'

function Read-Observation([string]$Prompt) {
    while ($true) {
        $value = (Read-Host $Prompt).Trim()
        if ($value.Length -gt 0) { return $value }
        Write-Host 'Please type works, no-change, broken, or describe exactly what happened; blank is ambiguous.' -ForegroundColor Yellow
    }
}

Write-Host '===== A14 FN-LOCK / ASUS OPTIMIZATION A/B TEST ====='
Write-Host 'This transiently stops only the ASUS Optimization USER-MODE service.'
Write-Host 'It does NOT stop/unbind the ASUS keyboard, HID, WMI, or EC kernel drivers.'
Write-Host 'If the service was running, the script restores it automatically in finally.'
Write-Host ''

$all = @(Get-CimInstance Win32_Service)
$matches = @($all | Where-Object {
    $_.Name -match 'ASUSOptimization' -or
    $_.DisplayName -match 'ASUS.*Optimization' -or
    $_.PathName -match 'ASUSOptimization\\.*AsusOptimization\.exe|AsusOptimization\.exe'
})

if ($matches.Count -eq 0) {
    Write-Host 'ASUS_OPTIMIZATION_SERVICE=NOT_FOUND'
    Write-Host 'Candidate ASUS user-mode services:'
    $all | Where-Object {
        $_.Name -match 'ASUS|ATK' -or $_.DisplayName -match 'ASUS|ATK' -or $_.PathName -match 'ASUS|ATK'
    } | Select-Object Name, DisplayName, State, StartMode, PathName | Format-Table -AutoSize
    throw 'Could not identify the ASUS Optimization service safely; nothing was stopped.'
}

if ($matches.Count -ne 1) {
    Write-Host "ASUS_OPTIMIZATION_SERVICE=AMBIGUOUS count=$($matches.Count)"
    $matches | Select-Object Name, DisplayName, State, StartMode, PathName | Format-List
    throw 'More than one ASUS Optimization service matched; nothing was stopped.'
}

$svc = $matches[0]
$svcName = [string]$svc.Name
$originalState = [string]$svc.State
$wasRunning = $originalState -eq 'Running'

Write-Host "SERVICE_NAME=$svcName"
Write-Host "SERVICE_DISPLAY_NAME=$($svc.DisplayName)"
Write-Host "SERVICE_STATE=$originalState"
Write-Host "SERVICE_START_MODE=$($svc.StartMode)"
Write-Host "SERVICE_PATH=$($svc.PathName)"

function Get-ServiceState {
    $current = Get-CimInstance Win32_Service -Filter ("Name='" + ($svcName -replace "'", "''") + "'")
    if ($null -eq $current) { return 'MISSING' }
    return [string]$current.State
}

function Wait-ServiceState([string]$Wanted, [int]$Seconds = 15) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $state = Get-ServiceState
        if ($state -eq $Wanted) { return $true }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

$runningObservation = $null
$stoppedObservation = $null
$restoreResult = 'NOT_NEEDED'

try {
    Write-Host ''
    Write-Host '===== A: SERVICE IN ORIGINAL STATE ====='
    Write-Host "current_state=$(Get-ServiceState)"
    Write-Host 'Press physical Fn+Esc once. Then test the SAME ordinary F-row key and Fn+key form.'
    Write-Host 'There is NO time limit.'
    $runningObservation = Read-Observation 'Describe behavior with ASUS Optimization in its original state'

    if (-not $wasRunning) {
        Write-Host ''
        Write-Host 'The service was not running originally, so a running-vs-stopped A/B would require changing the baseline.' -ForegroundColor Yellow
        Write-Host 'No service state was changed.'
        $stoppedObservation = 'SKIPPED_ORIGINALLY_NOT_RUNNING'
    }
    else {
        Write-Host ''
        Write-Host '===== STOP ASUS OPTIMIZATION ====='
        Stop-Service -Name $svcName -Force -ErrorAction Stop
        if (-not (Wait-ServiceState 'Stopped')) {
            throw "ASUS Optimization did not reach Stopped state; current=$(Get-ServiceState)"
        }
        Write-Host 'ASUS_OPTIMIZATION_STOPPED=YES'

        Write-Host ''
        Write-Host '===== B: SERVICE STOPPED ====='
        Write-Host 'Press physical Fn+Esc once. Then test the SAME ordinary F-row key and Fn+key form.'
        Write-Host 'There is NO time limit.'
        Write-Host 'Ignore missing ASUS OSD/toast graphics; report whether the actual F-row mode changes.'
        $stoppedObservation = Read-Observation 'Describe behavior while ASUS Optimization is stopped'
    }
}
finally {
    if ($wasRunning) {
        Write-Host ''
        Write-Host '===== RESTORE ASUS OPTIMIZATION ====='
        try {
            if ((Get-ServiceState) -ne 'Running') {
                Start-Service -Name $svcName -ErrorAction Stop
                if (-not (Wait-ServiceState 'Running')) {
                    throw "service did not reach Running state; current=$(Get-ServiceState)"
                }
            }
            $restoreResult = 'RUNNING'
            Write-Host 'ASUS_OPTIMIZATION_RESTORE=RUNNING'
        }
        catch {
            $restoreResult = "FAILED: $($_.Exception.Message)"
            Write-Host "ASUS_OPTIMIZATION_RESTORE=$restoreResult" -ForegroundColor Red
        }
    }
}

Write-Host ''
Write-Host '===== RESULT ====='
Write-Host "ORIGINAL_STATE=$originalState"
Write-Host "ORIGINAL_OBSERVATION=$runningObservation"
Write-Host "STOPPED_OBSERVATION=$stoppedObservation"
Write-Host "RESTORE_RESULT=$restoreResult"
Write-Host "FINAL_STATE=$(Get-ServiceState)"
Write-Host 'A14_FNLOCK_ASUSOPTIMIZATION_AB=COMPLETE'
