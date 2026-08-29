#Requires -Version 5.1

<#
.SYNOPSIS
    Ported QFIL Helper logic from VB.NET (clsLUNs.vb) to PowerShell.
.DESCRIPTION
    Provides functions for backing up LUNs and individual partitions using fh_loader.exe.
#>

# --- Global Variables ---
$WorkingDirectory = "tools\qpst"
$FHLoaderPath = Join-Path $ProjectRoot "$WorkingDirectory\fh_loader.exe"
$TMP = "$WorkingDirectory\TMP"
$ErrorsPath = "$WorkingDirectory\Errors"

$galoLookUp = @(@(), @(), @(), @(), @(), @(), @())
$gsBackupDir = $null
$geFailed = 0 # 0: NOERR, 1: FAILD, 2: ABORT

# --- Functions ---

function BackupLUNs
{
    if (-not (ValidateCQF))
    {
        return
    }

    ResetLookUp
    CreateBackupFolder

    # Read GPT Headers to get partition layouts for each LUN
    if (-not (ReadGPTHeaders -isTemp $true))
    {
        CleanUpBackupFolder
        ProcessCompletedMsg -isExec $false
        return
    }

    $isExec = $false

    # Iterate through LUN 0 to 6
    for ($iCnt = 0; $iCnt -le 6; $iCnt++)
    {
        $obPInfo = [PSCustomObject]@{
            iLUN = $iCnt
            iStart = 0
            sLabel = "complete"
            iSectors = 0
        }

        if (-not (CalcBounds $obPInfo))
        {
            break
        }

        $sCMDLine = BuildCommand -obPInfo $obPInfo -isTemp $false

        Write-Log "Backing up LUN $( $obPInfo.iLUN )..." "Action"
        if (-not (ExecuteCommand $sCMDLine))
        {
            break
        }

        $isExec = $true
    }

    CleanUpBackupFolder
    ProcessCompletedMsg -isExec $isExec
}

function ValidateCQF
{
    # Locate fh_loader.exe
    if (-not (Test-Path $script:FHLoaderPath))
    {
        if (Test-Path "fh_loader.exe")
        {
            $script:FHLoaderPath = (Get-Item "fh_loader.exe").FullName
        }
        else
        {
            Write-Log "fh_loader.exe not found. Please ensure QPST is installed." "Error"
            return $false
        }
    }

    # Create/Clean TMP folder
    if (-not (Test-Path $TMP ))
    {
        New-Item -ItemType Directory -Path $TMP  | Out-Null
    }
    else
    {
        Remove-Item -Path "$TMP\*" -Recurse -Force -ErrorAction SilentlyContinue
    }

    return $true
}

function ResetLookUp
{
    $script:galoLookUp = @(@(), @(), @(), @(), @(), @(), @())
}

function CreateBackupFolder
{
    $script:gsBackupDir = "$WorkingDirectory\Backup-$TimeStamp\"
    New-Item -ItemType Directory -Path $script:gsBackupDir | Out-Null
}

function ReadGPTHeaders([bool]$isTemp = $false, [bool]$isSort = $false)
{
    for ($iCnt = 0; $iCnt -le 6; $iCnt++)
    {
        $obPInfo = [PSCustomObject]@{
            iLUN = $iCnt

            iStart = 0
            iSectors = 6
        }

        $sCMDLine = BuildCommand -obPInfo $obPInfo -isTemp $isTemp
        if (-not (ExecuteCommand $sCMDLine))
        {
            return $false
        }

        LoadGPTData -obPInfo $obPInfo -isTemp $isTemp -isSort $isSort
    }
    return $true
}

function LoadGPTData($obPInfo, [bool]$isTemp, [bool]$isSort = $false)
{
    $sFileName = BuildFileName -obPInfo $obPInfo -isTemp $isTemp
    if (-not (Test-Path $sFileName))
    {
        return
    }

    $fileStream = [System.IO.File]::OpenRead($sFileName)
    $binaryReader = New-Object System.IO.BinaryReader($fileStream)

    try
    {
        # GPT Partition entries structure starts at offset 0x2000 (standard for many devices)
        # VB code uses 0x2020 as offset for First LBA
        $binaryReader.BaseStream.Position = 0x2020
        $fileLength = $binaryReader.BaseStream.Length

        while ($binaryReader.BaseStream.Position -lt ($fileLength - 128))
        {
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

            if ($iStart -eq 0 -and $sLabel -eq "")
            {
                break
            }

            $pInfo = [PSCustomObject]@{
                iLUN = $obPInfo.iLUN
                sLabel = $sLabel
                iStart = $iStart
                iEnd = $iEnd
                iSectors = ($iEnd + 1) - $iStart
            }

            $script:galoLookUp[$obPInfo.iLUN] += $pInfo

            # Move to next GPT entry (128 bytes total, we already read 96 bytes)
            $binaryReader.BaseStream.Position += 32
        }

        if ($isSort)
        {
            $script:galoLookUp[$obPInfo.iLUN] = $script:galoLookUp[$obPInfo.iLUN] | Sort-Object sLabel
        }
    }
    catch
    {
        Write-Log "Failed to parse GPT data for LUN $( $obPInfo.iLUN )" "Warning"
    }
    finally
    {
        $binaryReader.Close()
        $fileStream.Close()
    }
}

