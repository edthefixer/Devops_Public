#Requires -RunAsAdministrator
<#
.SYNOPSIS
  STEP 2 OF 2 — FSLogix registry baseline for AVD session hosts.
  Run this script on EVERY session host AFTER 80_AVD_Configure_AzureFiles_FSLogix_ADDS.ps1 has completed.

.DESCRIPTION
  *** EXECUTION ORDER ***
  Step 1: 80_AVD_Configure_AzureFiles_FSLogix_ADDS.ps1
            Run ONCE from a domain-joined admin workstation, management VM, or session host.
            Sets up Azure Files share, AD DS storage identity, RBAC, and NTFS ACLs.
            Must complete successfully before this script is deployed to session hosts.

  Step 2: 81_AVD_Configure_AzureFiles_FSLogix_ADDS_Registry.ps1  (this script)
            Run on EVERY AVD session host after Step 1 is complete.
            No Azure connectivity required — local registry configuration only.
            Safe to push via Intune, GPO, or bake into a custom golden image.

  *** WHAT THIS SCRIPT DOES (Step 2) ***
  Applies the complete FSLogix registry baseline to the local session host.
  Makes no changes in Azure. All it does is write to HKLM:\SOFTWARE\FSLogix\Profiles.

  Supports two modes:
   - Standard (default): sets VHDLocations to a single Azure Files UNC path.
   - Cloud Cache (-UseCloudCache): sets CCDLocations to one or more UNC providers
     for multi-region redundancy. Cleans the conflicting key in both modes.

  Registry keys written:
   - Enabled                            = 1
   - DeleteLocalProfileWhenVHDShouldApply = 1  (removes local profile if container applies)
   - FlipFlopProfileDirectoryName       = 1  (username-first folder naming)
   - LockedRetryCount                   = 3  (retries if VHD is locked)
   - LockedRetryInterval                = 15 (seconds between retries)
   - ProfileType                        = 0  (standard read-write container)
   - ReAttachIntervalSeconds            = 15 (reconnect interval if attach drops)
  - ReAttachRetryCount                 = 3  (retries if container attach fails)
  - SizeInMBs                          = 25000 (profile container size in MB)
   - VolumeType                         = vhdx (VHDX format for profile container)
   - VHDLocations or CCDLocations           (UNC path to the Azure Files share)
   - CloudKerberosTicketRetrievalEnabled = 1  (Entra ID Kerberos auth; set under HKLM:\SYSTEM\...\Kerberos\Parameters)

.PARAMETER AzureFilesUNC
  Azure Files UNC path for standard profile container mode.
  Also accepts an Azure Files HTTPS URL and converts it to UNC.
  Example: \\stfslogix01.file.core.windows.net\profiles
  Example: https://stfslogix01.file.core.windows.net/profiles

.PARAMETER DiscoverAzureFilesShare
  Discovers accessible Azure Files shares from the current Az context,
  shows them as a numbered list, and prompts for selection.
  Use this when the share path is unknown.

.PARAMETER StorageAccountName
  Azure Storage account name. Used with FileShareName to build AzureFilesUNC.

.PARAMETER FileShareName
  Azure Files share name. Used with StorageAccountName to build AzureFilesUNC.

.PARAMETER UseCloudCache
  Switches configuration to Cloud Cache mode (CCDLocations).

.PARAMETER CCDLocations
  One or more provider paths separated by semicolons.
  Each entry can be a UNC path or Azure Files HTTPS URL.
  Example: \\sa1.file.core.windows.net\profiles;\\sa2.file.core.windows.net\profiles

.PARAMETER RestartHost
  If set, restarts the host after applying configuration.

.EXAMPLE
  # Step 2 — Standard Azure Files mode using storage account name and share name
  .\81_AVD_Configure_AzureFiles_FSLogix_ADDS_Registry.ps1 -StorageAccountName stfslogix01 -FileShareName profiles -Verbose

