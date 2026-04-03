###################################################################################################
#region Get-AvdWebClientAuthDiagnosis Function and Helpers

<#
.SYNOPSIS
Diagnoses AVD Web Client authentication/SSO issues from log files.

.DESCRIPTION
Parses AVD Web Client logs to detect SSO/authentication failure patterns, outputs structured diagnosis, and provides actionable recommendations. Efficiently processes large logs. Supports exporting results to JSON/CSV.

.PARAMETER LogPath
Path to the log file to analyze.

.PARAMETER RawText
Raw log text (optional, overrides LogPath if provided).

.EXAMPLE
Get-AvdWebClientAuthDiagnosis -LogPath 'C:\Logs\WebClient.log' | ConvertTo-Json -Depth 4

.EXAMPLE
Get-AvdWebClientAuthDiagnosis -LogPath 'C:\Logs\WebClient.log' | Export-Csv -Path diagnosis.csv -NoTypeInformation
#>
function Get-AvdWebClientAuthDiagnosis {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, Position=0)]
    [string]$LogPath,
    [string]$RawText
  )

  # Helper: Stream log lines efficiently
  function Get-LogLines {
    param([string]$Path, [string]$Text)
    if ($Text) {
      return $Text -split "`r?`n"
    } elseif (Test-Path $Path) {
      return [System.IO.File]::ReadLines($Path)
    } else {
      throw "Log file not found: $Path"
    }
  }

  # Helper: Extract metadata (UserName, ClientVersion, etc.)
  function Get-ClientMetadataFromLog {
    param([string[]]$Lines)
    $meta = @{}
    $meta.UserName = ($Lines | Select-String -Pattern 'UserName"?"?\s*[:=]\s*"([^"]+)"' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1)
    $meta.ClientVersion = ($Lines | Select-String -Pattern 'ClientVersion"?"?\s*[:=]\s*"([^"]+)"' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1)
    $meta.ClientOS = ($Lines | Select-String -Pattern 'ClientOS"?"?\s*[:=]\s*"([^"]+)"' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1)
    $meta.PlatformName = ($Lines | Select-String -Pattern 'PlatformName"?"?\s*[:=]\s*"([^"]+)"' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1)
    return $meta
  }

  # Helper: Find log evidence lines for a pattern
  function Find-LogEvidence {
    param([string[]]$Lines, [string[]]$Patterns)
    $evidence = @()
    foreach ($pat in $Patterns) {
      $evidence += $Lines | Select-String -Pattern $pat | ForEach-Object { $_.Line }
    }
    return $evidence | Select-Object -Unique
  }

  $lines = Get-LogLines -Path $LogPath -Text $RawText
  $linesArr = @($lines) # ensure array for multiple passes

  # Patterns
  $feedDiscoveryPattern = 'feeddiscovery.*StatusCode:200'
  $rdpFilePattern = 'RDP\.File\.URL.*StatusCode:200'
  $claimsTokenPattern = 'Claims token requested|Fetching claims token'
  $passwordFallbackPattern = 'Connect using Username and Password'
  $disconnectReasonPattern = 'Disconnect(ed)?: reason = 43|DisconnectReason.*Code: 43'
  $singleAccountPattern = '\[Auth\] Single account found'
  $endpointIdWarnPattern = 'EndpointId undefined not found in URL parameters'

  # Evidence
  $feedDiscoveryEvidence = Find-LogEvidence $linesArr @($feedDiscoveryPattern)
  $rdpFileEvidence = Find-LogEvidence $linesArr @($rdpFilePattern)
  $claimsTokenEvidence = Find-LogEvidence $linesArr @($claimsTokenPattern)
  $passwordFallbackEvidence = Find-LogEvidence $linesArr @($passwordFallbackPattern)
  $disconnectReasonEvidence = Find-LogEvidence $linesArr @($disconnectReasonPattern)
  $singleAccountEvidence = Find-LogEvidence $linesArr @($singleAccountPattern)
  $endpointIdWarnEvidence = Find-LogEvidence $linesArr @($endpointIdWarnPattern)

  # Metadata
  $meta = Get-ClientMetadataFromLog $linesArr

  # SSO Failure Pattern Detection
  $claimsIdx = ($linesArr | Select-String -Pattern $claimsTokenPattern | Select-Object -First 1).LineNumber
  $fallbackIdx = ($linesArr | Select-String -Pattern $passwordFallbackPattern | Select-Object -First 1).LineNumber
  $disconnectIdx = ($linesArr | Select-String -Pattern $disconnectReasonPattern | Select-Object -First 1).LineNumber
  $isSsoFailure = $false
  if ($claimsIdx -and $fallbackIdx -and $disconnectIdx) {
    # Require fallback and disconnect to be within 20 lines after claims
    if (($fallbackIdx - $claimsIdx -le 20) -and ($disconnectIdx - $fallbackIdx -le 20)) {
      $isSsoFailure = $true
    }
  }

  # Diagnosis summary and recommendations
  $diagnosisSummary = if ($isSsoFailure) {
    'SSO/claims handoff failure detected (Entra ID to session host)'
  } elseif ($feedDiscoveryEvidence -and $rdpFileEvidence) {
    'AVD authentication and resource discovery succeeded.'
  } else {
    'No SSO failure pattern detected; check for other issues.'
  }

  $likelyRootCause = if ($isSsoFailure) {
    'The AVD Web Client attempted SSO using Entra ID claims, but the session host did not accept the token, resulting in fallback to username/password and immediate disconnect (code 43). This suggests a misconfiguration in session host SSO or identity integration.'
  } else {
    $null
  }

  $recommendedFixes = if ($isSsoFailure) {
    @(
      'Verify session host is correctly configured to accept Entra ID SSO / token-based auth for AVD.'
      'Confirm required Entra authentication settings for the AVD client/service principals used by AVD login.'
      'Validate host pool RDP properties related to SSO / authentication are consistent with identity model.'
      'Check Conditional Access / MFA prompts interfering with token-based sign-in.'
      'Validate session host join state (Entra ID joined vs hybrid vs Entra ID Kerberos) matches the AVD identity configuration.'
    )
  } else {
    @()
  }

  # Compose evidence
  $evidence = @()
  $evidence += $claimsTokenEvidence
  $evidence += $passwordFallbackEvidence
  $evidence += $disconnectReasonEvidence
  $evidence = $evidence | Select-Object -Unique

  # Output object
  [PSCustomObject]@{
    UserName = $meta.UserName
    ClientVersion = $meta.ClientVersion
    ClientOS = $meta.ClientOS
    PlatformName = $meta.PlatformName
    HasFeedDiscoverySuccess = [bool]$feedDiscoveryEvidence
    HasRdpFileSuccess = [bool]$rdpFileEvidence
    ClaimsTokenRequestedCount = ($claimsTokenEvidence | Measure-Object).Count
    HasPasswordFallback = [bool]$passwordFallbackEvidence
    DisconnectReasonCode = if ($disconnectReasonEvidence) { 43 } else { $null }
    IsSsoFailurePattern = $isSsoFailure
    DiagnosisSummary = $diagnosisSummary
    LikelyRootCause = $likelyRootCause
    RecommendedFixes = $recommendedFixes
    Evidence = $evidence
    EndpointIdWarn = if ($endpointIdWarnEvidence) { $true } else { $false }
    EndpointIdWarnEvidence = $endpointIdWarnEvidence
  }
}

