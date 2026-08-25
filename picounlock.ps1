#Requires -Version 5.1

<#
.SYNOPSIS
    Automates the bootloader unlock process for Pico 4 devices.
.DESCRIPTION
    This script follows the steps outlined in more-picohaxx.py to unlock the bootloader.
    It handles getting the serial number, generating the unlock code, downloading necessary files,
    and executing the required edl and fastboot commands.

    WARNING:
    - Unlocking the bootloader will wipe your data partition. BACKUP YOUR DATA.
    - This is a complex process. Proceed only if you are familiar with adb, edl, and fastboot.
    - The script authors and I are not responsible for any damage to your device.

.NOTES
    Prerequisites:
    - adb.exe and fastboot.exe must be in your PATH or the script's directory.
    - qdl.exe (from https://github.com/linux-msm/qdl) must be in the script's directory.
    - python must be installed and in your PATH.
    - The 'more-picohaxx.py' script must be in the same directory.
#>

# --- Script Configuration ---
$PicoHaxxPyScript = ".\more-picohaxx.py"
$DRIVER = ".\tools\qdl-driver"

$FirehosePath = ".\tools\firehoses\prog_firehose_ddr.elf"
$AblPath = ".\tools\engineering\abl.elf"
$AblBackupPath = ".\device-backup"

$QDL = ".\tools\qdl.exe"
$ADB = ".\tools\adb.exe"
$FASTBOOT = ".\tools\fastboot.exe"

# --- Helper Functions ---

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

function Check-Prerequisites {
   Write-Host "--- Running Prerequisite Checks ---"
   if (-not (Test-Path $ADB) -and -not (Test-CommandExists "adb")) { Write-Error "$ADB not found. Please add it to your PATH or place it in the script
 directory."; return }
   if (-not (Test-Path $FASTBOOT) -and -not (Test-CommandExists "fastboot")) { Write-Error "$FASTBOOT not found. Please add it to your PATH or place i
t in the script directory."; return }
   if (-not (Test-Path $QDL)) { Write-Error "qdl.exe not found. Please place it in the script directory."; return }
   if (-not (Test-CommandExists "python")) { Write-Error "python not found. Please install Python and add it to your PATH."; return }
   if (-not (Test-Path $PicoHaxxPyScript)) { Write-Error "'$PicoHaxxPyScript' not found in the script directory."; return }
   if (-not (Test-Path $AblPath)) { Write-Error "'$AblPath' not found. Please download it and place it correctly."; return }
   if (-not (Test-Path $FirehosePath)) { Write-Error "'$FirehosePath' not found. Please download it and place it correctly."; return }
   Write-Host "All prerequisites found." -ForegroundColor Green
   Write-Host ""

   # Check for EDL driver and offer to install it
   $driverInf = "qdl_winusb.inf"
   $driverInstalled = (pnputil /enum-drivers) -join "`n" | Select-String -Pattern $driverInf -Quiet
   if (-not $driverInstalled) {
      Write-Warning "The WinUSB driver for EDL mode (Qualcomm 9008) does not appear to be installed."
      Write-Host "This is required for flashing the bootloader."
      $choice = Read-Host "Press Y to install the driver now, or N to skip (Requires Administrator privileges)"
      if ($choice -eq 'Y') {
         $installScript = Join-Path $DRIVER "install.ps1"
         if (-not (Test-Path $installScript)) {
            Write-Error "Driver installation script not found at '$installScript'."
            return
         }

         # Start the install script elevated
         Write-Host "Launching driver installer..."
         Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$installScript`"" -Verb RunAs -Wait

         Write-Host "Driver installation process finished. Re-checking for driver..."
         if (-not ((pnputil /enum-drivers) -join "`n" | Select-String -Pattern $driverInf -Quiet)) {
            Write-Error "Driver still not found. Please run '$installScript' manually as Administrator and then re-run this script."
            return
         }
         Write-Host "Driver successfully installed." -ForegroundColor Green
      } else {
         Write-Warning "Skipping driver installation. The script may fail if the driver is not installed correctly."
      }
   }
}

function Invoke-PicoHaxxScript {
   # Run the python script and capture the unlock command
   $unlockCommand = (python $PicoHaxxPyScript | Select-String -Pattern "fastboot oem pico").Line
   if (-not $unlockCommand) {
      Write-Error "Failed to generate unlock code using the python script."
      return $null
   }
   Write-Host "Generated Unlock Command: $unlockCommand" -ForegroundColor Green
   Write-Host ""

   return $unlockCommand
}

function Generate-UnlockCode {
   Write-Host "--- Generating Unlock Code ---"
   Write-Host "Please connect your Pico device via USB and ensure USB debugging is enabled."
   Read-Host "Press Enter to continue..."

   $serialNumber = (& $ADB shell "cat /sys/devices/soc0/serial_number").Trim()
   if (-not ($serialNumber -match "^\d+$")) {
      Write-Error "Failed to get a valid serial number from the device. Is it connected and authorized?"
      return
   }
   Write-Host "Device serial number: $serialNumber"

   # Modify the python script to use the correct serial
   (Get-Content $PicoHaxxPyScript) -replace 'pico_unlock\(\d+\)', "pico_unlock($serialNumber)" | Set-Content $PicoHaxxPyScript
}

function Flash-EngineeringAbl {
   Write-Host "--- Flashing Engineering ABL via EDL ---"
   Write-Warning "This step will reboot your device into EDL (Emergency Download) mode to flash a new bootloader."
   Write-Warning "This is a critical part of the unlock process."
   $rebootConfirmation = Read-Host "To proceed with rebooting to EDL, type 'YES' and press Enter"
   if ($rebootConfirmation -ne 'YES') {
      Write-Error "Reboot to EDL aborted by user. No changes have been made."
      return
   }

   # Create backup directory if it doesn't exist
   if (-not (Test-Path $AblBackupPath)) {
      New-Item -Path $AblBackupPath -ItemType Directory | Out-Null
   }

   # Reboot EDL
   if (IsAdbMode) {
      Write-Host "Device detected in ADB mode. Attempting to reboot into EDL mode..."
      & $ADB reboot edl
   }

   Write-Host "Waiting for device to enter EDL mode (Qualcomm 9008)..."
   $timeout = 30
   $deviceDetected = $false
   foreach ($i in 1..$timeout) {
      if (IsEdlMode) {
         Write-Host "`rEDL device detected.                                 " -ForegroundColor Green
         Start-Sleep -Seconds 5 # Wait a moment for the device and driver to be fully ready
         $deviceDetected = $true
         break
      }
      Write-Host "`r  ...waiting ($i/$timeout) " -NoNewline
      Start-Sleep -Seconds 1
   }
   Write-Host ""
   if (-not $deviceDetected) {
      Write-Error "Device not detected in EDL mode. Please ensure drivers are installed (run qdl-driver\install.ps1 as Admin) and manually boot to EDL
 (Hold Vol Up + Vol Down + Power from off state), then re-run this script."
      return
   }

   # Find the next available backup folder index
   $index = 1
   while (Test-Path (Join-Path $AblBackupPath $index)) {
      $index++
   }
   $currentBackupPath = Join-Path $AblBackupPath $index
   New-Item -Path $currentBackupPath -ItemType Directory | Out-Null
   $backupFile = Join-Path $currentBackupPath "abl.bin"

   Write-Host "Backing up original abl and flashing engineering abl in a single operation..."
   & $QDL --storage ufs --include (Split-Path $FirehosePath -Parent) $FirehosePath read abl $backupFile write abl $AblPath
   if ($LASTEXITCODE -ne 0) {
      Write-Error "The combined backup and flash operation failed. Your device may be in an unusable state. Check if a backup was created at '$backupFile' and attempt a manual restore if necessary."
      return
   }
   Write-Host "Original abl backed up to '$backupFile' (in folder '$index')." -ForegroundColor Green
   Write-Host "Engineering abl flashed successfully in the same operation." -ForegroundColor Green
}

function Perform-FastbootUnlock {
   Write-Host "--- Performing Unlock Bootloader ---"
   Write-Host "The device may not boot normally now. Please manually boot it into Fastboot mode."
   Write-Host " (Typically: Hold Vol Down + Power from a powered-off state)"
   Read-Host "Press Enter when your device is in Fastboot mode..." | Out-Null

   Write-Host "Executing unlock commands..."
   Invoke-Expression Invoke-PicoHaxxScript
   & $FASTBOOT oem setenforce 0
   & $FASTBOOT flashing unlock
   & $FASTBOOT flashing unlock_critical

   Write-Host "Checking device unlock status..."
   $deviceInfo = & $FASTBOOT oem device-info 2>&1
   Write-Host $deviceInfo
   if (($deviceInfo -like "*Device unlocked: true*") -and ($deviceInfo -like "*Device critical unlocked: true*")) {
      Write-Host "Device unlock status confirmed!" -ForegroundColor Green
   } else {
      Write-Warning "Device does not report as fully unlocked. You may need to repeat the process."
   }
   Write-Host ""
}

function Verify-Unlock {
   Write-Host "--- Rebooting Bootloader to Verify ---"
   Write-Host "Rebooting to bootloader to check if the unlock persists."
   & $FASTBOOT reboot bootloader
   Write-Host "Please check your device screen. The bootloader menu should now show 'UNLOCKED'."
   Write-Host "If it still shows 'LOCKED', you may need to run this script again." -ForegroundColor Yellow
   Read-Host "Press Enter to continue to the final step..." | Out-Null
   Write-Host ""
}

function Show-FinalInstructions {
   Write-Host "--- Finalizing ---"
   Write-Host "Your bootloader should now be unlocked."
   Write-Host "Attempt a normal boot ('& $FASTBOOT reboot'). You will likely be prompted to perform a factory reset. This is expected."
   Write-Host "After the factory reset, your device will be unlocked and boot normally."
   Write-Host "!!! CRITICAL FINAL STEP !!!" -ForegroundColor Red
   Write-Host "It is highly recommended to flash back your original bootloader (abl) from your backup folder."
   Write-Host "You can do this using Option 3 in the main menu."
   Write-Host ""
   Write-Host "Unlock process complete. Enjoy!" -ForegroundColor Cyan
}

function Get-LatestBackupPath {
   [CmdletBinding()]
   param (
      [string]$FileName = "abl.bin"
   )
   process {
      if (-not (Test-Path -Path $AblBackupPath -PathType Container)) {
         Write-Error "The specified backup directory '$AblBackupPath' does not exist."
         return $null
      }
      $highestFolder = Get-ChildItem -Path $AblBackupPath -Directory |
         Where-Object { $_.Name -match '^\d+$' } |
         Sort-Object { [int]$_.Name } -Descending |
         Select-Object -First 1
      if ($highestFolder) {
         return Join-Path -Path $highestFolder.FullName -ChildPath $FileName
      } else {
         Write-Error "No numeric backup folders found in '$AblBackupPath'."
         return $null
      }
   }
}

function Restore-OriginalAbl {
   Write-Host "--- Restoring Original ABL via EDL ---"
   Write-Host "This fix resolves issues like slow reboots and unwanted booting into EDL mode."
   Write-Host "SELinux will return to Enforcing mode, using https://github.com/evdenis/selinux_permissive to change back to Permissive mode"
   $backupPath = Get-LatestBackupPath
   if (-not $backupPath) { return }

   Write-Host "Target backup file: $backupPath"
   $confirmation = Read-Host "Are you sure you want to flash this backup? (Type 'YES')"
   if ($confirmation -ne 'YES') { return }

   if (IsAdbMode) {
      Write-Host "Device detected in ADB mode. Attempting to reboot into EDL mode..."
      & $ADB reboot edl
   }

   Write-Host "Waiting for device to enter EDL mode (Qualcomm 9008)..."
   $timeout = 30
   $deviceDetected = $false
   foreach ($i in 1..$timeout) {
      if (IsEdlMode) {
         Write-Host "`rEDL device detected.                                 " -ForegroundColor Green
         Start-Sleep -Seconds 5
         $deviceDetected = $true
         break
      }
      Write-Host "`r  ...waiting ($i/$timeout) " -NoNewline
      Start-Sleep -Seconds 1
   }
   Write-Host ""

   if ($deviceDetected) {
      & $QDL --storage ufs --include (Split-Path $FirehosePath -Parent) $FirehosePath write abl $backupPath
      if ($LASTEXITCODE -eq 0) {
         Write-Host "Backup restored successfully!" -ForegroundColor Green
      } else {
         Write-Error "Failed to restore backup."
      }
   } else {
      Write-Error "Device not detected in EDL mode."
   }
}

function Perform-FastbootLock {
   Write-Host "--- Performing Lock Bootloader ---"
   Write-Host "The device may not boot normally now. Please manually boot it into Fastboot mode."
   Write-Host " (Typically: Hold Vol Down + Power from a powered-off state)"
   Read-Host "Press Enter when your device is in Fastboot mode..." | Out-Null

   Write-Host "Executing lock commands..."
   # Authorization may be required even for locking on some engineering builds
   Invoke-Expression Invoke-PicoHaxxScript

   $backupPath = Get-LatestBackupPath
   if ($backupPath) {
      Write-Host "Flashing original ABL from backup: $backupPath"
      & $FASTBOOT flash abl $backupPath
   } else {
      Write-Warning "No backup found to restore during lock process. Proceeding with caution."
   }

   & $FASTBOOT oem setenforce 1
   & $FASTBOOT flashing lock
   & $FASTBOOT flashing lock_critical

   Write-Host "Checking device lock status..."
   $deviceInfo = & $FASTBOOT oem device-info 2>&1
   Write-Host $deviceInfo
   if (($deviceInfo -like "*Device locked: false*") -and ($deviceInfo -like "*Device critical locked: false*")) {
      Write-Host "Device lock status confirmed!" -ForegroundColor Green
   } else {
      Write-Warning "Device does not report as fully locked. You may need to repeat the process."
   }
   Write-Host ""
}

function Verify-Lock {
   Write-Host "--- Rebooting Bootloader to Verify ---"
   Write-Host "Rebooting to bootloader to check the lock state."
   & $FASTBOOT reboot bootloader
   Write-Host "Please check your device screen for the current lock state."
   Write-Host "Verify if the bootloader status reads 'UNLOCKED' or 'LOCKED'." -ForegroundColor Yellow
   Read-Host "Press Enter to continue to the final step..." | Out-Null
   Write-Host ""
}

function Show-LockFinalInstructions {
   Write-Host "--- Finalizing Lock ---"
   Write-Host "Check your device screen to confirm the current lock state."
   Write-Host "Attempt a normal boot ('& $FASTBOOT reboot'). You will likely be prompted to perform a factory reset. This is expected."
   Write-Host "After the factory reset, check the bootloader state again in settings or bootloader mode to verify."
   Write-Host "Lock process complete." -ForegroundColor Cyan
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
      Write-Host "`n=== PicoUnlock Main Menu ===" -ForegroundColor Cyan
      Write-Host "1. Flash Engineering ABL"
      Write-Host "2. Perform unlock bootloader"
      Write-Host "3. Flash backup ABL - Fix slow reboot, fix boot into EDL"
      Write-Host "4. Perform lock bootloader"
      Write-Host "0. Exit"

      $choice = Read-Host "`nSelect an option"

      switch ($choice) {
         "1" {
            if (IsAdbMode) { Generate-UnlockCode }
            Flash-EngineeringAbl
         }
         "2" {
            Perform-FastbootUnlock
            Verify-Unlock
            Show-FinalInstructions
         }
         "3" {
            Restore-OriginalAbl
         }
         "4" {
            if (IsAdbMode) { Generate-UnlockCode }
            Perform-FastbootLock
            Verify-Lock
            Show-LockFinalInstructions
         }
         "0" {
            $quit = $true
         }
         default {
            Write-Warning "Invalid option. Please try again."
         }
      }
      if (-not $quit) {
         Read-Host "Press Enter to return to the menu..."
      }
   }
} catch {
   Write-Error "An unexpected error occurred: $_"
} finally {
   Stop-Transcript
}
