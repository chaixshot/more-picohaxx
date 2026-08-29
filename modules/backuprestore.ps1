#Requires -Version 5.1

<#
.SYNOPSIS
    Backup and Restore functions for the PicoUnlock project.
.DESCRIPTION
    Provides functionality for backing up device partitions using QPST/QFIL
    and restoring them. Includes prerequisite checks for QPST installation.
#>

# --- Backup & Restore Functions ---

$ProjectRoot = Split-Path -Path $PSScriptRoot -Parent
$QPSTInstaller = Join-Path $ProjectRoot "tools\qpst\QPST Tool v2.7.496.exe"
$QSaharaServerPath = Join-Path $ProjectRoot "tools\qpst\QSaharaServer.exe"
$QFILHelper = Join-Path $ProjectRoot "tools\qpst\QFILHelper.exe"
$ComPort = $null

$BackupPath = Join-Path $ProjectRoot "tools\qpst"
$TMPPath = Join-Path $ProjectRoot "tools\qpst\TMP"
$ErrorsPath = Join-Path $ProjectRoot "tools\qpst\Errors"
$PortTracePath = Join-Path $ProjectRoot ".\port_trace.txt"
$FlashBackupName = ""
$FlashPath = Join-Path $BackupPath "Flash"

function Get-QualcommCOMPort
{
    Write-Log "Scanning for Qualcomm Emergency Download (EDL) device..." "Info"

    # Query WMI for devices matching "Qualcomm" and "9008" or "QDLoader"
    $device = Get-CimInstance -ClassName Win32_PnPEntity |
            Where-Object { $_.Name -match "Qualcomm.*QDLoader.*9008|Qualcomm.*HS-USB.*9008" } |
            Select-Object -First 1

    if ($device -and $device.Name -match '\(COM(\d+)\)')
    {
        # Extract the digit inside (COMx)
        return [int]$Matches[1]
    }
    return $null
}

function Move-Log{
    # Move port_trace.txt
    if (Test-Path -Path $PortTracePath)
    {
        Write-Log "Moving port trace to logs..." "Action"
        if (-not (Test-Path -Path $LogsPath))
        {
            New-Item -ItemType Directory -Path $LogsPath | Out-Null
        }
        Move-Item -Path $PortTracePath -Destination "$LogsPath\${TimeStamp}_port_trace.txt" -Force
    }

    # Move qpst/Errors/
    if (Test-Path -Path $ErrorsPath)
    {
        $latestError = Get-ChildItem -Path $ErrorsPath -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -ne $latestError)
        {
            if (-not (Test-Path -Path $script:LogsPath))
            {
                New-Item -ItemType Directory -Path $script:LogsPath | Out-Null
            }
            $destErrorLog = "$script:LogsPath\${script:TimeStamp}_qfilerror.log"
            Move-Item -Path $latestError.FullName -Destination $destErrorLog -Force
            Write-Log "Moved QFIL error log to: $destErrorLog" "Action"
        }
    }
}

function Send-Firehose
{
    $saharaOutput = & $QSaharaServerPath -p "\\.\COM$ComPort" -s "13:`"$FirehoseTargetPath`"" 2>&1 | ForEach-Object { Write-Host $_; $_ }
    $lastLine = $saharaOutput | Where-Object { $_ -match '\S' } | Select-Object -Last 1

    if ($lastLine -match "Sahara protocol completed")
    {
        Write-Log "Sahara protocol completed successfully." "Success"
        return $true
    }
    else
    {
        Write-Log "Sahara protocol failed: $lastLine" "Error"
        return $false
    }
}

function QFIL-ShowInstructions
{
    Write-Header "QFIL Instructions"
    Write-Log "Once you have saved the partition file, return here and press Enter." "Action"
    Write-Log "When process is done, you will hear the beep sound." "Info"
}

function Post-Steps
{
    Write-Header "Post Steps"
    Write-Log "Your device will not automatically reboot." "Info"
    Write-Log "Hold ${cYellow}Power Button${cReset} for 10 seconds to reboot to system." "Info"
}

function Select-BackupFolder
{
    Write-Header "Select Backup Folder"

    $backupFolders = Get-ChildItem -Path $BackupPath -Directory -Filter "Backup-*" | Sort-Object CreationTime -Descending

    if ($backupFolders.Count -eq 0)
    {
        Write-Log "No backup folders found in '$BackupPath'." "Error"
        return $null
    }

    Write-Log "Listing available backup folders..." "Info"
    Write-Host "`nAvailable Backup Folders:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $backupFolders.Count; $i++) {
        Write-Host " [${cCyan}$( $i + 1 )${cReset}] $( $backupFolders[$i].Name ) ${cGreen}($( $backupFolders[$i].CreationTime ))${cReset}"
    }

    $selection = Read-Host "`nSelect a backup folder [${cCyan}1-$( $backupFolders.Count )${cReset}], [${cCyan}c${cReset}] to cancel"

    if ($selection -eq 'c')
    {
        Write-Log "Operation cancelled by user." "Info"
        return $null
    }

    if (-not [int]::TryParse($selection, [ref]$null) -or [int]$selection -lt 1 -or [int]$selection -gt $backupFolders.Count)
    {
        Write-Log "Invalid selection '$selection'. Aborting." "Error"
        return $null
    }

    $targetBackup = $backupFolders[[int]$selection - 1]
    $script:FlashBackupName = $targetBackup.Name

    # Check if a folder named 'Flash' already exists
    if (Test-Path -Path $FlashPath)
    {
        Write-Log "Folder 'Flash' already exists in '$BackupPath'. Please remove or rename it before restoring." "Error"
        return $null
    }

    Write-Log "Selected backup folder: ${cCyan}$FlashBackupName${cReset}" "Success"

    # Rename the selected backup folder to 'Flash'
    Write-Log "Renaming folder ${cCyan}'$FlashBackupName'${cReset} to ${cCyan}'Flash'${cReset}..." "Action"
    Rename-Item -Path $targetBackup.FullName -NewName "Flash"

    Write-Log "Flash folder prepared successfully via renaming." "Success"
    Wait-Continue

    return $targetBackup
}

