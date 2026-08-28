#Requires -Version 5.1

<#
.SYNOPSIS
    Root functions for the PicoUnlock project.
.DESCRIPTION
    Provides functionality for installing Magisk, patching the boot image,
    and flashing the patched image to achieve superuser access.
#>

# --- Root Functions ---

$Magisk = ".\tools\Magisk4Pico.apk"

function Prepare-Magisk
{
    Clear-Host
    Write-Header "Preparing Magisk"

    if (IsFastbootMode)
    {
        Fastboot-To-System
    }
    elseif (-not (IsAdbMode))
    {
        Warning-ADB
    }

    if (-not (Wait-AdbMode 100))
    {
        Warning-ADB
        return
    }

    Write-Log "Installing ${cYellow}Magisk APK${cReset}..." "Info"
    if (Test-Path $Magisk)
    {
        & $ADB install $Magisk
        if ($LASTEXITCODE -eq 0)
        {
            Write-Log "${cGreen}Magisk${cReset} installed successfully." "Success"
        }
        else
        {
            Write-Log "Failed to install ${cYellow}Magisk${cReset}." "Error"
        }
    }
    else
    {
        Write-Log "Magisk APK not found at ${cYellow}$Magisk${cReset}" "Error"
    }

    Write-Log "Important Step: You need to download the correct firmware for your device to get the ${cYellow}'boot.img'${cReset}." "Warning"
    Write-Log "Please download it from here: ${cCyan}https://owomushi.com/Pico-4-Archive/${cReset}" "Info"

    Write-Host "`nWould you like to open this URL in your browser? (${cCyan}y${cReset}/n): " -NoNewline
    $openUrl = Read-Host
    if ($openUrl -eq 'y')
    {
        Start-Process "https://owomushi.com/Pico-4-Archive/"
    }

    Write-Log "Step 2: Extract ${cYellow}'boot.img'${cReset}" "Action"
    Write-Log "Once the firmware is downloaded, extract ${cYellow}'boot.img'${cReset} from the ZIP file." "Info"

    $bootImgPath = ""
    while ($true)
    {
        Write-Host "`nEnter the full path to your extracted ${cYellow}'boot.img'${cReset} (e.g., C:\Downloads\boot.img): " -NoNewline
        $bootImgPath = Read-Host
        $bootImgPath = $bootImgPath.Trim('"').Trim()

        if ($bootImgPath -ne "" -and (Test-Path $bootImgPath -PathType Leaf))
        {
            break
        }

        Write-Log "File not found at '${cYellow}$bootImgPath${cReset}'. Please ensure the path is correct and try again." "Warning"
    }

    Write-Log "Pushing ${cYellow}'boot.img'${cReset} to device..." "Action"
    & $ADB push $bootImgPath /sdcard/Download/
    if ($LASTEXITCODE -eq 0)
    {
        Write-Log "Success! ${cYellow}'boot.img'${cReset} is now on your device in the ${cCyan}'Download'${cReset} folder." "Success"
        Write-Host "`n${cCyan}Actions on Device:${cReset}"
        Write-Host " 1. Open the ${cYellow}Magisk${cReset} app on your Pico."
        Write-Host " 2. Tap ${cYellow}'Install'${cReset} on the home page."
        Write-Host " 3. Choose ${cYellow}'Select and Patch a File'${cReset}."
        Write-Host " 4. Navigate to ${cYellow}'Download'${cReset} and select the ${cYellow}'boot.img'${cReset} you just pushed."
        Write-Host " 5. Press ${cYellow}'LET'S GO'${cReset}."
        Write-Host " 6. Wait for the process to finish."

        Write-Host "`nOnce Magisk says ${cGreen}'All done!'${cReset}, " -NoNewline
        Wait-Continue "pull the patched image back to your computer..."

        $localDir = Split-Path $bootImgPath -Parent
        Write-Log "Searching for patched image on device (${cCyan}/sdcard/Download/magisk_patched*.img${cReset})..." "Info"

        # Try to find the specific filename created by Magisk (handles both _ and - separators)
        $remoteFiles = & $ADB shell "ls /sdcard/Download/magisk_patched*.img" 2> $null
        if ($LASTEXITCODE -eq 0 -and $remoteFiles)
        {
            # Handle potential multiple files by taking the latest/first
            $remoteFile = $remoteFiles.Trim().Split("`n")[0].Trim()
            Write-Log "Found patched file: ${cCyan}$remoteFile${cReset}" "Success"

            & $ADB pull $remoteFile $localDir
            if ($LASTEXITCODE -eq 0)
            {
                $patchedLocalPath = Join-Path $localDir (Split-Path $remoteFile -Leaf)
                $script:PatchedImagePath = $patchedLocalPath
                Write-Log "Patched image pulled successfully to: ${cGreen}$patchedLocalPath${cReset}" "Success"
                Write-Log "You are now ready to flash this image in ${cCyan}fastboot${cReset} mode." "Info"
            }
            else
            {
                Write-Log "Failed to pull the patched image from the device." "Error"
            }
        }
        else
        {
            Write-Log "Could not find a file matching ${cYellow}'magisk_patched.img'${cReset} in ${cCyan}/sdcard/Download/${cReset}." "Warning"
            Write-Log "Please check the Magisk app for errors." "Warning"
        }
    }
    else
    {
        Write-Log "Failed to push ${cYellow}'boot.img'${cReset} to the device." "Error"
    }
}

