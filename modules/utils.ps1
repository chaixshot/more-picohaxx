#Requires -Version 5.1

<#
.SYNOPSIS
    Utility functions for the PicoUnlock project.
.DESCRIPTION
    Provides common functions for logging, UI headers, device mode detection,
    and rebooting operations. Used across all PicoUnlock modules.
#>

# --- Utility Functions ---

$e = [char]27
$cReset = "$e[0m"
$cCyan = "$e[36m"
$cYellow = "$e[33m"
$cGreen = "$e[32m"
$cMagenta = "$e[35m"
$cRed = "$e[31m"
$cBold = "$e[1m"
$cGray = "$e[90m"
$cDarkGray = "$e[90m"
$cWhite = "$e[97m"

function Write-Log([string]$Message, [string]$Type = "Info")
{
    $Color = switch ($Type)
    {
        "Success" {
            $cGreen
        }
        "Warning" {
            $cYellow
        }
        "Error" {
            $cRed
        }
        "Action" {
            $cMagenta
        }
        Default {
            $cGray
        }
    }
    Write-Host "${Color}[$Type] ${cReset}$Message"
}

function Clean-LogFormat
{
    param([string]$LogFile)

    if (Test-Path $LogFile)
    {
        $content = Get-Content $LogFile -Raw

        # Remove ANSI escape sequences (colors, styles, etc.)
        # This covers $cReset, $cCyan, $cYellow, $cGreen, $cMagenta, $cRed, $cBold, $cGray, $cWhite
        $esc = [char]27
        $pattern = "$([char]27)\[[0-9;]*[a-zA-Z]"

        $cleanContent = $content -replace $pattern, ""
        $cleanContent | Set-Content $LogFile -Force
    }
}

function Write-Header([string]$Title)
{
    # Calculate the exact width needed for the border
    # 4 accounts for the " # " prefix and the trailing space/hashtag spacing
    $BorderLength = $Title.Length + 4
    $Border = "#" * $BorderLength

    Write-Host "`n"
    Write-Host " ${cDarkGray}$Border${cReset} "
    Write-Host " ${cCyan}# $Title #${cReset} "
    Write-Host " ${cDarkGray}$Border${cReset} "
}

# Function to check if a command exists
function Test-CommandExists([string]$Command)
{
    return (Get-Command $Command -ErrorAction SilentlyContinue)
}

function IsEdlMode
{
    # Returns $true if a Qualcomm 9008 device is present.
    $edlDevice = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like "*USB\VID_05C6&PID_9008*" }
    return [bool]$edlDevice
}

function IsAdbMode
{
    $adbOutput = & $ADB devices
    return $adbOutput | Select-String -Pattern "`t" -Quiet
}

function IsFastbootMode
{
    $fbDevices = & $FASTBOOT devices
    return $fbDevices -match "fastboot$"
}

function Wait-Continue([string]$Action = "continue...")
{
    Write-Host "`nPress ${cCyan}Enter${cReset} to $Action" -NoNewline
    Read-Host | Out-Null
    Write-Host ""
}