# Rename Flash back to its original name
function Restore-FlashBackupName
{
    if (Test-Path -Path $FlashPath)
    {
        Write-Log "Restoring ${cCyan}'Flash'${cReset} folder back to ${cCyan}'$FlashBackupName'${cReset}..." "Action"
        Rename-Item -Path $FlashPath -NewName $FlashBackupName
        Wait-Continue
    }
}

function Get-UserdataSizeGB
{
    if (IsAdbMode)
    {
        try
        {
            # Logic: Get block size from /sys/class/block/ for userdata partition
            $partitionPath = (& $ADB shell "readlink -f /dev/block/by-name/userdata").Trim()
            $partitionName = Split-Path $partitionPath -Leaf
            $blocksRaw = (& $ADB shell "cat /sys/class/block/$partitionName/size").Trim()

            if ($blocksRaw -match '^\d+$')
            {
                $blocks = [long]$blocksRaw
                # Standard block size is 512 bytes
                $sizeGB = [math]::Round(($blocks * 512) / 1GB, 2)
                return $sizeGB
            }
        }
        catch
        {
        }
    }
    return 110 # Default for Pico 4
}

function Verify-DiskSpace
{
    $userdataSize = Get-UserdataSizeGB
    $scriptDriveLetter = Split-Path -Path $PSScriptRoot -Qualifier

    # Strip trailing colon if needed (e.g., "C:" -> "C")
    $driveName = $scriptDriveLetter.TrimEnd(':')
    $targetDrive = Get-PSDrive $driveName -ErrorAction SilentlyContinue

    $freeSpaceGB = if ($targetDrive)
    {
        [math]::Round($targetDrive.Free / 1GB, 2)
    }
    else
    {
        0
    }

    Write-Log "Estimated userdata size: ${cGreen}$userdataSize GB${cReset}" "Info"
    Write-Log "Current disk space (${cCyan}Drive ${driveName}${cReset}): ${cGreen}$freeSpaceGB GB${cReset}" "Info"

    if ($freeSpaceGB -lt $userdataSize)
    {
        Write-Log "Free space on drive ${cCyan}${scriptDriveLetter}${cReset} is less than the estimated userdata size (${cCyan}$userdataSize GB${cReset})!" "Error"
        Write-Log "Please ensure you have enough space on drive ${cCyan}${scriptDriveLetter}${cReset} before proceeding." "Error"
        Wait-Continue
        return $false
    }
    else
    {
        Write-Log "Please preserve disk space ${cCyan}${userdataSize} GB${cReset} on drive ${cCyan}${scriptDriveLetter}${cReset} for this process." "Info"
        Write-Host ""

        return $true
    }
}

function Wait-UserConfirm
{
    Write-Log "This step will reboot your device into ${cCyan}EDL${cReset} mode to access the userdata partition." "Warning"
    Write-Log "This process takes at least ${cGreen}40 minutes${cReset}. High speed ${cGreen}USB 3.0${cReset} is recommended." "Warning"
    Write-Host "To proceed with rebooting to EDL, type ${cYellow}'YES'${cReset} and press Enter: " -NoNewline
    $confirmation = Read-Host
    if ($confirmation -ne 'YES')
    {
        Write-Log "Reboot to EDL aborted by user. No changes have been made." "Warning"
        return $false
    }

    return $true
}

