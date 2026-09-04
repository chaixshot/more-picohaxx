#Requires -Version 5.1

<#
.SYNOPSIS
    Backup and Restore functions for the PicoUnlock project.
.DESCRIPTION
    Provides functionality for backing up device partitions using QPST/QFIL
    and restoring them. Includes prerequisite checks for QPST installation.
#>

# --- Backup & Restore Functions ---

$ComPort = $null
$QSaharaServerPath = "tools\qpst\QSaharaServer.exe"

$LUNsBackupPath = "${BackupPath}\luns"
$UserBackupPath = "${BackupPath}\userdata"
$PartitionsBackupPath = "${BackupPath}\partitions"

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
    Write-Log "Hold ${cYellow}Power Button${cReset} for 10 seconds to reboot to ${cCyan}SYSTEM${cReset}." "Info"
    Write-Log "Hold ${cYellow}Vol Up + Vol Down + Power${cReset} for 10 seconds to reboot to ${cCyan}EDL${cReset}." "Info"
}

function Select-BackupFolder {
    Write-Header "Select Backup Folder"

    $backupSources = @(
        @{ Path = $LUNsBackupPath; Type = "luns" },
        @{ Path = $UserBackupPath; Type = "userdata" },
        @{ Path = $PartitionsBackupPath; Type = "partitions" }
    )

    $allBackupFolders = New-Object System.Collections.Generic.List[PSObject]

    foreach ($source in $backupSources) {
        if (Test-Path $source.Path) {
            $folders = Get-ChildItem -Path $source.Path -Directory
            foreach ($f in $folders) {
                $f | Add-Member -MemberType NoteProperty -Name "BackupType" -Value $source.Type
                $allBackupFolders.Add($f)
            }
        }
    }

    $backupFolders = $allBackupFolders | Sort-Object CreationTime -Descending

    if ($backupFolders.Count -eq 0) {
        Write-Log "No backup folders found in any backup directory." "Error"
        return $null
    }

    Write-Host "Available Backup Folders:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $backupFolders.Count; $i++) {
        $folder = $backupFolders[$i]
        Write-Host " [${cCyan}$( $i + 1 )${cReset}] $( $folder.Name ) ${cYellow}[$( $folder.BackupType )]${cReset} ${cGreen}($( $folder.CreationTime ))${cReset}"
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

    Write-Log "Selected backup: ${cCyan}$($targetBackup.Name)${cReset} [${cYellow}$($targetBackup.BackupType)${cReset}] ${cGreen}($($targetBackup.CreationTime))${cReset}" "Success"
    Wait-Continue

    return [PSCustomObject]@{
        Path = $targetBackup.FullName
        Type = $targetBackup.BackupType
    }
}

function Get-LunsSizeGB {
    if (IsAdbMode) {
        try {
            # Query /proc/partitions for total blocks of internal storage (usually sda to sdf)
            $partitions = (& $ADB shell "cat /proc/partitions").Split("`n")
            $totalBlocks = 0
            foreach ($line in $partitions) {
                if ($line -match "\s+(\d+)\s+sd[a-f]$") {
                    $totalBlocks += [long]$matches[1]
                }
            }

            if ($totalBlocks -gt 0) {
                $totalSize = [math]::Round(($totalBlocks * 1KB) / 1GB, 2)
                # Get userdata size to subtract it (since BackupLUNs cuts it off)
                $userdataSize = Get-UserdataSizeGB
                $systemSize = $totalSize - $userdataSize

                if ($systemSize -gt 0 -and $systemSize -lt $totalSize) {
                    return $systemSize + 1
                }
            }
        } catch {
        }
    }

    Write-Log "Could not determine partition size via USB Debugging." "Warning"
    return 15
}

function Get-UserdataSizeGB {
    if (IsAdbMode) {
        try {
            # Query mounted /data directory using standard df (in 1K blocks)
            $dfOutput = (& $ADB shell "df -k /data").Split("`n") | Select-Object -Last 1
            $columns = ($dfOutput.Trim()) -split '\s+'

            if ($columns.Count -ge 2 -and $columns[1] -match '^\d+$') {
                $sizeKB = [long]$columns[1]
                return [math]::Round(($sizeKB * 1KB) / 1GB, 2) + 1
            }
        } catch {
        }
    }

    Write-Log "Could not determine userdata partition size via USB Debugging." "Warning"
    Write-Log "Userdata size depends on your device model (e.g., 128GB, 256GB, or 512GB)." "Warning"
    return 110 
}

