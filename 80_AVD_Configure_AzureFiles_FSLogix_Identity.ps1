<#
.SYNOPSIS
  STEP 1 OF 2 — Azure infrastructure setup for FSLogix profile containers (AD DS scenario).
  Run this script ONCE from any domain-joined machine before running 81_AVD_Configure_AzureFiles_FSLogix_ADDS_Registry.ps1 on session hosts.

.DESCRIPTION
  *** EXECUTION ORDER ***
  Step 1: 80_AVD_Configure_AzureFiles_FSLogix_ADDS.ps1  (this script)
            Run ONCE from a domain-joined admin workstation, management VM, or session host.
            Requires elevation and Azure permissions.
            Performs all Azure-side and AD DS-side infrastructure work.

  Step 2: 81_AVD_Configure_AzureFiles_FSLogix_ADDS_Registry.ps1
            Run on EVERY AVD session host after Step 1 is complete.
            No Azure connectivity required — local registry configuration only.
            Safe to push via Intune, GPO, or custom image.

  *** WHAT THIS SCRIPT DOES (Step 1) ***
  This script sets up the Azure and AD DS infrastructure required for FSLogix profile containers:
   - Creates the Azure Files share if it does not already exist.
   - Joins the storage account identity to AD DS as a computer account using AzFilesHybrid.
   - Assigns share-level RBAC role 'Storage File Data SMB Share Contributor' to the Entra group.
   - Applies NTFS ACLs on the file share (Modify for users, Creator Owner for isolation).
   - Writes a minimal FSLogix registry baseline (Enabled + VHDLocations) on the local machine.
   - Optionally runs Debug-AzStorageAccountAuth to validate the AD DS authentication chain.

  AD DS is the identity and authentication source. Azure Files is the actual storage location
  for FSLogix profile containers (.vhdx files). The two are separate concerns.

  This script is intended to be run on a domain-joined Windows host in an elevated PowerShell session.

.PARAMETER SubscriptionId
  Azure subscription ID containing the storage account.

.PARAMETER ResourceGroupName
  Resource group containing the storage account.

.PARAMETER StorageAccountName
  Storage account name.

.PARAMETER FileShareName
  Azure Files share name.

.PARAMETER AdGroupSam
  AD DS group in DOMAIN\GroupName format used for NTFS ACLs.

.PARAMETER EntraGroupObjectId
  Object ID (GUID) of the synced group in Microsoft Entra ID used for share-level RBAC.

.PARAMETER DriveLetter
  Drive letter to temporarily map the file share (default: Y).

.PARAMETER AzFilesHybridPath
  Optional folder path containing AzFilesHybrid.psd1 (for example after downloading/extracting AzFilesHybrid).

.PARAMETER ModulePath
  Optional local module root path to load Az modules and AzFilesHybrid without using OneDrive-backed profile paths.

.PARAMETER OrganizationalUnitDistinguishedName
  Optional OU DN to place the storage account computer identity.

.PARAMETER RunDebugAuth
  If set, runs Debug-AzStorageAccountAuth after configuration.

.PARAMETER RestartHost
  If set, restarts the host after FSLogix registry configuration.

.PARAMETER Interactive
  If set (or if required parameters are omitted), enables guided discovery mode.
  The script scans tenant/subscription resources and prompts you to choose available options.

.PARAMETER TargetIdentityMode
  Target Azure Files directory service mode for the selected storage account.
  Valid values: KeepCurrent, AD, AADDS, AADKERB, None.
  In interactive mode, you can choose this after selecting the storage account.

.PARAMETER UseDeviceAuthentication
  If set, uses device code authentication with Connect-AzAccount to avoid UI pop-up sign-in hangs.

.PARAMETER AuthMethod
  Authentication method to Azure.
  Valid values: Interactive, DeviceCode, ServicePrincipalSecret, ServicePrincipalCertificate, ManagedIdentity.

.PARAMETER TenantId
  Optional tenant ID used for authentication methods that require or benefit from explicit tenant scoping.

.PARAMETER ServicePrincipalApplicationId
  Optional service principal application (client) ID for service principal authentication methods.

.PARAMETER ServicePrincipalClientSecret
  Optional service principal client secret as SecureString.

.PARAMETER ServicePrincipalCertificateThumbprint
  Optional service principal certificate thumbprint for certificate-based authentication.

.NOTES
  Prerequisites:
   - Elevated PowerShell session.
   - Domain-joined machine with line of sight to AD DS (admin workstation, management VM, or session host).
   - Azure permissions to configure storage account identity and RBAC.
   - Az PowerShell modules and AzFilesHybrid module accessible.

  Input requirements:
   - AdGroupSam must be in DOMAIN\GroupName format.
   - EntraGroupObjectId must reference the synced Entra group for the same AD DS group.

  After this script completes successfully, run 81_AVD_Configure_AzureFiles_FSLogix_ADDS_Registry.ps1
  on each AVD session host to apply the full FSLogix registry baseline.

.EXAMPLE
  # Step 1 — Full explicit run with AD DS validation
  .\80_AVD_Configure_AzureFiles_FSLogix_ADDS.ps1 -SubscriptionId 'xxxx' -ResourceGroupName 'rg1' -StorageAccountName 'stfslogix01' -FileShareName 'profiles' `
    -AdGroupSam 'CONTOSO\\AVDUsers' -EntraGroupObjectId '00000000-0000-0000-0000-000000000000' `
    -AzFilesHybridPath 'C:\\Tools\\AzFilesHybrid' -RunDebugAuth -Verbose

