<#
.SYNOPSIS
Live/online adaptation of ntdevlabs' tiny11builder debloat steps.

.DESCRIPTION
tiny11builder (https://github.com/ntdevlabs/tiny11builder) works by mounting an OFFLINE
install.wim and stripping bloat before deployment. This script instead applies the SAME
set of removals/tweaks to your CURRENTLY RUNNING Windows install - which is what you want
when your workflow is:
    1. Fresh install -> fully patch via Windows Update
    2. Run THIS script to debloat live (this file)
    3. Delete throwaway account
    4. Sysprep /generalize /oobe /shutdown
    5. Boot WinPE, dism /capture-image the drive into a fresh install.wim
    6. Pack that wim into a new ISO

Run this AFTER Windows Update is fully finished and BEFORE you delete the throwaway
account and sysprep. Run it as Administrator.

.NOTES
Source reference: ntdevlabs/tiny11builder tiny11maker.ps1 (release 09-07-25)
This is not the tiny11 project's own code - it is a rewrite of its DISM/registry actions
targeting an online system (/Online instead of /Image:<mount>, HKLM/HKCU directly instead
of loading offline hives under z-prefixed keys).
#>

#Requires -RunAsAdministrator

# ===========================================================================
# ============================ FILL THIS OUT ===============================
# ===========================================================================
# Leave any value as "" (empty string) to skip that step.

# Shown as the build name/edition string. Written into Registered Owner /
# a custom "BuildLabName" style string, and used as the OEM Model field.
$BuildName = ""                      # e.g. "MyCorp Windows 11 Lite"

# Local path OR URL to a logo image. If a URL, it's downloaded first.
# Ideally a BMP under 120x120, but if it's a PNG/JPG this script converts it.
$LogoSource = ""                     # e.g. "https://example.com/logo.png" or "C:\logo.bmp"

# One or more URLs to .themepack / .deskthemepack files. ALL of them get
# downloaded and installed as selectable themes. The FIRST one in the list
# is also set as the default theme for new users.
$ThemepackUrls = @(
     "https://github.com/IshikDeveloper/makdows/raw/refs/heads/11/Makdows11.themepack",
     "https://github.com/IshikDeveloper/makdows/raw/refs/heads/11/CatppuccinMocha.themepack"  
)

# URL or local path to the image shown during first-boot OOBE setup.
$OobeWallpaperSource = "https://github.com/IshikDeveloper/makdows/blob/11/mak.png"            # e.g. "https://example.com/oobe.jpg"

# URL or local path to the lock screen image.
$LockscreenWallpaperSource = "https://github.com/IshikDeveloper/makdows/blob/11/mak.png"      # e.g. "https://example.com/lock.jpg"

# URL or local path to the image shown during the blue "Setup" / install
# screens (this is the one that gets resized/converted automatically,
# since Setup is picky about exact dimensions and BMP format).
$SetupWallpaperSource = "https://github.com/IshikDeveloper/makdows/blob/11/mak.png"           # e.g. "https://example.com/setup.jpg"

# ===========================================================================
# =========================== END OF CONFIG ================================
# ===========================================================================

$ErrorActionPreference = 'Continue'
Start-Transcript -Path "$PSScriptRoot\live-debloat_$(Get-Date -f yyyyMMdd_HHmms).log"

# -------------------------------------------------------------------------
# Helper: resolve a config value that may be a URL or a local file path,
# downloading it to a temp working folder if needed. Returns local path,
# or $null if the source was left blank or failed.
# -------------------------------------------------------------------------
$BrandingWorkDir = "$env:TEMP\branding-assets"
New-Item -Path $BrandingWorkDir -ItemType Directory -Force | Out-Null

function Resolve-Asset {
    param([string]$Source, [string]$DestFileName)
    if ([string]::IsNullOrWhiteSpace($Source)) { return $null }

    $destPath = Join-Path $BrandingWorkDir $DestFileName

    if ($Source -match '^https?://') {
        try {
            Write-Output "Downloading: $Source"
            Invoke-WebRequest -Uri $Source -OutFile $destPath -UseBasicParsing
            return $destPath
        } catch {
            Write-Output "FAILED to download $Source : $_"
            return $null
        }
    } else {
        if (Test-Path $Source) {
            Copy-Item -Path $Source -Destination $destPath -Force
            return $destPath
        } else {
            Write-Output "Local path not found: $Source"
            return $null
        }
    }
}

# -------------------------------------------------------------------------
# Helper: convert/resize any image to an exact target size + format using
# .NET's System.Drawing (available on any live Windows install, no extra
# tools needed). Crops to fill (center-crop), rather than stretching.
# -------------------------------------------------------------------------
Add-Type -AssemblyName System.Drawing

function Convert-ImageToSpec {
    param(
        [string]$InputPath,
        [string]$OutputPath,
        [int]$TargetWidth,
        [int]$TargetHeight,
        [System.Drawing.Imaging.ImageFormat]$Format
    )
    if (-not (Test-Path $InputPath)) { return $false }

    try {
        $srcImage = [System.Drawing.Image]::FromFile($InputPath)

        $srcRatio = $srcImage.Width / $srcImage.Height
        $targetRatio = $TargetWidth / $TargetHeight

        if ($srcRatio -gt $targetRatio) {
            $cropHeight = $srcImage.Height
            $cropWidth = [int]($srcImage.Height * $targetRatio)
        } else {
            $cropWidth = $srcImage.Width
            $cropHeight = [int]($srcImage.Width / $targetRatio)
        }
        $cropX = [int](($srcImage.Width - $cropWidth) / 2)
        $cropY = [int](($srcImage.Height - $cropHeight) / 2)

        $bitmap = New-Object System.Drawing.Bitmap $TargetWidth, $TargetHeight
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.DrawImage(
            $srcImage,
            (New-Object System.Drawing.Rectangle 0, 0, $TargetWidth, $TargetHeight),
            (New-Object System.Drawing.Rectangle $cropX, $cropY, $cropWidth, $cropHeight),
            [System.Drawing.GraphicsUnit]::Pixel
        )

        $bitmap.Save($OutputPath, $Format)

        $graphics.Dispose()
        $bitmap.Dispose()
        $srcImage.Dispose()
        return $true
    } catch {
        Write-Output "FAILED converting $InputPath : $_"
        return $false
    }
}

function Set-Reg {
    param([string]$Path, [string]$Name, [string]$Type, [string]$Value)
    try {
        & reg add $Path /v $Name /t $Type /d $Value /f | Out-Null
        Write-Output "Set: $Path\$Name = $Value"
    } catch {
        Write-Output "Failed to set $Path\$Name : $_"
    }
}

function Remove-RegKey {
    param([string]$Path)
    try {
        & reg delete $Path /f | Out-Null
        Write-Output "Removed key: $Path"
    } catch {
        Write-Output "Failed to remove $Path : $_"
    }
}

Write-Output "=== tiny11-style LIVE debloat starting ==="
Write-Output "Target: currently running online OS (not an offline WIM)"
Write-Output ""

# -------------------------------------------------------------------------
# 1. Remove provisioned Appx packages (same prefix list as tiny11maker.ps1)
#    Online equivalent: /Online instead of /Image:<mount path>
# -------------------------------------------------------------------------
Write-Output ">>> Removing provisioned Appx packages..."

$packagePrefixes = @(
    'AppUp.IntelManagementandSecurityStatus',
    'Clipchamp.Clipchamp',
    'DolbyLaboratories.DolbyAccess',
    'DolbyLaboratories.DolbyDigitalPlusDecoderOEM',
    'Microsoft.BingNews',
    'Microsoft.BingSearch',
    'Microsoft.BingWeather',
    'Microsoft.Copilot',
    'Microsoft.Windows.CrossDevice',
    'Microsoft.GamingApp',
    'Microsoft.GetHelp',
    'Microsoft.Getstarted',
    'Microsoft.Microsoft3DViewer',
    'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.MicrosoftStickyNotes',
    'Microsoft.MixedReality.Portal',
    'Microsoft.MSPaint',
    'Microsoft.Office.OneNote',
    'Microsoft.OfficePushNotificationUtility',
    'Microsoft.OutlookForWindows',
    'Microsoft.Paint',
    'Microsoft.People',
    'Microsoft.PowerAutomateDesktop',
    'Microsoft.SkypeApp',
    'Microsoft.StartExperiencesApp',
    'Microsoft.Todos',
    'Microsoft.Wallet',
    'Microsoft.Windows.DevHome',
    'Microsoft.Windows.Copilot',
    'Microsoft.Windows.Teams',
    'Microsoft.WindowsAlarms',
    'Microsoft.WindowsCamera',
    'microsoft.windowscommunicationsapps',
    'Microsoft.WindowsFeedbackHub',
    'Microsoft.WindowsMaps',
    'Microsoft.WindowsSoundRecorder',
    'Microsoft.WindowsTerminal',
    'Microsoft.Xbox.TCUI',
    'Microsoft.XboxApp',
    'Microsoft.XboxGameOverlay',
    'Microsoft.XboxGamingOverlay',
    'Microsoft.XboxIdentityProvider',
    'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.YourPhone',
    'Microsoft.ZuneMusic',
    'Microsoft.ZuneVideo',
    'MicrosoftCorporationII.MicrosoftFamily',
    'MicrosoftCorporationII.QuickAssist',
    'MSTeams',
    'MicrosoftTeams',
    'Microsoft.549981C3F5F10'
)

# Get-AppxProvisionedPackage is the online (live-system) equivalent of
# dism /image:<mount> /Get-ProvisionedAppxPackages
$packages = Get-AppxProvisionedPackage -Online | Select-Object -ExpandProperty PackageName

$packagesToRemove = $packages | Where-Object {
    $pkg = $_
    $packagePrefixes | Where-Object { $pkg -like "*$_*" }
}

foreach ($package in $packagesToRemove) {
    Write-Output "Removing provisioned package: $package"
    Remove-AppxProvisionedPackage -Online -PackageName $package -ErrorAction SilentlyContinue | Out-Null
}

# Also remove for the CURRENT user profile (tiny11 only strips provisioning,
# since it's working offline pre-first-login; live system also needs this
# so the throwaway account's Start Menu doesn't show them before you delete it)
Write-Output ">>> Removing installed Appx packages for current user..."
$installedPackages = Get-AppxPackage | Select-Object -ExpandProperty Name
$installedToRemove = $installedPackages | Where-Object {
    $pkg = $_
    $packagePrefixes | Where-Object { $pkg -like "*$_*" }
}
foreach ($package in $installedToRemove) {
    Write-Output "Removing installed package: $package"
    Get-AppxPackage -Name $package | Remove-AppxPackage -ErrorAction SilentlyContinue
}

Write-Output ""

# -------------------------------------------------------------------------
# 2. Remove Edge (live system paths - service must be stopped first)
# -------------------------------------------------------------------------
Write-Output ">>> Removing Edge..."

# Kill Edge/EdgeUpdate processes so files aren't locked
Get-Process msedge, MicrosoftEdgeUpdate -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# Stop the Edge update service (edgeupdate) if running
Stop-Service edgeupdate -Force -ErrorAction SilentlyContinue
Stop-Service edgeupdatem -Force -ErrorAction SilentlyContinue

$edgePaths = @(
    "$env:ProgramFiles(x86)\Microsoft\Edge",
    "$env:ProgramFiles(x86)\Microsoft\EdgeUpdate",
    "$env:ProgramFiles(x86)\Microsoft\EdgeCore",
    "$env:SystemRoot\System32\Microsoft-Edge-Webview"
)

foreach ($path in $edgePaths) {
    if (Test-Path $path) {
        & takeown /F $path /R /D Y | Out-Null
        & icacls $path /grant "*S-1-5-32-544:(OI)(CI)F" /T /C | Out-Null
        Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
        Write-Output "Removed: $path"
    } else {
        Write-Output "Not found (already absent): $path"
    }
}

Write-Output ""

# -------------------------------------------------------------------------
# 3. Remove OneDrive (live system - must uninstall running instance first)
# -------------------------------------------------------------------------
Write-Output ">>> Removing OneDrive..."

# Uninstall the running OneDrive instance properly first (live-system step
# tiny11 doesn't need since it works on an offline pre-first-run image)
Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$oneDriveSetup = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
if (-not (Test-Path $oneDriveSetup)) { $oneDriveSetup = "$env:SystemRoot\System32\OneDriveSetup.exe" }
if (Test-Path $oneDriveSetup) {
    Start-Process $oneDriveSetup -ArgumentList "/uninstall" -Wait -ErrorAction SilentlyContinue
}

$oneDriveExe = "$env:SystemRoot\System32\OneDriveSetup.exe"
if (Test-Path $oneDriveExe) {
    & takeown /F $oneDriveExe | Out-Null
    & icacls $oneDriveExe /grant "*S-1-5-32-544:(F)" | Out-Null
    Remove-Item -Path $oneDriveExe -Force -ErrorAction SilentlyContinue
    Write-Output "Removed: $oneDriveExe"
}

Write-Output ""

# -------------------------------------------------------------------------
# 4. Registry tweaks - LIVE equivalents.
#    tiny11 loads offline hives as zCOMPONENTS/zDEFAULT/zNTUSER/zSOFTWARE/zSYSTEM.
#    On a live system these map directly to:
#       zDEFAULT/zNTUSER -> HKCU (current interactive user's hive is already loaded)
#       zSOFTWARE         -> HKLM\SOFTWARE
#       zSYSTEM           -> HKLM\SYSTEM
#    NOTE: skipping the CPU/RAM/TPM/SecureBoot bypass keys here - you already
#    installed successfully, so LabConfig/MoSetup bypasses are not relevant
#    to a live already-running system the way they are to an offline setup image.
# -------------------------------------------------------------------------
Write-Output ">>> Disabling Sponsored Apps / suggestions..."
Set-Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 'REG_DWORD' '0'
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed' 'REG_DWORD' '0'
Set-Reg 'HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start' 'ConfigureStartPins' 'REG_SZ' '{"pinnedList": [{}]}'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'FeatureManagementEnabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEverEnabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContentEnabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 'REG_DWORD' '0'
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\PushToInstall' 'DisablePushToInstall' 'REG_DWORD' '1'
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\MRT' 'DontOfferThroughWUAU' 'REG_DWORD' '1'
Remove-RegKey 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions'
Remove-RegKey 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps'
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'REG_DWORD' '1'
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 'REG_DWORD' '1'

Write-Output ">>> Enabling local accounts on OOBE (BypassNRO)..."
Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'BypassNRO' 'REG_DWORD' '1'

Write-Output ">>> Disabling Reserved Storage..."
Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 'REG_DWORD' '0'

Write-Output ">>> Disabling BitLocker Device Encryption..."
Set-Reg 'HKLM\SYSTEM\ControlSet001\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'

Write-Output ">>> Disabling Chat icon..."
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 'REG_DWORD' '3'
Set-Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'

Write-Output ">>> Removing Edge-related uninstall registry entries..."
Remove-RegKey "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge"
Remove-RegKey "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update"

Write-Output ">>> Disabling OneDrive folder backup..."
Set-Reg "HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" "REG_DWORD" "1"

Write-Output ">>> Disabling Telemetry..."
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Input\TIPC' 'Enabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 'REG_DWORD' '1'
Set-Reg 'HKCU\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 'REG_DWORD' '1'
Set-Reg 'HKCU\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 'REG_DWORD' '0'
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 'REG_DWORD' '0'
Set-Reg 'HKLM\SYSTEM\ControlSet001\Services\dmwappushservice' 'Start' 'REG_DWORD' '4'

Write-Output ">>> Preventing installation of DevHome and Outlook..."
Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' 'workCompleted' 'REG_DWORD' '1'
Remove-RegKey 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate'
Remove-RegKey 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate'

Write-Output ">>> Disabling Copilot..."
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 'REG_DWORD' '1'
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 'REG_DWORD' '0'
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'REG_DWORD' '1'

Write-Output ">>> Preventing installation of Teams..."
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Teams' 'DisableInstallation' 'REG_DWORD' '1'

Write-Output ">>> Preventing installation of New Outlook..."
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Mail' 'PreventRun' 'REG_DWORD' '1'

Write-Output ""

# -------------------------------------------------------------------------
# 5. Scheduled tasks - identical to tiny11 (same task paths exist live)
# -------------------------------------------------------------------------
Write-Output ">>> Disabling/removing scheduled tasks..."

$tasksToRemove = @(
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
    '\Microsoft\Windows\Chkdsk\Proxy',
    '\Microsoft\Windows\Windows Error Reporting\QueueReporting'
)
foreach ($task in $tasksToRemove) {
    schtasks /Delete /TN $task /F 2>$null | Out-Null
    Write-Output "Removed task (if present): $task"
}
# CEIP is a whole folder of tasks in tiny11 (Remove-Item -Recurse on the folder)
schtasks /Delete /TN "\Microsoft\Windows\Customer Experience Improvement Program" /F 2>$null | Out-Null
Get-ScheduledTask -TaskPath "\Microsoft\Windows\Customer Experience Improvement Program\" -ErrorAction SilentlyContinue |
    ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction SilentlyContinue }