function Get-PartitionsSizeGB {
    if (IsAdbMode) {
        try {
            $partitions = (& $ADB shell "cat /proc/partitions").Split("`n")
            
            # Find the largest partition on sda (likely userdata) to exclude it
            $maxSdaSize = 0
            $userdataName = ""
            foreach ($line in $partitions) {
                if ($line -match "\s+(\d+)\s+(sda\d+)$") {
                    $size = [long]$matches[1]
                    if ($size -gt $maxSdaSize) {
                        $maxSdaSize = $size
                        $userdataName = $matches[2]
                    }
                }
            }

            $totalBlocks = 0
            foreach ($line in $partitions) {
                # Sum all partitions (sd[a-f][0-9]+) except the detected userdata
                if ($line -match "\s+(\d+)\s+(sd[a-f]\d+)$") {
                    if ($matches[2] -ne $userdataName) {
                        $totalBlocks += [long]$matches[1]
                    }
                }
            }

            if ($totalBlocks -gt 0) {
                return [math]::Round(($totalBlocks * 1KB) / 1GB, 2) + 1
            }
        } catch { }
    }
    
    Write-Log "Could not determine partition size via USB Debugging." "Warning"
    return 15 # Default system partitions size
}

function Verify-DiskSpace([string]$backupMode) {
    if ($backupMode -eq "luns") {
        $diskSize = Get-LunsSizeGB
    } elseif ($backupMode -eq "userdata") {
        $diskSize = Get-UserdataSizeGB
    } elseif ($backupMode -eq "partitions") {
        $diskSize = Get-PartitionsSizeGB
    }

    $scriptDriveLetter = Split-Path -Path $PSScriptRoot -Qualifier

    # Strip trailing colon if needed (e.g., "C:" -> "C")
    $driveName = $scriptDriveLetter.TrimEnd(':')
    $targetDrive = Get-PSDrive $driveName -ErrorAction SilentlyContinue

    $freeSpaceGB = if ($targetDrive) {
        [math]::Round($targetDrive.Free / 1GB, 2)
    } else {
        0
    }

    Write-Log "Estimated backup size: ${cGreen}$diskSize GB${cReset}" "Info"
    Write-Log "Current disk space (${cCyan}Drive ${driveName}${cReset}): ${cGreen}$freeSpaceGB GB${cReset}" "Info"

    if ($freeSpaceGB -lt $diskSize) {
        Write-Log "Free space on drive ${cCyan}${scriptDriveLetter}${cReset} is less than the estimated backup size (${cCyan}$diskSize GB${cReset})!" "Error"
        Write-Log "Please ensure you have enough space on drive ${cCyan}${scriptDriveLetter}${cReset} before proceeding." "Error"
        Wait-Continue
        return $false
    } else {
        Write-Log "Please preserve disk space ${cCyan}${diskSize} GB${cReset} on drive ${cCyan}${scriptDriveLetter}${cReset} for this process." "Info"
        Write-Host ""

        return $true
    }
}

function Wait-UserConfirm([string]$backupMode) {
    if ($backupMode -eq "luns") {
        $waitMinutes = 5
    } elseif ($backupMode -eq "userdata") {
        $waitMinutes = 40
    } elseif ($backupMode -eq "partitions") {
        $waitMinutes = 10
    }

    Write-Log "This step will reboot your device into ${cCyan}EDL${cReset} mode to access the userdata partition." "Warning"
    Write-Log "This process takes at least ${cGreen}${waitMinutes} minutes${cReset}. High speed ${cGreen}USB 3.0${cReset} is recommended." "Warning"
    Write-Log "Make sure the device is '${cCyan}Fully Charged${cReset}'." "Warning"
    Write-Host "To proceed with rebooting to EDL, type ${cYellow}'YES'${cReset} and press Enter: " -NoNewline
    $confirmation = Read-Host
    if ($confirmation -ne 'YES') {
        Write-Log "Reboot to EDL aborted by user. No changes have been made." "Warning"
        return $false
    }

    return $true
}

