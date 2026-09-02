#Requires -Version 5.1

<#
.SYNOPSIS
    Ported QFIL Helper logic from VB.NET (clsLUNs.vb) to PowerShell.
.DESCRIPTION
    Provides functions for backing up LUNs and individual partitions using fh_loader.exe.
#>

# --- Local Variables ---
$workingDirectory = "tools\qpst"
$qpstTMP = "$workingDirectory\TMP"
$portTrace = "$LogsPath\${TimeStamp}_port_trace.txt"
$fhLoader = "$workingDirectory\fh_loader.exe"

$galoLookUp = @(@(), @(), @(), @(), @(), @(), @())
$gsBackupDir = $null
$geFailed = 0 # 0: NOERR, 1: FAILD, 2: ABORT

# --- Functions ---

function BackupLUNs {
    if (-not (ValidateCQF)) {
        return
    }

    ResetLookUp
    CreateBackupFolder

    # Read GPT Headers to get partition layouts for each LUN
    if (-not (ReadGPTHeaders -isTemp $true)) {
        CleanUpBackupFolder
        ProcessCompleted -isExec $false
        return
    }

    $isExec = $false

    # Iterate through LUN 0 to 6
    Display-DontInterrupt
    $total = 6

    for ($iCnt = 0; $iCnt -le $total; $iCnt++) {
        Write-Progress -Activity "Backing up LUNs" -Status "Processing LUN $iCnt (Progress: $([math]::Round(($iCnt / 7) * 100) )%)" -PercentComplete (($iCnt / 7) * 100)

        $obPInfo = [PSCustomObject]@{
            iLUN     = $iCnt
            iStart   = 0
            iEnd     = 0
            sLabel   = "complete"
            iSectors = 0
        }

        if (-not (CalcBounds $obPInfo)) {
            break
        }

        $sCMDLine = BuildCommand -obPInfo $obPInfo -isTemp $false

        Write-Log "[$( $iCnt + 1 )/$total] Backing up LUN '${cCyan}$( $obPInfo.iLUN )${cReset}'..." "Action"
        if (-not (ExecuteCommand $sCMDLine)) {
            break
        }

        $isExec = $true
    }

    Write-Progress -Activity "Backing up LUNs" -Completed
    CleanUpBackupFolder
    ProcessCompleted -isExec $isExec
}

function BackupUserData {
    if (-not (ValidateCQF)) {
        return
    }

    ResetLookUp
    CreateBackupFolder

    # Read GPT Headers with sorting enabled to allow looking up partition names
    if (-not (ReadGPTHeaders -isTemp $false -isSort $true)) {
        CleanUpBackupFolder
        ProcessCompleted -isExec $false
        return
    }

    $obPInfo = [PSCustomObject]@{
        sLabel   = "userdata"
        iLUN     = $null
        iStart   = 0
        iEnd     = 0
        iSectors = 0
    }

    if (-not (LookUpNames $obPInfo)) {
        Write-Log "Failed to resolve LUN and sectors for partition 'userdata'." "Error"
        CleanUpBackupFolder
        ProcessCompleted -isExec $false
        return
    }

    $sCMDLine = BuildCommand -obPInfo $obPInfo -isTemp $false

    Display-DontInterrupt
    Write-Progress -Activity "Backing up UserData" -Status "Backing up partition 'userdata'..." -PercentComplete 50
    Write-Log "Backing up partition '${cCyan}$( $obPInfo.sLabel )${cReset}'..." "Action"
    if (-not (ExecuteCommand $sCMDLine)) {
        Write-Progress -Activity "Backing up UserData" -Completed
        CleanUpBackupFolder
        ProcessCompleted -isExec $false
        return
    }

    Write-Progress -Activity "Backing up UserData" -Completed
    CleanUpBackupFolder
    ProcessCompleted -isExec $true
}

