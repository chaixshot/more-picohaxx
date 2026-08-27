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
    - python must be installed and in your PATH.
    - The 'more-picohaxx.py' script must be in the same directory.
    - Magisk4Pico.apk must be in the .\tools directory for rooting.
#>

# --- Script Configuration ---
$PicoHaxxPyScript = ".\more-picohaxx.py"
$DRIVER = ".\tools\qdl-driver"
$Picounlock = ".\picounlock.txt"

$FirehoseDDR4Path = (Get-Item ".\tools\firehoses\prog_firehose_ddr.elf").FullName
$FirehoseDDR5Path = (Get-Item ".\tools\firehoses\prog_firehose_lite.elf").FullName
$FirehoseTargetPath = $null

$AblPath = ".\tools\engineering\abl.elf"
$DevInfoPath = ".\tools\engineering\devinfo"
$AblBackupPath = ".\abl-backup"

$QDL = ".\tools\qdl.exe"
$ADB = ".\tools\adb.exe"
$FASTBOOT = ".\tools\fastboot.exe"

$script:PatchedImagePath = $null

# --- Helper Functions ---
. "$PSScriptRoot/modules/utils.ps1"
. "$PSScriptRoot/modules/root.ps1"
. "$PSScriptRoot/modules/backuprestore.ps1"


function Check-Prerequisites {
   Write-Header "Running Prerequisite Checks"
   if (-not (Test-Path $ADB) -and -not (Test-CommandExists "adb")) {
      Write-Log "${cYellow}$ADB${cReset} not found. Please add it to your ${cCyan}PATH${cReset} or place it in the script directory." "Error"
      return
   }
   if (-not (Test-Path $FASTBOOT) -and -not (Test-CommandExists "fastboot")) {
      Write-Log "${cYellow}$FASTBOOT${cReset} not found. Please add it to your ${cCyan}PATH${cReset} or place it in the script directory." "Error"
      return
   }
   if (-not (Test-Path $QDL)) {
      Write-Log "${cYellow}qdl.exe${cReset} not found. Please place it in the script directory." "Error"
      return
   }
   if (-not (Test-CommandExists "python")) {
      Write-Log "${cCyan}python${cReset} not found. Please install Python and add it to your ${cCyan}PATH${cReset}." "Error"
      return
   }
   if (-not (Test-Path $PicoHaxxPyScript)) {
      Write-Log "'${cYellow}$PicoHaxxPyScript${cReset}' not found in the script directory." "Error"
      return
   }
   if (-not (Test-Path $AblPath)) {
      Write-Log "'${cYellow}$AblPath${cReset}' not found. Please download it and place it correctly." "Error"
      return
   }
   if (-not (Test-Path $FirehoseDDR4Path)) {
      Write-Log "'${cYellow}$FirehoseDDR4Path${cReset}' not found. Please download it and place it correctly." "Error"
      return
   }
   if (-not (Test-Path $FirehoseDDR5Path)) {
      Write-Log "'${cYellow}$FirehoseDDR5Path${cReset}' not found. Please download it and place it correctly." "Error"
      return
   }
   Write-Log "All prerequisites found." "Success"
   Write-Host ""

   # Check for EDL driver and offer to install it
   $driverInstalled = (pnputil /enum-drivers) -join "`n" -match "qcser\.inf"
   if (-not $driverInstalled) {
      Write-Log "The WinUSB driver for ${cCyan}EDL mode (Qualcomm 9008)${cReset} does not appear to be installed." "Warning"
      Write-Log "This is required for flashing the ${cYellow}bootloader${cReset}." "Info"
      Write-Host "Press ${cCyan}Y${cReset} to install the driver now, or ${cYellow}N${cReset} to skip (Requires Administrator privileges): " -NoNewline

      $choice = Read-Host
      if ($choice -eq 'Y' -or $choice -eq 'y') {
         $installScript = Join-Path $DRIVER "install.ps1"
         if (-not (Test-Path $installScript)) {
            Write-Log "Driver installation script not found at '${cYellow}$installScript${cReset}'." "Error"
            return
         }

         # Start the install script elevated
         Write-Log "Launching driver installer..." "Action"
         Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$installScript`"" -Verb RunAs -Wait

         Write-Log "Driver installation process finished. Re-checking for driver..." "Info"
         if (-not ((pnputil /enum-drivers) -join "`n" | Select-String -Pattern $driverPattern -Quiet)) {
            Write-Log "Driver still not found. Please run '${cYellow}$installScript${cReset}' manually as ${cCyan}Administrator${cReset} and then re-run this script." "Error"
            return
         }
         Write-Log "Driver successfully installed." "Success"
      }
      else {
         Write-Log "Skipping driver installation. The script may fail if the driver is not installed correctly." "Warning"
      }

      Wait-Continue
   }

   Clear-Host
}


