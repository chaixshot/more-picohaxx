# Self-elevate to Administrator if not already running as Admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Find and install all .inf drivers in script's folder and subfolders
Get-ChildItem -Path $PSScriptRoot -Recurse -Filter "*.inf" | ForEach-Object {
    Write-Host "Installing: $($_.FullName)" -ForegroundColor Cyan
    pnputil.exe /add-driver $_.FullName /install
}