Write-Output ""

# -------------------------------------------------------------------------
# 6. Branding / theming - all driven by the config block at the top of
#    this file. Every step below is skipped automatically if you left the
#    corresponding variable blank.
# -------------------------------------------------------------------------
Write-Output ">>> Applying branding/theming..."

# --- Build name ---
if (-not [string]::IsNullOrWhiteSpace($BuildName)) {
    Write-Output "Setting build name: $BuildName"
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'RegisteredOrganization' 'REG_SZ' $BuildName
    $oemKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation"
    New-Item -Path $oemKey -Force | Out-Null
    Set-ItemProperty -Path $oemKey -Name "Model" -Value $BuildName
    Set-ItemProperty -Path $oemKey -Name "Manufacturer" -Value $BuildName
} else {
    Write-Output "Build name: skipped (blank)"
}

# --- OEM logo (System Properties / About page) ---
if (-not [string]::IsNullOrWhiteSpace($LogoSource)) {
    Write-Output "Applying OEM logo..."
    $logoLocal = Resolve-Asset -Source $LogoSource -DestFileName "logo_source"
    if ($logoLocal) {
        $oobeInfoDir = "$env:SystemRoot\System32\oobe\info"
        New-Item -Path $oobeInfoDir -ItemType Directory -Force | Out-Null
        $logoDest = "$oobeInfoDir\OEMLOGO.bmp"

        # Convert to BMP at a sane size regardless of source format (PNG/JPG/etc)
        $converted = Convert-ImageToSpec -InputPath $logoLocal -OutputPath $logoDest -TargetWidth 120 -TargetHeight 120 -Format ([System.Drawing.Imaging.ImageFormat]::Bmp)
        if ($converted) {
            $oemKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation"
            New-Item -Path $oemKey -Force | Out-Null
            Set-ItemProperty -Path $oemKey -Name "Logo" -Value $logoDest
            Write-Output "Logo applied: $logoDest"
        }
    }
} else {
    Write-Output "OEM logo: skipped (blank)"
}