.EXAMPLE
  # Step 2 — Standard Azure Files mode using the full UNC path directly
  .\81_AVD_Configure_AzureFiles_FSLogix_ADDS_Registry.ps1 -AzureFilesUNC '\\stfslogix01.file.core.windows.net\profiles' -Verbose

.EXAMPLE
  # Step 2 — Cloud Cache mode with two redundant providers
  .\81_AVD_Configure_AzureFiles_FSLogix_ADDS_Registry.ps1 -UseCloudCache -CCDLocations '\\sa1.file.core.windows.net\profiles;\\sa2.file.core.windows.net\profiles' -Verbose

.EXAMPLE
  # Step 2 — Dry run to preview registry changes without applying them
  .\81_AVD_Configure_AzureFiles_FSLogix_ADDS_Registry.ps1 -StorageAccountName stfslogix01 -FileShareName profiles -WhatIf -Verbose

.EXAMPLE
  # Step 2 — Discover Azure Files share and select interactively
  .\81_AVD_Configure_AzureFiles_FSLogix_ADDS_Registry.ps1 -DiscoverAzureFilesShare -Verbose
#>

[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'StandardByUNC')]
param(
  [Parameter(ParameterSetName = 'StandardByUNC')]
  [ValidateScript({
    if ($_ -match '^\\\\[^\\]+\\[^\\].+') { return $true }
    if ($_ -match '^https?://') { return $true }
    throw 'AzureFilesUNC must be a UNC path (\\server\share...) or an Azure Files URL (https://<account>.file.core.windows.net/<share>).'
  })]
  [string]$AzureFilesUNC,

  [Parameter(ParameterSetName = 'StandardByUNC')]
  [switch]$DiscoverAzureFilesShare,

  [Parameter(Mandatory, ParameterSetName = 'StandardByName')]
  [ValidateNotNullOrEmpty()]
  [string]$StorageAccountName,

  [Parameter(Mandatory, ParameterSetName = 'StandardByName')]
  [ValidateNotNullOrEmpty()]
  [string]$FileShareName,

  [Parameter(Mandatory, ParameterSetName = 'CloudCache')]
  [switch]$UseCloudCache,

  [Parameter(Mandatory, ParameterSetName = 'CloudCache')]
  [string]$CCDLocations,

  [switch]$RestartHost
)

$RegPath = 'HKLM:\SOFTWARE\FSLogix\Profiles'

function Get-Value {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Name
  )

  try {
    (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
  }
  catch {
    $null
  }
}

function Set-Dword {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][int]$Value
  )

  New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
}

function Set-MultiString {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string[]]$Values
  )

  New-ItemProperty -Path $Path -Name $Name -PropertyType MultiString -Value $Values -Force | Out-Null
}

function Test-IsValidUNCPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  # Match UNC paths with format: \\server\share or \\\\server\\share
  return $Path -match '^\\{2,4}[^\\]+\\{1,2}[^\\].+'
}

function Convert-ToFslogixUNCPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw 'Provider path cannot be empty.'
  }

  $trimmed = $Path.Trim()

  if ($trimmed -match '^\\\\') {
    return $trimmed
  }

  if ($trimmed -match '^https?://') {
    try {
      $uri = [Uri]$trimmed
    }
    catch {
      throw "Invalid provider URL: $trimmed"
    }

    if ([string]::IsNullOrWhiteSpace($uri.Host)) {
      throw "Provider URL is missing host: $trimmed"
    }

    $shareAndSubPath = $uri.AbsolutePath.Trim('/')
    if ([string]::IsNullOrWhiteSpace($shareAndSubPath)) {
      throw "Provider URL is missing file share name in path: $trimmed"
    }

    $uncSubPath = $shareAndSubPath -replace '/', '\\'
    return "\\\\$($uri.Host)\\$uncSubPath"
  }

  return $trimmed
}

