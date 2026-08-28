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
$QFILPath = "${env:ProgramFiles(x86)}\Qualcomm\QPST\bin\QFIL.exe"
$QFILHelper = Join-Path $ProjectRoot "tools\qpst\QFILHelper.exe"
$QfilAppdataPath = Join-Path $env:APPDATA "Qualcomm\QFIL"

$BackupPath = Join-Path $ProjectRoot "tools\qpst"
$FlashPath = Join-Path $BackupPath "Flash"

function Check-BackupPrerequisites
{
    Clear-Host
    Write-Header "Backup Prerequisite Checks"

    $isReady = $true

    # 1. Check if QPST is installed
    if (-not (Test-Path $QFILPath))
    {
        Write-Log "QPST does not appear to be installed on your system." "Warning"
        if (Test-Path $QPSTInstaller)
        {
            Write-Log "QPST Installer found at ${cYellow}$QPSTInstaller${cReset}." "Info"
            Write-Host "Press ${cCyan}Y${cReset} to run the installer now, or any other key to skip: " -NoNewline
            $choice = Read-Host
            if ($choice -eq 'Y' -or $choice -eq 'y')
            {
                Write-Log "Launching QPST Installer..." "Action"
                Start-Process $QPSTInstaller -Wait
                # Re-check after installation
                if (-not (Test-Path $QFILPath))
                {
                    Write-Log "QPST still not detected after installation." "Error"
                    $isReady = $false
                }
            }
            else
            {
                $isReady = $false
            }
        }
        else
        {
            Write-Log "QPST Installer not found at ${cRed}$QPSTInstaller${cReset}." "Error"
            $isReady = $false
        }
    }
    else
    {
        Write-Log "QPST installation detected." "Success"
    }

    # 2. Check for local QFILHelper
    if (-not (Test-Path $QFILHelper))
    {
        Write-Log "Required tool ${cRed}$QFILHelper${cReset} not found." "Error"
        $isReady = $false
    }
    else
    {
        Write-Log "Local tool ${cCyan}QFILHelper${cReset} found." "Success"
    }

    if (-not $isReady)
    {
        Write-Log "Some prerequisites are missing. Functions may not work correctly." "Warning"
        Wait-Continue
    }

    return $isReady
}

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

function Start-QFILHelper
{
    if (Test-Path -Path $QFILHelper)
    {
        $qfilHelperFile = Get-Item -Path $QFILHelper
        $executablePath = $qfilHelperFile.FullName
        $workingDirectory = $qfilHelperFile.DirectoryName
        # Run QFILHelper in the current window and wait
        Start-Process -FilePath $executablePath -WorkingDirectory $workingDirectory -NoNewWindow -Wait
    }
    else
    {
        Write-Log "QFILHelper.exe was not found at: $QFILHelper" "Error"
        return
    }
}

function QFIL-ShowInstructions
{
    Clear-Host
    Write-Header "QFIL Instructions"

    $comPort = Get-QualcommCOMPort
    if ($null -eq $comPort)
    {
        Write-Log "Failed to detect COM port for EDL device." "Error"
        return
    }

    Write-Host "1. QFIL Window will open shortly."
    Write-Host "2. Select Port: ${cCyan}Qualcomm HS-USB QDLoader 9008 (COM$comPort)${cReset} and press OK"
    Write-Host "3. Select Build Type: ${cCyan}Flat Build${cReset}"
    Write-Host "4. Select Programmer > Browse... > ${cCyan}$FirehoseTargetPath${cReset}"
    Write-Host "5. Bottom - Storage Type: ${cCyan}ufs${cReset}"
    Write-Host "6. Top Menu - Tools > Partition Manager > OK"
    Write-Host "7. Wait for ${cCyan}'Finish Get GPT'${cReset} in the status box."
    Write-Log "If status box displays 'Download Fail:Sahara Fail', reboot EDL and try again." "Warning"
    Write-Host "8. In Partition Manager Window > Click ${cGreen}Save Partition File${cReset}"
    Write-Host "9. Wait for ${cCyan}'Finish SavePartitionFile'${cReset} in status box."
    Write-Host "10. Minimize or leave Partition Manager open."
    Write-Host ""
    Write-Log "Once you have saved the partition file, return here and press Enter." "Action"
}

