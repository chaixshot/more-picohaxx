#Requires -Version 5.1

<#
.SYNOPSIS
    Automates the bootloader unlock and root process for Pico 4 devices.
.DESCRIPTION
    This script follows the steps outlined in more-picohaxx.py to unlock the bootloader and root the device.
    It handles getting the serial number, generating the unlock code, downloading necessary files,
    executing required edl, fastboot, and Magisk rooting operations.

    WARNING:
    - Unlocking the bootloader will wipe your data partition. BACKUP YOUR DATA.
    - Rooting may void your warranty.
    - Incorrect flashing can brick your device.
    - This is a complex process. Proceed only if you are familiar with adb, edl, and fastboot.
    - The script authors and I are not responsible for any damage to your device.

.NOTES
    Prerequisites:
    - adb.exe and fastboot.exe must be in your PATH or the script's directory.
    - qdl.exe (from https://github.com/linux-msm/qdl) must be in the script's directory.
    - The 'more-picohaxx.py' script must be in the same directory.
    - Magisk4Pico.apk must be in the .\tools directory for rooting.
#>

# ----------------------------
# --- Script Configuration ---
# ----------------------------
$LogsPath = ".\logs"
$DriverInstall = ".\tools\driver\install.ps1"
$DeviceSerial = ".\serial_number.txt"

$FirehoseDDR4Path = (Get-Item ".\tools\firehoses\prog_firehose_ddr.elf").FullName
$FirehoseDDR5Path = (Get-Item ".\tools\firehoses\prog_firehose_lite.elf").FullName
$FirehoseTargetPath = $null

$AblPath = ".\tools\engineering\abl.elf"
$DevInfoPath = ".\tools\engineering\devinfo"

$BackupPath = ".\backup"
$AblBackupPath = "${BackupPath}\abl"
$UserBackupPath =  "${BackupPath}\userdata"

$QDL = ".\tools\qdl.exe"
$ADB = ".\tools\adb.exe"
$FASTBOOT = ".\tools\fastboot.exe"

$TimeStamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

# ----------------------------
# ----- Helper Functions -----
# ----------------------------

. "$PSScriptRoot/modules/utils.ps1"
. "$PSScriptRoot/modules/root.ps1"
. "$PSScriptRoot/modules/backuprestore.ps1"
. "$PSScriptRoot/modules/qfilhelper.ps1"

function Check-Prerequisites
{
    Write-Header "Running Prerequisite Checks"

    $isReady = $true

    if (-not (Test-Path $ADB) -and -not (Test-CommandExists "adb"))
    {
        Write-Log "${cYellow}$ADB${cReset} not found. Please add it to your ${cCyan}PATH${cReset} or place it in the script directory." "Error"
        $isReady = $false
    }
    if (-not (Test-Path $FASTBOOT) -and -not (Test-CommandExists "fastboot"))
    {
        Write-Log "${cYellow}$FASTBOOT${cReset} not found. Please add it to your ${cCyan}PATH${cReset} or place it in the script directory." "Error"
        $isReady = $false
    }
    if (-not (Test-Path $QDL))
    {
        Write-Log "${cYellow}qdl.exe${cReset} not found. Please place it in the script directory." "Error"
        $isReady = $false
    }
    if (-not (Test-Path $AblPath))
    {
        Write-Log "'${cYellow}$AblPath${cReset}' not found. Please download it and place it correctly." "Error"
        $isReady = $false
    }
    if (-not (Test-Path $FirehoseDDR4Path))
    {
        Write-Log "'${cYellow}$FirehoseDDR4Path${cReset}' not found. Please download it and place it correctly." "Error"
        $isReady = $false
    }
    if (-not (Test-Path $FirehoseDDR5Path))
    {
        Write-Log "'${cYellow}$FirehoseDDR5Path${cReset}' not found. Please download it and place it correctly." "Error"
        $isReady = $false
    }

    # Detect legacy/conflicting qdl_winusb.inf driver
    $allDrivers = pnputil /enum-drivers
    $qdlDrivers = $allDrivers | Select-String -Pattern "qdl_winusb\.inf" -Context 1,0
    if ($qdlDrivers)
    {
        Write-Log "Found legacy/conflicting driver '${cYellow}qdl_winusb.inf${cReset}' installed." "Warning"
        Write-Log "This driver is known to cause issues with current EDL flashing tools." "Info"
        Write-Host "Do you want to ${cRed}delete${cReset} it? (${cCyan}y${cReset}/n): " -NoNewline
        $deleteChoice = Read-Host
        if ($deleteChoice -eq 'y')
        {
            foreach ($match in $qdlDrivers)
            {
                # Extract oemXX.inf from the line above the match
                $publishedName = ($match.Context.PreContext[0] -replace "Published Name:\s+", "").Trim()
                if ($publishedName -match "oem\d+\.inf")
                {
                    Write-Log "Deleting driver ${cCyan}$publishedName${cReset} (qdl_winusb.inf)..." "Action"
                    pnputil /delete-driver $publishedName /uninstall /force | Out-Null
                }
            }

            Write-Log "Rescanning hardware devices to rebind correct driver..." "Action"
            pnputil /scan-devices | Out-Null

            # Verification step
            Write-Host ""
            $verifyDrivers = pnputil /enum-drivers
            if ($verifyDrivers -match "qdl_winusb\.inf")
            {
                Write-Log "Failed to completely remove '${cYellow}qdl_winusb.inf${cReset}'. Manual removal may be required." "Error"
                Write-Log "Use DriverStoreExplorer (https://github.com/lostindark/driverstoreExplorer) to proceed." "Info"
                $isReady = $false
            }
            else
            {
                Write-Log "'${cYellow}qdl_winusb.inf${cReset}' has been removed." "Success"
            }

            Wait-Continue
        }
        else{
            $isReady = $false
        }
    }

    # Check for EDL driver and offer to install it
    $targetDrivers = "qcser\.inf|android_winusb\.inf"
    $installedDrivers = (pnputil /enum-drivers) -join "`n"
    if ($installedDrivers -notmatch $targetDrivers)
    {
        Write-Log "All prerequisites found." "Success"
        Write-Host ""
        Write-Log "The WinUSB driver for ${cCyan}EDL mode (Qualcomm 9008)${cReset} does not appear to be installed." "Warning"
        Write-Log "This is required for flashing the ${cYellow}bootloader${cReset}." "Info"
        Write-Host "Press ${cCyan}Y${cReset} to install the driver now, or ${cYellow}N${cReset} to skip (Requires Administrator privileges): " -NoNewline

        $choice = Read-Host
        if ($choice -eq 'Y' -or $choice -eq 'y')
        {
            $installScript = $DriverInstall
            if (-not (Test-Path $installScript))
            {
                Write-Log "Driver installation script not found at '${cYellow}$installScript${cReset}'." "Error"
                $isReady = $false
            }
            else
            {
                # Start the install script elevated
                Write-Log "Launching driver installer..." "Action"
                Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$installScript`"" -NoNewWindow -Wait

                Write-Log "Driver installation process finished. Re-checking for driver..." "Info"

                $recheckDrivers = (pnputil /enum-drivers) -join "`n"
                if ($recheckDrivers -notmatch $targetDrivers)
                {
                    Write-Log "Driver still not found. Please run '${cYellow}$installScript${cReset}' manually as ${cCyan}Administrator${cReset} and then re-run this script." "Error"
                    $isReady = $false
                }
                else
                {
                    Write-Log "Driver successfully installed." "Success"
                }

                Write-Log "Rescanning hardware devices to rebind correct driver..." "Action"
                pnputil /scan-devices | Out-Null
            }
        }
        else
        {
            Write-Log "Skipping driver installation. The script may fail if the driver is not installed correctly." "Warning"
        }

        Wait-Continue
    }

    if (-not $isReady)
    {
        Write-Log "Some prerequisites are missing. Functions may not work correctly." "Warning"
        Wait-Continue
    }

    return $isReady
}

function Generate-UnlockCode
{
    Write-Header "Generating Unlock Code"

    if (-not (IsAdbMode))
    {
        Warning-ADB
        return
    }

    $serialNumber = (& $ADB shell "cat /sys/devices/soc0/serial_number").Trim()
    if (-not ($serialNumber -match "^\d+$"))
    {
        Write-Log "Failed to get a valid serial number from the device. Is it connected and authorized?" "Error"
        return
    }

    $serialNumber | Set-Content -Path $DeviceSerial -Encoding Ascii
    Write-Log "Device serial number saved to ${cCyan}'$DeviceSerial'${cReset}." "Info"
    Write-Log "Device serial number: ${cGreen}$serialNumber${cReset}" "Success"
}

# ----------------------------
# ---------- ABL -------------
# ----------------------------

function Flash-EngineeringAbl
{
    Write-Header "Flashing Engineering ABL & Devinfo via EDL"
    Write-Log "This step will reboot your device into ${cCyan}EDL (Emergency Download)${cReset} mode to flash engineering files." "Warning"
    Write-Log "This is a critical part of the unlock process." "Warning"
    Write-Log "Make sure the device is '${cCyan}Fully Charged${cReset}'." "Warning"

    Write-Host "`nTo proceed with rebooting to EDL, type ${cYellow}'YES'${cReset} and press Enter: " -NoNewline
    $confirmation = Read-Host
    if ($confirmation -ne 'YES')
    {
        Write-Log "Reboot to EDL aborted by user. No changes have been made." "Warning"
        return
    }

    # Create backup directory if it doesn't exist
    if (-not (Test-Path $AblBackupPath))
    {
        New-Item -Path $AblBackupPath -ItemType Directory | Out-Null
    }

    # Reboot EDL
    if (IsAdbMode)
    {
        ADB-To-Edl
    }
    elseif (-not (IsEdlMode))
    {
        Warning-EDL
    }

    if (-not (Wait-EdlMode 100))
    {
        Warning-EDL
        return
    }

    # Create a timestamped backup folder
    $currentBackupPath = Join-Path $AblBackupPath $TimeStamp
    New-Item -Path $currentBackupPath -ItemType Directory | Out-Null
    $backupAbl = Join-Path $currentBackupPath "abl.bin"
    $backupDevInfo = Join-Path $currentBackupPath "devinfo.bin"

    Write-Log "Backing up original partitions and flashing engineering files in a single operation..." "Action"
    & $QDL --storage ufs --include (Split-Path $FirehoseTargetPath -Parent) $FirehoseTargetPath read abl $backupAbl read devinfo $backupDevInfo write abl $AblPath write devinfo $DevInfoPath
    if ($LASTEXITCODE -ne 0)
    {
        Write-Log "The combined backup and flash operation failed. Your device may be in an unusable state. Check if backups were created in '${cYellow}$currentBackupPath${cReset}' and attempt a manual restore if necessary." "Error"
        return
    }
    Write-Log "Original partitions backed up to ${cGreen}'$currentBackupPath'${cReset}." "Success"
    Write-Log "Engineering ABL and Devinfo flashed successfully." "Success"
    Write-Log "Engineering ABL might reboot device to EDL mode sometimes." "Warning"
    Write-Log "Your device will automatically reboot to the system." "Info"
}

function Restore-OriginalAbl
{
    Write-Header "Restoring Original Partitions via EDL"
    Write-Log "This fix resolves issues like slow reboots and unwanted booting into ${cCyan}EDL${cReset} mode." "Info"
    Write-Log "SELinux will return to ${cYellow}Enforcing${cReset} mode, using ${cCyan}https://github.com/evdenis/selinux_permissive${cReset} to change back to Permissive mode" "Info"
    Write-Log "Perform ${cYellow}rooting${cReset} (${cCyan}Option 4${cReset}) before doing this step!" "Warning"
    Write-Log "Make sure the device is '${cCyan}Fully Charged${cReset}'." "Warning"

    $backupFolder = Get-LatestAblBackup -FileName ""
    if (-not $backupFolder)
    {
        return
    }
    $backupAbl = Join-Path $backupFolder "abl.bin"
    $backupDevInfo = Join-Path $backupFolder "devinfo.bin"

    Write-Log "Target backup folder: ${cGreen}$backupFolder${cReset}" "Info"
    Write-Host "`nAre you sure you want to flash this backup? (Type ${cYellow}'YES'${cReset}): " -NoNewline
    $confirmation = Read-Host
    if ($confirmation -ne 'YES')
    {
        Write-Log "Restore aborted by user." "Warning"
        return
    }

    if (IsAdbMode)
    {
        ADB-To-Edl
    }
    elseif (-not (IsEdlMode))
    {
        Warning-EDL
    }

    if (-not (Wait-EdlMode 100))
    {
        Warning-EDL
        return
    }

    & $QDL --storage ufs --include (Split-Path $FirehoseTargetPath -Parent) $FirehoseTargetPath write abl $backupAbl write devinfo $backupDevInfo
    if ($LASTEXITCODE -eq 0)
    {
        Write-Log "Your device will automatically reboot to the system." "Info"
    }
    else
    {
        Write-Log "Failed to restore backup partitions." "Error"
    }
    Write-Log "Original partitions restored successfully!" "Success"
}

function Get-LatestAblBackup([string]$FileName = "abl.bin")
{
    if (-not (Test-Path -Path $AblBackupPath -PathType Container))
    {
        Write-Log "The specified backup directory '${cYellow}$AblBackupPath${cReset}' does not exist." "Error"
        return $null
    }
    $folders = Get-ChildItem -Path $AblBackupPath -Directory |
            Where-Object { $_.Name -match '^\d+$|^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$' } |
            Sort-Object -Property LastWriteTime -Descending

    if (-not $folders)
    {
        Write-Log "No valid backup folders found in '${cYellow}$AblBackupPath${cReset}'." "Error"
        return $null
    }

    if ($folders.Count -gt 1)
    {
        $selectedFolder = $null
        while (-not $selectedFolder)
        {
            Write-Host "`nAvailable backup folders:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $folders.Count; $i++) {
                Write-Host " [${cCyan}$i${cReset}] $( $folders[$i].Name )"
            }
            Write-Host "`nSelect a backup folder (enter index or folder name, default [${cCyan}0${cReset}] for latest, [${cYellow}c${cReset}] to cancel): " -NoNewline
            $selection = Read-Host

            if ( [string]::IsNullOrWhiteSpace($selection))
            {
                $selection = "0"
            }

            if ($selection -eq 'c')
            {
                Write-Log "Operation cancelled." "Warning"
                return $null
            }

            # Check if it matches a folder name directly
            $selectedFolder = $folders | Where-Object { $_.Name -eq $selection } | Select-Object -First 1

            # If not, check if it's an index
            if (-not $selectedFolder -and $selection -match '^\d+$')
            {
                $index = [int]$selection
                if ($index -ge 0 -and $index -lt $folders.Count)
                {
                    $selectedFolder = $folders[$index]
                }
            }

            if (-not $selectedFolder)
            {
                Clear-Host
                Write-Log "Invalid selection '$selection'. Please try again or type '${cCyan}c${cReset}' to cancel." "Warning"
            }
        }
        return Join-Path -Path $selectedFolder.FullName -ChildPath $FileName
    }

    return Join-Path -Path $folders[0].FullName -ChildPath $FileName
}