# --- Themepacks (one or more, first one becomes default for new users) ---
if ($ThemepackUrls.Count -gt 0) {
    Write-Output ">>> Installing $($ThemepackUrls.Count) themepack(s)..."
    $themesDir = "$env:SystemRoot\Resources\Themes"
    $installedThemeFiles = @()

    for ($i = 0; $i -lt $ThemepackUrls.Count; $i++) {
        $url = $ThemepackUrls[$i]
        if ([string]::IsNullOrWhiteSpace($url)) { continue }

        $themePackLocal = Resolve-Asset -Source $url -DestFileName "themepack_$i.deskthemepack"
        if (-not $themePackLocal) { continue }

        # .deskthemepack / .themepack files are just renamed CAB/ZIP archives
        # containing a .theme file plus assets. Extract into Themes folder.
        $extractDir = "$BrandingWorkDir\theme_$i"
        New-Item -Path $extractDir -ItemType Directory -Force | Out-Null

        try {
            # Try as a zip/cab first
            Expand-Archive -Path $themePackLocal -DestinationPath $extractDir -Force -ErrorAction Stop
        } catch {
            # Some .themepack files are actually raw CAB - fall back to expand.exe
            & expand.exe $themePackLocal -F:* $extractDir | Out-Null
        }

        $themeFile = Get-ChildItem -Path $extractDir -Filter "*.theme" -Recurse | Select-Object -First 1
        if ($themeFile) {
            # Copy the whole extracted folder's assets alongside the theme file
            $destThemeDir = "$themesDir\CustomTheme_$i"
            New-Item -Path $destThemeDir -ItemType Directory -Force | Out-Null
            Copy-Item -Path "$extractDir\*" -Destination $destThemeDir -Recurse -Force

            $destThemeFile = "$destThemeDir\$($themeFile.Name)"
            $installedThemeFiles += $destThemeFile
            Write-Output "Installed theme: $destThemeFile"
        } else {
            Write-Output "No .theme file found inside package $i - skipped"
        }
    }

    # Set the first successfully installed theme as default for new users
    if ($installedThemeFiles.Count -gt 0) {
        $defaultTheme = $installedThemeFiles[0]
        Write-Output "Setting default theme for new users: $defaultTheme"
        try {
            reg load HKU\DefaultUser "C:\Users\Default\NTUSER.DAT" 2>$null
            & reg add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Themes" /v "CurrentTheme" /t REG_SZ /d $defaultTheme /f | Out-Null
            reg unload HKU\DefaultUser 2>$null
        } catch {
            Write-Output "Could not set default theme for new users: $_"
        }
    }
} else {
    Write-Output "Themepacks: skipped (none provided)"
}

