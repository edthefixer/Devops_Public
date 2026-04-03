<#
.SYNOPSIS
    Enterprise-grade AVD RemoteApp Discovery and Publishing Tool with Security-First Design and 
    Tenant-Wide Duplicate Prevention for Production Azure Virtual Desktop Environments

.DESCRIPTION
    Production-hardened PowerShell automation tool for Azure Virtual Desktop (AVD) RemoteApp lifecycle 
     management. Delivers comprehensive application discovery, tenant-wide duplicate prevention,
     security-enforced authentication, intelligent publishing workflows, and convention-aware automatic
     resource naming for enterprise AVD deployments.
    
    SECURITY-FIRST DESIGN:
    - Forced Fresh Authentication: Automatically clears cached Azure sessions and enforces re-authentication
    - Multi-Method Authentication: Supports Interactive Browser and Device Code flows
    - Session Lifecycle Management: Secure cleanup with automatic disconnect after operations
    - Zero Session Reuse: Prevents credential staleness and ensures audit compliance
    
    TENANT-WIDE DUPLICATE PREVENTION:
    - Comprehensive RemoteApp Scanning: Discovers all published RemoteApps across entire Azure tenant
    - Intelligent Application Matching: Path-based and name-based comparison to identify duplicates
    - Smart Categorization: Classifies apps as New, Already Published, or Potential Updates
    - Efficient Selection Interface: Filters view to show only unpublished applications
    - Cross-Application-Group Analysis: Prevents publishing conflicts across multiple app groups
    
    PRODUCTION-GRADE ERROR HANDLING:
    - Comprehensive Input Validation: Validates all paths, names, and Azure resources
    - Text Encoding Cleanup: Handles international characters and removes encoding artifacts
    - Detailed Logging Framework: Color-coded status messages (INFO, WARN, ERROR, SUCCESS, DEBUG)
    - Graceful Failure Recovery: Continues publishing remaining apps when individual publishes fail
    - Comprehensive Exception Handling: Captures and reports Azure API and file system errors
    
    INTELLIGENT APPLICATION DISCOVERY:
    - Multi-Source Discovery: Scans Start Menu, Registry, Microsoft Store, and custom paths
    - Metadata Extraction: Retrieves version info, publisher, description from executables
    - AVD Compatibility Validation: Ensures applications meet RemoteApp technical requirements
    - Clean Naming Convention: Generates meaningful identifiers without timestamps
    - Command Line Support: Configures launch parameters for applications requiring arguments
    
    AZURE RESOURCE AUTOMATION:
    - Interactive Resource Selection: Lists existing Resource Groups, Application Groups, and Workspaces
    - Automated Resource Creation: Creates missing resources with validation and confirmation
    - Workspace Integration: Assigns Application Groups for immediate end-user availability
    - Bulk Publishing Engine: Processes multiple RemoteApps simultaneously with progress tracking
    - Resource Group Management: Handles cross-subscription resource targeting

        INTELLIGENT RESOURCE NAMING ENGINE:
        - Convention Detection: Analyses existing host pool, app group, and workspace names to detect
            your established naming convention (prefix-number or suffix-number style)
        - Consistent Name Suggestions: Proposes the next sequential name that matches your convention
            (e.g. raap-finance-01 → raap-finance-02; 02-raap-finance → 03-raap-finance)
        - Canonical Base Extraction: Derives the workload core from any combination of existing resources
        - Fully Automated: No manual naming required when creating new Application Groups, Workspaces,
            or Host Pools during an interactive session

.PARAMETER ResourceGroupName
    Optional. Specifies the Azure Resource Group containing AVD resources. When omitted, displays 
    interactive selection menu with all available resource groups and option to create new.
    
.PARAMETER ApplicationGroupName
    Optional. Specifies the target RemoteApp Application Group. When omitted, displays interactive 
    selection menu filtered to RemoteApp-type application groups with option to create new.
    
.EXAMPLE
    .\40_AVD_Execute_AppDiscoveryAndRemoteAppPublishing.ps1
    
    Fully interactive mode - recommended for first-time users:
    1. Enforces fresh Azure authentication with method selection
    2. Discovers all installed applications on local system
    3. Scans tenant for existing RemoteApps to prevent duplicates
    4. Displays color-coded categorization (New/Published/Updates)
    5. Allows filtering to show only unpublished applications
    6. Guides through Azure resource selection (Resource Group, App Group, Workspace)
    7. Configures command line arguments for selected applications
    8. Publishes RemoteApps with comprehensive error handling
    9. Securely disconnects Azure session

.EXAMPLE
    .\40_AVD_Execute_AppDiscoveryAndRemoteAppPublishing.ps1 -ResourceGroupName "rg-avd-prod-eastus" -ApplicationGroupName "ag-remoteapps-finance"

    Targeted deployment mode - ideal for scripted/automated workflows:
    - Authenticates to specified Azure tenant with fresh credentials
    - Targets specific Resource Group and Application Group
    - Performs full application discovery and tenant comparison
    - Still provides interactive selection of applications to publish
    - Reduces prompts by pre-specifying Azure resources
    - Suitable for department-specific or environment-specific deployments

.EXAMPLE
    .\40_AVD_Execute_AppDiscoveryAndRemoteAppPublishing.ps1 -ResourceGroupName "rg-avd-shared"

    Partial targeting - specify Resource Group, choose Application Group interactively:
    - Pre-targets Resource Group while keeping Application Group selection interactive
    - Useful when multiple Application Groups exist in same Resource Group
    - Allows selection of appropriate App Group based on discovered applications

.NOTES
     HOW TO RUN:
     1. Open an elevated PowerShell session (Run as Administrator) on the AVD session host.
         Administrative rights are required for complete Start Menu and registry app discovery.

     2. Set execution policy if needed:
         Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process

     3. Run in fully interactive mode (recommended for first use):
         .\40_AVD_Execute_AppDiscoveryAndRemoteAppPublishing.ps1

     4. Or target a specific Resource Group and Application Group directly:
         .\40_AVD_Execute_AppDiscoveryAndRemoteAppPublishing.ps1 `
              -ResourceGroupName "rg-avd-prod-eastus" `
              -ApplicationGroupName "ag-remoteapps-finance"

     5. Authentication prompt: choose [1] Interactive Browser (default) or [2] Device Code.
         The script always clears any cached Azure session and forces fresh authentication.

     MODULE BOOTSTRAP (no pre-installation required):
     The script self-manages all required modules at startup:
     - Strips OneDrive and stale paths from PSModulePath automatically.
     - On first run, downloads Az.Accounts, Az.DesktopVirtualization, and Az.Resources
        from PSGallery into %TEMP%\AVDRemoteApp_mods (one-time, ~30-60 seconds).
     - On subsequent runs, the cached modules are reused — startup is fast.
     - If a _psmodules folder is found up to 4 levels above the script, it is also
        prepended to PSModulePath and preferred over the temp cache.
     - No manual Install-Module step is needed.

     PREREQUISITES:
     - Azure Permissions (minimum):
        * Desktop Virtualization Application Group Contributor (on target Application Group)
        * Reader (on Subscription for resource discovery)
    
    - Azure Virtual Desktop Environment:
        * Deployed AVD Host Pool with active session hosts
        * Applications must be installed on ALL session hosts
        * RemoteApp-type Application Group (not Desktop)
    
    - PowerShell Environment:
        * PowerShell 5.1 or PowerShell 7+ (recommended)
        * Execution policy allowing script execution
        * Administrative rights on local machine for full application discovery
    
    TROUBLESHOOTING:
    - Authentication Issues:
        * Clear browser cache if Interactive Browser auth fails
        * Use Device Code method for restricted network environments
        * Verify Azure AD permissions allow authentication
    
    - Application Discovery Issues:
        * Run as Administrator for complete system application discovery
        * Check Start Menu shortcuts have valid target paths
        * Verify applications are properly installed (not portable)
    
    - Publishing Failures:
        * Confirm application exists on all session hosts at identical paths
        * Validate Azure RBAC permissions on Application Group
        * Check Application Group type is RemoteApp (not Desktop)
        * Ensure application paths are accessible on session hosts
    
    - Duplicate Detection Issues:
        * Script matches by exact path and display name
        * Different versions of same app may be categorized as updates
        * Review "Potential Updates" category carefully before publishing
    
    OUTPUT ARTIFACTS:
    - Published RemoteApp Applications: Added to specified Application Group
    - Application Group Assignment: Linked to selected Workspace for user access
    - Execution Logs: Detailed console output with color-coded status indicators
    - Application Metadata: Clean identifiers, descriptions, and command line arguments
    
    VERSION INFORMATION:
    Author: AVD Automation Team
        Version: 4.1 Enterprise Production Release
        Last Modified: March 30, 2026

        CHANGELOG (v4.1 - March 26, 2026):
        - ADDED: Intelligent resource naming engine (12 new helper functions):
            Get-NameSequenceMetadata, Get-SequentialNamingStyle, Get-NextSequenceText,
            Get-RgBaseName, Get-ResourceObjectPropertyValue, Get-ResourceNameFromObject,
            Get-ApplicationGroupTypeFromObject, ConvertTo-NamingSlug,
            Get-CanonicalWorkloadBaseName, Get-NextRemoteAppApplicationGroupName,
            Get-NextWorkspaceName, Get-NextHostPoolName
        - ADDED: Convention-aware name suggestion when creating new App Groups, Workspaces,
            and Host Pools — detects prefix vs. suffix numbering style automatically
        - IMPROVED: Module bootstrap rewritten as a 6-step self-contained block; no manual
            pre-installation required; OneDrive paths stripped automatically every run
        - IMPROVED: Azure resource object access hardened via Get-ResourceObjectPropertyValue
            and Get-ResourceNameFromObject to handle both hashtable and PSObject return types
            across different Az.DesktopVirtualization module versions
        - FIXED: Name suggestion logic replaced hardcoded patterns with convention-aware
            functions that adapt to existing resource naming in the target Resource Group
    
    BEST PRACTICES:
    - Always run from session host to ensure accurate application discovery
    - Test with small application sets before bulk publishing
    - Verify applications are installed on all session hosts
    - Use meaningful Resource Group and Application Group names
    - Document command line arguments for complex applications
    - Review tenant comparison results before publishing
    - Maintain consistent application versions across session hosts
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $false)]
    [string]$ApplicationGroupName
)

#region --- MODULE BOOTSTRAP (runs before any function is called) ---
# OneDrive paths are always stripped per security policy.
# Modules are loaded fresh every run and unloaded in Disconnect-AzureSession.

$_requiredModules = @('Az.Accounts', 'Az.DesktopVirtualization', 'Az.Resources')

# Track what THIS script loads so cleanup can unload exactly those.
$script:_bootstrapLoadedModules = [System.Collections.Generic.List[string]]::new()

# STEP 1: Force-remove required modules currently in this session.
# This kills stale in-memory references (e.g. loaded from a deleted folder in a prior run)
# which would otherwise cause dependency resolution to follow broken paths.
foreach ($_mod in $_requiredModules) {
    Remove-Module -Name $_mod -Force -ErrorAction SilentlyContinue
}

# STEP 2: Delete stale on-disk caches written by previous versions of this script.
foreach ($_stale in @(
    (Join-Path $env:LOCALAPPDATA 'AVDRemoteAppPublisher\_modules'),
    (Join-Path $env:USERPROFILE  '.avd-remoteapp-publisher\_modules'),
    (Join-Path $env:TEMP         'AVDRemoteApp_psmodules')
)) {
    if ($_stale -and (Test-Path -LiteralPath $_stale -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $_stale -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[MODULE] Removed stale cache: $_stale" -ForegroundColor DarkYellow
    }
}

# STEP 3: Build a clean PSModulePath — strip OneDrive and any AVDRemoteApp entries.
$env:PSModulePath = (
    $env:PSModulePath -split ';' | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        $_ -notmatch 'OneDrive' -and
        $_ -notmatch 'AVDRemoteApp'
    }
) -join ';'

# STEP 4: Set up the persistent module cache folder and add it to PSModulePath NOW
# so Get-Module -ListAvailable picks up previously downloaded modules.
$_dlPath = Join-Path $env:TEMP 'AVDRemoteApp_mods'
if (-not (Test-Path -LiteralPath $_dlPath)) {
    New-Item -Path $_dlPath -ItemType Directory -Force | Out-Null
}
$env:PSModulePath = $_dlPath + ';' + $env:PSModulePath

# Optionally also prepend _psmodules if found in a repo tree above this script.
$_searchDir = $PSScriptRoot
for ($i = 0; $i -lt 4; $i++) {
    if ([string]::IsNullOrWhiteSpace($_searchDir)) { break }
    $_psm = Join-Path $_searchDir '_psmodules'
    if (Test-Path -LiteralPath $_psm) {
        $env:PSModulePath = (Resolve-Path -LiteralPath $_psm).Path + ';' + $env:PSModulePath
        Write-Host "[MODULE] Repo _psmodules: $_psm" -ForegroundColor Cyan
        break
    }
    $_p = Split-Path $_searchDir -Parent
    if ([string]::IsNullOrWhiteSpace($_p) -or $_p -eq $_searchDir) { break }
    $_searchDir = $_p
}

# STEP 5: Download any modules not found in the cache (runs once; skipped on repeat runs).
foreach ($_m in $_requiredModules) {
    if (Get-Module -ListAvailable -Name $_m -ErrorAction SilentlyContinue) { continue }
    Write-Host "[MODULE] '$_m' not cached — downloading to '$_dlPath'..." -ForegroundColor Yellow
    try {
        Save-Module -Name $_m -Path $_dlPath -Repository PSGallery -Force -ErrorAction Stop
        Write-Host "[MODULE] '$_m' saved." -ForegroundColor Green
    } catch {
        Write-Error (
            "Could not download '$_m': $_`n" +
            "Quick fix: run  Install-Module '$_m' -Scope CurrentUser  then retry."
        )
        exit 1
    }
}