function Generate-UnlockCode {
   Clear-Host
   Write-Header "Generating Unlock Code"

   if (-not (IsAdbMode)) {
      Write-Log "Device not detected in ${cCyan}ADB${cReset} mode. Please connect your device and enable ${cYellow}USB debugging${cReset}." "Error"
      Wait-Continue
      return
   }

   $serialNumber = (& $ADB shell "cat /sys/devices/soc0/serial_number").Trim()
   if (-not ($serialNumber -match "^\d+$")) {
      Write-Log "Failed to get a valid serial number from the device. Is it connected and authorized?" "Error"
      Wait-Continue
      return
   }
   Write-Log "Device serial number: ${cGreen}$serialNumber${cReset}" "Success"

   # Modify the python script to use the correct serial
   (Get-Content $PicoHaxxPyScript) -replace 'pico_unlock\(\d+\)', "pico_unlock($serialNumber)" | Set-Content $PicoHaxxPyScript
}

function Flash-EngineeringAbl {
   Clear-Host
   Write-Header "Flashing Engineering ABL & Devinfo via EDL"
   Write-Log "This step will reboot your device into ${cCyan}EDL (Emergency Download)${cReset} mode to flash engineering files." "Warning"
   Write-Log "This is a critical part of the unlock process." "Warning"

   Write-Host "`nTo proceed with rebooting to EDL, type ${cYellow}'YES'${cReset} and press Enter: " -NoNewline
   $rebootConfirmation = Read-Host
   if ($rebootConfirmation -ne 'YES') {
      Write-Log "Reboot to EDL aborted by user. No changes have been made." "Warning"
      return
   }

   Select-Firehose

   # Create backup directory if it doesn't exist
   if (-not (Test-Path $AblBackupPath)) {
      New-Item -Path $AblBackupPath -ItemType Directory | Out-Null
   }

   # Reboot EDL
   if (IsAdbMode) {
      Write-Log "Device detected in ${cCyan}ADB${cReset} mode. Attempting to reboot into ${cCyan}EDL${cReset} mode..." "Info"
      & $ADB reboot edl
   }
   elseif (-not (IsEdlMode)) {
      Write-Log "Device not detected in ${cCyan}ADB${cReset} mode. Please connect your device and enable ${cYellow}USB debugging${cReset}." "Error"
      Write-Log "Please ensure drivers are installed (run ${cYellow}qdl-driver\install.ps1${cReset} as Admin)." "Error"
      Write-Log "Manually boot to EDL (Hold ${cYellow}Vol Up + Vol Down + Power${cReset} from off state), then re-run this script." "Error"
   }

   if (-not (Wait-EdlMode 100))
   {
      Write-Log "Device not detected in EDL mode." "Error"
      Write-Log "Hold ${cYellow}Vol Up + Vol Down + Power${cReset} from off state to enter EDL." "Info"
      return
   }

   # Create a timestamped backup folder
   $folderName = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
   $currentBackupPath = Join-Path $AblBackupPath $folderName
   New-Item -Path $currentBackupPath -ItemType Directory | Out-Null
   $backupAbl = Join-Path $currentBackupPath "abl.bin"
   $backupDevInfo = Join-Path $currentBackupPath "devinfo.bin"

   Write-Log "Backing up original partitions and flashing engineering files in a single operation..." "Action"
   & $QDL --storage ufs --include (Split-Path $FirehoseTargetPath -Parent) $FirehoseTargetPath read abl $backupAbl read devinfo $backupDevInfo write abl $AblPath write devinfo $DevInfoPath
   if ($LASTEXITCODE -ne 0) {
      Write-Log "The combined backup and flash operation failed. Your device may be in an unusable state. Check if backups were created in '${cYellow}$currentBackupPath${cReset}' and attempt a manual restore if necessary." "Error"
      return
   }
   Write-Log "Original partitions backed up to ${cGreen}'$currentBackupPath'${cReset}." "Success"
   Write-Log "Engineering ABL and Devinfo flashed successfully." "Success"
}