# --- OOBE wallpaper (shown during first-boot setup, pre-login) ---
if (-not [string]::IsNullOrWhiteSpace($OobeWallpaperSource)) {
    Write-Output "Applying OOBE wallpaper..."
    $oobeLocal = Resolve-Asset -Source $OobeWallpaperSource -DestFileName "oobe_source"
    if ($oobeLocal) {
        $oobeBgDir = "$env:SystemRoot\System32\oobe\info\backgrounds"
        New-Item -Path $oobeBgDir -ItemType Directory -Force | Out-Null
        $oobeDest = "$oobeBgDir\background.jpg"
        Convert-ImageToSpec -InputPath $oobeLocal -OutputPath $oobeDest -TargetWidth 1920 -TargetHeight 1080 -Format ([System.Drawing.Imaging.ImageFormat]::Jpeg) | Out-Null
        Write-Output "OOBE wallpaper applied: $oobeDest"
    }
} else {
    Write-Output "OOBE wallpaper: skipped (blank)"
}

# --- Lock screen wallpaper ---
if (-not [string]::IsNullOrWhiteSpace($LockscreenWallpaperSource)) {
    Write-Output "Applying lock screen wallpaper..."
    $lockLocal = Resolve-Asset -Source $LockscreenWallpaperSource -DestFileName "lock_source"
    if ($lockLocal) {
        $lockDestDir = "$env:SystemRoot\Web\Screen"
        New-Item -Path $lockDestDir -ItemType Directory -Force | Out-Null
        $lockDest = "$lockDestDir\CustomLockScreen.jpg"
        $converted = Convert-ImageToSpec -InputPath $lockLocal -OutputPath $lockDest -TargetWidth 1920 -TargetHeight 1080 -Format ([System.Drawing.Imaging.ImageFormat]::Jpeg)
        if ($converted) {
            $lockKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
            New-Item -Path $lockKey -Force | Out-Null
            Set-ItemProperty -Path $lockKey -Name "LockScreenImage" -Value $lockDest
            Write-Output "Lock screen applied: $lockDest"
        }
    }
} else {
    Write-Output "Lock screen wallpaper: skipped (blank)"
}