.EXAMPLE
  # Step 1 — Dry run to preview all changes without applying them
  .\80_AVD_Configure_AzureFiles_FSLogix_ADDS.ps1 -SubscriptionId 'xxxx' -ResourceGroupName 'rg1' -StorageAccountName 'stfslogix01' -FileShareName 'profiles' `
    -AdGroupSam 'CONTOSO\\AVDUsers' -EntraGroupObjectId '00000000-0000-0000-0000-000000000000' -WhatIf -Verbose

.EXAMPLE
  # Step 1 — Interactive guided mode (discovers subscription, RG, storage account, share, and group)
  .\80_AVD_Configure_AzureFiles_FSLogix_ADDS.ps1 -Interactive -Verbose

.EXAMPLE
  # Step 2 — After Step 1 completes, run this on every session host
  .\81_AVD_Configure_AzureFiles_FSLogix_ADDS_Registry.ps1 -StorageAccountName 'stfslogix01' -FileShareName 'profiles' -Verbose
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string] $SubscriptionId,
  [string] $ResourceGroupName,
  [string] $StorageAccountName,
  [string] $FileShareName,
  [string] $AdGroupSam,
  [string] $EntraGroupObjectId,
  [ValidatePattern('^[A-Z]$')] [string] $DriveLetter = 'Y',
  [string] $AzFilesHybridPath,
  [string] $ModulePath = 'C:\DEVOPS\_psmodules',
  [string] $OrganizationalUnitDistinguishedName = $null,
  [ValidateSet('KeepCurrent','AD','AADDS','AADKERB','ENTRAID','None')] [string] $TargetIdentityMode = 'KeepCurrent',
  [ValidateSet('Interactive','DeviceCode','ServicePrincipalSecret','ServicePrincipalCertificate','ManagedIdentity')] [string] $AuthMethod = 'Interactive',
  [string] $TenantId,
  [string] $ServicePrincipalApplicationId,
  [securestring] $ServicePrincipalClientSecret,
  [string] $ServicePrincipalCertificateThumbprint,
  [switch] $UseDeviceAuthentication,
  [switch] $RunDebugAuth,
  [switch] $RestartHost,
  [switch] $AllowHighImpactIdentityTransition,
  [switch] $Interactive
)

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Please run this script in an *elevated* PowerShell session (Run as Administrator).'
  }
}

function Initialize-Modules {
  Write-Verbose 'Loading Azure PowerShell modules from explicit local/system paths...'

  if (-not [string]::IsNullOrWhiteSpace($ModulePath) -and (Test-Path $ModulePath)) {
    $pathParts = @($env:PSModulePath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($pathParts -notcontains $ModulePath) {
      $env:PSModulePath = "$ModulePath;$env:PSModulePath"
      Write-Verbose "Prepended ModulePath to PSModulePath: $ModulePath"
    }
  }

  $requiredModules = @('Az.Accounts', 'Az.Resources', 'Az.Storage')
  foreach ($moduleName in $requiredModules) {
    $loadedModule = Get-Module -Name $moduleName -ErrorAction SilentlyContinue
    if ($loadedModule -and $loadedModule.ModuleBase -like '*OneDrive*') {
      Write-Verbose "Removing loaded OneDrive-backed module: $moduleName ($($loadedModule.ModuleBase))"
      Remove-Module -Name $moduleName -Force -WhatIf:$false -Confirm:$false -ErrorAction Stop
    }

    $moduleInfo = $null

    if (-not [string]::IsNullOrWhiteSpace($ModulePath) -and (Test-Path $ModulePath)) {
      $moduleInfo = Get-Module -ListAvailable -Name $moduleName |
        Where-Object { $_.ModuleBase -like "$ModulePath*" } |
        Sort-Object Version -Descending |
        Select-Object -First 1
    }

    if ($null -eq $moduleInfo) {
      $moduleInfo = Get-Module -ListAvailable -Name $moduleName |
        Where-Object { $_.ModuleBase -notlike '*OneDrive*' } |
        Sort-Object Version -Descending |
        Select-Object -First 1
    }

    if ($null -eq $moduleInfo) {
      throw "Required module '$moduleName' not found in '$ModulePath' or non-OneDrive system module paths."
    }

    try {
      Import-Module $moduleInfo.Path -Force -ErrorAction Stop -Verbose:$false -DisableNameChecking
    } catch {
      Write-Warning "Import-Module $moduleName failed: $($_.Exception.Message)"
    }
  }
}

function Import-AzFilesHybridModule {
  param([string]$AzFilesHybridPath)

  $isPowerShellCore = $PSVersionTable.PSEdition -eq 'Core'

  function Import-AzFilesHybridCompat {
    param([Parameter(Mandatory)][string]$ModuleNameOrPath)

    if ($isPowerShellCore) {
      Write-Verbose 'PowerShell 7 detected. Trying native import with -SkipEditionCheck first.'
      try {
        Import-Module $ModuleNameOrPath -SkipEditionCheck -ErrorAction Stop -Verbose:$false
        Write-Verbose 'AzFilesHybrid imported natively with -SkipEditionCheck.'
        return
      }
      catch {
        Write-Verbose "Native import failed: $($_.Exception.Message)"

        $nativeCommandsAvailable =
          (Get-Command -Name Join-AzStorageAccount -ErrorAction SilentlyContinue) -and
          (Get-Command -Name Debug-AzStorageAccountAuth -ErrorAction SilentlyContinue)

        if ($nativeCommandsAvailable) {
          Write-Verbose 'AzFilesHybrid commands are available despite import exception. Continuing without WinPS fallback.'
          return
        }

        Write-Verbose 'Falling back to Windows PowerShell compatibility mode.'

        if (-not [string]::IsNullOrWhiteSpace($ModulePath) -and (Test-Path $ModulePath)) {
          $pathParts = @($env:PSModulePath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
          if ($pathParts -notcontains $ModulePath) {
            $env:PSModulePath = "$ModulePath;$env:PSModulePath"
          }
        }

        Import-Module $ModuleNameOrPath -UseWindowsPowerShell -ErrorAction Stop -Verbose:$false
        return
      }
    }

    Import-Module $ModuleNameOrPath -ErrorAction Stop -Verbose:$false
  }

  function Resolve-AzFilesHybridManifestFromPath {
    param([Parameter(Mandatory)][string]$BasePath)

    if (-not (Test-Path $BasePath)) {
      return $null
    }

    $directManifest = Join-Path $BasePath 'AzFilesHybrid.psd1'
    if (Test-Path $directManifest) {
      return $directManifest
    }

    $moduleFolder = Join-Path $BasePath 'AzFilesHybrid'
    if (Test-Path $moduleFolder) {
      $moduleManifest = Join-Path $moduleFolder 'AzFilesHybrid.psd1'
      if (Test-Path $moduleManifest) {
        return $moduleManifest
      }

      $versionDir = Get-ChildItem -Path $moduleFolder -Directory -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Name } -Descending |
        Select-Object -First 1

      if ($versionDir) {
        $versionManifest = Join-Path $versionDir.FullName 'AzFilesHybrid.psd1'
        if (Test-Path $versionManifest) {
          return $versionManifest
        }
      }
    }

    return $null
  }

  if ($AzFilesHybridPath -and (Test-Path $AzFilesHybridPath)) {
    $manifestPath = Resolve-AzFilesHybridManifestFromPath -BasePath $AzFilesHybridPath
    if ($manifestPath) {
      Write-Verbose "Importing AzFilesHybrid from $manifestPath"
      Import-AzFilesHybridCompat -ModuleNameOrPath $manifestPath
      return
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($ModulePath) -and (Test-Path $ModulePath)) {
    $manifestPath = Resolve-AzFilesHybridManifestFromPath -BasePath $ModulePath
    if ($manifestPath) {
      Write-Verbose "Importing AzFilesHybrid from local module path manifest: $manifestPath"
      Import-AzFilesHybridCompat -ModuleNameOrPath $manifestPath
      return
    }

    $moduleInfo = Get-Module -ListAvailable -Name AzFilesHybrid |
      Where-Object { $_.ModuleBase -like "$ModulePath*" } |
      Sort-Object Version -Descending |
      Select-Object -First 1

    if ($moduleInfo) {
      Write-Verbose "Importing AzFilesHybrid from local module path: $($moduleInfo.ModuleBase)"
      Import-AzFilesHybridCompat -ModuleNameOrPath $moduleInfo.Path
      return
    }
  }

  # If path not provided, try to import if already installed in PSModulePath
  if (Get-Module -ListAvailable -Name AzFilesHybrid) {
    $moduleInfo = Get-Module -ListAvailable -Name AzFilesHybrid |
      Where-Object { $_.ModuleBase -notlike '*OneDrive*' } |
      Sort-Object Version -Descending |
      Select-Object -First 1

    if ($moduleInfo) {
      Write-Verbose "Importing AzFilesHybrid from non-OneDrive module path: $($moduleInfo.ModuleBase)"
      Import-AzFilesHybridCompat -ModuleNameOrPath $moduleInfo.Path
      return
    }
  }

  throw "AzFilesHybrid module not found in '$ModulePath' or non-OneDrive system module paths. Download/extract AzFilesHybrid and pass -AzFilesHybridPath, or save the module to '$ModulePath'."
}

function Connect-Azure {
  Write-Verbose 'Connecting to Azure...'

  if ($UseDeviceAuthentication) {
    $script:AuthMethod = 'DeviceCode'
  }

  $resolvedAuthMethod = $AuthMethod

  try {
    $connectParams = @{ ErrorAction = 'Stop' }
    if ($TenantId) { $connectParams['TenantId'] = $TenantId }

    switch ($resolvedAuthMethod) {
      'Interactive' {
        Write-Verbose 'Clearing any cached Azure session to ensure fresh credential prompt...'
        Disconnect-AzAccount -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
        Clear-AzContext -Scope Process -Force -ErrorAction SilentlyContinue | Out-Null
        Write-Host 'Opening interactive browser login...' -ForegroundColor Cyan
        Connect-AzAccount @connectParams | Out-Null
      }
      'DeviceCode' {
        Write-Verbose 'Clearing any cached Azure session to ensure fresh credential prompt...'
        Disconnect-AzAccount -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
        Clear-AzContext -Scope Process -Force -ErrorAction SilentlyContinue | Out-Null
        Write-Host 'Device code authentication: visit https://microsoft.com/devicelogin' -ForegroundColor Cyan
        $connectParams['UseDeviceAuthentication'] = $true
        Connect-AzAccount @connectParams | Out-Null
      }
      'ServicePrincipalSecret' {
        $appId = $ServicePrincipalApplicationId
        if ([string]::IsNullOrWhiteSpace($appId)) {
          $appId = Read-RequiredInput -Prompt 'Application (Client) ID' -Purpose 'Used to authenticate to Azure as the automation identity that performs storage and RBAC configuration.'
        }

        $secret = $ServicePrincipalClientSecret
        if ($null -eq $secret) {
          $secret = Read-Host -Prompt 'Client Secret' -AsSecureString
        }

        $tenantToUse = $TenantId
        if ([string]::IsNullOrWhiteSpace($tenantToUse)) {
          $tenantToUse = Read-RequiredInput -Prompt 'Tenant ID' -Purpose 'Required to authenticate the service principal against the correct Microsoft Entra tenant.'
        }

        $cred = New-Object System.Management.Automation.PSCredential($appId, $secret)
        Connect-AzAccount -ServicePrincipal -Credential $cred -TenantId $tenantToUse -ErrorAction Stop | Out-Null
      }
      'ServicePrincipalCertificate' {
        $appId = $ServicePrincipalApplicationId
        if ([string]::IsNullOrWhiteSpace($appId)) {
          $appId = Read-RequiredInput -Prompt 'Application (Client) ID' -Purpose 'Used to authenticate to Azure as the automation identity that performs storage and RBAC configuration.'
        }

        $certThumb = $ServicePrincipalCertificateThumbprint
        if ([string]::IsNullOrWhiteSpace($certThumb)) {
          $certThumb = Read-RequiredInput -Prompt 'Certificate Thumbprint' -Purpose 'Used to locate the local certificate for certificate-based service principal authentication.'
        }

        $tenantToUse = $TenantId
        if ([string]::IsNullOrWhiteSpace($tenantToUse)) {
          $tenantToUse = Read-RequiredInput -Prompt 'Tenant ID' -Purpose 'Required to authenticate the service principal against the correct Microsoft Entra tenant.'
        }

        Connect-AzAccount -ServicePrincipal -ApplicationId $appId -CertificateThumbprint $certThumb -TenantId $tenantToUse -ErrorAction Stop | Out-Null
      }
      'ManagedIdentity' {
        Write-Host 'Authenticating with Managed Identity...' -ForegroundColor Cyan
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
      }
      default {
        throw "Unsupported AuthMethod '$resolvedAuthMethod'."
      }
    }

    $ctx = Get-AzContext -ErrorAction Stop
    if ($null -ne $ctx) {
      Write-Host "Authenticated: $($ctx.Account.Id)" -ForegroundColor Green
      Write-Host "Tenant: $($ctx.Tenant.Id) | Subscription: $($ctx.Subscription.Name)" -ForegroundColor Gray
      if ($SubscriptionId) {
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
        Write-Host "Subscription context set to: $SubscriptionId" -ForegroundColor Green
      }
      return $true
    }

    return $false
  }
  catch {
    Write-Error "Authentication failed: $($_.Exception.Message)"
    return $false
  }
}

function Select-FromMenu {
  param(
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][string]$Message,
    [string]$Purpose,
    [Parameter(Mandatory)][array]$Items,
    [Parameter(Mandatory)][scriptblock]$LabelScript,
    [int]$DefaultIndex = 0
  )

  if ($Items.Count -eq 0) {
    throw "No options available for '$Title'."
  }

  if ($DefaultIndex -lt 0 -or $DefaultIndex -ge $Items.Count) {
    $DefaultIndex = 0
  }

  Write-Host "`n$Title" -ForegroundColor Cyan
  Write-Host $Message
  if (-not [string]::IsNullOrWhiteSpace($Purpose)) {
    Write-Host "Purpose: $Purpose" -ForegroundColor DarkGray
  }

  for ($index = 0; $index -lt $Items.Count; $index++) {
    $label = (& $LabelScript $Items[$index])
    Write-Host ('[{0}] {1}' -f ($index + 1), $label)
  }

  $defaultChoice = $DefaultIndex + 1

  while ($true) {
    $raw = Read-Host -Prompt "Enter selection number (default: $defaultChoice)"
    if ([string]::IsNullOrWhiteSpace($raw)) {
      return $Items[$DefaultIndex]
    }

    $selected = 0
    if (-not [int]::TryParse($raw, [ref]$selected)) {
      Write-Warning 'Invalid number. Please enter a numeric choice.'
      continue
    }

    if ($selected -lt 1 -or $selected -gt $Items.Count) {
      Write-Warning "Selection out of range. Choose a number between 1 and $($Items.Count)."
      continue
    }

    return $Items[$selected - 1]
  }
}

