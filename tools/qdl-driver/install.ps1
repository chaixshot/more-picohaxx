# Elevated: trust the package cert, then install WinUSB for the EDL device.
# Run as administrator. Exit 0 = success (or "no matching device yet").
[CmdletBinding()]
param([switch]$Uninstall)
$ErrorActionPreference = "Stop"
$dir = $PSScriptRoot
$cer = Join-Path $dir "PicoUnlockQDL.cer"
$inf = Join-Path $dir "qdl_winusb.inf"

if ($Uninstall) {
    # Remove any published copy of our INF from the driver store.
    (pnputil /enum-drivers) -join "`n" -split "Published Name\s*:\s*" |
        ForEach-Object {
            if ($_ -match "^(oem\d+\.inf)" -and $_ -match "qdl_winusb\.inf") {
                pnputil /delete-driver $Matches[1] /uninstall /force | Out-Null
            }
        }
    Get-ChildItem Cert:\LocalMachine\Root, Cert:\LocalMachine\TrustedPublisher |
        Where-Object { $_.Subject -eq "CN=PicoUnlock QDL WinUSB (self-signed)" } |
        ForEach-Object { Remove-Item $_.PSPath -Force -ErrorAction SilentlyContinue }
    Write-Host "Uninstalled."
    exit 0
}

# The interfaces this package binds WinUSB to: EDL (qdl) + fastboot (recovery
# fastbootd and the bootloader interface).
$targets = @('USB\VID_05C6&PID_9008','USB\VID_18D1&PID_4E11','USB\VID_18D1&PID_D00D')

# Trust our self-signed catalog signer so the package validates.
Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null

# Add the package to the driver store AND install it on matching present devices.
# For a device with no other driver this binds WinUSB directly.
& pnputil /add-driver $inf /install | Out-Null

# Fallback: for any present target interface not already on WinUSB (e.g. held by
# a higher-ranked serial driver, or unbound), force our INF onto it via
# UpdateDriverForPlugAndPlayDevices + INSTALLFLAG_FORCE (0x1) -- what Zadig does.
$member = '[System.Runtime.InteropServices.DllImport("newdev.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)] public static extern bool UpdateDriverForPlugAndPlayDevices(System.IntPtr hwndParent, string HardwareId, string FullInfPath, uint InstallFlags, out bool bRebootRequired);'
Add-Type -Namespace Native -Name NewDev -MemberDefinition $member | Out-Null

foreach ($t in $targets) {
    Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like "*$t*" } | ForEach-Object {
        $svc = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_Service -ErrorAction SilentlyContinue).Data
        if ($svc -ieq 'winusb') { return }   # already good, skip this device
        $hwids = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_HardwareIds -ErrorAction SilentlyContinue).Data
        foreach ($hw in @($hwids)) {
            $reboot = $false
            if ([Native.NewDev]::UpdateDriverForPlugAndPlayDevices([IntPtr]::Zero, $hw, $inf, 1, [ref]$reboot)) {
                Write-Host "WinUSB force-bound $($_.InstanceId) via $hw."
                break
            }
        }
    }
}

Write-Host "Install complete."
exit 0