function Flash-Magisk
{
    Clear-Host
    Write-Header "Flashing Magisk"
    Write-Log "This step will reboot your device into ${cCyan}bootloader${cReset} mode to flash the patched boot image." "Warning"
    Write-Host "To proceed with rebooting to bootloader, type ${cYellow}'YES'${cReset} and press Enter: " -NoNewline
    $confirmation = Read-Host
    if ($confirmation -ne 'YES')
    {
        Write-Log "Reboot to bootloader aborted by user. No changes have been made." "Warning"
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

    # Read unlock command from picounlock.txt
    if (Test-Path $Picounlock)
    {
        $unlockCmd = Get-Content $Picounlock | Select-Object -First 1
        if ($unlockCmd -match "fastboot oem pico")
        {
            Write-Log "Running unlock command: ${cCyan}$unlockCmd${cReset}" "Action"
            # Use the local fastboot path with the call operator (&)
            $cmdToRun = "& " + ($unlockCmd -replace 'fastboot', "`"$FASTBOOT`"")
            Invoke-Expression $cmdToRun
            if ($LASTEXITCODE -eq 0)
            {
                Write-Log "Unlock command executed successfully." "Success"
            }
            else
            {
                Write-Log "Failed to execute unlock command." "Error"
                Write-Log "Please make sure ${cYellow}picounlock${cReset} is successful." "Error"
                Write-Log "And do not flash ${cYellow}backup ABL${cReset} yet!" "Error"
                return
            }
        }
        else
        {
            Write-Log "First line of ${cYellow}$Picounlock${cReset} does not look like an unlock command." "Warning"
            Write-Log "Please make sure ${cYellow}picounlock${cReset} is successful" "Warning"
            return
        }
    }
    else
    {
        Write-Log "${cYellow}$Picounlock${cReset} not found." "Warning"
        Write-Log "Please make sure ${cYellow}picounlock${cReset} is successful" "Warning"
        return
    }

    # Find patched image
    $patchedImage = $null

    if ($script:PatchedImagePath -and (Test-Path $script:PatchedImagePath))
    {
        $patchedImage = Get-Item $script:PatchedImagePath
        Write-Log "Found patched image from last adb pull: ${cGreen}$( $patchedImage.FullName )${cReset}" "Success"
    }
    else
    {
        Write-Log "Searching for patched image locally..." "Info"
        $patchedImage = Get-ChildItem -Path "." -Filter "magisk_patched*.img" -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }

    if (-not $patchedImage)
    {
        Write-Log "Could not find any ${cYellow}'magisk_patched.img'${cReset} file automatically." "Warning"
        $patchedImageInput = ""
        while ($true)
        {
            Write-Host "`nEnter the full path to your ${cYellow}'magisk_patched.img'${cReset} (e.g., C:\Downloads\magisk_patched-30700_0lM5L.img): " -NoNewline
            $patchedImageInput = Read-Host
            $patchedImageInput = $patchedImageInput.Trim('"').Trim()

            if ($patchedImageInput -ne "" -and (Test-Path $patchedImageInput -PathType Leaf))
            {
                $patchedImage = Get-Item $patchedImageInput
                break
            }

            Write-Log "File not found at '${cYellow}$patchedImageInput${cReset}'. Please ensure the path is correct and try again." "Warning"
        }
    }

    if ($patchedImage)
    {
        $script:PatchedImagePath = $patchedImage.FullName
    }

    if ($patchedImage)
    {
        Write-Log "Flashing patched boot image: ${cCyan}$( $patchedImage.FullName )${cReset}" "Action"
        & $FASTBOOT flash boot $patchedImage.FullName
        if ($LASTEXITCODE -eq 0)
        {
            Write-Log "Flash successful!" "Success"
            Fastboot-To-System
        }
        else
        {
            Write-Log "Failed to flash boot image." "Error"
        }
    }
    else
    {
        Write-Log "No patched image found or selected. Aborting flash." "Error"
    }
}

function Show-RootMenu
{
    $rootQuit = $false
    while (-not $rootQuit)
    {
        Clear-Host
        Write-Header "Pico Root Menu"
        Write-Host " [${cCyan}1${cReset}] Prepare Magisk ${cDarkGray}(Install APK & Firmware link)${cReset}"
        Write-Host " [${cCyan}2${cReset}] Flash Magisk ${cDarkGray}(Fastboot)${cReset}"
        Write-Host ""
        Write-Host " [${cCyan}r${cReset}] Reboot"
        Write-Host " [${cCyan}0${cReset}] Back to Main Menu"

        $choice = Read-Host "`nSelect an option"

        switch ($choice)
        {
            "1" {
                Prepare-Magisk
            }
            "2" {
                Flash-Magisk
            }
            "r" {
                Perform-Reboot
            }
            "0" {
                $rootQuit = $true
            }
            default {
                Write-Log "Invalid option. Please try again." "Warning"
            }
        }
        if (-not $rootQuit)
        {
            Wait-Continue "return to the Root menu..."
        }
    }
}