function BackupPartitions {
    if (-not (ValidateCQF)) {
        return
    }

    ResetLookUp
    CreateBackupFolder

    # Read GPT Headers to populate $galoLookUp
    if (-not (ReadGPTHeaders -isTemp $true)) {
        CleanUpBackupFolder
        ProcessCompleted -isExec $false
        return
    }

    $isExec = $false

    # Calculate total partitions to back up
    $totalParts = 0
    for ($i = 0; $i -le 6; $i++) {
        foreach ($part in $galoLookUp[$i]) {
            if ($part.sLabel -ne "userdata") {
                $totalParts++
            }
        }
    }
    $currentPart = 0

    # Iterate through LUN 0 to 6
    Display-DontInterrupt
    for ($iLUN = 0; $iLUN -le 6; $iLUN++) {
        foreach ($part in $galoLookUp[$iLUN]) {
            # Skip userdata partition as it's handled separately
            if ($part.sLabel -eq "userdata") {
                continue
            }

            $currentPart++
            Write-Progress -Activity "Backing up Partitions" -Status "Processing partition '$( $part.sLabel )' (LUN $iLUN)..." -PercentComplete (($currentPart / $totalParts) * 100)

            $obPInfo = [PSCustomObject]@{
                iLUN     = $part.iLUN
                sLabel   = $part.sLabel
                iStart   = $part.iStart
                iEnd     = $part.iEnd
                iSectors = $part.iSectors
            }

            $sCMDLine = BuildCommand -obPInfo $obPInfo -isTemp $false
            Write-Log "Backing up partition '${cCyan}$( $obPInfo.sLabel )${cReset}' (LUN $( $obPInfo.iLUN ))..." "Action"

            if (-not (ExecuteCommand $sCMDLine)) {
                $script:geFailed = 1
                break
            }
            $isExec = $true
        }

        if ($geFailed -eq 1) {
            break
        }
    }

    Write-Progress -Activity "Backing up Partitions" -Completed
    CleanUpBackupFolder
    ProcessCompleted -isExec $isExec
}

function FlashFirmware([string]$FlashPath = "") {
    if ( [string]::IsNullOrEmpty($FlashPath)) {
        return
    }

    if (-not (ValidateCQF)) {
        return
    }

    ResetLookUp

    # Read GPT Headers to get partition layouts for each LUN
    if (-not (ReadGPTHeaders -isTemp $true)) {
        ProcessCompleted -isExec $false
        return
    }

    $flashList = LoadFileList -FlashPath $FlashPath
    if ($flashList.Count -eq 0) {
        Write-Log "No firmware files found in '${cCyan}${FlashPath}${cCyan}'." "Error"
        ProcessCompleted -isExec $false
        return
    }

    $isExec = $false
    Display-DontInterrupt

    # Flash LUNs
    if (-not (FlashLUNs -flashList $flashList -FlashPath $FlashPath)) {
        ProcessCompleted -isExec $isExec
        return
    }
    if ($flashList.LUNs.Count -gt 0) {
        $isExec = $true
    }

    # Flash GPTs
    if (-not (FlashGPTs -flashList $flashList -FlashPath $FlashPath)) {
        ProcessCompleted -isExec $isExec
        return
    }
    if ($flashList.GPTs.Count -gt 0) {
        $isExec = $true
    }

    # Re-read GPT headers before flashing partitions to ensure we use the new layout
    if (-not (ReadGPTHeaders -isTemp $true -isSort $true)) {
        ProcessCompleted -isExec $isExec
        return
    }

    # Flash Partitions
    $totalParts = $flashList.Partitions.Count
    for ($i = 0; $i -lt $totalParts; $i++) {
        $fileInfo = $flashList.Partitions[$i]
        Write-Progress -Activity "Flashing Firmware" -Status "Flashing partition '$( $fileInfo.sLabel )'..." -PercentComplete (($i / $totalParts) * 100)

        $obPInfo = [PSCustomObject]@{
            sLabel   = $fileInfo.sLabel
            iLUN     = $fileInfo.iLUN
            iStart   = 0
            iEnd     = 0
            iSectors = 0
        }

        if (-not (LookUpNames $obPInfo)) {
            Display-NotFound -obPInfo $obPInfo
            continue
        }

        $sCMDLine = BuildCommand -obPInfo $obPInfo -isTemp $false -isFlash $true -FlashPath $FlashPath
        Write-Log "[$( $i + 1 )/$totalParts] Flashing partition '${cCyan}$( $obPInfo.sLabel )${cReset}'..." "Action"
        if (-not (ExecuteCommand $sCMDLine)) {
            break
        }
        $isExec = $true
    }

    Write-Progress -Activity "Flashing Firmware" -Completed
    ProcessCompleted -isExec $isExec
}

