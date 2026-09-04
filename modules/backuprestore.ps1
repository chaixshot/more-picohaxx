#Requires -Version 5.1

<#
.SYNOPSIS
    Backup and Restore functions for the PicoUnlock project.
.DESCRIPTION
    Provides functionality for backing up device partitions using QPST/QFIL
    and restoring them. Includes prerequisite checks for QPST installation.
#>

# --- Backup & Restore Functions ---

$QSaharaServerPath = "tools\qpst\QSaharaServer.exe"
$ComPort = $null

# Define Kernel32 API for reliable NTFS compressed size calculation
if (-not ([System.Management.Automation.PSTypeName]'Native.Win32').Type) {
    Add-Type -MemberDefinition '[DllImport("kernel32.dll", EntryPoint="GetCompressedFileSizeW", CharSet=CharSet.Unicode)] public static extern uint GetCompressedFileSize(string lpFileName, out uint lpFileSizeHigh);' -Name 'Win32' -Namespace 'Native'
}

function Get-QualcommCOMPort {
    Write-Log "Scanning for Qualcomm Emergency Download (EDL) device..." "Action"

    # Query WMI for devices matching "Qualcomm" and "9008" or "QDLoader"
    $device = Get-CimInstance -ClassName Win32_PnPEntity |
    Where-Object { $_.Name -match "Qualcomm.*QDLoader.*9008|Qualcomm.*HS-USB.*9008" } |
    Select-Object -First 1

    if ($device -and $device.Name -match '\(COM(\d+)\)') {
        # Extract the digit inside (COMx)
        return [int]$Matches[1]
    }
    return $null
}

function Send-Firehose {
    if ($null -eq $ComPort) {
        Write-Log "Unable to detect Qualcomm COM Port." "Error"
        Write-Log "Ensure the device is connected in EDL mode and using the '${cCyan}qcser.inf${cReset}' driver." "Error"
        Wait-Continue

        return $false
    }

    Write-Log "Sending firehose with QSaharaServer..." "Action"
    Write-Log "If the process is stuck here, it means EDL timed out. Reboot EDL and try again." "Warning"

    $saharaOutput = & $QSaharaServerPath -p "\\.\COM$ComPort" -s "13:$FirehoseTargetPath" 2>&1 | ForEach-Object { Write-Host $_; $_ }
    $lastLine = $saharaOutput | Where-Object { $_ -match '\S' } | Select-Object -Last 1
    Write-Host ""

    if ($lastLine -match "Sahara protocol completed") {
        Write-Log "Sahara protocol completed successfully." "Success"
        return $true
    } else {
        Write-Log "Sahara protocol failed: $lastLine" "Error"
        Write-Log "Reboot EDL and try again." "Info"
        Wait-Continue

        return $false
    }
}

function Post-Steps {
    Write-Header "Post Steps"
    Write-Log "Your device will not automatically reboot." "Info"
    Write-Log "Hold ${cYellow}Power Button${cReset} for 10 seconds to reboot to system." "Info"
}

function Select-BackupFolder {
    Write-Header "Select Backup Folder"

    $backupFolders = Get-ChildItem -Path $UserBackupPath -Directory -Filter "Backup-*" | Sort-Object CreationTime -Descending

    if ($backupFolders.Count -eq 0) {
        Write-Log "No backup folders found in '$UserBackupPath'." "Error"
        return $null
    }

    Write-Host "`nAvailable Backup Folders:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $backupFolders.Count; $i++) {
        Write-Host " [${cCyan}$( $i + 1 )${cReset}] $( $backupFolders[$i].Name ) ${cGreen}($( $backupFolders[$i].CreationTime ))${cReset}"
    }

    $selection = Read-Host "`nSelect a backup folder [${cCyan}1-$( $backupFolders.Count )${cReset}], [${cCyan}c${cReset}] to cancel"

    if ($selection -eq 'c') {
        Write-Log "Operation cancelled by user." "Info"
        return $null
    }

    if (-not [int]::TryParse($selection, [ref]$null) -or [int]$selection -lt 1 -or [int]$selection -gt $backupFolders.Count) {
        Write-Log "Invalid selection '$selection'. Aborting." "Error"
        return $null
    }

    $targetBackup = $backupFolders[[int]$selection - 1]

    Write-Log "Selected backup folder: ${cCyan}${targetBackup}${cReset}" "Success"
    Wait-Continue

    return "$UserBackupPath\$targetBackup"
}