# ----------------------------
# ------- Bootloader ---------
# ----------------------------

function Perform-FastbootUnlock
{
    Write-Header "Performing Unlock Bootloader"
    Write-Log "This step will reboot your device into ${cCyan}FASTBOOT${cReset} mode to unlock bootloader." "Warning"
    Write-Log "If bootloader is in ${cRed}Locked${cReset} state, this process will factory reset device data." "Warning"
    Write-Log "Recommended to do a backup in the main menu." "Warning"

    Write-Host "`nTo proceed with rebooting to FASTBOOT, type ${cYellow}'YES'${cReset} and press Enter: " -NoNewline
    $confirmation = Read-Host
    if ($confirmation -ne 'YES')
    {
        Write-Log "Reboot to FASTBOOT aborted by user. No changes have been made." "Warning"
        return
    }

    if (IsAdbMode)
    {
        ADB-To-Fastboot
    }
    elseif (-not (IsFastbootMode))
    {
        Warning-FASTBOOT
    }

    if (-not (Wait-FastbootMode 100))
    {
        Warning-FASTBOOT
        return
    }

    # Check current state
    if (-not (IsFastbootUnlocked))
    {
        Write-Log "Bootloader status confirmed: ${cGreen}LOCKED${cReset}" "Warning"
        Write-Log "Your device will factory reset after the process." "Warning"
        Wait-Continue
    }

    if (-not (Execute-UnlockCommand))
    {
        return
    }

    Write-Host ""
    Write-Log "Executing commands: ${cCyan}fastboot flashing unlock_critical${cReset}" "Action"
    & $FASTBOOT flashing unlock_critical
    Write-Host ""
    Write-Log "Executing commands: ${cCyan}fastboot flashing unlock${cReset}" "Action"
    & $FASTBOOT flashing unlock
    Write-Host ""
    Write-Log "Executing commands: ${cCyan}fastboot oem setenforce 0${cReset}" "Action"
    & $FASTBOOT oem setenforce 0

    Write-Host ""
    if (IsFastbootUnlocked)
    {
        Write-Log "Bootloader status confirmed: ${cGreen}UNLOCKED${cReset}" "Success"
        Write-Log "Unplug the device and plug it back in before continuing." "Warning"
    }
    else
    {
        Write-Log "Device does not report as fully unlocked. You may need to repeat the process." "Error"
    }

    Wait-Continue
    if(Verify-FastbootState "unlock")
    {
        Show-FastbootFinalInstruction
    }
}

