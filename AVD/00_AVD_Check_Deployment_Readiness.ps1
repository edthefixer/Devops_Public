#Requires -Version 5.1

<#
.SYNOPSIS
    00_AVD_Check_Deployment_Readiness.ps1 - Azure Virtual Desktop deployment readiness check (standalone).
    Read-only. No resources are created, modified, or deleted.
    All validation functions are self-contained - no external module file required.

.DESCRIPTION
    A self-contained PowerShell readiness assessment tool that validates every
    prerequisite needed to successfully deploy Azure Virtual Desktop (AVD) in any
    tenant and subscription. The script is entirely read-only: it never creates,
    modifies, or deletes any Azure resource.

    HOW IT WORKS
    ------------
    When run interactively, a guided setup wizard walks the operator through every
    configuration choice (region, VM SKU, identity model, authentication method, and
    report options) before the assessment starts. All settings can also be supplied
    directly as parameters to skip the wizard and run non-interactively (e.g. from
    a CI/CD pipeline or automation script).

    WHAT IT VALIDATES  (15 sequential check areas)
    -----------------------------------------------
        1  PowerShell environment (version, required Az modules)
        2  Azure sign-in
        3  Subscription and tenant status
        4  Resource provider registration (8 required, 3 recommended)
        5  Entra ID tenant requirements, for every identity model (AVD service
           principal, single sign-on service principal, Conditional Access review)
        6  RBAC role assessment (current user + what is needed for deployment)
        7  Network configuration (VNet, subnets, NSG, DNS, routes, peering)
        8  AVD endpoint connectivity (TCP tests to required Microsoft FQDNs)
        9  Compute quota and VM SKU availability in the target region
        10 Storage / FSLogix readiness (identity auth, TLS, SMB port 445)
        11 Identity model-specific checks:
                 ADDS            - Active Directory DNS and LDAP connectivity
                 EntraID         - Entra join: the Virtual Machine User Login role
                                   (host pools without an Entra sign-in RDP
                                   property are also flagged in area 14)
                 EntraIDKerberos - Hybrid Kerberos / Entra Connect sync validation
                 EntraDS         - Microsoft Entra Domain Services readiness
        12 Monitoring readiness (Log Analytics workspace)
        13 Key Vault security settings
        14 Existing AVD resource health (host pools, SSO configuration,
           application groups and their user assignments)
        15 Azure Compute Gallery and session host image readiness

    SIGN-IN
    -------
    By default the script uses the Azure PowerShell session you already have
    (Connect-AzAccount). Choosing Interactive or DeviceCode sign-in first signs
    out the account Azure PowerShell currently holds on this computer.

    RESULTS FORMAT
    --------------
    Every check produces one of: PASS / FAIL / WARN / INFO / SKIP.
    Every FAIL result includes:
        - WHY it is a deployment blocker (Roadblock)
        - HOW to fix it (exact PowerShell commands or portal steps)
        - A link to the relevant Microsoft documentation

    REPORTS
    -------
    Every run writes a timestamped Excel report to -ReportPath (default: the
    script's folder), unless -NoExport is given. The workbook contains every
    check result with all Roadblock and HowToFix fields, making it easy to share
    with other teams or to track remediation progress.

    AUTOMATION / PIPELINE USE
    -------------------------
    Use -PassThru to return a structured PSCustomObject at exit that contains
    Results[], FailCount, WarnCount, and PassCount. This makes it straightforward
    to consume the output from an automation script or orchestration pipeline.
    Use -NonInteractive for unattended execution.

    STANDALONE
    ----------
    This script has no external dependencies beyond the Az PowerShell modules.
    All validation logic is embedded directly - distribute this single .ps1 file
    without any additional module or library files.

.PARAMETER SubscriptionId
    The Azure Subscription ID to validate. Defaults to the current context.

.PARAMETER TenantId
    Azure Tenant ID. Required with -NonInteractive for ServicePrincipalSecret and
    ServicePrincipalCertificate; for other sign-in methods it selects the tenant to sign in to.

.PARAMETER TargetRegion
    The Azure region where AVD will be deployed (e.g. 'eastus2', 'westeurope').
    Used for quota checks and VNet scoping.

.PARAMETER VmSku
    VM SKU to validate quota and availability for. Default: Standard_D4s_v5.

.PARAMETER PlannedSessionHosts
    Number of session hosts planned. Used to provide context in quota reports.

.PARAMETER DomainName
    Active Directory domain FQDN (e.g. 'contoso.local'). Required for ADDS checks.

.PARAMETER IdentityModel
    Identity model for session hosts:
    ADDS            = Active Directory Domain Services (classic domain-join + hybrid AAD join)
    EntraID         = Microsoft Entra join only; AD DS / Entra DS checks are not required
    EntraIDKerberos = Hybrid identity with Microsoft Entra Kerberos for Azure Files
    EntraDS         = Microsoft Entra Domain Services (managed domain)
    All             = Run every identity check (default)

.PARAMETER SkipConnectivityTests
    Skip the TCP reachability tests to the required AVD endpoints.

.PARAMETER SkipADValidation
    Skip the Active Directory DNS and LDAP checks.

.PARAMETER ResourceGroupName
    Resource group to scope the network, storage, monitoring, Key Vault, AVD
    resource and image checks to. Defaults to the whole subscription.

.PARAMETER VNetName
    Virtual network to validate. Used with -ResourceGroupName.

.PARAMETER SubnetName
    Subnet the session hosts will use. Only virtual networks containing it are checked.

.PARAMETER StorageAccountName
    Storage account for FSLogix profiles. Used with -ResourceGroupName.

.PARAMETER NonInteractive
    Skip the setup wizard and every prompt. Supply the settings as parameters.

.PARAMETER AuthMethod
    How to sign in to Azure:
    ExistingContext             = Use the current Az session (default)
    Interactive                 = Browser sign-in
    DeviceCode                  = Device code sign-in
    ServicePrincipalSecret      = App registration with a client secret (-ServicePrincipalCredential)
    ServicePrincipalCertificate = App registration with a certificate (-ApplicationId, -CertificateThumbprint)
    ManagedIdentity             = The managed identity of the machine running the script

.PARAMETER ApplicationId
    Application (client) ID for ServicePrincipalCertificate sign-in.

.PARAMETER CertificateThumbprint
    Certificate thumbprint for ServicePrincipalCertificate sign-in.

.PARAMETER ServicePrincipalCredential
    Application ID and client secret as a PSCredential, for ServicePrincipalSecret sign-in.

.PARAMETER ReportPath
    Folder for the Excel report. Defaults to the script's own folder.

.PARAMETER ExportReport
    Accepted for compatibility. The Excel report is always written unless -NoExport is given.

.PARAMETER CriticalOnly
    Show failures only in the console summary; warnings are left out.

.PARAMETER PassThru
    Return a PSCustomObject with Results, FailCount, WarnCount and PassCount.

.PARAMETER NoExport
    Never write a report file, including the automatic one at exit.

.PARAMETER SkipModuleValidation
    Skip the Az module check and temporary module loading. Use only when the
    required Az modules are already imported.

.EXAMPLE
    .\00_AVD_Check_Deployment_Readiness.ps1
    Runs the setup wizard, then the full assessment.

.EXAMPLE
    .\00_AVD_Check_Deployment_Readiness.ps1 -SubscriptionId <subscription-id> -TargetRegion eastus2 -IdentityModel EntraID -NonInteractive -ExportReport
    Runs unattended against one subscription and writes the Excel report.

.EXAMPLE
    $r = .\00_AVD_Check_Deployment_Readiness.ps1 -NonInteractive -PassThru -NoExport
    if ($r.FailCount -gt 0) { throw 'AVD deployment blockers found' }
    Uses the result in a pipeline. Use -NonInteractive -ExportReport for unattended / pipeline execution.

.NOTES
    Author: etf
#>

[CmdletBinding(SupportsShouldProcess=$false)]
param(
    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$TargetRegion,

    [string]$VmSku = 'Standard_D4s_v5',
    [ValidateRange(1, 10000)]
    [int]$PlannedSessionHosts = 10,

    [string]$DomainName,

    [ValidateSet('ADDS','EntraID','EntraIDKerberos','EntraDS','All')]
    [string]$IdentityModel = 'All',

    [switch]$SkipConnectivityTests,
    [switch]$SkipADValidation,

    [string]$ResourceGroupName,
    [string]$VNetName,
    [string]$SubnetName,
    [string]$StorageAccountName,

    [switch]$NonInteractive,

    [ValidateSet('ExistingContext','Interactive','DeviceCode','ServicePrincipalSecret','ServicePrincipalCertificate','ManagedIdentity')]
    [string]$AuthMethod = 'ExistingContext',

    [string]$ApplicationId,
    [string]$CertificateThumbprint,
    [System.Management.Automation.PSCredential]$ServicePrincipalCredential,

    [string]$ReportPath = $(if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }),

    [switch]$ExportReport,
    [switch]$CriticalOnly,
    [switch]$PassThru,
    [switch]$NoExport,
    [switch]$SkipModuleValidation
)

Set-StrictMode -Off   # Disabled to preserve PS5.1 broad compatibility with optional properties
$ErrorActionPreference = 'Continue'

# ======================================================================
# AVD Module Preflight - Session-scoped ephemeral module loading
# ======================================================================
# Embedded so this script can be distributed as a single file.
# Missing modules are saved under $env:TEMP, imported for this run, then removed.
$env:PSModulePath = (($env:PSModulePath -split [IO.Path]::PathSeparator) |
    Where-Object { $_ -and $_ -notmatch '(?:^|[\\/])_modules(?:[\\/]|$)' }) -join [IO.Path]::PathSeparator
$script:AVDTempPath = $null
$script:AVDTempModuleNames = [System.Collections.Generic.List[string]]::new()
$script:AVDImportedModuleNames = [System.Collections.Generic.List[string]]::new()

function Get-AVDModuleTempPath {
    if (-not $script:AVDTempPath) {
        $script:AVDTempPath = Join-Path $env:TEMP ("AVD_TempMod_{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:AVDTempPath -Force -ErrorAction Stop | Out-Null
    }
    return $script:AVDTempPath
}

function Resolve-AVDBestLocalModule {
    param(
        [Parameter(Mandatory=$true)] [string]$Name,
        [version]$MinimumVersion = [version]'0.0'
    )

    return Get-Module -Name $Name -ListAvailable -ErrorAction SilentlyContinue |
        Where-Object { $_.ModuleBase -notmatch '(?:^|[\\/])_modules(?:[\\/]|$)' -and $_.Version -ge $MinimumVersion } |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

function Invoke-AVDModulePreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable[]]$Modules
    )

    $script:AVDTempPath = $null
    $script:AVDTempModuleNames = [System.Collections.Generic.List[string]]::new()
    $script:AVDImportedModuleNames = [System.Collections.Generic.List[string]]::new()

    Write-Host ''
    Write-Host ('=' * 100) -ForegroundColor White
    Write-Host 'Validating Azure modules installation' -ForegroundColor White
    Write-Host ('=' * 100) -ForegroundColor White
    Write-Host ''

    # Modules staged by an earlier run stay loaded until its window closes, so that run
    # cannot delete them. Remove those folders now. A rename fails while another window
    # still has the modules loaded, so only folders that can be renamed are deleted.
    Get-ChildItem -Path $env:TEMP -Directory -Filter 'AVD_TempMod_*' -ErrorAction SilentlyContinue | ForEach-Object {
        $staleName = Join-Path $env:TEMP ('AVD_Stale_{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        try { Rename-Item -LiteralPath $_.FullName -NewName (Split-Path $staleName -Leaf) -ErrorAction Stop } catch { return }
        Remove-Item -LiteralPath $staleName -Recurse -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem -Path $env:TEMP -Directory -Filter 'AVD_Stale_*' -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

    $originalPSModulePath = $env:PSModulePath
    $resolvedPaths = @{}
    $needFetch = [System.Collections.Generic.List[string]]::new()

    foreach ($moduleRequirement in $Modules) {
        $moduleName = [string]$moduleRequirement.Name
        $minimumVersion = if ($moduleRequirement.MinVersion) { [version]$moduleRequirement.MinVersion } else { [version]'0.0' }
        $foundModule = Resolve-AVDBestLocalModule -Name $moduleName -MinimumVersion $minimumVersion

        if ($foundModule) {
            $resolvedPaths[$moduleName] = $foundModule.Path
            Write-Host ("Module Check - Pass: Module already available: {0} (Version: {1})" -f $moduleName, $foundModule.Version) -ForegroundColor Green
        } else {
            Write-Host ("Module Check - Info: Fetching {0} {1}+ to temporary storage" -f $moduleName, $minimumVersion) -ForegroundColor Yellow
            [void]$needFetch.Add($moduleName)
        }
    }

    if ($needFetch.Count -gt 0) {
        if (-not (Get-Command -Name Save-Module -ErrorAction SilentlyContinue)) {
            throw ("Save-Module is unavailable to fetch {0}. Install or update PowerShellGet, or install the module, then rerun this script." -f ($needFetch -join ', '))
        }
        $tempPath = Get-AVDModuleTempPath
        foreach ($moduleName in $needFetch) {
            try {
                $moduleRequirement = $Modules | Where-Object { [string]$_.Name -eq $moduleName } | Select-Object -First 1
                $minimumVersion = if ($moduleRequirement.MinVersion) { [version]$moduleRequirement.MinVersion } else { [version]'0.0' }
                Save-Module -Name $moduleName -MinimumVersion $minimumVersion -Path $tempPath -Force -ErrorAction Stop
                $manifest = Get-ChildItem -Path (Join-Path $tempPath $moduleName) -Filter "$moduleName.psd1" -Recurse -ErrorAction SilentlyContinue |
                    Sort-Object {
                        try { [version]$_.Directory.Name } catch { [version]'0.0' }
                    } -Descending |
                    Select-Object -First 1

                if (-not $manifest) {
                    throw "Module manifest not found after Save-Module completed."
                }

                $resolvedPaths[$moduleName] = $manifest.FullName
                [void]$script:AVDTempModuleNames.Add($moduleName)
                Write-Host ("Module Check - Pass: Fetched to temporary storage: {0} (Version: {1})" -f $moduleName, $manifest.Directory.Name) -ForegroundColor Green
            } catch {
                throw ("Module Fetch - Fail [{0}]: {1}" -f $moduleName, $_.Exception.Message)
            }
        }
    }

    if ($script:AVDTempPath) {
        $env:PSModulePath = @($script:AVDTempPath, $originalPSModulePath) -join ';'
    }

    return [PSCustomObject]@{
        Success = $true
        TempPath = $script:AVDTempPath
        OriginalPSModulePath = $originalPSModulePath
        TempModuleNames = $script:AVDTempModuleNames.ToArray()
        ImportedModuleNames = $script:AVDImportedModuleNames.ToArray()
    }
}

function Invoke-AVDModuleCleanup {
    [CmdletBinding()]
    param([PSCustomObject]$PreflightResult)

    if (-not $PreflightResult) { return }

    if ($PreflightResult.PSObject.Properties.Name -contains 'OriginalPSModulePath') {
        $env:PSModulePath = $PreflightResult.OriginalPSModulePath
    }

    $importedModuleNames = @($PreflightResult.ImportedModuleNames)
    $hasTempPath = $PreflightResult.TempPath -and (Test-Path -LiteralPath $PreflightResult.TempPath)
    if ($importedModuleNames.Count -eq 0 -and -not $hasTempPath) { return }

    Write-Host ''
    Write-Host ('=' * 100) -ForegroundColor DarkGray
    Write-Host 'Module cleanup - unloading modules imported by this run' -ForegroundColor DarkGray
    Write-Host ('=' * 100) -ForegroundColor DarkGray

    for ($moduleIndex = $importedModuleNames.Count - 1; $moduleIndex -ge 0; $moduleIndex--) {
        $moduleName = $importedModuleNames[$moduleIndex]
        Remove-Module -Name $moduleName -Force -ErrorAction SilentlyContinue
        Write-Host ("Module Unload - Pass: Removed from session: {0}" -f $moduleName) -ForegroundColor DarkGray
    }

    if ($hasTempPath) {
        Remove-Item -LiteralPath $PreflightResult.TempPath -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $PreflightResult.TempPath) {
            Write-Host ("Temp Cleanup - Info: Modules in {0} stay in use until this window closes; the next run deletes them." -f $PreflightResult.TempPath) -ForegroundColor DarkGray
        } else {
            Write-Host ("Temp Cleanup - Pass: Deleted temporary folder: {0}" -f $PreflightResult.TempPath) -ForegroundColor DarkGray
        }
    }

    $PreflightResult.ImportedModuleNames = @()
    $PreflightResult.TempModuleNames = @()
    $PreflightResult.TempPath = $null
    Write-Host ''
}

$preflight_Modules = @(
    @{ Name = 'Az.Accounts'; MinVersion = '2.12.0'; Required = $true }
    @{ Name = 'Az.Compute'; MinVersion = '7.0.0'; Required = $true }
    @{ Name = 'Az.Resources'; MinVersion = '6.0.0'; Required = $true }
    @{ Name = 'Az.DesktopVirtualization'; MinVersion = '3.0.0'; Required = $true }
    @{ Name = 'Az.Network'; MinVersion = '5.0.0'; Required = $true }
    @{ Name = 'Az.Storage'; MinVersion = '5.0.0'; Required = $true }
    @{ Name = 'Az.KeyVault'; MinVersion = '4.0.0'; Required = $true }
    @{ Name = 'ImportExcel'; MinVersion = '7.0.0'; Required = $true }
)

$preflight_Result = $null
if (-not $SkipModuleValidation) {
    $preflight_Result = Invoke-AVDModulePreflight -Modules $preflight_Modules
}

trap {
    Invoke-AVDModuleCleanup -PreflightResult $preflight_Result
    throw $_
}
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Invoke-AVDModuleCleanup -PreflightResult $preflight_Result
} -ErrorAction SilentlyContinue

# Always export reports to the script root using the script file name.
$script:ReportRootPath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:ReportScriptName = $env:AVD_REPORT_SCRIPT_NAME
if ([string]::IsNullOrWhiteSpace($script:ReportScriptName)) {
    $script:ReportScriptName = if ($PSCommandPath) { [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath) } else { [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name) }
}
$script:ReportExported = $false
$script:RecoveredByChildProcess = $false

# ==============================================================================
# EMBEDDED VALIDATION LIBRARY
# Extracted from AVD_Validation_Library.psm1 - all 24 functions inline
# ==============================================================================

#region -- Module-Level State --------------------------------------------------

$script:ValidationResults = [System.Collections.Generic.List[object]]::new()
$script:TotalChecks  = 0
$script:PassCount    = 0
$script:FailCount    = 0
$script:WarnCount    = 0
$script:SkipCount    = 0
$script:InfoCount    = 0

#endregion

#region -- Logging & Reporting -------------------------------------------------

function Write-AVDLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('INFO','PASS','FAIL','WARN','SKIP','SECTION')]
        [string]$Level,

        [Parameter(Mandatory=$true)]
        [string]$Message
    )

    $colorMap = @{
        INFO    = 'Cyan'
        PASS    = 'Green'
        FAIL    = 'Red'
        WARN    = 'Yellow'
        SKIP    = 'DarkGray'
        SECTION = 'White'
    }

    $paddedLevel = switch ($Level) {
        'INFO'    { ' INFO  ' }
        'PASS'    { ' PASS  ' }
        'FAIL'    { ' FAIL  ' }
        'WARN'    { ' WARN  ' }
        'SKIP'    { ' SKIP  ' }
        'SECTION' { 'SECTION' }
    }

    $ts   = Get-Date -Format 'HH:mm:ss'
    $line = "[$ts][$paddedLevel] $Message"
    Write-Host $line -ForegroundColor $colorMap[$Level]
}

function Write-AVDSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Title
    )
    $bar = '-' * 78
    Write-Host ''
    Write-Host $bar         -ForegroundColor White
    Write-Host "  $Title"  -ForegroundColor White
    Write-Host $bar         -ForegroundColor White
}

function Add-AVDCheckResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Category,
        [Parameter(Mandatory=$true)] [string]$CheckName,
        [Parameter(Mandatory=$true)]
        [ValidateSet('PASS','FAIL','WARN','INFO','SKIP')]
        [string]$Result,
        [Parameter(Mandatory=$true)] [string]$Details,
        [string]$Roadblock = '',
        [string]$HowToFix  = '',
        [string]$DocLink   = ''
    )

    $script:TotalChecks++
    switch ($Result) {
        'PASS' { $script:PassCount++ }
        'FAIL' { $script:FailCount++ }
        'WARN' { $script:WarnCount++ }
        'SKIP' { $script:SkipCount++ }
        'INFO' { $script:InfoCount++ }
    }

    $entry = [PSCustomObject]@{
        Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Category  = $Category
        CheckName = $CheckName
        Result    = $Result
        Details   = $Details
        Roadblock = $Roadblock
        HowToFix  = $HowToFix
        DocLink   = $DocLink
    }
    $script:ValidationResults.Add($entry)

    $logLevel = if ($Result -eq 'INFO') { 'INFO' } else { $Result }
    Write-AVDLog -Level $logLevel -Message "[$Category] $CheckName"
    Write-Host "           $Details" -ForegroundColor Gray

    if ($Result -eq 'FAIL' -and $Roadblock) {
        Write-Host "           ROADBLOCK : $Roadblock" -ForegroundColor Red
    }
    if (($Result -eq 'FAIL' -or $Result -eq 'WARN') -and $HowToFix) {
        Write-Host "           HOW TO FIX: $HowToFix" -ForegroundColor Yellow
    }
    if ($DocLink) {
        Write-Host "           DOC LINK  : $DocLink" -ForegroundColor DarkCyan
    }
}

function Reset-AVDValidationState {
    [CmdletBinding()]
    param()
    $script:ValidationResults = [System.Collections.Generic.List[object]]::new()
    $script:TotalChecks = 0
    $script:PassCount   = 0
    $script:FailCount   = 0
    $script:WarnCount   = 0
    $script:SkipCount   = 0
    $script:InfoCount   = 0
}

function Get-AVDValidationSummary {
    [CmdletBinding()]
    param()
    return [PSCustomObject]@{
        TotalChecks = $script:TotalChecks
        PassCount   = $script:PassCount
        FailCount   = $script:FailCount
        WarnCount   = $script:WarnCount
        SkipCount   = $script:SkipCount
        InfoCount   = $script:InfoCount
        Results     = $script:ValidationResults.ToArray()
    }
}

function Export-AVDValidationReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$OutputPath,
        [switch]$IncludePassedChecks,
        [switch]$IncludeInfoChecks
    )

    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $excelPath = Join-Path $OutputPath ("$($script:ReportScriptName)_$ts.xlsx")

    $all = $script:ValidationResults.ToArray()

    $all | Export-Excel -Path $excelPath -WorksheetName 'Validation Results' -AutoSize -FreezeTopRow -BoldTopRow

    return [PSCustomObject]@{ ExcelPath = $excelPath }
}

#endregion

#region -- Module Management ---------------------------------------------------