function Get-StorageIdentityMode {
  param([Parameter(Mandatory)]$StorageAccount)

  $mode = $StorageAccount.AzureFilesIdentityBasedAuth.DirectoryServiceOptions
  if ([string]::IsNullOrWhiteSpace([string]$mode)) {
    return 'None'
  }
  return [string]$mode
}

function Get-StorageLabel {
  param([Parameter(Mandatory)]$StorageAccount)

  $sku = if ($StorageAccount.Sku -and $StorageAccount.Sku.Name) { $StorageAccount.Sku.Name } else { 'UnknownSku' }
  $kind = if ($StorageAccount.Kind) { $StorageAccount.Kind } else { 'UnknownKind' }
  $identityMode = Get-StorageIdentityMode -StorageAccount $StorageAccount
  return "$($StorageAccount.StorageAccountName) | Kind=$kind | SKU=$sku | Identity=$identityMode"
}

function Resolve-EffectiveIdentityMode {
  param(
    [Parameter(Mandatory)][string]$RequestedMode,
    [Parameter(Mandatory)][string]$CurrentMode
  )

  # Keep ENTRAID as a user-facing alias and map it to Azure Files Entra Kerberos mode.
  if ($RequestedMode -eq 'ENTRAID') {
    return 'AADKERB'
  }

  if ($RequestedMode -eq 'KeepCurrent') {
    if ([string]::IsNullOrWhiteSpace($CurrentMode)) {
      return 'None'
    }
    return $CurrentMode
  }

  return $RequestedMode
}