function Post-Steps
{
    Clear-Host
    Write-Header "Post Steps"
    Write-Log "Your device will not automatically reboot." "Info"
    Write-Log "Hold ${cYellow}Power Button${cReset} for 10 seconds to reboot to system." "Info"
}

# Ensure target Flash folder exists and clear it
function Clean-FlashFolder
{
    if (Test-Path -Path $FlashPath)
    {
        Write-Log "Clearing existing contents in Flash folder: $FlashPath" "Info"
        Remove-Item -Path "$FlashPath\*" -Recurse -Force -ErrorAction SilentlyContinue
    }
    else
    {
        Write-Log "Creating Flash folder: $FlashPath" "Info"
        New-Item -Path $FlashPath -ItemType Directory | Out-Null
    }
}


function Clean-QualcommAppdata
{
    if (Test-Path -Path $QfilAppdataPath)
    {
        Write-Log "Cleaning QFIL AppData folder: $QfilAppdataPath" "Info"
        Remove-Item -Path "$QfilAppdataPath\*" -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Select-BackupFolder
{
    Clear-Host
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

    $selection = Read-Host "`nSelect a backup folder [${cCyan}1-$( $backupFolders.Count )${cReset}], 'c' to cancel"

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
    Write-Log "Selected backup folder: $( $targetBackup.Name )" "Success"

    Clean-FlashFolder

    # Copy all files from selected Backup folder to Flash
    Write-Log "Copying contents from '$( $targetBackup.Name )' to 'Flash'..." "Action"
    Copy-Item -Path "$( $targetBackup.FullName )\\*" -Destination $FlashPath -Recurse -Force

    Write-Log "Flash folder prepared successfully." "Success"
    Wait-Continue

    return $targetBackup
}

function Backup-Device
{
    Clear-Host
    Write-Header "Backup Device"

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

    $latestBackup = Get-ChildItem -Path $BackupPath -Directory -Filter "Backup-*" | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    QFIL-ShowInstructions
    Write-Log "After press Enter, select ${cCyan}1-Full backup (LUN mode)${cReset}" "Info"
    Write-Log "Wait for process finish select ${cCyan}Q-Quit${cReset}" "Info"


    # Start QFIL
    Clean-QualcommAppdata
    $qfilProc = Start-Process -FilePath $QFILPath -PassThru
    Wait-Continue "launch QFILHelper and start partition backup..."

    # Start the automated helper
    Start-QFILHelper

    # Stop QFIL
    Stop-Process -InputObject $qfilProc -ErrorAction SilentlyContinue

    # Post-process organization
    $newBackup = Get-ChildItem -Path $BackupPath -Directory -Filter "Backup-*" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $latestBackup -or $latestBackup.FullName -ne $newBackup.FullName)
    {
        Write-Log "Detected new backup at: ${cCyan}$( $newBackup.FullName )${cReset}" "Success"
    }
    else
    {
        Write-Log "Could not automatically find the backup folder in tools\qpst." "Warning"
    }

    Wait-Continue
}

function Restore-Backup
{
    Clear-Host
    Write-Header "Restore Device"

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

    QFIL-ShowInstructions
    Write-Log "After press Enter, select ${cCyan}5-Flash files${cReset}" "Info"
    Write-Log "Wait for process finish select ${cCyan}Q-Quit${cReset}" "Info"


    # Start QFIL
    Clean-QualcommAppdata
    $qfilProc = Start-Process -FilePath $QFILPath -PassThru
    Wait-Continue "launch QFILHelper and start partition backup..."

    # Start the automated helper
    Start-QFILHelper

    # Stop QFIL
    Stop-Process -InputObject $qfilProc -ErrorAction SilentlyContinue

    Clean-FlashFolder
    Wait-Continue
}

function Show-BackupRestoreMenu
{
    if (Check-BackupPrerequisites)
    {
        Clear-Host
    }

    $menuQuit = $false
    while (-not $menuQuit)
    {
        Clear-Host
        Write-Header "Backup/Restore Menu"
        Write-Host " [${cCyan}1${cReset}] Backup Device"
        Write-Host " [${cCyan}2${cReset}] Restore Device"
        Write-Host ""
        Write-Host " [${cCyan}r${cReset}] Reboot to System"
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
                    Post-Steps
                }
            }
            "r" {
                Reboot-System
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