function Perform-FastbootLock
{
    Write-Header "Performing Lock Bootloader"
    Write-Log "This step will reboot your device into ${cCyan}FASTBOOT${cReset} mode to lock bootloader." "Warning"
    Write-Log "If bootloader is in ${cGreen}Unlocked${cReset} state, this process will factory reset device data." "Warning"
    Write-Log "Recommended to do a backup in the main menu." "Warning"
    Write-Host ""

    Write-Host "`nTo proceed with rebooting to FASTBOOT, type ${cYellow}'YES'${cReset} and press Enter: " -NoNewline
    $confirmation = Read-Host
    if ($confirmation -ne 'YES')
    {
        Write-Log "Reboot to FASTBOOT aborted by user. No changes have been made." "Warning"
        return
    }

    if (IsAdbMode)
    {
        ADB-To-Fastboot
    }
    elseif (-not (IsFastbootMode))
    {
        Warning-FASTBOOT
    }

    if (-not (Wait-FastbootMode 100))
    {
        Warning-FASTBOOT
        return
    }

    # Check current state
    if (IsFastbootUnlocked)
    {
        Write-Log "Bootloader status confirmed: ${cGreen}UNLOCKED${cReset}" "Warning"
        Write-Log "Your device will factory reset after the process." "Warning"
        Wait-Continue
    }

    if (-not (Execute-UnlockCommand))
    {
        return
    }

    $backupPath = Get-LatestAblBackup
    if ($backupPath)
    {
        Write-Log "Flashing original ABL from backup: ${cGreen}$backupPath${cReset}" "Action"
        & $FASTBOOT flash abl $backupPath
    }
    else
    {
        Write-Log "No backup found to restore during lock process. Proceeding with caution." "Warning"
    }

    Write-Host ""
    Write-Log "Executing commands: ${cCyan}fastboot oem setenforce 1${cReset}" "Action"
    & $FASTBOOT oem setenforce 1
    Write-Host ""
    Write-Log "Executing commands: ${cCyan}fastboot flashing lock${cReset}" "Action"
    & $FASTBOOT flashing lock
    Write-Host ""
    Write-Log "Executing commands: ${cCyan}fastboot flashing lock_critical${cReset}" "Action"
    & $FASTBOOT flashing lock_critical

    Write-Host ""
    if (-not (IsFastbootUnlocked))
    {
        Write-Log "Bootloader status confirmed: ${cGreen}LOCKED${cReset}" "Success"
        Write-Log "Unplug the device and plug it back in before continuing." "Warning"
    }
    else
    {
        Write-Log "Device does not report as fully locked. You may need to repeat the process." "Error"
    }

    Wait-Continue

    if(Verify-FastbootState "lock")
    {
        Show-FastbootFinalInstruction
    }
}