function Resolve-StandardUNC {
  if (-not [string]::IsNullOrWhiteSpace($AzureFilesUNC)) {
    return (Convert-ToFslogixUNCPath -Path $AzureFilesUNC)
  }

  if ($DiscoverAzureFilesShare) {
    return (Select-AzureFilesSharePath)
  }

  # Default behavior: if no standard-mode path inputs are provided, discover and prompt.
  if ([string]::IsNullOrWhiteSpace($StorageAccountName) -and [string]::IsNullOrWhiteSpace($FileShareName)) {
    return (Select-AzureFilesSharePath)
  }

  if ([string]::IsNullOrWhiteSpace($StorageAccountName) -or [string]::IsNullOrWhiteSpace($FileShareName)) {
    throw 'For standard mode, provide either -AzureFilesUNC or both -StorageAccountName and -FileShareName.'
  }

  return "\\$StorageAccountName.file.core.windows.net\$FileShareName"
}

$script:TempModulePath = $null

function Initialize-AzDiscoveryDependencies {
  if (Get-Command -Name Get-AzContext -ErrorAction SilentlyContinue) {
    return
  }

  $moduleRoots = @()

  if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $moduleRoots += (Join-Path $PSScriptRoot '_psmodules')
    $moduleRoots += (Join-Path $PSScriptRoot '..\_psmodules')
    $moduleRoots += (Join-Path $PSScriptRoot '..\..\_psmodules')
  }

  # Workspace-local fallback for this repo layout.
  $moduleRoots += 'C:\Devops\_psmodules'

  foreach ($root in ($moduleRoots | Select-Object -Unique)) {
    if (Test-Path $root) {
      $existingPaths = $env:PSModulePath -split ';'
      if ($existingPaths -notcontains $root) {
        $env:PSModulePath = "$root;$env:PSModulePath"
      }
    }
  }

  $requiredModules = @('Az.Accounts', 'Az.Resources', 'Az.Storage')
  $missingModules = @()

  foreach ($moduleName in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $moduleName -ErrorAction SilentlyContinue)) {
      $missingModules += $moduleName
    }
  }

  if ($missingModules.Count -gt 0) {
    Write-Host "Downloading missing Az modules into temporary location..." -ForegroundColor Cyan
    $script:TempModulePath = Join-Path $env:TEMP "PSModules_$(Get-Date -Format yyyyMMdd_HHmmss)"
    New-Item -ItemType Directory -Path $script:TempModulePath -Force | Out-Null
    $env:PSModulePath = "$script:TempModulePath;$env:PSModulePath"

    foreach ($moduleName in $missingModules) {
      try {
        Write-Host "  Downloading ${moduleName}..." -ForegroundColor Gray
        Save-Module -Name $moduleName -Path $script:TempModulePath -Force -ErrorAction Stop | Out-Null
        Write-Host "  Downloaded ${moduleName}" -ForegroundColor Green
      }
      catch {
        Write-Host "  Failed to download ${moduleName}: $($_.Exception.Message)" -ForegroundColor Red
        throw "Cannot download ${moduleName}. Ensure PowerShell has internet access or provide -AzureFilesUNC directly."
      }
    }
  }

  foreach ($moduleName in $requiredModules) {
    try {
      Import-Module -Name $moduleName -ErrorAction Stop | Out-Null
    }
    catch {
      Write-Verbose "Unable to import ${moduleName}: $($_.Exception.Message)"
    }
  }
}

function Cleanup-TempModules {
  if (-not [string]::IsNullOrWhiteSpace($script:TempModulePath) -and (Test-Path $script:TempModulePath)) {
    Write-Host "Cleaning up temporary modules from $script:TempModulePath..." -ForegroundColor Cyan
    try {
      Remove-Item -Path $script:TempModulePath -Recurse -Force -ErrorAction SilentlyContinue
      Write-Host "Cleanup complete." -ForegroundColor Green
    }
    catch {
      Write-Host "Warning: Could not clean temporary modules. Manual cleanup may be needed." -ForegroundColor Yellow
    }
  }
}