# STEP 6: Import in declared order (Az.Accounts first — all others depend on it).
# Always use the explicit .psd1 path from the cache so PowerShell resolves all
# dependencies from that same folder, never from a stale system location.
foreach ($_mod in $_requiredModules) {
    $_loadArg = $_mod  # fallback: import by name from PSModulePath
    $_modDir  = Join-Path $_dlPath $_mod
    if (Test-Path -LiteralPath $_modDir) {
        $_vdir = Get-ChildItem -LiteralPath $_modDir -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($_vdir) {
            $_psd1 = Join-Path $_vdir.FullName "$_mod.psd1"
            if (Test-Path -LiteralPath $_psd1) { $_loadArg = $_psd1 }
        }
    }
    try {
        Import-Module -Name $_loadArg -Force -ErrorAction Stop
        $script:_bootstrapLoadedModules.Add($_mod)
        Write-Host "[MODULE] '$_mod' ready." -ForegroundColor Green
    } catch {
        Write-Error "Could not load '$_mod': $($_.Exception.Message)"
        exit 1
    }
}
#endregion

# Initialize required modules (no-op guard — modules are loaded by the bootstrap above)
function Initialize-RequiredModules {
    foreach ($moduleName in @('Az.Accounts', 'Az.DesktopVirtualization', 'Az.Resources')) {
        if (-not (Get-Module -Name $moduleName -ErrorAction SilentlyContinue)) {
            try {
                Import-Module -Name $moduleName -ErrorAction Stop | Out-Null
            } catch {
                Write-Error "Module '$moduleName' is not available. Re-run the script to trigger automatic download."
                throw
            }
        }
    }
}

function Write-Log {
    param(
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','DEBUG')]
        [string]$Level = 'INFO',
        [string]$Message
    )
    
    $colors = @{
        'INFO'    = 'White'
        'WARN'    = 'Yellow' 
        'ERROR'   = 'Red'
        'SUCCESS' = 'Green'
        'DEBUG'   = 'Gray'
    }
    
    Write-Host "[$Level] $Message" -ForegroundColor $colors[$Level]
}

function Get-NameSequenceMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Name
    )

    $result = @{
        PrefixNumber = $null
        PrefixWidth = 0
        PrefixRemainder = $Name
        SuffixNumber = $null
        SuffixWidth = 0
        SuffixBase = $Name
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $result
    }

    if ($Name -match '^(?<num>\d+)[-_](?<rest>.+)$') {
        $result.PrefixNumber = [int]$Matches.num
        $result.PrefixWidth = $Matches.num.Length
        $result.PrefixRemainder = $Matches.rest
    }

    if ($Name -match '^(?<base>.+?)[-_](?<num>\d+)$') {
        $result.SuffixNumber = [int]$Matches.num
        $result.SuffixWidth = $Matches.num.Length
        $result.SuffixBase = $Matches.base
    }

    return $result
}

function Get-SequentialNamingStyle {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [array]$Names = @()
    )

    if ($null -eq $Names) {
        $Names = @()
    }

    $prefixCount = 0
    $suffixCount = 0
    foreach ($name in $Names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
        $meta = Get-NameSequenceMetadata -Name $name
        if ($null -ne $meta.PrefixNumber) { $prefixCount++ }
        if ($null -ne $meta.SuffixNumber) { $suffixCount++ }
    }

    if ($prefixCount -gt 0 -and $prefixCount -ge $suffixCount) {
        return 'Prefix'
    }

    if ($suffixCount -gt 0) {
        return 'Suffix'
    }

    return 'Suffix'
}

function Get-NextSequenceText {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [array]$Names = @(),
        [ValidateSet('Prefix','Suffix')]
        [string]$Style = 'Suffix'
    )

    if ($null -eq $Names) {
        $Names = @()
    }

    $max = 0
    $width = 2

    foreach ($name in $Names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
        $meta = Get-NameSequenceMetadata -Name $name

        if ($Style -eq 'Prefix' -and $null -ne $meta.PrefixNumber) {
            if ($meta.PrefixNumber -gt $max) { $max = $meta.PrefixNumber }
            if ($meta.PrefixWidth -gt $width) { $width = $meta.PrefixWidth }
        }

        if ($Style -eq 'Suffix' -and $null -ne $meta.SuffixNumber) {
            if ($meta.SuffixNumber -gt $max) { $max = $meta.SuffixNumber }
            if ($meta.SuffixWidth -gt $width) { $width = $meta.SuffixWidth }
        }
    }

    return ($max + 1).ToString("D$width")
}

function Get-RgBaseName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName
    )

    $base = ($ResourceGroupName -replace '^(?i)rg-', '' -replace '(?i)-management$', '').Trim('-')
    if ([string]::IsNullOrWhiteSpace($base)) { $base = 'avd' }
    return $base.ToLower()
}

function Get-ResourceObjectPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Object,
        [Parameter(Mandatory = $true)]
        [string[]]$PropertyNames
    )

    foreach ($propName in $PropertyNames) {
        if ($Object -is [hashtable]) {
            if ($Object.ContainsKey($propName) -and -not [string]::IsNullOrWhiteSpace([string]$Object[$propName])) {
                return [string]$Object[$propName]
            }
            continue
        }

        if ($Object.PSObject -and $Object.PSObject.Properties[$propName]) {
            $value = $Object.PSObject.Properties[$propName].Value
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                return [string]$value
            }
        }
    }

    return ''
}

function Get-ResourceNameFromObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Object
    )

    $name = Get-ResourceObjectPropertyValue -Object $Object -PropertyNames @('Name','ApplicationGroupName','WorkspaceName','HostPoolName')
    if (-not [string]::IsNullOrWhiteSpace($name)) {
        return $name
    }

    $id = Get-ResourceObjectPropertyValue -Object $Object -PropertyNames @('Id','ResourceId')
    if (-not [string]::IsNullOrWhiteSpace($id) -and $id -like '*/*') {
        return ($id -split '/')[-1]
    }

    return ''
}

function Get-ApplicationGroupTypeFromObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Object
    )

    $rawType = Get-ResourceObjectPropertyValue -Object $Object -PropertyNames @('ApplicationGroupType','Type','Kind')
    if ([string]::IsNullOrWhiteSpace($rawType)) {
        return ''
    }

    if ($rawType -match '(?i)RemoteApp') {
        return 'RemoteApp'
    }
    if ($rawType -match '(?i)Desktop') {
        return 'Desktop'
    }

    return $rawType
}

function ConvertTo-NamingSlug {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $slug = $Text.ToLower()
    $slug = $slug -replace '[^a-z0-9-]', '-'
    $slug = $slug -replace '-{2,}', '-'
    $slug = $slug.Trim('-')
    return $slug
}

function Get-CanonicalWorkloadBaseName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [array]$HostPoolNames = @(),
        [array]$ApplicationGroupNames = @(),
        [array]$WorkspaceNames = @()
    )

    $candidates = @($HostPoolNames + $ApplicationGroupNames + $WorkspaceNames) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($candidates.Count -eq 0) {
        return Get-RgBaseName -ResourceGroupName $ResourceGroupName
    }

    $score = @{}
    foreach ($name in $candidates) {
        $meta = Get-NameSequenceMetadata -Name $name
        $base = if ($null -ne $meta.PrefixNumber) { $meta.PrefixRemainder } elseif ($null -ne $meta.SuffixNumber) { $meta.SuffixBase } else { $name }
        $base = $base.ToLower()

        # Remove role/type tokens repeatedly to preserve only the workload core.
        do {
            $before = $base
            $base = $base -replace '^(hp|hostpool|raap|vdag|dag|ag|appgroup|workspace|ws)-', ''
            $base = $base -replace '-(hp|hostpool|raap|vdag|dag|ag|appgroup|workspace|ws)$', ''
            $base = $base.Trim('-')
        } while ($base -ne $before)

        $base = ConvertTo-NamingSlug -Text $base
        if ([string]::IsNullOrWhiteSpace($base) -or $base -match '^\d+$') {
            continue
        }

        if (-not $score.ContainsKey($base)) {
            $score[$base] = 0
        }
        $score[$base]++
    }

    if ($score.Keys.Count -eq 0) {
        return Get-RgBaseName -ResourceGroupName $ResourceGroupName
    }

    $best = $null
    $bestScore = -1
    foreach ($key in $score.Keys) {
        if ($score[$key] -gt $bestScore) {
            $best = $key
            $bestScore = $score[$key]
        }
    }

    if ([string]::IsNullOrWhiteSpace($best)) {
        return Get-RgBaseName -ResourceGroupName $ResourceGroupName
    }

    return $best
}