function Show-FastbootFinalInstruction
{
    Write-Header "Bootloader Finalizing"
    Write-Log "!!! CRITICAL NEXT STEP !!!" "Warning"
    Write-Log "If you want to root the device (${cCyan}Option 4${cReset}), do it before flash backup ABL." "Warning"
    Write-Host ""
    Write-Log "Check your device screen to confirm the current bootloader state." "Info"
    Write-Log "After rebooting, you will likely be prompted to perform a ${cYellow}factory reset${cReset}. This is expected." "Info"
    Write-Log "After the factory reset, your device will boot normally." "Info"
    Write-Host ""
    Write-Log "If device does not boot normally, hold ${cYellow}Vol Up + Power${cReset} until the robot shows up as recovery mode." "Warning"
    Write-Log "In recovery mode, hold ${cYellow}Power${cReset} first then press ${cYellow}Vol Up${cReset} to access the menu." "Warning"
    Write-Log "Use ${cYellow}Vol Up and Vol Down${cReset} to navigate, and press ${cYellow}Power${cReset} to select ${cCyan}Wipe data/factory reset${cReset}." "Warning"
    Wait-Continue

    if (-not (Wait-FastbootMode 100))
    {
        Warning-FASTBOOT
        return
    }

    Fastboot-To-System
}