function LoadFileList([string]$FlashPath) {
    $flashList = [PSCustomObject]@{
        LUNs       = @()
        GPTs       = @()
        Partitions = @()
        Count      = 0
    }

    if (-not (Test-Path $FlashPath)) {
        return $flashList
    }

    $files = Get-ChildItem -Path $FlashPath -Filter "*.bin"
    foreach ($file in $files) {
        $name = $file.BaseName.ToLower()

        # Determine if it needs renaming (Short2Long)
        if (-not $name.StartsWith("lun")) {
            $name = Short2Long -fileName $file.Name -FlashPath $FlashPath
            if ($null -eq $name) {
                continue
            }
        }

        # Parse name: lunX_label.bin or lunX.bin or lunX_gpt.bin
        if ($name -match "^lun(\d+)$" -or $name -match "^lun(\d+)_complete$") {
            $sLabel = if ( $name.Contains("_complete")) {
                "complete"
            } else {
                ""
            }
            $flashList.LUNs += [PSCustomObject]@{ iLUN = [int]$matches[1]; sLabel = $sLabel; Path = $file.FullName }
            $flashList.Count++
        } elseif ($name -match "^lun(\d+)_gpt$" -or $name -match "^lun(\d+)_gpt_header$") {
            $sLabel = if ( $name.Contains("_gpt_header")) {
                "gpt_header"
            } else {
                "gpt"
            }
            $flashList.GPTs += [PSCustomObject]@{ iLUN = [int]$matches[1]; sLabel = $sLabel; Path = $file.FullName }
            $flashList.Count++
        } elseif ($name -match "^lun(\d+)_(.+)$") {
            $flashList.Partitions += [PSCustomObject]@{
                iLUN   = [int]$matches[1]
                sLabel = $matches[2]
                Path   = $file.FullName
            }
            $flashList.Count++
        }
    }

    return $flashList
}

function FlashLUNs($flashList, [string]$FlashPath) {
    $total = $flashList.LUNs.Count
    for ($i = 0; $i -lt $total; $i++) {
        $lunFile = $flashList.LUNs[$i]
        Write-Progress -Activity "Flashing LUNs" -Status "Flashing LUN $( $lunFile.iLUN )..." -PercentComplete (($i / $total) * 100)

        $obPInfo = [PSCustomObject]@{
            sLabel   = $lunFile.sLabel
            iLUN     = $lunFile.iLUN
            iStart   = 0
            iEnd     = 0
            iSectors = 0
        }

        $sCMDLine = BuildCommand -obPInfo $obPInfo -isTemp $false -isFlash $true -FlashPath $FlashPath
        Write-Log "[$( $i + 1 )/$total] Flashing LUN '${cCyan}$( $obPInfo.iLUN )${cReset}'..." "Action"
        if (-not (ExecuteCommand $sCMDLine)) {
            Write-Progress -Activity "Flashing LUNs" -Completed
            return $false
        }
    }
    Write-Progress -Activity "Flashing LUNs" -Completed
    return $true
}