function Get-NextRemoteAppApplicationGroupName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        $Discovery
    )

    $rgAppGroups = @($Discovery.ApplicationGroups | Where-Object { $_.ResourceGroup -eq $ResourceGroupName })
    $remoteAppNames = @($rgAppGroups | Where-Object { $_.Type -eq 'RemoteApp' } | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $allAgNames = @($rgAppGroups | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $hostPoolNames = @($Discovery.HostPools | Where-Object { $_.ResourceGroup -eq $ResourceGroupName } | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $styleNames = if ($remoteAppNames.Count -gt 0) { $remoteAppNames } elseif ($allAgNames.Count -gt 0) { $allAgNames } elseif ($hostPoolNames.Count -gt 0) { $hostPoolNames } else { @() }
    $style = Get-SequentialNamingStyle -Names $styleNames
    $nextSeq = Get-NextSequenceText -Names $styleNames -Style $style

    $workspaceNames = @($Discovery.Workspaces | Where-Object { $_.ResourceGroup -eq $ResourceGroupName } | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $base = Get-CanonicalWorkloadBaseName -ResourceGroupName $ResourceGroupName -HostPoolNames $hostPoolNames -ApplicationGroupNames $allAgNames -WorkspaceNames $workspaceNames
    $nameCore = "raap-$base"

    if ($style -eq 'Prefix') {
        return "$nextSeq-$nameCore"
    }

    return "$nameCore-$nextSeq"
}

function Get-NextWorkspaceName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        $Discovery
    )

    $workspaceNames = @($Discovery.Workspaces | Where-Object { $_.ResourceGroup -eq $ResourceGroupName } | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $hostPoolNames = @($Discovery.HostPools | Where-Object { $_.ResourceGroup -eq $ResourceGroupName } | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $styleNames = if ($workspaceNames.Count -gt 0) { $workspaceNames } elseif ($hostPoolNames.Count -gt 0) { $hostPoolNames } else { @() }
    $style = Get-SequentialNamingStyle -Names $styleNames
    $nextSeq = Get-NextSequenceText -Names $styleNames -Style $style

    $allAgNames = @($Discovery.ApplicationGroups | Where-Object { $_.ResourceGroup -eq $ResourceGroupName } | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $base = if ($workspaceNames.Count -gt 0) {
        $wsMeta = Get-NameSequenceMetadata -Name $workspaceNames[0]
        $wsBase = if ($null -ne $wsMeta.PrefixNumber) { $wsMeta.PrefixRemainder } elseif ($null -ne $wsMeta.SuffixNumber) { $wsMeta.SuffixBase } else { $workspaceNames[0] }
        $wsBase = ($wsBase -replace '(?i)-workspace$', '').Trim('-').ToLower()
        if ([string]::IsNullOrWhiteSpace($wsBase)) {
            Get-CanonicalWorkloadBaseName -ResourceGroupName $ResourceGroupName -HostPoolNames $hostPoolNames -ApplicationGroupNames $allAgNames -WorkspaceNames $workspaceNames
        } else {
            ConvertTo-NamingSlug -Text $wsBase
        }
    } else {
        Get-CanonicalWorkloadBaseName -ResourceGroupName $ResourceGroupName -HostPoolNames $hostPoolNames -ApplicationGroupNames $allAgNames -WorkspaceNames $workspaceNames
    }

    $nameCore = "$base-workspace"
    if ($style -eq 'Prefix') {
        return "$nextSeq-$nameCore"
    }

    return "$nameCore-$nextSeq"
}

function Get-NextHostPoolName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$ApplicationGroupName,
        [Parameter(Mandatory = $true)]
        [array]$ExistingHostPoolNames
    )

    if ($ExistingHostPoolNames.Count -gt 0) {
        $style = Get-SequentialNamingStyle -Names $ExistingHostPoolNames
        $nextSeq = Get-NextSequenceText -Names $ExistingHostPoolNames -Style $style
        $base = Get-CanonicalWorkloadBaseName -ResourceGroupName $ResourceGroupName -HostPoolNames $ExistingHostPoolNames
        $nameCore = "hp-$base"
        if ($style -eq 'Prefix') {
            return "$nextSeq-$nameCore"
        }
        return "$nameCore-$nextSeq"
    }

    $cleanAg = $ApplicationGroupName.ToLower()
    $cleanAg = $cleanAg -replace '(?i)^\d+[-_]', ''
    $cleanAg = $cleanAg -replace '(?i)^raap-', ''
    $cleanAg = $cleanAg -replace '(?i)-\d+$', ''
    $cleanAg = ConvertTo-NamingSlug -Text $cleanAg
    if ([string]::IsNullOrWhiteSpace($cleanAg)) {
        $cleanAg = Get-RgBaseName -ResourceGroupName $ResourceGroupName
    }

    return "hp-$cleanAg-01"
}

function Get-AuthenticationMethod {
    Write-Host "--- AZURE AUTHENTICATION ---" -ForegroundColor Yellow
    Write-Log -Level WARN -Message "For security, you must authenticate for each script execution."
    Write-Host "Please select authentication method:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] Interactive Browser Login (default - recommended)" -ForegroundColor Green
    Write-Host "  [2] Device Code Authentication (for restricted environments)" -ForegroundColor White
    Write-Host ""
    
    do {
        $choice = Read-Host "Select authentication method (1-2, or press Enter for default)"
        
        # Default to Interactive if user presses Enter
        if ([string]::IsNullOrWhiteSpace($choice)) {
            $choice = '1'
        }
        
        switch ($choice) {
            '1' { 
                Write-Log -Level SUCCESS -Message "Selected Interactive Browser authentication"
                return 'Interactive' 
            }
            '2' { 
                Write-Log -Level SUCCESS -Message "Selected Device Code authentication"
                return 'DeviceCode' 
            }
            default { 
                Write-Host "Invalid selection. Please choose 1 or 2." -ForegroundColor Red 
            }
        }
    } while ($true)
}

function Test-AzureConnection {
    try {
        # Check if there's an existing session and disconnect it for security
        $existingContext = Get-AzContext -ErrorAction SilentlyContinue
        if ($null -ne $existingContext) {
            Write-Log -Level WARN -Message "Existing Azure session detected. Disconnecting for security..."
            Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
            Write-Log -Level INFO -Message "Previous session cleared."
        }
        
        # Force fresh authentication
        Write-Log -Level INFO -Message "Initiating fresh authentication..."
        $authMethod = Get-AuthenticationMethod
        
        Write-Host "Authenticating to Azure using $authMethod method..." -ForegroundColor Cyan
        
        switch ($authMethod) {
            'Interactive' {
                Connect-AzAccount -UseDeviceAuthentication:$false -Force
            }
            'DeviceCode' {
                Connect-AzAccount -UseDeviceAuthentication -Force
            }
        }
        
        $context = Get-AzContext
        if ($null -eq $context) {
            Write-Log -Level ERROR -Message "Authentication failed - no context established"
            return $false
        }
        
        Write-Log -Level SUCCESS -Message "Azure connection verified"
        Write-Log -Level INFO -Message "Account: $($context.Account)"
        Write-Log -Level INFO -Message "Subscription: $($context.Subscription.Name)"
        return $true
    }
    catch {
        Write-Log -Level ERROR -Message "Azure connection test failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-TenantResourceDiscovery {
    Write-Host "--- TENANT RESOURCE DISCOVERY ---" -ForegroundColor Yellow
    Write-Host "Scanning your Azure tenant for existing resources..." -ForegroundColor Cyan
    
    $discovery = @{
        Subscriptions = @()
        AllResourceGroups = @()
        AvdResourceGroups = @()
        HostPools = @()
        ApplicationGroups = @()
        Workspaces = @()
        VirtualMachines = @()
    }
    
    try {
        # Get current subscription info
        $context = Get-AzContext
        Write-Host "  - Current Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))" -ForegroundColor White
        
        $discovery.Subscriptions += @{
            Name = $context.Subscription.Name
            Id = $context.Subscription.Id
            State = $context.Subscription.State
            Current = $true
        }
        
        # Scan all resource groups
        Write-Host "  - Scanning resource groups..." -ForegroundColor Gray
        $allRGs = Get-AzResourceGroup
        $discovery.AllResourceGroups = $allRGs | ForEach-Object {
            @{
                Name = $_.ResourceGroupName
                Location = $_.Location
                Tags = $_.Tags
            }
        }
        
        # Scan for AVD resources
        Write-Host "  - Identifying AVD resources..." -ForegroundColor Gray
        foreach ($rg in $allRGs) {
            try {
                $hostPools = Get-AzWvdHostPool -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue
                $appGroups = Get-AzWvdApplicationGroup -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue
                $workspaces = Get-AzWvdWorkspace -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue

                # VM discovery is optional; do not let it block AVD resource discovery.
                $vms = @()
                if (Get-Command -Name Get-AzVM -ErrorAction SilentlyContinue) {
                    try {
                        $vms = @(Get-AzVM -ResourceGroupName $rg.ResourceGroupName -Status -ErrorAction SilentlyContinue)
                    } catch {
                        $vms = @()
                    }
                }
                
                if ($hostPools.Count -gt 0 -or $appGroups.Count -gt 0 -or $workspaces.Count -gt 0) {
                    $discovery.AvdResourceGroups += @{
                        Name = $rg.ResourceGroupName
                        Location = $rg.Location
                        HostPoolCount = $hostPools.Count
                        ApplicationGroupCount = $appGroups.Count
                        WorkspaceCount = $workspaces.Count
                        VmCount = $vms.Count
                        Tags = $rg.Tags
                    }
                    
                    # Add individual AVD resources
                    $discovery.HostPools += $hostPools | ForEach-Object { 
                        @{
                            Name = $_.Name
                            ResourceGroup = $rg.ResourceGroupName
                            Type = $_.HostPoolType
                            LoadBalancer = $_.LoadBalancerType
                            Location = $_.Location
                        }
                    }
                    
                    $discovery.ApplicationGroups += $appGroups | ForEach-Object {
                        $appGroupName = Get-ResourceNameFromObject -Object $_
                        $appGroupType = Get-ApplicationGroupTypeFromObject -Object $_
                        @{
                            Name = $appGroupName
                            ResourceGroup = $rg.ResourceGroupName
                            Type = $appGroupType
                            FriendlyName = Get-ResourceObjectPropertyValue -Object $_ -PropertyNames @('FriendlyName','DisplayName')
                            Location = Get-ResourceObjectPropertyValue -Object $_ -PropertyNames @('Location')
                            HostPoolPath = Get-ResourceObjectPropertyValue -Object $_ -PropertyNames @('HostPoolArmPath','HostPoolPath')
                        }
                    }
                    
                    $discovery.Workspaces += $workspaces | ForEach-Object {
                        $workspaceName = Get-ResourceNameFromObject -Object $_
                        @{
                            Name = $workspaceName
                            ResourceGroup = $rg.ResourceGroupName
                            FriendlyName = Get-ResourceObjectPropertyValue -Object $_ -PropertyNames @('FriendlyName','DisplayName')
                            Location = Get-ResourceObjectPropertyValue -Object $_ -PropertyNames @('Location')
                        }
                    }

                    $discovery.VirtualMachines += $vms | ForEach-Object {
                        @{
                            Name = $_.Name
                            ResourceGroup = $rg.ResourceGroupName
                            Location = $_.Location
                            PowerState = $_.PowerState
                        }
                    }
                }
            }
            catch {
                # Skip inaccessible resource groups
            }
        }
        
        # Display summary
        Write-Host "--- DISCOVERY SUMMARY ---" -ForegroundColor Green
        Write-Host "  Subscription: $($context.Subscription.Name)" -ForegroundColor White
        Write-Host "  Total Resource Groups: $($discovery.AllResourceGroups.Count)" -ForegroundColor White
        Write-Host "  AVD-Enabled Resource Groups: $($discovery.AvdResourceGroups.Count)" -ForegroundColor White
        Write-Host "  Host Pools: $($discovery.HostPools.Count)" -ForegroundColor White
        Write-Host "  Application Groups: $($discovery.ApplicationGroups.Count)" -ForegroundColor White
        Write-Host "  Workspaces: $($discovery.Workspaces.Count)" -ForegroundColor White
        Write-Host "  Virtual Machines: $($discovery.VirtualMachines.Count)" -ForegroundColor White
        
        return $discovery
    }
    catch {
        Write-Log -Level ERROR -Message "Resource discovery failed: $($_.Exception.Message)"
        throw
    }
}

function Select-ResourceGroup {
    param(
        [Parameter(Mandatory = $true)]
        $Discovery,
        [string]$PreSelectedName
    )
    
    if (![string]::IsNullOrWhiteSpace($PreSelectedName)) {
        # Validate pre-selected resource group exists
        $existing = $Discovery.AllResourceGroups | Where-Object { $_.Name -eq $PreSelectedName }
        if ($existing) {
            Write-Log -Level SUCCESS -Message "Using specified resource group: $PreSelectedName"
            return $PreSelectedName
        } else {
            Write-Log -Level WARN -Message "Specified resource group '$PreSelectedName' not found. Will create or let user choose."
        }
    }
    
    Write-Host "--- RESOURCE GROUP SELECTION ---" -ForegroundColor Yellow

    # Build a deterministic menu list so displayed indexes always map to selected values.
    $menuResourceGroups = @()
    $avdRgNames = @()

    if ($Discovery.AvdResourceGroups.Count -gt 0) {
        $avdRgNames = $Discovery.AvdResourceGroups | ForEach-Object { $_.Name }
        $menuResourceGroups += $Discovery.AvdResourceGroups
    }

    $otherRGs = $Discovery.AllResourceGroups | Where-Object { $_.Name -notin $avdRgNames }
    if ($otherRGs.Count -gt 0) {
        $menuResourceGroups += $otherRGs
    }
    
    if ($Discovery.AvdResourceGroups.Count -gt 0) {
        Write-Host "Existing AVD Resource Groups (recommended for reuse):" -ForegroundColor Green
        for ($i = 0; $i -lt $Discovery.AvdResourceGroups.Count; $i++) {
            $rg = $Discovery.AvdResourceGroups[$i]
            Write-Host "  [$($i + 1)] $($rg.Name) ($($rg.Location))" -ForegroundColor White
            Write-Host "      Host Pools: $($rg.HostPoolCount), App Groups: $($rg.ApplicationGroupCount), Workspaces: $($rg.WorkspaceCount)" -ForegroundColor Gray
        }
        Write-Host ""
    }
    
    if ($otherRGs.Count -gt 0) {
        Write-Host "Other Resource Groups (can be repurposed for AVD):" -ForegroundColor Cyan
        $startIndex = $Discovery.AvdResourceGroups.Count
        for ($i = 0; $i -lt $otherRGs.Count; $i++) {
            $rg = $otherRGs[$i]
            Write-Host "  [$($startIndex + $i + 1)] $($rg.Name) ($($rg.Location))" -ForegroundColor Gray
        }
        Write-Host ""
    }
    
    Write-Host "Options:" -ForegroundColor Yellow
    Write-Host "  [N] Create NEW resource group" -ForegroundColor Green
    if (![string]::IsNullOrWhiteSpace($PreSelectedName)) {
        Write-Host "  [C] Create '$PreSelectedName' (as specified)" -ForegroundColor Green
    }
    Write-Host ""
    
    do {
        $maxSelection = $menuResourceGroups.Count
        if (![string]::IsNullOrWhiteSpace($PreSelectedName)) {
            $prompt = "Select resource group (1-$maxSelection), N for new, C to create '$PreSelectedName'"
        } else {
            $prompt = "Select resource group (1-$maxSelection) or N for new"
        }
        
        $choice = Read-Host $prompt
        
        if ($choice.ToUpper() -eq 'N') {
            Write-Host "Resource Group Naming Examples:" -ForegroundColor Cyan
            Write-Host "  - rg-avd-production-eastus" -ForegroundColor Gray
            Write-Host "  - rg-vdi-department-region" -ForegroundColor Gray  
            Write-Host "  - resourcegroup-avd-environment" -ForegroundColor Gray
            
            do {
                $newRgName = Read-Host "Enter new resource group name"
                if ([string]::IsNullOrWhiteSpace($newRgName)) {
                    Write-Host "Resource group name cannot be empty." -ForegroundColor Red
                    continue
                }
                if ($newRgName -match '^[a-zA-Z0-9._\-]+$' -and $newRgName.Length -le 90) {
                    return $newRgName
                } else {
                    Write-Host "Invalid name. Use letters, numbers, periods, hyphens, underscores. Max 90 chars." -ForegroundColor Red
                }
            } while ($true)
        }
        elseif (![string]::IsNullOrWhiteSpace($PreSelectedName) -and $choice.ToUpper() -eq 'C') {
            return $PreSelectedName
        }
        elseif ([int]::TryParse($choice, [ref]$null) -and [int]$choice -ge 1 -and [int]$choice -le $menuResourceGroups.Count) {
            $selectedRg = $menuResourceGroups[[int]$choice - 1]
            
            # Handle different object types
            $rgName = ""
            if ($selectedRg -is [hashtable]) {
                $rgName = $selectedRg.Name
            } elseif ($selectedRg.PSObject.Properties['ResourceGroupName']) {
                $rgName = $selectedRg.ResourceGroupName
            } elseif ($selectedRg.PSObject.Properties['Name']) {
                $rgName = $selectedRg.Name
            } else {
                $rgName = $selectedRg.ToString()
            }
            
            if ([string]::IsNullOrWhiteSpace($rgName)) {
                Write-Host "Error: Unable to get resource group name. Please try again." -ForegroundColor Red
                continue
            }
            
            Write-Host "Selected: $rgName" -ForegroundColor Green
            return $rgName
        }
        else {
            Write-Host "Invalid selection. Please try again." -ForegroundColor Red
        }
    } while ($true)
}

function Select-ApplicationGroup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        $Discovery,
        [string]$PreSelectedName
    )
    
    Write-Host "--- APPLICATION GROUP SELECTION ---" -ForegroundColor Yellow
    Write-Host "Resource Group: $ResourceGroupName" -ForegroundColor Cyan

    # Always refresh from Azure for the selected RG so menu data is accurate.
    $rgAppGroups = @()
    try {
        $liveAppGroups = @(Get-AzWvdApplicationGroup -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue)
        $rgAppGroups = $liveAppGroups | ForEach-Object {
            @{
                Name = Get-ResourceNameFromObject -Object $_
                ResourceGroup = $ResourceGroupName
                Type = Get-ApplicationGroupTypeFromObject -Object $_
                FriendlyName = Get-ResourceObjectPropertyValue -Object $_ -PropertyNames @('FriendlyName','DisplayName')
                Location = Get-ResourceObjectPropertyValue -Object $_ -PropertyNames @('Location')
                HostPoolPath = Get-ResourceObjectPropertyValue -Object $_ -PropertyNames @('HostPoolArmPath','HostPoolPath')
            }
        }
    } catch {
        $rgAppGroups = @()
    }

    if ($rgAppGroups.Count -eq 0) {
        $rgAppGroups = @($Discovery.ApplicationGroups | Where-Object { $_.ResourceGroup -eq $ResourceGroupName })
    }

    $rgAppGroups = @($rgAppGroups | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })

    if (![string]::IsNullOrWhiteSpace($PreSelectedName)) {
        $existing = $rgAppGroups | Where-Object { $_.Name -eq $PreSelectedName } | Select-Object -First 1
        if ($existing) {
            Write-Log -Level SUCCESS -Message "Using specified application group: $PreSelectedName"
            return $PreSelectedName
        }
    }
    
    if ($rgAppGroups.Count -gt 0) {
        Write-Host "Existing Application Groups in this Resource Group:" -ForegroundColor Green
        for ($i = 0; $i -lt $rgAppGroups.Count; $i++) {
            $ag = $rgAppGroups[$i]
            Write-Host "  [$($i + 1)] $($ag.Name) - $($ag.Type)" -ForegroundColor White
            if ($ag.FriendlyName) { Write-Host "      Friendly Name: $($ag.FriendlyName)" -ForegroundColor Gray }
            Write-Host "      Location: $($ag.Location)" -ForegroundColor Gray
        }
        Write-Host ""
    }
    
    Write-Host "Options:" -ForegroundColor Yellow
    Write-Host "  [N] Create NEW RemoteApp application group" -ForegroundColor Green
    if (![string]::IsNullOrWhiteSpace($PreSelectedName)) {
        Write-Host "  [C] Create '$PreSelectedName' (as specified)" -ForegroundColor Green
    }
    Write-Host ""
    
    do {
        if ($rgAppGroups.Count -gt 0) {
            if (![string]::IsNullOrWhiteSpace($PreSelectedName)) {
                $prompt = "Select application group (1-$($rgAppGroups.Count)), N for new, C to create '$PreSelectedName'"
            } else {
                $prompt = "Select existing application group (1-$($rgAppGroups.Count)) or N for new"
            }
        } else {
            if (![string]::IsNullOrWhiteSpace($PreSelectedName)) {
                $prompt = "No existing groups. N for new, C to create '$PreSelectedName'"
            } else {
                $prompt = "No existing application groups found. Enter N to create new"
            }
        }
        
        $choice = Read-Host $prompt
        
        if ($choice.ToUpper() -eq 'N') {
            $existingAgNames = $rgAppGroups | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $suggestedAgName = Get-NextRemoteAppApplicationGroupName -ResourceGroupName $ResourceGroupName -Discovery $Discovery

            Write-Host "Application Group Naming Examples:" -ForegroundColor Cyan
            if ($existingAgNames.Count -gt 0) {
                Write-Host "  Existing in this resource group:" -ForegroundColor Gray
                $existingAgNames | Select-Object -First 5 | ForEach-Object { Write-Host "    - $_" -ForegroundColor Gray }
            }
            Write-Host "  RemoteApp convention enforced: raap-*" -ForegroundColor Gray
            Write-Host "  Suggested (next in sequence): $suggestedAgName" -ForegroundColor Gray
            
            do {
                $newAgName = Read-Host "Enter new RemoteApp application group name (press Enter for '$suggestedAgName')"
                if ([string]::IsNullOrWhiteSpace($newAgName)) {
                    $newAgName = $suggestedAgName
                }

                if ($newAgName -notmatch '(?i)^\d+[-_]raap-' -and $newAgName -notmatch '(?i)^raap-') {
                    Write-Host "RemoteApp application groups must start with 'raap-' (or '<NN>-raap-' when numeric prefix style is used)." -ForegroundColor Red
                    continue
                }

                if ([string]::IsNullOrWhiteSpace($newAgName)) {
                    Write-Host "Application group name cannot be empty." -ForegroundColor Red
                    continue
                }
                if ($newAgName -match '^[a-z0-9][a-z0-9\-]{1,62}[a-z0-9]$') {
                    return $newAgName
                } else {
                    Write-Host "Invalid name. Use lowercase letters, numbers, and hyphens only (3-64 chars)." -ForegroundColor Red
                }
            } while ($true)
        }
        elseif (![string]::IsNullOrWhiteSpace($PreSelectedName) -and $choice.ToUpper() -eq 'C') {
            return $PreSelectedName
        }
        elseif ($rgAppGroups.Count -gt 0 -and [int]::TryParse($choice, [ref]$null) -and [int]$choice -ge 1 -and [int]$choice -le $rgAppGroups.Count) {
            $selectedAg = $rgAppGroups[[int]$choice - 1]
            $agName = if ($selectedAg -is [hashtable]) { $selectedAg.Name } else { $selectedAg.Name }
            $agType = if ($selectedAg -is [hashtable]) { $selectedAg.Type } else { $selectedAg.ApplicationGroupType }
            if ($agType -ne 'RemoteApp') {
                Write-Host "Warning: Selected group is type '$agType'. RemoteApp publishing requires 'RemoteApp' type." -ForegroundColor Yellow
                $confirm = Read-Host "Continue anyway? (y/N)"
                if ($confirm.ToUpper() -ne 'Y') {
                    continue
                }
            }
            Write-Host "Selected: $agName" -ForegroundColor Green
            return $agName
        }
        elseif ($rgAppGroups.Count -gt 0) {
            $matchedByName = $rgAppGroups | Where-Object { $_.Name -eq $choice } | Select-Object -First 1
            if ($matchedByName) {
                Write-Host "Selected: $($matchedByName.Name)" -ForegroundColor Green
                return $matchedByName.Name
            }
        }
        else {
            Write-Host "Invalid selection. Please try again." -ForegroundColor Red
        }
    } while ($true)
}