function Wait-FastbootMode([int]$Timeout = 100)
{
    Write-Host ""
    Write-Log "Waiting for device to enter ${cCyan}FASTBOOT${cReset} mode..." "Action"
    $deviceDetected = $false
    foreach ($i in 1..$Timeout)
    {
        if (IsFastbootMode)
        {
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

function Wait-EdlMode([int]$Timeout = 100)
{
    Write-Host ""
    Write-Log "Waiting for device to enter ${cCyan}EDL${cReset} mode..." "Action"
    $deviceDetected = $false
    foreach ($i in 1..$Timeout)
    {
        if (IsEdlMode)
        {
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

function Wait-AdbMode([int]$Timeout = 100)
{
    Write-Host ""
    Write-Log "Waiting for device to connect in ${cCyan}ADB${cReset} mode..." "Action"
    $deviceDetected = $false
    foreach ($i in 1..$Timeout)
    {
        if (IsAdbMode)
        {
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

function Select-Firehose
{
    if ($null -eq $script:FirehoseTargetPath)
    {
        Write-Host "`n"
        Write-Log "Select your device model to use the correct firehose:" "Info"
        Write-Host " [${cCyan}1${cReset}] Pico 4 / Pico Neo 3 (DDR 4)"
        Write-Host " [${cCyan}2${cReset}] Pico 4 Pro (DDR 5)"

        $fhChoice = Read-Host "`nSelect an option"

        if ($fhChoice -in "1", "")
        {
            $script:FirehoseTargetPath = $FirehoseDDR4Path
            Write-Log "Using DDR 4 Firehose." "Info"
        }
        elseif ($fhChoice -eq "2")
        {
            $script:FirehoseTargetPath = $FirehoseDDR5Path
            Write-Log "Using DDR 5 Firehose." "Info"
        }

        if (-not $fhChoice)
        {
            Wait-Continue
        }
    }
}

function Invoke-PicoHaxxScript
{
    # Run the python script and capture the unlock command
    $unlockCommand = (python $PicoHaxxPyScript | Select-String -Pattern "fastboot oem pico").Line
    if (-not $unlockCommand)
    {
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
    $instructions | Set-Content $Picounlock

    return $unlockCommand
}

function Perform-Reboot
{
    Clear-Host
    Write-Header "Reboot Selection"
    Write-Host " [${cCyan}1${cReset}] Boot to SYSTEM"
    Write-Host " [${cCyan}2${cReset}] Boot to FASTBOOT"
    Write-Host " [${cCyan}3${cReset}] Boot to recovery"
    if(-not (IsFastbootMode))
    {
        Write-Host " [${cCyan}4${cReset}] Boot to EDL"
    }
    Write-Host ""

    if (IsFastbootMode)
    {
        Write-Host "Device detected: ${cCyan}FASTBOOT${cReset}"
    }
    elseif (IsAdbMode)
    {
        Write-Host "Device detected: ${cGreen}ADB${cReset}"
    }
    elseif (IsEdlMode)
    {
        Write-Log "Device is detected in ${cCyan}EDL${cReset} mode." "Warning"
        Write-Log "Manually reboot by hold ${cYellow}Power${cReset}." "Info"
        return
    }
    else
    {
        Write-Log "No device detected." "Error"
        Write-Log "Please connect your device and ensure it is powered on." "Info"
        return
    }

    $choice = Read-Host "Select an option"

    if (IsFastbootMode)
    {
        if ($choice -in "1", "")
        {
            Fastboot-To-System
        }
        elseif ($choice -eq "2")
        {
            Fastboot-To-Fastboot
        }
        elseif ($choice -eq "3")
        {
            Fastboot-To-Recovery
        }
        elseif ($choice -eq "4")
        {
            Write-Log "Device is detected in ${cCyan}FASTBOOT${cReset} mode." "Warning"
            Write-Log "Unable to reboot to EDL." "Error"
        }
    }
    elseif (IsAdbMode)
    {
        if ($choice -in "1", "")
        {
            ADB-To-System
        }
        elseif ($choice -eq "2")
        {
            ADB-To-Fastboot
        }
        elseif ($choice -eq "3")
        {
            ADB-To-Recovery
        }
        elseif ($choice -eq "4")
        {
            ADB-To-Edl
        }
    }
}

function Warning-ADB
{
    Write-Host ""
    Write-Log "Device not detected in ${cCyan}ADB${cReset} mode." "Error"
    Write-Log "Please connect your device and enable USB Debug." "Info"
    Write-Log "${cYellow}https://knowledge.matts-digital.com/en/virtual-reality/pico/pico-g3/how-to-enable-usb-debugging-on-the-pico-g3/${cReset}" "Info"
}

function Warning-FASTBOOT
{
    Write-Host ""
    Write-Log "Device not detected in ${cCyan}FASTBOOT${cReset} mode." "Error"
    Write-Log "Please ensure device connected and in FASTBOOT mode." "Error"
    Write-Host "Manually boot to FASTBOOT by keep hold ${cYellow}Vol Down + Power${cReset}."
}

function Warning-EDL
{
    Write-Host ""
    Write-Log "Device not detected in EDL mode." "Error"
    Write-Log "Manually boot to EDL by keep hold ${cYellow}Vol Up + Vol Down + Power${cReset}." "Info"
}

function ADB-To-System
{
    Write-Host ""
    Write-Log "Device detected in ${cCyan}ADB${cReset} mode. Attempting to reboot into ${cCyan}SYSTEM${cReset} mode..." "Info"
    & $ADB reboot
}

function ADB-To-Fastboot
{
    Write-Host ""
    Write-Log "Device detected in ${cCyan}ADB${cReset} mode. Attempting to reboot into ${cCyan}FASTBOOT${cReset} mode..." "Info"
    & $ADB reboot bootloader
}

function ADB-To-Recovery
{
    Write-Host ""
    Write-Log "Device detected in ${cCyan}ADB${cReset} mode. Attempting to reboot into ${cCyan}RECOVERY${cReset} mode..." "Info"
    & $ADB reboot recovery
}

function ADB-To-Edl
{
    Write-Host ""
    Write-Log "Device detected in ${cCyan}ADB${cReset} mode. Attempting to reboot into ${cCyan}EDL${cReset} mode..." "Info"
    & $ADB reboot edl
}

function Fastboot-To-System
{
    Write-Host ""
    Write-Log "Device detected in ${cCyan}FASTBOOT${cReset} mode. Attempting to reboot into ${cCyan}SYSTEM${cReset} mode..." "Info"
    & $FASTBOOT reboot
}

function Fastboot-To-Fastboot
{
    Write-Host ""
    Write-Log "Device detected in ${cCyan}FASTBOOT${cReset} mode. Attempting to reboot into ${cCyan}FASTBOOT${cReset} mode..." "Info"
    & $FASTBOOT reboot bootloader
}

function Fastboot-To-Recovery
{
    Write-Host ""
    Write-Log "Device detected in ${cCyan}FASTBOOT${cReset} mode. Attempting to reboot into ${cCyan}RECOVERY${cReset} mode..." "Info"
    & $FASTBOOT reboot recovery
}