function FlashGPTs($flashList, [string]$FlashPath) {
    $total = $flashList.GPTs.Count
    for ($i = 0; $i -lt $total; $i++) {
        $gptFile = $flashList.GPTs[$i]
        Write-Progress -Activity "Flashing GPTs" -Status "Flashing GPT for LUN $( $gptFile.iLUN )..." -PercentComplete (($i / $total) * 100)

        $obPInfo = [PSCustomObject]@{
            sLabel   = $gptFile.sLabel
            iLUN     = $gptFile.iLUN
            iStart   = 0
            iEnd     = 0
            iSectors = 0
        }

        $sCMDLine = BuildCommand -obPInfo $obPInfo -isTemp $false -isFlash $true -FlashPath $FlashPath
        Write-Log "[$( $i + 1 )/$total] Flashing GPT for LUN '${cCyan}$( $obPInfo.iLUN )${cReset}'..." "Action"
        if (-not (ExecuteCommand $sCMDLine)) {
            Write-Progress -Activity "Flashing GPTs" -Completed
            return $false
        }
    }
    Write-Progress -Activity "Flashing GPTs" -Completed
    return $true
}

function Short2Long($fileName, [string]$FlashPath) {
    # Check all LUNs for a partition matching the filename
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    for ($i = 0; $i -le 6; $i++) {
        foreach ($part in $galoLookUp[$i]) {
            if ($part.sLabel -eq $baseName) {
                $newName = "lun$( $i )_$( $baseName ).bin"
                $oldPath = Join-Path $FlashPath $fileName
                $newPath = Join-Path $FlashPath $newName

                Write-Log "Renaming '${cCyan}$fileName${cReset}' to '${cCyan}$newName${cReset}'..." "Info"
                try {
                    Rename-Item -Path $oldPath -NewName $newName -ErrorAction Stop
                    return [System.IO.Path]::GetFileNameWithoutExtension($newName).ToLower()
                } catch {
                    Write-Log "Failed to rename '${cCyan}$fileName${cReset}': ${cCyan}$( $_.Exception.Message )${cReset}" "Error"
                    return $null
                }
            }
        }
    }
    return $null
}

function Display-NotFound($obPInfo) {
    Write-Log "Partition '$( $obPInfo.sLabel )' not found on device (LUN $( $obPInfo.iLUN )). Skipping." "Warning"
}

function Display-DontInterrupt {
    Write-Log "Do not disconnect the device and interrupt the process." "Warning"
    Write-Log "In the ${cCyan}restore process${cReset}, getting interrupted might brick the device." "Warning"
    Write-Log "In the ${cCyan}backup process${cReset}, getting interrupted might cause the backup data to collapse, but the device is fine." "Warning"
}

function LookUpNames($obPInfo) {
    $targetLabel = $obPInfo.sLabel.ToLower()
    $iLBound = 0
    $iUBound = $galoLookUp.Count - 1

    if ($null -ne $obPInfo.iLUN) {
        $iLBound = $obPInfo.iLUN
        $iUBound = $obPInfo.iLUN
    }

    for ($i = $iLBound; $i -le $iUBound; $i++) {
        foreach ($part in $galoLookUp[$i]) {
            if ($part.sLabel -eq $targetLabel) {
                # Update the object with found values
                $obPInfo.iLUN = $part.iLUN
                $obPInfo.iStart = $part.iStart
                $obPInfo.iEnd = $part.iEnd
                $obPInfo.iSectors = $part.iSectors
                return $true
            }
        }
    }
    return $false
}

function ValidateCQF {
    # Create/Clean TMP folder
    if (-not (Test-Path $qpstTMP)) {
        New-Item -ItemType Directory -Path $qpstTMP  | Out-Null
    } else {
        Remove-Item -Path "$qpstTMP\*" -Recurse -Force -ErrorAction SilentlyContinue
    }

    return $true
}

function ResetLookUp {
    $script:galoLookUp = @(@(), @(), @(), @(), @(), @(), @())
}

function CreateBackupFolder {
    $script:gsBackupDir = "$UserBackupPath\Backup-$TimeStamp\"
    New-Item -ItemType Directory -Path $gsBackupDir | Out-Null
}