function Initialize-ResourceGroup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [string]$Location = "East US"
    )
    
    try {
        $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
        if ($null -eq $rg) {
            Write-Log -Level WARN -Message "Resource group '$ResourceGroupName' not found. Creating..."
            $rg = New-AzResourceGroup -Name $ResourceGroupName -Location $Location
            Write-Log -Level SUCCESS -Message "Resource group '$ResourceGroupName' created successfully in $Location"
        } else {
            Write-Log -Level SUCCESS -Message "Resource group '$ResourceGroupName' already exists in $($rg.Location)"
        }
        return $rg
    }
    catch {
        Write-Log -Level ERROR -Message "Failed to ensure resource group '$ResourceGroupName': $($_.Exception.Message)"
        throw
    }
}

function Initialize-HostPoolAndApplicationGroup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$ApplicationGroupName,
        [Parameter(Mandatory = $false)]
        [string]$Location = "East US",
        [Parameter(Mandatory = $false)]
        $Discovery
    )
    
    try {
        # Check if application group exists
        $appGroup = Get-AzWvdApplicationGroup -ResourceGroupName $ResourceGroupName -Name $ApplicationGroupName -ErrorAction SilentlyContinue
        
        if ($null -eq $appGroup) {
            Write-Log -Level WARN -Message "Application group '$ApplicationGroupName' not found. Creating host pool and application group..."
            
            # Derive host pool name from existing host pool naming pattern in this resource group
            $existingHpNames = @()
            if ($Discovery -and $Discovery.HostPools) {
                $existingHpNames = @($Discovery.HostPools | Where-Object { $_.ResourceGroup -eq $ResourceGroupName } | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }
            if ($existingHpNames.Count -eq 0) {
                # Fallback: query directly
                $existingHpNames = @(Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }

            $hostPoolName = Get-NextHostPoolName -ResourceGroupName $ResourceGroupName -ApplicationGroupName $ApplicationGroupName -ExistingHostPoolNames $existingHpNames
            $hostPool = Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $hostPoolName -ErrorAction SilentlyContinue
            
            if ($null -eq $hostPool) {
                Write-Log -Level INFO -Message "Creating host pool '$hostPoolName'..."
                # Ensure we have a valid location
                if ([string]::IsNullOrWhiteSpace($Location)) {
                    $Location = "East US"
                    Write-Log -Level INFO -Message "Location not specified, using default: $Location"
                }
                $hostPool = New-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $hostPoolName -Location $Location -HostPoolType 'Pooled' -LoadBalancerType 'DepthFirst' -MaxSessionLimit 10 -PreferredAppGroupType 'RailApplications'
                Write-Log -Level SUCCESS -Message "Host pool '$hostPoolName' created successfully"
            }
            
            # Create application group
            Write-Log -Level INFO -Message "Creating application group '$ApplicationGroupName'..."
            $appGroup = New-AzWvdApplicationGroup -ResourceGroupName $ResourceGroupName -Name $ApplicationGroupName -Location $Location -ApplicationGroupType 'RemoteApp' -HostPoolArmPath $hostPool.Id
            Write-Log -Level SUCCESS -Message "Application group '$ApplicationGroupName' created successfully"
        } else {
            Write-Log -Level SUCCESS -Message "Application group '$ApplicationGroupName' already exists"
        }
        
        return $appGroup
    }
    catch {
        Write-Log -Level ERROR -Message "Failed to ensure application group '$ApplicationGroupName': $($_.Exception.Message)"
        throw
    }
}

function Get-ExistingRemoteApps {
    <#
    .SYNOPSIS
        Retrieves all existing RemoteApps from the tenant for comparison with discovered applications
    #>
    [CmdletBinding()]
    param(
        [string]$ResourceGroupName,
        [hashtable]$Discovery
    )
    
    Write-Log -Level INFO -Message "Scanning tenant for existing RemoteApps..."
    
    $existingApps = @()
    $scannedAppGroups = 0
    $totalAppGroups = 0
    
    try {
        # Get all application groups from the discovery data or scan all
        $applicationGroups = @()
        
        if ($Discovery -and $Discovery.ApplicationGroups) {
            $applicationGroups = $Discovery.ApplicationGroups | Where-Object { $_.Type -eq 'RemoteApp' -or $_.ApplicationGroupType -eq 'RemoteApp' }
            Write-Log -Level INFO -Message "Using discovery data: Found $($applicationGroups.Count) RemoteApp application groups"
        } else {
            # Fallback: scan all resource groups for application groups
            Write-Log -Level INFO -Message "Discovery data not available, scanning all resource groups..."
            $allResourceGroups = Get-AzResourceGroup -ErrorAction SilentlyContinue
            
            foreach ($rg in $allResourceGroups) {
                try {
                    $rgAppGroups = Get-AzWvdApplicationGroup -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue | Where-Object { $_.ApplicationGroupType -eq 'RemoteApp' }
                    if ($rgAppGroups) {
                        $applicationGroups += $rgAppGroups
                    }
                } catch {
                    Write-Log -Level DEBUG -Message "Could not scan resource group '$($rg.ResourceGroupName)': $($_.Exception.Message)"
                }
            }
            Write-Log -Level INFO -Message "Found $($applicationGroups.Count) RemoteApp application groups across all resource groups"
        }
        
        $totalAppGroups = $applicationGroups.Count
        
        # Get RemoteApps from each application group
        foreach ($appGroup in $applicationGroups) {
            try {
                $scannedAppGroups++
                
                # Handle different object types from discovery vs direct query
                $rgName = if ($appGroup.ResourceGroup) { $appGroup.ResourceGroup } else { $appGroup.Id.Split('/')[4] }
                $agName = if ($appGroup.Name) { $appGroup.Name } else { $appGroup.ApplicationGroupName }
                
                Write-Log -Level DEBUG -Message "Scanning application group '$agName' in '$rgName' ($scannedAppGroups/$totalAppGroups)"
                
                $apps = Get-AzWvdApplication -ResourceGroupName $rgName -ApplicationGroupName $agName -ErrorAction SilentlyContinue
                
                foreach ($app in $apps) {
                    # Normalize the existing app data for comparison
                    $existingApp = @{
                        Name = $app.Name
                        DisplayName = if ($app.FriendlyName) { $app.FriendlyName } else { $app.Name }
                        ApplicationPath = $app.FilePath
                        ResourceGroupName = $rgName
                        ApplicationGroupName = $agName
                        Description = $app.Description
                        CommandLineArguments = $app.CommandLineArguments
                        ShowInPortal = $app.ShowInPortal
                        ApplicationId = $app.Name
                        ApplicationType = if ($app.FilePath) { 'FilePath' } elseif ($app.MsixPackageFamilyName) { 'MSIX' } else { 'Unknown' }
                    }
                    
                    $existingApps += $existingApp
                }
                
            } catch {
                Write-Log -Level WARN -Message "Failed to scan application group '$agName': $($_.Exception.Message)"
            }
        }
        
        Write-Log -Level SUCCESS -Message "Found $($existingApps.Count) existing RemoteApps across $scannedAppGroups application groups"
        
        # Group by application path for easier comparison
        $existingByPath = @{}
        $existingByName = @{}
        
        foreach ($app in $existingApps) {
            if ($app.ApplicationPath) {
                $normalizedPath = $app.ApplicationPath.ToLower()
                if (-not $existingByPath.ContainsKey($normalizedPath)) {
                    $existingByPath[$normalizedPath] = @()
                }
                $existingByPath[$normalizedPath] += $app
            }
            
            if ($app.DisplayName) {
                $normalizedName = $app.DisplayName.ToLower()
                if (-not $existingByName.ContainsKey($normalizedName)) {
                    $existingByName[$normalizedName] = @()
                }
                $existingByName[$normalizedName] += $app
            }
        }
        
        return @{
            AllApps = $existingApps
            ByPath = $existingByPath
            ByName = $existingByName
            AppGroupsScanned = $scannedAppGroups
            TotalFound = $existingApps.Count
        }
        
    } catch {
        Write-Log -Level ERROR -Message "Failed to retrieve existing RemoteApps: $($_.Exception.Message)"
        return @{
            AllApps = @()
            ByPath = @{}
            ByName = @{}
            AppGroupsScanned = 0
            TotalFound = 0
        }
    }
}

function Compare-DiscoveredWithExisting {
    <#
    .SYNOPSIS
        Compares discovered applications with existing RemoteApps and categorizes them
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$DiscoveredApps,
        [Parameter(Mandatory = $true)]
        [hashtable]$ExistingApps
    )
    
    Write-Log -Level INFO -Message "Comparing $($DiscoveredApps.Count) discovered applications with $($ExistingApps.TotalFound) existing RemoteApps..."
    
    $comparison = @{
        NewApps = @()
        ExistingApps = @()
        PotentialUpdates = @()
        Duplicates = @()
    }
    
    foreach ($app in $DiscoveredApps) {
        if ($null -eq $app -or -not $app.ApplicationPath) {
            continue
        }
        
        $normalizedPath = $app.ApplicationPath.ToLower()
        $normalizedName = $app.DisplayName.ToLower()
        
        # Check for exact path match
        $pathMatch = $ExistingApps.ByPath[$normalizedPath]
        $nameMatch = $ExistingApps.ByName[$normalizedName]
        
        # Add comparison result to the app object
        $app.ComparisonResult = @{
            Status = 'New'
            ExistingApp = $null
            Reason = ''
        }
        
        if ($pathMatch) {
            # Exact path match found
            $app.ComparisonResult.Status = 'Existing'
            $app.ComparisonResult.ExistingApp = $pathMatch[0]
            $app.ComparisonResult.Reason = "Same application path already published in '$($pathMatch[0].ApplicationGroupName)'"
            $comparison.ExistingApps += $app
        } elseif ($nameMatch) {
            # Same display name but different path - potential update or duplicate
            $app.ComparisonResult.Status = 'PotentialUpdate'
            $app.ComparisonResult.ExistingApp = $nameMatch[0]
            $app.ComparisonResult.Reason = "Same display name exists with different path in '$($nameMatch[0].ApplicationGroupName)'"
            $comparison.PotentialUpdates += $app
        } else {
            # No match found - new application
            $app.ComparisonResult.Status = 'New'
            $app.ComparisonResult.Reason = 'Not currently published as RemoteApp'
            $comparison.NewApps += $app
        }
    }
    
    Write-Log -Level SUCCESS -Message "Comparison complete: $($comparison.NewApps.Count) new, $($comparison.ExistingApps.Count) existing, $($comparison.PotentialUpdates.Count) potential updates"
    
    return $comparison
}