function Verify-FastbootState([string]$state)
{
    # Normalize state check
    $isCheckUnlock = $state -match "^unlock"
    $actionName = if ($isCheckUnlock) { "Verify Unlock" } else { "Verify Lock" }

    Write-Header $actionName

    if(IsFastbootMode)
    {
        Fastboot-To-Fastboot
    }
    elseif (IsAdbMode){
        ADB-To-Fastboot
    }
    else{
        Warning-FASTBOOT
    }

    if (-not (Wait-FastbootMode 100))
    {
        Warning-FASTBOOT
        return $null
    }

    $isUnlocked = IsFastbootUnlocked

    if ($null -eq $isUnlocked)
    {
        $statusText = if ($isCheckUnlock) { "${cGreen}'UNLOCKED'${cReset}" } else { "${cYellow}'LOCKED'${cReset}" }
        Write-Log "Unable to automatically detect bootloader state via fastboot." "Warning"
        Write-Log "Please check your device screen. The bootloader menu should now show $statusText." "Warning"
        
        Wait-Continue
        return $null
    }

    # Determine if actual device state matches desired state
    $desiredState = if ($isCheckUnlock) { $true } else { $false }
    $isSuccess = ($isUnlocked -eq $desiredState)
    $statusText = if ($isUnlocked) { "UNLOCKED" } else { "LOCKED" }

    if ($isSuccess)
    {
        Write-Log "Bootloader status confirmed: ${cGreen}$statusText${cReset}" "Success"
    }
    else
    {
        Write-Log "Bootloader is still ${cRed}$statusText${cReset}." "Error"
        Write-Log "It is known that the unlock bits (written to protected RPMB storage) might not 'stick' immediately." "Info"
        Write-Log "Try a different USB port and cable, unplug the headset and plug it back in." "Info"
        Write-Log "You may need to repeat the process." "Info"
    }

    Wait-Continue

    return $isSuccess
}