#endregion

# Example usage:
# $result = Get-AvdWebClientAuthDiagnosis -LogPath 'C:\Logs\WebClient.log'
# $result | ConvertTo-Json -Depth 4
# $result | Export-Csv -Path diagnosis.csv -NoTypeInformation

# Detection logic mapping:
# - Looks for claims token request, password fallback, and disconnect 43 in sequence (within 20 lines) for SSO failure.
# - Reports feed discovery and RDP file success for successful auth.
# - Outputs all evidence lines for transparency.
# - Warns if EndpointId is missing (optional).

<#
.SYNOPSIS
  AVD SSO validator and automated fixer for "Logon attempt failed (0x0/0x0)" errors.

.DESCRIPTION
  Validates and (with -Fix) automatically remediates the most common causes of AVD SSO failures:
  - HostPool CustomRdpProperty: targetisaadjoined:i:1 and enablerdsaadauth:i:1  ← root cause
  - Session host health / host pool association
  - AADLoginForWindows extension presence/state on VM
  - RBAC checks for current user: Virtual Machine User Login / Virtual Machine Administrator Login
  - Microsoft Graph: isRemoteDesktopProtocolEnabled on both required enterprise apps

  Run without -Fix to diagnose only. Add -Fix to automatically remediate every FAIL found.

.PARAMETER Fix
  When specified, automatically remediates every detected issue instead of only reporting it.
  Applies missing RDP properties to the host pool and enables isRemoteDesktopProtocolEnabled
  on the required enterprise apps in Entra ID.

.EXAMPLE
  # Diagnose only – script always prompts for fresh login then presents menus for subscription,
  # host pool, and session host selection.
  .\42_AVD_Fix_SSO.ps1

.EXAMPLE
  # Diagnose AND fix all issues automatically
  .\31_AVD_Fix_SSO.ps1 -Fix
#>



function Write-Result {
  param(
    [string]$Check,
    [ValidateSet("PASS","WARN","FAIL","INFO")] [string]$Status,
    [string]$Details
  )
  $color = switch ($Status) {
    "PASS" { "Green" }
    "WARN" { "Yellow" }
    "FAIL" { "Red" }
    default { "Cyan" }
  }
  Write-Host ("[{0}] {1} - {2}" -f $Status, $Check, $Details) -ForegroundColor $color
}