function Get-IdentityRecommendation {
  param(
    [Parameter(Mandatory)][string]$CurrentMode,
    [Parameter(Mandatory)][string]$RequestedMode
  )

  $effectiveMode = Resolve-EffectiveIdentityMode -RequestedMode $RequestedMode -CurrentMode $CurrentMode
  $isConfigured = $CurrentMode -ne 'None'
  $needsSuggestion = $false
  $recommendation = ''

  if (-not $isConfigured) {
    $needsSuggestion = $true
    $recommendation = 'No storage identity provisioning is configured. For FSLogix, select AD, AADDS, or AADKERB.'
  }
  elseif ($effectiveMode -eq 'None') {
    $needsSuggestion = $true
    $recommendation = 'Identity mode None is not recommended for FSLogix profile access. Consider AD, AADDS, or AADKERB.'
  }

  [pscustomobject]@{
    CurrentMode = $CurrentMode
    RequestedMode = $RequestedMode
    EffectiveMode = $effectiveMode
    IsConfigured = $isConfigured
    NeedsSuggestion = $needsSuggestion
    Recommendation = $recommendation
  }
}

function Write-IdentityRecommendation {
  param(
    [Parameter(Mandatory)]$Assessment
  )

  Write-Host "Storage Identity Assessment: Current=$($Assessment.CurrentMode), Requested=$($Assessment.RequestedMode), Effective=$($Assessment.EffectiveMode)" -ForegroundColor DarkCyan

  if ($Assessment.NeedsSuggestion) {
    Write-Warning $Assessment.Recommendation
    Write-Host 'Suggested action:' -ForegroundColor Yellow
    Write-Host '  - AD      : For classic domain-joined hosts and on-prem AD DS'
    Write-Host '  - AADDS   : For Microsoft Entra Domain Services scenarios'
    Write-Host '  - ENTRAID : Alias for Microsoft Entra ID (mapped to AADKERB for Azure Files SMB)'
    Write-Host '  - AADKERB : For Microsoft Entra Kerberos scenarios'
  }
}

function Test-AdDsEnrollmentCondition {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$StorageAccount
  )

  $mode = Get-StorageIdentityMode -StorageAccount $StorageAccount
  $props = $StorageAccount.AzureFilesIdentityBasedAuth.ActiveDirectoryProperties
  $requiredFields = @('DomainName', 'NetBiosDomainName', 'ForestName', 'DomainGuid', 'DomainSid', 'AzureStorageSid', 'SamAccountName')
  $missingFields = @()

  foreach ($field in $requiredFields) {
    $value = $null
    if ($props) {
      $value = $props.$field
    }

    if ([string]::IsNullOrWhiteSpace([string]$value)) {
      $missingFields += $field
    }
  }

  $isAdMode = $mode -eq 'AD'
  $isReady = $isAdMode -and ($missingFields.Count -eq 0)

  [pscustomobject]@{
    CurrentMode = $mode
    IsReady = $isReady
    MissingFields = $missingFields
  }
}

function Test-EnrollmentCondition {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]$StorageAccount,
    [Parameter(Mandatory)][string]$EffectiveMode
  )

  $currentMode = Get-StorageIdentityMode -StorageAccount $StorageAccount
  $missingFields = @()
  $isReady = $false
  $repairHint = ''

  switch ($EffectiveMode) {
    'AD' {
      $adCheck = Test-AdDsEnrollmentCondition -StorageAccount $StorageAccount
      $missingFields = $adCheck.MissingFields
      $isReady = $adCheck.IsReady
      $repairHint = 'Run Join-AzStorageAccount to complete or repair AD DS enrollment.'
    }
    'AADDS' {
      $props = $StorageAccount.AzureFilesIdentityBasedAuth.ActiveDirectoryProperties
      $requiredFields = @('DomainName', 'NetBiosDomainName', 'ForestName', 'DomainGuid', 'DomainSid')

      foreach ($field in $requiredFields) {
        $value = $null
        if ($props) {
          $value = $props.$field
        }

        if ([string]::IsNullOrWhiteSpace([string]$value)) {
          $missingFields += $field
        }
      }

      $isReady = ($currentMode -eq 'AADDS') -and ($missingFields.Count -eq 0)
      $repairHint = 'Re-enable Azure AD DS identity mode and verify domain service metadata is populated.'
    }
    'AADKERB' {
      $isReady = $currentMode -eq 'AADKERB'
      $repairHint = 'Enable Microsoft Entra Kerberos for Azure Files on the storage account.'
    }
    'None' {
      $isReady = $false
      $repairHint = 'Identity mode None cannot satisfy FSLogix domain-based access requirements.'
    }
    default {
      $isReady = $false
      $repairHint = "Unsupported effective identity mode '$EffectiveMode'."
    }
  }

  [pscustomobject]@{
    CurrentMode = $currentMode
    EffectiveMode = $EffectiveMode
    IsReady = $isReady
    MissingFields = $missingFields
    RepairHint = $repairHint
  }
}

function Write-EnrollmentCondition {
  param(
    [Parameter(Mandatory)]$Assessment
  )

  Write-Host "Enrollment Condition: Effective=$($Assessment.EffectiveMode), Current=$($Assessment.CurrentMode), Ready=$($Assessment.IsReady)" -ForegroundColor DarkCyan
  if (-not $Assessment.IsReady) {
    if ($Assessment.MissingFields -and $Assessment.MissingFields.Count -gt 0) {
      Write-Warning "Missing identity metadata fields: $($Assessment.MissingFields -join ', ')"
    }
    Write-Warning $Assessment.RepairHint
  }
}

function Normalize-AdGroupSam {
  param(
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $Value
  }

  $normalized = $Value.Trim().Trim('"')
  # Users often paste escaped values like DOMAIN\\Group; normalize to DOMAIN\Group.
  $normalized = $normalized -replace '\\{2,}', '\\'
  return $normalized
}

function Test-IdentityTransitionPreflight {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$CurrentMode,
    [Parameter(Mandatory)][string]$EffectiveMode
  )

  $issues = @()
  $warnings = @()

  if ($EffectiveMode -eq 'AD') {
    # AD DS conversion requires a domain-joined execution context with AD line of sight.
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    if (-not $computerSystem -or -not $computerSystem.PartOfDomain) {
      $issues += 'Host is not domain joined. AD DS enrollment requires running from a domain-joined machine.'
    }

    $normalizedAdGroupSam = Normalize-AdGroupSam -Value $AdGroupSam
    if (-not [string]::Equals($normalizedAdGroupSam, $AdGroupSam, [System.StringComparison]::Ordinal)) {
      $warnings += "AdGroupSam was normalized from '$AdGroupSam' to '$normalizedAdGroupSam'."
      $script:AdGroupSam = $normalizedAdGroupSam
    }

    if ([string]::IsNullOrWhiteSpace($normalizedAdGroupSam)) {
      $issues += 'AdGroupSam is required for AD DS mode.'
    }
    elseif ($normalizedAdGroupSam -notmatch '^[^\\]+\\[^\\]+$') {
      $issues += "AdGroupSam must use DOMAIN\Group format. Received '$normalizedAdGroupSam'."
    }

    $joinCommand = Get-Command -Name Join-AzStorageAccount -ErrorAction SilentlyContinue
    if (-not $joinCommand) {
      $issues += 'Join-AzStorageAccount command is unavailable. Ensure AzFilesHybrid is imported successfully.'
    }

    $getAdDomainCmd = Get-Command -Name Get-ADDomain -ErrorAction SilentlyContinue
    if ($getAdDomainCmd) {
      try {
        Get-ADDomain -ErrorAction Stop | Out-Null
      }
      catch {
        $warnings += "Unable to query Active Directory domain from this host: $($_.Exception.Message)"
        $warnings += 'AD DS preflight could not fully verify domain connectivity. Conversion may still fail if AD DS is unreachable.'
      }
    }
    else {
      $warnings += 'Get-ADDomain command is unavailable (RSAT AD module not found). AD reachability checks are limited.'
    }

    if ($CurrentMode -eq 'AADKERB') {
      $warnings += 'Transition AADKERB -> AD is a high-impact identity switch. Validate AD DS permissions/connectivity before conversion.'
    }
  }

  [pscustomobject]@{
    CurrentMode = $CurrentMode
    EffectiveMode = $EffectiveMode
    IsReady = ($issues.Count -eq 0)
    Issues = $issues
    Warnings = $warnings
  }
}