function Get-UserdataSizeGB {
    if (IsAdbMode) {
        try {
            # Query mounted /data directory using standard df (in 1K blocks)
            $dfOutput = (& $ADB shell "df -k /data").Split("`n") | Select-Object -Last 1
            $columns = ($dfOutput.Trim()) -split '\s+'

            if ($columns.Count -ge 2 -and $columns[1] -match '^\d+$') {
                $sizeKB = [long]$columns[1]
                return [math]::Round(($sizeKB * 1KB) / 1GB, 2)
            }
        } catch {
        }
    }

    Write-Log "Could not determine userdata partition size via USB Debugging." "Warning"
    Write-Log "Userdata size depends on your device model (e.g., 128GB, 256GB, or 512GB)." "Warning"

    return 110 
}

function Verify-DiskSpace {
    $userdataSize = Get-UserdataSizeGB
    $scriptDriveLetter = Split-Path -Path $PSScriptRoot -Qualifier

    # Strip trailing colon if needed (e.g., "C:" -> "C")
    $driveName = $scriptDriveLetter.TrimEnd(':')
    $targetDrive = Get-PSDrive $driveName -ErrorAction SilentlyContinue

    $freeSpaceGB = if ($targetDrive) {
        [math]::Round($targetDrive.Free / 1GB, 2)
    } else {
        0
    }

    Write-Log "Estimated userdata size: ${cGreen}$userdataSize GB${cReset}" "Info"
    Write-Log "Current disk space (${cCyan}Drive ${driveName}${cReset}): ${cGreen}$freeSpaceGB GB${cReset}" "Info"

    if ($freeSpaceGB -lt $userdataSize) {
        Write-Log "Free space on drive ${cCyan}${scriptDriveLetter}${cReset} is less than the estimated userdata size (${cCyan}$userdataSize GB${cReset})!" "Error"
        Write-Log "Please ensure you have enough space on drive ${cCyan}${scriptDriveLetter}${cReset} before proceeding." "Error"
        Wait-Continue
        return $false
    } else {
        Write-Log "Please preserve disk space ${cCyan}${userdataSize} GB${cReset} on drive ${cCyan}${scriptDriveLetter}${cReset} for this process." "Info"
        Write-Host ""

        return $true
    }
}

function Wait-UserConfirm {
    Write-Log "This step will reboot your device into ${cCyan}EDL${cReset} mode to access the userdata partition." "Warning"
    Write-Log "This process takes at least ${cGreen}40 minutes${cReset}. High speed ${cGreen}USB 3.0${cReset} is recommended." "Warning"
    Write-Log "Make sure the device is '${cCyan}Fully Charged${cReset}'." "Warning"
    Write-Host "To proceed with rebooting to EDL, type ${cYellow}'YES'${cReset} and press Enter: " -NoNewline
    $confirmation = Read-Host
    if ($confirmation -ne 'YES') {
        Write-Log "Reboot to EDL aborted by user. No changes have been made." "Warning"
        return $false
    }

    return $true
}

function Verify-Backup([string]$FolderPath) {
    $userDataFiles = @("lun0_gpt_header.bin", "lun0_userdata.bin", "lun1_gpt_header.bin", "lun2_gpt_header.bin", "lun3_gpt_header.bin", "lun4_gpt_header.bin", "lun5_gpt_header.bin", "lun6_gpt_header.bin")
    $lunsFiles = @("lun0_complete.bin", "lun1_complete.bin", "lun2_complete.bin", "lun3_complete.bin", "lun4_complete.bin", "lun5_complete.bin")

    $userDataFilesExist = $true
    foreach ($file in $userDataFiles) {
        if (-not (Test-Path -Path (Join-Path $FolderPath $file))) {
            $userDataFilesExist = $false
            break
        }
    }

    $lunsFilesExist = $true
    foreach ($file in $lunsFiles) {
        if (-not (Test-Path -Path (Join-Path $FolderPath $file))) {
            $lunsFilesExist = $false
            break
        }
    }

    if ($userDataFilesExist) {
        Write-Log "UserData backup set found." "Success"
    } elseif ($lunsFilesExist) {
        Write-Log "Full LUN backup set found." "Success"
    } else {
        Write-Log "Backup verification failed: required backup sets are missing." "Error"
        return $false
    }

    $folderSize = (Get-ChildItem -Path $FolderPath -Recurse | Measure-Object -Property Length -Sum).Sum
    $sizeGB = $folderSize / 1GB
    $sizeFormatted = "{0:N2}" -f $sizeGB

    if ($sizeGB -le 10) {
        Write-Log "Backup verification failed: total folder size (${cYellow}$sizeFormatted GB${cReset}) is not greater than 10GB." "Error"
        return $false
    }

    Write-Log "Backup verification successful. Total size: ${cGreen}$sizeFormatted GB${cReset}" "Success"
    return $true
}