function Verify-Backup([string]$backupMode, [string]$folderPath) {
    $verifySuccess = $true

    if ($backupMode -eq "luns") { 
        $lunsFiles = @("lun0_complete.bin", "lun1_complete.bin", "lun2_complete.bin", "lun3_complete.bin", "lun4_complete.bin", "lun5_complete.bin")
        foreach ($file in $lunsFiles) {
            if (-not (Test-Path -Path (Join-Path $folderPath $file))) {
                $verifySuccess = $false
                break
            }
        }
    }
    
    if ($backupMode -eq "userdata") { 
        $userDataFiles = @("lun0_gpt_header.bin", "lun0_userdata.bin", "lun1_gpt_header.bin", "lun2_gpt_header.bin", "lun3_gpt_header.bin", "lun4_gpt_header.bin", "lun5_gpt_header.bin", "lun6_gpt_header.bin")
        foreach ($file in $userDataFiles) {
            if (-not (Test-Path -Path (Join-Path $folderPath $file))) {
                $verifySuccess = $false
                break
            }
        }
    }

    if ($backupMode -eq "partitions") { 
        $partitonsFiles = @("lun0_cache.bin", "lun0_frp.bin", "lun0_keystore.bin", "lun0_metadata.bin", "lun0_misc.bin", "lun0_persist.bin", "lun0_picocfg.bin", "lun0_rawdump.bin", "lun0_recovery.bin", "lun0_ssd.bin", "lun0_super.bin", "lun0_vbmeta_system.bin", "lun0_vbmeta_systembak.bin", "lun0_vm_system.bin", "lun0_vm_systembak.bin", "lun1_last_parti.bin", "lun1_xbl.bin", "lun1_xbl_config.bin", "lun2_last_parti.bin", "lun2_xblbak.bin", "lun2_xbl_configbak.bin", "lun3_align_to_128k_1.bin", "lun3_cdt.bin", "lun3_ddr.bin", "lun3_last_parti.bin", "lun3_mdmddr.bin", "lun4_abl.bin", "lun4_ablbak.bin", "lun4_aop.bin", "lun4_aopbak.bin", "lun4_apdp.bin", "lun4_bluetooth.bin", "lun4_bluetoothbak.bin", "lun4_boot.bin", "lun4_bootbak.bin", "lun4_cmnlib.bin", "lun4_cmnlib64.bin", "lun4_cmnlib64bak.bin", "lun4_cmnlibbak.bin", "lun4_devcfg.bin", "lun4_devcfgbak.bin", "lun4_devinfo.bin", "lun4_dip.bin", "lun4_dsp.bin", "lun4_dspbak.bin", "lun4_dtbo.bin", "lun4_dtbobak.bin", "lun4_featenabler.bin", "lun4_featenablerbak.bin", "lun4_hyp.bin", "lun4_hypbak.bin", "lun4_imagefv.bin", "lun4_imagefvbak.bin", "lun4_keymaster.bin", "lun4_keymasterbak.bin", "lun4_last_parti.bin", "lun4_limits.bin", "lun4_limits_cdsp.bin", "lun4_logdump.bin", "lun4_logfs.bin", "lun4_mdtp.bin", "lun4_mdtpbak.bin", "lun4_mdtpsecapp.bin", "lun4_mdtpsecappbak.bin", "lun4_modem.bin", "lun4_modembak.bin", "lun4_msadp.bin", "lun4_multiimgoem.bin", "lun4_multiimgoembak.bin", "lun4_multiimgqti.bin", "lun4_multiimgqtibak.bin", "lun4_qupfw.bin", "lun4_qupfwbak.bin", "lun4_secdata.bin", "lun4_spunvm.bin", "lun4_storsec.bin", "lun4_tz.bin", "lun4_tzbak.bin", "lun4_uefisecapp.bin", "lun4_uefisecappbak.bin", "lun4_uefivarstore.bin", "lun4_vbmeta.bin", "lun4_vbmetabak.bin", "lun4_vm_data.bin", "lun4_vm_keystore.bin", "lun4_vm_linux.bin", "lun4_vm_linuxbak.bin", "lun5_align_to_128k_2.bin", "lun5_fsc.bin", "lun5_fsg.bin", "lun5_last_parti.bin", "lun5_mdm1m9kefs1.bin", "lun5_mdm1m9kefs2.bin", "lun5_mdm1m9kefs3.bin", "lun5_mdm1m9kefsc.bin", "lun5_modemst1.bin", "lun5_modemst2.bin")
        foreach ($file in $partitonsFiles) {
            if (-not (Test-Path -Path (Join-Path $folderPath $file))) {
                $verifySuccess = $false
                break
            }
        }
    }

    if (-not $verifySuccess) {
        Write-Log "Backup verification failed: required backup sets are missing." "Error"
        return $false
    }

    $folderSize = (Get-ChildItem -Path $folderPath -Recurse | Measure-Object -Property Length -Sum).Sum
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

function Select-BackupMode {
    Write-Header " Select Backup Mode"
    Write-Host " [${cCyan}1${cReset}] Physical Binary Dump (LUNs)"
    Write-Host "     ${cGray}-> Sector-by-sector clone of physical drives (LUN 0-6).${cReset}"
    Write-Host "     ${cGray}-> Best for unbricking, GPT repair, and low-level recovery.${cReset}"
    Write-Host "     ${cGray}-> Excludes bulk of UserData to save space (~12-15 GB).${cReset}"
    Write-Host ""
    Write-Host " [${cCyan}2${cReset}] User Personal Data (UserData)"
    Write-Host "     ${cGray}-> Backup of the 'userdata' partition ONLY.${cReset}"
    Write-Host "     ${cGray}-> Includes all apps, games, photos, and internal storage files.${cReset}"
    Write-Host "     ${cGray}-> Size depends on usage (up to 128/256/512 GB).${cReset}"
    Write-Host ""
    Write-Host " [${cCyan}3${cReset}] System Partition Dump (Partitions)"
    Write-Host "     ${cGray}-> Individual file per system partition (boot, abl, system, etc.).${cReset}"
    Write-Host "     ${cGray}-> Best for general firmware backup or modding. Excludes userdata.${cReset}"
    Write-Host "     ${cGray}-> Balanced safety and manageable size (~10-15 GB).${cReset}"
    Write-Host ""

    $choice = Read-Host "Select an option"

    if ($choice -eq "1") {
        return "luns"
    } elseif ($choice -eq "2") {
        return "userdata"
    } elseif ($choice -eq "3") {
        return "partitions"
    }

    return $null
}

function Backup-Device([string]$backupMode) {
    Write-Header "Backup Device"

    if (-not (Verify-DiskSpace $backupMode)) {
        return
    }

    if (-not (Wait-UserConfirm $backupMode)) {
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
    if ($backupMode -eq "luns") {
        BackupLUNs
        $backupFolder = $LUNsBackupPath
    } elseif ($backupMode -eq "userdata") {
        BackupUserData
        $backupFolder = $UserBackupPath
    } elseif ($backupMode -eq "partitions") {
        BackupPartitions
        $backupFolder = $PartitionsBackupPath
    }

    # Post-process organization
    $newBackup = Get-ChildItem -Path $backupFolder -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $newBackup) {
        Write-Log "Could not automatically find the backup folder in $backupFolder." "Warning"
    } elseif (Verify-Backup $backupMode $newBackup.FullName) {
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

function Restore-Backup($backupInfo) {
    $flashPath = $backupInfo.Path
    $backupMode = $backupInfo.Type
    Write-Header "Restore Device"

    if (-not (Wait-UserConfirm $backupMode)) {
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
                $targetBackup = Select-BackupMode
                if ($null -ne $targetBackup) {
                    Select-Firehose
                    Backup-Device $targetBackup
                    Post-Steps
                }
            }
            "2" {
                $backupInfo = Select-BackupFolder
                if ($null -ne $backupInfo) {
                    Select-Firehose
                    Restore-Backup $backupInfo
                    Post-Steps
                }
            }
            "3" {
                $backupInfo = Select-BackupFolder
                if ($null -ne $backupInfo) {
                    Folder-Compression $backupInfo.Path
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