function Select-AzureFilesSharePath {
  Initialize-AzDiscoveryDependencies

  if (-not (Get-Command -Name Get-AzContext -ErrorAction SilentlyContinue)) {
    throw 'Az PowerShell modules are not available. Ensure Az.Accounts/Az.Resources/Az.Storage are in PSModulePath (for example C:\Devops\_psmodules) or provide -AzureFilesUNC directly.'
  }

  $ctx = Get-AzContext
  if (-not $ctx) {
    if ([Console]::IsInputRedirected) {
      throw 'No active Az context found in non-interactive session. Run Connect-AzAccount first or provide -AzureFilesUNC directly.'
    }

    Write-Host 'No active Az context found. Starting interactive sign-in...' -ForegroundColor Yellow
    Connect-AzAccount -ErrorAction Stop | Out-Null
    $ctx = Get-AzContext
    if (-not $ctx) {
      throw 'Az sign-in did not produce an active context. Provide -AzureFilesUNC directly.'
    }
  }

  if ([Console]::IsInputRedirected) {
    throw 'Discovery selection requires interactive input. Provide -AzureFilesUNC for non-interactive runs.'
  }

  Write-Host 'Discovering accessible Azure Files shares from current Az context...' -ForegroundColor Cyan

  $candidates = @()
  $storageAccounts = Get-AzStorageAccount -ErrorAction Stop

  foreach ($sa in $storageAccounts) {
    try {
      $saContext = New-AzStorageContext -StorageAccountName $sa.StorageAccountName -UseConnectedAccount -ErrorAction Stop
      $shares = Get-AzStorageShare -Context $saContext -ErrorAction Stop

      foreach ($share in $shares) {
        $unc = "\\$($sa.StorageAccountName).file.core.windows.net\$($share.Name)"
        $url = "https://$($sa.StorageAccountName).file.core.windows.net/$($share.Name)"
        $candidates += [PSCustomObject]@{
          StorageAccount = $sa.StorageAccountName
          Share          = $share.Name
          Location       = $sa.Location
          UNC            = $unc
          URL            = $url
        }
      }
    }
    catch {
      Write-Verbose "Skipping storage account '$($sa.StorageAccountName)': $($_.Exception.Message)"
    }
  }

  if ($candidates.Count -lt 1) {
    throw 'No accessible Azure Files shares were discovered from the current Az context.'
  }

  $index = 1
  $menu = $candidates | ForEach-Object {
    [PSCustomObject]@{
      Index          = $index
      StorageAccount = $_.StorageAccount
      Share          = $_.Share
      Location       = $_.Location
      UNC            = $_.UNC
    }
    $index++
  }

  Write-Host 'Select the Azure Files share for FSLogix VHDLocations:' -ForegroundColor Yellow
  $menu | Format-Table -AutoSize | Out-Host

  while ($true) {
    $choice = Read-Host "Enter selection number (1-$($menu.Count))"
    if ($choice -match '^\d+$') {
      $selectedIndex = [int]$choice
      if ($selectedIndex -ge 1 -and $selectedIndex -le $menu.Count) {
        $selected = $menu | Where-Object { $_.Index -eq $selectedIndex } | Select-Object -First 1
        Write-Host "Selected: $($selected.UNC)" -ForegroundColor Green
        return $selected.UNC
      }
    }

    Write-Host 'Invalid selection. Try again.' -ForegroundColor Red
  }
}

if (-not (Test-Path $RegPath)) {
  New-Item -Path $RegPath -Force | Out-Null
}

Write-Host 'Current FSLogix settings:' -ForegroundColor Cyan
Write-Host ("  Enabled      : {0}" -f (Get-Value -Path $RegPath -Name 'Enabled'))
Write-Host ("  VHDLocations : {0}" -f ((Get-Value -Path $RegPath -Name 'VHDLocations') -join '; '))
Write-Host ("  CCDLocations : {0}" -f ((Get-Value -Path $RegPath -Name 'CCDLocations') -join '; '))
Write-Host ''