# --- Setup wallpaper (blue install-screen background - strict format) ---
if (-not [string]::IsNullOrWhiteSpace($SetupWallpaperSource)) {
    Write-Output "Applying Setup wallpaper..."
    $setupLocal = Resolve-Asset -Source $SetupWallpaperSource -DestFileName "setup_source"
    if ($setupLocal) {
        # Windows Setup background lives in boot.wim, not the running OS - this
        # applies it to the ONLINE install's equivalent branding asset used by
        # PE-based UI (best-effort on a live system; for full Setup-screen
        # branding you'd also need to inject this into boot.wim offline).
        $setupDestDir = "$env:SystemRoot\System32\oobe\info\backgrounds"
        New-Item -Path $setupDestDir -ItemType Directory -Force | Out-Null
        $setupDest = "$setupDestDir\setup_background.bmp"
        # Setup screens historically expect BMP, exact 1920x1200 (or 1366x768 for lower-res)
        Convert-ImageToSpec -InputPath $setupLocal -OutputPath $setupDest -TargetWidth 1920 -TargetHeight 1200 -Format ([System.Drawing.Imaging.ImageFormat]::Bmp) | Out-Null
        Write-Output "Setup wallpaper applied (online-asset best-effort): $setupDest"
        Write-Output "NOTE: for the actual blue Setup screens seen booting from your final ISO,"
        Write-Output "      this asset also needs injecting into boot.wim offline - see note below."
    }
} else {
    Write-Output "Setup wallpaper: skipped (blank)"
}