function Ensure-Module {
  param([string]$Name)

  # Download to temp only if not already saved there during this run
  $tempModDir = Join-Path $script:TempModulePath $Name
  if (-not (Test-Path $tempModDir)) {
    try {
      Write-Result "Module" "INFO" "Downloading $Name..."
      # Save into an isolated staging dir so Save-Module can write its dependencies freely
      # without colliding with modules already present (and file-locked) in the main temp path.
      $stageDir = Join-Path $env:TEMP ("AVDStage_$Name`_" + [System.Guid]::NewGuid().ToString('N'))
      $null = New-Item -ItemType Directory -Path $stageDir -Force
      Save-Module -Name $Name -Path $stageDir -Force -ErrorAction Stop
      # Copy only the target module folder to the shared temp path; skip any dependency
      # folders that were staged but are already present in temp.
      Get-ChildItem -Directory -Path $stageDir | ForEach-Object {
        $dest = Join-Path $script:TempModulePath $_.Name
        if (-not (Test-Path $dest)) {
          Copy-Item -Path $_.FullName -Destination $dest -Recurse -Force
        }
      }
      Remove-Item -Path $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
      Write-Result "Module" "FAIL" "Failed to download $Name. $_"
      throw
    }
  }

  # Import by explicit full path – bypasses PSModulePath resolution entirely
  try {
    $psd1 = Get-ChildItem -Path $tempModDir -Filter "$Name.psd1" -Recurse -ErrorAction Stop |
              Sort-Object { $_.DirectoryName } -Descending | Select-Object -First 1
    if (-not $psd1) { throw "$Name.psd1 not found under $tempModDir" }
    Import-Module $psd1.FullName -ErrorAction Stop | Out-Null
    Write-Result "Module" "INFO" "$Name loaded from temp"
  } catch {
    Write-Result "Module" "FAIL" "Failed to import $Name. $_"
    throw
  }
}

# ── Self-relaunch in a clean child process ─────────────────────────────────────────
# If we are NOT already running inside a clean child process, re-launch this script
# via a fresh pwsh with no profile and OneDrive/Documents stripped from PSModulePath.
# This guarantees no broken or OneDrive-based modules are loaded or referenced.
if (-not $env:AVD_FIX_SSO_CLEAN) {
  # Strip OneDrive/Documents from PSModulePath in the environment BEFORE spawning the child.
  # Child processes inherit environment variables, so the clean path is in effect from the
  # very first line of the child – no modules from OneDrive can be loaded or referenced.
  $env:PSModulePath = ($env:PSModulePath -split [System.IO.Path]::PathSeparator |
    Where-Object {
      $_ -notlike '*OneDrive*'     -and
      $_ -notlike '*\Documents\*'  -and
      $_ -notlike '*\My Documents\*'
    }) -join [System.IO.Path]::PathSeparator

  $env:AVD_FIX_SSO_CLEAN = '1'
  $passArgs = if ($Fix) { @('-Fix') } else { @() }
  & pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File $PSCommandPath @passArgs
  exit $LASTEXITCODE
}

# ── Bootstrap (running inside clean child process) ────────────────────────────
$ErrorActionPreference = 'Stop'