# Validate inputs before ShouldProcess so -WhatIf still surfaces invalid parameters.
$providers = $null
$targetUNC = $null
if ($UseCloudCache) {
  $providers = $CCDLocations.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  if ($providers.Count -lt 1) {
    throw 'CCDLocations must contain at least one UNC path.'
  }

  $providers = $providers | ForEach-Object { Convert-ToFslogixUNCPath -Path $_ }

  $invalidProviders = $providers | Where-Object { -not (Test-IsValidUNCPath -Path $_) }
  if ($invalidProviders.Count -gt 0) {
    throw "Invalid UNC path(s) in CCDLocations: $($invalidProviders -join ', ')"
  }
}
else {
  $targetUNC = Resolve-StandardUNC
  if (-not (Test-IsValidUNCPath -Path $targetUNC)) {
    throw "AzureFiles UNC is invalid: $targetUNC"
  }
}

if ($PSCmdlet.ShouldProcess($RegPath, 'Apply full FSLogix profile baseline')) {
  Set-Dword -Path $RegPath -Name 'Enabled' -Value 1
  Set-Dword -Path $RegPath -Name 'DeleteLocalProfileWhenVHDShouldApply' -Value 1
  Set-Dword -Path $RegPath -Name 'FlipFlopProfileDirectoryName' -Value 1
  Set-Dword -Path $RegPath -Name 'LockedRetryCount' -Value 3
  Set-Dword -Path $RegPath -Name 'LockedRetryInterval' -Value 15
  Set-Dword -Path $RegPath -Name 'ProfileType' -Value 0
  Set-Dword -Path $RegPath -Name 'ReAttachIntervalSeconds' -Value 15
  Set-Dword -Path $RegPath -Name 'ReAttachRetryCount' -Value 3
  Set-Dword -Path $RegPath -Name 'SizeInMBs' -Value 25000
  Set-MultiString -Path $RegPath -Name 'VolumeType' -Values @('vhdx')

  # Configure Cloud Kerberos Ticket Retrieval for Entra ID Kerberos auth
  $KerberosPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters'
  if (-not (Test-Path $KerberosPath)) {
    New-Item -Path $KerberosPath -Force | Out-Null
  }
  Set-Dword -Path $KerberosPath -Name 'CloudKerberosTicketRetrievalEnabled' -Value 1

  if ($UseCloudCache) {
    if (Get-Value -Path $RegPath -Name 'VHDLocations') {
      Remove-ItemProperty -Path $RegPath -Name 'VHDLocations' -ErrorAction SilentlyContinue
    }

    Set-MultiString -Path $RegPath -Name 'CCDLocations' -Values $providers
    Write-Host 'Configured Cloud Cache providers:' -ForegroundColor Green
    $providers | ForEach-Object { Write-Host "  - $_" }
  }
  else {
    if (Get-Value -Path $RegPath -Name 'CCDLocations') {
      Remove-ItemProperty -Path $RegPath -Name 'CCDLocations' -ErrorAction SilentlyContinue
    }

    Set-MultiString -Path $RegPath -Name 'VHDLocations' -Values @($targetUNC)
    Write-Host 'Set VHDLocations to Azure Files UNC:' -ForegroundColor Green
    Write-Host "  $targetUNC"
  }
}

Write-Host ''
Write-Host 'Updated FSLogix settings:' -ForegroundColor Cyan
Write-Host ("  Enabled      : {0}" -f (Get-Value -Path $RegPath -Name 'Enabled'))
Write-Host ("  VHDLocations : {0}" -f ((Get-Value -Path $RegPath -Name 'VHDLocations') -join '; '))
Write-Host ("  CCDLocations : {0}" -f ((Get-Value -Path $RegPath -Name 'CCDLocations') -join '; '))

if ($RestartHost) {
  if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Restart host')) {
    Restart-Computer -Force
  }
}

Write-Host ''
Write-Host 'Done. Recommend testing with a pilot user and validating profile attach in FSLogix logs.' -ForegroundColor Yellow

# Cleanup temporary modules before script exits.
Cleanup-TempModules