function IsFastbootUnlocked
{
    # Primary Check: fastboot oem device-info
    Write-Log "Checking bootloader status using ${cCyan}fastboot oem device-info${cReset}..." "Action"
    $deviceInfoRaw = & $FASTBOOT oem device-info 2>&1
    $deviceInfo = $deviceInfoRaw -join "`n"
    Write-Host $deviceInfo

    if ($deviceInfo -match "Device\s*Unlocked\s*[:=]\s*true")
    {
        return $true
    }
    elseif ($deviceInfo -match "Device\s*Unlocked\s*[:=]\s*false")
    {
        return $false
    }

    # Fallback Check: fastboot getvar unlocked
    Write-Log "OEM command unrecognized/unparseable." "Warning"
    Write-Log "Checking with ${cCyan}fastboot getvar unlocked${cReset}..." "Action"
    $unlockedVarRaw = & $FASTBOOT getvar unlocked 2>&1
    $unlockedVar = $unlockedVarRaw -join "`n"
    Write-Host $unlockedVar

    if ($unlockedVar -match "unlocked:\s*yes")
    {
        return $true
    }
    elseif ($unlockedVar -match "unlocked:\s*no")
    {
        return $false
    }

    # Unknown or unparseable output
    return $null
}

# --------------------------------
# ---- Main Script Execution -----
# --------------------------------

