# --- Backup/Restore Functions ---

$QPSTInstaller = ".\tools\qpst\QPST Tool v2.7.496.exe"
$QFILPath = "${env:ProgramFiles(x86)}\Qualcomm\QPST\bin\QFIL.exe"
$QFILHelper = ".\tools\qpst\QFILHelper.exe"

function Check-BackupPrerequisites
{
    Write-Header "Backup Prerequisite Checks"

    $isReady = $true

    # 1. Check if QPST is installed
    if (-not (Test-Path $QFILPath))
    {
        Write-Log "QPST does not appear to be installed on your system." "Warning"
        if (Test-Path $QPSTInstaller)
        {
            Write-Log "QPST Installer found at ${cYellow}$QPSTInstaller${cReset}." "Info"
            Write-Host "Press " -NoNewline
            Write-Host "Y" -ForegroundColor Cyan -NoNewline
            Write-Host " to run the installer now, or any other key to skip: " -NoNewline
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
    $ProjectRoot = Split-Path -Path $PSScriptRoot -Parent
    $QFILHelperFullPath = Join-Path -Path $ProjectRoot -ChildPath $QFILHelper
    if (-not (Test-Path $QFILHelperFullPath))
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
        Write-Log "Some backup/restore prerequisites are missing. Functions may not work correctly." "Warning"
        Wait-Continue
    }

    return $isReady
}

function Get-QualcommCOMPort
{
    Write-Log "Scanning for Qualcomm Emergency Download (EDL) device..." "Info"

    # Query WMI for devices matching "Qualcomm" and "9008" or "QDLoader"
    $Device = Get-CimInstance -ClassName Win32_PnPEntity |
            Where-Object { $_.Name -match "Qualcomm.*QDLoader.*9008|Qualcomm.*HS-USB.*9008" } |
            Select-Object -First 1

    if ($Device -and $Device.Name -match '\(COM(\d+)\)')
    {
        # Extract the digit inside (COMx)
        return [int]$Matches[1]
    }
    return $null
}

function Start-QFILHelper
{
    $ProjectRoot = Split-Path -Path $PSScriptRoot -Parent
    $QFILHelperFullPath = Join-Path -Path $ProjectRoot -ChildPath $QFILHelper
    if (Test-Path -Path $QFILHelperFullPath)
    {
        $QFILHelperFile = Get-Item -Path $QFILHelperFullPath
        $ExecutablePath = $QFILHelperFile.FullName
        $WorkingDirectory = $QFILHelperFile.DirectoryName
        # Run QFILHelper in the current window and wait
        Start-Process -FilePath $ExecutablePath -WorkingDirectory $WorkingDirectory -NoNewWindow -Wait
    }
    else
    {
        Write-Log "QFILHelper.exe was not found at: $QFILHelperFullPath" "Error"
        return
    }
}

function Backup-Device
{
    Clear-Host
    Write-Header "Backup Device"

    Select-Firehose

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

    $COMPort = Get-QualcommCOMPort
    if ($null -eq $COMPort)
    {
        Write-Log "Failed to detect COM port for EDL device." "Error"
        return
    }

    Write-Log "EDL Device detected on COM$COMPort" "Success"
    Write-Host ""
    Write-Host "--- QFIL Backup Instructions ---" -ForegroundColor Yellow
    Write-Host "1. QFIL Window will open shortly."
    Write-Host "2. Select Port: ${cCyan}Qualcomm HS-USB QDLoader 9008 (COM$COMPort)${cReset} and press OK"
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
    Write-Log "After press Enter, select ${cCyan}1-Full backup (LUN mode)${cReset}" "Info"
    Write-Log "Wait for process finish select ${cCyan}Q-Quit${cReset}" "Info"
    Write-Host ""

    # Start QFIL
    Start-Process -FilePath $QFILPath

    Wait-Continue "launch QFILHelper and start partition backup..."

    # Start the automated helper
    Start-QFILHelper
    Clear-Host

    # Post-process organization
    $ProjectRoot = Split-Path -Path $PSScriptRoot -Parent
    $QPSTToolsDir = Join-Path $ProjectRoot "tools\qpst"
    $LatestBackup = Get-ChildItem -Path $QPSTToolsDir -Directory -Filter "Backup-*" | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if ($LatestBackup)
    {
        Write-Log "Detected new backup at: ${cCyan}$($LatestBackup.FullName)${cReset}" "Success"
    }
    else
    {
        Write-Log "Could not automatically find the backup folder in tools\qpst." "Warning"
    }

    Write-Host ""
    Write-Host "--- Post-Backup Steps ---" -ForegroundColor Yellow
    Write-Host "1. Close ${cCyan}Partition Manager${cReset} window > Press OK to reset EDL."
    Write-Host "2. Wait for ${cCyan}'Finish Reset to EDL'${cReset} in status box, then close QFIL."
    Write-Host "3. Hold ${cYellow}Power Button${cReset} for 10 seconds to reboot to system."
    Write-Host ""
}

function Restore-Backup
{
    Clear-Host
    Write-Header "Restore Device"
    
    Select-Firehose
}

function Show-BackupRestoreMenu
{
    # Run prerequisite checks once when entering the menu
    Clear-Host
    if (-not (Check-BackupPrerequisites))
    {
        Write-Log "Prerequisite checks failed. Some features may not work." "Warning"
        Wait-Continue
    }
    else
    {
        Clear-Host
    }

    # Ensure firehose is known
    if ($null -eq $FirehoseTargetPath)
    {
        Select-Firehose
    }

    $menuQuit = $false
    while (-not $menuQuit)
    {
        Clear-Host
        Write-Header "Pico Backup/Restore Menu"
        Write-Host " [" -NoNewline -ForegroundColor DarkGray
        Write-Host "1" -NoNewline -ForegroundColor Cyan
        Write-Host "] " -NoNewline -ForegroundColor DarkGray
        Write-Host "Backup Device (LUN Mode)"

        Write-Host " [" -NoNewline -ForegroundColor DarkGray
        Write-Host "2" -NoNewline -ForegroundColor Cyan
        Write-Host "] " -NoNewline -ForegroundColor DarkGray
        Write-Host "Restore Device (Partition Manager)"

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

        switch ($choice)
        {
            "1" {
                Backup-Device
            }
            "2" {
                Restore-Backup
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