function ReadGPTHeaders([bool]$isTemp = $false, [bool]$isSort = $false) {
    for ($iCnt = 0; $iCnt -le 6; $iCnt++) {
        Write-Progress -Activity "Reading GPT Headers" -Status "Reading LUN $iCnt..." -PercentComplete (($iCnt / 7) * 100)

        $obPInfo = [PSCustomObject]@{
            sLabel   = "gpt_header"
            iLUN     = $iCnt
            iStart   = 0
            iEnd     = 0
            iSectors = 6
        }

        $sCMDLine = BuildCommand -obPInfo $obPInfo -isTemp $isTemp
        if (-not (ExecuteCommand $sCMDLine)) {
            Write-Progress -Activity "Reading GPT Headers" -Completed
            return $false
        }

        LoadGPTData -obPInfo $obPInfo -isTemp $isTemp -isSort $isSort
    }
    Write-Progress -Activity "Reading GPT Headers" -Completed
    return $true
}

function LoadGPTData($obPInfo, [bool]$isTemp, [bool]$isSort = $false) {
    $sFileName = BuildFileName -obPInfo $obPInfo -isTemp $isTemp
    if (-not (Test-Path $sFileName)) {
        return
    }

    $fileStream = [System.IO.File]::OpenRead($sFileName)
    $binaryReader = New-Object System.IO.BinaryReader($fileStream)

    try {
        # GPT Partition entries structure starts at offset 0x2000 (standard for many devices)
        # VB code uses 0x2020 as offset for First LBA
        $binaryReader.BaseStream.Position = 0x2020
        $fileLength = $binaryReader.BaseStream.Length

        while ($binaryReader.BaseStream.Position -lt ($fileLength - 128)) {
            # Read first LBA (8 bytes)
            $iaStart = $binaryReader.ReadBytes(8)
            $iStart = [BitConverter]::ToUInt64($iaStart, 0)

            # Read last LBA (8 bytes)
            $iaEnd = $binaryReader.ReadBytes(8)
            $iEnd = [BitConverter]::ToUInt64($iaEnd, 0)

            $binaryReader.BaseStream.Position += 8 # Skip attributes

            # Read partition name (72 bytes, UTF-16LE)
            $iaLabel = $binaryReader.ReadBytes(72)
            $sLabel = [System.Text.Encoding]::Unicode.GetString($iaLabel).Replace("`0", "").Trim().ToLower()

            if ($iStart -eq 0 -and $sLabel -eq "") {
                break
            }

            $pInfo = [PSCustomObject]@{
                iLUN     = $obPInfo.iLUN
                sLabel   = $sLabel
                iStart   = $iStart
                iEnd     = $iEnd
                iSectors = ($iEnd + 1) - $iStart
            }

            $script:galoLookUp[$obPInfo.iLUN] += $pInfo

            # Move to next GPT entry (128 bytes total, we already read 96 bytes)
            $binaryReader.BaseStream.Position += 32
        }

        if ($isSort) {
            $script:galoLookUp[$obPInfo.iLUN] = $galoLookUp[$obPInfo.iLUN] | Sort-Object sLabel
        }
    } catch {
        Write-Log "Failed to parse GPT data for LUN '${cCyan}$( $obPInfo.iLUN )${cReset}'" "Warning"
    } finally {
        $binaryReader.Close()
        $fileStream.Close()
    }
}

function CalcBounds($obPInfo) {
    try {
        if ($obPInfo.iLUN -eq 0) {
            # For LUN0, we typically want the size up to userdata or the grow partition
            # Logic from VB: index = count - 3
            $lun0 = $galoLookUp[0]
            if ($lun0.Count -ge 3) {
                $targetPart = $lun0[$lun0.Count - 3]
                $obPInfo.iSectors = $targetPart.iStart + $targetPart.iSectors
                return $true
            }
        } else {
            # For other LUNs, we take the size up to the end of the last partition
            $iCnt = $obPInfo.iLUN
            $lun = $galoLookUp[$iCnt]
            if ($lun.Count -gt 0) {
                $targetPart = $lun[$lun.Count - 1]
                $obPInfo.iSectors = $targetPart.iStart + $targetPart.iSectors
                return $true
            }
        }

        # Fallback if no partitions found (unlikely for valid headers)
        $obPInfo.iSectors = 0
        return $false
    } catch {
        $script:geFailed = 1
        return $false
    }
}