# Create a session-only temp folder under %TEMP% for module downloads.
$script:TempModulePath = Join-Path $env:TEMP ("AVDFixSSO_" + [System.Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $script:TempModulePath -Force -ErrorAction Stop

# PowerShell 7 unconditionally appends $HOME\Documents\PowerShell\Modules to PSModulePath
# at process startup, even when that path is not in the inherited environment. On machines
# where Documents is redirected to OneDrive this re-adds the broken path. Strip it now
# (same filter as the parent) so no OneDrive path survives into module resolution.
$env:PSModulePath = ($env:PSModulePath -split [System.IO.Path]::PathSeparator |
  Where-Object {
    $_ -notlike '*OneDrive*'     -and
    $_ -notlike '*\Documents\*'  -and
    $_ -notlike '*\My Documents\*'
  }) -join [System.IO.Path]::PathSeparator

# Prepend temp path – all Az/Graph modules will be downloaded and resolved from here.
$env:PSModulePath = $script:TempModulePath + [System.IO.Path]::PathSeparator + $env:PSModulePath

$mode = if ($Fix) { 'VALIDATE + FIX' } else { 'VALIDATE ONLY  (add -Fix to auto-remediate)' }
Write-Host "`n=== AVD SSO Validator & Fixer  |  Mode: $mode ===" -ForegroundColor Cyan

$requiredAzModules = @('Az.Accounts','Az.Compute','Az.Resources','Az.DesktopVirtualization')
foreach ($m in $requiredAzModules) { Ensure-Module -Name $m }

# ── Fresh login – no cached credentials ───────────────────────────────────────
Write-Host "`n-- Authentication --" -ForegroundColor Cyan
Write-Result "Auth" "INFO" "Clearing existing Azure session and prompting for fresh login..."
Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
Clear-AzContext -Force -ErrorAction SilentlyContinue | Out-Null
try {
  Connect-AzAccount -ErrorAction Stop | Out-Null
  Write-Result "Auth" "PASS" "Signed in successfully"
} catch {
  Write-Result "Auth" "FAIL" "Login failed. $_"
  exit 1
}

# ── Pick subscription ──────────────────────────────────────────────────────────
Write-Host "`n-- Subscription --" -ForegroundColor Cyan
try {
  $subs = Get-AzSubscription -ErrorAction Stop | Where-Object State -eq 'Enabled' | Sort-Object Name
  if (-not $subs) {
    Write-Result "Subscription" "FAIL" "No enabled subscriptions found for this account."
    exit 1
  }
  if ($subs.Count -eq 1) {
    $selectedSub = $subs[0]
    Write-Result "Subscription" "INFO" "One subscription available – auto-selected: $($selectedSub.Name)"
  } else {
    Write-Host ""
    $i = 1
    foreach ($s in $subs) {
      Write-Host ("  {0,2}. {1}  [{2}]" -f $i, $s.Name, $s.Id)
      $i++
    }
    Write-Host ""
    do { $choice = Read-Host "Select subscription number (1-$($subs.Count))" }
    until ([int]::TryParse($choice,[ref]$null) -and [int]$choice -ge 1 -and [int]$choice -le $subs.Count)
    $selectedSub = $subs[[int]$choice - 1]
  }
  Set-AzContext -SubscriptionId $selectedSub.Id -ErrorAction Stop | Out-Null
  $SubscriptionId = $selectedSub.Id
  Write-Result "Subscription" "PASS" "$($selectedSub.Name)  [$SubscriptionId]"
} catch {
  Write-Result "Subscription" "FAIL" "Could not retrieve subscriptions. $_"
  exit 1
}

# ── Scan and pick host pool ────────────────────────────────────────────────────
Write-Host "`n-- Host Pool Selection --" -ForegroundColor Cyan
try {
  Write-Result "Scan" "INFO" "Enumerating AVD host pools in subscription..."
  $hpResources = Get-AzResource -ResourceType 'Microsoft.DesktopVirtualization/hostPools' `
                   -ErrorAction Stop | Sort-Object ResourceGroupName, Name
  if (-not $hpResources) {
    Write-Result "Scan" "FAIL" "No AVD host pools found in this subscription."
    exit 1
  }
  Write-Host ""
  $i = 1
  foreach ($r in $hpResources) {
    Write-Host ("  {0,2}. {1}  (RG: {2})" -f $i, $r.Name, $r.ResourceGroupName)
    $i++
  }
  Write-Host ""
  do { $choice = Read-Host "Select host pool number (1-$($hpResources.Count))" }
  until ([int]::TryParse($choice,[ref]$null) -and [int]$choice -ge 1 -and [int]$choice -le $hpResources.Count)
  $selectedHpRes    = $hpResources[[int]$choice - 1]
  $HostPoolName     = $selectedHpRes.Name
  $ResourceGroupName = $selectedHpRes.ResourceGroupName
  Write-Result "Host Pool" "PASS" "$HostPoolName  (RG: $ResourceGroupName)"
} catch {
  Write-Result "Host Pool" "FAIL" "Could not enumerate host pools. $_"
  exit 1
}

# ── Scan and pick session host ─────────────────────────────────────────────────
Write-Host "`n-- Session Host Selection --" -ForegroundColor Cyan
try {
  Write-Result "Scan" "INFO" "Enumerating session hosts in '$HostPoolName'..."
  $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName `
                    -HostPoolName $HostPoolName -ErrorAction Stop | Sort-Object Name
  if (-not $sessionHosts) {
    Write-Result "Scan" "FAIL" "No session hosts found in host pool '$HostPoolName'."
    exit 1
  }
  Write-Host ""
  $i = 1
  foreach ($sh in $sessionHosts) {
    $shDisplay = ($sh.Name -split '/')[1]
    Write-Host ("  {0,2}. {1}  [Status: {2} | AllowNewSession: {3}]" -f $i, $shDisplay, $sh.Status, $sh.AllowNewSession)
    $i++
  }
  Write-Host ""
  do { $choice = Read-Host "Select session host number (1-$($sessionHosts.Count))" }
  until ([int]::TryParse($choice,[ref]$null) -and [int]$choice -ge 1 -and [int]$choice -le $sessionHosts.Count)
  $selectedSh      = $sessionHosts[[int]$choice - 1]
  # Name format is "hostpoolname/vmfqdn" – extract the short VM hostname
  $SessionHostName = (($selectedSh.Name -split '/')[1] -split '\.')[0]
  Write-Result "Session Host" "PASS" "$SessionHostName  (AVD object: $(($selectedSh.Name -split '/')[1]))"
} catch {
  Write-Result "Session Host" "FAIL" "Could not enumerate session hosts. $_"
  exit 1
}



# ── Resolve VM resource group with robust matching ─────────────────────────────
Write-Host "`n-- Resolving VM --" -ForegroundColor Cyan
$vmNameGuess = $SessionHostName
# Try to extract short name if FQDN
if ($vmNameGuess -match '^[^\.]+') { $vmNameGuess = $Matches[0] }
$vmResource = $null
try {
  # Try exact match in host pool RG
  $vmResource = Get-AzResource -ResourceType 'Microsoft.Compute/virtualMachines' -ResourceGroupName $ResourceGroupName -Name $vmNameGuess -ErrorAction SilentlyContinue
  if (-not $vmResource) {
    # Try all VMs in RG, match by prefix (for FQDNs or registration mismatches)
    $allVMs = Get-AzResource -ResourceType 'Microsoft.Compute/virtualMachines' -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($allVMs) {
      $vmResource = $allVMs | Where-Object { $_.Name -eq $SessionHostName -or $SessionHostName -like ("$($_.Name)*") -or $vmNameGuess -eq $_.Name }
      if (-not $vmResource) {
        # Try partial match (prefix)
        $vmResource = $allVMs | Where-Object { $SessionHostName -like ("$($_.Name)*") -or $_.Name -like ("$vmNameGuess*") }
      }
    }
  }
  if (-not $vmResource) {
    # Try all VMs in subscription (slow fallback)
    $allVMs = Get-AzResource -ResourceType 'Microsoft.Compute/virtualMachines' -ErrorAction SilentlyContinue
    if ($allVMs) {
      $vmResource = $allVMs | Where-Object { $_.Name -eq $SessionHostName -or $_.Name -eq $vmNameGuess }
      if (-not $vmResource) {
        $vmResource = $allVMs | Where-Object { $SessionHostName -like ("$($_.Name)*") -or $_.Name -like ("$vmNameGuess*") }
      }
    }
  }
  if ($vmResource) {
    $VmResourceGroupName = $vmResource.ResourceGroupName
    Write-Result "VM Lookup" "PASS" "$($vmResource.Name)  (RG: $VmResourceGroupName)"
  } else {
    # Prompt user to pick from available VMs in RG
    $allVMs = Get-AzResource -ResourceType 'Microsoft.Compute/virtualMachines' -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($allVMs -and $allVMs.Count -gt 0) {
      Write-Host "No VM found matching '$SessionHostName'. Select from available VMs in RG: $ResourceGroupName" -ForegroundColor Yellow
      $i = 1
      foreach ($vm in $allVMs) { Write-Host ("  {0,2}. {1}" -f $i, $vm.Name); $i++ }
      do { $choice = Read-Host "Select VM number (1-$($allVMs.Count)) or press Enter to skip" }
      until ($choice -eq '' -or ([int]::TryParse($choice,[ref]$null) -and [int]$choice -ge 1 -and [int]$choice -le $allVMs.Count))
      if ($choice -ne '') {
        $vmResource = $allVMs[[int]$choice - 1]
        $VmResourceGroupName = $vmResource.ResourceGroupName
        Write-Result "VM Lookup" "PASS" "$($vmResource.Name)  (RG: $VmResourceGroupName)"
      } else {
        Write-Result "VM Lookup" "WARN" "No VM selected. Defaulting to host pool RG '$ResourceGroupName'."
        $VmResourceGroupName = $ResourceGroupName
      }
    } else {
      Write-Result "VM Lookup" "WARN" "Could not auto-resolve VM RG; defaulting to host pool RG '$ResourceGroupName'. No VMs found in RG."
      $VmResourceGroupName = $ResourceGroupName
    }
  }
} catch {
  Write-Result "VM Lookup" "WARN" "Could not auto-resolve VM RG; defaulting to host pool RG '$ResourceGroupName'. $_"
  $VmResourceGroupName = $ResourceGroupName
}

# ── Detect session host identity provisioning type ─────────────────────────────
Write-Host "`n-- Detecting Session Host Identity Type --" -ForegroundColor Cyan
$identityType = $null
try {
  $vm = Get-AzVM -ResourceGroupName $VmResourceGroupName -Name $SessionHostName -ErrorAction Stop
  $osProfile = $vm.OsProfile
  $aadJoin = $false
  $domainJoin = $false
  $kerberosEnabled = $false
  $aadDsJoin = $false

  # Check for Entra ID join (Azure AD)
  if ($osProfile.WindowsConfiguration -and $osProfile.WindowsConfiguration.EnableAutomaticUpdates -ne $null) {
    # Use extension presence as a proxy for AAD join
    $aadExt = Get-AzVMExtension -ResourceGroupName $VmResourceGroupName -VMName $SessionHostName -Name 'AADLoginForWindows' -ErrorAction SilentlyContinue
    if ($aadExt) {
      $aadJoin = $true
    }
  }

  # Check for domain join
  if ($osProfile.WindowsConfiguration -and $osProfile.WindowsConfiguration.ProvisionVMAgent) {
    if ($osProfile.WindowsConfiguration.DomainJoin -and $osProfile.WindowsConfiguration.DomainJoin.Domain) {
      $domainJoin = $true
    }
  }

  # Check for Entra ID Kerberos (RDP property and/or extension)
  $hp = Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostPoolName -ErrorAction SilentlyContinue
  $rdpProps = $hp.CustomRdpProperty
  if ($rdpProps -match 'enablerdsaadkerberos:i:1') {
    $kerberosEnabled = $true
  }

  # Check for Azure AD DS (Entra DS) - heuristic: domain join to managed domain
  if ($domainJoin -and $osProfile.WindowsConfiguration.DomainJoin.Domain -like '*.onmicrosoft.com') {
    $aadDsJoin = $true
  }

  # Decide identity type
  if ($kerberosEnabled -and $aadJoin) {
    $identityType = 'EntraIDKerberos'
  } elseif ($aadJoin) {
    $identityType = 'EntraID'
  } elseif ($aadDsJoin) {
    $identityType = 'EntraDS'
  } elseif ($domainJoin) {
    $identityType = 'ADDS'
  } else {
    $identityType = 'Unknown'
  }
  Write-Result "Identity Type" "INFO" "Detected: $identityType"
} catch {
  Write-Result "Identity Type" "WARN" "Could not determine session host identity type. $_"
  $identityType = 'Unknown'
}

# ── Summary ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host ("-" * 60) -ForegroundColor DarkGray
Write-Host "  Session host : $SessionHostName"
Write-Host "  Host pool    : $HostPoolName  |  RG: $ResourceGroupName"
Write-Host "  VM RG        : $VmResourceGroupName"
Write-Host "  Subscription : $SubscriptionId"
Write-Host "  IdentityType : $identityType"
Write-Host ("-" * 60) -ForegroundColor DarkGray

# ── Branch SSO validation/remediation by identity type ─────────────────────────
switch ($identityType) {
  'ADDS' {
    Write-Host "`n-- SSO Validation: AD DS (classic domain join) --" -ForegroundColor Cyan
    # AD DS: No Entra SSO RDP properties, must be domain-joined, AADLoginForWindows not required
    if ($rdpProps -match 'targetisaadjoined:i:1|enablerdsaadauth:i:1|enablerdsaadkerberos:i:1') {
      Write-Result "RDP Properties" "FAIL" "Entra SSO RDP properties present but host is domain-joined. Remove for classic AD SSO."
      if ($Fix) {
        $corrected = $rdpProps -replace '(?i)targetisaadjoined:i:\d+;?', '' -replace '(?i)enablerdsaadauth:i:\d+;?', '' -replace '(?i)enablerdsaadkerberos:i:\d+;?', ''
        $corrected = $corrected.TrimEnd(';').Trim()
        Update-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostPoolName -CustomRdpProperty $corrected -ErrorAction Stop | Out-Null
        Write-Result "RDP Properties" "PASS" "Removed Entra SSO RDP properties for AD DS."
      }
    } else {
      Write-Result "RDP Properties" "PASS" "No Entra SSO RDP properties present (expected for AD DS)."
    }
    # AADLoginForWindows not required
    Write-Result "AADLoginForWindows" "INFO" "Not required for AD DS SSO."
  }
  'EntraDS' {
    Write-Host "`n-- SSO Validation: Entra DS (Azure AD DS) --" -ForegroundColor Cyan
    # Entra DS: Domain join to managed domain, may require specific RDP properties
    Write-Result "Entra DS" "INFO" "Ensure host is joined to Azure AD DS managed domain."
    # No special RDP properties required, but warn if Entra SSO properties are present
    if ($rdpProps -match 'targetisaadjoined:i:1|enablerdsaadauth:i:1|enablerdsaadkerberos:i:1') {
      Write-Result "RDP Properties" "WARN" "Entra SSO RDP properties present but host is Azure AD DS joined. Remove unless hybrid scenario."
    } else {
      Write-Result "RDP Properties" "PASS" "No Entra SSO RDP properties present (expected for Entra DS)."
    }
    Write-Result "AADLoginForWindows" "INFO" "Not required for Entra DS SSO."
  }
  'EntraID' {
    Write-Host "`n-- SSO Validation: Entra ID (Azure AD Join) --" -ForegroundColor Cyan
    # Entra ID: Must have both RDP properties, AADLoginForWindows not required
    $missing = @()
    if ($rdpProps -notmatch 'targetisaadjoined:i:1') { $missing += 'targetisaadjoined:i:1' }
    if ($rdpProps -notmatch 'enablerdsaadauth:i:1') { $missing += 'enablerdsaadauth:i:1' }
    if ($missing.Count -gt 0) {
      Write-Result "RDP Properties" "FAIL" ("Missing: " + ($missing -join ', '))
      if ($Fix) {
        $corrected = $rdpProps
        if (-not $corrected) { $corrected = '' }
        # Remove any existing (possibly wrong) values for these keys
        $corrected = $corrected -replace '(?i)targetisaadjoined:i:\d+;?', '' -replace '(?i)enablerdsaadauth:i:\d+;?', '' -replace '(?i)enablerdsaadkerberos:i:\d+;?', ''
        $corrected = $corrected.TrimEnd(';').Trim()
        if ($corrected) { $corrected += ';' }
        $corrected += 'targetisaadjoined:i:1;enablerdsaadauth:i:1;'
        Update-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostPoolName -CustomRdpProperty $corrected -ErrorAction Stop | Out-Null
        Write-Result "RDP Properties" "PASS" "CustomRdpProperty updated: $corrected"
      }
    } else {
      Write-Result "RDP Properties" "PASS" "All required Entra SSO RDP properties present."
    }
    Write-Result "AADLoginForWindows" "INFO" "Not required for Entra ID SSO."
    # Graph config and RBAC checks remain as in original script
  }
  'EntraIDKerberos' {
    Write-Host "`n-- SSO Validation: Entra ID Kerberos --" -ForegroundColor Cyan
    # Entra ID Kerberos: Must have all Entra ID props plus enablerdsaadkerberos:i:1
    $missing = @()
    if ($rdpProps -notmatch 'targetisaadjoined:i:1') { $missing += 'targetisaadjoined:i:1' }
    if ($rdpProps -notmatch 'enablerdsaadauth:i:1') { $missing += 'enablerdsaadauth:i:1' }
    if ($rdpProps -notmatch 'enablerdsaadkerberos:i:1') { $missing += 'enablerdsaadkerberos:i:1' }
    if ($missing.Count -gt 0) {
      Write-Result "RDP Properties" "FAIL" ("Missing: " + ($missing -join ', '))
      if ($Fix) {
        $corrected = $rdpProps
        if (-not $corrected) { $corrected = '' }
        # Remove any existing (possibly wrong) values for these keys
        $corrected = $corrected -replace '(?i)targetisaadjoined:i:\d+;?', '' -replace '(?i)enablerdsaadauth:i:\d+;?', '' -replace '(?i)enablerdsaadkerberos:i:\d+;?', ''
        $corrected = $corrected.TrimEnd(';').Trim()
        if ($corrected) { $corrected += ';' }
        $corrected += 'targetisaadjoined:i:1;enablerdsaadauth:i:1;enablerdsaadkerberos:i:1;'
        Update-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostPoolName -CustomRdpProperty $corrected -ErrorAction Stop | Out-Null
        Write-Result "RDP Properties" "PASS" "CustomRdpProperty updated: $corrected"
      }
    } else {
      Write-Result "RDP Properties" "PASS" "All required Entra ID Kerberos RDP properties present."
    }
    Write-Result "AADLoginForWindows" "INFO" "Not required for Entra ID Kerberos SSO."
    Write-Result "Kerberos" "INFO" "Ensure SPNs and ticketing are configured for Entra ID Kerberos."
  }
  default {
    Write-Result "Identity Type" "WARN" "Unknown or unsupported identity type. Manual validation required."
  }
}


# ── Check: Session host health ───────────────────────────────────────────────
Write-Host "`n-- Session host health --" -ForegroundColor Cyan
$hostStatus = $selectedSh.Status
$statusOk   = $hostStatus -eq 'Available'
Write-Result "Session Host Status" $(if ($statusOk) { "PASS" } else { "WARN" }) `
             "Status=$hostStatus | AllowNewSession=$($selectedSh.AllowNewSession)"

# ── Check: VM AADLoginForWindows extension ───────────────────────────────────
Write-Host "`n-- VM extension --" -ForegroundColor Cyan
try {
  # Use Get-AzVMExtension (reflects deployed state) rather than $vm.Extensions
  # (which only reflects the VM model and can miss extensions on Entra-joined hosts)
  $ext = Get-AzVMExtension -ResourceGroupName $VmResourceGroupName `
           -VMName $SessionHostName -Name 'AADLoginForWindows' -ErrorAction SilentlyContinue
  if ($ext) {
    $pState = $ext.ProvisioningState
    Write-Result "AADLoginForWindows" $(if ($pState -eq 'Succeeded') { "PASS" } else { "WARN" }) `
                 "ProvisioningState=$pState"
  } else {
    # For Entra-joined AVD hosts SSO is controlled by the host pool RDP properties
    # (enablerdsaadauth / targetisaadjoined), not by this extension. Its absence is
    # informational for Entra-joined pools but not a hard blocker for AVD SSO.
    Write-Result "AADLoginForWindows" "WARN" `
      "Extension not found on VM $SessionHostName. Not required for AVD SSO on Entra-joined hosts (SSO is controlled by host pool RDP properties). Required only for direct VM login via Entra credentials."
  }
} catch {
  Write-Result "AADLoginForWindows" "WARN" "Could not query VM extensions for '$SessionHostName'. $_"
}

# ── Check: RBAC – VM User Login / VM Admin Login ─────────────────────────────
Write-Host "`n-- RBAC (VM Login roles) --" -ForegroundColor Cyan
try {
  $vmScope     = "/subscriptions/$SubscriptionId/resourceGroups/$VmResourceGroupName/providers/Microsoft.Compute/virtualMachines/$SessionHostName"
  $assignments = Get-AzRoleAssignment -Scope $vmScope -ErrorAction Stop
  $loginRoles  = $assignments | Where-Object {
    $_.RoleDefinitionName -in @('Virtual Machine User Login','Virtual Machine Administrator Login')
  }
  if ($loginRoles) {
    foreach ($r in $loginRoles) {
      $principal = if ($r.SignInName) { $r.SignInName } else { $r.ObjectId }
      Write-Result "RBAC – VM Login" "PASS" ("Role '{0}' → '{1}'" -f $r.RoleDefinitionName, $principal)
    }
  } else {
    Write-Result "RBAC – VM Login" "WARN" ("No 'Virtual Machine User Login' / 'Virtual Machine Administrator Login' found at VM scope.`n" +
      "  Users may be unable to sign in via SSO.")
  }
} catch {
  Write-Result "RBAC – VM Login" "WARN" "Could not query RBAC at VM scope. Check permissions. $_"
}

# ── Check: Microsoft Graph – isRemoteDesktopProtocolEnabled ─────────────────
#   Per docs, BOTH service principals must have this flag = true for SSO to work.
#   Windows Cloud Login  : 270efc09-cd0d-444b-a71f-39af4910ec45
#   Microsoft Remote Desktop: a4a365df-50f1-4397-bc59-1a1564b8bb9c
Write-Host "`n-- Microsoft Graph: RDP authentication enabled on service principals --" -ForegroundColor Cyan
Write-Host "   (Will prompt for Entra credentials – requires Application.Read.All scope)" -ForegroundColor Yellow

try {
  Ensure-Module -Name 'Microsoft.Graph.Authentication'
  Ensure-Module -Name 'Microsoft.Graph.Applications'

  Connect-MgGraph -Scopes "Application.Read.All","Application-RemoteDesktopConfig.ReadWrite.All" -NoWelcome

  $appsToCheck = @(
    [PSCustomObject]@{ Name = 'Windows Cloud Login';       AppId = '270efc09-cd0d-444b-a71f-39af4910ec45' }
    [PSCustomObject]@{ Name = 'Microsoft Remote Desktop';  AppId = 'a4a365df-50f1-4397-bc59-1a1564b8bb9c' }
  )

  foreach ($app in $appsToCheck) {
    try {
      $sp = Get-MgServicePrincipal -Filter "AppId eq '$($app.AppId)'" -ErrorAction Stop
      if (-not $sp) {
        Write-Result "Graph – $($app.Name)" "WARN" "Service principal not found in tenant (AppId $($app.AppId))"
        continue
      }
      $rdsCfg = Get-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $sp.Id -ErrorAction Stop
      if ($rdsCfg.IsRemoteDesktopProtocolEnabled -eq $true) {
        Write-Result "Graph – $($app.Name)" "PASS" "isRemoteDesktopProtocolEnabled = true"
      } else {
        Write-Result "Graph – $($app.Name)" "FAIL" "isRemoteDesktopProtocolEnabled = false – SSO will not work until this is enabled"
        if ($Fix) {
          try {
            Update-MgServicePrincipalRemoteDesktopSecurityConfiguration `
              -ServicePrincipalId $sp.Id `
              -IsRemoteDesktopProtocolEnabled `
              -ErrorAction Stop | Out-Null
            Write-Result "Graph – $($app.Name) Fix" "PASS" "isRemoteDesktopProtocolEnabled set to true"
          } catch {
            Write-Result "Graph – $($app.Name) Fix" "FAIL" "Could not enable RDP config. Ensure you have an eligible admin role (Global Admin or Privileged Role Administrator). $_"
          }
        } else {
          Write-Result "Graph – $($app.Name)" "INFO" "Re-run with -Fix to automatically enable isRemoteDesktopProtocolEnabled"
        }
      }
    } catch {
      # Detect MSA (personal Microsoft account) limitation cleanly – the Graph
      # RemoteDesktopSecurityConfiguration API only works with Entra work/school accounts.
      if ($_ -match 'MSA' -or $_ -match 'addressUrl' -or $_ -match 'BadRequest') {
        Write-Result "Graph – $($app.Name)" "WARN" `
          "Skipped: signed-in account is a personal Microsoft account (MSA). This Graph API requires an Entra ID work/school account. Sign in with a work account to validate this check."
      } else {
        Write-Result "Graph – $($app.Name)" "WARN" "Could not query remote desktop config. $_"
      }
    }
  }

  Disconnect-MgGraph | Out-Null
} catch {
  Write-Result "Graph – Auth" "WARN" "Could not connect to Microsoft Graph. SSO service principal checks skipped.`n  $_"
}

if ($Fix) {
  Write-Host "`n=== Remediation complete – re-run without -Fix to confirm all checks now PASS ===`n" -ForegroundColor Green
} else {
  Write-Host "`n=== Validation complete – re-run with -Fix to automatically remediate any FAIL items ===`n" -ForegroundColor Cyan
}

# ── Cleanup: unload modules and delete session-only temp path ────────────────────
Write-Host "`n-- Cleanup --" -ForegroundColor DarkGray
$modulesToUnload = @(
  'Microsoft.Graph.Applications',
  'Microsoft.Graph.Authentication',
  'Az.DesktopVirtualization',
  'Az.Compute',
  'Az.Resources',
  'Az.Accounts'
)
foreach ($m in $modulesToUnload) {
  if (Get-Module -Name $m -ErrorAction SilentlyContinue) {
    Remove-Module -Name $m -Force -ErrorAction SilentlyContinue
    Write-Host ("  Unloaded: $m") -ForegroundColor DarkGray
  }
}
if (Test-Path $script:TempModulePath) {
  Remove-Item -Path $script:TempModulePath -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "  Temp module path removed." -ForegroundColor DarkGray
}