function Write-IdentityTransitionPreflight {
  param(
    [Parameter(Mandatory)]$Assessment
  )

  Write-Host "Transition Preflight: Current=$($Assessment.CurrentMode), Target=$($Assessment.EffectiveMode), Ready=$($Assessment.IsReady)" -ForegroundColor DarkCyan

  foreach ($warning in $Assessment.Warnings) {
    Write-Warning $warning
  }

  if ($Assessment.Issues -and $Assessment.Issues.Count -gt 0) {
    $issueSummary = $Assessment.Issues -join "`nERROR: "
    Write-Host ("ERROR: {0}" -f $issueSummary) -ForegroundColor Red
  }
}

function Confirm-HighImpactIdentityTransition {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$CurrentMode,
    [Parameter(Mandatory)][string]$EffectiveMode
  )

  if (-not ($CurrentMode -eq 'AADKERB' -and $EffectiveMode -eq 'AD')) {
    return
  }

  if ($AllowHighImpactIdentityTransition) {
    Write-Warning 'High-impact transition AADKERB -> AD confirmed via -AllowHighImpactIdentityTransition.'
    return
  }

  if (-not $Interactive) {
    throw "Transition '$CurrentMode' -> '$EffectiveMode' requires explicit confirmation. Re-run with -Interactive and type the confirmation phrase, or use -AllowHighImpactIdentityTransition if this is intentional automation."
  }

  $confirmationPhrase = 'I-UNDERSTAND-AADKERB-TO-AD'
  Write-Warning 'You are about to perform a high-impact identity transition from AADKERB to AD.'
  Write-Warning 'This can disrupt SMB authentication paths if AD DS prerequisites are not fully validated.'
  $enteredPhrase = Read-Host -Prompt "Type '$confirmationPhrase' to continue"

  if ($enteredPhrase -ne $confirmationPhrase) {
    throw "Transition '$CurrentMode' -> '$EffectiveMode' cancelled because confirmation phrase did not match."
  }
}

function Read-RequiredInput {
  param(
    [Parameter(Mandatory)][string]$Prompt,
    [string]$Purpose,
    [string]$DefaultValue
  )

  if (-not [string]::IsNullOrWhiteSpace($Purpose)) {
    Write-Host "Purpose: $Purpose" -ForegroundColor DarkGray
  }

  while ($true) {
    $value = Read-Host -Prompt $Prompt
    if ([string]::IsNullOrWhiteSpace($value)) {
      if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
        return $DefaultValue
      }
      Write-Warning 'A value is required.'
      continue
    }
    return $value
  }
}