function Get-LocalApplications {
    <#
    .SYNOPSIS
        Discovers applications installed on the local machine that can be published as RemoteApps
    #>
    [CmdletBinding()]
    param(
        [switch]$IncludeSystemApps,
        [switch]$IncludeStoreApps
    )
    
    Write-Log -Level INFO -Message "Scanning local machine for RemoteApp-capable applications..."
    
    $applications = @()
    
    try {
        # Scan Start Menu applications
        Write-Log -Level INFO -Message "Scanning Start Menu applications..."
        $startMenuPaths = @(
            "$env:ALLUSERSPROFILE\Microsoft\Windows\Start Menu\Programs",
            "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
        )
        
        foreach ($path in $startMenuPaths) {
            if (Test-Path $path) {
                $shortcuts = Get-ChildItem -Path $path -Recurse -Filter "*.lnk" -ErrorAction SilentlyContinue
                foreach ($shortcut in $shortcuts) {
                    try {
                        $shell = New-Object -ComObject WScript.Shell
                        $link = $shell.CreateShortcut($shortcut.FullName)
                        
                        if ($link.TargetPath -and (Test-Path $link.TargetPath) -and $link.TargetPath -match '\.exe$') {
                            $appInfo = Get-ApplicationInfo -ExecutablePath $link.TargetPath -ShortcutPath $shortcut.FullName -SourceType "StartMenu"
                            if ($appInfo) {
                                Write-Log -Level DEBUG -Message "Adding StartMenu app: $($appInfo.DisplayName) at $($appInfo.ApplicationPath)"
                                $applications += $appInfo
                            } else {
                                Write-Log -Level DEBUG -Message "Get-ApplicationInfo returned null for StartMenu: $($link.TargetPath)"
                            }
                        }
                    }
                    catch {
                        Write-Log -Level DEBUG -Message "Failed to process shortcut: $($shortcut.FullName)"
                    }
                }
            }
        }
        
        # Scan installed programs from registry
        Write-Log -Level INFO -Message "Scanning installed programs registry..."
        $regPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        
        foreach ($regPath in $regPaths) {
            try {
                $programs = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue | Where-Object { 
                    $_.DisplayName -and $_.DisplayName -notlike "Microsoft Visual C++*" -and 
                    $_.DisplayName -notlike "Microsoft .NET*" -and $_.Publisher -notlike "Microsoft Corporation"
                }
                
                foreach ($program in $programs) {
                    if ($program.InstallLocation -and (Test-Path $program.InstallLocation)) {
                        $exeFiles = Get-ChildItem -Path $program.InstallLocation -Recurse -Filter "*.exe" -ErrorAction SilentlyContinue | 
                                   Where-Object { $_.Name -notlike "*uninstall*" -and $_.Name -notlike "*setup*" }
                        
                        foreach ($exe in $exeFiles | Select-Object -First 1) {
                            $appInfo = Get-ApplicationInfo -ExecutablePath $exe.FullName -ProgramName $program.DisplayName -SourceType "FilePath"
                            if ($appInfo) {
                                Write-Log -Level DEBUG -Message "Adding app: $($appInfo.DisplayName) at $($appInfo.ApplicationPath)"
                                $applications += $appInfo
                            } else {
                                Write-Log -Level DEBUG -Message "Get-ApplicationInfo returned null for: $($exe.FullName)"
                            }
                        }
                    }
                }
            }
            catch {
                Write-Log -Level DEBUG -Message "Failed to scan registry path: $regPath"
            }
        }
        
        # Scan Microsoft Store applications if requested
        if ($IncludeStoreApps) {
            Write-Log -Level INFO -Message "Scanning Microsoft Store applications..."
            try {
                $storeApps = Get-AppxPackage | Where-Object { 
                    $_.Name -notlike "*Microsoft.Windows*" -and 
                    $_.Name -notlike "*Microsoft.NET*" -and
                    $_.PackageFamilyName -and 
                    $_.InstallLocation 
                }
                
                foreach ($app in $storeApps) {
                    $appInfo = @{
                        Name = $app.DisplayName -replace '[^\w\-_\.]', ''
                        DisplayName = $app.DisplayName
                        FilePath = "shell:AppsFolder\$($app.PackageFamilyName)!App"
                        Description = "Microsoft Store App: $($app.DisplayName)"
                        Publisher = $app.Publisher
                        Version = $app.Version
                        InstallLocation = $app.InstallLocation
                        Source = "Microsoft Store"
                        IsValid = $true
                        ValidationResults = @("Microsoft Store app - uses shell:AppsFolder path")
                        RequiresCustomIcon = $true
                    }
                    $applications += $appInfo
                }
            }
            catch {
                Write-Log -Level WARN -Message "Failed to scan Microsoft Store applications: $($_.Exception.Message)"
            }
        }
        
        # Remove duplicates using a simpler method that preserves object integrity  
        Write-Log -Level INFO -Message "Removing duplicates from $($applications.Count) discovered applications..."
        $uniqueApps = @()
        $seenPaths = @{}
        
        foreach ($app in $applications) {
            if ($null -ne $app -and $app.ApplicationPath -and -not $seenPaths.ContainsKey($app.ApplicationPath)) {
                $seenPaths[$app.ApplicationPath] = $true
                $uniqueApps += $app
            }
        }
        
        $applications = $uniqueApps | Sort-Object { $_.DisplayName }
        Write-Log -Level INFO -Message "After deduplication: $($applications.Count) unique applications"
        
        Write-Log -Level SUCCESS -Message "Found $($applications.Count) potential RemoteApp applications"
        
        # Debug: Check if applications array contains nulls
        $nullCount = ($applications | Where-Object { $null -eq $_ }).Count
        if ($nullCount -gt 0) {
            Write-Log -Level ERROR -Message "Applications array contains $nullCount null values!"
        }
        
        # Debug: Check first few applications for validity
        for ($i = 0; $i -lt [Math]::Min(3, $applications.Count); $i++) {
            $app = $applications[$i]
            if ($null -eq $app) {
                Write-Log -Level ERROR -Message "Application at index $i is NULL"
            } else {
                Write-Log -Level INFO -Message "App $i - DisplayName: '$($app.DisplayName)', Path: '$($app.ApplicationPath)'"
            }
        }
        
        return $applications
    }
    catch {
        Write-Log -Level ERROR -Message "Application discovery failed: $($_.Exception.Message)"
        throw
    }
}

function Get-ApplicationInfo {
    <#
    .SYNOPSIS
        Gets detailed RemoteApp parameters for an application according to Microsoft AVD requirements
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath,
        [string]$ShortcutPath,
        [string]$ProgramName,
        [string]$SourceType = "FilePath"  # FilePath, StartMenu, or AppAttach
    )
    
    # Helper function to clean encoding issues and special characters
    function ConvertTo-CleanTextEncoding {
        param([string]$Text)
        if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
        
        # Remove common encoding artifacts and special characters
        $cleaned = $Text -replace '[^\x20-\x7E]', '' # Remove non-ASCII printable characters
        $cleaned = $cleaned -replace '\s+', ' '      # Normalize whitespace
        $cleaned = $cleaned.Trim()
        
        return $cleaned
    }
    
    try {
        Write-Log -Level DEBUG -Message "Get-ApplicationInfo called for: $ExecutablePath"
        if (-not (Test-Path $ExecutablePath)) {
            Write-Log -Level DEBUG -Message "File not found: $ExecutablePath"
            return $null
        }
        
        $fileInfo = Get-Item $ExecutablePath
        $versionInfo = $fileInfo.VersionInfo
        Write-Log -Level DEBUG -Message "Version info - ProductName: '$($versionInfo.ProductName)', Company: '$($versionInfo.CompanyName)'"
        
        # Generate clean application name with encoding fix
        $rawName = if ($ProgramName -and ![string]::IsNullOrWhiteSpace($ProgramName)) { 
            $ProgramName
        } elseif ($versionInfo.ProductName -and ![string]::IsNullOrWhiteSpace($versionInfo.ProductName)) { 
            $versionInfo.ProductName
        } else { 
            $fileInfo.BaseName
        }
        
        # Clean encoding issues from the display name
        $appName = ConvertTo-CleanTextEncoding -Text $rawName
        if ([string]::IsNullOrWhiteSpace($appName)) {
            $appName = $fileInfo.BaseName
        }
        
        # Create simple, clean identifier (just alphanumeric and basic punctuation)
        $cleanName = $appName -replace '[^a-zA-Z0-9\s\-]', '' -replace '\s+', '-'
        $cleanName = $cleanName.Trim('-')
        if ([string]::IsNullOrWhiteSpace($cleanName)) {
            $cleanName = $fileInfo.BaseName -replace '[^a-zA-Z0-9\-]', ''
        }
        
        # Validate for RemoteApp compatibility
        $validation = Test-RemoteAppCompatibility -ExecutablePath $ExecutablePath -ApplicationName $appName
        
        # Create RemoteApp parameter object according to Microsoft documentation
        $appInfo = @{
            # Core RemoteApp Parameters (required for all types)
            ApplicationPath = $ExecutablePath  # File path to .exe
            ApplicationIdentifier = $cleanName  # Simple, clean identifier (product name)
            DisplayName = $appName  # Friendly name shown to users (cleaned)
            Description = if ($versionInfo.FileDescription -and ![string]::IsNullOrWhiteSpace($versionInfo.FileDescription)) { 
                ConvertTo-CleanTextEncoding -Text $versionInfo.FileDescription 
            } else { 
                "Application: $appName" 
            }
            
            # Additional metadata
            Publisher = if ($versionInfo.CompanyName -and ![string]::IsNullOrWhiteSpace($versionInfo.CompanyName)) { 
                ConvertTo-CleanTextEncoding -Text $versionInfo.CompanyName 
            } else { 
                "Unknown Publisher" 
            }
            Version = if ($versionInfo.ProductVersion -and ![string]::IsNullOrWhiteSpace($versionInfo.ProductVersion)) { $versionInfo.ProductVersion.Trim() } else { "Unknown Version" }
            FileSize = [math]::Round($fileInfo.Length / 1MB, 2)
            InstallLocation = $fileInfo.DirectoryName
            
            # RemoteApp Configuration
            SourceType = $SourceType  # FilePath, StartMenu, or AppAttach
            RequireCommandLine = $false  # Default to not requiring command line
            CommandLineArguments = ""  # Empty by default
            RequiresCustomIcon = $false  # Default to using application's built-in icon
            IconPath = $ExecutablePath  # Use executable for icon extraction
            IconIndex = 0  # Default icon index
            
            # Discovery metadata
            ShortcutPath = $ShortcutPath
            Source = "Local Installation"
            IsValid = $validation.IsValid
            ValidationResults = $validation.Results
        }
        
        # Final validation to ensure critical RemoteApp parameters are populated
        if ([string]::IsNullOrWhiteSpace($appInfo.DisplayName)) {
            $appInfo.DisplayName = $fileInfo.BaseName
        }
        if ([string]::IsNullOrWhiteSpace($appInfo.ApplicationIdentifier)) {
            $appInfo.ApplicationIdentifier = ($fileInfo.BaseName -replace '[^a-zA-Z0-9\-]', '').Trim('-')
        }
        if ([string]::IsNullOrWhiteSpace($appInfo.Publisher)) {
            $appInfo.Publisher = "Unknown Publisher"
        }
        if ([string]::IsNullOrWhiteSpace($appInfo.Description)) {
            $appInfo.Description = "Application: $($appInfo.DisplayName)"
        }
        
        Write-Log -Level DEBUG -Message "Created app info - DisplayName: '$($appInfo.DisplayName)', Path: '$($appInfo.ApplicationPath)', Publisher: '$($appInfo.Publisher)'"
        return $appInfo
    }
    catch {
        Write-Log -Level DEBUG -Message "Failed to get application info for: $ExecutablePath - $($_.Exception.Message)"
        return $null
    }
}

