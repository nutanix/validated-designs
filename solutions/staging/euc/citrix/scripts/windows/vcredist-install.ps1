Function Set-Repository {
    # https://github.com/aaronparker/build-azure-lab/blob/master/rds-packer/Rds-CoreApps.ps1
    # Trust the PSGallery for installing modules
    If (Get-PSRepository | Where-Object { $_.Name -eq "PSGallery" -and $_.InstallationPolicy -ne "Trusted" }) {
        Write-Verbose "Trusting the repository: PSGallery"
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }
}

# Function to Install VcRedists via Aaron Parker
function InstallVCRedists {
    # https://docs.stealthpuppy.com/vcredist/
    Set-Repository
    Install-Module -Name VcRedist -Force
    Import-Module -Name VcRedist
    
    # Download the Redists
    if (!(Test-Path "$InstallerLocation\VcRedist")) {
        New-Item "$InstallerLocation\VcRedist" -ItemType Directory
    }
    
    Get-VcList | Get-VcRedist -Path "$InstallerLocation\VcRedist"
    # Install the Redists
    $VcList = Get-VcList
    Install-VcRedist -Path "$InstallerLocation\VcRedist" -VcList $VcList -Silent
}

InstallVCRedists