function Resolve-ExecutionParameters {
  $missingRequired = @(
    [string]::IsNullOrWhiteSpace($SubscriptionId),
    [string]::IsNullOrWhiteSpace($ResourceGroupName),
    [string]::IsNullOrWhiteSpace($StorageAccountName),
    [string]::IsNullOrWhiteSpace($FileShareName),
    [string]::IsNullOrWhiteSpace($EntraGroupObjectId)
  ) -contains $true

  $useInteractive = $Interactive -or $missingRequired

  if (-not $useInteractive) {
    return
  }

  Write-Host 'Interactive discovery mode enabled. Scanning tenant and building options...' -ForegroundColor Cyan

  if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $subscriptions = Get-AzSubscription | Sort-Object Name
    if (-not $subscriptions) {
      throw 'No Azure subscriptions found for the current account.'
    }

    $selectedSubscription = Select-FromMenu -Title 'Subscription' -Message 'Select the subscription to use:' -Purpose 'This sets the tenant/subscription context used for all Azure queries and changes in this run.' -Items $subscriptions -LabelScript {
      param($item)
      "$($item.Name) [$($item.Id)]"
    }
    $script:SubscriptionId = $selectedSubscription.Id
  }

  $ctx = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
  Write-Verbose "Active context subscription: $($ctx.Subscription.Id)"

  if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $resourceGroups = Get-AzResourceGroup | Sort-Object ResourceGroupName
    if (-not $resourceGroups) {
      Write-Warning 'No resource groups were returned for the selected subscription.'
      Write-Warning 'This can be caused by lack of Reader permissions at subscription scope or an empty subscription.'
      $script:ResourceGroupName = Read-RequiredInput -Prompt 'Enter resource group name manually to continue' -Purpose 'The script must know which resource group contains the target storage account.'
    }
    else {
      $selectedResourceGroup = Select-FromMenu -Title 'Resource Group' -Message 'Select the resource group containing the storage account:' -Purpose 'Used to locate the Azure Files storage account that will host FSLogix profiles.' -Items $resourceGroups -LabelScript {
        param($item)
        $item.ResourceGroupName
      }
      $script:ResourceGroupName = $selectedResourceGroup.ResourceGroupName
    }
  }

  if ([string]::IsNullOrWhiteSpace($StorageAccountName)) {
    $storageAccounts = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName | Sort-Object StorageAccountName
    if (-not $storageAccounts) {
      throw "No storage accounts found in resource group '$ResourceGroupName'."
    }

    $selectedStorageAccount = Select-FromMenu -Title 'Storage Account' -Message 'Select the storage account for FSLogix profiles:' -Purpose 'This storage account receives identity configuration updates and hosts the profile file share.' -Items $storageAccounts -LabelScript {
      param($item)
      Get-StorageLabel -StorageAccount $item
    }
    $script:StorageAccountName = $selectedStorageAccount.StorageAccountName
  }

  $selectedStorage = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop
  $currentIdentityMode = Get-StorageIdentityMode -StorageAccount $selectedStorage
  $identityAssessment = Get-IdentityRecommendation -CurrentMode $currentIdentityMode -RequestedMode $TargetIdentityMode
  Write-IdentityRecommendation -Assessment $identityAssessment

  if (-not $PSBoundParameters.ContainsKey('TargetIdentityMode')) {
    $identityOptions = @(
      [pscustomobject]@{ Name = 'KeepCurrent'; Description = "Keep current mode ($currentIdentityMode)" },
      [pscustomobject]@{ Name = 'AD'; Description = 'Active Directory Domain Services (on-prem AD DS)' },
      [pscustomobject]@{ Name = 'AADDS'; Description = 'Microsoft Entra Domain Services (Azure AD DS)' },
      [pscustomobject]@{ Name = 'ENTRAID'; Description = 'Microsoft Entra ID (mapped to Entra Kerberos for Azure Files SMB)' },
      [pscustomobject]@{ Name = 'AADKERB'; Description = 'Microsoft Entra Kerberos' },
      [pscustomobject]@{ Name = 'None'; Description = 'Disable identity-based auth (not recommended for FSLogix)' }
    )

    $defaultIdentityIndex = 0
    if ($currentIdentityMode -eq 'AD') { $defaultIdentityIndex = 1 }
    elseif ($currentIdentityMode -eq 'AADDS') { $defaultIdentityIndex = 2 }
    elseif ($currentIdentityMode -eq 'AADKERB') { $defaultIdentityIndex = 4 }

    $selectedIdentity = Select-FromMenu -Title 'Identity Provisioning' -Message "Current identity mode: $currentIdentityMode. Select target mode:" -Purpose 'Controls which identity provider Azure Files SMB auth will use for FSLogix profile access.' -Items $identityOptions -LabelScript {
      param($item)
      "$($item.Name) - $($item.Description)"
    } -DefaultIndex $defaultIdentityIndex

    $script:TargetIdentityMode = $selectedIdentity.Name
  }

  $effectiveIdentityMode = Resolve-EffectiveIdentityMode -RequestedMode $TargetIdentityMode -CurrentMode $currentIdentityMode

  if ([string]::IsNullOrWhiteSpace($FileShareName)) {
    $storageKey = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccountName)[0].Value
    $storageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $storageKey
    $shares = Get-AzStorageShare -Context $storageContext | Sort-Object Name

    if (-not $shares) {
      $script:FileShareName = Read-RequiredInput -Prompt 'No file shares found. Enter a new Azure Files share name to use/create' -Purpose 'This share path becomes the FSLogix profile container location (VHDLocations).'
    } else {
      $selectedShare = Select-FromMenu -Title 'File Share' -Message 'Select the Azure Files share for FSLogix containers:' -Purpose 'This is where user profile containers (VHD/VHDX) will be stored and mounted by FSLogix.' -Items $shares -LabelScript {
        param($item)
        $item.Name
      }
      $script:FileShareName = $selectedShare.Name
    }
  }

  if ($effectiveIdentityMode -eq 'AD' -and [string]::IsNullOrWhiteSpace($AdGroupSam)) {
    $defaultSam = if ([string]::IsNullOrWhiteSpace($env:USERDOMAIN)) { '' } else { "$($env:USERDOMAIN)\AVDUsers" }
    $script:AdGroupSam = Read-RequiredInput -Prompt "Identity mode AD selected. Enter AD DS group in DOMAIN\Group format (default: $defaultSam)" -Purpose 'Use the AD DS security group that contains users assigned to access AVD. This group receives NTFS Modify permissions on the profile share so those users can create/use FSLogix profile containers.' -DefaultValue $defaultSam
  }

  if ($effectiveIdentityMode -eq 'AD' -and -not [string]::IsNullOrWhiteSpace($AdGroupSam)) {
    $normalizedAdGroupSam = Normalize-AdGroupSam -Value $AdGroupSam
    if (-not [string]::Equals($normalizedAdGroupSam, $AdGroupSam, [System.StringComparison]::Ordinal)) {
      Write-Warning "Normalized AD DS group value from '$AdGroupSam' to '$normalizedAdGroupSam'."
      $script:AdGroupSam = $normalizedAdGroupSam
    }
  }

  if ([string]::IsNullOrWhiteSpace($EntraGroupObjectId)) {
    Write-Host 'Purpose: Used to find the Entra group that will receive share-level SMB RBAC (Storage File Data SMB Share Contributor).' -ForegroundColor DarkGray
    $groupHint = Read-Host -Prompt 'Enter Entra group name prefix to search (press Enter for AVD)'
    if ([string]::IsNullOrWhiteSpace($groupHint)) { $groupHint = 'AVD' }

    $entraGroups = @(Get-AzADGroup -DisplayNameStartsWith $groupHint -First 50 -ErrorAction SilentlyContinue)
    if (-not $entraGroups) {
      Write-Warning "No groups found with prefix '$groupHint'. Showing first 50 groups instead."
      $entraGroups = @(Get-AzADGroup -First 50)
    }

    if (-not $entraGroups) {
      $script:EntraGroupObjectId = Read-RequiredInput -Prompt 'No Entra groups available from API query. Enter Entra Group ObjectId manually' -Purpose 'This group receives Azure Files share-level RBAC access required for SMB authorization.'
    } else {
      $selectedEntraGroup = Select-FromMenu -Title 'Entra Group' -Message 'Select the Entra group for share-level RBAC assignment:' -Purpose 'This group will be assigned share-level RBAC for Azure Files SMB access.' -Items $entraGroups -LabelScript {
        param($item)
        "$($item.DisplayName) [$($item.Id)]"
      }
      $script:EntraGroupObjectId = $selectedEntraGroup.Id
    }
  }

  Write-Host 'Selection summary:' -ForegroundColor Green
  Write-Host "  SubscriptionId    : $SubscriptionId"
  Write-Host "  ResourceGroupName : $ResourceGroupName"
  Write-Host "  StorageAccountName: $StorageAccountName"
  Write-Host "  StorageKind/SKU    : $($selectedStorage.Kind) / $($selectedStorage.Sku.Name)"
  Write-Host "  CurrentIdentity    : $currentIdentityMode"
  Write-Host "  TargetIdentityMode : $TargetIdentityMode"
  Write-Host "  EffectiveIdentity  : $effectiveIdentityMode"
  Write-Host "  FileShareName     : $FileShareName"
  if (-not [string]::IsNullOrWhiteSpace($AdGroupSam)) {
    Write-Host "  AdGroupSam        : $AdGroupSam"
  }
  Write-Host "  EntraGroupObjectId: $EntraGroupObjectId"
}

function Assert-RequiredParameters {
  $selectedStorage = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop
  $currentIdentityMode = Get-StorageIdentityMode -StorageAccount $selectedStorage
  $effectiveIdentityMode = Resolve-EffectiveIdentityMode -RequestedMode $TargetIdentityMode -CurrentMode $currentIdentityMode

  $required = @{
    SubscriptionId = $SubscriptionId
    ResourceGroupName = $ResourceGroupName
    StorageAccountName = $StorageAccountName
    FileShareName = $FileShareName
    EntraGroupObjectId = $EntraGroupObjectId
  }

  if ($effectiveIdentityMode -eq 'AD') {
    $required['AdGroupSam'] = $AdGroupSam
  }

  $missing = $required.GetEnumerator() |
    Where-Object { [string]::IsNullOrWhiteSpace($_.Value) } |
    Select-Object -ExpandProperty Key

  if ($missing) {
    throw "Missing required parameters: $($missing -join ', '). Provide them explicitly or use -Interactive."
  }
}

