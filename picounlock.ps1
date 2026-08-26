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
$Magisk = ".\tools\Magisk4Pico.apk"
$Picounlock = ".\picounlock.txt"

$FirehosePath = ".\tools\firehoses\prog_firehose_ddr.elf"
$AblPath = ".\tools\engineering\abl.elf"
$AblBackupPath = ".\device-backup"

$QDL = ".\tools\qdl.exe"
$ADB = ".\tools\adb.exe"
$FASTBOOT = ".\tools\fastboot.exe"

$script:PatchedImagePath = $null

# --- ANSI Color Codes for Highlights ---
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

# --- Helper Functions ---

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
   if (-not (Test-Path $FirehosePath)) {
      Write-Log "'${cYellow}$FirehosePath${cReset}' not found. Please download it and place it correctly." "Error"
      return
   }
   Write-Log "All prerequisites found." "Success"
   Write-Host ""

   # Check for EDL driver and offer to install it
   $driverPattern = "qdl_winusb\.inf|qcser\.inf"
   $driverInstalled = (pnputil /enum-drivers) -join "`n" | Select-String -Pattern $driverPattern -Quiet
   if (-not $driverInstalled) {
      Write-Log "The WinUSB driver for ${cCyan}EDL mode (Qualcomm 9008)${cReset} does not appear to be installed." "Warning"
      Write-Log "This is required for flashing the ${cYellow}bootloader${cReset}." "Info"
      Write-Host "Press " -NoNewline
      Write-Host "Y" -ForegroundColor Cyan -NoNewline
      Write-Host " to install the driver now, or " -NoNewline
      Write-Host "N" -ForegroundColor Yellow -NoNewline
      Write-Host " to skip (Requires Administrator privileges): " -NoNewline
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
   Write-Header "Flashing Engineering ABL via EDL"
   Write-Log "This step will reboot your device into ${cCyan}EDL (Emergency Download)${cReset} mode to flash a new bootloader." "Warning"
   Write-Log "This is a critical part of the unlock process." "Warning"
   Write-Host "To proceed with rebooting to EDL, type " -NoNewline
   Write-Host "'YES'" -ForegroundColor Yellow -NoNewline
   Write-Host " and press Enter: " -NoNewline
   $rebootConfirmation = Read-Host
   if ($rebootConfirmation -ne 'YES') {
      Write-Log "Reboot to EDL aborted by user. No changes have been made." "Warning"
      return
   }

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

   if (-not (Wait-EdlMode 100)) {
      Write-Log "Device not detected in ${cCyan}EDL${cReset} mode." "Error"
      return
   }

   # Create a timestamped backup folder
   $folderName = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
   $currentBackupPath = Join-Path $AblBackupPath $folderName
   New-Item -Path $currentBackupPath -ItemType Directory | Out-Null
   $backupFile = Join-Path $currentBackupPath "abl.bin"

   Write-Log "Backing up original ${cYellow}abl${cReset} and flashing ${cYellow}engineering abl${cReset} in a single operation..." "Action"
   & $QDL --storage ufs --include (Split-Path $FirehosePath -Parent) $FirehosePath read abl $backupFile write abl $AblPath
   if ($LASTEXITCODE -ne 0) {
      Write-Log "The combined backup and flash operation failed. Your device may be in an unusable state. Check if a backup was created at '${cYellow}$backupFile${cReset}' and attempt a manual restore if necessary." "Error"
      return
   }
   Write-Log "Original abl backed up to ${cGreen}'$backupFile'${cReset} (in folder '${cCyan}$folderName${cReset}')." "Success"
   Write-Log "Engineering abl flashed successfully in the same operation." "Success"
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
      Write-Host " (Typically: Hold " -NoNewline
      Write-Host "Vol Down + Power" -ForegroundColor Yellow -NoNewline
      Write-Host " from a powered-off state)"
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
               Write-Host " [" -NoNewline -ForegroundColor DarkGray
               Write-Host "$i" -NoNewline -ForegroundColor Cyan
               Write-Host "] " -NoNewline -ForegroundColor DarkGray
               Write-Host "$($folders[$i].Name)"
            }
            Write-Host "`nSelect a backup folder (enter index or folder name, default [" -NoNewline
            Write-Host "0" -ForegroundColor Cyan -NoNewline
            Write-Host "] for latest, '" -NoNewline
            Write-Host "c" -ForegroundColor Yellow -NoNewline
            Write-Host "' to cancel): " -NoNewline
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
   Write-Header "Restoring Original ABL via EDL"
   Write-Log "This fix resolves issues like slow reboots and unwanted booting into ${cCyan}EDL${cReset} mode." "Info"
   Write-Log "SELinux will return to ${cYellow}Enforcing${cReset} mode, using ${cCyan}https://github.com/evdenis/selinux_permissive${cReset} to change back to Permissive mode" "Info"
   Write-Log "Perform ${cYellow}rooting${cReset} (${cCyan}Option 4${cReset}) before doing this step!" "Warning"
   $backupPath = Get-LatestBackupPath
   if (-not $backupPath) { return }

   Write-Log "Target backup file: ${cGreen}$backupPath${cReset}" "Info"
   Write-Host "Are you sure you want to flash this backup? (Type " -NoNewline
   Write-Host "'YES'" -ForegroundColor Yellow -NoNewline
   Write-Host "): " -NoNewline
   $confirmation = Read-Host
   if ($confirmation -ne 'YES') {
      Write-Log "Restore aborted by user." "Warning"
      return
   }

   if (IsAdbMode) {
      Write-Log "Device detected in ${cCyan}ADB${cReset} mode. Attempting to reboot into ${cCyan}EDL${cReset} mode..." "Info"
      & $ADB reboot edl
   }

   if (Wait-EdlMode 100) {
      & $QDL --storage ufs --include (Split-Path $FirehosePath -Parent) $FirehosePath write abl $backupPath
      if ($LASTEXITCODE -eq 0) {
         Write-Log "Backup restored successfully!" "Success"
      }
      else {
         Write-Log "Failed to restore backup." "Error"
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
      Write-Host " (Typically: Hold " -NoNewline
      Write-Host "Vol Down + Power" -ForegroundColor Yellow -NoNewline
      Write-Host " from a powered-off state)"
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

# --- Root Functions ---

function Prepare-Magisk {
   Clear-Host
   Write-Header "Preparing Magisk"

   if (IsFastbootMode) {
      Write-Log "Device detected in ${cCyan}Fastboot${cReset} mode." "Warning"
      Write-Host "Would you like to reboot the device to system? (" -NoNewline
      Write-Host "y" -ForegroundColor Cyan -NoNewline
      Write-Host "/n): " -NoNewline
      $rebootChoice = Read-Host
      if ($rebootChoice -eq 'y') {
         Write-Log "Rebooting device to ${cCyan}system${cReset}..." "Action"
         & $FASTBOOT reboot
         if (-not (Wait-AdbMode 100)) {
            Write-Log "Device did not connect in ${cCyan}ADB${cReset} mode. Please ensure it has fully booted and ${cYellow}USB debugging${cReset} is enabled." "Error"
            return
         }
      }
      else {
         Write-Log "Operation cancelled. Device must be in ${cCyan}ADB${cReset} mode to prepare Magisk." "Warning"
         return
      }
   }

   if (-not (IsAdbMode)) {
      Write-Log "Device not detected in ${cCyan}ADB${cReset} mode. Please connect your device and enable ${cYellow}USB debugging${cReset}." "Error"
      return
   }

   Write-Log "Installing ${cYellow}Magisk APK${cReset}..." "Info"
   if (Test-Path $Magisk) {
      & $ADB install $Magisk
      if ($LASTEXITCODE -eq 0) {
         Write-Log "${cGreen}Magisk${cReset} installed successfully." "Success"
      }
      else {
         Write-Log "Failed to install ${cYellow}Magisk${cReset}." "Error"
      }
   }
   else {
      Write-Log "Magisk APK not found at ${cYellow}$Magisk${cReset}" "Error"
   }

   Write-Log "Important Step: You need to download the correct firmware for your device to get the ${cYellow}'boot.img'${cReset}." "Warning"
   Write-Log "Please download it from here: ${cCyan}https://owomushi.com/Pico-4-Archive/${cReset}" "Info"

   Write-Host "`nWould you like to open this URL in your browser? (" -NoNewline
   Write-Host "y" -ForegroundColor Cyan -NoNewline
   Write-Host "/n): " -NoNewline
   $openUrl = Read-Host
   if ($openUrl -eq 'y') {
      Start-Process "https://owomushi.com/Pico-4-Archive/"
   }

   Write-Log "Step 2: Extract ${cYellow}'boot.img'${cReset}" "Action"
   Write-Log "Once the firmware is downloaded, extract ${cYellow}'boot.img'${cReset} from the ZIP file." "Info"

   $bootImgPath = ""
   while ($true) {
      Write-Host "`nEnter the full path to your extracted " -NoNewline
      Write-Host "'boot.img'" -ForegroundColor Yellow -NoNewline
      Write-Host " (e.g., C:\Downloads\boot.img): " -NoNewline
      $bootImgPath = Read-Host
      $bootImgPath = $bootImgPath.Trim('"').Trim()

      if ($bootImgPath -ne "" -and (Test-Path $bootImgPath -PathType Leaf)) {
         break
      }

      Write-Log "File not found at '${cYellow}$bootImgPath${cReset}'. Please ensure the path is correct and try again." "Warning"
   }

   Write-Log "Pushing ${cYellow}'boot.img'${cReset} to device..." "Action"
   & $ADB push $bootImgPath /sdcard/Download/
   if ($LASTEXITCODE -eq 0) {
      Write-Log "Success! ${cYellow}'boot.img'${cReset} is now on your device in the ${cCyan}'Download'${cReset} folder." "Success"
      Write-Host "`nActions on Device:" -ForegroundColor Cyan
      Write-Host " 1. Open the " -NoNewline; Write-Host "Magisk" -ForegroundColor Yellow -NoNewline; Write-Host " app on your Pico."
      Write-Host " 2. Tap " -NoNewline; Write-Host "'Install'" -ForegroundColor Yellow -NoNewline; Write-Host " on the home page."
      Write-Host " 3. Choose " -NoNewline; Write-Host "'Select and Patch a File'" -ForegroundColor Yellow -NoNewline; Write-Host "."
      Write-Host " 4. Navigate to " -NoNewline; Write-Host "'Download'" -ForegroundColor Yellow -NoNewline; Write-Host " and select the " -NoNewline; Write-Host "'boot.img'" -ForegroundColor Yellow -NoNewline; Write-Host " you just pushed."
      Write-Host " 5. Press " -NoNewline; Write-Host "'LET'S GO'" -ForegroundColor Yellow -NoNewline; Write-Host "."
      Write-Host " 6. Wait for the process to finish."

      Write-Host "`nOnce Magisk says " -NoNewline
      Write-Host "'All done!'" -ForegroundColor Green -NoNewline
      Write-Host ", " -NoNewline
      Wait-Continue "pull the patched image back to your computer..."

      $localDir = Split-Path $bootImgPath -Parent
      Write-Log "Searching for patched image on device (${cCyan}/sdcard/Download/magisk_patched*.img${cReset})..." "Info"

      # Try to find the specific filename created by Magisk (handles both _ and - separators)
      $remoteFiles = & $ADB shell "ls /sdcard/Download/magisk_patched*.img" 2>$null
      if ($LASTEXITCODE -eq 0 -and $remoteFiles) {
         # Handle potential multiple files by taking the latest/first
         $remoteFile = $remoteFiles.Trim().Split("`n")[0].Trim()
         Write-Log "Found patched file: ${cCyan}$remoteFile${cReset}" "Success"

         & $ADB pull $remoteFile $localDir
         if ($LASTEXITCODE -eq 0) {
            $patchedLocalPath = Join-Path $localDir (Split-Path $remoteFile -Leaf)
            $script:PatchedImagePath = $patchedLocalPath
            Write-Log "Patched image pulled successfully to: ${cGreen}$patchedLocalPath${cReset}" "Success"
            Write-Log "You are now ready to flash this image in ${cCyan}fastboot${cReset} mode." "Info"
         }
         else {
            Write-Log "Failed to pull the patched image from the device." "Error"
         }
      }
      else {
         Write-Log "Could not find a file matching ${cYellow}'magisk_patched.img'${cReset} in ${cCyan}/sdcard/Download/${cReset}." "Warning"
         Write-Log "Please check the Magisk app for errors." "Warning"
      }
   }
   else {
      Write-Log "Failed to push ${cYellow}'boot.img'${cReset} to the device." "Error"
   }
}

function Flash-Magisk {
   Clear-Host
   Write-Header "Flashing Magisk"
   Write-Log "This step will reboot your device into ${cCyan}bootloader${cReset} mode to flash the patched boot image." "Warning"
   Write-Host "To proceed with rebooting to bootloader, type " -NoNewline
   Write-Host "'YES'" -ForegroundColor Yellow -NoNewline
   Write-Host " and press Enter: " -NoNewline
   $confirmation = Read-Host
   if ($confirmation -ne 'YES') {
      Write-Log "Reboot to bootloader aborted by user. No changes have been made." "Warning"
      return
   }

   if (IsAdbMode) {
      Write-Log "Device detected in ${cCyan}ADB${cReset} mode. Attempting to reboot into ${cCyan}bootloader${cReset} mode..." "Info"
      & $ADB reboot bootloader
   }
   elseif (-not (IsFastbootMode)) {
      Write-Log "Device not detected in ${cCyan}FASTBOOT${cReset} mode. Please ensure it's connected and in bootloader mode." "Error"
      Write-Host " (Typically: Hold " -NoNewline
      Write-Host "Vol Down + Power" -ForegroundColor Yellow -NoNewline
      Write-Host " from a powered-off state)"
   }

   if (-not (Wait-FastbootMode 100)) {
      Write-Log "Device not detected in ${cCyan}FASTBOOT${cReset} mode." "Error"
      return
   }

   # Read unlock command from picounlock.txt
   if (Test-Path $Picounlock) {
      $unlockCmd = Get-Content $Picounlock | Select-Object -First 1
      if ($unlockCmd -match "fastboot oem pico") {
         Write-Log "Running unlock command: ${cCyan}$unlockCmd${cReset}" "Action"
         # Use the local fastboot path with the call operator (&)
         $cmdToRun = "& " + ($unlockCmd -replace 'fastboot', "`"$FASTBOOT`"")
         Invoke-Expression $cmdToRun
         if ($LASTEXITCODE -eq 0) {
            Write-Log "Unlock command executed successfully." "Success"
         }
         else {
            Write-Log "Failed to execute unlock command." "Error"
            Write-Log "Please make sure ${cYellow}picounlock${cReset} is successful." "Error"
            Write-Log "And do not flash ${cYellow}backup ABL${cReset} yet!" "Error"
            return
         }
      }
      else {
         Write-Log "First line of ${cYellow}$Picounlock${cReset} does not look like an unlock command." "Warning"
         Write-Log "Please make sure ${cYellow}picounlock${cReset} is successful" "Warning"
         return
      }
   }
   else {
      Write-Log "${cYellow}$Picounlock${cReset} not found." "Warning"
      Write-Log "Please make sure ${cYellow}picounlock${cReset} is successful" "Warning"
      return
   }

   # Find patched image
   $patchedImage = $null

   if ($script:PatchedImagePath -and (Test-Path $script:PatchedImagePath)) {
      $patchedImage = Get-Item $script:PatchedImagePath
      Write-Log "Found patched image from last adb pull: ${cGreen}$($patchedImage.FullName)${cReset}" "Success"
   }
   else {
      Write-Log "Searching for patched image locally..." "Info"
      $patchedImage = Get-ChildItem -Path "." -Filter "magisk_patched*.img" -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
   }

   if (-not $patchedImage) {
      Write-Log "Could not find any ${cYellow}'magisk_patched.img'${cReset} file automatically." "Warning"
      $patchedImageInput = ""
      while ($true) {
         Write-Host "`nEnter the full path to your " -NoNewline
         Write-Host "'magisk_patched.img'" -ForegroundColor Yellow -NoNewline
         Write-Host " (e.g., C:\Downloads\magisk_patched-30700_0lM5L.img): " -NoNewline
         $patchedImageInput = Read-Host
         $patchedImageInput = $patchedImageInput.Trim('"').Trim()

         if ($patchedImageInput -ne "" -and (Test-Path $patchedImageInput -PathType Leaf)) {
            $patchedImage = Get-Item $patchedImageInput
            break
         }

         Write-Log "File not found at '${cYellow}$patchedImageInput${cReset}'. Please ensure the path is correct and try again." "Warning"
      }
   }

   if ($patchedImage) {
      $script:PatchedImagePath = $patchedImage.FullName
   }

   if ($patchedImage) {
      Write-Log "Flashing patched boot image: ${cCyan}$($patchedImage.FullName)${cReset}" "Action"
      & $FASTBOOT flash boot $patchedImage.FullName
      if ($LASTEXITCODE -eq 0) {
         Write-Log "Flash successful!" "Success"
         Write-Log "Rebooting device to ${cCyan}system${cReset}..." "Info"
         & $FASTBOOT reboot
      }
      else {
         Write-Log "Failed to flash boot image." "Error"
      }
   }
   else {
      Write-Log "No patched image found or selected. Aborting flash." "Error"
   }
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

function Show-RootMenu {
   $rootQuit = $false
   while (-not $rootQuit) {
      Clear-Host
      Write-Header "Pico Root Menu"
      Write-Host " [" -NoNewline -ForegroundColor DarkGray
      Write-Host "1" -NoNewline -ForegroundColor Cyan
      Write-Host "] " -NoNewline -ForegroundColor DarkGray
      Write-Host "Prepare Magisk " -NoNewline
      Write-Host "(Install APK & Firmware link)" -ForegroundColor DarkGray

      Write-Host " [" -NoNewline -ForegroundColor DarkGray
      Write-Host "2" -NoNewline -ForegroundColor Cyan
      Write-Host "] " -NoNewline -ForegroundColor DarkGray
      Write-Host "Flash Magisk " -NoNewline
      Write-Host "(Fastboot)" -ForegroundColor DarkGray

      Write-Host ""

      Write-Host " [" -NoNewline -ForegroundColor DarkGray
      Write-Host "r" -NoNewline -ForegroundColor Cyan
      Write-Host "] " -NoNewline -ForegroundColor DarkGray
      Write-Host "Reboot to System"

      Write-Host " [" -NoNewline -ForegroundColor DarkGray
      Write-Host "0" -NoNewline -ForegroundColor Cyan
      Write-Host "] " -NoNewline -ForegroundColor DarkGray
      Write-Host "Back to Main Menu"

      $choice = Read-Host "`nSelect an option"

      switch ($choice) {
         "1" {
            Prepare-Magisk
         }
         "2" {
            Flash-Magisk
         }
         "r" {
            Reboot-System
         }
         "0" {
            $rootQuit = $true
         }
         default {
            Write-Log "Invalid option. Please try again." "Warning"
         }
      }
      if (-not $rootQuit) {
         Wait-Continue "return to the Root menu..."
      }
   }
}

# --- Main Script Execution ---

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
if (-not (Test-Path ".\logs")) { New-Item -ItemType Directory -Path ".\logs" | Out-Null }
Start-Transcript -Path ".\logs\unlock_$timestamp.log" -Append

try {
   $quit = $false
   while (-not $quit) {
      Clear-Host
      Check-Prerequisites
      Write-Header "PicoUnlock Main Menu"

      Write-Host " [" -NoNewline -ForegroundColor DarkGray
      Write-Host "1" -NoNewline -ForegroundColor Cyan
      Write-Host "] " -NoNewline -ForegroundColor DarkGray
      Write-Host "Generate UnlockCode"

      Write-Host " [" -NoNewline -ForegroundColor DarkGray
      Write-Host "2" -NoNewline -ForegroundColor Cyan
      Write-Host "] " -NoNewline -ForegroundColor DarkGray
      Write-Host "Flash Engineering ABL"

      Write-Host " [" -NoNewline -ForegroundColor DarkGray
      Write-Host "3" -NoNewline -ForegroundColor Cyan
      Write-Host "] " -NoNewline -ForegroundColor DarkGray
      Write-Host "Unlock bootloader"

      Write-Host " [" -NoNewline -ForegroundColor DarkGray
      Write-Host "4" -NoNewline -ForegroundColor Cyan
      Write-Host "] " -NoNewline -ForegroundColor DarkGray
      Write-Host "Root " -NoNewline
      Write-Host "(Superuser)" -ForegroundColor DarkGray

      Write-Host " [" -NoNewline -ForegroundColor DarkGray
      Write-Host "5" -NoNewline -ForegroundColor Cyan
      Write-Host "] " -NoNewline -ForegroundColor DarkGray
      Write-Host "Flash backup ABL " -NoNewline
      Write-Host "(Fix slow reboot, fix boot into EDL)" -ForegroundColor DarkGray

      Write-Host " [" -NoNewline -ForegroundColor DarkGray
      Write-Host "6" -NoNewline -ForegroundColor Cyan
      Write-Host "] " -NoNewline -ForegroundColor DarkGray
      Write-Host "Lock bootloader"

      Write-Host ""

      Write-Host " [" -NoNewline -ForegroundColor DarkGray
      Write-Host "r" -NoNewline -ForegroundColor Cyan
      Write-Host "] " -NoNewline -ForegroundColor DarkGray
      Write-Host "Reboot to System"

      Write-Host " [" -NoNewline -ForegroundColor DarkGray
      Write-Host "0" -NoNewline -ForegroundColor Cyan
      Write-Host "] " -NoNewline -ForegroundColor DarkGray
      Write-Host "Exit"

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
