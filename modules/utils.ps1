$e = [char]27
$cReset = "$e[0m"
$cCyan = "$e[36m"
$cYellow = "$e[33m"
$cGreen = "$e[32m"
$cMagenta = "$e[35m"
$cRed = "$e[31m"
$cBold = "$e[1m"
$cGray = "$e[90m"
$cWhite = "$e[97m"

function Write-Log ([string]$Message, [string]$Type = "Info") {
    $Color = switch ($Type) {
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error" { "Red" }
        "Action" { "Magenta" }
        Default { "Gray" }
    }
    $Timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$Timestamp] " -NoNewLine -ForegroundColor DarkGray
    Write-Host "[$Type] " -NoNewLine -ForegroundColor $Color
    Write-Host $Message
}

function Write-Header ([string]$Title) {
    # Calculate the exact width needed for the border
    # 4 accounts for the " # " prefix and the trailing space/hashtag spacing
    $BorderLength = $Title.Length + 4
    $Border = "#" * $BorderLength

    Write-Host "`n"
    Write-Host " $Border " -ForegroundColor DarkGray
    Write-Host " # $Title # " -ForegroundColor Cyan
    Write-Host " $Border " -ForegroundColor DarkGray
}

# Function to check if a command exists
function Test-CommandExists {
    param($command)
    return (Get-Command $command -ErrorAction SilentlyContinue)
}

function IsEdlMode {
    # Returns $true if a Qualcomm 9008 device is present.
    $edlDevice = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like "*USB\VID_05C6&PID_9008*" }
    return [bool]$edlDevice
}

function IsAdbMode {
    $adbOutput = & $ADB devices
    return $adbOutput | Select-String -Pattern "`t" -Quiet
}

function IsFastbootMode {
    $fbDevices = & $FASTBOOT devices
    return $fbDevices -match "fastboot$"
}

function Wait-Continue ([string]$Action = "continue...") {
    Write-Host "Press " -NoNewline
    Write-Host "Enter" -ForegroundColor Cyan -NoNewline
    Write-Host " to $Action" -NoNewline
    Read-Host | Out-Null
    Write-Host ""
}

function Wait-FastbootMode ([int]$Timeout = 100) {
    Write-Log "Waiting for device to enter ${cCyan}fastboot${cReset} mode..." "Info"
    $deviceDetected = $false
    foreach ($i in 1..$Timeout) {
        if (IsFastbootMode) {
            Write-Host "`rFastboot device detected.                                 " -ForegroundColor Green
            $deviceDetected = $true
            break
        }
        Write-Host "`r  ...waiting ($i/$Timeout) " -NoNewline
        Start-Sleep -Seconds 1
    }
    Write-Host ""
    return $deviceDetected
}

function Wait-EdlMode ([int]$Timeout = 100) {
    Write-Log "Waiting for device to enter ${cCyan}EDL mode (Qualcomm 9008)${cReset}..." "Info"
    $deviceDetected = $false
    foreach ($i in 1..$Timeout) {
        if (IsEdlMode) {
            Write-Host "`rEDL device detected.                                 " -ForegroundColor Green
            Start-Sleep -Seconds 5
            $deviceDetected = $true
            break
        }
        Write-Host "`r  ...waiting ($i/$Timeout) " -NoNewline
        Start-Sleep -Seconds 1
    }
    Write-Host ""
    return $deviceDetected
}

function Wait-AdbMode ([int]$Timeout = 100) {
    Write-Log "Waiting for device to connect in ${cCyan}ADB${cReset} mode..." "Info"
    $deviceDetected = $false
    foreach ($i in 1..$Timeout) {
        if (IsAdbMode) {
            Write-Host "`rADB device detected.                                      " -ForegroundColor Green
            $deviceDetected = $true
            break
        }
        Write-Host "`r  ...waiting for device to boot ($i/$Timeout) " -NoNewline
        Start-Sleep -Seconds 1
    }
    Write-Host ""
    return $deviceDetected
}

function Select-Firehose {
    if ($null -eq $script:FirehoseTargetPath) {
        Write-Host "`n"
        Write-Log "Select your device model to use the correct firehose:" "Info"
        Write-Host " ${cCyan}[1]${cReset} Pico 4 / Pico Neo 3 (DDR 4)"
        Write-Host " ${cCyan}[2]${cReset} Pico 4 Pro (DDR 5)"

        $fhChoice = Read-Host "`nSelect an option"

        if ($fhChoice -eq "2") {
            $script:FirehoseTargetPath = $FirehoseDDR5Path
            Write-Log "Using Lite Firehose for Pico 4 Pro." "Info"
        }
        else {
            $script:FirehoseTargetPath = $FirehoseDDR4Path
            Write-Log "Using standard DDR Firehose." "Info"
        }
    }
}

function Invoke-PicoHaxxScript {
    # Run the python script and capture the unlock command
    $unlockCommand = (python $PicoHaxxPyScript | Select-String -Pattern "fastboot oem pico").Line
    if (-not $unlockCommand) {
        Write-Log "Failed to generate unlock code using the ${cCyan}python${cReset} script." "Error"
        return $null
    }
    Write-Log "Generated Unlock Command: ${cCyan}$unlockCommand${cReset}" "Success"
    Write-Host ""

    # Create unlock command file
    $instructions = @"
$unlockCommand
fastboot oem setenforce 0
fastboot flashing unlock
fastboot flashing unlock_critical
"@
    $instructions | Set-Content "./picounlock.txt"

    return $unlockCommand
}

function Reboot-System {
    Clear-Host
    Write-Header "Rebooting to System"

    if (IsFastbootMode) {
        Write-Log "Device detected in ${cCyan}Fastboot${cReset} mode. Rebooting to ${cCyan}system${cReset}..." "Action"
        & $FASTBOOT reboot
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Reboot command sent successfully." "Success"
        }
        else {
            Write-Log "Failed to execute fastboot reboot." "Error"
        }
    }
    elseif (IsAdbMode) {
        Write-Log "Device detected in ${cCyan}ADB${cReset} mode. Rebooting to ${cCyan}system${cReset}..." "Action"
        & $ADB reboot
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Reboot command sent successfully." "Success"
        }
        else {
            Write-Log "Failed to execute adb reboot." "Error"
        }
    }
    else {
        Write-Log "Device not detected in ${cCyan}FASTBOOT${cReset} or ${cCyan}ADB${cReset} mode. Please connect your device and ensure it is powered on." "Warning"
    }
}

# Note: Export-ModuleMember is omitted to allow this file to be dot-sourced
# while maintaining access to caller-scoped variables ($ADB, $FASTBOOT, etc.)