function Test-RemoteAppCompatibility {
    <#
    .SYNOPSIS
        Tests if an application is compatible with RemoteApp publishing
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath,
        [Parameter(Mandatory = $true)]
        [string]$ApplicationName
    )
    
    $validationResults = @()
    $isValid = $true
    
    # Check if file exists and is accessible
    if (-not (Test-Path $ExecutablePath)) {
        $validationResults += "ERROR: Executable file not found or not accessible"
        $isValid = $false
    } else {
        $validationResults += "PASS: Executable file exists and is accessible"
    }
    
    # Check file extension
    if ($ExecutablePath -notmatch '\.exe$') {
        $validationResults += "ERROR: File must be a .exe executable"
        $isValid = $false
    } else {
        $validationResults += "PASS: Valid executable file (.exe)"
    }
    
    # Check if it's a system file (potential issues)
    $systemPaths = @("Windows\System32", "Windows\SysWOW64", "Windows\winsxs")
    $isSystemFile = $systemPaths | ForEach-Object { $ExecutablePath -like "*$_*" } | Where-Object { $_ -eq $true }
    
    if ($isSystemFile) {
        $validationResults += "WARNING: System file - may have compatibility issues"
    } else {
        $validationResults += "PASS: Non-system application"
    }
    
    # Check for common problematic applications
    $problematicApps = @("uninstall", "setup", "installer", "update", "patch", "launcher")
    $isProblematic = $problematicApps | ForEach-Object { $ApplicationName -like "*$_*" } | Where-Object { $_ -eq $true }
    
    if ($isProblematic) {
        $validationResults += "WARNING: Application name suggests installer/launcher - may not be suitable"
    } else {
        $validationResults += "PASS: Application name appears suitable for RemoteApp"
    }
    
    # Check file size (very large files might have issues)
    try {
        $fileInfo = Get-Item $ExecutablePath
        $fileSizeMB = [math]::Round($fileInfo.Length / 1MB, 2)
        if ($fileSizeMB -gt 500) {
            $validationResults += "WARNING: Large executable file ($fileSizeMB MB) - may impact performance"
        } else {
            $validationResults += "PASS: Reasonable file size ($fileSizeMB MB)"
        }
    } catch {
        $validationResults += "WARNING: Could not determine file size"
    }
    
    # Check for dependencies in the same directory
    try {
        $appDir = Split-Path $ExecutablePath -Parent
        $dllCount = (Get-ChildItem -Path $appDir -Filter "*.dll" -ErrorAction SilentlyContinue).Count
        if ($dllCount -gt 0) {
            $validationResults += "PASS: Found $dllCount DLL dependencies in application directory"
        } else {
            $validationResults += "INFO: No DLL dependencies found in application directory"
        }
    } catch {
        $validationResults += "INFO: Could not scan for dependencies"
    }
    
    return @{
        IsValid = $isValid
        Results = $validationResults
    }
}

function Set-ApplicationCommandLine {
    <#
    .SYNOPSIS
        Allows users to specify command line requirements for selected applications
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Applications
    )
    
    Write-Host "--- COMMAND LINE CONFIGURATION ---" -ForegroundColor Yellow
    Write-Host "Some applications may require command line arguments to function properly as RemoteApps." -ForegroundColor Cyan
    Write-Host "Review each application and specify if command line arguments are needed." -ForegroundColor Cyan
    Write-Host ""
    
    foreach ($app in $Applications) {
        Write-Host "Application: $($app.DisplayName)" -ForegroundColor White
        Write-Host "Path: $($app.ApplicationPath)" -ForegroundColor Gray
        Write-Host ""
        
        $needsCommandLine = Read-Host "Does this application require command line arguments? (y/N)"
        
        if ($needsCommandLine.ToUpper() -eq 'Y') {
            $app.RequireCommandLine = $true
            
            Write-Host "Examples of common command line arguments:" -ForegroundColor Cyan
            Write-Host "  - /minimized - Start minimized" -ForegroundColor Gray
            Write-Host "  - /safe - Start in safe mode" -ForegroundColor Gray
            Write-Host "  - /document - Open specific document type" -ForegroundColor Gray
            Write-Host "  - /readonly - Open in read-only mode" -ForegroundColor Gray
            Write-Host ""
            
            $commandLine = Read-Host "Enter command line arguments (or press Enter for none)"
            if (![string]::IsNullOrWhiteSpace($commandLine)) {
                $app.CommandLineArguments = $commandLine.Trim()
                Write-Log -Level SUCCESS -Message "Command line set: $($app.CommandLineArguments)"
            } else {
                $app.RequireCommandLine = $false
                Write-Log -Level INFO -Message "No command line arguments specified"
            }
        } else {
            $app.RequireCommandLine = $false
            $app.CommandLineArguments = ""
            Write-Log -Level INFO -Message "No command line arguments required"
        }
        Write-Host ""
    }
    
    return $Applications
}

function Show-ApplicationSelectionMenu {
    <#
    .SYNOPSIS
        Displays an enhanced interactive menu for selecting applications to publish as RemoteApps
        with comparison against existing RemoteApps in the tenant
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Applications,
        [hashtable]$ComparisonData
    )
    
    if ($Applications.Count -eq 0) {
        Write-Log -Level WARN -Message "No applications found to publish"
        return @()
    }
    
    # Debug: Check what properties are available on the application objects
    Write-Log -Level INFO -Message "Show-ApplicationSelectionMenu received $($Applications.Count) applications"
    if ($Applications.Count -gt 0) {
        $firstApp = $Applications[0]
        if ($null -eq $firstApp) {
            Write-Log -Level ERROR -Message "First application is NULL!"
        } else {
            Write-Log -Level INFO -Message "First app properties: $($firstApp.Keys -join ', ')" 
            Write-Log -Level INFO -Message "First app DisplayName: '$($firstApp.DisplayName)'"
            Write-Log -Level INFO -Message "First app ApplicationPath: '$($firstApp.ApplicationPath)'"
            Write-Log -Level INFO -Message "First app Publisher: '$($firstApp.Publisher)'"
        }
    }
    
    Write-Host "--- APPLICATION SELECTION FOR REMOTEAPP PUBLISHING ---" -ForegroundColor Yellow
    
    # Show tenant analysis if comparison data is available
    if ($ComparisonData -and $ComparisonData.TotalFound -gt 0) {
        Write-Host "Tenant Analysis: Found $($ComparisonData.TotalFound) existing RemoteApps across $($ComparisonData.AppGroupsScanned) application groups" -ForegroundColor Cyan
        Write-Host ""
    }
    
    Write-Host "Found $($Applications.Count) potential applications. Select which ones to publish:" -ForegroundColor Cyan
    Write-Host ""
    
    # Enhanced display with comparison data if available
    if ($ComparisonData) {
        $newApps = $Applications | Where-Object { $_.ComparisonResult.Status -eq 'New' }
        $existingApps = $Applications | Where-Object { $_.ComparisonResult.Status -eq 'Existing' }
        $updateApps = $Applications | Where-Object { $_.ComparisonResult.Status -eq 'PotentialUpdate' }
        $displayedApps = @($newApps + $updateApps + $existingApps)
        
        # Show new applications (recommended for publishing)
        if ($newApps.Count -gt 0) {
            Write-Host "--- NEW APPLICATIONS (Recommended for publishing) ---" -ForegroundColor Green
            for ($i = 0; $i -lt $newApps.Count; $i++) {
                $app = $newApps[$i]
                if ($null -eq $app) {
                    Write-Log -Level ERROR -Message "New app $($i+1) is NULL!"
                    continue
                }
                
                $displayName = if ($app.DisplayName) { $app.DisplayName } else { "Unknown Application" }
                $filePath = if ($app.ApplicationPath) { $app.ApplicationPath } else { "Unknown Path" }
                $validStatus = if ($app.IsValid) { "Valid" } else { "Needs Review" }
                $publisher = if ($app.Publisher) { $app.Publisher } else { "Unknown Publisher" }
                $fileSize = if ($app.FileSize) { $app.FileSize } else { "0" }
                
                Write-Host "  [$($i + 1)] $displayName" -ForegroundColor White
                Write-Host "      Path: $filePath" -ForegroundColor Gray
                Write-Host "      Publisher: $publisher | Status: $validStatus | Size: $fileSize MB" -ForegroundColor Gray
                Write-Host ""
            }
        } else {
            Write-Host "--- NEW APPLICATIONS ---" -ForegroundColor Green
            Write-Host "  No new applications found (all discovered apps are already published)" -ForegroundColor Gray
            Write-Host ""
        }
        
        # Show applications that might need updates
        if ($updateApps.Count -gt 0) {
            Write-Host "--- POTENTIAL UPDATES (Same name, different path) ---" -ForegroundColor Yellow
            $startIndex = $newApps.Count
            for ($i = 0; $i -lt $updateApps.Count; $i++) {
                $app = $updateApps[$i]
                if ($null -eq $app) {
                    Write-Log -Level ERROR -Message "Update app $($i+1) is NULL!"
                    continue
                }
                
                $displayName = if ($app.DisplayName) { $app.DisplayName } else { "Unknown Application" }
                $filePath = if ($app.ApplicationPath) { $app.ApplicationPath } else { "Unknown Path" }
                $existingInfo = $app.ComparisonResult.ExistingApp
                
                Write-Host "  [$($startIndex + $i + 1)] $displayName" -ForegroundColor Yellow
                Write-Host "      New Path: $filePath" -ForegroundColor Gray
                Write-Host "      Existing: $($existingInfo.ApplicationPath) in '$($existingInfo.ApplicationGroupName)'" -ForegroundColor Gray
                Write-Host ""
            }
        }
        
        # Show already published applications (for reference, limited display)
        if ($existingApps.Count -gt 0) {
            Write-Host "--- ALREADY PUBLISHED (Available for reference) ---" -ForegroundColor Red
            $startIndex = $newApps.Count + $updateApps.Count
            $displayCount = [Math]::Min(3, $existingApps.Count)
            
            for ($i = 0; $i -lt $displayCount; $i++) {
                $app = $existingApps[$i]
                if ($null -eq $app) {
                    Write-Log -Level ERROR -Message "Existing app $($i+1) is NULL!"
                    continue
                }
                
                $displayName = if ($app.DisplayName) { $app.DisplayName } else { "Unknown Application" }
                $existingInfo = $app.ComparisonResult.ExistingApp
                
                Write-Host "  [$($startIndex + $i + 1)] $displayName (Already Published)" -ForegroundColor Red
                Write-Host "      Published in: $($existingInfo.ApplicationGroupName)" -ForegroundColor Gray
                Write-Host ""
            }
            
            if ($existingApps.Count -gt 3) {
                Write-Host "      ... and $($existingApps.Count - 3) more already published applications (use 'ALL' to see)" -ForegroundColor DarkGray
                Write-Host ""
            }
        }
        
        # Selection options with enhanced NEW option
        Write-Host "Selection Options:" -ForegroundColor Cyan
        Write-Host "  [1] NEW   - Select only new applications (recommended - $($newApps.Count) apps)" -ForegroundColor Green
        Write-Host "  [2] VALID - Select only validated applications" -ForegroundColor White
        Write-Host "  [3] ALL   - Select all applications" -ForegroundColor White
        Write-Host "  [4] LIST  - Enter numbers separated by commas (e.g., 1,3,5)" -ForegroundColor White
        Write-Host "  [5] NONE  - Skip publishing" -ForegroundColor White
        Write-Host ""
        
        do {
            $selection = Read-Host "Select applications to publish"
            $selectionText = if ([string]::IsNullOrWhiteSpace($selection)) { '' } else { $selection.Trim().ToUpper() }
            
            if ([string]::IsNullOrWhiteSpace($selection) -or $selectionText -eq 'NONE' -or $selectionText -eq '5') {
                Write-Log -Level INFO -Message "No applications selected for publishing"
                return @()
            }
            
            if ($selectionText -eq 'NEW' -or $selectionText -eq '1') {
                Write-Log -Level SUCCESS -Message "Selected $($newApps.Count) new applications (not already published)"
                return $newApps
            }
            
            if ($selectionText -eq 'ALL' -or $selectionText -eq '3') {
                Write-Log -Level INFO -Message "Selected all $($Applications.Count) applications"
                return $Applications
            }
            
            if ($selectionText -eq 'VALID' -or $selectionText -eq '2') {
                $validApps = $Applications | Where-Object { $_.IsValid }
                Write-Log -Level INFO -Message "Selected $($validApps.Count) validated applications"
                return $validApps
            }

            if ($selectionText -eq 'LIST' -or $selectionText -eq '4') {
                Write-Host "Enter application numbers separated by commas (e.g., 1,3,5)" -ForegroundColor Cyan
                $selection = Read-Host "Application numbers"
            }
            
            # Parse comma-separated numbers
            try {
                $indices = $selection -split ',' | ForEach-Object { [int]$_.Trim() }
                $selectedApps = @()
                
                foreach ($index in $indices) {
                    if ($index -ge 1 -and $index -le $displayedApps.Count) {
                        $selectedApps += $displayedApps[$index - 1]
                    } else {
                        Write-Host "Invalid selection: $index (must be between 1 and $($displayedApps.Count))" -ForegroundColor Red
                        throw "Invalid selection"
                    }
                }
                
                Write-Log -Level SUCCESS -Message "Selected $($selectedApps.Count) applications for publishing"
                return $selectedApps
            }
            catch {
                Write-Host "Invalid selection format. Please try again." -ForegroundColor Red
            }
        } while ($true)
        
    } else {
        # Fallback to original logic without comparison data
        $validApps = $Applications | Where-Object { $_.IsValid }
        $invalidApps = $Applications | Where-Object { -not $_.IsValid }
        $displayedApps = @($validApps + $invalidApps)
        
        if ($validApps.Count -gt 0) {
            Write-Host "--- RECOMMENDED APPLICATIONS (Valid for RemoteApp) ---" -ForegroundColor Green
            for ($i = 0; $i -lt $validApps.Count; $i++) {
                $app = $validApps[$i]
                if ($null -eq $app) {
                    Write-Log -Level ERROR -Message "Valid app $($i+1) is NULL!"
                    continue
                }
                
                $displayName = if ($app.DisplayName) { $app.DisplayName } else { "Unknown Application" }
                $filePath = if ($app.ApplicationPath) { $app.ApplicationPath } else { "Unknown Path" }
                $publisher = if ($app.Publisher) { $app.Publisher } else { "Unknown Publisher" }
                $fileSize = if ($app.FileSize) { $app.FileSize } else { "0" }
                
                Write-Host "  [$($i + 1)] $displayName" -ForegroundColor White
                Write-Host "      Path: $filePath" -ForegroundColor Gray
                Write-Host "      Publisher: $publisher | Size: $fileSize MB" -ForegroundColor Gray
                Write-Host ""
            }
        }
        
        if ($invalidApps.Count -gt 0) {
            Write-Host "--- APPLICATIONS WITH ISSUES (Review Required) ---" -ForegroundColor Yellow
            $startIndex = $validApps.Count
            for ($i = 0; $i -lt $invalidApps.Count; $i++) {
                $app = $invalidApps[$i]
                if ($null -eq $app) {
                    Write-Log -Level ERROR -Message "Invalid app $($i+1) is NULL!"
                    continue
                }
                
                $displayName = if ($app.DisplayName) { $app.DisplayName } else { "Unknown Application" }
                $filePath = if ($app.ApplicationPath) { $app.ApplicationPath } else { "Unknown Path" }
                $issues = if ($app.ValidationResults) { ($app.ValidationResults | Where-Object { $_ -like 'ERROR:*' -or $_ -like 'WARNING:*' }) -join ', ' } else { "Validation failed" }
                
                Write-Host "  [$($startIndex + $i + 1)] $displayName [WARNING]" -ForegroundColor Yellow
                Write-Host "      Path: $filePath" -ForegroundColor Gray
                Write-Host "      Issues: $issues" -ForegroundColor Red
                Write-Host ""
            }
        }
        
        Write-Host "Selection Options:" -ForegroundColor Cyan
        Write-Host "  [1] LIST  - Enter numbers separated by commas (e.g., 1,3,5)" -ForegroundColor White
        Write-Host "  [2] ALL   - Select all recommended applications" -ForegroundColor White
        Write-Host "  [3] VALID - Select only validated applications" -ForegroundColor White
        Write-Host "  [4] NONE  - Skip publishing" -ForegroundColor White
        Write-Host ""
        
        do {
            $selection = Read-Host "Select applications to publish"
            $selectionText = if ([string]::IsNullOrWhiteSpace($selection)) { '' } else { $selection.Trim().ToUpper() }
            
            if ([string]::IsNullOrWhiteSpace($selection) -or $selectionText -eq 'NONE' -or $selectionText -eq '4') {
                Write-Log -Level INFO -Message "No applications selected for publishing"
                return @()
            }
            
            if ($selectionText -eq 'ALL' -or $selectionText -eq '2') {
                Write-Log -Level INFO -Message "Selected all $($Applications.Count) applications"
                return $Applications
            }
            
            if ($selectionText -eq 'VALID' -or $selectionText -eq '3') {
                Write-Log -Level INFO -Message "Selected $($validApps.Count) validated applications"
                return $validApps
            }

            if ($selectionText -eq 'LIST' -or $selectionText -eq '1') {
                Write-Host "Enter application numbers separated by commas (e.g., 1,3,5)" -ForegroundColor Cyan
                $selection = Read-Host "Application numbers"
            }
            
            # Parse comma-separated numbers
            try {
                $indices = $selection -split ',' | ForEach-Object { [int]$_.Trim() }
                $selectedApps = @()
                
                foreach ($index in $indices) {
                    if ($index -ge 1 -and $index -le $displayedApps.Count) {
                        $selectedApps += $displayedApps[$index - 1]
                    } else {
                        Write-Host "Invalid selection: $index (must be between 1 and $($displayedApps.Count))" -ForegroundColor Red
                        throw "Invalid selection"
                    }
                }
                
                Write-Log -Level SUCCESS -Message "Selected $($selectedApps.Count) applications for publishing"
                return $selectedApps
            }
            catch {
                Write-Host "Invalid selection format. Please try again." -ForegroundColor Red
            }
        } while ($true)
    }
}