if (-not (Test-Path $LogsPath))
{
    New-Item -ItemType Directory -Path $LogsPath  | Out-Null
}
$LogFile = "$LogsPath\${TimeStamp}_console.log"
Start-Transcript -Path $LogFile -Append

try
{
    if (Check-Prerequisites)
    {
        Clear-Host
    }

    $quit = $false
    while (-not $quit)
    {
        Write-Header "PicoUnlock Main Menu"

        Write-Host " [${cCyan}1${cReset}] Generate UnlockCode"
        Write-Host " [${cCyan}2${cReset}] Flash Engineering ABL"
        Write-Host " [${cCyan}3${cReset}] Unlock bootloader"
        Write-Host " [${cCyan}4${cReset}] Root ${cDarkGray}(Superuser)${cReset}"
        Write-Host " [${cCyan}5${cReset}] Flash backup ABL ${cDarkGray}(Fix slow boot, EDL boot)${cReset}"
        Write-Host ""
        Write-Host " [${cCyan}l${cReset}] Lock bootloader"
        Write-Host " [${cCyan}r${cReset}] Reboot"
        Write-Host " [${cCyan}b${cReset}] Backup/Resotre"
        Write-Host " [${cCyan}0${cReset}] Exit"

        $choice = Read-Host "`nSelect an option"

        switch ($choice)
        {
            "1" {
                Generate-UnlockCode
            }
            "2" {
                Select-Firehose
                Flash-EngineeringAbl
            }
            "3" {
                Perform-FastbootUnlock
            }
            "4" {
                Show-RootMenu
            }
            "5" {
                Select-Firehose
                Restore-OriginalAbl
            }
            "l" {
                Perform-FastbootLock
            }
            "r" {
                Perform-Reboot
            }
            "b" {
                Show-BackupRestoreMenu
            }
            "0" {
                $quit = $true
            }
            default {
                Write-Log "Invalid option. Please try again." "Warning"
            }
        }
        if (-not $quit)
        {
            Wait-Continue "return to the menu..."
        }
    }
}
catch
{
    Write-Log "An unexpected error occurred: $_" "Error"
}
finally
{
    Write-Header "Exited"
    Write-Log "Version: 1.0.3" "Info"

    try
    {
        Stop-Transcript
    }
    catch
    {
    }
    try
    {
        Clean-LogFormat -LogFile $LogFile
    }
    catch
    {
    }
}