Write-Output ""

# -------------------------------------------------------------------------
# 7. Component store cleanup - THIS is the key one for a live post-update
#    system, since you just installed a bunch of cumulative updates.
#    Online equivalent of: dism /Image:<mount> /Cleanup-Image /StartComponentCleanup /ResetBase
# -------------------------------------------------------------------------
Write-Output ">>> Cleaning up WinSxS component store (this can take a while)..."
dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase

Write-Output ""
Write-Output "=== Live debloat + branding complete ==="
Write-Output "Downloaded/converted branding assets are cached in: $BrandingWorkDir"
Write-Output "(safe to delete after you confirm everything looks right)"
Write-Output ""
Write-Output "NOTE on Setup wallpaper: the blue Windows Setup screens (before OOBE, while"
Write-Output "the installer itself is running) are drawn from boot.wim, which this live"
Write-Output "script cannot touch since it's not part of the running OS. If you want that"
Write-Output "screen branded too, mount boot.wim offline back on Linux/Windows and replace"
Write-Output "its background asset there - ask if you want a follow-up script for that step."
Write-Output ""
Write-Output "Next steps in your workflow:"
Write-Output "  1. Reboot once to let everything settle, confirm Windows Update still shows clean"
Write-Output "  2. Confirm branding looks right: sysdm.cpl for OEM info, Settings > Personalization"
Write-Output "     for themes, and Settings > Personalization > Lock screen for the lock image"
Write-Output "  3. Delete the throwaway account (from a different admin session, e.g. built-in Administrator)"
Write-Output "  4. cd C:\Windows\System32\Sysprep"
Write-Output "     sysprep /generalize /oobe /shutdown"
Write-Output "  5. Boot WinPE (from your install media) and capture:"
Write-Output "     dism /Capture-Image /ImageFile:D:\install.wim /CaptureDir:C:\ /Name:""Windows 11 Custom"""
Write-Output "  6. Bring that install.wim back to your Linux box and rebuild the ISO"

Stop-Transcript