function Perform-FastbootUnlock {
   Clear-Host
   Write-Header "Performing Unlock Bootloader"

   if (IsAdbMode) {
      Write-Log "Device detected in ${cCyan}ADB${cReset} mode. Attempting to reboot into ${cCyan}bootloader${cReset} mode..." "Info"
      & $ADB reboot bootloader
   }
   elseif (-not (IsFastbootMode)) {
      Write-Log "Device not detected in ${cCyan}FASTBOOT${cReset} mode. Please ensure it's connected and in bootloader mode." "Error"
      Write-Host " (Typically: Hold ${cYellow}Vol Down + Power${cReset} from a powered-off state)"
   }

   if (-not (Wait-FastbootMode 100)) {
      Write-Log "Device not detected in ${cCyan}FASTBOOT${cReset} mode." "Error"
      return
   }

   Write-Log "Executing unlock commands..." "Action"
   Invoke-Expression Invoke-PicoHaxxScript
   & $FASTBOOT oem setenforce 0
   & $FASTBOOT flashing unlock
   & $FASTBOOT flashing unlock_critical

   Write-Log "Checking device unlock status..." "Info"
   $deviceInfo = & $FASTBOOT oem device-info 2>&1
   Write-Host $deviceInfo
   if (($deviceInfo -like "*Device unlocked: true*") -and ($deviceInfo -like "*Device critical unlocked: true*")) {
      Write-Log "Device unlock status confirmed: ${cGreen}UNLOCKED${cReset}!" "Success"
   }
   else {
      Write-Log "Device does not report as fully unlocked. You may need to repeat the process." "Warning"
   }
   
   Wait-Continue
   Verify-Unlock
   Show-UnlockFinalInstructions
}

function Verify-Unlock {
   Clear-Host
   Write-Header "Verify Unlock"
   Write-Log "Rebooting to ${cCyan}bootloader${cReset} to check if the unlock persists." "Info"
   & $FASTBOOT reboot bootloader

   if (-not (Wait-FastbootMode 100)) {
      Write-Log "Device not detected in ${cCyan}FASTBOOT${cReset} mode." "Error"
      return
   }

   Write-Log "Checking unlock status with ${cCyan}fastboot getvar unlocked${cReset}..." "Info"
   $unlockedVar = (& $FASTBOOT getvar unlocked 2>&1) -join "`n"
   Write-Host $unlockedVar

   if ($unlockedVar -match "unlocked:\s*yes") {
      Write-Log "Bootloader unlock status confirmed: ${cGreen}UNLOCKED (yes)${cReset}" "Success"
   }
   elseif ($unlockedVar -match "unlocked:\s*no") {
      Write-Log "Bootloader is still ${cRed}LOCKED (no)${cReset}. You may need to repeat the unlock process." "Warning"
   }
   else {
      Write-Log "Please check your device screen. The bootloader menu should now show ${cGreen}'UNLOCKED'${cReset}." "Info"
   }

   Wait-Continue
}

function Show-UnlockFinalInstructions {
   Clear-Host
   Write-Header "Finalizing"
   Write-Log "!!! CRITICAL NEXT STEP !!!" "Warning"
   Write-Log "It is highly recommended to root your device (${cCyan}Option 4${cReset}) before flashing back your original bootloader (${cYellow}abl${cReset}) from your backup folder (${cCyan}Option 5${cReset})." "Warning"
   Write-Log "You can flash back your original abl using ${cCyan}Option 5${cReset} in the main menu." "Info"
   Write-Host ""
   Write-Log "After rebooting, you will likely be prompted to perform a ${cYellow}factory reset${cReset}. This is expected." "Info"
   Write-Log "After the factory reset, your device will boot normally." "Info"

   if (Wait-FastbootMode 100) {
      Write-Log "Rebooting device to ${cCyan}system${cReset}..." "Action"
      & $FASTBOOT reboot
   }
   else {
      Write-Log "Device not detected in ${cCyan}FASTBOOT${cReset} mode. Please reboot manually." "Error"
   }
}