function Test-BackupSuccess([string]$FolderPath)
{
    $requiredFiles = @(
        "lun0_gpt_header.bin",
        "lun0_userdata.bin",
        "lun1_gpt_header.bin",
        "lun2_gpt_header.bin",
        "lun3_gpt_header.bin",
        "lun4_gpt_header.bin",
        "lun5_gpt_header.bin",
        "lun6_gpt_header.bin"
    )

    $allFilesExist = $true
    foreach ($file in $requiredFiles)
    {
        if (-not (Test-Path -Path (Join-Path $FolderPath $file)))
        {
            Write-Log "Missing required backup file: ${cYellow}$file${cReset}" "Error"
            $allFilesExist = $false
        }
    }

    if (-not $allFilesExist)
    {
        Write-Log "Backup verification failed: one or more files are missing." "Error"
        return $false
    }

    $folderSize = (Get-ChildItem -Path $FolderPath -Recurse | Measure-Object -Property Length -Sum).Sum
    $sizeGB = $folderSize / 1GB

    if ($sizeGB -le 10)
    {
        $sizeFormatted = "{0:N2}" -f $sizeGB
        Write-Log "Backup verification failed: total folder size (${cYellow}$sizeFormatted GB${cReset}) is not greater than 10GB." "Error"
        return $false
    }

    $sizeFormatted = "{0:N2}" -f $sizeGB
    Write-Log "Backup verification successful! Total size: ${cGreen}$sizeFormatted GB${cReset}" "Success"
    return $true
}

function Backup-Device
{
    Write-Header "Backup Device"

    if (-not (Verify-DiskSpace))
    {
        return
    }

    if (-not (Wait-UserConfirm))
    {
        return
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

    $ComPort = Get-QualcommCOMPort
    QFIL-ShowInstructions

    # Start Sahara to load programmer
    <#if(-not (Send-Firehose))
    {
        return
    }#>

    Wait-Continue "start userdata backup..."

    # Start the automated helper
    BackupLUNs
    Move-Log
    [Console]::Beep(523, 150) # C5 tone for 150ms
    [Console]::Beep(784, 300) # G5 tone for 300ms

    # Post-process organization
    $newBackup = Get-ChildItem -Path $BackupPath -Directory -Filter "Backup-*" | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $newBackup)
    {
        Write-Log "Could not automatically find the backup folder in $BackupPath." "Warning"
    }
    elseif (Test-BackupSuccess -FolderPath $newBackup.FullName)
    {
        Write-Log "Detected new backup at: ${cCyan}$( $newBackup.FullName )${cReset}" "Success"
    }
    else
    {
        Write-Log "Found backup folder at '${cCyan}$( $newBackup.FullName )${cReset}', but validation failed." "Error"
        if (Test-Path -Path $newBackup.FullName)
        {
            Write-Log "Deleting invalid backup folder..." "Action"
            Remove-Item -Path $newBackup.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Delete TMP folder
    if (Test-Path -Path $TMPPath)
    {
        Write-Log "Deleting ${cCyan}$( $TMPPath )${cReset} folder..." "Action"
        Remove-Item -Path $TMPPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    Wait-Continue
}

function Restore-Backup
{
    Write-Header "Restore Device"
    if (-not (Wait-UserConfirm))
    {
        return
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

    $ComPort = Get-QualcommCOMPort
    QFIL-ShowInstructions

    # Start Sahara to load programmer
    if(-not (Send-Firehose))
    {
        return
    }

    Wait-Continue "start restore userdata..."

    # Start the automated helper
    Move-Log
    [Console]::Beep(523, 150) # C5 tone for 150ms
    [Console]::Beep(784, 300) # G5 tone for 300ms

    Wait-Continue
}

function Show-BackupRestoreMenu
{
    $menuQuit = $false
    while (-not $menuQuit)
    {
        Write-Header "Backup/Restore Menu"
        Write-Host " [${cCyan}1${cReset}] Backup Device"
        Write-Host " [${cCyan}2${cReset}] Restore Device"
        Write-Host ""
        Write-Host " [${cCyan}r${cReset}] Reboot"
        Write-Host " [${cCyan}0${cReset}] Back to Main Menu"

        $choice = Read-Host "`nSelect an option"

        switch ($choice)
        {
            "1" {
                Backup-Device
                Post-Steps
            }
            "2" {
                if (Select-BackupFolder)
                {
                    Restore-Backup
                    Restore-FlashBackupName
                    Post-Steps
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
        if (-not $menuQuit)
        {
            Wait-Continue "return to the Backup/Restore menu..."
        }
    }
}