function Publish-RemoteAppApplications {
    <#
    .SYNOPSIS
        Publishes selected applications as RemoteApps in the specified Application Group
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$ApplicationGroupName,
        [Parameter(Mandatory = $true)]
        [array]$Applications,
        [string]$WorkspaceName
    )
    
    Write-Host "--- REMOTEAPP PUBLISHING ---" -ForegroundColor Yellow
    Write-Log -Level INFO -Message "Publishing $($Applications.Count) applications to $ResourceGroupName/$ApplicationGroupName"
    
    $publishedApps = @()
    $failedApps = @()
    
    foreach ($app in $Applications) {
        try {
            Write-Log -Level INFO -Message "Publishing: $($app.DisplayName)"
            
            # Use simple, clean application identifier (just the product name)
            $appId = if ($app.ApplicationIdentifier) { 
                ($app.ApplicationIdentifier -replace '_', '-')
            } else { 
                # Create clean identifier from display name
                ($app.DisplayName -replace '[^a-zA-Z0-9\s\-]', '' -replace '\s+', '-').Trim('-')
            }
            if ([string]::IsNullOrWhiteSpace($appId)) {
                $appId = "RemoteApp-" + (Get-Random -Minimum 1000 -Maximum 9999)
            }
            
            Write-Log -Level INFO -Message "Using Application Identifier (Name): '$appId' for '$($app.DisplayName)'"
            
            # Prepare RemoteApp parameters according to Microsoft documentation
            $appParams = @{
                ResourceGroupName = $ResourceGroupName
                ApplicationGroupName = $ApplicationGroupName
                Name = $appId  # Application identifier (unique)
                FilePath = $app.ApplicationPath  # Application path (.exe file)
                FriendlyName = $app.DisplayName  # Display name shown to users
                Description = $app.Description  # Application description
                ShowInPortal = $true
                CommandLineSetting = if ($app.RequireCommandLine) { 'Allow' } else { 'DoNotAllow' }
            }
            
            # Add command line arguments if required
            if ($app.RequireCommandLine -and ![string]::IsNullOrWhiteSpace($app.CommandLineArguments)) {
                $appParams.Add('CommandLineArguments', $app.CommandLineArguments)
            }
            
            # Handle Microsoft Store apps differently
            if ($app.Source -eq "Microsoft Store") {
                Write-Log -Level INFO -Message "Publishing Microsoft Store app: $($app.DisplayName)"
                # Store apps use shell:AppsFolder path format
            }
            
            if ($PSCmdlet.ShouldProcess("$ResourceGroupName/$ApplicationGroupName", "Publish RemoteApp '$($app.DisplayName)'")) {
                $result = New-AzWvdApplication @appParams
                
                $publishedApps += @{
                    Application = $app
                    Result = $result
                    Status = "Success"
                }
                
                Write-Log -Level SUCCESS -Message "Published: $($app.DisplayName)"
            } else {
                Write-Log -Level INFO -Message "Simulated publishing: $($app.DisplayName) (WhatIf mode)"
            }
        }
        catch {
            $failedApps += @{
                Application = $app
                Error = $_.Exception.Message
                Status = "Failed"
            }
            Write-Log -Level ERROR -Message "FAILED to publish $($app.DisplayName): $($_.Exception.Message)"
        }
    }
    
    # Assign to workspace if specified
    if (![string]::IsNullOrWhiteSpace($WorkspaceName) -and $publishedApps.Count -gt 0) {
        Write-Log -Level INFO -Message "Assigning Application Group to Workspace: $WorkspaceName"
        Write-Log -Level INFO -Message "NOTE: This will create a workspace assignment (no user assignments yet)"
        try {
            if ($PSCmdlet.ShouldProcess("$ResourceGroupName/$WorkspaceName", "Assign Application Group")) {
                Register-AzWvdApplicationGroup -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -ApplicationGroupPath "/subscriptions/$((Get-AzContext).Subscription.Id)/resourcegroups/$ResourceGroupName/providers/Microsoft.DesktopVirtualization/applicationGroups/$ApplicationGroupName"
                Write-Log -Level SUCCESS -Message "Application Group assigned to Workspace: $WorkspaceName"
                Write-Log -Level INFO -Message "You can now assign users/groups to this application group"
            }
        }
        catch {
            Write-Log -Level ERROR -Message "Failed to assign to workspace: $($_.Exception.Message)"
        }
    }
    
    # Display summary
    Write-Host "--- PUBLISHING SUMMARY ---" -ForegroundColor Green
    Write-Log -Level INFO -Message "Successfully Published: $($publishedApps.Count)"
    Write-Log -Level INFO -Message "Failed: $($failedApps.Count)"
    
    if ($publishedApps.Count -gt 0) {
        Write-Host "Successfully Published Applications:" -ForegroundColor Green
        foreach ($pub in $publishedApps) {
            Write-Host "  - $($pub.Application.DisplayName)" -ForegroundColor White
        }
    }
    
    if ($failedApps.Count -gt 0) {
        Write-Host "Failed Applications:" -ForegroundColor Red
        foreach ($fail in $failedApps) {
            Write-Host "  FAILED: $($fail.Application.DisplayName) - $($fail.Error)" -ForegroundColor Red
        }
    }
    
    return @{
        Published = $publishedApps
        Failed = $failedApps
        Total = $Applications.Count
    }
}

function Select-Workspace {
    <#
    .SYNOPSIS
        Allows selection or creation of a workspace for RemoteApp assignment
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        $Discovery
    )
    
    Write-Host "--- WORKSPACE SELECTION ---" -ForegroundColor Yellow
    Write-Host "Select workspace for RemoteApp assignment:" -ForegroundColor Cyan

    # Always refresh from Azure for the selected RG so menu data is accurate.
    $rgWorkspaces = @()
    try {
        $liveWorkspaces = @(Get-AzWvdWorkspace -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue)
        $rgWorkspaces = $liveWorkspaces | ForEach-Object {
            @{
                Name = Get-ResourceNameFromObject -Object $_
                ResourceGroup = $ResourceGroupName
                FriendlyName = Get-ResourceObjectPropertyValue -Object $_ -PropertyNames @('FriendlyName','DisplayName')
                Location = Get-ResourceObjectPropertyValue -Object $_ -PropertyNames @('Location')
            }
        }
    } catch {
        $rgWorkspaces = @()
    }

    if ($rgWorkspaces.Count -eq 0) {
        $rgWorkspaces = @($Discovery.Workspaces | Where-Object { $_.ResourceGroup -eq $ResourceGroupName })
    }

    $rgWorkspaces = @($rgWorkspaces | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })
    
    if ($rgWorkspaces.Count -gt 0) {
        Write-Host "Existing Workspaces in Resource Group:" -ForegroundColor Green
        for ($i = 0; $i -lt $rgWorkspaces.Count; $i++) {
            $ws = $rgWorkspaces[$i]
            Write-Host "  [$($i + 1)] $($ws.Name)" -ForegroundColor White
            if ($ws.FriendlyName) { Write-Host "      Friendly Name: $($ws.FriendlyName)" -ForegroundColor Gray }
            Write-Host "      Location: $($ws.Location)" -ForegroundColor Gray
        }
    }
    
    Write-Host "Options:" -ForegroundColor Yellow
    Write-Host "  [N] Create NEW workspace" -ForegroundColor Green
    Write-Host "  [S] Skip workspace assignment" -ForegroundColor Yellow
    Write-Host ""
    
    do {
        if ($rgWorkspaces.Count -gt 0) {
            $prompt = "Select workspace (1-$($rgWorkspaces.Count)), N for new, S to skip"
        } else {
            $prompt = "No existing workspaces. N for new, S to skip"
        }
        
        $choice = Read-Host $prompt
        
        if ($choice.ToUpper() -eq 'S') {
            Write-Log -Level INFO -Message "Skipping workspace assignment"
            return $null
        }
        
        if ($choice.ToUpper() -eq 'N') {
            $existingWsNames = $rgWorkspaces | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $suggestedWsName = Get-NextWorkspaceName -ResourceGroupName $ResourceGroupName -Discovery $Discovery

            Write-Host "Workspace Naming Examples:" -ForegroundColor Cyan
            if ($existingWsNames.Count -gt 0) {
                Write-Host "  Existing in this resource group:" -ForegroundColor Gray
                $existingWsNames | Select-Object -First 5 | ForEach-Object { Write-Host "    - $_" -ForegroundColor Gray }
            }
            Write-Host "  Suggested (next in sequence): $suggestedWsName" -ForegroundColor Gray

            do {
                $newWsName = Read-Host "Enter new workspace name (press Enter for '$suggestedWsName')"
                if ([string]::IsNullOrWhiteSpace($newWsName)) {
                    $newWsName = $suggestedWsName
                }
                if ([string]::IsNullOrWhiteSpace($newWsName)) {
                    Write-Host "Workspace name cannot be empty." -ForegroundColor Red
                    continue
                }
                if ($newWsName -match '^[a-z0-9][a-z0-9\-]{1,62}[a-z0-9]$') {
                    return $newWsName
                } else {
                    Write-Host "Invalid name. Use lowercase letters, numbers, and hyphens only (3-64 chars)." -ForegroundColor Red
                }
            } while ($true)
        }
        elseif ($rgWorkspaces.Count -gt 0 -and [int]::TryParse($choice, [ref]$null) -and [int]$choice -ge 1 -and [int]$choice -le $rgWorkspaces.Count) {
            $selectedWs = $rgWorkspaces[[int]$choice - 1]
            $wsName = if ($selectedWs -is [hashtable]) { $selectedWs.Name } else { $selectedWs.Name }
            Write-Host "Selected: $wsName" -ForegroundColor Green
            return $wsName
        }
        elseif ($rgWorkspaces.Count -gt 0) {
            $matchedByName = $rgWorkspaces | Where-Object { $_.Name -eq $choice } | Select-Object -First 1
            if ($matchedByName) {
                Write-Host "Selected: $($matchedByName.Name)" -ForegroundColor Green
                return $matchedByName.Name
            }
        }
        else {
            Write-Host "Invalid selection. Please try again." -ForegroundColor Red
        }
    } while ($true)
}