function CalcBounds($obPInfo)
{
    try
    {
        if ($obPInfo.iLUN -eq 0)
        {
            # For LUN0, we typically want the size up to userdata or the grow partition
            # Logic from VB: index = count - 3
            $lun0 = $script:galoLookUp[0]
            if ($lun0.Count -ge 3)
            {
                $targetPart = $lun0[$lun0.Count - 3]
                $obPInfo.iSectors = $targetPart.iStart + $targetPart.iSectors
                return $true
            }
        }
        else
        {
            # For other LUNs, we take the size up to the end of the last partition
            $iCnt = $obPInfo.iLUN
            $lun = $script:galoLookUp[$iCnt]
            if ($lun.Count -gt 0)
            {
                $targetPart = $lun[$lun.Count - 1]
                $obPInfo.iSectors = $targetPart.iStart + $targetPart.iSectors
                return $true
            }
        }

        # Fallback if no partitions found (unlikely for valid headers)
        $obPInfo.iSectors = 0
        return $false
    }
    catch
    {
        $script:geFailed = 1
        return $false
    }
}

function BuildCommand($obPInfo, [bool]$isTemp)
{
    $sFileName = BuildFileName -obPInfo $obPInfo -isTemp $isTemp

    $cmd = " --port=\\.\COM$ComPort"
    $cmd += " --convertprogram2read --sendimage=$sFileName"
    $cmd += " --start_sector=$( $obPInfo.iStart )"
    $cmd += " --lun=$( $obPInfo.iLUN )"
    $cmd += " --num_sectors=$( $obPInfo.iSectors )"
    $cmd += " --noprompt --showpercentagecomplete --zlpawarehost=1 --memoryname=ufs"

    return $cmd
}

function ExecuteCommand([string]$sCMDLine)
{
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $script:FHLoaderPath
    $processInfo.Arguments = $sCMDLine
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo

    try
    {
        $process.Start() | Out-Null
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        if ($stdout -like "*Failed to open com port*" -or
                $stdout -like "*ERROR: Could not write to*" -or
                $stdout -like "*SAHARA mode!!*")
        {
            Write-Log "fh_loader failed: $($stdout.Trim() )" "Error"
            $script:geFailed = 1

            # Save error log
            if (-not (Test-Path ErrorsPath))
            {
                New-Item -ItemType Directory -Path ErrorsPath | Out-Null
            }
            $errorFile = "$ErrorsPath\QFIL-Error-$TimeStamp.txt"
            Set-Content -Path $errorFile -Value ($stderr + "`n" + $stdout)

            return $false
        }
    }
    catch
    {
        Write-Log "Exception during ExecuteCommand: $( $_.Exception.Message )" "Error"
        $script:geFailed = 1
        return $false
    }

    return $true
}

function CleanUpBackupFolder()
{
    if ($null -eq $script:gsBackupDir)
    {
        return
    }
    if (Test-Path $script:gsBackupDir)
    {
        if ((Get-ChildItem -Path $script:gsBackupDir -Filter "*.bin").Count -eq 0)
        {
            Remove-Item -Path $script:gsBackupDir -Recurse -Force
        }
    }
}

function ProcessCompletedMsg([bool]$isExec = $true)
{
    [Console]::Beep(523, 150)
    [Console]::Beep(784, 300)

    if ($script:geFailed -eq 1)
    {
        Write-Log "Process finished with errors." "Error"
        $script:geFailed = 0
        return
    }

    if (-not $isExec)
    {
        return
    }

    Write-Log "Process completed successfully." "Success"
}

# --- Internal Helper ---
function BuildFileName($obPInfo, [bool]$isTemp)
{
    $sDir = if ($isTemp)
    {
        "$TMP\"
    }
    else
    {
        $script:gsBackupDir
    }
    $safeLabel = $obPInfo.sLabel -replace '[^a-zA-Z0-9_]', '_'
    return Join-Path $sDir "lun$( $obPInfo.iLUN )_$( $safeLabel ).bin"
}