function Test-AVDModuleAvailability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable[]]$Modules
    )

    Write-AVDSection -Title 'POWERSHELL MODULE AVAILABILITY'

    foreach ($mod in $Modules) {
        $name       = $mod.Name
        $minVer     = if ($mod.MinVersion) { $mod.MinVersion } else { '0.0.0' }
        $isRequired = if ($null -ne $mod.Required) { [bool]$mod.Required } else { $true }

        try {
            # Tier 1: already loaded in this PowerShell session
            $installed = Get-Module -Name $name -ErrorAction SilentlyContinue |
                         Sort-Object Version -Descending | Select-Object -First 1

            # Tier 2: available on PSModulePath  +  Windows PS5 fallback paths
            # (PS7 does not include the PS5 user/system module dirs by default)
            if ($null -eq $installed) {
                $ps5Paths = @(
                    (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'),
                    'C:\Program Files\WindowsPowerShell\Modules'
                )
                $origPSModPath = $env:PSModulePath
                $expandedPaths = (($env:PSModulePath -split ';') + $ps5Paths |
                                  Where-Object { $_ } | Select-Object -Unique) -join ';'
                $env:PSModulePath = $expandedPaths
                try {
                    $installed = Get-Module -Name $name -ListAvailable -ErrorAction SilentlyContinue |
                                 Where-Object { $_.ModuleBase -notmatch '(?:^|[\\/])_modules(?:[\\/]|$)' } |
                                 Sort-Object Version -Descending | Select-Object -First 1
                } finally {
                    $env:PSModulePath = $origPSModPath
                }
            }

            if ($null -eq $installed) {
                if ($isRequired) {
                    Add-AVDCheckResult `
                        -Category 'Modules' `
                        -CheckName "Module: $name" `
                        -Result 'FAIL' `
                        -Details "Not installed" `
                        -Roadblock "The Az module '$name' is required to query Azure resources. Validation checks that depend on it cannot run without it." `
                        -HowToFix "Rerun with network access so '$name' can be staged temporarily." `
                        -DocLink 'https://learn.microsoft.com/powershell/azure/install-az-ps'
                } else {
                    Add-AVDCheckResult `
                        -Category 'Modules' `
                        -CheckName "Module: $name (optional)" `
                        -Result 'WARN' `
                        -Details "Not installed  -  checks requiring this module will be skipped" `
                        -HowToFix "Rerun with network access so '$name' can be staged temporarily."
                }
            } else {
                $vOk = [System.Version]$installed.Version -ge [System.Version]$minVer
                if (-not $vOk) {
                    Add-AVDCheckResult `
                        -Category 'Modules' `
                        -CheckName "Module: $name" `
                        -Result 'WARN' `
                        -Details "Version $($installed.Version) installed; $minVer+ recommended" `
                        -HowToFix "Update-Module -Name '$name' -Force"
                } else {
                    Add-AVDCheckResult `
                        -Category 'Modules' `
                        -CheckName "Module: $name" `
                        -Result 'PASS' `
                        -Details "Version $($installed.Version) installed"
                }
            }
        } catch {
            Add-AVDCheckResult `
                -Category 'Modules' `
                -CheckName "Module: $name" `
                -Result 'WARN' `
                -Details "Error checking module: $($_.Exception.Message)"
        }
    }
}

function Import-AVDRequiredModulesToMemory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable[]]$Modules
    )

    if (-not $script:ModulesLoadedByThisScript) {
        $script:ModulesLoadedByThisScript = New-Object 'System.Collections.Generic.List[string]'
    }

    # IMPORTANT: Do NOT call Remove-Module on Az modules before importing.
    # Removing PS module objects leaves their .NET assemblies in the AppDomain.
    # A subsequent Import-Module then fails with "Assembly with same name is already loaded"
    # and the session cannot recover without a fresh process.
    # Correct pattern: skip if already loaded (guard below); import if not loaded.

    foreach ($mod in $Modules) {
        $name       = $mod.Name
        $isRequired = if ($null -ne $mod.Required) { [bool]$mod.Required } else { $true }
        if (-not $isRequired) { continue }

        # Module already loaded in this session — accept as-is, no reimport needed.
        if (Get-Module -Name $name -ErrorAction SilentlyContinue) { continue }

        # Resolve on-disk install path; extend search to PS5 module dirs for PS7 sessions.
        $installed = Get-Module -Name $name -ListAvailable -ErrorAction SilentlyContinue |
                     Where-Object { $_.ModuleBase -notmatch '(?:^|[\\/])_modules(?:[\\/]|$)' } |
                     Sort-Object Version -Descending | Select-Object -First 1

        if ($null -eq $installed) {
            $ps5Paths = @(
                (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'),
                'C:\Program Files\WindowsPowerShell\Modules'
            )
            $origPSModPath = $env:PSModulePath
            $expandedPaths = (($env:PSModulePath -split ';') + $ps5Paths |
                              Where-Object { $_ } | Select-Object -Unique) -join ';'
            $env:PSModulePath = $expandedPaths
            try {
                $installed = Get-Module -Name $name -ListAvailable -ErrorAction SilentlyContinue |
                             Where-Object { $_.ModuleBase -notmatch '(?:^|[\\/])_modules(?:[\\/]|$)' } |
                             Sort-Object Version -Descending | Select-Object -First 1
            } finally {
                $env:PSModulePath = $origPSModPath
            }
        }

        if ($null -eq $installed) {
            throw "Required module '$name' was validated but could not be resolved for import."
        }

        try {
            if ($installed.Path) {
                Import-Module -Name $installed.Path -Global -ErrorAction Stop -WarningAction SilentlyContinue
            } else {
                Import-Module -Name $name -Global -ErrorAction Stop -WarningAction SilentlyContinue
            }
            [void]$script:ModulesLoadedByThisScript.Add($name)
        } catch {
            $importErr = $_
            # Module may have landed in session despite the throw (PS ALC edge case).
            if (Get-Module -Name $name -ErrorAction SilentlyContinue) {
                [void]$script:ModulesLoadedByThisScript.Add($name)
                continue
            }
            # Assembly collision: a prior script called Remove-Module Az.* in this process,
            # leaving .NET assemblies orphaned in the AppDomain. Try a name-only import
            # — PowerShell may reuse the already-loaded assembly version.
            if ($importErr.Exception.Message -match 'Assembly with same name is already loaded|Microsoft\.Azure\.PowerShell\.AssemblyLoading|requires Az\.Accounts version|earlier version of Az\.Accounts is imported|multiple incompatible versions') {
                try {
                    Import-Module -Name $name -Global -ErrorAction Stop -WarningAction SilentlyContinue
                    [void]$script:ModulesLoadedByThisScript.Add($name)
                    continue
                } catch {
                    Write-AVDLog -Level 'WARN' -Message ("Retry import for module '{0}' failed after assembly collision: {1}" -f $name, $_.Exception.Message)
                }
                if (Get-Module -Name $name -ErrorAction SilentlyContinue) {
                    [void]$script:ModulesLoadedByThisScript.Add($name)
                    continue
                }
                throw "AVD_AZ_MODULE_CONFLICT: Failed to import required module '$name': Az assemblies from a prior script in this terminal are stuck in the process. Open a fresh PowerShell terminal and run again."
            }
            throw "Failed to import required module '$name': $($importErr.Exception.Message)"
        }
    }
}
function Remove-AVDRequiredModulesFromMemory {
    [CmdletBinding()]
    param()

    if (-not $script:ModulesLoadedByThisScript) { return }

    foreach ($moduleName in ($script:ModulesLoadedByThisScript | Sort-Object -Unique)) {
        Get-Module -Name $moduleName -ErrorAction SilentlyContinue |
            Remove-Module -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-AVDFreshProcessRecovery {
    [CmdletBinding()]
    param(
        [string]$SubscriptionId,
        [string]$TenantId,
        [string]$TargetRegion,
        [string]$VmSku,
        [int]$PlannedSessionHosts,
        [string]$DomainName,
        [string]$IdentityModel,
        [string]$ResourceGroupName,
        [string]$ReportPath,
        [switch]$ExportReport,
        [switch]$CriticalOnly,
        [switch]$SkipConnectivityTests,
        [switch]$SkipADValidation
    )

    # Avoid infinite relaunch loops.
    if ($env:AVD00_FRESH_PROCESS_RETRY -eq '1') {
        return $false
    }

    $isWindowsPlatform = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    if (-not $isWindowsPlatform) {
        return $false
    }

    # PowerShell ISE cannot show a child process, so there the import error is reported instead.
    if ($Host.Name -eq 'Windows PowerShell ISE Host') {
        return $false
    }

    $scriptPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path -Path $scriptPath)) {
        return $false
    }

    # Prefer relaunching into the same PowerShell engine (pwsh -> pwsh, powershell -> powershell).
    # Falling back to Windows PowerShell 5.1 can change cmdlet behavior and increase console noise.
    # Resolve the engine, not the host: in PowerShell ISE this process is powershell_ise.exe.
    $pwshExe = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
    if ([string]::IsNullOrWhiteSpace($pwshExe) -or -not (Test-Path -Path $pwshExe)) {
        $pwshExe = (Get-Command -Name 'pwsh.exe' -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    }
    if ([string]::IsNullOrWhiteSpace($pwshExe)) {
        $pwshExe = (Get-Command -Name 'powershell.exe' -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    }
    if ([string]::IsNullOrWhiteSpace($pwshExe)) {
        $pwshExe = 'powershell.exe'
    }

    $argList = [System.Collections.Generic.List[string]]::new()
    [void]$argList.Add('-NoLogo')
    [void]$argList.Add('-NoProfile')
    [void]$argList.Add('-ExecutionPolicy')
    [void]$argList.Add('Bypass')
    [void]$argList.Add('-File')
    [void]$argList.Add($scriptPath)
    [void]$argList.Add('-NonInteractive')

    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) { [void]$argList.Add('-SubscriptionId'); [void]$argList.Add($SubscriptionId) }
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) { [void]$argList.Add('-TenantId'); [void]$argList.Add($TenantId) }
    if (-not [string]::IsNullOrWhiteSpace($TargetRegion)) { [void]$argList.Add('-TargetRegion'); [void]$argList.Add($TargetRegion) }
    if (-not [string]::IsNullOrWhiteSpace($VmSku)) { [void]$argList.Add('-VmSku'); [void]$argList.Add($VmSku) }
    if ($PlannedSessionHosts -gt 0) { [void]$argList.Add('-PlannedSessionHosts'); [void]$argList.Add([string]$PlannedSessionHosts) }
    if (-not [string]::IsNullOrWhiteSpace($DomainName)) { [void]$argList.Add('-DomainName'); [void]$argList.Add($DomainName) }
    if (-not [string]::IsNullOrWhiteSpace($IdentityModel)) { [void]$argList.Add('-IdentityModel'); [void]$argList.Add($IdentityModel) }
    if (-not [string]::IsNullOrWhiteSpace($ResourceGroupName)) { [void]$argList.Add('-ResourceGroupName'); [void]$argList.Add($ResourceGroupName) }
    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) { [void]$argList.Add('-ReportPath'); [void]$argList.Add($ReportPath) }

    if ($ExportReport) { [void]$argList.Add('-ExportReport') }
    if ($CriticalOnly) { [void]$argList.Add('-CriticalOnly') }
    if ($SkipConnectivityTests) { [void]$argList.Add('-SkipConnectivityTests') }
    if ($SkipADValidation) { [void]$argList.Add('-SkipADValidation') }

    $previousRetryFlag = $env:AVD00_FRESH_PROCESS_RETRY
    $env:AVD00_FRESH_PROCESS_RETRY = '1'
    try {
        Write-Host ''
        Write-Host '[ INFO ] Recovering from in-process Az assembly collision...' -ForegroundColor Yellow
        Write-Host "[ INFO ] Relaunching in clean child process: $pwshExe" -ForegroundColor Yellow
        $child = Start-Process -FilePath $pwshExe -ArgumentList $argList.ToArray() -Wait -PassThru -NoNewWindow
        $script:FreshProcessExitCode = $child.ExitCode
        return ($child.ExitCode -in @(0, 1))
    } catch {
        return $false
    } finally {
        if ($null -eq $previousRetryFlag) {
            Remove-Item Env:AVD00_FRESH_PROCESS_RETRY -ErrorAction SilentlyContinue
        } else {
            $env:AVD00_FRESH_PROCESS_RETRY = $previousRetryFlag
        }
    }
}

#endregion

#region -- Authentication Helpers ----------------------------------------------

function Select-AuthenticationMethod {
    [CmdletBinding()]
    param([switch]$NonInteractive)

    if ($NonInteractive) {
        Write-AVDLog -Level 'INFO' -Message "Non-interactive mode: Prompting for fresh authentication method"
        return "Interactive"
    }

    Write-AVDSection -Title 'AUTHENTICATION METHOD SELECTION'
    Write-Host "For security, you must select an authentication method for each execution." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1. Interactive Browser Login (Default)" -ForegroundColor White
    Write-Host "      - Opens browser for authentication" -ForegroundColor Gray
    Write-Host "      - Best for most users" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  2. Device Code Authentication (Recommended)" -ForegroundColor White
    Write-Host "      - Use when browser login is not available" -ForegroundColor Gray
    Write-Host "      - Good for remote sessions or restricted environments" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  3. Service Principal (Client Secret)" -ForegroundColor White
    Write-Host "      - For automated scenarios" -ForegroundColor Gray
    Write-Host "      - Requires Application ID and Secret" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  4. Service Principal (Certificate)" -ForegroundColor White
    Write-Host "      - For automated scenarios with certificate authentication" -ForegroundColor Gray
    Write-Host "      - Requires Application ID and Certificate" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  5. Managed Identity" -ForegroundColor White
    Write-Host "      - For Azure VMs with managed identity enabled" -ForegroundColor Gray
    Write-Host "      - No credentials required" -ForegroundColor Gray
    Write-Host ""

    do {
        $selection = Read-Host "Please select an authentication method (1-5) [Default: 1]"
        if ([string]::IsNullOrWhiteSpace($selection)) { $selection = "1" }
        $selectionInt = 0
        $validSelection = [int]::TryParse($selection, [ref]$selectionInt) -and $selectionInt -ge 1 -and $selectionInt -le 5
        if (-not $validSelection) {
            Write-Host "Invalid selection. Please enter a number between 1 and 5." -ForegroundColor Red
        }
    } while (-not $validSelection)

    $authMethods = @{ 1 = "Interactive"; 2 = "DeviceCode"; 3 = "ServicePrincipalSecret"; 4 = "ServicePrincipalCertificate"; 5 = "ManagedIdentity" }
    $selectedMethod = $authMethods[$selectionInt]
    $methodNames = @{ "Interactive" = "Interactive Browser Login"; "DeviceCode" = "Device Code Authentication"; "ServicePrincipalSecret" = "Service Principal (Client Secret)"; "ServicePrincipalCertificate" = "Service Principal (Certificate)"; "ManagedIdentity" = "Managed Identity" }
    Write-AVDLog -Level 'PASS' -Message "Selected authentication method: $($methodNames[$selectedMethod])"
    return $selectedMethod
}

function Connect-AVDAzureAccount {
    [CmdletBinding()]
    param(
        [string]$TenantId,
        [string]$SubscriptionId,
        [switch]$NonInteractive,
        [string]$PreferredAuthMethod,
        [string]$RequestedAuthMethod = 'ExistingContext',
        [string]$ApplicationId,
        [string]$CertificateThumbprint,
        [System.Management.Automation.PSCredential]$ServicePrincipalCredential,
        [switch]$ReuseExistingContext
    )

    Write-AVDSection -Title 'AZURE AUTHENTICATION'

    try {
        if ($ReuseExistingContext -or $RequestedAuthMethod -eq 'ExistingContext') {
            $existingCtx = Get-AzContext -ErrorAction SilentlyContinue
            if ($null -ne $existingCtx) {
                Write-AVDLog -Level 'INFO' -Message 'Reusing the existing Azure context.'
                if ($SubscriptionId) {
                    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
                    $existingCtx = Get-AzContext -ErrorAction Stop
                    Write-AVDLog -Level 'PASS' -Message "Subscription context set to: $SubscriptionId"
                }

                Write-AVDLog -Level 'PASS' -Message "Authenticated: $($existingCtx.Account.Id)"
                Write-AVDLog -Level 'INFO' -Message "Tenant: $($existingCtx.Tenant.Id) | Subscription: $($existingCtx.Subscription.Name)"
                return $true
            }

            if ($NonInteractive) {
                throw 'No existing Azure context is available. Authenticate first or specify -AuthMethod ManagedIdentity or ServicePrincipalCertificate.'
            }

            Write-AVDLog -Level 'WARN' -Message 'No existing Azure context is available. Prompting for sign-in.'
        }

        Write-AVDLog -Level 'INFO' -Message 'Clearing any cached Azure session to ensure fresh authentication...'
        Disconnect-AzAccount -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null

        $validPreferredAuthMethods = @('Interactive','DeviceCode','ServicePrincipalSecret','ServicePrincipalCertificate','ManagedIdentity')
        if (-not $NonInteractive -and $PreferredAuthMethod -and ($PreferredAuthMethod -in $validPreferredAuthMethods)) {
            $selectedAuthMethod = $PreferredAuthMethod
            Write-AVDLog -Level 'INFO' -Message "Reusing authentication method selected in wizard: $selectedAuthMethod"
        } elseif ($RequestedAuthMethod -and $RequestedAuthMethod -ne 'ExistingContext') {
            $selectedAuthMethod = $RequestedAuthMethod
        } else {
            $selectedAuthMethod = Select-AuthenticationMethod -NonInteractive:$NonInteractive
        }

        $connectParams = @{ ErrorAction = 'Stop' }
        if ($TenantId) { $connectParams['TenantId'] = $TenantId }

        switch ($selectedAuthMethod) {
            'Interactive' {
                Write-AVDLog -Level 'INFO' -Message 'Opening interactive browser login...'
                Connect-AzAccount @connectParams | Out-Null
            }
            'DeviceCode' {
                Write-AVDLog -Level 'INFO' -Message 'Device code authentication - visit https://microsoft.com/devicelogin'
                $connectParams['UseDeviceAuthentication'] = $true
                Connect-AzAccount @connectParams | Out-Null
            }
            'ServicePrincipalSecret' {
                if ($NonInteractive -and (-not $ServicePrincipalCredential -or -not $TenantId)) {
                    throw 'ServicePrincipalSecret requires -ServicePrincipalCredential and -TenantId in non-interactive mode.'
                }
                if (-not $ServicePrincipalCredential) {
                    $appId = Read-Host 'Application (Client) ID'
                    $secret = Read-Host 'Client Secret' -AsSecureString
                    $ServicePrincipalCredential = New-Object System.Management.Automation.PSCredential($appId, $secret)
                }
                if (-not $TenantId) { $TenantId = Read-Host 'Tenant ID' }
                Connect-AzAccount -ServicePrincipal -Credential $ServicePrincipalCredential -TenantId $TenantId -ErrorAction Stop | Out-Null
            }
            'ServicePrincipalCertificate' {
                if ($NonInteractive -and (-not $ApplicationId -or -not $CertificateThumbprint -or -not $TenantId)) {
                    throw 'ServicePrincipalCertificate requires -ApplicationId, -CertificateThumbprint, and -TenantId in non-interactive mode.'
                }
                if (-not $ApplicationId) { $ApplicationId = Read-Host 'Application (Client) ID' }
                if (-not $CertificateThumbprint) { $CertificateThumbprint = Read-Host 'Certificate Thumbprint' }
                if (-not $TenantId) { $TenantId = Read-Host 'Tenant ID' }
                Connect-AzAccount -ServicePrincipal -ApplicationId $ApplicationId -CertificateThumbprint $CertificateThumbprint -TenantId $TenantId -ErrorAction Stop | Out-Null
            }
            'ManagedIdentity' {
                Write-AVDLog -Level 'INFO' -Message 'Authenticating with Managed Identity...'
                Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
            }
        }

        $ctx = Get-AzContext -ErrorAction Stop
        if ($null -ne $ctx) {
            Write-AVDLog -Level 'PASS' -Message "Authenticated: $($ctx.Account.Id)"
            Write-AVDLog -Level 'INFO' -Message "Tenant: $($ctx.Tenant.Id) | Subscription: $($ctx.Subscription.Name)"
            if ($SubscriptionId) {
                Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
                Write-AVDLog -Level 'PASS' -Message "Subscription context set to: $SubscriptionId"
            }
            return $true
        }
        return $false
    } catch {
        Write-AVDLog -Level 'FAIL' -Message "Authentication failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-AVDCurrentContext {
    [CmdletBinding()]
    param()
    return Get-AzContext -ErrorAction SilentlyContinue
}

#endregion

#region -- Subscription & Tenant -----------------------------------------------

function Test-AVDSubscriptionReadiness {
    [CmdletBinding()]
    param([string]$SubscriptionId)

    Write-AVDSection -Title 'SUBSCRIPTION & TENANT VALIDATION'

    try {
        $ctx = Get-AzContext -ErrorAction Stop
        if ($null -eq $ctx) {
            Add-AVDCheckResult `
                -Category 'Subscription' `
                -CheckName 'Azure Authentication' `
                -Result 'FAIL' `
                -Details 'No active Azure context found' `
                -Roadblock 'All subsequent checks require an authenticated Azure session.' `
                -HowToFix 'Run Connect-AzAccount before executing this script.'
            return
        }

        if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
            $SubscriptionId = $ctx.Subscription.Id
        }

        $sub = Get-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop

        if ($sub.State -eq 'Enabled') {
            Add-AVDCheckResult `
                -Category 'Subscription' `
                -CheckName 'Subscription Status' `
                -Result 'PASS' `
                -Details "Name: '$($sub.Name)' | ID: $SubscriptionId | State: Enabled"
        } else {
            Add-AVDCheckResult `
                -Category 'Subscription' `
                -CheckName 'Subscription Status' `
                -Result 'FAIL' `
                -Details "Subscription '$($sub.Name)' is in state: $($sub.State)" `
                -Roadblock 'An inactive/disabled subscription cannot host Azure resources. AVD deployment will be blocked.' `
                -HowToFix 'Contact your Azure account admin or billing department to re-activate the subscription.'
        }

        Add-AVDCheckResult `
            -Category 'Subscription' `
            -CheckName 'Tenant Identity' `
            -Result 'PASS' `
            -Details "Tenant ID: $($ctx.Tenant.Id) | Account: $($ctx.Account.Id)"

        try {
            $policyAssignments = Get-AzPolicyAssignment -Scope "/subscriptions/$SubscriptionId" -ErrorAction SilentlyContinue
            $policyCount = if ($null -ne $policyAssignments) { @($policyAssignments).Count } else { 0 }
            if ($policyCount -gt 0) {
                Add-AVDCheckResult `
                    -Category 'Subscription' `
                    -CheckName 'Azure Policy Assignments' `
                    -Result 'WARN' `
                    -Details "$policyCount policy assignment(s) found. Some policies may restrict AVD resource creation." `
                    -HowToFix 'Review Azure Policy assignments in the Azure Portal under Policy > Compliance. Look for any deny policies that affect VM creation, networking, or storage.' `
                    -DocLink 'https://learn.microsoft.com/azure/governance/policy/overview'
            } else {
                Add-AVDCheckResult `
                    -Category 'Subscription' `
                    -CheckName 'Azure Policy Assignments' `
                    -Result 'INFO' `
                    -Details 'No subscription-level policy assignments detected (inherited MG policies not checked here)'
            }
        } catch {
            Write-AVDLog -Level 'WARN' -Message ("Could not enumerate subscription policy assignments for {0}: {1}" -f $SubscriptionId, $_.Exception.Message)
        }

    } catch {
        Add-AVDCheckResult `
            -Category 'Subscription' `
            -CheckName 'Subscription Validation' `
            -Result 'FAIL' `
            -Details "Error: $($_.Exception.Message)" `
            -HowToFix 'Ensure you are authenticated and have at least Reader role on the target subscription.'
    }
}

#endregion

#region -- Resource Providers --------------------------------------------------

function Test-AVDResourceProviders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$RequiredProviders,

        [string[]]$RecommendedProviders = @()
    )

    Write-AVDSection -Title 'RESOURCE PROVIDER REGISTRATION'

    $allProviders = @(Get-AzResourceProvider -ErrorAction SilentlyContinue)

    foreach ($ns in $RequiredProviders) {
        $rp = $allProviders | Where-Object { $_.ProviderNamespace -eq $ns } | Select-Object -First 1
        if ($null -eq $rp) {
            Add-AVDCheckResult `
                -Category 'ResourceProviders' `
                -CheckName "Provider: $ns" `
                -Result 'FAIL' `
                -Details 'Not found in subscription' `
                -Roadblock "Resource provider '$ns' is not registered. Azure will reject any API call to create resources under this namespace." `
                -HowToFix "Register-AzResourceProvider -ProviderNamespace '$ns'  (requires Owner or Contributor role on the subscription)" `
                -DocLink 'https://learn.microsoft.com/azure/azure-resource-manager/management/resource-providers-and-types'
        } elseif ($rp.RegistrationState -eq 'Registered') {
            Add-AVDCheckResult `
                -Category 'ResourceProviders' `
                -CheckName "Provider: $ns" `
                -Result 'PASS' `
                -Details 'Registered'
        } else {
            Add-AVDCheckResult `
                -Category 'ResourceProviders' `
                -CheckName "Provider: $ns" `
                -Result 'FAIL' `
                -Details "State: $($rp.RegistrationState)" `
                -Roadblock "Provider '$ns' is not registered (state: $($rp.RegistrationState)). AVD deployment requires this provider." `
                -HowToFix "Register-AzResourceProvider -ProviderNamespace '$ns'  then wait 2-5 minutes and re-check." `
                -DocLink 'https://learn.microsoft.com/azure/azure-resource-manager/management/resource-providers-and-types'
        }
    }

    foreach ($ns in $RecommendedProviders) {
        $rp = $allProviders | Where-Object { $_.ProviderNamespace -eq $ns } | Select-Object -First 1
        $state = if ($null -ne $rp) { $rp.RegistrationState } else { 'NotFound' }
        if ($state -eq 'Registered') {
            Add-AVDCheckResult `
                -Category 'ResourceProviders' `
                -CheckName "Provider (optional): $ns" `
                -Result 'PASS' `
                -Details 'Registered'
        } else {
            Add-AVDCheckResult `
                -Category 'ResourceProviders' `
                -CheckName "Provider (optional): $ns" `
                -Result 'WARN' `
                -Details "State: $state  -  optional AVD features that depend on this provider will be unavailable" `
                -HowToFix "Register-AzResourceProvider -ProviderNamespace '$ns'"
        }
    }
}

#endregion

#region -- Network Validation --------------------------------------------------

function Test-AVDNetworkConfiguration {
    [CmdletBinding()]
    param(
        [string]$TargetRegion,
        [string]$ResourceGroupName,
        [string]$VNetName,
        [string]$SubnetName,
        [int]$MinFreeIPsRequired = 10,
        [switch]$SkipNSGCheck,
        [switch]$SkipDNSCheck,
        [switch]$SkipRouteCheck
    )

    Write-AVDSection -Title 'NETWORK CONFIGURATION VALIDATION'

    function Get-ResourceGroupNameFromResourceId {
        param([string]$ResourceId)

        if ([string]::IsNullOrWhiteSpace($ResourceId)) { return $null }

        $match = [regex]::Match($ResourceId, '/resourceGroups/([^/]+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success -and $match.Groups.Count -gt 1) {
            return $match.Groups[1].Value
        }

        return $null
    }

    try {
        if ($VNetName -and $ResourceGroupName) {
            $vnets = @(Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
        } elseif ($TargetRegion) {
            $normalRegion = $TargetRegion.ToLower().Replace(' ','')
            $vnets = @(Get-AzVirtualNetwork -ErrorAction Stop | Where-Object { $_.Location -eq $normalRegion })
        } else {
            $vnets = @(Get-AzVirtualNetwork -ErrorAction Stop)
        }
    } catch {
        Add-AVDCheckResult `
            -Category 'Network' `
            -CheckName 'Virtual Networks  -  Read' `
            -Result 'FAIL' `
            -Details "Cannot enumerate virtual networks: $($_.Exception.Message)" `
            -Roadblock 'Cannot assess network readiness without permission to read VNet resources.' `
            -HowToFix 'Ensure your account has at least Reader role on the subscription or the VNet resource group.'
        return
    }

    if ($SubnetName) {
        $vnets = @($vnets | Where-Object { @($_.Subnets.Name) -contains $SubnetName })
    }

    if ($vnets.Count -eq 0) {
        $scopeParts = @()
        if ($VNetName) { $scopeParts += "VNet '$VNetName'" }
        if ($SubnetName) { $scopeParts += "subnet '$SubnetName'" }
        if ($TargetRegion) { $scopeParts += "region '$TargetRegion'" }
        $scopeNote = if ($scopeParts.Count) { ' matching ' + ($scopeParts -join ', ') } else { '' }
        Add-AVDCheckResult `
            -Category 'Network' `
            -CheckName 'Virtual Networks' `
            -Result 'FAIL' `
            -Details "No virtual networks found$scopeNote" `
            -Roadblock 'AVD session hosts must be placed in a VNet subnet. Without a VNet in the target region, no session host VMs can be deployed.' `
            -HowToFix "Create a VNet in the target region with a subnet of /24 or larger. Ensure line-of-sight to your identity provider." `
            -DocLink 'https://learn.microsoft.com/azure/virtual-desktop/prerequisites#network'
        return
    }

    Add-AVDCheckResult `
        -Category 'Network' `
        -CheckName 'Virtual Networks' `
        -Result 'PASS' `
        -Details "Found $($vnets.Count) VNet(s)$(if($TargetRegion){' in ' + $TargetRegion})"

    foreach ($vnet in $vnets) {
        $vn = $vnet.Name
        $vr = $vnet.ResourceGroupName
        $subnets = if ($SubnetName) {
            @($vnet.Subnets | Where-Object Name -eq $SubnetName)
        } else {
            @($vnet.Subnets)
        }

        if ($subnets.Count -eq 0) {
            Add-AVDCheckResult `
                -Category 'Network' `
                -CheckName "VNet '$vn'  -  Subnets" `
                -Result 'FAIL' `
                -Details 'No subnets defined' `
                -Roadblock 'Session host VMs require a subnet. A VNet without subnets cannot host AVD.' `
                -HowToFix "Add a subnet (/24 minimum) to VNet '$vn'."
            continue
        }

        foreach ($subnet in $subnets) {
            $sn = $subnet.Name

            $prefix = [string]$subnet.AddressPrefix
            if ([string]::IsNullOrWhiteSpace($prefix)) {
                $prefix = [string](@($subnet.AddressPrefixes | Select-Object -First 1))
            }
            $prefixMatch = [regex]::Match($prefix, '/(\d+)$')
            if ($prefixMatch.Success) {
                $mask        = [int]$prefixMatch.Groups[1].Value
                $totalUsable = [Math]::Pow(2, 32 - $mask) - 5
                $used        = if ($null -ne $subnet.IpConfigurations) { @($subnet.IpConfigurations).Count } else { 0 }
                $free        = $totalUsable - $used

                if ($free -lt $MinFreeIPsRequired) {
                    Add-AVDCheckResult `
                        -Category 'Network' `
                        -CheckName "VNet '$vn' / Subnet '$sn'  -  IP Space" `
                        -Result 'FAIL' `
                        -Details "Only $free free IPs (Prefix: $prefix | Used: $used / $totalUsable)" `
                        -Roadblock 'Each AVD session host requires one IP address. Insufficient free IPs will block VM NIC creation.' `
                        -HowToFix "Create a new larger subnet (/24 gives 251 usable IPs) or expand the address space of the VNet and resize the subnet."
                } elseif ($free -lt 50) {
                    Add-AVDCheckResult `
                        -Category 'Network' `
                        -CheckName "VNet '$vn' / Subnet '$sn'  -  IP Space" `
                        -Result 'WARN' `
                        -Details "$free free IPs (Prefix: $prefix). Sufficient for now but limited for growth." `
                        -HowToFix 'For production AVD (20+ hosts), use a /24 subnet to ensure 251 usable IPs with room for growth.'
                } else {
                    Add-AVDCheckResult `
                        -Category 'Network' `
                        -CheckName "VNet '$vn' / Subnet '$sn'  -  IP Space" `
                        -Result 'PASS' `
                        -Details "$free free IPs (Prefix: $prefix)"
                }
            }

            $delegations = @($subnet.Delegations)
            if ($delegations.Count -gt 0) {
                $delSvcs = ($delegations | ForEach-Object { $_.ServiceName }) -join ', '
                Add-AVDCheckResult `
                    -Category 'Network' `
                    -CheckName "VNet '$vn' / Subnet '$sn'  -  Delegations" `
                    -Result 'WARN' `
                    -Details "Subnet delegated to: $delSvcs" `
                    -HowToFix "Session host NICs cannot be placed in a delegated subnet. Create a separate, undelegated subnet for AVD session hosts."
            }

            if (-not $SkipNSGCheck -and $null -ne $subnet.NetworkSecurityGroup) {
                $nsgId   = $subnet.NetworkSecurityGroup.Id
                $nsgName = $nsgId.Split('/')[-1]
                $nsgRg   = Get-ResourceGroupNameFromResourceId -ResourceId $nsgId
                try {
                    if (-not $nsgRg) {
                        throw "Unable to determine resource group from NSG resource ID '$nsgId'."
                    }
                    $nsg = Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $nsgRg -ErrorAction Stop

                    $blockAll = $nsg.SecurityRules | Where-Object {
                        $_.Direction -eq 'Outbound' -and $_.Access -eq 'Deny' -and
                        $_.DestinationAddressPrefix -eq '*' -and $_.DestinationPortRange -eq '*'
                    }
                    $allowAVD = $nsg.SecurityRules | Where-Object {
                        $_.Direction -eq 'Outbound' -and $_.Access -eq 'Allow' -and
                        ($_.DestinationPortRange -contains '443' -or $_.DestinationPortRange -eq '*') -and
                        ($_.DestinationAddressPrefix -in @('*','AzureCloud','AzureVirtualDesktop',
                                                           'WindowsVirtualDesktop','AzureFrontDoor.Frontend'))
                    }

                    if ($null -ne $blockAll -and $null -eq $allowAVD) {
                        Add-AVDCheckResult `
                            -Category 'Network' `
                            -CheckName "NSG '$nsgName' on Subnet '$sn'  -  AVD Outbound" `
                            -Result 'FAIL' `
                            -Details 'Block-all-outbound rule found with no explicit AVD Allow rule' `
                            -Roadblock 'AVD session hosts must reach AVD control plane on port 443 to register agents and broker sessions. Blocking all outbound traffic prevents this.' `
                            -HowToFix 'Add Outbound Allow rules: Port 443 -> AzureVirtualDesktop, Port 443 -> WindowsVirtualDesktop, Port 443 -> AzureFrontDoor.Frontend, Port 80 -> * (for CRL). See documentation for full list.' `
                            -DocLink 'https://learn.microsoft.com/azure/virtual-desktop/required-fqdn-endpoint'
                    } else {
                        Add-AVDCheckResult `
                            -Category 'Network' `
                            -CheckName "NSG '$nsgName' on Subnet '$sn'  -  AVD Outbound" `
                            -Result 'PASS' `
                            -Details 'No outbound block-all rule or explicit AVD Allow rule is present  -  default allow applies'
                    }
                } catch {
                    Add-AVDCheckResult `
                        -Category 'Network' `
                        -CheckName "NSG on Subnet '$sn'" `
                        -Result 'WARN' `
                        -Details "Could not read NSG '$nsgName': $($_.Exception.Message)" `
                        -HowToFix 'Manually verify the NSG allows outbound HTTPS (443) to AzureVirtualDesktop and WindowsVirtualDesktop service tags.'
                }
            } else {
                if (-not $SkipNSGCheck) {
                    Add-AVDCheckResult `
                        -Category 'Network' `
                        -CheckName "VNet '$vn' / Subnet '$sn'  -  NSG" `
                        -Result 'INFO' `
                        -Details 'No NSG on subnet  -  default Azure rules allow all outbound'
                }
            }

            if (-not $SkipRouteCheck -and $null -ne $subnet.RouteTable) {
                $rtId   = $subnet.RouteTable.Id
                $rtName = $rtId.Split('/')[-1]
                $rtRg   = Get-ResourceGroupNameFromResourceId -ResourceId $rtId
                try {
                    if (-not $rtRg) {
                        throw "Unable to determine resource group from route table resource ID '$rtId'."
                    }
                    $rt = Get-AzRouteTable -Name $rtName -ResourceGroupName $rtRg -ErrorAction Stop
                    $nvaDefault = $rt.Routes | Where-Object {
                        $_.AddressPrefix -eq '0.0.0.0/0' -and $_.NextHopType -eq 'VirtualAppliance'
                    }
                    if ($null -ne $nvaDefault) {
                        Add-AVDCheckResult `
                            -Category 'Network' `
                            -CheckName "RouteTable '$rtName' on Subnet '$sn'  -  NVA Default Route" `
                            -Result 'WARN' `
                            -Details "0.0.0.0/0 routes to a Virtual Appliance (firewall/NVA)" `
                            -Roadblock 'If the NVA does not explicitly allow AVD service FQDNs/IPs on port 443, AVD agent registration and session brokering will fail silently.' `
                            -HowToFix 'Configure the NVA/Firewall with Allow rules for: AzureVirtualDesktop, WindowsVirtualDesktop, AzureFrontDoor.Frontend, StorageAccount, and AzureMonitor service tags on port 443.' `
                            -DocLink 'https://learn.microsoft.com/azure/virtual-desktop/required-fqdn-endpoint'
                    } else {
                        Add-AVDCheckResult `
                            -Category 'Network' `
                            -CheckName "RouteTable '$rtName' on Subnet '$sn'" `
                            -Result 'PASS' `
                            -Details 'No NVA force-tunnel default route detected'
                    }
                } catch {
                    Add-AVDCheckResult `
                        -Category 'Network' `
                        -CheckName "RouteTable on Subnet '$sn'" `
                        -Result 'WARN' `
                        -Details "Could not read route table '$rtName': $($_.Exception.Message)"
                }
            }
        } # end foreach subnet

        if (-not $SkipDNSCheck) {
            $dns = $vnet.DhcpOptions.DnsServers
            if ($null -eq $dns -or $dns.Count -eq 0) {
                Add-AVDCheckResult `
                    -Category 'Network' `
                    -CheckName "VNet '$vn'  -  DNS" `
                    -Result 'INFO' `
                    -Details 'Azure-provided DNS. Sufficient for Entra ID-only AVD. For AD DS, custom DNS pointing to DCs is required.' `
                    -HowToFix 'For AD DS scenarios: set VNet DNS to your domain controller IPs so session hosts can resolve and join the domain.'
            } else {
                Add-AVDCheckResult `
                    -Category 'Network' `
                    -CheckName "VNet '$vn'  -  DNS" `
                    -Result 'INFO' `
                    -Details "Custom DNS: $($dns -join ', '). Ensure these servers resolve Azure service FQDNs."
            }
        }

        try {
            $peerings = Get-AzVirtualNetworkPeering -VirtualNetworkName $vn -ResourceGroupName $vr -ErrorAction SilentlyContinue
            if ($null -ne $peerings) {
                foreach ($peer in $peerings) {
                    if ($peer.PeeringState -eq 'Connected') {
                        Add-AVDCheckResult `
                            -Category 'Network' `
                            -CheckName "VNet '$vn'  -  Peering '$($peer.Name)'" `
                            -Result 'PASS' `
                            -Details "PeeringState: Connected"
                    } else {
                        Add-AVDCheckResult `
                            -Category 'Network' `
                            -CheckName "VNet '$vn'  -  Peering '$($peer.Name)'" `
                            -Result 'FAIL' `
                            -Details "PeeringState: $($peer.PeeringState)" `
                            -Roadblock 'A disconnected VNet peering breaks hub-spoke connectivity. Session hosts may not reach domain controllers, shared services, or on-premises resources.' `
                            -HowToFix "Repair the peering by deleting and recreating it from both sides. Ensure the remote VNet still exists and access is not blocked by RBAC."
                    }
                }
            }
        } catch {
            Write-AVDLog -Level 'WARN' -Message ("Could not enumerate peering state for VNet '{0}' in resource group '{1}': {2}" -f $vn, $vr, $_.Exception.Message)
        }

    } # end foreach vnet
}

# TCP reachability with a short timeout. Test-NetConnection waits about 21 seconds
# on every blocked port, which added minutes to runs from locked-down networks.
function Test-AVDTcpPort {
    param(
        [Parameter(Mandatory=$true)] [string]$ComputerName,
        [Parameter(Mandatory=$true)] [int]$Port,
        [int]$TimeoutMs = 5000
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $attempt = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $attempt.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($attempt)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Test-AVDEndpointConnectivity {
    [CmdletBinding()]
    param()

    Write-AVDSection -Title 'AVD ENDPOINT CONNECTIVITY (from this host)'

    $endpoints = @(
        @{ Host = 'rdweb.wvd.microsoft.com';              Port = 443;  Desc = 'AVD Web Client / Broker'        }
        @{ Host = 'rdbroker.wvd.microsoft.com';           Port = 443;  Desc = 'AVD Broker'                    }
        @{ Host = 'rdgateway.wvd.microsoft.com';          Port = 443;  Desc = 'AVD Gateway'                   }
        @{ Host = 'rddiagnostics.wvd.microsoft.com';      Port = 443;  Desc = 'AVD Diagnostics'               }
        @{ Host = 'catalogartifact.azureedge.net';        Port = 443;  Desc = 'AVD Artifacts'                 }
        @{ Host = 'login.microsoftonline.com';            Port = 443;  Desc = 'Entra ID Login'                }
        @{ Host = 'management.azure.com';                 Port = 443;  Desc = 'Azure Management API'          }
        @{ Host = 'kms.core.windows.net';                 Port = 1688; Desc = 'Windows KMS Activation';        WarnOnly = $true  }
        @{ Host = 'azkms.core.windows.net';               Port = 1688; Desc = 'Azure KMS (secondary)';         WarnOnly = $true  }
        @{ Host = 'ocsp.microsoft.com';                   Port = 80;   Desc = 'Certificate Revocation (OCSP)'; WarnOnly = $true  }
    )

    foreach ($ep in $endpoints) {
        $warnOnly = ($null -ne $ep.WarnOnly -and $ep.WarnOnly -eq $true)
        try {
            $reach = Test-AVDTcpPort -ComputerName $ep.Host -Port $ep.Port
            if ($reach) {
                Add-AVDCheckResult `
                    -Category 'Connectivity' `
                    -CheckName "Endpoint $($ep.Host):$($ep.Port)" `
                    -Result 'INFO' `
                    -Details "$($ep.Desc)  -  reachable from this host; session-host connectivity is not proven"
            } elseif ($warnOnly) {
                Add-AVDCheckResult `
                    -Category 'Connectivity' `
                    -CheckName "Endpoint $($ep.Host):$($ep.Port)" `
                    -Result 'WARN' `
                    -Details "$($ep.Desc)  -  not reachable FROM THIS WORKSTATION (this is normal for admin PCs)" `
                    -HowToFix "This port is only required on session host VMs, not the machine running this script. Verify reachability by running Test-NetConnection -ComputerName $($ep.Host) -Port $($ep.Port) from within the session host subnet after deployment." `
                    -DocLink 'https://learn.microsoft.com/azure/virtual-desktop/required-fqdn-endpoint'
            } else {
                Add-AVDCheckResult `
                    -Category 'Connectivity' `
                    -CheckName "Endpoint $($ep.Host):$($ep.Port)" `
                    -Result 'WARN' `
                    -Details "$($ep.Desc)  -  not reachable from this host; this does not prove the session-host result" `
                    -HowToFix "Run AVD_Deployment_Blocker_Analysis.ps1 against an existing VM in the target session-host subnet. If that VM also fails, review outbound firewall, proxy, TLS inspection, and effective routes." `
                    -DocLink 'https://learn.microsoft.com/azure/virtual-desktop/required-fqdn-endpoint'
            }
        } catch {
            Add-AVDCheckResult `
                -Category 'Connectivity' `
                -CheckName "Endpoint $($ep.Host):$($ep.Port)" `
                -Result 'WARN' `
                -Details "Test-NetConnection error: $($_.Exception.Message)"
        }
    }
}

#endregion

#region -- Compute & Quota -----------------------------------------------------

function Get-AVDVMQuotaFamilyName {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)] [string]$SkuName)

    switch -Regex ($SkuName) {
        '^Standard_D\d+as_v5'  { return 'standardDASv5Family' }
        '^Standard_D\d+s_v5'   { return 'standardDSv5Family'  }
        '^Standard_D\d+ads_v5' { return 'standardDASv5Family' }
        '^Standard_D\d+as_v4'  { return 'standardDASv4Family' }
        '^Standard_D\d+s_v4'   { return 'standardDSv4Family'  }
        '^Standard_D\d+s_v3'   { return 'standardDSv3Family'  }
        '^Standard_E\d+s_v5'   { return 'standardESv5Family'  }
        '^Standard_E\d+as_v5'  { return 'standardEASv5Family' }
        '^Standard_E\d+s_v4'   { return 'standardESv4Family'  }
        '^Standard_E\d+s_v3'   { return 'standardESv3Family'  }
        '^Standard_F\d+s_v2'   { return 'standardFSv2Family'  }
        '^Standard_B\d+'        { return 'standardBSFamily'    }
        '^Standard_NV\d+s_v3'  { return 'standardNVSv3Family' }
        '^Standard_NV\d+'       { return 'standardNVFamily'    }
        '^Standard_NC\d+s_v3'  { return 'standardNCSv3Family' }
        '^Standard_NC\d+'       { return 'standardNCFamily'    }
        '^Standard_ND\d+'       { return 'standardNDFamily'    }
        default                 { return $null                 }
    }
}

function Test-AVDComputeQuota {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Location,
        [string]$VmSku,
        [int]$PlannedSessionHosts = 1
    )

    Write-AVDSection -Title "COMPUTE QUOTA  -  $Location"

    try {
        $usages = Get-AzVMUsage -Location $Location -ErrorAction Stop
        $skuInfo = $null
        $requiredVcpus = $null

        if ($VmSku) {
            $skuInfo = Get-AzComputeResourceSku -Location $Location -ErrorAction Stop |
                Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -eq $VmSku } |
                Select-Object -First 1
            $vCpuCapability = $skuInfo.Capabilities | Where-Object Name -eq 'vCPUs' | Select-Object -First 1
            if ($vCpuCapability -and [int]$vCpuCapability.Value -gt 0) {
                $requiredVcpus = [int]$vCpuCapability.Value * $PlannedSessionHosts
                Add-AVDCheckResult `
                    -Category 'ComputeQuota' `
                    -CheckName 'Planned Deployment Requirement' `
                    -Result 'INFO' `
                    -Details "$PlannedSessionHosts x $VmSku at $($vCpuCapability.Value) vCPUs each requires $requiredVcpus vCPUs"
            } else {
                Add-AVDCheckResult `
                    -Category 'ComputeQuota' `
                    -CheckName 'Planned Deployment Requirement' `
                    -Result 'WARN' `
                    -Details "Could not determine the vCPU count for '$VmSku'; planned quota sufficiency cannot be confirmed."
            }
        }

        $regional = $usages | Where-Object { $_.Name.Value -eq 'cores' }
        if ($null -ne $regional) {
            $free        = $regional.Limit - $regional.CurrentValue
            $pctUsed     = [Math]::Round(($regional.CurrentValue / $regional.Limit) * 100, 1)
            if ($requiredVcpus -and $free -lt $requiredVcpus) {
                Add-AVDCheckResult `
                    -Category 'ComputeQuota' `
                    -CheckName "Regional vCPUs  -  $Location" `
                    -Result 'FAIL' `
                    -Details "$requiredVcpus vCPUs required, but only $free are free (Limit: $($regional.Limit), Used: $($regional.CurrentValue))" `
                    -Roadblock 'Insufficient regional vCPU quota. VM creation will fail with ResourceQuotaExceeded.' `
                    -HowToFix 'Request a quota increase at: https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas or raise a support ticket.' `
                    -DocLink 'https://learn.microsoft.com/azure/virtual-desktop/quotas'
            } elseif ($pctUsed -gt 80) {
                Add-AVDCheckResult `
                    -Category 'ComputeQuota' `
                    -CheckName "Regional vCPUs  -  $Location" `
                    -Result 'WARN' `
                    -Details "$free free regional vCPUs ($pctUsed% used, Limit: $($regional.Limit)). Consider requesting an increase proactively." `
                    -HowToFix 'Request a quota increase proactively: https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas'
            } else {
                Add-AVDCheckResult `
                    -Category 'ComputeQuota' `
                    -CheckName "Regional vCPUs  -  $Location" `
                    -Result 'PASS' `
                    -Details "$free free regional vCPUs ($pctUsed% used, Limit: $($regional.Limit))"
            }
        }

        if ($VmSku) {
            $family = if ($skuInfo -and $skuInfo.Family) { [string]$skuInfo.Family } else { Get-AVDVMQuotaFamilyName -SkuName $VmSku }
            if ($null -ne $family) {
                $fq = $usages | Where-Object { $_.Name.Value -eq $family }
                if ($null -ne $fq) {
                    $fFree = $fq.Limit - $fq.CurrentValue
                    if ($requiredVcpus -and $fFree -lt $requiredVcpus) {
                        Add-AVDCheckResult `
                            -Category 'ComputeQuota' `
                            -CheckName "VM Family '$family'" `
                            -Result 'FAIL' `
                            -Details "$requiredVcpus vCPUs required, but only $fFree are free in this family (Limit: $($fq.Limit))" `
                            -Roadblock "Insufficient VM-family quota for '$VmSku'. Deployment using this SKU will fail." `
                            -HowToFix "Request VM family quota increase for '$family' in '$Location' at: https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas" `
                            -DocLink 'https://learn.microsoft.com/azure/virtual-machines/quotas'
                    } else {
                        Add-AVDCheckResult `
                            -Category 'ComputeQuota' `
                            -CheckName "VM Family '$family'" `
                            -Result 'PASS' `
                            -Details "$fFree vCPUs free in family (Limit: $($fq.Limit))"
                    }
                } else {
                    Add-AVDCheckResult `
                        -Category 'ComputeQuota' `
                        -CheckName "VM Family '$family'" `
                        -Result 'INFO' `
                        -Details 'Family quota entry not returned  -  may indicate first deployment in this family'
                }
            }

            Test-AVDVMSKUAvailability -Location $Location -VmSku $VmSku
        }

    } catch {
        Add-AVDCheckResult `
            -Category 'ComputeQuota' `
            -CheckName "Compute Quota  -  $Location" `
            -Result 'WARN' `
            -Details "Could not read quota: $($_.Exception.Message)" `
            -HowToFix 'Check quota manually in Azure Portal: Subscriptions > Usage + Quotas.'
    }
}

function Test-AVDVMSKUAvailability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Location,
        [Parameter(Mandatory=$true)] [string]$VmSku
    )

    try {
        $sku = Get-AzComputeResourceSku -Location $Location -ErrorAction SilentlyContinue |
               Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -eq $VmSku } |
               Select-Object -First 1

        if ($null -eq $sku) {
            Add-AVDCheckResult `
                -Category 'ComputeQuota' `
                -CheckName "VM SKU '$VmSku' in $Location" `
                -Result 'FAIL' `
                -Details "SKU not available in this region" `
                -Roadblock "The requested VM SKU '$VmSku' does not exist in '$Location'. Session host deployment will fail with SkuNotAvailable." `
                -HowToFix "Choose a different SKU or a different Azure region. List available SKUs: Get-AzComputeResourceSku -Location '$Location' | Where-Object ResourceType -eq 'virtualMachines' | Select-Object Name" `
                -DocLink 'https://learn.microsoft.com/azure/virtual-machines/skus-availability'
            return
        }

        $restricted = $sku.Restrictions | Where-Object {
            $null -ne $_.RestrictionInfo -and
            ($_.RestrictionInfo.Locations -contains $Location -or $_.RestrictionInfo.Locations.Count -eq 0)
        }

        if ($null -ne $restricted -and @($restricted).Count -gt 0) {
            $types = ($restricted | ForEach-Object { $_.Type }) -join ', '
            Add-AVDCheckResult `
                -Category 'ComputeQuota' `
                -CheckName "VM SKU '$VmSku' in $Location" `
                -Result 'FAIL' `
                -Details "SKU is RESTRICTED. Restriction type(s): $types" `
                -Roadblock "Azure policy or platform capacity restrictions prevent deployment of '$VmSku' in '$Location'." `
                -HowToFix "1. Contact Azure Support to lift the restriction (if policy-based). 2. Try a different region. 3. Check if restriction is zone-specific and deploy to a different availability zone." `
                -DocLink 'https://learn.microsoft.com/azure/virtual-machines/troubleshooting-shared-images'
        } else {
            $accel = $sku.Capabilities | Where-Object { $_.Name -eq 'AcceleratedNetworkingEnabled' }
            if ($null -ne $accel -and $accel.Value -eq 'True') {
                Add-AVDCheckResult `
                    -Category 'ComputeQuota' `
                    -CheckName "VM SKU '$VmSku' in $Location" `
                    -Result 'PASS' `
                    -Details 'Available. Accelerated Networking: Supported (recommended for AVD)'
            } else {
                Add-AVDCheckResult `
                    -Category 'ComputeQuota' `
                    -CheckName "VM SKU '$VmSku' in $Location" `
                    -Result 'WARN' `
                    -Details 'Available. Accelerated Networking: Not supported by this SKU.' `
                    -HowToFix 'For production AVD, choose SKUs with Accelerated Networking support (D/E/F v3+ series) for lower latency and higher throughput.'
            }
        }
    } catch {
        Add-AVDCheckResult `
            -Category 'ComputeQuota' `
            -CheckName "VM SKU '$VmSku' in $Location" `
            -Result 'WARN' `
            -Details "Could not check SKU restrictions: $($_.Exception.Message)"
    }
}

#endregion

#region -- Storage & FSLogix ---------------------------------------------------

function Test-AVDStorageReadiness {
    [CmdletBinding()]
    param(
        [string]$ResourceGroupName,
        [string]$StorageAccountName,
        [switch]$SkipPortTest
    )

    Write-AVDSection -Title 'STORAGE & FSLOGIX READINESS'

    # Always enumerate all storage accounts across the subscription so accounts in any
    # resource group are never silently missed. Accounts are then sorted so those inside
    # the selected RG appear first and are clearly distinguished from others.
    try {
        $allAccounts = if ($StorageAccountName -and $ResourceGroupName) {
            @(Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop)
        } else {
            @(Get-AzStorageAccount -ErrorAction Stop)
        }
    } catch {
        Add-AVDCheckResult `
            -Category 'Storage' `
            -CheckName 'Storage Account Enumeration' `
            -Result 'WARN' `
            -Details "Cannot list storage accounts: $($_.Exception.Message)" `
            -HowToFix 'Ensure your account has Storage Account Reader or Reader role.'
        return
    }

    if ($allAccounts.Count -eq 0) {
        Add-AVDCheckResult `
            -Category 'Storage' `
            -CheckName 'Storage Accounts' `
            -Result 'WARN' `
            -Details 'No storage accounts found in the subscription. FSLogix profile containers require Azure Files.' `
            -HowToFix 'Create a Premium (FileStorage) or Standard (StorageV2) storage account with Azure Files enabled in the same region as session hosts.' `
            -DocLink 'https://learn.microsoft.com/azure/virtual-desktop/fslogix-profile-container-configure-azure-files-active-directory'
        return
    }

    # Split into in-scope (selected RG) and out-of-scope accounts; process in-scope first.
    $inRGAccounts  = if ($ResourceGroupName) {
        @($allAccounts | Where-Object { $_.ResourceGroupName -eq $ResourceGroupName })
    } else { @($allAccounts) }
    $outRGAccounts = if ($ResourceGroupName) {
        @($allAccounts | Where-Object { $_.ResourceGroupName -ne $ResourceGroupName })
    } else { @() }

    if ($ResourceGroupName) {
        $inCount  = $inRGAccounts.Count
        $outCount = $outRGAccounts.Count
        $scopeNote = "Found $inCount account(s) in selected RG '$ResourceGroupName'"
        if ($outCount -gt 0) { $scopeNote += " + $outCount additional account(s) in other RGs also evaluated (see below)" }
        if ($inCount -eq 0) {
            Add-AVDCheckResult `
                -Category 'Storage' `
                -CheckName 'Storage Accounts Found' `
                -Result 'WARN' `
                -Details "$scopeNote. No storage account found in '$ResourceGroupName'. FSLogix requires Azure Files in the same deployment scope." `
                -HowToFix "Create a storage account in resource group '$ResourceGroupName' and enable Azure Files with the appropriate identity auth (AD DS or Entra Kerberos)." `
                -DocLink 'https://learn.microsoft.com/azure/virtual-desktop/fslogix-profile-container-configure-azure-files-active-directory'
        } else {
            Add-AVDCheckResult `
                -Category 'Storage' `
                -CheckName 'Storage Accounts Found' `
                -Result 'INFO' `
                -Details $scopeNote
        }
    } else {
        Add-AVDCheckResult `
            -Category 'Storage' `
            -CheckName 'Storage Accounts Found' `
            -Result 'INFO' `
            -Details "Found $($allAccounts.Count) storage account(s) across the subscription"
    }

    # Helper closure: runs the three checks (identity auth, TLS, port 445) for one account.
    # $rgLabel is prepended to every Details string so the RG is always visible in the CSV.
    $checkAccount = {
        param($sa, [string]$rgLabel, [bool]$skipPort)

        $saName = $sa.StorageAccountName
        $saRg   = $sa.ResourceGroupName

        $auth = $sa.AzureFilesIdentityBasedAuth
        if ($null -ne $auth) {
            $mode = [string]$auth.DirectoryServiceOptions
            switch ($mode) {
                'None' {
                    Add-AVDCheckResult `
                        -Category 'Storage' `
                        -CheckName "${rgLabel}SA '$saName'  -  Identity Auth" `
                        -Result 'WARN' `
                        -Details "[RG: $saRg] No identity-based SMB auth configured (DirectoryServiceOptions = None)" `
                        -HowToFix "For Entra ID-joined AVD: Enable Entra Kerberos auth on the storage account. For AD DS: Use AzFilesHybrid module to join the storage account to your domain. See the documentation." `
                        -DocLink 'https://learn.microsoft.com/azure/storage/files/storage-files-identity-auth-overview'
                }
                'AADKERB' {
                    Add-AVDCheckResult `
                        -Category 'Storage' `
                        -CheckName "${rgLabel}SA '$saName'  -  Identity Auth" `
                        -Result 'PASS' `
                        -Details "[RG: $saRg] Microsoft Entra Kerberos auth (AADKERB) configured  -  compatible with Entra ID-joined AVD hosts"
                }
                'AD' {
                    $ad = $auth.ActiveDirectoryProperties
                    $domOk = ($null -ne $ad) -and (-not [string]::IsNullOrWhiteSpace([string]$ad.DomainName))
                    if ($domOk) {
                        Add-AVDCheckResult `
                            -Category 'Storage' `
                            -CheckName "${rgLabel}SA '$saName'  -  Identity Auth" `
                            -Result 'PASS' `
                            -Details "[RG: $saRg] AD DS auth configured. Domain: $($ad.DomainName)"
                    } else {
                        Add-AVDCheckResult `
                            -Category 'Storage' `
                            -CheckName "${rgLabel}SA '$saName'  -  Identity Auth" `
                            -Result 'WARN' `
                            -Details "[RG: $saRg] AD DS selected but domain metadata appears incomplete (DomainName missing)" `
                            -HowToFix 'Re-run Join-AzStorageAccount from the AzFilesHybrid module on a domain-joined machine to populate AD metadata correctly.'
                    }
                }
                'AADDS' {
                    Add-AVDCheckResult `
                        -Category 'Storage' `
                        -CheckName "${rgLabel}SA '$saName'  -  Identity Auth" `
                        -Result 'PASS' `
                        -Details "[RG: $saRg] Microsoft Entra Domain Services configured"
                }
                default {
                    Add-AVDCheckResult `
                        -Category 'Storage' `
                        -CheckName "${rgLabel}SA '$saName'  -  Identity Auth" `
                        -Result 'INFO' `
                        -Details "[RG: $saRg] Directory service mode: $mode"
                }
            }
        }

        $tlsVer = [string]$sa.MinimumTlsVersion
        if ($tlsVer -in @('TLS1_0','TLS1_1')) {
            Add-AVDCheckResult `
                -Category 'Storage' `
                -CheckName "${rgLabel}SA '$saName'  -  TLS Version" `
                -Result 'WARN' `
                -Details "[RG: $saRg] Minimum TLS: $tlsVer. TLS 1.2 required for Azure Files security compliance." `
                -HowToFix "Set-AzStorageAccount -Name '$saName' -ResourceGroupName '$saRg' -MinimumTlsVersion TLS1_2"
        } else {
            Add-AVDCheckResult `
                -Category 'Storage' `
                -CheckName "${rgLabel}SA '$saName'  -  TLS Version" `
                -Result 'PASS' `
                -Details "[RG: $saRg] Minimum TLS: $tlsVer"
        }

        if (-not $skipPort) {
            $fqdn = "$saName.file.core.windows.net"
            try {
                $tcp = Test-AVDTcpPort -ComputerName $fqdn -Port 445
                if ($tcp) {
                    Add-AVDCheckResult `
                        -Category 'Storage' `
                        -CheckName "${rgLabel}SA '$saName'  -  SMB Port 445" `
                        -Result 'PASS' `
                        -Details "[RG: $saRg] Port 445 reachable from this host to $fqdn"
                } else {
                    Add-AVDCheckResult `
                        -Category 'Storage' `
                        -CheckName "${rgLabel}SA '$saName'  -  SMB Port 445" `
                        -Result 'WARN' `
                        -Details "[RG: $saRg] Port 445 not reachable FROM THIS WORKSTATION to $fqdn  -  this is common on admin/dev machines" `
                        -HowToFix '1. Port 445 is only required on session host VMs, not on the machine running this script. 2. To verify authoritative reachability, run this test from within the session host subnet. 3. If session hosts use Private Endpoints for storage, SMB traffic stays on the private network and never tests clean from external machines.' `
                        -DocLink 'https://learn.microsoft.com/azure/storage/files/storage-troubleshoot-windows-file-connection-problems#cause-1-port-445-is-blocked'
                }
            } catch {
                Add-AVDCheckResult `
                    -Category 'Storage' `
                    -CheckName "${rgLabel}SA '$saName'  -  SMB Port 445" `
                    -Result 'WARN' `
                    -Details "[RG: $saRg] Could not test port 445: $($_.Exception.Message)"
            }
        }
    }

    # --- Accounts inside the selected resource group (primary scope) ---
    foreach ($sa in $inRGAccounts) {
        & $checkAccount $sa '' ([bool]$SkipPortTest)
    }

    # --- Accounts outside the selected resource group (informational) ---
    foreach ($sa in $outRGAccounts) {
        Add-AVDCheckResult `
            -Category 'Storage' `
            -CheckName "[Outside selected RG] SA '$($sa.StorageAccountName)'  -  Scope Note" `
            -Result 'INFO' `
            -Details "[RG: $($sa.ResourceGroupName)] This account is OUTSIDE your selected resource group '$ResourceGroupName'. It is evaluated for completeness but is likely not part of this AVD deployment. If it is intended for FSLogix, move or recreate it within '$ResourceGroupName'."
        & $checkAccount $sa '[Outside selected RG] ' ([bool]$SkipPortTest)
    }
}

#endregion

#region -- Identity Validation -------------------------------------------------

function Test-AVDDomainConnectivity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$DomainName
    )

    Write-AVDSection -Title "ACTIVE DIRECTORY CONNECTIVITY  -  $DomainName"

    try {
        $dnsHits = @(Resolve-DnsName -Name $DomainName -Type A -ErrorAction Stop | Select-Object -First 5)
        if ($dnsHits.Count -gt 0) {
            $ips = ($dnsHits | ForEach-Object { $_.IPAddress }) -join ', '
            Add-AVDCheckResult `
                -Category 'Identity' `
                -CheckName "AD DNS Resolution  -  $DomainName" `
                -Result 'INFO' `
                -Details "Resolves from this host to: $ips; session-host DNS resolution is not proven"

            $firstIp = $dnsHits[0].IPAddress
            try {
                $ldap = Test-AVDTcpPort -ComputerName $firstIp -Port 389
                if ($ldap) {
                    Add-AVDCheckResult `
                        -Category 'Identity' `
                        -CheckName "LDAP Port 389  -  $firstIp" `
                        -Result 'INFO' `
                        -Details 'Domain controller reachable from this host on LDAP port 389; session-host reachability is not proven'
                } else {
                    Add-AVDCheckResult `
                        -Category 'Identity' `
                        -CheckName "LDAP Port 389  -  $firstIp" `
                        -Result 'WARN' `
                        -Details "This host cannot reach DC $firstIp on port 389; the session-host result is unknown" `
                        -HowToFix 'Repeat DNS and LDAP tests inside a VM on the target session-host subnet before changing NSGs, routing, peering, or DNS.' `
                        -DocLink 'https://learn.microsoft.com/azure/virtual-desktop/create-host-pools-azure-marketplace#active-directory'
                }
                } catch {
                    Write-AVDLog -Level 'WARN' -Message ("LDAP connectivity test failed for domain controller '{0}': {1}" -f $firstIp, $_.Exception.Message)
                }

            try {
                $ldaps = Test-AVDTcpPort -ComputerName $firstIp -Port 636
                $ldapsResult = if ($ldaps) { 'PASS' } else { 'INFO' }
                $ldapsDetail = if ($ldaps) { "LDAPS port 636 reachable on $firstIp" } else { "LDAPS port 636 not reachable on $firstIp (optional but recommended)" }
                Add-AVDCheckResult `
                    -Category 'Identity' `
                    -CheckName "LDAPS Port 636  -  $firstIp" `
                    -Result $ldapsResult `
                    -Details $ldapsDetail `
                    -HowToFix 'Enable LDAPS on domain controllers and open port 636 in NSGs for secure LDAP communication.'
            } catch {
                Write-AVDLog -Level 'WARN' -Message ("LDAPS connectivity test failed for domain controller '{0}': {1}" -f $firstIp, $_.Exception.Message)
            }

        } else {
            Add-AVDCheckResult `
                -Category 'Identity' `
                -CheckName "AD DNS Resolution  -  $DomainName" `
                -Result 'FAIL' `
                -Details "No A records returned for domain '$DomainName'" `
                -Roadblock 'Session hosts need to resolve the domain name to perform domain join and Kerberos authentication.' `
                -HowToFix 'Verify the VNet DNS is set to domain controller IPs (not Azure DNS) so the domain FQDN can be resolved within the VNet.'
        }
    } catch {
        Add-AVDCheckResult `
            -Category 'Identity' `
            -CheckName "AD DNS Resolution  -  $DomainName" `
            -Result 'FAIL' `
            -Details "DNS lookup failed: $($_.Exception.Message)" `
            -Roadblock "Cannot resolve '$DomainName'. Session hosts on this network will fail domain join." `
            -HowToFix 'Check VNet DNS configuration and ensure custom DNS servers point to domain controllers that can resolve the domain.'
    }
}

function Test-AVDEntraIDRequirements {
    [CmdletBinding()]
    param()

    Write-AVDSection -Title 'ENTRA ID (AZURE AD) REQUIREMENTS'

    try {
        $avdSp = Get-AzADServicePrincipal -ApplicationId '9cdead84-a844-4324-93f2-b2e6bb768d07' -ErrorAction SilentlyContinue
        if ($null -ne $avdSp) {
            Add-AVDCheckResult `
                -Category 'Identity' `
                -CheckName 'AVD Service Principal (Windows Virtual Desktop)' `
                -Result 'PASS' `
                -Details "Present in tenant. ObjectId: $($avdSp.Id)"
        } else {
            Add-AVDCheckResult `
                -Category 'Identity' `
                -CheckName 'AVD Service Principal (Windows Virtual Desktop)' `
                -Result 'FAIL' `
                -Details 'Service principal 9cdead84-a844-4324-93f2-b2e6bb768d07 not found in tenant' `
                -Roadblock 'This service principal enables the AVD service to interact with your tenant (agent registration, session brokering, scaling). Without it, host pool registration will fail.' `
                -HowToFix 'A Global Administrator must consent to the app. Navigate to: https://login.microsoftonline.com/TENANT_ID/adminconsent?client_id=9cdead84-a844-4324-93f2-b2e6bb768d07  (replace TENANT_ID). Or run: New-AzADServicePrincipal -ApplicationId 9cdead84-a844-4324-93f2-b2e6bb768d07' `
                -DocLink 'https://learn.microsoft.com/azure/virtual-desktop/overview#requirements'
        }
    } catch {
        Add-AVDCheckResult `
            -Category 'Identity' `
            -CheckName 'AVD Service Principal (Windows Virtual Desktop)' `
            -Result 'WARN' `
            -Details "Cannot query Entra ID service principals: $($_.Exception.Message)" `
            -HowToFix 'Check that your account has the Global Reader or Application Developer role in Entra ID to enumerate service principals.'
    }

    try {
        $rdSp = Get-AzADServicePrincipal -ApplicationId 'a4a365df-50f1-4397-bc59-1a1564b8bb9c' -ErrorAction SilentlyContinue
        if ($null -ne $rdSp) {
            Add-AVDCheckResult `
                -Category 'Identity' `
                -CheckName 'Microsoft Remote Desktop SP (SSO)' `
                -Result 'PASS' `
                -Details "Present in tenant. Required for AVD Single Sign-On (SSO)."
        } else {
            Add-AVDCheckResult `
                -Category 'Identity' `
                -CheckName 'Microsoft Remote Desktop SP (SSO)' `
                -Result 'WARN' `
                -Details 'Microsoft Remote Desktop SP not found. SSO (enablerdsaadauth) will not work without it.' `
                -HowToFix 'Consent to app: https://login.microsoftonline.com/TENANT_ID/adminconsent?client_id=a4a365df-50f1-4397-bc59-1a1564b8bb9c (replace TENANT_ID)' `
                -DocLink 'https://learn.microsoft.com/azure/virtual-desktop/configure-single-sign-on'
        }
    } catch {
        Write-AVDLog -Level 'WARN' -Message ("Could not validate Microsoft Remote Desktop service principal: {0}" -f $_.Exception.Message)
    }

    Add-AVDCheckResult `
        -Category 'Identity' `
        -CheckName 'Conditional Access (Manual Review)' `
        -Result 'INFO' `
        -Details 'Manually verify that Conditional Access policies do not block app IDs: 9cdead84-a844-4324-93f2-b2e6bb768d07 (Azure Virtual Desktop) and a4a365df-50f1-4397-bc59-1a1564b8bb9c (Microsoft Remote Desktop).' `
        -DocLink 'https://learn.microsoft.com/azure/virtual-desktop/set-up-mfa'
}

function Test-AVDEntraIDKerberosHybrid {
    [CmdletBinding()]
    param([string]$DomainName)

    Write-AVDSection -Title 'ENTRA ID KERBEROS HYBRID IDENTITY VALIDATION'

    # Entra Connect Health service principal
    try {
        $aadchSp = Get-AzADServicePrincipal -ApplicationId 'cb1056e2-e479-49de-ae31-7812af012ed8' -ErrorAction SilentlyContinue
        if ($null -ne $aadchSp) {
            Add-AVDCheckResult `
                -Category 'Identity-HybridKerberos' `
                -CheckName 'Microsoft Entra Connect Health SP' `
                -Result 'PASS' `
                -Details "Present in tenant (ObjectId: $($aadchSp.Id)). Entra Connect Health is or was configured."
        } else {
            Add-AVDCheckResult `
                -Category 'Identity-HybridKerberos' `
                -CheckName 'Microsoft Entra Connect Health SP' `
                -Result 'WARN' `
                -Details 'Microsoft Entra Connect Health service principal (cb1056e2) not found. Sync health monitoring may be unavailable or Entra Connect is not installed.' `
                -HowToFix 'Install the Microsoft Entra Connect Health agent on your Entra Connect server and DCs. See: https://aka.ms/aadconnecthealth' `
                -DocLink 'https://learn.microsoft.com/azure/active-directory/hybrid/connect/whatis-azure-ad-connect-health'
        }
    } catch {}

    # Storage accounts with AADKERB auth configured
    try {
        $accounts = @(Get-AzStorageAccount -ErrorAction SilentlyContinue)
        $aadkerbAccounts = $accounts | Where-Object {
            $null -ne $_.AzureFilesIdentityBasedAuth -and
            [string]$_.AzureFilesIdentityBasedAuth.DirectoryServiceOptions -eq 'AADKERB'
        }
        if ($null -ne $aadkerbAccounts -and @($aadkerbAccounts).Count -gt 0) {
            $saNames = ($aadkerbAccounts | ForEach-Object { $_.StorageAccountName }) -join ', '
            Add-AVDCheckResult `
                -Category 'Identity-HybridKerberos' `
                -CheckName 'Storage Accounts - Entra Kerberos Auth (AADKERB)' `
                -Result 'PASS' `
                -Details "$(@($aadkerbAccounts).Count) account(s) with AADKERB configured: $saNames" `
                -DocLink 'https://learn.microsoft.com/azure/storage/files/storage-files-identity-auth-azure-active-directory-enable'
        } else {
            Add-AVDCheckResult `
                -Category 'Identity-HybridKerberos' `
                -CheckName 'Storage Accounts - Entra Kerberos Auth (AADKERB)' `
                -Result 'WARN' `
                -Details 'No storage accounts found with Entra Kerberos (AADKERB) auth configured. FSLogix with Entra ID Kerberos Hybrid requires AADKERB on the Azure Files storage account.' `
                -HowToFix 'Enable Entra Kerberos on the storage account: Azure Portal > Storage Account > File Shares > Active Directory > Microsoft Entra Kerberos. Then assign Storage File Data SMB Share Contributor to session host identities.' `
                -DocLink 'https://learn.microsoft.com/azure/storage/files/storage-files-identity-auth-azure-active-directory-enable'
        }
    } catch {
        Write-AVDLog -Level 'WARN' -Message ("Could not enumerate storage accounts for AADKERB validation: {0}" -f $_.Exception.Message)
    }

    # Hybrid Azure AD Join requirement (manual check - informational)
    Add-AVDCheckResult `
        -Category 'Identity-HybridKerberos' `
        -CheckName 'Hybrid Azure AD Join (Manual Check)' `
        -Result 'INFO' `
        -Details 'Session hosts MUST be Hybrid Azure AD Joined (domain-joined AND registered with Entra ID). After deployment, verify device state shows "Hybrid Azure AD Joined" in Entra ID > Devices.' `
        -HowToFix 'Configure Hybrid Azure AD Join in the Entra Connect wizard: Tasks > Configure device options > Configure Hybrid Azure AD Join. Ensure the OU containing session host computer accounts is in scope for sync.' `
        -DocLink 'https://learn.microsoft.com/azure/active-directory/devices/hybrid-join-plan'

    # UPN suffix synchronisation (manual check)
    Add-AVDCheckResult `
        -Category 'Identity-HybridKerberos' `
        -CheckName 'UPN Suffix Synchronisation (Manual Check)' `
        -Result 'INFO' `
        -Details 'Users UPN suffix must match a verified domain in Entra ID and be synchronised via Entra Connect. Mismatched UPN suffixes prevent Kerberos ticket acquisition for Azure Files, causing FSLogix mount failures.' `
        -HowToFix 'In Entra ID: Settings > Domain names - verify the on-prem UPN suffix is listed and verified. In Entra Connect: confirm userPrincipalName is mapped and in-scope for sync.' `
        -DocLink 'https://learn.microsoft.com/azure/storage/files/storage-files-identity-auth-azure-active-directory-enable#prerequisites'

    # Password Hash Sync / PTA requirement (manual check)
    Add-AVDCheckResult `
        -Category 'Identity-HybridKerberos' `
        -CheckName 'Password Hash Sync / Pass-Through Auth (Manual Check)' `
        -Result 'INFO' `
        -Details 'Entra Kerberos for Azure Files uses on-prem credentials synced to Entra ID. Password Hash Sync (PHS) or Pass-Through Authentication (PTA) is required. Pure ADFS federation without PHS is NOT supported for this scenario.' `
        -HowToFix 'In Entra Connect: Optional Features > verify Password Hash Synchronization is enabled, or confirm PTA agent health. For ADFS environments, enable PHS as a backup authentication method alongside federation.' `
        -DocLink 'https://learn.microsoft.com/azure/storage/files/storage-files-identity-auth-azure-active-directory-enable#enable-azure-ad-kerberos-authentication'

    # AzureADKerberos computer object (domain-specific check)
    if ($DomainName) {
        Add-AVDCheckResult `
            -Category 'Identity-HybridKerberos' `
            -CheckName "AzureADKerberos Object in '$DomainName' (Manual Check)" `
            -Result 'INFO' `
            -Details "Enabling AADKERB on a storage account creates an AzureADKerberos computer object and Kerberos server key in domain '$DomainName'. Confirm this object exists after enabling Entra Kerberos on the storage account." `
            -HowToFix "From a domain-joined machine: Get-ADComputer -Filter {Name -eq 'AzureADKerberos'} -Properties * | Select Name,DistinguishedName to verify the object was created." `
            -DocLink 'https://learn.microsoft.com/azure/storage/files/storage-files-identity-auth-azure-active-directory-enable#create-a-kerberos-server-in-azure-ad'
    }
}

function Test-AVDEntraDSReadiness {
    [CmdletBinding()]
    param(
        [string]$TargetRegion,
        [string]$ResourceGroupName
    )

    Write-AVDSection -Title 'MICROSOFT ENTRA DOMAIN SERVICES (ENTRA DS) READINESS'

    try {
        $aaddsResources = @(Get-AzResource -ResourceType 'Microsoft.AAD/domainServices' -ErrorAction SilentlyContinue)

        if ($aaddsResources.Count -eq 0) {
            Add-AVDCheckResult `
                -Category 'Identity-EntraDS' `
                -CheckName 'Entra Domain Services Instance' `
                -Result 'FAIL' `
                -Details 'No Microsoft Entra Domain Services managed domain found in this subscription.' `
                -Roadblock 'The EntraDS identity model requires an active Entra DS managed domain in a VNet accessible to AVD session hosts. Session hosts cannot be domain-joined without it.' `
                -HowToFix 'Enable Entra DS in the Azure Portal: Microsoft Entra ID > Microsoft Entra Domain Services > Create. Provisioning takes 30-60 minutes. Place the managed domain in a VNet peered to the AVD session host VNet.' `
                -DocLink 'https://learn.microsoft.com/azure/active-directory-domain-services/tutorial-create-instance'
            return
        }

        foreach ($aadds in $aaddsResources) {
            Add-AVDCheckResult `
                -Category 'Identity-EntraDS' `
                -CheckName "Entra DS Instance: $($aadds.Name)" `
                -Result 'PASS' `
                -Details "Found in resource group '$($aadds.ResourceGroupName)' | Location: $($aadds.Location)"

            if ($TargetRegion) {
                $normalRegion = $TargetRegion.ToLower().Replace(' ','')
                if ($aadds.Location -ne $normalRegion) {
                    Add-AVDCheckResult `
                        -Category 'Identity-EntraDS' `
                        -CheckName "Entra DS '$($aadds.Name)' - Region Alignment" `
                        -Result 'WARN' `
                        -Details "Entra DS is in region '$($aadds.Location)' but AVD target is '$TargetRegion'. Cross-region authentication adds latency to every user session." `
                        -HowToFix 'Add a replica set in the target AVD region: Azure Portal > Entra DS > Replica Sets > Add. Replica sets distribute DC workload and reduce latency for session hosts.' `
                        -DocLink 'https://learn.microsoft.com/azure/active-directory-domain-services/concepts-replica-sets'
                } else {
                    Add-AVDCheckResult `
                        -Category 'Identity-EntraDS' `
                        -CheckName "Entra DS '$($aadds.Name)' - Region Alignment" `
                        -Result 'PASS' `
                        -Details "Entra DS is co-located in target region '$TargetRegion'"
                }
            }
        }

        # Storage accounts with AADDS auth
        try {
            $accounts = @(Get-AzStorageAccount -ErrorAction SilentlyContinue)
            $aaddsAccounts = $accounts | Where-Object {
                $null -ne $_.AzureFilesIdentityBasedAuth -and
                [string]$_.AzureFilesIdentityBasedAuth.DirectoryServiceOptions -eq 'AADDS'
            }
            if ($null -ne $aaddsAccounts -and @($aaddsAccounts).Count -gt 0) {
                $saNames = ($aaddsAccounts | ForEach-Object { $_.StorageAccountName }) -join ', '
                Add-AVDCheckResult `
                    -Category 'Identity-EntraDS' `
                    -CheckName 'Storage Accounts - Entra DS Auth (AADDS)' `
                    -Result 'PASS' `
                    -Details "$(@($aaddsAccounts).Count) account(s) with Entra DS (AADDS) auth configured: $saNames"
            } else {
                Add-AVDCheckResult `
                    -Category 'Identity-EntraDS' `
                    -CheckName 'Storage Accounts - Entra DS Auth (AADDS)' `
                    -Result 'WARN' `
                    -Details 'No storage accounts found with Entra Domain Services auth. FSLogix requires AADDS auth mode on the Azure Files storage account for Entra DS-joined session hosts.' `
                    -HowToFix 'Azure Portal > Storage Account > File shares > Active Directory > Microsoft Entra Domain Services. The storage account VNet must have connectivity to the Entra DS VNet.' `
                    -DocLink 'https://learn.microsoft.com/azure/storage/files/storage-files-identity-auth-domain-services-enable'
            }
        } catch {
            Write-AVDLog -Level 'WARN' -Message ("Could not enumerate storage accounts for AADDS validation: {0}" -f $_.Exception.Message)
        }

        # NSG requirements for Entra DS subnet
        Add-AVDCheckResult `
            -Category 'Identity-EntraDS' `
            -CheckName 'Entra DS Subnet NSG Requirements (Manual Check)' `
            -Result 'INFO' `
            -Details 'The Entra DS dedicated subnet requires its own NSG with Microsoft-prescribed inbound rules (Allow TCP 443 from AzureActiveDirectoryDomainServices service tag, plus RDP/TCP 3389 from CorpNetSaw for MS support). The Azure Portal Entra DS Health blade will alert if required rules are missing.' `
            -HowToFix 'Navigate to: Azure Portal > Entra DS instance > Health > scroll to Alerts. Fix any NSG-related alerts shown there. Apply rules to the Entra DS subnet NSG only, not the session host subnet NSG.' `
            -DocLink 'https://learn.microsoft.com/azure/active-directory-domain-services/alert-nsg'

        # Limitations informational
        Add-AVDCheckResult `
            -Category 'Identity-EntraDS' `
            -CheckName 'Entra DS Feature Limitations (Informational)' `
            -Result 'INFO' `
            -Details 'Entra DS does NOT support: on-premises forest trusts (limited preview), Kerberos Constrained Delegation (KCD), AD schema extensions, NTLM v1, custom OU writeback to on-prem. Evaluate these gaps for enterprise AVD before choosing this identity model.' `
            -DocLink 'https://learn.microsoft.com/azure/active-directory-domain-services/comparison'

    } catch {
        Add-AVDCheckResult `
            -Category 'Identity-EntraDS' `
            -CheckName 'Entra Domain Services Assessment' `
            -Result 'WARN' `
            -Details "Error querying Entra DS resources: $($_.Exception.Message)" `
            -HowToFix 'Ensure the Microsoft.AAD resource provider is registered and your account has at least Reader role on the subscription.'
    }
}

function Test-AVDEntraJoinReadiness {
    [CmdletBinding()]
    param(
        [string]$ResourceGroupName
    )

    Write-AVDSection -Title 'MICROSOFT ENTRA JOIN READINESS'

    # Users of Entra-joined session hosts need one of these roles on the VMs (or a scope above them).
    $signInRoles = [ordered]@{
        'Virtual Machine User Login'          = 'fb879df8-f326-4884-b1cf-06f3ad86be52'
        'Virtual Machine Administrator Login' = '1c0163c0-47e6-4577-8991-ea5c82e286e4'
    }
    $scopeLabel = if ($ResourceGroupName) { "resource group '$ResourceGroupName'" } else { 'the subscription' }

    try {
        $found = @()
        $rgScope = if ($ResourceGroupName) { '/subscriptions/{0}/resourceGroups/{1}' -f (Get-AzContext).Subscription.Id, $ResourceGroupName }
        foreach ($roleName in $signInRoles.Keys) {
            # -ResourceGroupName cannot be combined with -RoleDefinitionId; -Scope can.
            $assignments = if ($ResourceGroupName) {
                @(Get-AzRoleAssignment -Scope $rgScope -RoleDefinitionId $signInRoles[$roleName] -ErrorAction Stop)
            } else {
                @(Get-AzRoleAssignment -RoleDefinitionId $signInRoles[$roleName] -ErrorAction Stop)
            }
            if ($assignments.Count -gt 0) { $found += "$roleName ($($assignments.Count) assignment(s))" }
        }

        if ($found.Count -gt 0) {
            Add-AVDCheckResult `
                -Category 'Identity-EntraID' `
                -CheckName 'VM Sign-in Role Assignments' `
                -Result 'PASS' `
                -Details "Applies to ${scopeLabel} (assigned there or above): $($found -join '; ')"
        } else {
            Add-AVDCheckResult `
                -Category 'Identity-EntraID' `
                -CheckName 'VM Sign-in Role Assignments' `
                -Result 'WARN' `
                -Details "No Virtual Machine User Login or Virtual Machine Administrator Login assignment found in $scopeLabel." `
                -Roadblock 'Users cannot sign in to Microsoft Entra-joined session hosts without one of these roles, even when they are assigned to the application group.' `
                -HowToFix "Assign the role to the AVD user group on the session hosts' resource group: New-AzRoleAssignment -ObjectId <group object id> -RoleDefinitionName 'Virtual Machine User Login' -ResourceGroupName <session host RG>" `
                -DocLink 'https://learn.microsoft.com/azure/virtual-desktop/azure-ad-joined-session-hosts#assign-user-access-to-host-pools'
        }
    } catch {
        Add-AVDCheckResult `
            -Category 'Identity-EntraID' `
            -CheckName 'VM Sign-in Role Assignments' `
            -Result 'WARN' `
            -Details "Could not read role assignments in ${scopeLabel}: $($_.Exception.Message)" `
            -HowToFix 'Run with an account that can read role assignments (Reader is enough), or check in the portal: resource group > Access control (IAM) > Role assignments.' `
            -DocLink 'https://learn.microsoft.com/azure/virtual-desktop/azure-ad-joined-session-hosts#assign-user-access-to-host-pools'
    }
}

#endregion

#region -- RBAC Validation -----------------------------------------------------

function Test-AVDRBACRequirements {
    [CmdletBinding()]
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName
    )

    Write-AVDSection -Title 'RBAC & PERMISSION ASSESSMENT'

    try {
        $ctx     = Get-AzContext -ErrorAction Stop
        $account = $ctx.Account.Id
        $subId   = if ($SubscriptionId) { $SubscriptionId } else { $ctx.Subscription.Id }
        $subScope = "/subscriptions/$subId"
        $rgScope  = if ($ResourceGroupName) { "$subScope/resourceGroups/$ResourceGroupName" } else { $null }

        # --- Subscription-level check (always performed) ---
        $subAssignments = Get-AzRoleAssignment -SignInName $account -Scope $subScope -ErrorAction SilentlyContinue
        if ($null -eq $subAssignments) { $subAssignments = @() } else { $subAssignments = @($subAssignments) }
        $subRoles = $subAssignments | Select-Object -ExpandProperty RoleDefinitionName -Unique

        if ($subRoles -and $subRoles.Count -gt 0) {
            Add-AVDCheckResult `
                -Category 'RBAC' `
                -CheckName "Subscription Scope: $account" `
                -Result 'PASS' `
                -Details "Roles at subscription scope: $($subRoles -join ', ')"
        } else {
            Add-AVDCheckResult `
                -Category 'RBAC' `
                -CheckName "Subscription Scope: $account" `
                -Result 'FAIL' `
                -Details "No role assignments found at subscription scope: $subScope" `
                -Roadblock 'Without any Azure role at subscription level, subscription-wide operations (provider registration, quota checks) will fail.' `
                -HowToFix 'Contact your Azure subscription owner to assign at least the Reader role at subscription scope.'
        }

        # --- Resource Group-level check (only when RG is provided) ---
        $rgRoles = @()
        if ($rgScope) {
            $rgAssignments = Get-AzRoleAssignment -SignInName $account -Scope $rgScope -ErrorAction SilentlyContinue
            if ($null -eq $rgAssignments) { $rgAssignments = @() } else { $rgAssignments = @($rgAssignments) }
            $rgRoles = $rgAssignments | Select-Object -ExpandProperty RoleDefinitionName -Unique

            if ($rgRoles -and $rgRoles.Count -gt 0) {
                Add-AVDCheckResult `
                    -Category 'RBAC' `
                    -CheckName "Resource Group Scope: $ResourceGroupName" `
                    -Result 'PASS' `
                    -Details "Roles at RG scope: $($rgRoles -join ', ')"
            } else {
                Add-AVDCheckResult `
                    -Category 'RBAC' `
                    -CheckName "Resource Group Scope: $ResourceGroupName" `
                    -Result 'WARN' `
                    -Details "No direct role assignments at RG scope '$ResourceGroupName' (may be inherited from subscription)" `
                    -HowToFix "Assign at least Contributor on resource group '$ResourceGroupName' for AVD deployment operations."
            }
        }

        # --- Effective role set (union of sub + RG roles) for downstream checks ---
        $roles = @($subRoles) + @($rgRoles) | Select-Object -Unique

        if ($roles -and $roles.Count -gt 0) {
            $hasRead = $roles | Where-Object { $_ -in @('Reader','Contributor','Owner') }
            if ($null -eq $hasRead) {
                Add-AVDCheckResult `
                    -Category 'RBAC' `
                    -CheckName 'Minimum Reader Role' `
                    -Result 'FAIL' `
                    -Details 'Account has no Reader, Contributor, or Owner role at subscription or RG scope. Full validation requires at minimum Reader.' `
                    -Roadblock 'Without Reader access, many validation checks cannot run, and all AVD deployment operations will fail with authorization errors.' `
                    -HowToFix 'Request assignment of the Reader role on the subscription or resource group from your administrator.'
            }

            $dvRole = $roles | Where-Object { $_ -like 'Desktop Virtualization*' -or $_ -in @('Contributor','Owner') }
            if ($null -eq $dvRole) {
                Add-AVDCheckResult `
                    -Category 'RBAC' `
                    -CheckName 'Desktop Virtualization Permissions' `
                    -Result 'WARN' `
                    -Details 'No Desktop Virtualization or Contributor role found at subscription or RG scope. Post-deployment AVD operations will fail.' `
                    -HowToFix "Assign 'Desktop Virtualization Contributor' role to manage host pools, app groups, and session hosts."
            } else {
                Add-AVDCheckResult `
                    -Category 'RBAC' `
                    -CheckName 'Desktop Virtualization Permissions' `
                    -Result 'PASS' `
                    -Details 'Sufficient permissions for AVD resource management found'
            }
        } else {
            Add-AVDCheckResult `
                -Category 'RBAC' `
                -CheckName "Current Account: $account" `
                -Result 'FAIL' `
                -Details 'No role assignments found at subscription or resource group scope.' `
                -Roadblock 'Without any Azure role, no resource operations (read or write) are possible. Deployment will fail.' `
                -HowToFix 'Contact your Azure subscription owner to assign at least the Reader role.'
        }

        $deployRoles = @(
            [PSCustomObject]@{ Role='Contributor or Owner';                     Scope='Resource Group (AVD)';           Purpose='Create host pools, session host VMs, app groups, workspaces' }
            [PSCustomObject]@{ Role='User Access Administrator or Owner';        Scope='Resource Group or Subscription'; Purpose='Assign Desktop Virtualization User roles to user groups' }
            [PSCustomObject]@{ Role='Virtual Machine Contributor';              Scope='Session Host Resource Group';    Purpose='Register VMs as session hosts and manage VM resources' }
            [PSCustomObject]@{ Role='Network Contributor';                      Scope='VNet Resource Group';            Purpose='Create NICs and attach session hosts to the network' }
            [PSCustomObject]@{ Role='Key Vault Secrets Officer';                Scope='Key Vault (if used)';            Purpose='Read domain join password and other deployment secrets' }
            [PSCustomObject]@{ Role='Storage File Data SMB Share Contributor';  Scope='Storage Account';               Purpose='FSLogix profile container access by session host identity' }
            [PSCustomObject]@{ Role='Desktop Virtualization Contributor';       Scope='Host Pool';                     Purpose='Assign scaling plans, manage registration tokens, manage app groups' }
        )

        Write-AVDLog -Level 'INFO' -Message 'Required roles for full AVD deployment (informational):'
        foreach ($r in $deployRoles) {
            Add-AVDCheckResult `
                -Category 'RBAC' `
                -CheckName "Required Role: $($r.Role)" `
                -Result 'INFO' `
                -Details "Scope: $($r.Scope). Purpose: $($r.Purpose)"
        }

    } catch {
        Add-AVDCheckResult `
            -Category 'RBAC' `
            -CheckName 'RBAC Assessment' `
            -Result 'WARN' `
            -Details "Error reading role assignments: $($_.Exception.Message)"
    }
}

#endregion

#region -- Monitoring ----------------------------------------------------------

function Test-AVDMonitoringReadiness {
    [CmdletBinding()]
    param([string]$ResourceGroupName)

    Write-AVDSection -Title 'MONITORING READINESS (AZURE MONITOR / LOG ANALYTICS)'

    try {
        $wsCmd = if ($ResourceGroupName) {
            Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        } else {
            Get-AzOperationalInsightsWorkspace -ErrorAction SilentlyContinue
        }
        $workspaces = @($wsCmd)

        if ($workspaces.Count -gt 0) {
            Add-AVDCheckResult `
                -Category 'Monitoring' `
                -CheckName 'Log Analytics Workspace' `
                -Result 'PASS' `
                -Details "Found $($workspaces.Count) workspace(s): $($workspaces.Name -join ', ')"
        } else {
            Add-AVDCheckResult `
                -Category 'Monitoring' `
                -CheckName 'Log Analytics Workspace' `
                -Result 'WARN' `
                -Details 'No Log Analytics workspaces found. AVD Insights requires a Log Analytics workspace.' `
                -HowToFix "Create a Log Analytics workspace in the AVD resource group. Enable AVD Insights diagnostics after deployment to monitor session host health, performance, and user sessions." `
                -DocLink 'https://learn.microsoft.com/azure/virtual-desktop/azure-monitor'
        }
    } catch {
        Add-AVDCheckResult `
            -Category 'Monitoring' `
            -CheckName 'Log Analytics Workspace' `
            -Result 'INFO' `
            -Details "Could not query Log Analytics (Az.OperationalInsights module may not be loaded): $($_.Exception.Message)"
    }
}

#endregion

#region -- Key Vault -----------------------------------------------------------

function Test-AVDKeyVaultReadiness {
    [CmdletBinding()]
    param([string]$ResourceGroupName)

    Write-AVDSection -Title 'KEY VAULT READINESS'

    try {
        $kvs = @(if ($ResourceGroupName) {
            Get-AzKeyVault -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        } else {
            Get-AzKeyVault -ErrorAction SilentlyContinue
        })

        if ($kvs.Count -eq 0) {
            Add-AVDCheckResult `
                -Category 'KeyVault' `
                -CheckName 'Key Vaults' `
                -Result 'INFO' `
                -Details 'No Key Vaults found. Key Vault is strongly recommended for storing domain join passwords, SP secrets, and certificates.' `
                -HowToFix "Create a Key Vault in the AVD resource group with soft-delete and purge protection enabled." `
                -DocLink 'https://learn.microsoft.com/azure/key-vault/general/best-practices'
            return
        }

        Add-AVDCheckResult `
            -Category 'KeyVault' `
            -CheckName 'Key Vaults' `
            -Result 'INFO' `
            -Details "Found $($kvs.Count) Key Vault(s)"

        foreach ($kv in $kvs) {
            if ($kv.EnableSoftDelete -eq $false) {
                Add-AVDCheckResult `
                    -Category 'KeyVault' `
                    -CheckName "KV '$($kv.VaultName)'  -  Soft Delete" `
                    -Result 'WARN' `
                    -Details 'Soft delete is disabled. Accidental secret deletion cannot be recovered.' `
                    -HowToFix "Update-AzKeyVault -VaultName '$($kv.VaultName)' -ResourceGroupName '$($kv.ResourceGroupName)' -EnableSoftDelete"
            } else {
                Add-AVDCheckResult `
                    -Category 'KeyVault' `
                    -CheckName "KV '$($kv.VaultName)'  -  Soft Delete" `
                    -Result 'PASS' `
                    -Details 'Soft delete enabled'
            }
            if ($kv.EnablePurgeProtection -ne $true) {
                Add-AVDCheckResult `
                    -Category 'KeyVault' `
                    -CheckName "KV '$($kv.VaultName)'  -  Purge Protection" `
                    -Result 'WARN' `
                    -Details 'Purge protection not enabled. Required for regulatory compliance in many environments.' `
                    -HowToFix "Update-AzKeyVault -VaultName '$($kv.VaultName)' -ResourceGroupName '$($kv.ResourceGroupName)' -EnablePurgeProtection"
            } else {
                Add-AVDCheckResult `
                    -Category 'KeyVault' `
                    -CheckName "KV '$($kv.VaultName)'  -  Purge Protection" `
                    -Result 'PASS' `
                    -Details 'Purge protection enabled'
            }
        }
    } catch {
        Add-AVDCheckResult `
            -Category 'KeyVault' `
            -CheckName 'Key Vault Assessment' `
            -Result 'INFO' `
            -Details "Cannot read Key Vaults: $($_.Exception.Message)"
    }
}

#endregion

#region -- AVD-Specific Checks -------------------------------------------------

function Test-AVDServiceConfiguration {
    [CmdletBinding()]
    param([string]$ResourceGroupName)

    Write-AVDSection -Title 'EXISTING AVD RESOURCE CONFIGURATION'

    try {
        $hpCmd = if ($ResourceGroupName) {
            Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        } else {
            Get-AzResource -ResourceType 'Microsoft.DesktopVirtualization/hostPools' -ErrorAction SilentlyContinue |
                ForEach-Object { Get-AzWvdHostPool -Name $_.Name -ResourceGroupName $_.ResourceGroupName -ErrorAction SilentlyContinue }
        }
        $hostPools = @($hpCmd)

        if ($hostPools.Count -eq 0) {
            Add-AVDCheckResult `
                -Category 'AVD' `
                -CheckName 'Host Pools' `
                -Result 'INFO' `
                -Details 'No existing host pools found  -  this may be a greenfield deployment'
            return
        }

        Add-AVDCheckResult `
            -Category 'AVD' `
            -CheckName 'Host Pools' `
            -Result 'INFO' `
            -Details "Found $($hostPools.Count) host pool(s)"

        foreach ($hp in $hostPools) {
            $hpName = $hp.Name
            $rdp    = [string]$hp.CustomRdpProperty

            if ($rdp -match 'targetisaadjoined:i:1') {
                Add-AVDCheckResult `
                    -Category 'AVD' `
                    -CheckName "HostPool '$hpName'  -  Entra ID Join RDP Property" `
                    -Result 'PASS' `
                    -Details 'targetisaadjoined:i:1 is set'
            } elseif ($IdentityModel -eq 'EntraID' -and $rdp -notmatch 'enablerdsaadauth:i:1') {
                # With single sign-on enabled the property is not needed; without either, many clients cannot connect.
                Add-AVDCheckResult `
                    -Category 'AVD' `
                    -CheckName "HostPool '$hpName'  -  Entra ID Join RDP Property" `
                    -Result 'WARN' `
                    -Details 'Neither targetisaadjoined:i:1 nor single sign-on (enablerdsaadauth:i:1) is set. Users connecting from devices that are not joined to this Entra tenant cannot sign in to Entra-joined session hosts.' `
                    -HowToFix "Enable single sign-on (recommended), or add the property: Update-AzWvdHostPool -Name '$hpName' -ResourceGroupName <RG> -CustomRdpProperty 'targetisaadjoined:i:1;$rdp'" `
                    -DocLink 'https://learn.microsoft.com/azure/virtual-desktop/azure-ad-joined-session-hosts'
            } else {
                Add-AVDCheckResult `
                    -Category 'AVD' `
                    -CheckName "HostPool '$hpName'  -  Entra ID Join RDP Property" `
                    -Result 'INFO' `
                    -Details 'targetisaadjoined not set (required only for Entra ID-joined session hosts)' `
                    -HowToFix "If using Entra ID-joined session hosts, add: Update-AzWvdHostPool -Name '$hpName' -ResourceGroupName <RG> -CustomRdpProperty 'targetisaadjoined:i:1;$rdp'"
            }

            if ($rdp -match 'enablerdsaadauth:i:1') {
                Add-AVDCheckResult `
                    -Category 'AVD' `
                    -CheckName "HostPool '$hpName'  -  SSO (enablerdsaadauth)" `
                    -Result 'PASS' `
                    -Details 'SSO is enabled (enablerdsaadauth:i:1)'
            } else {
                Add-AVDCheckResult `
                    -Category 'AVD' `
                    -CheckName "HostPool '$hpName'  -  SSO (enablerdsaadauth)" `
                    -Result 'INFO' `
                    -Details 'SSO (enablerdsaadauth:i:1) not configured. Users will be prompted for credentials on each session.' `
                    -HowToFix "Enable SSO: Update-AzWvdHostPool -Name '$hpName' -ResourceGroupName <RG> -CustomRdpProperty 'enablerdsaadauth:i:1;$rdp'" `
                    -DocLink 'https://learn.microsoft.com/azure/virtual-desktop/configure-single-sign-on'
            }

            Add-AVDCheckResult `
                -Category 'AVD' `
                -CheckName "HostPool '$hpName'  -  Type" `
                -Result 'INFO' `
                -Details "HostPoolType: $($hp.HostPoolType) | LoadBalancerType: $($hp.LoadBalancerType) | MaxSessions: $($hp.MaxSessionLimit)"

            # Users see a host pool's desktops and apps only through an application group they are assigned to.
            $hpRg = ($hp.Id -split '/')[4]
            $appGroups = @(Get-AzWvdApplicationGroup -ResourceGroupName $hpRg -ErrorAction SilentlyContinue |
                Where-Object { [string]$_.HostPoolArmPath -eq [string]$hp.Id })
            if ($appGroups.Count -eq 0) {
                Add-AVDCheckResult `
                    -Category 'AVD' `
                    -CheckName "HostPool '$hpName'  -  Application Groups" `
                    -Result 'WARN' `
                    -Details "No application group in resource group '$hpRg' is linked to this host pool." `
                    -HowToFix 'Create a desktop or RemoteApp application group for the host pool and register it in a workspace.' `
                    -DocLink 'https://learn.microsoft.com/azure/virtual-desktop/manage-app-groups'
            }
            foreach ($ag in $appGroups) {
                $assigned = @(Get-AzRoleAssignment -Scope $ag.Id -RoleDefinitionName 'Desktop Virtualization User' -ErrorAction SilentlyContinue)
                Add-AVDCheckResult `
                    -Category 'AVD' `
                    -CheckName "AppGroup '$($ag.Name)'  -  User Assignment" `
                    -Result $(if ($assigned.Count -gt 0) { 'PASS' } else { 'WARN' }) `
                    -Details "$($assigned.Count) Desktop Virtualization User assignment(s)" `
                    -Roadblock $(if ($assigned.Count -eq 0) { 'No user sees this application group in the Remote Desktop client.' } else { '' }) `
                    -HowToFix $(if ($assigned.Count -eq 0) { "Assign the users group to application group '$($ag.Name)' (Assignments), which grants Desktop Virtualization User." } else { '' }) `
                    -DocLink 'https://learn.microsoft.com/azure/virtual-desktop/manage-app-groups'
            }
        }

    } catch {
        Add-AVDCheckResult `
            -Category 'AVD' `
            -CheckName 'AVD Resources' `
            -Result 'WARN' `
            -Details "Cannot read AVD resources: $($_.Exception.Message)" `
            -HowToFix 'Ensure Az.DesktopVirtualization module is installed and your account has Reader access to AVD resources.'
    }
}

function Test-AVDImageReadiness {
    [CmdletBinding()]
    param([string]$ResourceGroupName)

    Write-AVDSection -Title 'IMAGE GALLERY & COMPUTE IMAGE READINESS'

    try {
        $galleries = @(if ($ResourceGroupName) {
            Get-AzGallery -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        } else {
            Get-AzGallery -ErrorAction SilentlyContinue
        })

        if ($galleries.Count -eq 0) {
            Add-AVDCheckResult `
                -Category 'Images' `
                -CheckName 'Azure Compute Gallery' `
                -Result 'INFO' `
                -Details 'No Azure Compute Gallery found. Custom golden images require a gallery. Marketplace images can be used without one.' `
                -HowToFix 'Create an Azure Compute Gallery to store and version custom AVD session host images (Windows 11 multi-session with recommended apps).' `
                -DocLink 'https://learn.microsoft.com/azure/virtual-machines/shared-image-galleries'
            return
        }

        foreach ($gallery in $galleries) {
            try {
                $images = @(Get-AzGalleryImageDefinition -GalleryName $gallery.Name -ResourceGroupName $gallery.ResourceGroupName -ErrorAction SilentlyContinue)
                Add-AVDCheckResult `
                    -Category 'Images' `
                    -CheckName "Gallery '$($gallery.Name)'" `
                    -Result 'PASS' `
                    -Details "Found gallery with $($images.Count) image definition(s)"

                foreach ($img in $images) {
                    $versions = @(Get-AzGalleryImageVersion -GalleryName $gallery.Name `
                                    -GalleryImageDefinitionName $img.Name `
                                    -ResourceGroupName $gallery.ResourceGroupName `
                                    -ErrorAction SilentlyContinue)
                    if ($versions.Count -gt 0) {
                        $latest = $versions | Sort-Object { [System.Version]($_.Name -replace '[^\d\.]','') } -Descending | Select-Object -First 1
                        Add-AVDCheckResult `
                            -Category 'Images' `
                            -CheckName "Image '$($img.Name)'" `
                            -Result 'PASS' `
                            -Details "OS: $($img.OsType) | $($versions.Count) version(s). Latest: $($latest.Name)"
                    } else {
                        Add-AVDCheckResult `
                            -Category 'Images' `
                            -CheckName "Image '$($img.Name)'" `
                            -Result 'WARN' `
                            -Details 'Image definition exists but has no published versions' `
                            -HowToFix 'Create and publish at least one image version using Azure Image Builder or a manually generalized VM.'
                    }
                }
            } catch {
                Write-AVDLog -Level 'WARN' -Message ("Could not enumerate versions for gallery image '{0}': {1}" -f $img.Name, $_.Exception.Message)
            }
        }
    } catch {
        Add-AVDCheckResult `
            -Category 'Images' `
            -CheckName 'Azure Compute Gallery' `
            -Result 'INFO' `
            -Details "Could not enumerate galleries: $($_.Exception.Message)"
    }
}

#endregion

# ==============================================================================
# INTERACTIVE SETUP WIZARD
# ==============================================================================

#region -- Setup Wizard --------------------------------------------------------

function Get-AVDWizardMenuChoice {
    [CmdletBinding()]
    param(
        [string]$Prompt  = '  Enter your choice',
        [int]$Min        = 1,
        [int]$Max        = 9,
        [int]$Default    = 1
    )
    while ($true) {
        $raw = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        if ($raw -match '^\d+$') {
            $n = [int]$raw
            if ($n -ge $Min -and $n -le $Max) { return $n }
        }
        Write-Host "  Invalid choice. Please enter a number between $Min and $Max." -ForegroundColor Yellow
    }
}

function Invoke-AVDSetupWizard {
    [CmdletBinding()]
    param()

    Clear-Host

    $line70 = '-' * 70
    $eq70   = '=' * 70

    Write-Host ''
    Write-Host "  $eq70" -ForegroundColor Cyan
    Write-Host '  AZURE VIRTUAL DESKTOP  -  READINESS ASSESSMENT WIZARD' -ForegroundColor Cyan
    Write-Host "  $eq70" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Welcome! This wizard will guide you through a quick, read-only assessment' -ForegroundColor White
    Write-Host '  of your Azure environment to ensure it is ready for Azure Virtual Desktop.' -ForegroundColor White
    Write-Host ''
    Write-Host '  WHAT IS AZURE VIRTUAL DESKTOP (AVD)?' -ForegroundColor Cyan
    Write-Host '  AVD lets your employees securely access their Windows desktops and apps' -ForegroundColor Gray
    Write-Host '  from any device, anywhere  -  all hosted in Microsoft Azure cloud.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  WHAT DOES THIS TOOL DO?' -ForegroundColor Cyan
    Write-Host '  It performs a read-only inspection of your Azure account to flag any' -ForegroundColor Gray
    Write-Host '  issues that would prevent a successful AVD deployment. Nothing is changed.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  HOW TO USE THIS WIZARD' -ForegroundColor Cyan
    Write-Host '  Answer 7 simple questions below. Press ENTER at any prompt to accept' -ForegroundColor Gray
    Write-Host '  the suggested default shown in [square brackets].' -ForegroundColor Gray
    Write-Host ''
    Write-Host "  $line70" -ForegroundColor DarkGray
    Write-Host ''
    $null = Read-Host '  Press ENTER to begin  '

    $config = [ordered]@{
        AuthMethod            = 'CurrentContext'
        WizardAuthenticated   = $false
        SubscriptionId        = ''
        TenantId              = ''
        TargetRegion          = ''
        VmSku                 = 'Standard_D4s_v5'
        PlannedSessionHosts   = 10
        IdentityModel         = 'All'
        DomainName            = ''
        ResourceGroupName     = ''
        ExportReport          = $true
        ReportPath            = $(if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path })
        SkipConnectivityTests = $false
    }

    $wizardSubs = @()   # track for confirmation display

    # =========================================================================
    # STEP 1  -  SIGN IN TO AZURE
    # =========================================================================
    Clear-Host
    Write-Host ''
    Write-Host "  $line70" -ForegroundColor White
    Write-Host '  STEP 1 of 7  -  SIGN IN TO AZURE' -ForegroundColor White
    Write-Host "  $line70" -ForegroundColor White
    Write-Host ''
    Write-Host '  To assess your environment, this tool needs to connect to your Azure account.' -ForegroundColor Gray
    Write-Host '  How would you like to sign in?' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  [1] Open a browser window to sign in (recommended for most users)' -ForegroundColor White
    Write-Host '      A login window will pop up in your default browser.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [2] Device code login  (enter a short code on a web page)' -ForegroundColor White
    Write-Host '      Use this if the browser popup is blocked or you are on a server.' -ForegroundColor DarkGray
    Write-Host '      You will be given a code and a URL to visit.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [3] I am already signed in  (reuse my existing session)' -ForegroundColor White
    Write-Host '      Use this if you have already run Connect-AzAccount in this window.' -ForegroundColor DarkGray
    Write-Host ''

    $authChoice = Get-AVDWizardMenuChoice -Min 1 -Max 3 -Default 1

    switch ($authChoice) {
        1 { $config.AuthMethod = 'Interactive'    }
        2 { $config.AuthMethod = 'DeviceCode'     }
        3 { $config.AuthMethod = 'CurrentContext' }
    }

    # Perform authentication now so we can enumerate subscriptions in Step 2
    $wizAuthOk = $false
    $wizAuthError = $null
    try {
        if ($config.AuthMethod -eq 'CurrentContext') {
            $existingCtx = Get-AzContext -ErrorAction SilentlyContinue
            if ($null -ne $existingCtx) {
                Write-Host ''
                Write-Host "  Using existing session  -  signed in as: $($existingCtx.Account.Id)" -ForegroundColor Green
                $wizAuthOk = $true
            } else {
                Write-Host ''
                Write-Host '  No existing session found. Opening browser for sign-in...' -ForegroundColor Yellow
                Disconnect-AzAccount -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
                Connect-AzAccount -ErrorAction Stop | Out-Null
                $config.AuthMethod = 'Interactive'
                $existingCtx = Get-AzContext -ErrorAction Stop
                Write-Host "  Signed in as: $($existingCtx.Account.Id)" -ForegroundColor Green
                $wizAuthOk = $true
            }
        } elseif ($config.AuthMethod -eq 'Interactive') {
            Write-Host ''
            Write-Host '  Opening browser window  -  please complete the sign-in in your browser...' -ForegroundColor Cyan
            Disconnect-AzAccount -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
            Connect-AzAccount -ErrorAction Stop | Out-Null
            $existingCtx = Get-AzContext -ErrorAction Stop
            Write-Host "  Signed in successfully as: $($existingCtx.Account.Id)" -ForegroundColor Green
            $wizAuthOk = $true
        } elseif ($config.AuthMethod -eq 'DeviceCode') {
            Write-Host ''
            Write-Host '  Starting device code sign-in...' -ForegroundColor Cyan
            Write-Host '  Follow the instructions above to visit the URL and enter the code shown.' -ForegroundColor Gray
            Write-Host ''
            Disconnect-AzAccount -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
            Connect-AzAccount -UseDeviceAuthentication -ErrorAction Stop | Out-Null
            $existingCtx = Get-AzContext -ErrorAction Stop
            Write-Host "  Signed in successfully as: $($existingCtx.Account.Id)" -ForegroundColor Green
            $wizAuthOk = $true
        }
    } catch {
        $wizAuthError = $_.Exception.Message
    }

    $config.WizardAuthenticated = $wizAuthOk

    # =========================================================================
    # STEP 2  -  SELECT SUBSCRIPTION
    # =========================================================================
    Clear-Host
    Write-Host ''
    Write-Host "  $line70" -ForegroundColor White
    Write-Host '  STEP 2 of 7  -  YOUR AZURE SUBSCRIPTION' -ForegroundColor White
    Write-Host "  $line70" -ForegroundColor White
    Write-Host ''
    Write-Host '  An Azure Subscription is your billing account in Azure  -  think of it as' -ForegroundColor Gray
    Write-Host '  a container that holds all your cloud resources and receives the monthly bill.' -ForegroundColor Gray
    Write-Host '  Select the subscription where AVD will be deployed.' -ForegroundColor Gray
    Write-Host ''

    # The sign-in result is shown here, not on the Step 1 screen, which is cleared
    # before anyone can read it (a browser that already knows the account signs in
    # without showing a page, so this line is the only sign that it happened).
    if ($wizAuthOk) {
        Write-Host "  Signed in as: $($existingCtx.Account.Id)" -ForegroundColor Green
    } else {
        Write-Host "  Sign-in did not complete: $wizAuthError" -ForegroundColor Red
    }
    Write-Host ''

    if ($wizAuthOk) {
        try {
            $wizardSubs = @(Get-AzSubscription -ErrorAction Stop |
                            Where-Object { $_.State -eq 'Enabled' } |
                            Sort-Object Name)
            $currentSubId = (Get-AzContext -ErrorAction SilentlyContinue).Subscription.Id

            if ($wizardSubs.Count -eq 0) {
                Write-Host '  No enabled subscriptions found. Will use the current context subscription.' -ForegroundColor Yellow
            } elseif ($wizardSubs.Count -eq 1) {
                $config.SubscriptionId = $wizardSubs[0].Id
                Write-Host "  Only one subscription found  -  automatically selected:" -ForegroundColor Green
                Write-Host "  $($wizardSubs[0].Name)" -ForegroundColor White
                Write-Host "  ID: $($wizardSubs[0].Id)" -ForegroundColor DarkGray
                Write-Host ''
                $null = Read-Host '  Press ENTER to continue'
            } else {
                Write-Host '  Your available subscriptions:' -ForegroundColor White
                Write-Host ''
                for ($i = 0; $i -lt $wizardSubs.Count; $i++) {
                    $cur = if ($wizardSubs[$i].Id -eq $currentSubId) { '  <- currently active' } else { '' }
                    Write-Host ("  [{0,2}] {1}{2}" -f ($i + 1), $wizardSubs[$i].Name, $cur) -ForegroundColor White
                    Write-Host ("        ID: {0}" -f $wizardSubs[$i].Id) -ForegroundColor DarkGray
                }
                Write-Host ''
                $subChoice = Get-AVDWizardMenuChoice `
                    -Prompt '  Enter the number of the subscription to assess' `
                    -Min 1 -Max $wizardSubs.Count -Default 1
                $config.SubscriptionId = $wizardSubs[$subChoice - 1].Id
                Set-AzContext -SubscriptionId $config.SubscriptionId -ErrorAction SilentlyContinue | Out-Null
                Write-Host ''
                Write-Host "  Selected: $($wizardSubs[$subChoice-1].Name)" -ForegroundColor Green
            }
        } catch {
            Write-Host "  Could not retrieve the subscription list: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host '  The assessment will use the subscription of the current session.' -ForegroundColor DarkGray
            Write-Host ''
            $null = Read-Host '  Press ENTER to continue'
        }
    } else {
        Write-Host '  Subscription selection is skipped. The assessment tries the same sign-in again' -ForegroundColor Yellow
        Write-Host '  before it starts. If that fails too, run the script again and choose [2] device code.' -ForegroundColor Yellow
        Write-Host ''
        $null = Read-Host '  Press ENTER to continue'
    }

    # =========================================================================
    # STEP 3  -  DEPLOYMENT REGION
    # =========================================================================
    Clear-Host
    Write-Host ''
    Write-Host "  $line70" -ForegroundColor White
    Write-Host '  STEP 3 of 7  -  AZURE DEPLOYMENT REGION' -ForegroundColor White
    Write-Host "  $line70" -ForegroundColor White
    Write-Host ''
    Write-Host '  Which Azure data center do you plan to deploy AVD in?' -ForegroundColor Gray
    Write-Host '  Choose the location geographically closest to your users for best performance.' -ForegroundColor Gray
    Write-Host '  If you are unsure, ask your IT team or pick the city nearest your main office.' -ForegroundColor Gray
    Write-Host ''

    # Core 15 regions shown on first page
    $regionsCore = @(
        [PSCustomObject]@{ Label = 'East US 2            (Virginia, USA)';         Value = 'eastus2'            }
        [PSCustomObject]@{ Label = 'East US              (Virginia, USA)';         Value = 'eastus'             }
        [PSCustomObject]@{ Label = 'West US 2            (Washington, USA)';       Value = 'westus2'            }
        [PSCustomObject]@{ Label = 'West US 3            (Arizona, USA)';          Value = 'westus3'            }
        [PSCustomObject]@{ Label = 'Central US           (Iowa, USA)';             Value = 'centralus'          }
        [PSCustomObject]@{ Label = 'South Central US     (Texas, USA)';            Value = 'southcentralus'     }
        [PSCustomObject]@{ Label = 'North Europe         (Ireland)';               Value = 'northeurope'        }
        [PSCustomObject]@{ Label = 'West Europe          (Netherlands)';           Value = 'westeurope'         }
        [PSCustomObject]@{ Label = 'UK South             (London, UK)';            Value = 'uksouth'            }
        [PSCustomObject]@{ Label = 'UK West              (Cardiff, UK)';           Value = 'ukwest'             }
        [PSCustomObject]@{ Label = 'Canada Central       (Toronto, Canada)';       Value = 'canadacentral'      }
        [PSCustomObject]@{ Label = 'Australia East       (New South Wales)';       Value = 'australiaeast'      }
        [PSCustomObject]@{ Label = 'Southeast Asia       (Singapore)';             Value = 'southeastasia'      }
        [PSCustomObject]@{ Label = 'Japan East           (Tokyo, Japan)';          Value = 'japaneast'          }
        [PSCustomObject]@{ Label = 'Brazil South         (Sao Paulo, Brazil)';     Value = 'brazilsouth'        }
    )

    # Additional regions shown on "more" page
    $regionsExtra = @(
        [PSCustomObject]@{ Label = 'France Central       (Paris, France)';         Value = 'francecentral'      }
        [PSCustomObject]@{ Label = 'Germany West Central (Frankfurt, Germany)';    Value = 'germanywestcentral' }
        [PSCustomObject]@{ Label = 'Switzerland North    (Zurich, Switzerland)';   Value = 'switzerlandnorth'   }
        [PSCustomObject]@{ Label = 'Norway East          (Oslo, Norway)';          Value = 'norwayeast'         }
        [PSCustomObject]@{ Label = 'Poland Central       (Warsaw, Poland)';        Value = 'polandcentral'      }
        [PSCustomObject]@{ Label = 'Sweden Central       (Gavle, Sweden)';         Value = 'swedencentral'      }
        [PSCustomObject]@{ Label = 'Canada East          (Quebec City, Canada)';   Value = 'canadaeast'         }
        [PSCustomObject]@{ Label = 'Mexico Central       (Queretaro, Mexico)';     Value = 'mexicocentral'      }
        [PSCustomObject]@{ Label = 'Korea Central        (Seoul, Korea)';          Value = 'koreacentral'       }
        [PSCustomObject]@{ Label = 'Japan West           (Osaka, Japan)';          Value = 'japanwest'          }
        [PSCustomObject]@{ Label = 'East Asia            (Hong Kong)';             Value = 'eastasia'           }
        [PSCustomObject]@{ Label = 'Central India        (Pune, India)';           Value = 'centralindia'       }
        [PSCustomObject]@{ Label = 'South India          (Chennai, India)';        Value = 'southindia'         }
        [PSCustomObject]@{ Label = 'Australia Southeast  (Victoria, Australia)';   Value = 'australiasoutheast' }
        [PSCustomObject]@{ Label = 'UAE North            (Dubai, UAE)';            Value = 'uaenorth'           }
        [PSCustomObject]@{ Label = 'South Africa North   (Johannesburg)';          Value = 'southafricanorth'   }
    )

    # Region selection loop with paging
    $regionSelected  = $false
    $showExtraPage   = $false

    while (-not $regionSelected) {
        if ($showExtraPage) {
            # -- More regions page ------------------------------------------------
            Clear-Host
            Write-Host ''
            Write-Host "  $line70" -ForegroundColor White
            Write-Host '  STEP 3 of 7  -  AZURE DEPLOYMENT REGION  (More Options)' -ForegroundColor White
            Write-Host "  $line70" -ForegroundColor White
            Write-Host ''

            for ($i = 0; $i -lt $regionsExtra.Count; $i++) {
                Write-Host ("  [{0,2}] {1}" -f ($i + 1), $regionsExtra[$i].Label) -ForegroundColor Gray
            }
            $nExtra = $regionsExtra.Count
            Write-Host ''
            Write-Host ("  [{0,2}] Back to main region list" -f ($nExtra + 1)) -ForegroundColor DarkGray
            Write-Host ("  [{0,2}] Enter region name manually" -f ($nExtra + 2)) -ForegroundColor DarkGray
            Write-Host ''

            $regionChoice = Get-AVDWizardMenuChoice -Prompt '  Enter your choice' -Min 1 -Max ($nExtra + 2) -Default 1

            if ($regionChoice -eq $nExtra + 1) {
                $showExtraPage = $false   # loop back to core list
            } elseif ($regionChoice -eq $nExtra + 2) {
                Write-Host ''
                $config.TargetRegion = (Read-Host '  Enter the Azure region name (e.g. eastus2, westeurope)').Trim().ToLower()
                $regionSelected = $true
            } else {
                $config.TargetRegion = $regionsExtra[$regionChoice - 1].Value
                Write-Host "  Selected: $($regionsExtra[$regionChoice - 1].Label)" -ForegroundColor Green
                $regionSelected = $true
            }
        } else {
            # -- Core 15 regions page ---------------------------------------------
            for ($i = 0; $i -lt $regionsCore.Count; $i++) {
                Write-Host ("  [{0,2}] {1}" -f ($i + 1), $regionsCore[$i].Label) -ForegroundColor Gray
            }
            $nCore = $regionsCore.Count
            Write-Host ''
            Write-Host ("  [{0,2}] More Azure regions  (Europe extras, Asia Pacific, Middle East...)" -f ($nCore + 1)) -ForegroundColor Cyan
            Write-Host ("  [{0,2}] Enter region name manually" -f ($nCore + 2)) -ForegroundColor DarkGray
            Write-Host ''

            $regionChoice = Get-AVDWizardMenuChoice -Prompt '  Enter your choice' -Min 1 -Max ($nCore + 2) -Default 1

            if ($regionChoice -eq $nCore + 1) {
                $showExtraPage = $true   # loop to extra page
            } elseif ($regionChoice -eq $nCore + 2) {
                Write-Host ''
                $config.TargetRegion = (Read-Host '  Enter the Azure region name (e.g. eastus2, westeurope)').Trim().ToLower()
                $regionSelected = $true
            } else {
                $config.TargetRegion = $regionsCore[$regionChoice - 1].Value
                Write-Host "  Selected: $($regionsCore[$regionChoice - 1].Label)" -ForegroundColor Green
                $regionSelected = $true
            }
        }
    }

    # =========================================================================
    # STEP 4  -  VM SIZE AND SESSION HOST COUNT
    # =========================================================================
    Clear-Host
    Write-Host ''
    Write-Host "  $line70" -ForegroundColor White
    Write-Host '  STEP 4 of 7  -  VIRTUAL MACHINE SIZE' -ForegroundColor White
    Write-Host "  $line70" -ForegroundColor White
    Write-Host ''
    Write-Host '  Session hosts are the virtual machines (VMs) your users connect to remotely.' -ForegroundColor Gray
    Write-Host '  Multiple users can share one VM at the same time.' -ForegroundColor Gray
    Write-Host '  Larger VMs can support more simultaneous users but cost more per hour.' -ForegroundColor Gray
    Write-Host '  Not sure what to pick?  Choose [1] for a safe, general-purpose default.' -ForegroundColor DarkGray
    Write-Host ''

    $skus = @(
        [PSCustomObject]@{ Label = 'Standard_D4s_v5   |  4 cores, 16 GB RAM  |  Light work: email, Office, web browsing (2-4 users)';          Value = 'Standard_D4s_v5'  }
        [PSCustomObject]@{ Label = 'Standard_D8s_v5   |  8 cores, 32 GB RAM  |  Office + moderate apps, small teams (4-8 users)';              Value = 'Standard_D8s_v5'  }
        [PSCustomObject]@{ Label = 'Standard_D16s_v5  | 16 cores, 64 GB RAM  |  Heavy workloads or large concurrent user counts';              Value = 'Standard_D16s_v5' }
        [PSCustomObject]@{ Label = 'Standard_E4s_v5   |  4 cores, 32 GB RAM  |  Memory-intensive: SharePoint, databases, developer tools';     Value = 'Standard_E4s_v5'  }
        [PSCustomObject]@{ Label = 'Standard_E8s_v5   |  8 cores, 64 GB RAM  |  Large in-memory workloads';                                   Value = 'Standard_E8s_v5'  }
        [PSCustomObject]@{ Label = 'Standard_F8s_v2   |  8 cores, 16 GB RAM  |  CPU-intensive: rendering, simulation, batch processing';       Value = 'Standard_F8s_v2'  }
        [PSCustomObject]@{ Label = 'I am not sure  -  use the recommended default (Standard_D4s_v5)';                                          Value = 'Standard_D4s_v5'  }
        [PSCustomObject]@{ Label = 'Enter a custom VM size name manually';                                                                      Value = '__manual__'       }
    )

    for ($i = 0; $i -lt $skus.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $skus[$i].Label) -ForegroundColor Gray
    }
    Write-Host ''

    $skuChoice = Get-AVDWizardMenuChoice -Prompt '  Enter your choice' -Min 1 -Max $skus.Count -Default 1

    if ($skus[$skuChoice - 1].Value -eq '__manual__') {
        Write-Host ''
        $config.VmSku = (Read-Host '  Enter VM size name (e.g. Standard_D4s_v5)').Trim()
    } else {
        $config.VmSku = $skus[$skuChoice - 1].Value
        Write-Host "  Selected: $($config.VmSku)" -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '  How many session host VMs do you plan to deploy in total?' -ForegroundColor Gray
    Write-Host '  This is used to estimate whether you have enough Azure quota.' -ForegroundColor Gray
    Write-Host '  A best estimate is fine  -  you can always re-run the check later.' -ForegroundColor DarkGray
    Write-Host ''

    while ($true) {
        $countInput = Read-Host '  Number of session hosts [10]'
        if ([string]::IsNullOrWhiteSpace($countInput)) { $config.PlannedSessionHosts = 10; break }
        if ($countInput -match '^\d+$' -and [int]$countInput -ge 1) {
            $config.PlannedSessionHosts = [int]$countInput
            break
        }
        Write-Host '  Please enter a whole number of 1 or more (e.g. 10).' -ForegroundColor Yellow
    }

    # =========================================================================
    # STEP 5  -  IDENTITY MODEL
    # =========================================================================
    Clear-Host
    Write-Host ''
    Write-Host "  $line70" -ForegroundColor White
    Write-Host '  STEP 5 of 7  -  HOW YOUR USERS ARE MANAGED' -ForegroundColor White
    Write-Host "  $line70" -ForegroundColor White
    Write-Host ''
    Write-Host '  AVD needs to know how your organisation manages user accounts and sign-ins.' -ForegroundColor Gray
    Write-Host '  If you are unsure of your setup, ask your IT team, or choose [5] to run' -ForegroundColor Gray
    Write-Host '  all checks and let the tool figure it out.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  [1] Cloud-only users  (Microsoft 365 / Entra ID only)' -ForegroundColor White
    Write-Host '      Your users ONLY have Microsoft 365 accounts (e.g. name@company.com).' -ForegroundColor Gray
    Write-Host '      There are no on-premises servers involved. Common for startups and' -ForegroundColor DarkGray
    Write-Host '      organisations that moved entirely to the cloud.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [2] On-premises Active Directory  (AD DS)' -ForegroundColor White
    Write-Host '      Your company has Windows Server domain controllers on-site.' -ForegroundColor Gray
    Write-Host '      Users log in as DOMAIN\username or user@yourdomain.local.' -ForegroundColor DarkGray
    Write-Host '      Common for traditional enterprises with on-site servers.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [3] Hybrid  -  On-premises AD + Microsoft 365  (most common enterprise setup)' -ForegroundColor White
    Write-Host '      Your on-premises Active Directory is synchronised with Microsoft 365.' -ForegroundColor Gray
    Write-Host '      Users use the same password on their computer and in Microsoft 365.' -ForegroundColor DarkGray
    Write-Host '      Common for large organisations using Entra Connect (Azure AD Connect).' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [4] Microsoft-managed domain  (Entra Domain Services)' -ForegroundColor White
    Write-Host '      Microsoft runs domain controllers in Azure on your behalf.' -ForegroundColor Gray
    Write-Host '      No on-premises servers required. Less common, specialist scenario.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [5] I am not sure  -  run all identity checks  (safest choice)' -ForegroundColor White
    Write-Host ''

    $idmChoice = Get-AVDWizardMenuChoice -Prompt '  Enter your choice' -Min 1 -Max 5 -Default 5
    $idmMap     = @{ 1 = 'EntraID'; 2 = 'ADDS'; 3 = 'EntraIDKerberos'; 4 = 'EntraDS'; 5 = 'All' }
    $config.IdentityModel = $idmMap[$idmChoice]

    $idmFriendly = @{
        'EntraID'         = 'Cloud-only (Entra ID)'
        'ADDS'            = 'On-premises Active Directory'
        'EntraIDKerberos' = 'Hybrid (Entra ID + on-premises AD)'
        'EntraDS'         = 'Microsoft-managed domain (Entra DS)'
        'All'             = 'All identity checks (recommended when unsure)'
    }
    Write-Host "  Selected: $($idmFriendly[$config.IdentityModel])" -ForegroundColor Green

    # Domain name prompt (only relevant for AD-related identity models)
    if ($config.IdentityModel -in @('ADDS', 'EntraIDKerberos', 'All')) {
        Write-Host ''
        Write-Host '  ACTIVE DIRECTORY DOMAIN NAME  (optional but improves the assessment)' -ForegroundColor White
        Write-Host ''
        Write-Host '  What is your Active Directory domain name?' -ForegroundColor Gray
        Write-Host '  This is the domain your computers are joined to  -  not an email address.' -ForegroundColor Gray
        Write-Host '  Examples:  contoso.local   corp.company.com   company.internal' -ForegroundColor DarkGray
        Write-Host '  (Press ENTER to skip; the AD connectivity test will be omitted)' -ForegroundColor DarkGray
        Write-Host ''
        $domInput = (Read-Host '  Domain name').Trim()
        $config.DomainName = $domInput
        if ($config.DomainName) {
            Write-Host "  Domain recorded: $($config.DomainName)" -ForegroundColor Green
        }
    }

    # =========================================================================
    # STEP 6  -  RESOURCE GROUP
    # =========================================================================
    Clear-Host
    Write-Host ''
    Write-Host "  $line70" -ForegroundColor White
    Write-Host '  STEP 6 of 7  -  RESOURCE GROUP  (optional)' -ForegroundColor White
    Write-Host "  $line70" -ForegroundColor White
    Write-Host ''
    Write-Host '  A Resource Group is a named folder in Azure that organises related resources' -ForegroundColor Gray
    Write-Host '  (like VMs, networks, and storage) together for management and billing.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  If you already have or plan to use a specific Resource Group for AVD,' -ForegroundColor Gray
    Write-Host '  enter its name here to focus the checks on that group.' -ForegroundColor Gray
    Write-Host '  Otherwise, press ENTER to scan the entire subscription.' -ForegroundColor Gray
    Write-Host ''

    if ($wizAuthOk) {
        try {
            $wizRGs = @(Get-AzResourceGroup -ErrorAction Stop | Sort-Object ResourceGroupName)
            if ($wizRGs.Count -gt 0) {
                Write-Host '  Here are the resource groups in your subscription:' -ForegroundColor Gray
                Write-Host ''
                for ($i = 0; $i -lt $wizRGs.Count; $i++) {
                    $loc = $wizRGs[$i].Location
                    Write-Host ("  [{0,2}] {1,-45} ({2})" -f ($i + 1), $wizRGs[$i].ResourceGroupName, $loc) -ForegroundColor Gray
                }
                $nRGs = $wizRGs.Count
                Write-Host ''
                Write-Host ("  [{0,2}] Scan ALL resource groups in the subscription" -f ($nRGs + 1)) -ForegroundColor Cyan
                Write-Host ("  [{0,2}] Enter a resource group name manually" -f ($nRGs + 2)) -ForegroundColor DarkGray
                Write-Host ''

                $rgChoice = Get-AVDWizardMenuChoice -Min 1 -Max ($nRGs + 2) -Default ($nRGs + 1)

                if ($rgChoice -le $nRGs) {
                    $config.ResourceGroupName = $wizRGs[$rgChoice - 1].ResourceGroupName
                    Write-Host "  Checks will be scoped to resource group: $($config.ResourceGroupName)" -ForegroundColor Green
                } elseif ($rgChoice -eq $nRGs + 1) {
                    $config.ResourceGroupName = ''
                    Write-Host '  Scanning all resource groups in the subscription.' -ForegroundColor Green
                } else {
                    $rgInput = (Read-Host '  Enter Resource Group name').Trim()
                    $config.ResourceGroupName = $rgInput
                    if ($config.ResourceGroupName) {
                        Write-Host "  Checks will be scoped to resource group: $($config.ResourceGroupName)" -ForegroundColor Green
                    } else {
                        Write-Host '  Scanning all resource groups in the subscription.' -ForegroundColor Green
                    }
                }
            } else {
                Write-Host '  No resource groups found in this subscription. Scanning subscription-wide.' -ForegroundColor Yellow
                $config.ResourceGroupName = ''
            }
        } catch {
            Write-Host '  Could not list resource groups. Enter a name or press ENTER to scan all.' -ForegroundColor Yellow
            $rgInput = (Read-Host '  Resource Group name  (or press ENTER to scan all)').Trim()
            $config.ResourceGroupName = $rgInput
            if ($config.ResourceGroupName) {
                Write-Host "  Checks will be scoped to resource group: $($config.ResourceGroupName)" -ForegroundColor Green
            } else {
                Write-Host '  Scanning all resource groups in the subscription.' -ForegroundColor Green
            }
        }
    } else {
        $rgInput = (Read-Host '  Resource Group name  (or press ENTER to scan all)').Trim()
        $config.ResourceGroupName = $rgInput
        if ($config.ResourceGroupName) {
            Write-Host "  Checks will be scoped to resource group: $($config.ResourceGroupName)" -ForegroundColor Green
        } else {
            Write-Host '  Scanning all resource groups in the subscription.' -ForegroundColor Green
        }
    }

    # =========================================================================
    # STEP 7  -  SAVE REPORT
    # =========================================================================
    Clear-Host
    Write-Host ''
    Write-Host "  $line70" -ForegroundColor White
    Write-Host '  STEP 7 of 7  -  SAVE A REPORT' -ForegroundColor White
    Write-Host "  $line70" -ForegroundColor White
    Write-Host ''
    Write-Host '  An Excel report will be saved automatically after the assessment completes.' -ForegroundColor Gray
    Write-Host '  Report location: script root folder' -ForegroundColor DarkGray
    Write-Host '  Report file name: <script-name>_yyyyMMdd_HHmmss.xlsx' -ForegroundColor DarkGray
    Write-Host ''

    $config.ExportReport = $true
    $config.ReportPath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    Write-Host "  Excel report will be saved to: $($config.ReportPath)" -ForegroundColor Green

    # =========================================================================
    # CONFIRMATION SUMMARY
    # =========================================================================
    Clear-Host
    Write-Host ''
    Write-Host "  $eq70" -ForegroundColor Cyan
    Write-Host '  READY TO START  -  CONFIGURATION SUMMARY' -ForegroundColor Cyan
    Write-Host "  $eq70" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Please review your selections before the assessment begins:' -ForegroundColor Gray
    Write-Host ''

    # Resolve display-friendly names
    $subDisplayName = ''
    if ($config.SubscriptionId -and $wizardSubs.Count -gt 0) {
        $matchedSub = $wizardSubs | Where-Object { $_.Id -eq $config.SubscriptionId } | Select-Object -First 1
        $subDisplayName = if ($matchedSub) { "$($matchedSub.Name)  ($($config.SubscriptionId))" } else { $config.SubscriptionId }
    }
    if (-not $subDisplayName) { $subDisplayName = '(current session context)' }

    $allRegionsFlat = @($regionsCore) + @($regionsExtra)
    $regionDisplayName = ($allRegionsFlat | Where-Object { $_.Value -eq $config.TargetRegion } | Select-Object -First 1).Label
    if (-not $regionDisplayName) { $regionDisplayName = $config.TargetRegion }

    Write-Host ("  {0,-20} {1}" -f 'Subscription:',  $subDisplayName) -ForegroundColor White
    Write-Host ("  {0,-20} {1}" -f 'Region:',         $regionDisplayName) -ForegroundColor White
    Write-Host ("  {0,-20} {1}  (x{2} session hosts planned)" -f 'VM Size:', $config.VmSku, $config.PlannedSessionHosts) -ForegroundColor White
    Write-Host ("  {0,-20} {1}" -f 'Identity Model:',  $idmFriendly[$config.IdentityModel]) -ForegroundColor White
    if ($config.DomainName) {
        Write-Host ("  {0,-20} {1}" -f 'AD Domain:', $config.DomainName) -ForegroundColor White
    }
    Write-Host ("  {0,-20} {1}" -f 'Resource Group:',
        $(if ($config.ResourceGroupName) { $config.ResourceGroupName } else { 'All groups in subscription' })) -ForegroundColor White
    Write-Host ("  {0,-20} {1}" -f 'Save Report:',
        $(if ($config.ExportReport) { "Yes  ->  $($config.ReportPath)" } else { 'No' })) -ForegroundColor White
    Write-Host ''
    Write-Host "  $line70" -ForegroundColor DarkGray
    Write-Host ''

    $confirm = Read-Host '  Press ENTER to start the assessment  (or type "restart" to go back to step 1)'
    if ($confirm -match 'restart') {
        return Invoke-AVDSetupWizard
    }

    Write-Host ''
    Write-Host '  Starting assessment...' -ForegroundColor Cyan
    Write-Host ''

    return $config
}

#endregion

# ==============================================================================
# MAIN SCRIPT
# ==============================================================================

#region -- Banner --------------------------------------------------------------

function Show-Banner {
    $psVer = "$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)"
    $bar   = '=' * 78
    $scriptName = if ($script:ReportScriptName) { $script:ReportScriptName } else { [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath) }
    $displayName = ($scriptName -replace '^\d+_', '' -replace '_Launcher$', '' -replace '_', ' ')
    $writeBannerLine = {
        param([string]$Text)
        Write-Host ('|  {0,-76}|' -f $Text) -ForegroundColor Cyan
    }
    Write-Host ''
    Write-Host "+$bar+" -ForegroundColor Cyan
    & $writeBannerLine $displayName
    & $writeBannerLine 'Azure Virtual Desktop  -  Tenant/Subscription Assessment'
    & $writeBannerLine "Version 1.1.0  |  PowerShell $psVer  |  READ-ONLY  -  No changes made"
    Write-Host "+$bar+" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  MINIMUM RBAC REQUIRED : Reader (Subscription) + Directory.Read (Entra ID)' -ForegroundColor Gray
    Write-Host '  OPERATIONS             : READ-ONLY. No resources are created or modified.' -ForegroundColor Gray
    Write-Host "  RUN AS                 : $env:USERNAME on $env:COMPUTERNAME" -ForegroundColor Gray
    Write-Host "  TIMESTAMP              : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
    Write-Host ''
    if ($TargetRegion)       { Write-Host "  Target Region      : $TargetRegion" -ForegroundColor White }
    if ($VmSku)              { Write-Host "  VM SKU             : $VmSku (x$PlannedSessionHosts hosts planned)" -ForegroundColor White }
    if ($DomainName)         { Write-Host "  AD Domain          : $DomainName" -ForegroundColor White }
    if ($ResourceGroupName)  { Write-Host "  Resource Group     : $ResourceGroupName" -ForegroundColor White }
    Write-Host "  Identity Model     : $IdentityModel" -ForegroundColor White
    Write-Host ''
}

#endregion

#region -- Module List ---------------------------------------------------------

$RequiredModules = @(
    @{ Name = 'Az.Accounts';             MinVersion = '2.12.0'; Required = $true  }
    @{ Name = 'Az.Compute';              MinVersion = '7.0.0';  Required = $true  }
    @{ Name = 'Az.Resources';            MinVersion = '6.0.0';  Required = $true  }
    @{ Name = 'Az.Network';              MinVersion = '5.0.0';  Required = $true  }
    @{ Name = 'Az.Storage';              MinVersion = '5.0.0';  Required = $true  }
    @{ Name = 'Az.KeyVault';             MinVersion = '4.0.0';  Required = $true  }
    @{ Name = 'Az.DesktopVirtualization';MinVersion = '3.0.0';  Required = $true  }
    @{ Name = 'Az.OperationalInsights';  MinVersion = '3.0.0';  Required = $false }
    @{ Name = 'ImportExcel';             MinVersion = '7.0.0';  Required = $true  }
)

#endregion

#region -- Required Resource Providers ----------------------------------------

$RequiredProviders = @(
    'Microsoft.DesktopVirtualization',
    'Microsoft.Compute',
    'Microsoft.Network',
    'Microsoft.Storage',
    'Microsoft.KeyVault',
    'Microsoft.Authorization',
    'Microsoft.ManagedIdentity',
    'Microsoft.Resources'
)

$RecommendedProviders = @(
    'Microsoft.OperationalInsights',
    'Microsoft.Insights',
    'Microsoft.GuestConfiguration'
)

#endregion

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

$script:ProcessExitCode = 0
$summary = $null

# -- Interactive Setup Wizard -------------------------------------------------
# Runs automatically when -NonInteractive is NOT specified.
# Walks the user through every setting with plain-English guidance, performs
# sign-in, and populates all script parameters before the assessment begins.
# Use -NonInteractive to skip the wizard entirely (CI/CD pipelines, AI agents).
# -----------------------------------------------------------------------------
try {
    # Report export is always enabled; it goes to -ReportPath when given, else to the script root.
    $ExportReport = $true
    if (-not $PSBoundParameters.ContainsKey('ReportPath')) { $ReportPath = $script:ReportRootPath }
    $PreferredAuthMethod = $null
    $ReuseExistingContext = $false

    if (-not $NonInteractive) {
        $wizCfg = Invoke-AVDSetupWizard
        if ($null -ne $wizCfg) {
            $PreferredAuthMethod    = $wizCfg.AuthMethod
            $ReuseExistingContext   = [bool]$wizCfg.WizardAuthenticated
            $SubscriptionId        = $wizCfg.SubscriptionId
            $TargetRegion          = $wizCfg.TargetRegion
            $VmSku                 = $wizCfg.VmSku
            $PlannedSessionHosts   = $wizCfg.PlannedSessionHosts
            $IdentityModel         = $wizCfg.IdentityModel
            $DomainName            = $wizCfg.DomainName
            $ResourceGroupName     = $wizCfg.ResourceGroupName
            $SkipConnectivityTests = $wizCfg.SkipConnectivityTests
        }
    }

    Show-Banner

    # -- STEP 1: PowerShell Environment -------------------------------------------
    Write-AVDSection -Title 'POWERSHELL ENVIRONMENT'

    $psVersion = $PSVersionTable.PSVersion
    if ($psVersion.Major -lt 5 -or ($psVersion.Major -eq 5 -and $psVersion.Minor -lt 1)) {
        Add-AVDCheckResult `
            -Category 'Environment' `
            -CheckName 'PowerShell Version' `
            -Result 'FAIL' `
            -Details "Running on PS $psVersion. Minimum required: 5.1" `
            -Roadblock 'Az PowerShell modules require PowerShell 5.1 or later. This script cannot run reliably on older versions.' `
            -HowToFix 'Upgrade to PowerShell 5.1 (Windows Management Framework 5.1) or install PowerShell 7.x from https://aka.ms/powershell'
    } else {
        Add-AVDCheckResult `
            -Category 'Environment' `
            -CheckName 'PowerShell Version' `
            -Result 'PASS' `
            -Details "PowerShell $psVersion"
    }

    if ($IsLinux -or $IsMacOS) {
        Add-AVDCheckResult `
            -Category 'Environment' `
            -CheckName 'Operating System' `
            -Result 'WARN' `
            -Details 'Non-Windows detected. Test-NetConnection and Resolve-DnsName are Windows-only. Connectivity and AD checks will be skipped.' `
            -HowToFix 'Run this script from a Windows host within the target VNet subnet for complete results, including connectivity and AD checks.'
        $SkipConnectivityTests = $true
        $SkipADValidation      = $true
    } else {
        Add-AVDCheckResult `
            -Category 'Environment' `
            -CheckName 'Operating System' `
            -Result 'PASS' `
            -Details "Windows  -  connectivity tests enabled"
    }

    if (-not $SkipModuleValidation) {
        Test-AVDModuleAvailability -Modules $RequiredModules
        try {
            Import-AVDRequiredModulesToMemory -Modules $RequiredModules
        } catch {
            $importErrText = $_.Exception.Message
            $isAssemblyCollision = $importErrText -match 'AVD_AZ_MODULE_CONFLICT|Assembly with same name is already loaded|Microsoft\.Azure\.PowerShell\.AssemblyLoading|requires Az\.Accounts version|earlier version of Az\.Accounts is imported|multiple incompatible versions|stuck in the process'

            if ($isAssemblyCollision) {
                $recovered = Invoke-AVDFreshProcessRecovery `
                    -SubscriptionId $SubscriptionId `
                    -TenantId $TenantId `
                    -TargetRegion $TargetRegion `
                    -VmSku $VmSku `
                    -PlannedSessionHosts $PlannedSessionHosts `
                    -DomainName $DomainName `
                    -IdentityModel $IdentityModel `
                    -ResourceGroupName $ResourceGroupName `
                    -ReportPath $ReportPath `
                    -ExportReport:$ExportReport `
                    -CriticalOnly:$CriticalOnly `
                    -SkipConnectivityTests:$SkipConnectivityTests `
                    -SkipADValidation:$SkipADValidation

                if ($recovered) {
                    $script:RecoveredByChildProcess = $true
                    $script:ReportExported = $true
                    $script:ProcessExitCode = $script:FreshProcessExitCode
                    $global:LASTEXITCODE = $script:FreshProcessExitCode
                    Write-Host ''
                    Write-Host '[ INFO ] Recovery run in clean process completed successfully.' -ForegroundColor Green
                    return
                }
            }

            Add-AVDCheckResult `
                -Category 'Modules' `
                -CheckName 'Required Module Import' `
                -Result 'FAIL' `
                -Details $importErrText `
                -Roadblock 'Required Az modules could not be loaded into the current PowerShell session.' `
                -HowToFix 'Close this shell and rerun the script in a fresh process, or remove conflicting loaded Az modules before execution.'
            Write-Host ''
            Write-Host '[ ABORT ] Required module import failed. Cannot proceed with validation.' -ForegroundColor Red
            throw
        }
    }

    # -- STEP 2: Authentication ---------------------------------------------------
    $authOk = Connect-AVDAzureAccount `
        -TenantId $TenantId `
        -SubscriptionId $SubscriptionId `
        -NonInteractive:$NonInteractive `
        -PreferredAuthMethod $PreferredAuthMethod `
        -RequestedAuthMethod $AuthMethod `
        -ApplicationId $ApplicationId `
        -CertificateThumbprint $CertificateThumbprint `
        -ServicePrincipalCredential $ServicePrincipalCredential `
        -ReuseExistingContext:$ReuseExistingContext

    if (-not $authOk) {
        Add-AVDCheckResult `
            -Category 'Authentication' `
            -CheckName 'Azure Login' `
            -Result 'FAIL' `
            -Details 'Authentication did not produce a valid Azure context. All subsequent Azure checks will be skipped.' `
            -Roadblock 'Without an authenticated Azure session, no resource queries can run.' `
            -HowToFix 'Run: Connect-AzAccount [-TenantId <tid>] [-SubscriptionId <subid>]'

        Write-Host ''
        Write-Host '[ ABORT ] Authentication failed. Cannot proceed with Azure validation.' -ForegroundColor Red
        throw 'Authentication failed. Aborting remaining checks.'
    }

# -- STEP 3: Subscription & Tenant --------------------------------------------
Test-AVDSubscriptionReadiness -SubscriptionId $SubscriptionId

# -- STEP 4: Resource Providers -----------------------------------------------
Test-AVDResourceProviders `
    -RequiredProviders    $RequiredProviders `
    -RecommendedProviders $RecommendedProviders

# -- STEP 5: Entra ID Requirements --------------------------------------------
Test-AVDEntraIDRequirements

# -- STEP 6: RBAC Assessment --------------------------------------------------
Test-AVDRBACRequirements `
    -SubscriptionId    $SubscriptionId `
    -ResourceGroupName $ResourceGroupName

# -- STEP 7: Network Configuration --------------------------------------------
Test-AVDNetworkConfiguration `
    -TargetRegion      $TargetRegion `
    -ResourceGroupName $ResourceGroupName `
    -VNetName          $VNetName `
    -SubnetName        $SubnetName

# -- STEP 8: Endpoint Connectivity --------------------------------------------
if (-not $SkipConnectivityTests) {
    Test-AVDEndpointConnectivity
} else {
    Write-AVDSection -Title 'AVD ENDPOINT CONNECTIVITY [SKIPPED]'
    Add-AVDCheckResult `
        -Category 'Connectivity' `
        -CheckName 'Endpoint Connectivity Tests' `
        -Result 'SKIP' `
        -Details 'Skipped via -SkipConnectivityTests or non-Windows OS'
}

# -- STEP 9: Compute Quota ----------------------------------------------------
if ($TargetRegion) {
    Test-AVDComputeQuota `
        -Location            $TargetRegion `
        -VmSku               $VmSku `
        -PlannedSessionHosts $PlannedSessionHosts
} else {
    Write-AVDSection -Title 'COMPUTE QUOTA [SKIPPED  -  no TargetRegion provided]'
    Add-AVDCheckResult `
        -Category 'ComputeQuota' `
        -CheckName 'Compute Quota Check' `
        -Result 'SKIP' `
        -Details 'Skipped  -  provide -TargetRegion to enable quota validation' `
        -HowToFix "Re-run with: -TargetRegion 'eastus2' (or your target region)"
}

# -- STEP 10: Storage & FSLogix -----------------------------------------------
Test-AVDStorageReadiness `
    -ResourceGroupName  $ResourceGroupName `
    -StorageAccountName $StorageAccountName `
    -SkipPortTest:$SkipConnectivityTests

# -- STEP 11: Identity Model - Specific Checks --------------------------------
# AD DS / domain connectivity (required when identity model needs on-prem or hybrid AD)
$runAD = (-not $SkipADValidation) -and ($IdentityModel -in @('ADDS','EntraIDKerberos','All'))

if ($runAD -and $DomainName) {
    Test-AVDDomainConnectivity -DomainName $DomainName
} elseif ($runAD -and -not $DomainName) {
    Write-AVDSection -Title 'ACTIVE DIRECTORY CONNECTIVITY [SKIPPED  -  no DomainName provided]'
    Add-AVDCheckResult `
        -Category 'Identity' `
        -CheckName 'AD DNS / LDAP Test' `
        -Result 'SKIP' `
        -Details "Identity model is '$IdentityModel' but -DomainName was not provided" `
        -HowToFix "Re-run with: -DomainName 'yourdomain.local' to test AD connectivity"
} elseif ($IdentityModel -notin @('EntraDS')) {
    Write-AVDSection -Title 'ACTIVE DIRECTORY [SKIPPED]'
    Add-AVDCheckResult `
        -Category 'Identity' `
        -CheckName 'AD DNS / LDAP Test' `
        -Result 'SKIP' `
        -Details "Skipped (IdentityModel=$IdentityModel or -SkipADValidation specified)"
}

# Entra ID Kerberos Hybrid - specific checks (Hybrid AAD Join + AADKERB storage)
if ($IdentityModel -in @('EntraIDKerberos','All')) {
    Test-AVDEntraIDKerberosHybrid -DomainName $DomainName
}

# Microsoft Entra join - specific checks (cloud-only session hosts)
if ($IdentityModel -in @('EntraID','All')) {
    Test-AVDEntraJoinReadiness -ResourceGroupName $ResourceGroupName
}

# Microsoft Entra Domain Services - specific checks (managed domain)
if ($IdentityModel -in @('EntraDS','All')) {
    Test-AVDEntraDSReadiness -TargetRegion $TargetRegion -ResourceGroupName $ResourceGroupName
}

# -- STEP 12: Monitoring ------------------------------------------------------
Test-AVDMonitoringReadiness -ResourceGroupName $ResourceGroupName

# -- STEP 13: Key Vault -------------------------------------------------------
Test-AVDKeyVaultReadiness -ResourceGroupName $ResourceGroupName

# -- STEP 14: Existing AVD Resources ------------------------------------------
Test-AVDServiceConfiguration -ResourceGroupName $ResourceGroupName

# -- STEP 15: Image Gallery ---------------------------------------------------
Test-AVDImageReadiness -ResourceGroupName $ResourceGroupName

# ==============================================================================
# RESULTS SUMMARY
# ==============================================================================

$summary = Get-AVDValidationSummary

$bar = '=' * 78
Write-Host ''
Write-Host "+$bar+" -ForegroundColor White
Write-Host "|  VALIDATION SUMMARY                                                          |" -ForegroundColor White
Write-Host "+$bar+" -ForegroundColor White
Write-Host ''
Write-Host "  TotalChecks : $($summary.TotalChecks)" -ForegroundColor White
Write-Host "  PassCount   : $($summary.PassCount)"   -ForegroundColor Green
Write-Host "  FailCount   : $($summary.FailCount)"   -ForegroundColor Red
Write-Host "  WarnCount   : $($summary.WarnCount)"   -ForegroundColor Yellow
Write-Host "  SkipCount   : $($summary.SkipCount)"   -ForegroundColor Blue
Write-Host "  InfoCount   : $($summary.InfoCount)"   -ForegroundColor Blue
Write-Host "  Results     : $($summary.Results.Count) detailed records collected" -ForegroundColor White
Write-Host ''

if ($summary.FailCount -eq 0 -and $summary.WarnCount -eq 0) {
    Write-Host '  VERDICT: [PASS] ALL CHECKS PASSED  -  Tenant appears READY for AVD deployment.' -ForegroundColor Green
} elseif ($summary.FailCount -eq 0) {
    Write-Host "  VERDICT: [WARN] No critical blockers found but $($summary.WarnCount) warning(s) detected." -ForegroundColor Yellow
    Write-Host '           Review warnings before deploying to production.' -ForegroundColor Yellow
} else {
    $script:ProcessExitCode = 1
    Write-Host "  VERDICT: [FAIL] $($summary.FailCount) CRITICAL FAILURE(S) detected." -ForegroundColor Red
    Write-Host '           These MUST be resolved before AVD deployment can succeed.' -ForegroundColor Red
}

Write-Host ''

$fails = $summary.Results | Where-Object { $_.Result -eq 'FAIL' }
if ($null -ne $fails -and @($fails).Count -gt 0) {
    Write-Host "  -- CRITICAL FAILURES ($($summary.FailCount)) --" -ForegroundColor Red
    foreach ($f in $fails) {
        Write-Host "  [$($f.Category)] $($f.CheckName)" -ForegroundColor Red
        Write-Host "    $($f.Details)" -ForegroundColor Gray
        if ($f.Roadblock) { Write-Host "    ROADBLOCK : $($f.Roadblock)" -ForegroundColor DarkRed  }
        if ($f.HowToFix)  { Write-Host "    HOW TO FIX: $($f.HowToFix)" -ForegroundColor Yellow   }
        Write-Host ''
    }
}

if (-not $CriticalOnly) {
    $warns = $summary.Results | Where-Object { $_.Result -eq 'WARN' }
    if ($null -ne $warns -and @($warns).Count -gt 0) {
        Write-Host "  -- WARNINGS ($($summary.WarnCount)) --" -ForegroundColor Yellow
        foreach ($w in $warns) {
            Write-Host "  [$($w.Category)] $($w.CheckName)" -ForegroundColor Yellow
            Write-Host "    $($w.Details)" -ForegroundColor Gray
            if ($w.HowToFix) { Write-Host "    HOW TO FIX: $($w.HowToFix)" -ForegroundColor DarkYellow }
            Write-Host ''
        }
    }
}

if ($ExportReport -and -not $NoExport) {
    Write-Host ''
    Write-Host '  Exporting report...' -ForegroundColor Cyan
    try {
        $exportPaths = Export-AVDValidationReport `
            -OutputPath          $ReportPath `
            -IncludePassedChecks:$true `
            -IncludeInfoChecks:$true
        $script:ReportExported = $true
        Write-Host "  Excel: $($exportPaths.ExcelPath)" -ForegroundColor Cyan
    } catch {
        Write-Host "  WARNING: Could not export report: $($_.Exception.Message)" -ForegroundColor Yellow
    }
} elseif ($NoExport) {
    Write-Host '  Skipping standalone export (-NoExport).' -ForegroundColor Yellow
}

Write-Host ''
Write-Host "  Completed at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
Write-Host ''

} catch {
    $script:ProcessExitCode = 2
    $executionError = $_.Exception.Message
    if (Get-Command -Name Add-AVDCheckResult -ErrorAction SilentlyContinue) {
        Add-AVDCheckResult `
            -Category 'Execution' `
            -CheckName 'Readiness Check Execution' `
            -Result 'FAIL' `
            -Details $executionError `
            -Roadblock 'The readiness assessment did not complete, so deployment readiness is unknown.' `
            -HowToFix 'Resolve the reported authentication, module, or runtime error and run the assessment again.'
    }
    Write-Host "  EXECUTION FAILED: $executionError" -ForegroundColor Red
}
finally {
    if (-not $NoExport -and -not $script:ReportExported -and -not $script:RecoveredByChildProcess -and $script:ValidationResults.Count -gt 0) {
        try {
            $fallbackExport = Export-AVDValidationReport `
                -OutputPath          $script:ReportRootPath `
                -IncludePassedChecks:$true `
                -IncludeInfoChecks:$true
            $script:ReportExported = $true
            Write-Host "  Excel (fallback): $($fallbackExport.ExcelPath)" -ForegroundColor Cyan
        } catch {
            Write-Host "  WARNING: Fallback report export failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    Invoke-AVDModuleCleanup -PreflightResult $preflight_Result
}

$global:LASTEXITCODE = $script:ProcessExitCode

# Return structured results for callers without terminating their PowerShell process.
if ($PassThru) {
    if ($null -eq $summary) {
        $summary = Get-AVDValidationSummary
    }
    return $summary
}

if ($NonInteractive) {
    exit $script:ProcessExitCode
}