function Invoke-TestRemoteApp {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ResourceGroupName,
        [string]$ApplicationGroupName
    )
    
    if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
        $ResourceGroupName = Read-Host "Enter Resource Group name"
    }
    
    if ([string]::IsNullOrWhiteSpace($ApplicationGroupName)) {
        $ApplicationGroupName = Read-Host "Enter Application Group name"
    }
    
    Write-Log -Level INFO -Message "Ensuring Azure resources exist for deployment..."
    
    # Ensure resource group exists
    $rg = Initialize-ResourceGroup -ResourceGroupName $ResourceGroupName
    
    # Ensure application group (and host pool) exists
    $appGroup = Initialize-HostPoolAndApplicationGroup -ResourceGroupName $ResourceGroupName -ApplicationGroupName $ApplicationGroupName -Location $rg.Location -Discovery $null
    Write-Log -Level SUCCESS -Message "Azure resources initialized: RG=$($rg.ResourceGroupName), AG=$($appGroup.Name)"

    Write-Log -Level INFO -Message "Testing RemoteApp deployment to $ResourceGroupName/$ApplicationGroupName"
    
    $testApp = @{
        ResourceGroupName = $ResourceGroupName
        ApplicationGroupName = $ApplicationGroupName
        Name = "notepad-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        FilePath = "C:\Windows\System32\notepad.exe"
        FriendlyName = "Test Notepad"
        Description = "Test RemoteApp deployment"
        CommandLineSetting = "DoNotAllow"
        ShowInPortal = $true
    }
    
    try {
        if ($PSCmdlet.ShouldProcess("$ResourceGroupName/$ApplicationGroupName", "Deploy test RemoteApp")) {
            Write-Log -Level INFO -Message "Deploying test RemoteApp: $($testApp.Name)"
            
            $result = New-AzWvdApplication @testApp
            
            Write-Log -Level SUCCESS -Message "Test RemoteApp deployed successfully"
            Write-Log -Level INFO -Message "Application ID: $($result.Name)"
            
            return $result
        }
        else {
            Write-Log -Level INFO -Message "Test deployment skipped (WhatIf mode)"
            return $null
        }
    }
    catch {
        Write-Log -Level ERROR -Message "Test deployment failed: $($_.Exception.Message)"
        throw
    }
}

function Main {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    
    # Initialize required Azure modules before proceeding
    Initialize-RequiredModules
    
    Write-Host "--- AVD REMOTEAPP ENHANCED PUBLISHER ---" -ForegroundColor Yellow
    Write-Host "Enhanced with local application discovery, validation, and automated RemoteApp publishing" -ForegroundColor Cyan
    Write-Host ""
    
    # Step 1: Ensure Azure Authentication
    if (!(Test-AzureConnection)) {
        Write-Log -Level ERROR -Message "Azure connection required."
        return
    }
    
    # Step 2: Discover existing tenant resources
    $discovery = Get-TenantResourceDiscovery
    
    # Step 3: Local Application Discovery
    Write-Host "--- LOCAL APPLICATION DISCOVERY ---" -ForegroundColor Yellow
    Write-Host "Scanning this machine for applications that can be published as RemoteApps..." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Discovery Options:" -ForegroundColor Yellow
    Write-Host "  [1] Standard scan (recommended applications only)" -ForegroundColor White
    Write-Host "  [2] Extended scan (include Microsoft Store apps)" -ForegroundColor White
    Write-Host "  [3] Full scan (include system apps - advanced users)" -ForegroundColor White
    Write-Host ""
    
    do {
        $scanChoice = Read-Host "Select scan type (1-3)"
        switch ($scanChoice) {
            '1' { 
                $applications = Get-LocalApplications
                break
            }
            '2' { 
                $applications = Get-LocalApplications -IncludeStoreApps
                break
            }
            '3' { 
                $applications = Get-LocalApplications -IncludeStoreApps -IncludeSystemApps
                break
            }
            default { 
                Write-Host "Invalid selection. Please choose 1, 2, or 3." -ForegroundColor Red 
                continue
            }
        }
        break
    } while ($true)
    
    if ($applications.Count -eq 0) {
        Write-Log -Level WARN -Message "No suitable applications found for RemoteApp publishing"
        return
    }
    
    # Debug: Check what applications were discovered
    Write-Log -Level INFO -Message "Total applications discovered: $($applications.Count)"
    foreach ($app in $applications | Select-Object -First 3) {
        Write-Log -Level INFO -Message "Sample app - DisplayName: '$($app.DisplayName)', Path: '$($app.ApplicationPath)', Publisher: '$($app.Publisher)'"
    }
    
    # Step 4: Check Existing RemoteApps in Tenant
    Write-Host "--- TENANT REMOTEAPP ANALYSIS ---" -ForegroundColor Yellow
    Write-Host "Checking for existing RemoteApps in your tenant..." -ForegroundColor Cyan
    
    $existingRemoteApps = Get-ExistingRemoteApps -Discovery $discovery
    $comparisonData = Compare-DiscoveredWithExisting -DiscoveredApps $applications -ExistingApps $existingRemoteApps
    
    if ($existingRemoteApps.TotalFound -gt 0) {
        Write-Host ""
        Write-Host "Analysis Results:" -ForegroundColor Cyan
        Write-Host "  - Total existing RemoteApps found: $($existingRemoteApps.TotalFound)" -ForegroundColor White
        Write-Host "  - Application Groups scanned: $($existingRemoteApps.AppGroupsScanned)" -ForegroundColor White
        Write-Host "  - New applications (not published): $($comparisonData.NewApps.Count)" -ForegroundColor Green
        Write-Host "  - Already published: $($comparisonData.ExistingApps.Count)" -ForegroundColor Red
        Write-Host "  - Potential updates: $($comparisonData.PotentialUpdates.Count)" -ForegroundColor Yellow
        
        if ($comparisonData.NewApps.Count -eq 0) {
            Write-Host ""
            Write-Host "INFO: All discovered applications are already published as RemoteApps!" -ForegroundColor Yellow
            Write-Host "   You can still proceed to review existing applications or publish updates." -ForegroundColor Gray
        }
    } else {
        Write-Host "No existing RemoteApps found in tenant - all discovered applications are new" -ForegroundColor Green
        $comparisonData = $null
    }
    
    # Step 5: Application Selection (Enhanced with Comparison)
    $selectedApps = Show-ApplicationSelectionMenu -Applications $applications -ComparisonData $existingRemoteApps
    
    if ($selectedApps.Count -eq 0) {
        Write-Log -Level INFO -Message "No applications selected for publishing. Exiting."
        return
    }
    
    # Step 6: Command Line Configuration
    Write-Host "--- COMMAND LINE CONFIGURATION ---" -ForegroundColor Yellow
    $configureCommandLine = Read-Host "Configure command line arguments for selected applications? (Y/n)"
    
    if ($configureCommandLine.ToUpper() -ne 'N') {
        $selectedApps = Set-ApplicationCommandLine -Applications $selectedApps
    }
    
    # Step 7: Resource Group Selection (reuse existing or create new)
    $selectedRG = Select-ResourceGroup -Discovery $discovery -PreSelectedName $ResourceGroupName
    
    # Step 8: Application Group Selection (reuse existing or create new)  
    $selectedAG = Select-ApplicationGroup -ResourceGroupName $selectedRG -Discovery $discovery -PreSelectedName $ApplicationGroupName
    
    # Step 9: Workspace Selection (optional)
    $selectedWS = Select-Workspace -ResourceGroupName $selectedRG -Discovery $discovery
    
    Write-Host "--- DEPLOYMENT CONFIGURATION ---" -ForegroundColor Yellow
    Write-Log -Level INFO -Message "Target Resource Group: $selectedRG"
    Write-Log -Level INFO -Message "Target Application Group: $selectedAG"
    if ($selectedWS) {
        Write-Log -Level INFO -Message "Target Workspace: $selectedWS"
    } else {
        Write-Log -Level INFO -Message "Workspace: Not assigned"
    }
    Write-Log -Level INFO -Message "Applications to publish: $($selectedApps.Count)"
    
    # Step 10: Validation Summary
    Write-Host "--- APPLICATION VALIDATION SUMMARY ---" -ForegroundColor Yellow
    $validApps = $selectedApps | Where-Object { $_.IsValid }
    $invalidApps = $selectedApps | Where-Object { -not $_.IsValid }
    
    Write-Log -Level INFO -Message "Valid applications: $($validApps.Count)"
    Write-Log -Level INFO -Message "Applications with issues: $($invalidApps.Count)"
    
    if ($invalidApps.Count -gt 0) {
        Write-Host "Applications with validation issues:" -ForegroundColor Yellow
        foreach ($app in $invalidApps) {
            Write-Host "  WARNING: $($app.DisplayName)" -ForegroundColor Yellow
            $errors = $app.ValidationResults | Where-Object { $_ -like 'ERROR:*' }
            foreach ($errorMsg in $errors) {
                Write-Host "     $errorMsg" -ForegroundColor Red
            }
        }
        
        Write-Host ""
        $continue = Read-Host "Continue with publishing? Some applications may fail (y/N)"
        if ($continue.ToUpper() -ne 'Y') {
            Write-Log -Level INFO -Message "Publishing cancelled by user"
            return
        }
    }
    
    # Step 11: Ensure all required Azure resources exist
    try {
        Write-Log -Level INFO -Message "Validating and ensuring Azure resources exist..."
        
        # Initialize resource group
        $rg = Initialize-ResourceGroup -ResourceGroupName $selectedRG
        
        # Initialize application group (and host pool)
        $appGroup = Initialize-HostPoolAndApplicationGroup -ResourceGroupName $selectedRG -ApplicationGroupName $selectedAG -Location $rg.Location -Discovery $discovery
        Write-Log -Level SUCCESS -Message "Target resources validated: RG=$($rg.ResourceGroupName), AG=$($appGroup.Name)"
        
        # Initialize workspace if specified
        if ($selectedWS) {
            try {
                $workspace = Get-AzWvdWorkspace -ResourceGroupName $selectedRG -Name $selectedWS -ErrorAction SilentlyContinue
                if ($null -eq $workspace) {
                    Write-Log -Level INFO -Message "Creating workspace: $selectedWS"
                    $workspace = New-AzWvdWorkspace -ResourceGroupName $selectedRG -Name $selectedWS -Location $rg.Location
                    Write-Log -Level SUCCESS -Message "Workspace created: $($workspace.Name)"
                } else {
                    Write-Log -Level SUCCESS -Message "Using existing workspace: $($workspace.Name)"
                }
            }
            catch {
                Write-Log -Level ERROR -Message "Failed to ensure workspace: $($_.Exception.Message)"
                $selectedWS = $null
            }
        }
        
        Write-Log -Level SUCCESS -Message "All required Azure resources validated and ready"
        
        # Step 12: Publish RemoteApps
        Write-Host "--- REMOTEAPP PUBLISHING ---" -ForegroundColor Yellow
        Write-Host "Publishing $($selectedApps.Count) applications as RemoteApps..." -ForegroundColor Cyan
        
        if ($PSCmdlet.ShouldProcess("$selectedRG/$selectedAG", "Publish $($selectedApps.Count) RemoteApps")) {
            $publishResults = Publish-RemoteAppApplications -ResourceGroupName $selectedRG -ApplicationGroupName $selectedAG -Applications $selectedApps -WorkspaceName $selectedWS
            
            Write-Host "--- DEPLOYMENT SUCCESS ---" -ForegroundColor Green
            Write-Log -Level SUCCESS -Message "RemoteApp publishing completed!"
            Write-Log -Level INFO -Message "Resource Group: $selectedRG"
            Write-Log -Level INFO -Message "Application Group: $selectedAG"
            if ($selectedWS) {
                Write-Log -Level INFO -Message "Workspace: $selectedWS"
            }
            Write-Log -Level INFO -Message "Successfully Published: $($publishResults.Published.Count) applications"
            Write-Log -Level INFO -Message "Failed: $($publishResults.Failed.Count) applications"
            
            Write-Host "Next Steps:" -ForegroundColor Cyan
            Write-Host "- Assign users/groups to the application group in Azure Portal" -ForegroundColor White
            Write-Host "- Configure conditional access policies if needed" -ForegroundColor White  
            Write-Host "- Ensure session hosts are available and running in the host pool" -ForegroundColor White
            Write-Host "- Test RemoteApp access through Windows App or web client" -ForegroundColor White
            Write-Host "- Monitor application performance and usage" -ForegroundColor White
            
            return $publishResults
        }
        else {
            Write-Log -Level INFO -Message "Publishing simulation completed (WhatIf mode)"
            return $null
        }
    }
    catch {
        Write-Log -Level ERROR -Message "Deployment failed: $($_.Exception.Message)"
        Write-Log -Level ERROR -Message "Stack trace: $($_.ScriptStackTrace)"
        throw
    }
    
    Write-Log -Level SUCCESS -Message "Enhanced AVD RemoteApp Publisher completed successfully"
}

function Disconnect-AzureSession {
    <#
    .SYNOPSIS
        Safely disconnects Azure session and unloads modules loaded by this script
    #>
    try {
        Write-Host "--- SECURITY CLEANUP ---" -ForegroundColor Yellow

        # Disconnect Azure session
        if (Get-Command -Name Get-AzContext -ErrorAction SilentlyContinue) {
            $context = Get-AzContext -ErrorAction SilentlyContinue
            if ($null -ne $context) {
                Write-Log -Level INFO -Message "Disconnecting Azure session: $($context.Account)"
                if (Get-Command -Name Disconnect-AzAccount -ErrorAction SilentlyContinue) {
                    Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
                }
                Write-Log -Level SUCCESS -Message "Azure session disconnected successfully"
            } else {
                Write-Log -Level INFO -Message "No active Azure session to disconnect"
            }
        } else {
            Write-Log -Level INFO -Message "Az.Accounts cmdlets not available; skipping disconnect"
        }

        # Unload only the modules this script loaded (leave pre-existing modules alone)
        if ($script:_bootstrapLoadedModules -and $script:_bootstrapLoadedModules.Count -gt 0) {
            foreach ($_m in ($script:_bootstrapLoadedModules | Select-Object -Unique)) {
                if (Get-Module -Name $_m -ErrorAction SilentlyContinue) {
                    Remove-Module -Name $_m -Force -ErrorAction SilentlyContinue
                    Write-Log -Level DEBUG -Message "Unloaded module: $_m"
                }
            }
        }
    }
    catch {
        Write-Log -Level WARN -Message "Cleanup warning: $($_.Exception.Message)"
    }
}

# Execute if not dot-sourced
if ($MyInvocation.InvocationName -ne '.') {
    try {
        [void](Main)
    }
    finally {
        # Always disconnect, even if script fails
        Disconnect-AzureSession
    }
}