function Get-LatestBackupPath {
   [CmdletBinding()]
   param (
      [string]$FileName = "abl.bin"
   )
   process {
      if (-not (Test-Path -Path $AblBackupPath -PathType Container)) {
         Write-Log "The specified backup directory '${cYellow}$AblBackupPath${cReset}' does not exist." "Error"
         return $null
      }
      $folders = Get-ChildItem -Path $AblBackupPath -Directory |
      Where-Object { $_.Name -match '^\d+$|^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$' } |
      Sort-Object -Property LastWriteTime -Descending

      if (-not $folders) {
         Write-Log "No valid backup folders found in '${cYellow}$AblBackupPath${cReset}'." "Error"
         return $null
      }

      if ($folders.Count -gt 1) {
         $selectedFolder = $null
         while (-not $selectedFolder) {
            Write-Host "`nAvailable backup folders:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $folders.Count; $i++) {
               Write-Host " [${cCyan}$i${cReset}] $($folders[$i].Name)"
            }
            Write-Host "`nSelect a backup folder (enter index or folder name, default [${cCyan}0${cReset}] for latest, '${cYellow}c${cReset}' to cancel): " -NoNewline
            $selection = Read-Host

            if ([string]::IsNullOrWhiteSpace($selection)) {
               $selection = "0"
            }

            if ($selection -eq 'c') {
               Write-Log "Operation cancelled." "Warning"
               return $null
            }

            # Check if it matches a folder name directly
            $selectedFolder = $folders | Where-Object { $_.Name -eq $selection } | Select-Object -First 1

            # If not, check if it's an index
            if (-not $selectedFolder -and $selection -match '^\d+$') {
               $index = [int]$selection
               if ($index -ge 0 -and $index -lt $folders.Count) {
                  $selectedFolder = $folders[$index]
               }
            }

            if (-not $selectedFolder) {
               Clear-Host
               Write-Log "Invalid selection '$selection'. Please try again or type 'c' to cancel." "Warning"
            }
         }
         return Join-Path -Path $selectedFolder.FullName -ChildPath $FileName
      }

      return Join-Path -Path $folders[0].FullName -ChildPath $FileName
   }
}

function Restore-OriginalAbl {
   Clear-Host
   Write-Header "Restoring Original Partitions via EDL"
   Write-Log "This fix resolves issues like slow reboots and unwanted booting into ${cCyan}EDL${cReset} mode." "Info"
   Write-Log "SELinux will return to ${cYellow}Enforcing${cReset} mode, using ${cCyan}https://github.com/evdenis/selinux_permissive${cReset} to
change back to Permissive mode" "Info"
   Write-Log "Perform ${cYellow}rooting${cReset} (${cCyan}Option 4${cReset}) before doing this step!" "Warning"

   $backupFolder = Get-LatestBackupPath -FileName ""
   if (-not $backupFolder) { return }
   $backupAbl = Join-Path $backupFolder "abl.bin"
   $backupDevInfo = Join-Path $backupFolder "devinfo.bin"

   Write-Log "Target backup folder: ${cGreen}$backupFolder${cReset}" "Info"
   Write-Host "`nAre you sure you want to flash this backup? (Type ${cYellow}'YES'${cReset}): " -NoNewline
   $confirmation = Read-Host
   if ($confirmation -ne 'YES') {
      Write-Log "Restore aborted by user." "Warning"
      return
   }

   Select-Firehose

   if (IsAdbMode) {
      Write-Log "Device detected in ${cCyan}ADB${cReset} mode. Attempting to reboot into ${cCyan}EDL${cReset} mode..." "Info"
      & $ADB reboot edl
   }

   if (Wait-EdlMode 100) {
      & $QDL --storage ufs --include (Split-Path $FirehoseTargetPath -Parent) $FirehoseTargetPath write abl $backupAbl write devinfo $backupDevInfo
      if ($LASTEXITCODE -eq 0) {
         Write-Log "Original partitions restored successfully!" "Success"
      }
      else {
         Write-Log "Failed to restore backup partitions." "Error"
      }
   }
   else {
      Write-Log "Device not detected in ${cCyan}EDL${cReset} mode." "Error"
   }
}

function Perform-FastbootLock {
   Clear-Host
   Write-Header "Performing Lock Bootloader"

   if (IsAdbMode) {
      Write-Log "Device detected in ${cCyan}ADB${cReset} mode. Attempting to reboot into ${cCyan}bootloader${cReset} mode..." "Info"
      & $ADB reboot bootloader
   }
   elseif (-not (IsFastbootMode)) {
      Write-Log "Device not detected in ${cCyan}FASTBOOT${cReset} mode. Please ensure it's connected and in bootloader mode." "Error"
      Write-Host " (Typically: Hold ${cYellow}Vol Down + Power${cReset} from a powered-off state)"
   }

   if (-not (Wait-FastbootMode 100)) {
      Write-Log "Device not detected in ${cCyan}FASTBOOT${cReset} mode." "Error"
      return
   }

   Write-Log "Executing lock commands..." "Action"
   # Authorization may be required even for locking on some engineering builds
   Invoke-Expression Invoke-PicoHaxxScript

   $backupPath = Get-LatestBackupPath
   if ($backupPath) {
      Write-Log "Flashing original ABL from backup: ${cGreen}$backupPath${cReset}" "Action"
      & $FASTBOOT flash abl $backupPath
   }
   else {
      Write-Log "No backup found to restore during lock process. Proceeding with caution." "Warning"
   }

   & $FASTBOOT oem setenforce 1
   & $FASTBOOT flashing lock
   & $FASTBOOT flashing lock_critical

   Write-Log "Checking device lock status..." "Info"
   $deviceInfo = & $FASTBOOT oem device-info 2>&1
   Write-Host $deviceInfo
   if (($deviceInfo -like "*Device locked: false*") -and ($deviceInfo -like "*Device critical locked: false*")) {
      Write-Log "Device lock status confirmed: ${cGreen}LOCKED${cReset}!" "Success"
   }
   else {
      Write-Log "Device does not report as fully locked. You may need to repeat the process." "Warning"
   }

   Wait-Continue
   Verify-Lock
   Show-LockFinalInstructions
}