function Folder-Compression([string]$folderPath) {
    if (-not (Test-Path -Path $folderPath)) {
        Write-Log "Target path '${cYellow}$folderPath${cReset}' does not exist." "Error"
        return
    }

    Write-Header "Folder Compression"
    Write-Log "Using Windows native ${cCyan}LZX${cReset} algorithm to compress folder for maximum space savings up to ${cGreen}60%${cReset}." "Info"
    Write-Log "Files stay as files, ${cGreen}negligible CPU impact${cReset} during decompression." "Info"
    Write-Log "This process takes at least ${cGreen}10 minutes${cReset}." "Warning"
    Write-Host ""

    Write-Host "You are about to compress folder '${cCyan}${folderPath}${cReset}'"
    $confirmation = Read-Host "To proceed, type ${cYellow}'YES'${cReset} and press Enter"

    if ($confirmation -eq 'YES') {
        Write-Host ""
        Write-Log "Scanning target directory..." "Action"

        Write-Progress -Activity "Scanning Files" -Status "Collecting file inventory..."
        $fileList = Get-ChildItem -Path $folderPath -Recurse -File -Force -ErrorAction SilentlyContinue
        Write-Progress -Activity "Scanning Files" -Completed

        $totalFiles = $fileList.Count
        if ($totalFiles -eq 0) {
            Write-Log "Folder is empty or contains no readable files." "Warning"
            return
        }

        $sizeBeforeBytes = ($fileList | Measure-Object -Property Length -Sum).Sum
        $sizeBeforeGB = [math]::Round($sizeBeforeBytes / 1GB, 2)

        Write-Log "Original size: ${cCyan}${sizeBeforeGB} GB${cReset} across ${cCyan}${totalFiles}${cReset} files." "Info"
        Write-Log "Compressing folder using ${cCyan}LZX${cReset}..." "Action"

        $processedCount = 0
        & compact.exe /c /s /a /i /exe:lzx "$folderPath\*" 2>&1 | ForEach-Object {
            $line = $_.ToString()

            # Match lines that indicate a file has been processed (contains compression ratio and [OK]/[ERR])
            if ($line -match ':\s*\d+\s+\[(OK|ERR)\]') {
                $processedCount++
                $percent = [math]::Min([math]::Round(($processedCount / $totalFiles) * 100), 100)
                Write-Progress -Activity "Compressing Files (LZX)" -Status "Processing: [$processedCount/$totalFiles] files" -PercentComplete $percent
            }
        }
        Write-Progress -Activity "Compressing Files (LZX)" -Completed

        # Calculate post-compression space stats
        Write-Progress -Activity "Calculating Space Savings" -Status "Measuring compressed footprint..."

        $sizeAfterBytes = [long]0
        foreach ($file in $fileList) {
            $high = 0
            $low = [Native.Win32]::GetCompressedFileSize($file.FullName, [ref]$high)

            if ($low -eq 0xFFFFFFFF -and ([System.Runtime.InteropServices.Marshal]::GetLastWin32Error() -ne 0)) {
                $sizeAfterBytes += $file.Length
            } else {
                $fileCompressedSize = ([long]$high -shl 32) -bor [long]$low
                $sizeAfterBytes += $fileCompressedSize
            }
        }

        Write-Progress -Activity "Calculating Space Savings" -Completed

        # Metrics calculation
        $sizeAfterGB = [math]::Round($sizeAfterBytes / 1GB, 2)
        $savedBytes = $sizeBeforeBytes - $sizeAfterBytes
        $savedGB = [math]::Round($savedBytes / 1GB, 2)

        $ratio = 0
        if ($sizeBeforeBytes -gt 0) {
            $ratio = [math]::Round(($savedBytes / $sizeBeforeBytes) * 100, 2)
        }

        Write-Host ""
        Write-Log "------------------------------------------------" "Info"
        Write-Log "Size Before: ${cYellow}${sizeBeforeGB} GB${cReset}" "Info"
        Write-Log "Size After:  ${cGreen}${sizeAfterGB} GB${cReset}" "Info"

        if ($LASTEXITCODE -eq 0) {
            Write-Log "Compression complete." "Success"
            Write-Log "Total Saved: ${cCyan}${savedGB} GB${cReset} (${cGreen}${ratio}%${cReset})" "Success"
        } else {
            Write-Log "Compression finished with warnings/errors (Exit Code: ${cRed}$LASTEXITCODE${cReset})." "Warning"
            Write-Log "Total Saved: ${cCyan}${savedGB} GB${cReset} (${cYellow}${ratio}%${cReset})" "Info"
        }
        Write-Log "------------------------------------------------" "Info"
    } else {
        Write-Log "Folder compression ${cRed}cancelled${cReset} by user." "Warning"
    }

    Play-BeepBeep
}