function Set-StorageIdentityProvisioning {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param()

  $storage = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop
  $currentMode = Get-StorageIdentityMode -StorageAccount $storage
  $effectiveMode = Resolve-EffectiveIdentityMode -RequestedMode $TargetIdentityMode -CurrentMode $currentMode
  $assessment = Get-IdentityRecommendation -CurrentMode $currentMode -RequestedMode $TargetIdentityMode

  Write-IdentityRecommendation -Assessment $assessment

  Write-Verbose "Storage account identity mode: current=$currentMode, requested=$TargetIdentityMode, effective=$effectiveMode"

  if ($effectiveMode -eq $currentMode) {
    $enrollment = Test-EnrollmentCondition -StorageAccount $storage -EffectiveMode $effectiveMode
    Write-EnrollmentCondition -Assessment $enrollment

    if (-not $enrollment.IsReady) {
      switch ($effectiveMode) {
        'AD' {
          Write-Verbose 'Running Join-AzStorageAccount to repair AD DS enrollment state...'
          Join-StorageToAD
          return 'AD'
        }
        'AADDS' {
          if ($PSCmdlet.ShouldProcess($StorageAccountName, 'Repair Azure AD DS identity configuration for Azure Files')) {
            Set-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -EnableAzureActiveDirectoryDomainServicesForFile $true | Out-Null
          }
          return 'AADDS'
        }
        'AADKERB' {
          if ($PSCmdlet.ShouldProcess($StorageAccountName, 'Repair Microsoft Entra Kerberos configuration for Azure Files')) {
            Set-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -EnableAzureActiveDirectoryKerberosForFile $true | Out-Null
          }
          return 'AADKERB'
        }
      }
    }

    Write-Verbose 'Storage identity mode already matches effective target. No conversion required.'
    return $effectiveMode
  }

  $transitionPreflight = Test-IdentityTransitionPreflight -CurrentMode $currentMode -EffectiveMode $effectiveMode
  Write-IdentityTransitionPreflight -Assessment $transitionPreflight
  if (-not $transitionPreflight.IsReady) {
    throw "Identity mode transition preflight failed. Resolve the reported issues before converting '$currentMode' to '$effectiveMode'."
  }

  Confirm-HighImpactIdentityTransition -CurrentMode $currentMode -EffectiveMode $effectiveMode

  try {
    switch ($effectiveMode) {
      'AD' {
        # If current mode is AADKERB, must disable it first
        if ($currentMode -eq 'AADKERB') {
          Write-Verbose 'Disabling AADKERB before enabling AD...'
          Set-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -EnableAzureActiveDirectoryKerberosForFile $false | Out-Null
        }
        Join-StorageToAD
        return 'AD'
      }
      'AADDS' {
        if ($currentMode -eq 'AADKERB') {
          Write-Verbose 'Disabling AADKERB before enabling AADDS...'
          Set-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -EnableAzureActiveDirectoryKerberosForFile $false | Out-Null
        }
        if ($PSCmdlet.ShouldProcess($StorageAccountName, 'Enable Azure AD DS for Azure Files')) {
          Set-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -EnableAzureActiveDirectoryDomainServicesForFile $true | Out-Null
        }
        return 'AADDS'
      }
      'AADKERB' {
        if ($currentMode -ne 'AADKERB') {
          if ($PSCmdlet.ShouldProcess($StorageAccountName, 'Enable Microsoft Entra Kerberos for Azure Files')) {
            Set-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -EnableAzureActiveDirectoryKerberosForFile $true | Out-Null
          }
        }
        return 'AADKERB'
      }
      'None' {
        if ($PSCmdlet.ShouldProcess($StorageAccountName, 'Disable identity-based auth options for Azure Files')) {
          Set-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -EnableAzureActiveDirectoryKerberosForFile $false -EnableAzureActiveDirectoryDomainServicesForFile $false -EnableActiveDirectoryDomainServicesForFile $false | Out-Null
        }
        return 'None'
      }
      default {
        throw "Unsupported effective identity mode '$effectiveMode'."
      }
    }
  } catch {
    $rawError = $_.Exception.Message
    Write-Error "Failed to set DirectoryServiceOptions to '$effectiveMode'. Error: $rawError"

    if ($effectiveMode -eq 'AD' -and $rawError -match 'rejected the client credentials|credential|access is denied|unauthorized') {
      throw 'Storage account identity mode change to AD failed due to credential validation. Run from a domain-joined host with AD DS line of sight, confirm Join-AzStorageAccount prerequisites, and verify the executing account has rights to create/update the storage account computer object in AD DS.'
    }

    throw "Storage account identity mode change failed. Please check permissions, region/SKU eligibility, and current configuration. See https://learn.microsoft.com/azure/storage/files/active-directory-overview for requirements."
  }
}

function Ensure-FileShareExists {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param()

  Write-Verbose "Ensuring Azure Files share '$FileShareName' exists in storage account '$StorageAccountName'..."

  $storageKey = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop)[0].Value
  $storageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $storageKey
  $existingShare = Get-AzStorageShare -Context $storageContext -Name $FileShareName -ErrorAction SilentlyContinue

  if ($existingShare) {
    Write-Verbose "Azure Files share '$FileShareName' already exists."
    return
  }

  if ($PSCmdlet.ShouldProcess("$StorageAccountName/$FileShareName", 'Create Azure Files share')) {
    New-AzStorageShare -Context $storageContext -Name $FileShareName -ErrorAction Stop | Out-Null
    Write-Verbose "Created Azure Files share '$FileShareName'."
  }
}

function Join-StorageToAD {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param()
  Write-Verbose 'Joining storage account identity to AD DS (computer account)...'
  $params = @{
    ResourceGroupName = $ResourceGroupName
    StorageAccountName = $StorageAccountName
    DomainAccountType = 'ComputerAccount'
  }
  if ($OrganizationalUnitDistinguishedName) {
    $params['OrganizationalUnitDistinguishedName'] = $OrganizationalUnitDistinguishedName
  }

  if ($PSCmdlet.ShouldProcess($StorageAccountName, 'Join-AzStorageAccount')) {
    Join-AzStorageAccount @params
  }

  Write-Verbose 'Verifying Azure Files identity-based auth properties...'
  $sa = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
  $sa.AzureFilesIdentityBasedAuth.DirectoryServiceOptions
  $sa.AzureFilesIdentityBasedAuth.ActiveDirectoryProperties
}

function Grant-ShareRbac {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param()
  Write-Verbose 'Assigning share-level RBAC role Storage File Data SMB Share Contributor to group...'

  $scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$StorageAccountName/fileServices/default/shares/$FileShareName"

  if ($PSCmdlet.ShouldProcess($scope, 'New-AzRoleAssignment')) {
    New-AzRoleAssignment -ObjectId $EntraGroupObjectId -RoleDefinitionName 'Storage File Data SMB Share Contributor' -Scope $scope | Out-Null
  }

  Write-Verbose 'RBAC assignment complete.'
}

function Set-NtfsAcls {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param()

  if (-not $PSCmdlet.ShouldProcess("\\$StorageAccountName.file.core.windows.net\$FileShareName", 'Set NTFS ACLs for FSLogix profile share')) {
    return
  }

  Write-Verbose 'Retrieving storage account key (key1) for temporary drive mapping...'
  $key = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccountName)[0].Value

  $unc = "\\$StorageAccountName.file.core.windows.net\$FileShareName"
  $drv = '{0}:' -f $DriveLetter

  Write-Verbose "Mapping $drv to $unc"
  cmd.exe /c "net use $drv $unc $key /user:Azure\$StorageAccountName" | Out-Null

  Write-Verbose 'Applying NTFS permissions per Microsoft Learn example...'
  if (-not (Test-Path $drv)) {
    throw "Drive mapping failed for $drv ($unc). Cannot apply NTFS ACLs."
  }

  icacls $drv /grant "$AdGroupSam`:(M)" | Out-Null
  icacls $drv /grant 'Creator Owner:(OI)(CI)(IO)(M)' | Out-Null
  icacls $drv /remove 'Authenticated Users' | Out-Null
  icacls $drv /remove 'Builtin\Users' | Out-Null

  Write-Verbose 'Disconnecting mapped drive...'
  cmd.exe /c "net use $drv /delete /y" | Out-Null
}