function Verify-Lock {
   Clear-Host
   Write-Header "Verify Lock"
   Write-Log "Rebooting to ${cCyan}bootloader${cReset} to check the lock state." "Info"
   & $FASTBOOT reboot bootloader

   if (-not (Wait-FastbootMode 100)) {
      Write-Log "Device not detected in ${cCyan}FASTBOOT${cReset} mode." "Error"
      return
   }

   Write-Log "Checking lock status with ${cCyan}fastboot getvar unlocked${cReset}..." "Info"
   $unlockedVar = (& $FASTBOOT getvar unlocked 2>&1) -join "`n"
   Write-Host $unlockedVar

   if ($unlockedVar -match "unlocked:\s*no") {
      Write-Log "Bootloader lock status confirmed: ${cGreen}LOCKED (no)${cReset}" "Success"
   }
   elseif ($unlockedVar -match "unlocked:\s*yes") {
      Write-Log "Bootloader is still ${cRed}UNLOCKED (yes)${cReset}. You may need to repeat the lock process." "Warning"
   }
   else {
      Write-Log "Please check your device screen for the current lock state (should read ${cYellow}'LOCKED'${cReset})." "Warning"
   }

   Wait-Continue
}

function Show-LockFinalInstructions {
   Clear-Host
   Write-Header "Finalizing Lock"
   Write-Log "Check your device screen to confirm the current lock state." "Info"
   Write-Log "After rebooting, you will likely be prompted to perform a ${cYellow}factory reset${cReset}. This is expected." "Info"
   Write-Log "After the factory reset, check the bootloader state again in settings or bootloader mode to verify." "Info"

   if (Wait-FastbootMode 100) {
      Write-Log "Rebooting device to ${cCyan}system${cReset}..." "Action"
      & $FASTBOOT reboot
   }
   else {
      Write-Log "Device not detected in ${cCyan}FASTBOOT${cReset} mode. Please reboot manually." "Error"
   }
}


# --- Main Script Execution ---

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
if (-not (Test-Path ".\logs")) { New-Item -ItemType Directory -Path ".\logs" | Out-Null }
Start-Transcript -Path ".\logs\$timestamp.log" -Append

try {
   $quit = $false
   while (-not $quit) {
      Clear-Host
      Check-Prerequisites
      Write-Header "PicoUnlock Main Menu"

      Write-Host " [${cCyan}1${cReset}] Generate UnlockCode"
      Write-Host " [${cCyan}2${cReset}] Flash Engineering ABL"
      Write-Host " [${cCyan}3${cReset}] Unlock bootloader"
      Write-Host " [${cCyan}4${cReset}] Root (Superuser)"
      Write-Host " [${cCyan}5${cReset}] Flash backup ABL (Fix slow boot, fix boot into EDL)"
      Write-Host " [${cCyan}6${cReset}] Lock bootloader"
      Write-Host ""
      Write-Host " [${cCyan}r${cReset}] Reboot to System"
      Write-Host " [${cCyan}b${cReset}] Backup/Resotre"
      Write-Host " [${cCyan}0${cReset}] Exit"

      $choice = Read-Host "`nSelect an option"

      switch ($choice) {
         "1" {
            if (IsAdbMode) {
               Generate-UnlockCode
            }
            else {
               Write-Log "Device not detected in ${cCyan}ADB${cReset} mode. Please connect your device and enable ${cYellow}USB debugging${cReset}." "Error"
            }
         }
         "2" {
            Flash-EngineeringAbl
         }
         "3" {
            Perform-FastbootUnlock
         }
         "4" {
            Show-RootMenu
         }
         "5" {
            Restore-OriginalAbl
         }
         "6" {
            Perform-FastbootLock
         }
         "r" {
            Reboot-System
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
      if (-not $quit) {
         Wait-Continue "return to the menu..."
      }
   }
}
catch {
   Write-Log "An unexpected error occurred: $_" "Error"
}
finally {
   Stop-Transcript
}