function Backup-Device {
    Write-Header "Backup Device"

    if (-not (Verify-DiskSpace)) {
        return
    }

    if (-not (Wait-UserConfirm)) {
        return
    }

    # Reboot EDL
    if (IsAdbMode) {
        ADB-To-Edl
    } elseif (-not (IsEdlMode)) {
        Warning-EDL
    }

    if (-not (Wait-EdlMode 100)) {
        return
    }

    # Start Sahara to load programmer
    $script:ComPort = Get-QualcommCOMPort
    if (-not (Send-Firehose)) {
        return
    }

    # Start the automated helper
    BackupUserData

    # Post-process organization
    $newBackup = Get-ChildItem -Path $UserBackupPath -Directory -Filter "Backup-*" | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $newBackup) {
        Write-Log "Could not automatically find the backup folder in $UserBackupPath." "Warning"
    } elseif (Verify-Backup -FolderPath $newBackup.FullName) {
        Write-Log "Detected new backup at: ${cCyan}$( $newBackup.FullName )${cReset}" "Success"
        Wait-Continue

        Folder-Compression $newBackup.FullName
    } else {
        Write-Log "Found backup folder at '${cCyan}$( $newBackup.FullName )${cReset}', but validation failed." "Error"
        if (Test-Path -Path $newBackup.FullName) {
            Write-Log "Deleting invalid backup folder..." "Action"
            Remove-Item -Path $newBackup.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Wait-Continue
}

function Restore-Backup([string]$FlashPath = "") {
    Write-Header "Restore Device"
    if (-not (Wait-UserConfirm)) {
        return
    }

    # Reboot EDL
    if (IsAdbMode) {
        ADB-To-Edl
    } elseif (-not (IsEdlMode)) {
        Warning-EDL
    }

    if (-not (Wait-EdlMode 100)) {
        return
    }

    # Start Sahara to load programmer
    $script:ComPort = Get-QualcommCOMPort
    if (-not (Send-Firehose)) {
        return
    }

    # Start the automated helper
    FlashFirmware $flashPath

    Wait-Continue
}

function Show-BackupRestoreMenu {
    $menuQuit = $false
    while (-not $menuQuit) {
        Write-Header "Backup/Restore Menu"
        Write-Host " [${cCyan}1${cReset}] Backup Device"
        Write-Host " [${cCyan}2${cReset}] Restore Device"
        Write-Host " [${cCyan}3${cReset}] Compress Backup"
        Write-Host ""
        Write-Host " [${cCyan}r${cReset}] Reboot"
        Write-Host " [${cCyan}0${cReset}] Back to Main Menu"

        $choice = Read-Host "`nSelect an option"

        switch ($choice) {
            "1" {
                Select-Firehose
                Backup-Device
                Post-Steps
            }
            "2" {
                Select-Firehose
                $targetBackup = Select-BackupFolder
                if ($null -ne $targetBackup) {
                    Restore-Backup $targetBackup
                    Post-Steps
                }
            }
            "3" {
                $targetFolder = Select-BackupFolder
                if ($null -ne $targetFolder) {
                    Folder-Compression $targetFolder
                }
            }
            "r" {
                Perform-Reboot
            }
            "0" {
                $menuQuit = $true
            }
            default {
                Write-Log "Invalid option. Please try again." "Warning"
            }
        }
        if (-not $menuQuit) {
            Wait-Continue "return to the Backup/Restore menu..."
        }
    }
}
