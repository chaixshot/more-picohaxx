# Self-elevate to Administrator if not already running as Admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Find and install all .inf drivers in script's folder and subfolders
Get-ChildItem -Path $PSScriptRoot -Recurse -Filter "*.inf" | ForEach-Object {
    $infName = $_.Name
    $drivers = pnputil /enum-drivers

    # Identify and remove any existing drivers with the same original name
    $found = $false
    $publishedName = $null

    # Iterate through pnputil output to find Published Name associated with the Original Name
    for ($i = 0; $i -lt $drivers.Count; $i++) {
        $line = $drivers[$i]
        if ($line -match "Original Name:\s+$infName") {
            # Found the original name, now look back for the Published Name (it appears earlier in the same block)
            for ($j = $i; $j -ge 0; $j--) {
                if ($drivers[$j] -match "Published Name:\s+(oem\d+\.inf)") {
                    $publishedName = $matches[1]
                    Write-Host "Force removing existing driver: $publishedName ($infName)" -ForegroundColor Yellow
                    pnputil /delete-driver $publishedName /uninstall /force | Out-Null
                    break
                }
                # Stop if we hit a previous block
                if ($drivers[$j] -match "Published Name:" -and $j -lt $i -and $drivers[$j] -notmatch $publishedName) {
                    break
                }
            }
        }
    }

    Write-Host "Installing: $($_.FullName)" -ForegroundColor Cyan
    pnputil.exe /add-driver $_.FullName /install
}