function BuildCommand($obPInfo, [bool]$isTemp, [bool]$isFlash = $false, [string]$FlashPath = "") {
    $sFileName = BuildFileName -obPInfo $obPInfo -isTemp $isTemp -isFlash $isFlash -FlashPath $FlashPath

    $cmd = " --port=\\.\COM$ComPort"
    if ($isFlash) {
        $cmd += " --sendimage=$sFileName"
    } else {
        $cmd += " --convertprogram2read --sendimage=$sFileName"
    }
    $cmd += " --start_sector=$( $obPInfo.iStart )"
    $cmd += " --lun=$( $obPInfo.iLUN )"
    if (-not $isFlash) {
        $cmd += " --num_sectors=$( $obPInfo.iSectors )"
    }
    $cmd += " --noprompt --showpercentagecomplete --zlpawarehost=1 --memoryname=ufs --loglevel=0 --porttracename=${portTrace}"

    return $cmd
}

function ExecuteCommand([string]$sCMDLine) {
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $fhLoader
    $processInfo.Arguments = $sCMDLine
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo

    try {
        $process.Start() | Out-Null
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        if ($process.ExitCode -ne 0 -or
            $stdout -like "*Failed to open com port*" -or
            $stdout -like "*ERROR: Could not write to*" -or
            $stdout -like "*SAHARA mode!!*") {
            Write-Log "fh_loader failed: ${cCyan}$($stdout.Trim() )${cReset}" "Error"
            Write-Log "ExitCode: $($process.ExitCode)" "Error"
            $script:geFailed = 1

            # Save error log
            if (-not (Test-Path $LogsPath)) {
                New-Item -ItemType Directory -Path $LogsPath | Out-Null
            }
            $errorLog = "$LogsPath\${TimeStamp}_qfilerror.log"
            Set-Content -Path $errorLog -Value ($stderr + "`n" + $stdout)

            return $false
        }
    } catch {
        Write-Log "Exception during ExecuteCommand: ${cCyan}$( $_.Exception.Message )${cReset}" "Error"
        $script:geFailed = 1
        return $false
    }

    return $true
}

function CleanUpBackupFolder() {
    if ($null -eq $gsBackupDir) {
        return
    }
    if (Test-Path $gsBackupDir) {
        if ((Get-ChildItem -Path $gsBackupDir -Filter "*.bin").Count -eq 0) {
            Remove-Item -Path $gsBackupDir -Recurse -Force
        }
    }
}

function ProcessCompleted([bool]$isExec = $true) {
    Play-BeepBeep

    # Delete /tools/qpst/TMP folder
    if (Test-Path -Path $qpstTMP) {
        Write-Log "Deleting ${cCyan}$( $qpstTMP )${cReset} folder..." "Action"
        Remove-Item -Path $qpstTMP -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($geFailed -eq 1) {
        Write-Log "Process finished with errors." "Error"
        $script:geFailed = 0
        return
    }

    if (-not $isExec) {
        return
    }

    Write-Log "Process completed successfully." "Success"
}

# --- Internal Helper ---
function BuildFileName($obPInfo, [bool]$isTemp, [bool]$isFlash = $false, [string]$FlashPath = "") {
    $sDir = if ($isFlash) {
        $FlashPath
    } elseif ($isTemp) {
        "$qpstTMP\"
    } else {
        $gsBackupDir
    }

    $sName = "lun$( $obPInfo.iLUN )"
    if ($isFlash) {
        if (-not [string]::IsNullOrEmpty($obPInfo.sLabel)) {
            $sName += "_$( $obPInfo.sLabel )"
        }
    } else {
        if (-not [string]::IsNullOrEmpty($obPInfo.sLabel)) {
            $safeLabel = $obPInfo.sLabel -replace '[^a-zA-Z0-9_]', '_'
            $sName += "_$safeLabel"
        }
    }

    return Join-Path $sDir "$sName.bin"
}