function Set-FSLogixConfiguration {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param()

  if (-not $PSCmdlet.ShouldProcess('HKLM:\SOFTWARE\FSLogix\Profiles', 'Configure FSLogix registry settings')) {
    return
  }

  Write-Verbose 'Configuring FSLogix registry keys Enabled and VHDLocations...'
  $regPath = 'HKLM:\SOFTWARE\FSLogix\Profiles'
  if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }

  New-ItemProperty -Path $regPath -Name Enabled -PropertyType DWORD -Value 1 -Force | Out-Null
  $vhdLoc = "\\$StorageAccountName.file.core.windows.net\$FileShareName"
  New-ItemProperty -Path $regPath -Name VHDLocations -PropertyType MultiString -Value $vhdLoc -Force | Out-Null

  Write-Verbose "FSLogix configured. VHDLocations = $vhdLoc"
}

function Test-ProfileShareAccess {
  [CmdletBinding()]
  param()

  $unc = "\\$StorageAccountName.file.core.windows.net\$FileShareName"
  Write-Verbose "Testing SMB access to $unc with current security context..."

  try {
    Get-ChildItem -LiteralPath $unc -ErrorAction Stop | Select-Object -First 1 | Out-Null
    Write-Host "SMB access test succeeded for $unc" -ForegroundColor Green
  }
  catch {
    Write-Warning "SMB access test failed for $unc : $($_.Exception.Message)"
    Write-Warning 'FSLogix may fail with error 0x0000052E until SMB identity/auth, RBAC, and NTFS ACLs are corrected.'
  }
}

function Invoke-DebugAuthCheck {
  Write-Verbose 'Running Debug-AzStorageAccountAuth (basic AD DS auth checks)...'
  Debug-AzStorageAccountAuth -StorageAccountName $StorageAccountName -ResourceGroupName $ResourceGroupName -Verbose
}

# MAIN
try {
  Assert-Admin
  Initialize-Modules

  # If you extracted AzFilesHybrid somewhere, pass it here:
  # Example: Import-AzFilesHybridModule -AzFilesHybridPath 'C:\\Tools\\AzFilesHybrid'
  # For now, attempt import from PSModulePath
  Import-AzFilesHybridModule -AzFilesHybridPath $AzFilesHybridPath

  $authOk = Connect-Azure
  if (-not $authOk) {
    throw 'Azure authentication failed. Provide valid credentials/auth method and retry.'
  }
  Resolve-ExecutionParameters
  Assert-RequiredParameters
  Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
  $effectiveIdentityMode = Set-StorageIdentityProvisioning

  $postProvisionStorage = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop
  $postProvisionAssessment = Test-EnrollmentCondition -StorageAccount $postProvisionStorage -EffectiveMode $effectiveIdentityMode
  Write-EnrollmentCondition -Assessment $postProvisionAssessment

  if (($effectiveIdentityMode -in @('AD', 'AADDS', 'AADKERB')) -and (-not $postProvisionAssessment.IsReady)) {
    throw "Enrollment condition for identity mode '$effectiveIdentityMode' is not ready. Resolve identity provisioning before continuing with share/RBAC/ACL tasks."
  }

  Ensure-FileShareExists
  Grant-ShareRbac
  if ($effectiveIdentityMode -eq 'AD') {
    try {
      Set-NtfsAcls
    } catch {
      Write-Error "Failed to set NTFS ACLs for AD group. Error: $($_.Exception.Message)"
      throw "NTFS ACL configuration failed. Ensure the AD group exists, you have permissions, and the share is accessible."
    }
  }
  elseif ($effectiveIdentityMode -eq 'AADDS' -or $effectiveIdentityMode -eq 'AADKERB') {
    Write-Verbose "Applying NTFS ACLs for identity mode '$effectiveIdentityMode' using Entra group."
    try {
      $entraGroupSid = $null
      # Try to resolve Entra group SID if synced to AD DS (for AADDS) or use Entra group for AADKERB
      if ($effectiveIdentityMode -eq 'AADDS') {
        $adGroupCmd = Get-Command -Name Get-ADGroup -ErrorAction SilentlyContinue
        if (-not $adGroupCmd) {
          Write-Warning 'Get-ADGroup is not available on this host. Install RSAT ActiveDirectory tools or set NTFS ACLs manually.'
        }
        else {
          $entraGroup = Get-AzADGroup -ObjectId $EntraGroupObjectId -ErrorAction SilentlyContinue
          $groupDisplayName = if ($entraGroup) { $entraGroup.DisplayName } else { $null }

          if ([string]::IsNullOrWhiteSpace($groupDisplayName)) {
            Write-Warning "Could not resolve Entra group ObjectId $EntraGroupObjectId."
          }
          else {
            $escapedName = $groupDisplayName.Replace("'", "''")
            $aadDsGroup = Get-ADGroup -Filter "Name -eq '$escapedName'" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($aadDsGroup) {
              $entraGroupSid = $aadDsGroup.SID.Value
            }
            else {
              Write-Warning "Could not find synced AADDS group named '$groupDisplayName' in AD DS. Ensure group sync is complete."
            }
          }
        }
      } elseif ($effectiveIdentityMode -eq 'AADKERB') {
        $entraGroupSid = $null # Not directly resolvable; user may need to set manually
        Write-Warning "For AADKERB, ensure NTFS permissions are set for the correct Entra group. Manual verification may be required."
      }
      if ($entraGroupSid) {
        $key = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccountName)[0].Value
        $unc = "\\$StorageAccountName.file.core.windows.net\$FileShareName"
        $drv = '{0}:' -f $DriveLetter
        Write-Verbose "Mapping $drv to $unc"
        cmd.exe /c "net use $drv $unc $key /user:Azure\$StorageAccountName" | Out-Null
        if (-not (Test-Path $drv)) {
          throw "Drive mapping failed for $drv ($unc). Cannot apply NTFS ACLs."
        }
        icacls $drv /grant "$entraGroupSid`:(M)" | Out-Null
        icacls $drv /grant 'Creator Owner:(OI)(CI)(IO)(M)' | Out-Null
        icacls $drv /remove 'Authenticated Users' | Out-Null
        icacls $drv /remove 'Builtin\Users' | Out-Null
        Write-Verbose 'Disconnecting mapped drive...'
        cmd.exe /c "net use $drv /delete /y" | Out-Null
      } else {
        Write-Warning "NTFS ACLs not set for Entra group. Please verify group sync and set permissions manually if needed."
      }
    } catch {
      Write-Warning "Error applying NTFS ACLs for identity mode '$effectiveIdentityMode': $($_.Exception.Message)"
    }
  }
  else {
    Write-Warning "NTFS ACL step is only required for AD DS, AADDS, or AADKERB. Skipping ACL configuration for identity mode '$effectiveIdentityMode'."
  }
  Set-FSLogixConfiguration
  Test-ProfileShareAccess

  if ($RunDebugAuth) {
    if ($effectiveIdentityMode -eq 'AD') {
      Invoke-DebugAuthCheck
    }
    else {
      Write-Warning "RunDebugAuth currently validates AD DS scenario. Skipping for identity mode '$effectiveIdentityMode'."
    }
  }

  if ($RestartHost) {
    Write-Verbose 'Restarting host...'
    Restart-Computer -Force
  }

  Write-Host 'Done. Next: sign in as a test user and confirm FSLogix VHD(X) creation on the share.'
} catch {
  Write-Error "Script failed: $($_.Exception.Message)"
  Write-Host 'For troubleshooting, review the error above and check permissions, network connectivity, and Azure/AD DS configuration.' -ForegroundColor Yellow
  exit 1
}
