#Requires -Version 5.1

<#
.SYNOPSIS
    00_IDN_Check_Identity_Prerequisites.ps1 - Identity provisioning prerequisites check (standalone).
    Read-only. No identity, directory, network, or Azure resource is created, modified, or deleted.
    All validation functions are self-contained - no external module file required.

.DESCRIPTION
    Checks, for one identity model (the way users and machines authenticate), every
    prerequisite Microsoft documents for it, and reports each one as PASS, FAIL, WARN,
    INFO or SKIP, with why it matters, how to fix it, and a link to the Microsoft
    documentation it comes from. Run it once per model to compare them.

    It checks the identity model only. Product-specific identity items (for example an
    Azure Virtual Desktop host pool's sign-in settings) are checked by that product's
    own readiness script.

    IDENTITY MODELS  (each is a separate check path; only the selected one runs)
    -----------------------------------------------------------------------------
        ADDS             Active Directory Domain Services. Machines join an AD DS
                         domain; users are synced from AD DS to Entra ID.
        EntraDS          Microsoft Entra Domain Services. Machines join a Microsoft-
                         managed domain; password hashes must reach Entra DS.
        EntraID          Microsoft Entra ID. Machines are Entra joined; no domain.
        EntraIDKerberos  Entra-joined machines with hybrid users, and Azure Files
                         authenticated through Microsoft Entra Kerberos.

    WHAT EVERY RUN VALIDATES
    ------------------------
        1  PowerShell environment and modules
        2  Azure sign-in, tenant and subscription (listed for selection)
        3  Microsoft Graph sign-in and granted permissions
        4  Directory synchronization (required, optional, or not applicable per model)
        5  Test user identity source (hybrid or cloud-only, as the model requires)
        6  The selected identity model's own dependencies (domain, DNS, Azure Files
           identity, sign-in roles, Conditional Access, as the model requires)
        7  Optional, Entra models: single sign-on for RDP (-CheckSsoConfiguration)

    REPORT
    ------
    The Excel report opens on a Summary sheet (identity model, tenant, who ran it and
    when, verdict, counts), followed by every requirement with its result, why it
    matters, how to fix it, and the Microsoft documentation link, so anyone can
    check each requirement against the source.

    RESULTS FORMAT
    --------------
    Every check produces one of: PASS / FAIL / WARN / INFO / SKIP.
    Every FAIL result includes the Roadblock, HowToFix, and a documentation link.
    Items that cannot be read from Azure or Graph (domain-join rights on an OU, session
    host registry settings) are reported as INFO with the exact command to verify them.

    SIGN-IN
    -------
    Sign-in is never silent, and the whole run happens in the PowerShell session you
    start it from: Windows PowerShell 5.1, PowerShell 7 or PowerShell ISE. One Azure
    sign-in (Az.Accounts) reads both Azure Resource Manager and Microsoft Graph, and the
    script only reads (GET requests). The sign-in is kept in memory for this run only:
    nothing is saved to disk, and an Azure PowerShell sign-in this window already had is
    put back when the run ends.

    Exit codes: 0 = no failures, 1 = one or more FAIL results, 2 = execution error.

.PARAMETER IdentityModel
    ADDS, EntraDS, EntraID, or EntraIDKerberos. The wizard asks when omitted.

.PARAMETER TenantId
    Tenant ID or domain. Required with -NonInteractive.

.PARAMETER SubscriptionId
    Subscription holding the resources. Required with -NonInteractive for Azure checks.

.PARAMETER VNetId
    Resource ID of the virtual network the machines use (DNS and peering checks).

.PARAMETER StorageAccountId
    Resource ID of an Azure Files storage account whose users authenticate with this
    identity model (for example, a share for FSLogix profiles).

.PARAMETER TestUserUpn
    A user who will sign in. Validates that the user's identity source fits the model.

.PARAMETER DomainName
    AD DS domain FQDN (ADDS). Used for DNS SRV and port tests from this host.

.PARAMETER CheckSsoConfiguration
    Also read the single sign-on configuration of the Remote Desktop service principals.
    Microsoft Graph offers only a read-write permission for it
    (Application-RemoteDesktopConfig.ReadWrite.All); the script still only reads.

.PARAMETER NonInteractive
    Skip the wizard and all prompts.

.PARAMETER AuthMethod
    Interactive, DeviceCode, ServicePrincipalCertificate, or ManagedIdentity. No default:
    the wizard asks, and -NonInteractive requires it. For a service principal, use a
    certificate: a client secret is not accepted.

.PARAMETER ApplicationId
    Application (client) ID for ServicePrincipalCertificate.

.PARAMETER CertificateThumbprint
    Certificate thumbprint for ServicePrincipalCertificate.

.PARAMETER ReportPath
    Folder for the Excel report. Default: the script folder.

.PARAMETER CriticalOnly
    Show only FAIL results in the closing summary.

.PARAMETER PassThru
    Return the summary object to the caller.

.PARAMETER ExportReport
    Accepted for compatibility. The Excel report is always written unless -NoExport is given.

.PARAMETER NoExport
    Do not write the Excel report.

.PARAMETER SkipModuleValidation
    Skip module staging and validation (modules must already be imported).

.EXAMPLE
    .\00_IDN_Check_Identity_Prerequisites.ps1
    Runs the guided wizard.

.EXAMPLE
    .\00_IDN_Check_Identity_Prerequisites.ps1 -NonInteractive -AuthMethod Interactive -IdentityModel EntraIDKerberos -TenantId contoso.com -SubscriptionId <id> -StorageAccountId <id> -TestUserUpn user@contoso.com

.NOTES
    Author: etf
    Minimum roles: Reader on the subscription; Global Reader in Entra ID.
    Signed in as a user, Microsoft Graph is read through the Microsoft Azure PowerShell
    app, limited to what the account's own Entra roles allow. A service principal or
    managed identity needs these Microsoft Graph application permissions, read-only:
        Organization.Read.All, Directory.Read.All, User.Read.All, Policy.Read.All,
        Application.Read.All, OnPremDirectorySynchronization.Read.All
#>

[CmdletBinding(SupportsShouldProcess=$false)]
param(
    [ValidateSet('ADDS','EntraDS','EntraID','EntraIDKerberos')]
    [string]$IdentityModel,

    [string]$TenantId,
    [string]$SubscriptionId,

    [string]$VNetId,
    [string]$StorageAccountId,
    [string]$TestUserUpn,
    [string]$DomainName,

    [switch]$CheckSsoConfiguration,

    [switch]$NonInteractive,

    # No default on purpose: sign-in is never silent.
    [ValidateSet('Interactive','DeviceCode','ServicePrincipalCertificate','ManagedIdentity')]
    [string]$AuthMethod,

    [string]$ApplicationId,
    [string]$CertificateThumbprint,

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
# INT Module Preflight - Session-scoped ephemeral module loading
# ======================================================================
# Embedded so this script can be distributed as a single file.
# Missing modules are saved under $env:TEMP, imported for this run, then removed.
$env:PSModulePath = (($env:PSModulePath -split [IO.Path]::PathSeparator) |
    Where-Object { $_ -and $_ -notmatch '(?:^|[\\/])_modules(?:[\\/]|$)' }) -join [IO.Path]::PathSeparator
$script:IDNTempPath = $null
$script:IDNTempModuleNames = [System.Collections.Generic.List[string]]::new()
$script:IDNImportedModuleNames = [System.Collections.Generic.List[string]]::new()

function Get-IDNModuleTempPath {
    if (-not $script:IDNTempPath) {
        $script:IDNTempPath = Join-Path $env:TEMP ("IDN_TempMod_{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:IDNTempPath -Force -ErrorAction Stop | Out-Null
    }
    return $script:IDNTempPath
}

function Resolve-IDNBestLocalModule {
    param(
        [Parameter(Mandatory=$true)] [string]$Name,
        [version]$MinimumVersion = [version]'0.0'
    )

    return Get-Module -Name $Name -ListAvailable -ErrorAction SilentlyContinue |
        Where-Object { $_.ModuleBase -notmatch '(?:^|[\\/])_modules(?:[\\/]|$)' -and $_.Version -ge $MinimumVersion } |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

function Invoke-IDNModulePreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable[]]$Modules
    )

    $script:IDNTempPath = $null
    $script:IDNTempModuleNames = [System.Collections.Generic.List[string]]::new()
    $script:IDNImportedModuleNames = [System.Collections.Generic.List[string]]::new()

    Write-Host ''
    Write-Host ('=' * 100) -ForegroundColor White
    Write-Host 'Validating PowerShell modules installation' -ForegroundColor White
    Write-Host ('=' * 100) -ForegroundColor White
    Write-Host ''

    # Modules staged by an earlier run stay loaded until its window closes, so that run
    # cannot delete them. Remove those folders now. A rename fails while another window
    # still has the modules loaded, so only folders that can be renamed are deleted.
    Get-ChildItem -Path $env:TEMP -Directory -Filter 'IDN_TempMod_*' -ErrorAction SilentlyContinue | ForEach-Object {
        $staleName = Join-Path $env:TEMP ('IDN_Stale_{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        try { Rename-Item -LiteralPath $_.FullName -NewName (Split-Path $staleName -Leaf) -ErrorAction Stop } catch { return }
        Remove-Item -LiteralPath $staleName -Recurse -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem -Path $env:TEMP -Directory -Filter 'IDN_Stale_*' -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

    $originalPSModulePath = $env:PSModulePath
    $needFetch = [System.Collections.Generic.List[string]]::new()

    foreach ($moduleRequirement in $Modules) {
        $moduleName = [string]$moduleRequirement.Name
        $minimumVersion = if ($moduleRequirement.MinVersion) { [version]$moduleRequirement.MinVersion } else { [version]'0.0' }
        $foundModule = Resolve-IDNBestLocalModule -Name $moduleName -MinimumVersion $minimumVersion

        if ($foundModule) {
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
        $tempPath = Get-IDNModuleTempPath
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

                [void]$script:IDNTempModuleNames.Add($moduleName)
                Write-Host ("Module Check - Pass: Fetched to temporary storage: {0} (Version: {1})" -f $moduleName, $manifest.Directory.Name) -ForegroundColor Green
            } catch {
                throw ("Module Fetch - Fail [{0}]: {1}" -f $moduleName, $_.Exception.Message)
            }
        }
    }

    if ($script:IDNTempPath) {
        $env:PSModulePath = @($script:IDNTempPath, $originalPSModulePath) -join [IO.Path]::PathSeparator
    }

    return [PSCustomObject]@{
        Success = $true
        TempPath = $script:IDNTempPath
        OriginalPSModulePath = $originalPSModulePath
        TempModuleNames = $script:IDNTempModuleNames.ToArray()
        ImportedModuleNames = $script:IDNImportedModuleNames.ToArray()
    }
}

function Invoke-IDNModuleCleanup {
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
    @{ Name = 'Az.Accounts';                    MinVersion = '2.12.0'; Required = $true }
    @{ Name = 'ImportExcel'; MinVersion = '7.0.0'; Required = $true }
)

$preflight_Result = $null
if (-not $SkipModuleValidation) {
    $preflight_Result = Invoke-IDNModulePreflight -Modules $preflight_Modules
}

trap {
    Invoke-IDNModuleCleanup -PreflightResult $preflight_Result
    throw $_
}
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Invoke-IDNModuleCleanup -PreflightResult $preflight_Result
} -ErrorAction SilentlyContinue

# Always export reports to the script root using the script file name.
$script:ReportRootPath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:ReportScriptName = $env:IDN_REPORT_SCRIPT_NAME
if ([string]::IsNullOrWhiteSpace($script:ReportScriptName)) {
    $script:ReportScriptName = if ($PSCommandPath) { [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath) } else { [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name) }
}
$script:ReportExported = $false
$script:RecoveredByChildProcess = $false

# ==============================================================================
# EMBEDDED VALIDATION LIBRARY
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

function Write-IDNLog {
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

function Write-IDNSection {
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

function Add-IDNCheckResult {
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
    Write-IDNLog -Level $logLevel -Message "[$Category] $CheckName"
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

function Get-IDNValidationSummary {
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

function Export-IDNValidationReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$OutputPath
    )

    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $excelPath = Join-Path $OutputPath ("$($script:ReportScriptName)_$ts.xlsx")

    # A cover sheet a client can read on its own: what was checked, where, by whom, and the outcome.
    $verdict = if ($script:FailCount -gt 0) { "FAIL: $($script:FailCount) blocker(s) to resolve before users can sign in" }
               elseif ($script:WarnCount -gt 0) { "WARN: no blockers, $($script:WarnCount) warning(s) to review" }
               else { 'PASS: the identity prerequisites checked are in place' }
    $modelName = if ($IdentityModel -and $script:ModelNames.ContainsKey($IdentityModel)) { $script:ModelNames[$IdentityModel] } else { 'not selected' }
    @(
        [PSCustomObject]@{ Item = 'Identity model checked'; Value = $modelName }
        [PSCustomObject]@{ Item = 'Tenant';                 Value = $(if ($TenantId) { $TenantId } else { 'not selected' }) }
        [PSCustomObject]@{ Item = 'Subscription';           Value = $(if ($SubscriptionId) { $SubscriptionId } else { 'none (directory checks only)' }) }
        [PSCustomObject]@{ Item = 'Run by';                 Value = "$env:USERNAME on $env:COMPUTERNAME" }
        [PSCustomObject]@{ Item = 'Completed';              Value = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }
        [PSCustomObject]@{ Item = 'Verdict';                Value = $verdict }
        [PSCustomObject]@{ Item = 'Checks';                 Value = "$($script:TotalChecks) total: $($script:PassCount) pass, $($script:FailCount) fail, $($script:WarnCount) warn, $($script:InfoCount) info, $($script:SkipCount) skipped" }
        [PSCustomObject]@{ Item = 'Changes made';           Value = 'None. Read-only: Azure Resource Manager and Microsoft Graph GET requests only.' }
        [PSCustomObject]@{ Item = 'How to verify';          Value = "Every requirement on the 'Validation Results' sheet links (DocLink) to the Microsoft documentation it comes from." }
    ) | Export-Excel -Path $excelPath -WorksheetName 'Summary' -AutoSize -BoldTopRow

    $script:ValidationResults.ToArray() |
        Export-Excel -Path $excelPath -WorksheetName 'Validation Results' -AutoSize -FreezeTopRow -BoldTopRow

    return [PSCustomObject]@{ ExcelPath = $excelPath }
}

#endregion

#region -- Module Management ---------------------------------------------------

function Test-IDNModuleAvailability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable[]]$Modules
    )

    Write-IDNSection -Title 'POWERSHELL MODULE AVAILABILITY'

    foreach ($mod in $Modules) {
        $name       = $mod.Name
        $minVer     = if ($mod.MinVersion) { $mod.MinVersion } else { '0.0.0' }
        $isRequired = if ($null -ne $mod.Required) { [bool]$mod.Required } else { $true }

        try {
            $installed = Get-Module -Name $name -ErrorAction SilentlyContinue |
                         Sort-Object Version -Descending | Select-Object -First 1
            if ($null -eq $installed) {
                $installed = Resolve-IDNBestLocalModule -Name $name
            }

            if ($null -eq $installed) {
                if ($isRequired) {
                    Add-IDNCheckResult `
                        -Category 'Modules' `
                        -CheckName "Module: $name" `
                        -Result 'FAIL' `
                        -Details 'Not installed' `
                        -Roadblock "The module '$name' is required to query Microsoft Graph or write the report." `
                        -HowToFix "Rerun with network access so '$name' can be staged temporarily." `
                        -DocLink 'https://learn.microsoft.com/powershell/microsoftgraph/installation'
                } else {
                    Add-IDNCheckResult `
                        -Category 'Modules' `
                        -CheckName "Module: $name (optional)" `
                        -Result 'WARN' `
                        -Details 'Not installed  -  checks requiring this module will be skipped' `
                        -HowToFix "Rerun with network access so '$name' can be staged temporarily."
                }
            } elseif ([System.Version]$installed.Version -lt [System.Version]$minVer) {
                Add-IDNCheckResult `
                    -Category 'Modules' `
                    -CheckName "Module: $name" `
                    -Result 'WARN' `
                    -Details "Version $($installed.Version) installed; $minVer+ recommended" `
                    -HowToFix "Update-Module -Name '$name' -Force"
            } else {
                Add-IDNCheckResult `
                    -Category 'Modules' `
                    -CheckName "Module: $name" `
                    -Result 'PASS' `
                    -Details "Version $($installed.Version) installed"
            }
        } catch {
            Add-IDNCheckResult `
                -Category 'Modules' `
                -CheckName "Module: $name" `
                -Result 'WARN' `
                -Details "Error checking module: $($_.Exception.Message)"
        }
    }
}

function Import-IDNRequiredModulesToMemory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable[]]$Modules
    )

    # IMPORTANT: Do NOT call Remove-Module on Graph or Az modules before importing.
    # Removing PS module objects leaves their .NET assemblies in the AppDomain
    # (Azure.Identity, Microsoft.Identity.Client). A later Import-Module then fails
    # with "Assembly with same name is already loaded" until a fresh process starts.
    # Correct pattern: skip if already loaded (guard below); import if not loaded.

    foreach ($mod in $Modules) {
        $name       = $mod.Name
        $isRequired = if ($null -ne $mod.Required) { [bool]$mod.Required } else { $true }
        if (-not $isRequired) { continue }

        if (Get-Module -Name $name -ErrorAction SilentlyContinue) { continue }

        $installed = Resolve-IDNBestLocalModule -Name $name
        if ($null -eq $installed) {
            throw "Required module '$name' was validated but could not be resolved for import."
        }

        try {
            Import-Module -Name $installed.Path -Global -ErrorAction Stop -WarningAction SilentlyContinue
            [void]$script:IDNImportedModuleNames.Add($name)
            if ($preflight_Result) { $preflight_Result.ImportedModuleNames = $script:IDNImportedModuleNames.ToArray() }
        } catch {
            $importErr = $_
            if (Get-Module -Name $name -ErrorAction SilentlyContinue) {
                [void]$script:IDNImportedModuleNames.Add($name)
                continue
            }
            if ($importErr.Exception.Message -match 'Assembly with same name is already loaded|Could not load file or assembly|Azure\.Identity|Microsoft\.Identity\.Client|multiple incompatible versions') {
                throw "IDN_MODULE_CONFLICT: Failed to import required module '$name': assemblies from a prior script in this terminal are stuck in the process. Open a fresh PowerShell terminal and run again."
            }
            throw "Failed to import required module '$name': $($importErr.Exception.Message)"
        }
    }
}

#endregion

#region -- Microsoft Graph Helpers ---------------------------------------------

function Invoke-IDNGraphRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Uri,
        [switch]$All,
        [hashtable]$Headers
    )

    if (-not $script:GraphToken) { throw 'No Microsoft Graph session.' }
    $requestHeaders = @{ Authorization = "Bearer $($script:GraphToken)" }
    if ($Headers) { foreach ($key in $Headers.Keys) { $requestHeaders[$key] = $Headers[$key] } }
    $target = if ($Uri -match '^https://') { $Uri } else { 'https://graph.microsoft.com/' + $Uri.TrimStart('/') }
    $requestParams = @{ Method = 'GET'; Uri = $target; Headers = $requestHeaders; ErrorAction = 'Stop' }

    $response = Invoke-RestMethod @requestParams
    if (-not $All) { return $response }

    $items = [System.Collections.Generic.List[object]]::new()
    while ($null -ne $response) {
        if ($response.PSObject.Properties.Name -contains 'value') {
            foreach ($item in @($response.value)) { if ($null -ne $item) { $items.Add($item) } }
        }
        $nextLink = $null
        if ($response.PSObject.Properties.Name -contains '@odata.nextLink') { $nextLink = $response.'@odata.nextLink' }
        if ([string]::IsNullOrWhiteSpace($nextLink)) { break }
        $requestParams['Uri'] = $nextLink
        $response = Invoke-RestMethod @requestParams
    }
    # Unrolled on purpose: callers wrap the call in @(...), and a comma-wrapped
    # return would nest the whole list inside a single element.
    return $items.ToArray()
}

function Get-IDNGraphStatusCode {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)] [System.Management.Automation.ErrorRecord]$ErrorRecord)

    try {
        $code = [int]$ErrorRecord.Exception.Response.StatusCode
        if ($code -gt 0) { return $code }
    } catch {
        Write-Verbose "No HTTP status on the Graph error: $($_.Exception.Message)"
    }
    $text = "$($ErrorRecord.Exception.Message) $($ErrorRecord.ErrorDetails)"
    if ($text -match '\b(400|401|403|404|429|500|503)\b') { return [int]$Matches[1] }
    if ($text -match 'Forbidden|Authorization_RequestDenied|insufficient privileges') { return 403 }
    if ($text -match 'NotFound|ResourceNotFound|does not exist') { return 404 }
    return 0
}

function Add-IDNGraphFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Category,
        [Parameter(Mandatory=$true)] [string]$CheckName,
        [Parameter(Mandatory=$true)] [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory=$true)] [string]$Permission,
        [string]$DocLink = ''
    )

    $status = Get-IDNGraphStatusCode -ErrorRecord $ErrorRecord
    if ($status -eq 403 -or $status -eq 401) {
        Add-IDNCheckResult `
            -Category $Category `
            -CheckName $CheckName `
            -Result 'WARN' `
            -Details "Access denied by Microsoft Graph (HTTP $status). This check could not run." `
            -HowToFix "Grant the read-only permission '$Permission' (admin consent) or sign in with a Global Reader account, then rerun." `
            -DocLink $DocLink
    } else {
        Add-IDNCheckResult `
            -Category $Category `
            -CheckName $CheckName `
            -Result 'WARN' `
            -Details "Could not query Microsoft Graph: $($ErrorRecord.Exception.Message)" `
            -HowToFix 'Rerun the check. If it persists, confirm Microsoft Graph is reachable from this host.' `
            -DocLink $DocLink
    }
}

function Get-IDNPropertyValue {
    [CmdletBinding()]
    param(
        $InputObject,
        [Parameter(Mandatory=$true)] [string]$Name
    )
    if ($null -eq $InputObject) { return $null }
    if ($InputObject.PSObject.Properties.Name -contains $Name) { return $InputObject.$Name }
    return $null
}

#endregion


#region -- Identity Constants --------------------------------------------------

# First-party application IDs (the same in every tenant).
$script:AppIds = @{
    MicrosoftRemoteDesktop    = 'a4a365df-50f1-4397-bc59-1a1564b8bb9c'
    WindowsCloudLogin         = '270efc09-cd0d-444b-a71f-39af4910ec45'
    AzureWindowsVmSignIn      = '372140e0-b3b7-4226-8ef9-d57986796201'
    DomainControllerServices  = '2565bd9d-da50-47d4-8b85-4c97f669dc36'
}

# Azure built-in role definition IDs.
$script:RoleIds = @{
    VirtualMachineUserLogin          = 'fb879df8-f326-4884-b1cf-06f3ad86be52'
    VirtualMachineAdministratorLogin = '1c0163c0-47e6-4577-8991-ea5c82e286e4'
    SmbShareReader                   = 'aba4ae5f-2193-4029-9191-0cb91df5e314'
    SmbShareContributor              = '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb'
    SmbShareElevatedContributor      = 'a7264617-510b-434b-a828-9731dc254ea7'
}

# What each model expects on an Azure Files storage account (directoryServiceOptions).
$script:ModelStorageOption = @{
    ADDS            = 'AD'
    EntraDS         = 'AADDS'
    EntraID         = 'AADKERB'
    EntraIDKerberos = 'AADKERB'
}

$script:ModelNames = @{
    ADDS            = 'Active Directory Domain Services'
    EntraDS         = 'Microsoft Entra Domain Services'
    EntraID         = 'Microsoft Entra ID (cloud)'
    EntraIDKerberos = 'Microsoft Entra ID with Entra Kerberos'
}

$script:ArmToken = $null
$script:SyncEnabled = $null
$script:PhsEnabled = $null
$script:TestUser = $null
$script:EntraDsCreated = $null
$script:SelectedVNet = $null

#endregion

#region -- Azure Resource Manager ---------------------------------------------

function ConvertTo-IDNTokenText {
    param([Parameter(Mandatory=$true)] $Token)
    # Az.Accounts 5 returns a SecureString, older versions a string.
    if ($Token -isnot [System.Security.SecureString]) { return [string]$Token }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-IDNTokenClaims {
    param([Parameter(Mandatory=$true)] [string]$Token)
    $payload = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $payload += '=' * ((4 - $payload.Length % 4) % 4)
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
}

function Connect-IDNAzure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Method,
        [string]$TenantId,
        [string]$SubscriptionId,
        [string]$ApplicationId,
        [string]$CertificateThumbprint,
        [switch]$NonInteractive
    )

    # The sign-in lives in memory for this run only. Remember what this window already
    # had, so Disconnect-IDNAzure can put it back.
    $script:IDNPriorAzContext = Get-AzContext -ErrorAction SilentlyContinue
    $script:IDNPriorAzContextNames = @(Get-AzContext -ListAvailable -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $script:IDNPriorAzAutosave = [string](Get-AzContextAutosaveSetting -ErrorAction SilentlyContinue).ContextSaveSetting
    Disable-AzContextAutosave -Scope Process | Out-Null
    $script:IDNAzConnected = $true

    $connectParams = @{ Scope = 'Process'; SkipContextPopulation = $true; ErrorAction = 'Stop' }
    if ($TenantId) { $connectParams['TenantId'] = $TenantId }
    switch ($Method) {
        'DeviceCode'                  { $connectParams['UseDeviceAuthentication'] = $true }
        'ServicePrincipalCertificate' { $connectParams['ServicePrincipal'] = $true; $connectParams['ApplicationId'] = $ApplicationId; $connectParams['CertificateThumbprint'] = $CertificateThumbprint }
        'ManagedIdentity'             { $connectParams['Identity'] = $true; $connectParams.Remove('TenantId') }
    }
    if ($Method -ne 'DeviceCode') { $connectParams['WarningAction'] = 'SilentlyContinue' }
    Connect-AzAccount @connectParams | Out-Null

    # -- Tenant -------------------------------------------------------------------
    $tenantName = ''
    $tenants = @(Get-AzTenant -ErrorAction Stop -WarningAction SilentlyContinue | Sort-Object Name)
    if ($TenantId) {
        $match = $tenants | Where-Object { $_.Id -eq $TenantId -or @($_.Domains) -contains $TenantId -or $_.DefaultDomain -eq $TenantId } | Select-Object -First 1
        if ($match) { $TenantId = [string]$match.Id; $tenantName = [string]$match.Name }
    } elseif ($tenants.Count -eq 1) {
        $TenantId = [string]$tenants[0].Id; $tenantName = [string]$tenants[0].Name
    } elseif (-not $NonInteractive -and $tenants.Count -gt 1) {
        Write-IDNWizardHeader -Title 'STEP 1 of 4  -  SIGN IN  (tenant)'
        Write-Host '  A tenant is your organization in Microsoft 365 and Entra ID: it holds your' -ForegroundColor Gray
        Write-Host '  users, groups and devices. Select the tenant to assess.' -ForegroundColor Gray
        Write-Host ''
        for ($i = 0; $i -lt $tenants.Count; $i++) {
            Write-Host ("  [{0,2}] {1}  ({2})" -f ($i + 1), $tenants[$i].Name, $tenants[$i].DefaultDomain) -ForegroundColor White
            Write-Host ("        ID: {0}" -f $tenants[$i].Id) -ForegroundColor DarkGray
        }
        Write-Host ''
        $n = Get-IDNWizardMenuChoice -Min 1 -Max $tenants.Count -Default 1
        $TenantId = [string]$tenants[$n - 1].Id; $tenantName = [string]$tenants[$n - 1].Name
    } else {
        throw 'No tenant could be determined. Pass -TenantId.'
    }

    # Tokens are issued per tenant: sign in to the chosen one if it is not the tenant
    # of the first sign-in (the browser usually completes this without asking again).
    $current = Get-AzContext
    if ($null -eq $current -or [string]$current.Tenant.Id -ne $TenantId) {
        Write-Host '  Signing in to the selected tenant...' -ForegroundColor Cyan
        $connectParams['TenantId'] = $TenantId
        Connect-AzAccount @connectParams | Out-Null
    }

    # -- Subscription -------------------------------------------------------------
    $subscriptionName = ''
    $subs = @(Get-AzSubscription -TenantId $TenantId -ErrorAction Stop -WarningAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' } | Sort-Object Name)
    if ($SubscriptionId) {
        $match = $subs | Where-Object { $_.Id -eq $SubscriptionId } | Select-Object -First 1
        if (-not $match) { throw "Subscription $SubscriptionId is not enabled or not visible in tenant $TenantId." }
        $subscriptionName = [string]$match.Name
    } elseif (-not $NonInteractive) {
        Write-IDNWizardHeader -Title 'STEP 1 of 4  -  SIGN IN  (subscription)'
        Write-Host '  The subscription that holds (or will hold) the virtual network, storage' -ForegroundColor Gray
        Write-Host '  account and domain. Azure resource checks run against it.' -ForegroundColor Gray
        Write-Host ''
        for ($i = 0; $i -lt $subs.Count; $i++) {
            Write-Host ("  [{0,2}] {1}" -f ($i + 1), $subs[$i].Name) -ForegroundColor White
            Write-Host ("        ID: {0}" -f $subs[$i].Id) -ForegroundColor DarkGray
        }
        $none = $subs.Count + 1
        Write-Host ''
        Write-Host ("  [{0,2}] No subscription  -  check directory items only" -f $none) -ForegroundColor DarkGray
        Write-Host ''
        $n = Get-IDNWizardMenuChoice -Min 1 -Max $none -Default 1
        if ($n -ne $none) { $SubscriptionId = [string]$subs[$n - 1].Id; $subscriptionName = [string]$subs[$n - 1].Name }
    }

    # -- Access token for Azure Resource Manager ----------------------------------
    $script:ArmToken = $null
    if ($SubscriptionId) {
        $tok = Get-AzAccessToken -ResourceTypeName Arm -TenantId $TenantId -ErrorAction Stop -WarningAction SilentlyContinue
        $script:ArmToken = ConvertTo-IDNTokenText -Token $tok.Token
    }

    $ctxNow = Get-AzContext
    return [PSCustomObject]@{
        TenantId         = $TenantId
        TenantName       = $tenantName
        Account          = $(if ($null -ne $ctxNow) { [string]$ctxNow.Account.Id } else { '' })
        SubscriptionId   = $SubscriptionId
        SubscriptionName = $subscriptionName
    }
}

function Disconnect-IDNAzure {
    [CmdletBinding()]
    param()

    if (-not $script:IDNAzConnected) { return }
    $script:IDNAzConnected = $false
    $priorAccounts = @(Get-AzContext -ListAvailable -ErrorAction SilentlyContinue |
        Where-Object { $script:IDNPriorAzContextNames -contains $_.Name } | ForEach-Object { [string]$_.Account.Id })
    foreach ($ctx in @(Get-AzContext -ListAvailable -ErrorAction SilentlyContinue | Where-Object { $script:IDNPriorAzContextNames -notcontains $_.Name })) {
        # An account this window was already using keeps its sign-in; only this run's context goes.
        if ($priorAccounts -contains [string]$ctx.Account.Id) { Remove-AzContext -InputObject $ctx -Force -ErrorAction SilentlyContinue }
        else { Disconnect-AzAccount -AzureContext $ctx -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null }
    }
    if ($script:IDNPriorAzAutosave -eq 'CurrentUser') { Enable-AzContextAutosave -Scope Process -ErrorAction SilentlyContinue | Out-Null }
    if ($null -ne $script:IDNPriorAzContext) { $null = Set-AzContext -Context $script:IDNPriorAzContext -ErrorAction SilentlyContinue -WarningAction SilentlyContinue }
}

function Invoke-IDNArmRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Path,
        [switch]$All
    )

    if (-not $script:ArmToken) { throw 'No Azure Resource Manager session (no subscription selected).' }
    $uri = if ($Path -match '^https://') { $Path } else { "https://management.azure.com$Path" }
    $headers = @{ Authorization = "Bearer $($script:ArmToken)" }

    $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
    if (-not $All) { return $response }

    $items = [System.Collections.Generic.List[object]]::new()
    while ($null -ne $response) {
        if ($response.PSObject.Properties.Name -contains 'value') {
            foreach ($item in @($response.value)) { if ($null -ne $item) { $items.Add($item) } }
        }
        $nextLink = $null
        if ($response.PSObject.Properties.Name -contains 'nextLink') { $nextLink = $response.nextLink }
        if ([string]::IsNullOrWhiteSpace($nextLink)) { break }
        $response = Invoke-RestMethod -Uri $nextLink -Headers $headers -Method Get -ErrorAction Stop
    }
    # Unrolled on purpose: callers wrap the call in @(...).
    return $items.ToArray()
}

function Add-IDNArmFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Category,
        [Parameter(Mandatory=$true)] [string]$CheckName,
        [Parameter(Mandatory=$true)] [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$DocLink = ''
    )

    $status = Get-IDNGraphStatusCode -ErrorRecord $ErrorRecord
    if ($status -eq 403 -or $status -eq 401) {
        Add-IDNCheckResult -Category $Category -CheckName $CheckName -Result 'WARN' `
            -Details "Access denied by Azure Resource Manager (HTTP $status). This check could not run." `
            -HowToFix 'Grant the signed-in account the Reader role on the subscription (or the resource), then rerun.' `
            -DocLink $DocLink
    } elseif ($status -eq 404) {
        Add-IDNCheckResult -Category $Category -CheckName $CheckName -Result 'FAIL' `
            -Details 'The resource was not found in the selected subscription.' `
            -Roadblock 'The check cannot validate a resource that does not exist or is in another subscription.' `
            -HowToFix 'Confirm the resource ID and the selected subscription.' `
            -DocLink $DocLink
    } else {
        Add-IDNCheckResult -Category $Category -CheckName $CheckName -Result 'WARN' `
            -Details "Could not query Azure Resource Manager: $($ErrorRecord.Exception.Message)" `
            -HowToFix 'Rerun the check. If it persists, confirm management.azure.com is reachable from this host.' `
            -DocLink $DocLink
    }
}

function Get-IDNRoleAssignments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Scope,
        [Parameter(Mandatory=$true)] [string[]]$RoleIds
    )
    # atScope() returns assignments at this scope and inherited from above it.
    $assignments = @(Invoke-IDNArmRequest -Path "$Scope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()" -All)
    return @($assignments | Where-Object {
        $roleGuid = ([string]$_.properties.roleDefinitionId -split '/')[-1]
        $roleGuid -in $RoleIds
    })
}

function Get-IDNResourceGroupScope {
    param([Parameter(Mandatory=$true)] [string]$ResourceId)
    if ($ResourceId -match '^(/subscriptions/[^/]+/resourceGroups/[^/]+)') { return $Matches[1] }
    return $null
}

#endregion

#region -- Microsoft Graph Sign-In ---------------------------------------------

function Connect-IDNGraphAccount {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)] [string]$TenantId)

    Write-IDNSection -Title 'MICROSOFT GRAPH AUTHENTICATION'
    try {
        # The same Azure sign-in, asked for a Microsoft Graph token: no second sign-in.
        $tok = Get-AzAccessToken -ResourceTypeName MSGraph -TenantId $TenantId -ErrorAction Stop -WarningAction SilentlyContinue
        $script:GraphToken = ConvertTo-IDNTokenText -Token $tok.Token
        $claims = Get-IDNTokenClaims -Token $script:GraphToken
        $script:GraphScopes = @(@(([string]$claims.scp) -split ' ') + @($claims.roles) | Where-Object { $_ })
        $null = Invoke-IDNGraphRequest -Uri 'v1.0/organization?$select=id'
        $who = if ($claims.upn) { "$($claims.upn) (via $($claims.app_displayname))" } else { "app $($claims.app_displayname) ($($claims.appid))" }
        Write-IDNLog -Level 'PASS' -Message "Authenticated: $who"
        Write-IDNLog -Level 'INFO' -Message "Tenant: $($claims.tid)"
        return $true
    } catch {
        Write-IDNLog -Level 'FAIL' -Message "Microsoft Graph authentication failed: $($_.Exception.Message)"
        return $false
    }
}

function Test-IDNGraphPermissions {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)] [string[]]$RequiredScopes)

    Write-IDNSection -Title 'GRAPH PERMISSIONS'
    $granted = @($script:GraphScopes)

    # A user signed in through Azure PowerShell reads with the account's own Entra roles.
    if ($granted -contains 'Directory.AccessAsUser.All') {
        Add-IDNCheckResult -Category 'Authentication' -CheckName 'Microsoft Graph Access' -Result 'PASS' `
            -Details 'Signed in as a user: Microsoft Graph is read with the account''s own Entra roles (Global Reader is enough). A check the account cannot read reports access denied.' `
            -DocLink 'https://learn.microsoft.com/entra/identity/role-based-access-control/permissions-reference#global-reader'
        return
    }

    foreach ($scope in $RequiredScopes) {
        $writeVariant = $scope -replace '\.Read\.', '.ReadWrite.'
        if (($granted -contains $scope) -or ($granted -contains $writeVariant)) {
            Add-IDNCheckResult -Category 'Authentication' -CheckName "Permission: $scope" -Result 'PASS' -Details 'Granted'
        } else {
            Add-IDNCheckResult -Category 'Authentication' -CheckName "Permission: $scope" -Result 'WARN' `
                -Details 'Not present in the token. Checks that need it will report access denied.' `
                -HowToFix "Grant '$scope' with admin consent to the app used for sign-in, then rerun." `
                -DocLink 'https://learn.microsoft.com/graph/permissions-reference'
        }
    }
}

function Get-IDNServicePrincipal {
    param([Parameter(Mandatory=$true)] [string]$AppId)
    return @(Invoke-IDNGraphRequest -Uri "v1.0/servicePrincipals?`$filter=appId eq '$AppId'&`$select=id,appId,displayName,accountEnabled" -All) | Select-Object -First 1
}

function Test-IDNServicePrincipal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Category,
        [Parameter(Mandatory=$true)] [string]$Name,
        [Parameter(Mandatory=$true)] [string]$AppId,
        [ValidateSet('FAIL','WARN','INFO')] [string]$MissingResult = 'FAIL',
        [string]$Roadblock = '',
        [string]$HowToFix = '',
        [string]$DocLink = ''
    )
    try {
        $sp = Get-IDNServicePrincipal -AppId $AppId
        if ($null -ne $sp -and $sp.accountEnabled -ne $false) {
            Add-IDNCheckResult -Category $Category -CheckName "Service Principal: $Name" -Result 'PASS' -Details "Present and enabled (appId $AppId)"
        } elseif ($null -ne $sp) {
            Add-IDNCheckResult -Category $Category -CheckName "Service Principal: $Name" -Result $MissingResult `
                -Details "Present but disabled (appId $AppId)" -Roadblock $Roadblock `
                -HowToFix 'Enable the service principal: Entra admin center > Enterprise applications > the app > Properties > Enabled for users to sign-in: Yes.' -DocLink $DocLink
        } else {
            Add-IDNCheckResult -Category $Category -CheckName "Service Principal: $Name" -Result $MissingResult `
                -Details "Not found in the tenant (appId $AppId)" -Roadblock $Roadblock -HowToFix $HowToFix -DocLink $DocLink
        }
    } catch {
        Add-IDNGraphFailure -Category $Category -CheckName "Service Principal: $Name" -ErrorRecord $_ -Permission 'Application.Read.All' -DocLink $DocLink
    }
}

#endregion

#region -- Common Identity Checks ----------------------------------------------

function Test-IDNDirectorySync {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)] [string]$Model)

    Write-IDNSection -Title 'DIRECTORY SYNCHRONIZATION'
    $syncDoc = 'https://learn.microsoft.com/entra/identity/hybrid/connect/how-to-connect-sync-whatis'
    $required = $Model -in @('ADDS', 'EntraIDKerberos')

    try {
        $org = @(Invoke-IDNGraphRequest -Uri 'v1.0/organization?$select=id,displayName,onPremisesSyncEnabled,onPremisesLastSyncDateTime' -All) | Select-Object -First 1
        $script:SyncEnabled = [bool]$org.onPremisesSyncEnabled
        $last = $org.onPremisesLastSyncDateTime

        if (-not $script:SyncEnabled) {
            if ($required) {
                Add-IDNCheckResult -Category 'Sync' -CheckName 'Directory Synchronization' -Result 'FAIL' `
                    -Details 'The tenant is not synchronized from an on-premises AD DS.' `
                    -Roadblock "$($script:ModelNames[$Model]) needs hybrid identities: users that exist in AD DS and are synchronized to Entra ID." `
                    -HowToFix 'Install Microsoft Entra Connect Sync or Entra Cloud Sync, scope it to the user OUs, and confirm the first sync completes.' `
                    -DocLink $syncDoc
            } else {
                Add-IDNCheckResult -Category 'Sync' -CheckName 'Directory Synchronization' -Result 'INFO' `
                    -Details 'Cloud-only tenant (no on-premises synchronization). Supported by this identity model.'
            }
            return
        }

        $ageHours = if ($last) { [math]::Round(((Get-Date).ToUniversalTime() - (Get-Date $last).ToUniversalTime()).TotalHours, 1) } else { $null }
        if ($null -eq $ageHours) {
            Add-IDNCheckResult -Category 'Sync' -CheckName 'Directory Synchronization' -Result $(if ($required) { 'FAIL' } else { 'WARN' }) `
                -Details 'Synchronization is enabled but has never completed.' `
                -Roadblock $(if ($required) { 'Users from AD DS do not exist in Entra ID yet.' } else { '' }) `
                -HowToFix 'On the sync server, check the Entra Connect Synchronization Service Manager (or the Cloud Sync agent) for errors.' -DocLink $syncDoc
        } elseif ($ageHours -le 3) {
            Add-IDNCheckResult -Category 'Sync' -CheckName 'Directory Synchronization' -Result 'PASS' `
                -Details "Enabled | Last sync $ageHours hour(s) ago"
        } elseif ($ageHours -le 24) {
            Add-IDNCheckResult -Category 'Sync' -CheckName 'Directory Synchronization' -Result 'WARN' `
                -Details "Enabled | Last sync $ageHours hour(s) ago (the default cycle is 30 minutes)" `
                -HowToFix 'Check the sync server and run Start-ADSyncSyncCycle -PolicyType Delta to confirm it still completes.' -DocLink $syncDoc
        } else {
            Add-IDNCheckResult -Category 'Sync' -CheckName 'Directory Synchronization' -Result $(if ($required) { 'FAIL' } else { 'WARN' }) `
                -Details "Enabled | Last sync $ageHours hour(s) ago  -  synchronization has stopped" `
                -Roadblock $(if ($required) { 'New users, group changes and password changes no longer reach Entra ID.' } else { '' }) `
                -HowToFix 'Restore the sync server (service running, connector credentials valid), then run a delta sync.' -DocLink $syncDoc
        }
    } catch {
        Add-IDNGraphFailure -Category 'Sync' -CheckName 'Directory Synchronization' -ErrorRecord $_ -Permission 'Organization.Read.All' -DocLink $syncDoc
        return
    }

    try {
        $syncConfig = @(Invoke-IDNGraphRequest -Uri 'v1.0/directory/onPremisesSynchronization' -All) | Select-Object -First 1
        $features = Get-IDNPropertyValue -InputObject $syncConfig -Name 'features'
        $script:PhsEnabled = [bool](Get-IDNPropertyValue -InputObject $features -Name 'passwordSyncEnabled')
        Add-IDNCheckResult -Category 'Sync' -CheckName 'Password Hash Synchronization' -Result 'INFO' `
            -Details "Password hash sync enabled: $($script:PhsEnabled)"
    } catch {
        Add-IDNGraphFailure -Category 'Sync' -CheckName 'Password Hash Synchronization' -ErrorRecord $_ -Permission 'OnPremDirectorySynchronization.Read.All' -DocLink $syncDoc
    }
}

function Test-IDNTestUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Model,
        [string]$UserPrincipalName
    )

    Write-IDNSection -Title 'TEST USER IDENTITY SOURCE'

    if ([string]::IsNullOrWhiteSpace($UserPrincipalName)) {
        Add-IDNCheckResult -Category 'User' -CheckName 'Test User' -Result 'SKIP' `
            -Details 'No test user given. Pass -TestUserUpn to confirm a real user fits this identity model.'
        return
    }

    try {
        $select = 'userPrincipalName,accountEnabled,onPremisesSyncEnabled,onPremisesSecurityIdentifier,onPremisesDomainName,onPremisesSamAccountName,lastPasswordChangeDateTime,assignedLicenses'
        $user = Invoke-IDNGraphRequest -Uri ("v1.0/users/{0}?`$select={1}" -f [uri]::EscapeDataString($UserPrincipalName), $select)
        $script:TestUser = $user
    } catch {
        if ((Get-IDNGraphStatusCode -ErrorRecord $_) -eq 404) {
            Add-IDNCheckResult -Category 'User' -CheckName "Test User: $UserPrincipalName" -Result 'FAIL' `
                -Details 'User not found in this tenant.' `
                -Roadblock 'The user cannot sign in to a tenant they do not exist in.' `
                -HowToFix 'Check the UPN, or confirm the user is in the sync scope and the last sync included them.'
        } else {
            Add-IDNGraphFailure -Category 'User' -CheckName "Test User: $UserPrincipalName" -ErrorRecord $_ -Permission 'User.Read.All'
        }
        return
    }

    $hybrid = [bool]$user.onPremisesSyncEnabled -and -not [string]::IsNullOrWhiteSpace([string]$user.onPremisesSecurityIdentifier)
    $source = if ($hybrid) { "hybrid (AD DS domain $($user.onPremisesDomainName), SID present)" } else { 'cloud-only' }
    $enabled = if ($user.accountEnabled) { 'enabled' } else { 'DISABLED' }

    if (-not $user.accountEnabled) {
        Add-IDNCheckResult -Category 'User' -CheckName "Test User: $UserPrincipalName" -Result 'FAIL' `
            -Details "Account is disabled | Source: $source" `
            -Roadblock 'A disabled account cannot sign in.' `
            -HowToFix 'Enable the account (in AD DS for a synced user, then sync).'
        return
    }

    switch ($Model) {
        { $_ -in @('ADDS', 'EntraIDKerberos') } {
            if ($hybrid) {
                Add-IDNCheckResult -Category 'User' -CheckName "Test User: $UserPrincipalName" -Result 'PASS' `
                    -Details "Source: $source | Account $enabled"
            } else {
                Add-IDNCheckResult -Category 'User' -CheckName "Test User: $UserPrincipalName" -Result 'FAIL' `
                    -Details "Source: $source" `
                    -Roadblock "$($script:ModelNames[$Model]) authenticates against AD DS identities (Kerberos tickets carry the on-premises SID). A cloud-only user cannot sign in to an AD DS domain or reach an Entra Kerberos file share with NTFS permissions." `
                    -HowToFix 'Create the user in AD DS and let sync link it to Entra ID, or choose the Entra ID model for cloud-only users.' `
                    -DocLink 'https://learn.microsoft.com/entra/identity/hybrid/whatis-hybrid-identity'
            }
        }
        'EntraDS' {
            if ($hybrid -and $script:SyncEnabled -and $script:PhsEnabled -eq $false) {
                Add-IDNCheckResult -Category 'User' -CheckName "Test User: $UserPrincipalName" -Result 'FAIL' `
                    -Details "Source: $source | Password hash sync is OFF" `
                    -Roadblock 'Entra DS can only authenticate synced users whose password hashes are synchronized.' `
                    -HowToFix 'Enable password hash synchronization in Entra Connect, then force a full password sync.' `
                    -DocLink 'https://learn.microsoft.com/entra/identity/domain-services/tutorial-configure-password-hash-sync'
            } elseif (-not $hybrid -and $script:EntraDsCreated -and $user.lastPasswordChangeDateTime -and ((Get-Date $user.lastPasswordChangeDateTime) -lt (Get-Date $script:EntraDsCreated))) {
                Add-IDNCheckResult -Category 'User' -CheckName "Test User: $UserPrincipalName" -Result 'FAIL' `
                    -Details "Source: cloud-only | Password last changed $($user.lastPasswordChangeDateTime), before the managed domain was created ($($script:EntraDsCreated))" `
                    -Roadblock 'Entra DS has no password hash for this user until the password is changed, so domain sign-in fails.' `
                    -HowToFix 'Have the user change their password (SSPR or https://myaccount.microsoft.com), wait about 20 minutes, then retry.' `
                    -DocLink 'https://learn.microsoft.com/entra/identity/domain-services/tutorial-create-instance#enable-user-accounts-for-azure-ad-ds'
            } else {
                Add-IDNCheckResult -Category 'User' -CheckName "Test User: $UserPrincipalName" -Result 'PASS' `
                    -Details "Source: $source | Account $enabled"
            }
        }
        'EntraID' {
            Add-IDNCheckResult -Category 'User' -CheckName "Test User: $UserPrincipalName" -Result 'PASS' `
                -Details "Source: $source | Account $enabled. Entra ID sign-in accepts cloud-only and hybrid users."
        }
    }

    $licenses = @($user.assignedLicenses).Count
    Add-IDNCheckResult -Category 'User' -CheckName "Licenses: $UserPrincipalName" -Result $(if ($licenses -gt 0) { 'INFO' } else { 'WARN' }) `
        -Details "$licenses license(s) assigned" `
        -HowToFix $(if ($licenses -eq 0) { 'Assign the license the deployment needs (for example Microsoft 365 or Windows Enterprise for desktop and device scenarios; Microsoft Entra ID P1 for Conditional Access).' } else { '' })
}

function Test-IDNVNetDns {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Model,
        [string[]]$ExpectedDnsServers = @()
    )

    $dnsDoc = 'https://learn.microsoft.com/azure/virtual-network/virtual-networks-name-resolution-for-vms-and-role-instances'
    if ($null -eq $script:SelectedVNet) {
        Add-IDNCheckResult -Category 'Network' -CheckName 'VNet DNS' -Result 'SKIP' `
            -Details 'No virtual network selected. Pass -VNetId to validate DNS for domain join.'
        return
    }

    $vnet = $script:SelectedVNet
    $dns = @($vnet.properties.dhcpOptions.dnsServers | Where-Object { $_ })
    $dnsText = if ($dns.Count) { $dns -join ', ' } else { 'Azure-provided DNS' }

    switch ($Model) {
        'ADDS' {
            if ($dns.Count -eq 0) {
                Add-IDNCheckResult -Category 'Network' -CheckName "VNet DNS: $($vnet.name)" -Result 'FAIL' `
                    -Details 'The VNet uses Azure-provided DNS.' `
                    -Roadblock 'Azure DNS cannot resolve the AD DS domain, so machines cannot locate a domain controller and domain join fails.' `
                    -HowToFix 'Set the VNet DNS servers to the domain controllers (or DNS forwarders that resolve the AD zone), then restart the VMs.' `
                    -DocLink $dnsDoc
            } else {
                Add-IDNCheckResult -Category 'Network' -CheckName "VNet DNS: $($vnet.name)" -Result 'PASS' `
                    -Details "Custom DNS: $dnsText. Confirm these are domain controllers or forward the AD zone."
            }
        }
        'EntraDS' {
            $missing = @($ExpectedDnsServers | Where-Object { $_ -notin $dns })
            if ($ExpectedDnsServers.Count -eq 0) {
                Add-IDNCheckResult -Category 'Network' -CheckName "VNet DNS: $($vnet.name)" -Result 'INFO' `
                    -Details "DNS: $dnsText. Managed domain controller addresses were not available to compare."
            } elseif ($missing.Count -eq 0) {
                Add-IDNCheckResult -Category 'Network' -CheckName "VNet DNS: $($vnet.name)" -Result 'PASS' `
                    -Details "DNS points to the managed domain controllers ($dnsText)"
            } else {
                Add-IDNCheckResult -Category 'Network' -CheckName "VNet DNS: $($vnet.name)" -Result 'FAIL' `
                    -Details "DNS: $dnsText | Managed domain controllers: $($ExpectedDnsServers -join ', ')" `
                    -Roadblock 'Machines cannot locate the managed domain, so domain join fails.' `
                    -HowToFix "Set the VNet DNS servers to $($ExpectedDnsServers -join ' and '), then restart the VMs." `
                    -DocLink 'https://learn.microsoft.com/entra/identity/domain-services/tutorial-configure-networking#configure-dns-servers-in-the-peered-virtual-network'
            }
        }
        default {
            Add-IDNCheckResult -Category 'Network' -CheckName "VNet DNS: $($vnet.name)" -Result 'INFO' `
                -Details "DNS: $dnsText. Entra join needs no domain controller; DNS must resolve public Microsoft endpoints."
        }
    }
}

function Test-IDNStorageIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Model,
        [string]$StorageAccountId
    )

    Write-IDNSection -Title 'AZURE FILES IDENTITY'
    $filesDoc = 'https://learn.microsoft.com/azure/storage/files/storage-files-active-directory-overview'

    if ([string]::IsNullOrWhiteSpace($StorageAccountId)) {
        Add-IDNCheckResult -Category 'Storage' -CheckName 'Azure Files Identity' -Result 'SKIP' `
            -Details 'No storage account selected. Pass -StorageAccountId to check Azure Files authentication for this model.'
        return $null
    }
    if (-not $script:ArmToken) {
        Add-IDNCheckResult -Category 'Storage' -CheckName 'Azure Files Identity' -Result 'SKIP' -Details 'No subscription selected'
        return $null
    }

    try {
        $sa = Invoke-IDNArmRequest -Path "$($StorageAccountId)?api-version=2023-01-01"
    } catch {
        Add-IDNArmFailure -Category 'Storage' -CheckName 'Azure Files Identity' -ErrorRecord $_ -DocLink $filesDoc
        return $null
    }

    $auth = $sa.properties.azureFilesIdentityBasedAuthentication
    $option = [string](Get-IDNPropertyValue -InputObject $auth -Name 'directoryServiceOptions')
    if (-not $option) { $option = 'None' }
    $expected = $script:ModelStorageOption[$Model]
    $labels = @{ AD = 'AD DS'; AADDS = 'Entra Domain Services'; AADKERB = 'Entra Kerberos'; None = 'none' }

    if ($option -eq $expected) {
        Add-IDNCheckResult -Category 'Storage' -CheckName "Identity Source: $($sa.name)" -Result 'PASS' `
            -Details "Azure Files authenticates with $($labels[$option]), as $($script:ModelNames[$Model]) requires"
    } else {
        Add-IDNCheckResult -Category 'Storage' -CheckName "Identity Source: $($sa.name)" -Result 'FAIL' `
            -Details "Configured: $($labels[$option]) | Required for this model: $($labels[$expected])" `
            -Roadblock 'Users cannot mount the file share with their identity (for example, FSLogix profiles fail to load at sign-in).' `
            -HowToFix "Enable $($labels[$expected]) authentication on the storage account (Storage account > Data storage > File shares > Identity-based access). A storage account supports one identity source at a time." `
            -DocLink $filesDoc
    }

    $adProps = Get-IDNPropertyValue -InputObject $auth -Name 'activeDirectoryProperties'
    if ($option -eq 'AD' -and $null -ne $adProps) {
        Add-IDNCheckResult -Category 'Storage' -CheckName "AD DS Join: $($sa.name)" -Result 'INFO' `
            -Details "Joined to $($adProps.domainName) as $($adProps.samAccountName) ($($adProps.accountType)). Its password must be rotated before it expires under the domain policy." `
            -DocLink 'https://learn.microsoft.com/azure/storage/files/storage-files-identity-ad-ds-update-password'
    }

    $default = [string](Get-IDNPropertyValue -InputObject $auth -Name 'defaultSharePermission')
    try {
        $shareRoles = @(Get-IDNRoleAssignments -Scope $StorageAccountId -RoleIds @($script:RoleIds.SmbShareReader, $script:RoleIds.SmbShareContributor, $script:RoleIds.SmbShareElevatedContributor))
        if ($shareRoles.Count -gt 0 -or ($default -and $default -ne 'None')) {
            Add-IDNCheckResult -Category 'Storage' -CheckName "Share Permissions: $($sa.name)" -Result 'PASS' `
                -Details "$($shareRoles.Count) SMB share role assignment(s) | Default share permission: $(if ($default) { $default } else { 'None' })"
        } else {
            Add-IDNCheckResult -Category 'Storage' -CheckName "Share Permissions: $($sa.name)" -Result 'FAIL' `
                -Details 'No Storage File Data SMB Share role is assigned and the default share permission is None.' `
                -Roadblock 'Authenticated users are still refused at the share level, so the share cannot be mounted.' `
                -HowToFix "Assign 'Storage File Data SMB Share Contributor' to the users group on the storage account (or the share), and 'Elevated Contributor' to the admins who set NTFS permissions." `
                -DocLink 'https://learn.microsoft.com/azure/storage/files/storage-files-identity-assign-share-level-permissions'
        }
    } catch {
        Add-IDNArmFailure -Category 'Storage' -CheckName "Share Permissions: $($sa.name)" -ErrorRecord $_
    }

    return $sa
}

function Test-IDNSsoConfiguration {
    [CmdletBinding()]
    param([switch]$Enabled)

    Write-IDNSection -Title 'SINGLE SIGN-ON (MICROSOFT ENTRA AUTHENTICATION FOR RDP)'
    $ssoDoc = 'https://learn.microsoft.com/entra/identity/devices/howto-vm-sign-in-azure-ad-windows'

    if (-not $Enabled) {
        Add-IDNCheckResult -Category 'SSO' -CheckName 'RDP Single Sign-On Configuration' -Result 'SKIP' `
            -Details 'Not checked. Pass -CheckSsoConfiguration to read it (Graph grants this only through a read-write permission; the script still only reads).' `
            -DocLink $ssoDoc
        return
    }

    foreach ($app in @(@{ Name = 'Microsoft Remote Desktop'; AppId = $script:AppIds.MicrosoftRemoteDesktop }, @{ Name = 'Windows Cloud Login'; AppId = $script:AppIds.WindowsCloudLogin })) {
        try {
            $sp = Get-IDNServicePrincipal -AppId $app.AppId
            if ($null -eq $sp) {
                Add-IDNCheckResult -Category 'SSO' -CheckName "RDP Protocol Enabled: $($app.Name)" -Result 'FAIL' `
                    -Details 'Service principal not found' `
                    -Roadblock 'Single sign-on cannot be enabled without it.' `
                    -HowToFix "Create it: New-MgServicePrincipal -AppId $($app.AppId)" -DocLink $ssoDoc
                continue
            }
            $config = Invoke-IDNGraphRequest -Uri "v1.0/servicePrincipals/$($sp.id)/remoteDesktopSecurityConfiguration"
            $on = [bool](Get-IDNPropertyValue -InputObject $config -Name 'isRemoteDesktopProtocolEnabled')
            if ($on) {
                $groups = @()
                try { $groups = @(Invoke-IDNGraphRequest -Uri "v1.0/servicePrincipals/$($sp.id)/remoteDesktopSecurityConfiguration/targetDeviceGroups" -All) } catch { Write-Verbose $_.Exception.Message }
                Add-IDNCheckResult -Category 'SSO' -CheckName "RDP Protocol Enabled: $($app.Name)" -Result 'PASS' `
                    -Details "Enabled | Target device groups (consent prompt hidden): $($groups.Count)"
            } else {
                Add-IDNCheckResult -Category 'SSO' -CheckName "RDP Protocol Enabled: $($app.Name)" -Result 'FAIL' `
                    -Details 'isRemoteDesktopProtocolEnabled is false' `
                    -Roadblock 'Microsoft Entra authentication for RDP fails without it, so single sign-on to Entra-joined machines does not work.' `
                    -HowToFix "Update-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $($sp.id) -IsRemoteDesktopProtocolEnabled" `
                    -DocLink $ssoDoc
            }
        } catch {
            Add-IDNGraphFailure -Category 'SSO' -CheckName "RDP Protocol Enabled: $($app.Name)" -ErrorRecord $_ -Permission 'Application-RemoteDesktopConfig.ReadWrite.All' -DocLink $ssoDoc
        }
    }
}

function Get-IDNMfaPoliciesCovering {
    param([Parameter(Mandatory=$true)] [string]$AppId)
    # Enabled Conditional Access policies that require MFA (or an authentication
    # strength) for this app, either named or through All cloud apps, without excluding it.
    $policies = @(Invoke-IDNGraphRequest -Uri 'v1.0/identity/conditionalAccess/policies' -All)
    return @($policies | Where-Object {
        $_.state -eq 'enabled' -and
        ((@($_.grantControls.builtInControls) -contains 'mfa') -or $null -ne $_.grantControls.authenticationStrength) -and
        ((@($_.conditions.applications.includeApplications) -contains 'All') -or (@($_.conditions.applications.includeApplications) -contains $AppId)) -and
        (@($_.conditions.applications.excludeApplications) -notcontains $AppId)
    })
}

function Test-IDNDomainConnectivity {
    [CmdletBinding()]
    param([string]$DomainName)

    Write-IDNSection -Title 'DOMAIN CONTROLLER REACHABILITY (from this host)'

    if ([string]::IsNullOrWhiteSpace($DomainName)) {
        Add-IDNCheckResult -Category 'Domain' -CheckName 'Domain Controller Discovery' -Result 'SKIP' `
            -Details 'No domain name given. Pass -DomainName (for example corp.contoso.com) to test DC discovery from this host.'
        return
    }
    if (-not (Get-Command -Name Resolve-DnsName -ErrorAction SilentlyContinue)) {
        Add-IDNCheckResult -Category 'Domain' -CheckName 'Domain Controller Discovery' -Result 'SKIP' -Details 'Resolve-DnsName is Windows-only'
        return
    }

    Add-IDNCheckResult -Category 'Domain' -CheckName 'Test Origin' -Result 'INFO' `
        -Details "These tests run from '$env:COMPUTERNAME'. The machines that join the domain need the same results from their own subnet."

    try {
        $srv = @(Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$DomainName" -Type SRV -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'SRV' })
    } catch {
        Add-IDNCheckResult -Category 'Domain' -CheckName "DC Locator: $DomainName" -Result 'WARN' `
            -Details "SRV record _ldap._tcp.dc._msdcs.$DomainName does not resolve from this host" `
            -HowToFix 'Run this from a machine that uses the same VNet DNS as the machines that join. If it still fails there, fix the DNS servers or forwarders for the AD zone.' `
            -DocLink 'https://learn.microsoft.com/troubleshoot/windows-server/networking/verify-srv-dns-records-have-been-created'
        return
    }

    Add-IDNCheckResult -Category 'Domain' -CheckName "DC Locator: $DomainName" -Result 'PASS' `
        -Details "$($srv.Count) domain controller(s): $((@($srv | Select-Object -ExpandProperty NameTarget -First 4)) -join ', ')"

    $ports = @(@{ Port = 53; Name = 'DNS' }, @{ Port = 88; Name = 'Kerberos' }, @{ Port = 135; Name = 'RPC endpoint mapper' }, @{ Port = 389; Name = 'LDAP' }, @{ Port = 445; Name = 'SMB (SYSVOL, Group Policy)' }, @{ Port = 464; Name = 'Kerberos password change' }, @{ Port = 3268; Name = 'Global Catalog' })
    foreach ($dc in @($srv | Select-Object -First 2)) {
        foreach ($p in $ports) {
            $client = $null
            try {
                $client = New-Object System.Net.Sockets.TcpClient
                $connect = $client.BeginConnect($dc.NameTarget, $p.Port, $null, $null)
                $ok = $connect.AsyncWaitHandle.WaitOne(3000, $false) -and $client.Connected
            } catch { $ok = $false } finally { if ($null -ne $client) { $client.Close() } }
            Add-IDNCheckResult -Category 'Domain' -CheckName "$($dc.NameTarget):$($p.Port)" -Result $(if ($ok) { 'PASS' } else { 'WARN' }) `
                -Details $p.Name `
                -HowToFix $(if (-not $ok) { "Allow TCP $($p.Port) from the subnet of the machines to the domain controllers (NSG, firewall, and the DC's Windows Firewall). Dynamic RPC ports 49152-65535 are also required." } else { '' }) `
                -DocLink $(if (-not $ok) { 'https://learn.microsoft.com/troubleshoot/windows-server/networking/service-overview-and-network-port-requirements' } else { '' })
        }
    }
}

#endregion

#region -- Identity Model: AD DS ----------------------------------------------

function Test-IDNModelADDS {
    [CmdletBinding()]
    param([string]$DomainName, [string]$StorageAccountId)

    Write-IDNSection -Title 'IDENTITY MODEL  -  ACTIVE DIRECTORY DOMAIN SERVICES'

    Test-IDNVNetDns -Model 'ADDS'
    Test-IDNDomainConnectivity -DomainName $DomainName

    Write-IDNSection -Title 'AD DS ITEMS TO VERIFY ON-PREMISES (not readable from Azure)'
    Add-IDNCheckResult -Category 'ADDS' -CheckName 'Domain-Join Account and OU' -Result 'INFO' `
        -Details 'The account that joins machines needs Create/Delete Computer objects on the target OU. On a domain-joined machine: (Get-Acl "AD:\OU=Computers,DC=corp,DC=contoso,DC=com").Access | Where-Object IdentityReference -like "*<account>*"' `
        -DocLink 'https://learn.microsoft.com/troubleshoot/windows-server/active-directory/access-denied-when-joining-computers'
    Add-IDNCheckResult -Category 'ADDS' -CheckName 'Hybrid Entra Join (recommended)' -Result 'INFO' `
        -Details 'For Intune and SSO to cloud apps, machines should hybrid-join: the Service Connection Point must be configured in Entra Connect (Device options) and the OU must be in sync scope.' `
        -DocLink 'https://learn.microsoft.com/entra/identity/devices/how-to-hybrid-join'

    $null = Test-IDNStorageIdentity -Model 'ADDS' -StorageAccountId $StorageAccountId
}

#endregion

#region -- Identity Model: Microsoft Entra Domain Services ---------------------

function Test-IDNModelEntraDS {
    [CmdletBinding()]
    param([string]$SubscriptionId, [string]$DomainName, [string]$StorageAccountId)

    Write-IDNSection -Title 'IDENTITY MODEL  -  MICROSOFT ENTRA DOMAIN SERVICES'
    $dsDoc = 'https://learn.microsoft.com/entra/identity/domain-services/overview'

    Test-IDNServicePrincipal -Category 'EntraDS' -Name 'Domain Controller Services' -AppId $script:AppIds.DomainControllerServices `
        -Roadblock 'Entra DS uses this service principal to manage the domain; without it the managed domain cannot be created or serviced.' `
        -HowToFix "New-MgServicePrincipal -AppId $($script:AppIds.DomainControllerServices)" -DocLink $dsDoc

    try {
        $group = @(Invoke-IDNGraphRequest -Uri "v1.0/groups?`$filter=displayName eq 'AAD DC Administrators'&`$select=id,displayName" -All) | Select-Object -First 1
        if ($null -ne $group) {
            $members = @(Invoke-IDNGraphRequest -Uri "v1.0/groups/$($group.id)/members?`$select=id" -All)
            Add-IDNCheckResult -Category 'EntraDS' -CheckName 'AAD DC Administrators Group' -Result $(if ($members.Count -gt 0) { 'PASS' } else { 'WARN' }) `
                -Details "$($members.Count) member(s). The account that joins machines must be a member." `
                -HowToFix $(if ($members.Count -eq 0) { 'Add the domain-join account (or its group) to AAD DC Administrators.' } else { '' })
        } else {
            Add-IDNCheckResult -Category 'EntraDS' -CheckName 'AAD DC Administrators Group' -Result 'WARN' `
                -Details 'Group not found. It is created with the managed domain.' `
                -HowToFix 'Create the managed domain first; then add the domain-join account to AAD DC Administrators.' -DocLink $dsDoc
        }
    } catch {
        Add-IDNGraphFailure -Category 'EntraDS' -CheckName 'AAD DC Administrators Group' -ErrorRecord $_ -Permission 'Directory.Read.All'
    }

    if (-not $script:ArmToken) {
        Add-IDNCheckResult -Category 'EntraDS' -CheckName 'Managed Domain' -Result 'SKIP' -Details 'No subscription selected; the managed domain is an Azure resource.'
        return
    }

    try {
        $provider = Invoke-IDNArmRequest -Path "/subscriptions/$SubscriptionId/providers/Microsoft.AAD?api-version=2021-04-01"
        $state = [string]$provider.registrationState
        Add-IDNCheckResult -Category 'EntraDS' -CheckName 'Provider: Microsoft.AAD' -Result $(if ($state -eq 'Registered') { 'PASS' } else { 'FAIL' }) `
            -Details "State: $state" `
            -Roadblock $(if ($state -ne 'Registered') { 'A managed domain cannot be created in this subscription.' } else { '' }) `
            -HowToFix $(if ($state -ne 'Registered') { "Register-AzResourceProvider -ProviderNamespace Microsoft.AAD" } else { '' })
    } catch {
        Add-IDNArmFailure -Category 'EntraDS' -CheckName 'Provider: Microsoft.AAD' -ErrorRecord $_
    }

    $dcIps = @()
    try {
        $domains = @(Invoke-IDNArmRequest -Path "/subscriptions/$SubscriptionId/providers/Microsoft.AAD/domainServices?api-version=2022-12-01" -All)
        $domain = if ($DomainName) { $domains | Where-Object { $_.properties.domainName -eq $DomainName } | Select-Object -First 1 } else { $domains | Select-Object -First 1 }
        if ($null -eq $domain) {
            Add-IDNCheckResult -Category 'EntraDS' -CheckName 'Managed Domain' -Result 'FAIL' `
                -Details $(if ($domains.Count) { "No managed domain named '$DomainName' (found: $((@($domains | ForEach-Object { $_.properties.domainName })) -join ', '))" } else { 'No Entra Domain Services managed domain in this subscription' }) `
                -Roadblock 'Machines have no domain to join.' `
                -HowToFix 'Create a managed domain (Entra admin center or Azure portal > Microsoft Entra Domain Services), in the region of the machines or a peered VNet.' `
                -DocLink 'https://learn.microsoft.com/entra/identity/domain-services/tutorial-create-instance'
            return
        }

        $script:EntraDsCreated = Get-IDNPropertyValue -InputObject $domain.systemData -Name 'createdAt'
        $alerts = @($domain.properties.healthAlerts)
        $provisioning = [string]$domain.properties.provisioningState
        Add-IDNCheckResult -Category 'EntraDS' -CheckName "Managed Domain: $($domain.properties.domainName)" -Result $(if ($provisioning -eq 'Succeeded' -and $alerts.Count -eq 0) { 'PASS' } elseif ($provisioning -eq 'Succeeded') { 'WARN' } else { 'FAIL' }) `
            -Details "Provisioning: $provisioning | Health alerts: $($alerts.Count) | SKU: $($domain.properties.sku)" `
            -Roadblock $(if ($provisioning -ne 'Succeeded') { 'The managed domain is not ready to authenticate domain joins.' } else { '' }) `
            -HowToFix $(if ($alerts.Count -gt 0) { "Resolve the health alerts: $((@($alerts | ForEach-Object { $_.name })) -join '; ')" } else { '' }) `
            -DocLink 'https://learn.microsoft.com/entra/identity/domain-services/check-health'

        $replicaVnets = @()
        foreach ($replica in @($domain.properties.replicaSets)) {
            $dcIps += @($replica.domainControllerIpAddress)
            if ($replica.subnetId -match '^(.+/virtualNetworks/[^/]+)') { $replicaVnets += $Matches[1] }
            Add-IDNCheckResult -Category 'EntraDS' -CheckName "Replica Set: $($replica.location)" -Result 'INFO' `
                -Details "Domain controllers: $(@($replica.domainControllerIpAddress) -join ', ') | Status: $($replica.serviceStatus)"
        }

        if ($null -ne $script:SelectedVNet) {
            $sessionVnetId = [string]$script:SelectedVNet.id
            $sameVnet = @($replicaVnets | Where-Object { $_ -eq $sessionVnetId }).Count -gt 0
            $peered = @($script:SelectedVNet.properties.virtualNetworkPeerings | Where-Object {
                $_.properties.peeringState -eq 'Connected' -and [string]$_.properties.remoteVirtualNetwork.id -in $replicaVnets
            }).Count -gt 0
            if ($sameVnet -or $peered) {
                Add-IDNCheckResult -Category 'EntraDS' -CheckName 'VNet to Managed Domain' -Result 'PASS' `
                    -Details $(if ($sameVnet) { 'Same virtual network' } else { 'Connected peering to the managed domain VNet' })
            } else {
                Add-IDNCheckResult -Category 'EntraDS' -CheckName 'VNet to Managed Domain' -Result 'FAIL' `
                    -Details "No connected peering from $($script:SelectedVNet.name) to the managed domain VNet" `
                    -Roadblock 'Machines cannot reach the managed domain controllers.' `
                    -HowToFix 'Peer the VNet of the machines with the Entra DS VNet in both directions (or route through a hub that reaches it).' `
                    -DocLink 'https://learn.microsoft.com/entra/identity/domain-services/tutorial-configure-networking'
            }
        }
    } catch {
        Add-IDNArmFailure -Category 'EntraDS' -CheckName 'Managed Domain' -ErrorRecord $_ -DocLink $dsDoc
    }

    Test-IDNVNetDns -Model 'EntraDS' -ExpectedDnsServers $dcIps

    if ($script:SyncEnabled -and $script:PhsEnabled -eq $false) {
        Add-IDNCheckResult -Category 'EntraDS' -CheckName 'Password Hashes for Synced Users' -Result 'FAIL' `
            -Details 'The tenant is synchronized but password hash sync is off.' `
            -Roadblock 'Synced users have no password hash in the managed domain, so they cannot sign in to domain-joined machines.' `
            -HowToFix 'Enable password hash synchronization in Entra Connect, then force a full password sync.' `
            -DocLink 'https://learn.microsoft.com/entra/identity/domain-services/tutorial-configure-password-hash-sync'
    }

    $null = Test-IDNStorageIdentity -Model 'EntraDS' -StorageAccountId $StorageAccountId
}

#endregion

#region -- Identity Model: Microsoft Entra ID ----------------------------------

function Test-IDNEntraJoinSignIn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Category,
        [string]$SubscriptionId
    )

    # Users signing in to Entra-joined Azure VMs need one of these roles. Listed for the whole
    # subscription (no atScope filter), so assignments on resource groups and VMs count too.
    $vmRoleDoc = 'https://learn.microsoft.com/entra/identity/devices/howto-vm-sign-in-azure-ad-windows#configure-role-assignments-for-the-vm'
    if ($SubscriptionId -and $script:ArmToken) {
        try {
            $assignments = @(Invoke-IDNArmRequest -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" -All |
                Where-Object { ([string]$_.properties.roleDefinitionId -split '/')[-1] -in @($script:RoleIds.VirtualMachineUserLogin, $script:RoleIds.VirtualMachineAdministratorLogin) })
            if ($assignments.Count -gt 0) {
                Add-IDNCheckResult -Category $Category -CheckName 'Azure VM Sign-In Roles' -Result 'PASS' `
                    -Details "$($assignments.Count) Virtual Machine User Login or Administrator Login assignment(s) in the subscription" -DocLink $vmRoleDoc
            } else {
                Add-IDNCheckResult -Category $Category -CheckName 'Azure VM Sign-In Roles' -Result 'WARN' `
                    -Details 'No Virtual Machine User Login or Virtual Machine Administrator Login assignment in the subscription.' `
                    -HowToFix 'If users will sign in to Entra-joined Azure VMs, assign Virtual Machine User Login to their group on the VMs or their resource group. Not needed for physical devices.' `
                    -DocLink $vmRoleDoc
            }
        } catch {
            Add-IDNArmFailure -Category $Category -CheckName 'Azure VM Sign-In Roles' -ErrorRecord $_ -DocLink $vmRoleDoc
        }
    } else {
        Add-IDNCheckResult -Category $Category -CheckName 'Azure VM Sign-In Roles' -Result 'SKIP' `
            -Details 'No subscription selected; role assignments are read from Azure.' -DocLink $vmRoleDoc
    }

    Test-IDNServicePrincipal -Category $Category -Name 'Azure Windows VM Sign-In' -AppId $script:AppIds.AzureWindowsVmSignIn -MissingResult 'INFO' `
        -HowToFix 'It appears after the first Entra sign-in to a VM; nothing to do unless Conditional Access must target it.' `
        -DocLink 'https://learn.microsoft.com/entra/identity/devices/howto-vm-sign-in-azure-ad-windows'

    try {
        $mfa = @(Get-IDNMfaPoliciesCovering -AppId $script:AppIds.AzureWindowsVmSignIn)
        if ($mfa.Count -gt 0) {
            Add-IDNCheckResult -Category $Category -CheckName 'MFA on Azure Windows VM Sign-In' -Result 'WARN' `
                -Details "$($mfa.Count) enforced polic(ies) require MFA for VM sign-in: $((@($mfa | ForEach-Object { $_.displayName })) -join '; ')" `
                -HowToFix 'With MFA required on this app, RDP sign-in to Entra-joined Azure VMs from devices that are not Entra joined fails unless Entra single sign-on for RDP is used. Use single sign-on, or exclude Azure Windows VM Sign-In (372140e0-b3b7-4226-8ef9-d57986796201) and enforce MFA on the application users connect through.' `
                -DocLink 'https://learn.microsoft.com/entra/identity/devices/howto-vm-sign-in-azure-ad-windows#using-conditional-access'
        } else {
            Add-IDNCheckResult -Category $Category -CheckName 'MFA on Azure Windows VM Sign-In' -Result 'PASS' `
                -Details 'No enforced Conditional Access policy requires MFA on the VM sign-in itself'
        }
    } catch {
        Add-IDNGraphFailure -Category $Category -CheckName 'MFA on Azure Windows VM Sign-In' -ErrorRecord $_ -Permission 'Policy.Read.All'
    }
}

function Test-IDNModelEntraID {
    [CmdletBinding()]
    param([string]$SubscriptionId, [string]$StorageAccountId)

    Write-IDNSection -Title 'IDENTITY MODEL  -  MICROSOFT ENTRA ID'

    Add-IDNCheckResult -Category 'EntraID' -CheckName 'Domain Requirement' -Result 'INFO' `
        -Details 'Machines are Entra joined (Azure VMs through the AADLoginForWindows extension). No domain controller, domain-join account or line of sight to AD DS is needed.'

    Test-IDNVNetDns -Model 'EntraID'
    Test-IDNEntraJoinSignIn -Category 'EntraID' -SubscriptionId $SubscriptionId

    $sa = Test-IDNStorageIdentity -Model 'EntraID' -StorageAccountId $StorageAccountId
    if ($null -ne $sa -and $null -ne $script:TestUser -and -not [bool]$script:TestUser.onPremisesSyncEnabled) {
        Add-IDNCheckResult -Category 'Storage' -CheckName 'Entra Kerberos for Cloud-Only Users' -Result 'WARN' `
            -Details 'The test user is cloud-only. Entra Kerberos on Azure Files was built for hybrid users; check current Microsoft support for cloud-only identities before relying on it for FSLogix.' `
            -HowToFix 'Use hybrid users (Entra ID Kerberos model), or confirm cloud-only support for your scenario in the linked article.' `
            -DocLink 'https://learn.microsoft.com/azure/storage/files/storage-files-identity-auth-hybrid-identities-enable'
    }
}

#endregion

#region -- Identity Model: Microsoft Entra ID Kerberos -------------------------

function Test-IDNModelEntraIDKerberos {
    [CmdletBinding()]
    param([string]$SubscriptionId, [string]$StorageAccountId)

    Write-IDNSection -Title 'IDENTITY MODEL  -  MICROSOFT ENTRA ID WITH ENTRA KERBEROS'
    $kerbDoc = 'https://learn.microsoft.com/azure/storage/files/storage-files-identity-auth-hybrid-identities-enable'

    Test-IDNVNetDns -Model 'EntraIDKerberos'
    Test-IDNEntraJoinSignIn -Category 'EntraIDKerberos' -SubscriptionId $SubscriptionId

    $sa = Test-IDNStorageIdentity -Model 'EntraIDKerberos' -StorageAccountId $StorageAccountId
    if ($null -ne $sa) {
        $auth = $sa.properties.azureFilesIdentityBasedAuthentication
        $adProps = Get-IDNPropertyValue -InputObject $auth -Name 'activeDirectoryProperties'
        if ($null -ne $adProps -and $adProps.domainName -and $adProps.domainGuid) {
            Add-IDNCheckResult -Category 'EntraIDKerberos' -CheckName "Domain Information: $($sa.name)" -Result 'PASS' `
                -Details "AD DS domain $($adProps.domainName) recorded on the storage account (needed to set NTFS permissions with AD DS groups)"
        } else {
            Add-IDNCheckResult -Category 'EntraIDKerberos' -CheckName "Domain Information: $($sa.name)" -Result 'WARN' `
                -Details 'No AD DS domain name and GUID on the storage account' `
                -HowToFix 'Set the domain name and GUID on the storage account (Identity-based access > Entra Kerberos), so NTFS permissions can be set with AD DS users and groups.' `
                -DocLink $kerbDoc
        }

        $appName = "[Storage Account] $($sa.name).file.core.windows.net"
        try {
            $storageSp = @(Invoke-IDNGraphRequest -Uri ("v1.0/servicePrincipals?`$filter=displayName eq '{0}'&`$select=id,appId,displayName" -f $appName.Replace("'", "''")) -All) | Select-Object -First 1
            if ($null -eq $storageSp) {
                Add-IDNCheckResult -Category 'EntraIDKerberos' -CheckName 'Storage Account App Registration' -Result 'FAIL' `
                    -Details "No enterprise application named '$appName'" `
                    -Roadblock 'Entra Kerberos cannot issue tickets for the share without it.' `
                    -HowToFix 'Re-enable Entra Kerberos on the storage account; Azure creates the application when it is enabled.' -DocLink $kerbDoc
            } else {
                $grants = @(Invoke-IDNGraphRequest -Uri "v1.0/oauth2PermissionGrants?`$filter=clientId eq '$($storageSp.id)'" -All)
                $consented = @($grants | Where-Object { $_.consentType -eq 'AllPrincipals' }).Count -gt 0
                Add-IDNCheckResult -Category 'EntraIDKerberos' -CheckName 'Storage Account App: Admin Consent' -Result $(if ($consented) { 'PASS' } else { 'FAIL' }) `
                    -Details $(if ($consented) { "Admin consent granted for '$appName'" } else { "No tenant-wide consent for '$appName'" }) `
                    -Roadblock $(if (-not $consented) { 'Kerberos ticket requests for the share are refused until an administrator consents.' } else { '' }) `
                    -HowToFix $(if (-not $consented) { "Entra admin center > App registrations > All applications > '$appName' > API permissions > Grant admin consent." } else { '' }) `
                    -DocLink $kerbDoc

                $mfa = @(Get-IDNMfaPoliciesCovering -AppId ([string]$storageSp.appId))
                if ($mfa.Count -gt 0) {
                    Add-IDNCheckResult -Category 'EntraIDKerberos' -CheckName 'MFA Exclusion for the Storage App' -Result 'FAIL' `
                        -Details "$($mfa.Count) enforced polic(ies) require MFA for the storage app: $((@($mfa | ForEach-Object { $_.displayName })) -join '; ')" `
                        -Roadblock 'Entra Kerberos does not support MFA on the storage application; profile mounts fail with access denied.' `
                        -HowToFix "Exclude '$appName' (appId $($storageSp.appId)) from these Conditional Access policies." `
                        -DocLink "$kerbDoc#disable-multifactor-authentication-on-the-storage-account"
                } else {
                    Add-IDNCheckResult -Category 'EntraIDKerberos' -CheckName 'MFA Exclusion for the Storage App' -Result 'PASS' `
                        -Details 'No enforced Conditional Access policy requires MFA for the storage app'
                }
            }
        } catch {
            Add-IDNGraphFailure -Category 'EntraIDKerberos' -CheckName 'Storage Account App Registration' -ErrorRecord $_ -Permission 'Application.Read.All' -DocLink $kerbDoc
        }
    }

    Write-IDNSection -Title 'ENTRA KERBEROS ITEMS TO VERIFY ON THE MACHINES (not readable from Azure)'
    Add-IDNCheckResult -Category 'EntraIDKerberos' -CheckName 'Cloud Kerberos Ticket Retrieval' -Result 'INFO' `
        -Details 'Machines must have CloudKerberosTicketRetrievalEnabled = 1 (Intune settings catalog: Kerberos > Cloud Kerberos Ticket Retrieval Enabled). Check on a host: Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters -Name CloudKerberosTicketRetrievalEnabled' `
        -DocLink "$kerbDoc#configure-the-clients-to-retrieve-kerberos-tickets"
    Add-IDNCheckResult -Category 'EntraIDKerberos' -CheckName 'Kerberos Server Object (on-premises SSO)' -Result 'INFO' `
        -Details 'Only for SSO from these machines to on-premises resources: create the Entra Kerberos server object in AD DS. Check with Get-AzureADKerberosServer (AzureADHybridAuthenticationManagement module).' `
        -DocLink 'https://learn.microsoft.com/entra/identity/authentication/howto-authentication-passwordless-security-key-on-premises'
}

#endregion

# INTERACTIVE SETUP WIZARD
# ==============================================================================

#region -- Setup Wizard --------------------------------------------------------

function Get-IDNWizardMenuChoice {
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

function Write-IDNWizardHeader {
    param([Parameter(Mandatory=$true)] [string]$Title)
    $line70 = '-' * 70
    Clear-Host
    Write-Host ''
    Write-Host "  $line70" -ForegroundColor White
    Write-Host "  $Title" -ForegroundColor White
    Write-Host "  $line70" -ForegroundColor White
    Write-Host ''
}

function Select-IDNFromList {
    [CmdletBinding()]
    param(
        [object[]]$Items,
        [Parameter(Mandatory=$true)] [scriptblock]$Label,
        [Parameter(Mandatory=$true)] [string]$SkipLabel,
        # Plural noun for the empty-list message, e.g. 'virtual networks'.
        [Parameter(Mandatory=$true)] [string]$Kind,
        [Parameter(Mandatory=$true)] [string]$SkippedChecks,
        [string]$SubscriptionName
    )
    $Items = @($Items)
    # A menu whose only entry is Skip reads as a broken list, so say what happened.
    if ($Items.Count -eq 0) {
        Write-Host "  No $Kind were found in subscription '$SubscriptionName'." -ForegroundColor Yellow
        Write-Host "  $SkippedChecks will be skipped." -ForegroundColor Yellow
        Write-Host ''
        $null = Read-Host '  Press ENTER to continue  '
        return $null
    }
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("  [{0,2}] {1}" -f ($i + 1), (& $Label $Items[$i])) -ForegroundColor White
    }
    $skip = $Items.Count + 1
    Write-Host ''
    Write-Host ("  [{0,2}] {1}" -f $skip, $SkipLabel) -ForegroundColor DarkGray
    Write-Host ''
    $n = Get-IDNWizardMenuChoice -Min 1 -Max $skip -Default $(if ($Items.Count -gt 0) { 1 } else { $skip })
    if ($n -eq $skip) { return $null }
    return $Items[$n - 1]
}

function Invoke-IDNSetupWizard {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)] [string[]]$Scopes)

    $eq70 = '=' * 70
    Clear-Host
    Write-Host ''
    Write-Host "  $eq70" -ForegroundColor Cyan
    Write-Host '  IDENTITY PROVISIONING  -  PREREQUISITES WIZARD' -ForegroundColor Cyan
    Write-Host "  $eq70" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  This wizard checks, read-only, everything your chosen identity model needs:' -ForegroundColor White
    Write-Host '  directory sync, domain services, DNS, Azure Files identity, sign-in roles.' -ForegroundColor White
    Write-Host ''
    Write-Host '  HOW TO USE THIS WIZARD' -ForegroundColor Cyan
    Write-Host '  Answer 4 short questions. Press ENTER at any prompt to accept the' -ForegroundColor Gray
    Write-Host '  suggested default shown in [square brackets].' -ForegroundColor Gray
    Write-Host ''
    $null = Read-Host '  Press ENTER to begin  '

    $config = [ordered]@{
        AuthMethod = 'Interactive'; Azure = $null; GraphAuthenticated = $false
        IdentityModel = ''
        VNetId = ''; StorageAccountId = ''; TestUserUpn = ''; DomainName = ''
    }

    # -- STEP 1: Sign in ---------------------------------------------------------
    Write-IDNWizardHeader -Title 'STEP 1 of 4  -  SIGN IN'
    Write-Host '  You sign in once, to Azure. The same sign-in lists your tenants and' -ForegroundColor Gray
    Write-Host '  subscriptions and reads Microsoft Graph for the tenant you choose. Read-only.' -ForegroundColor Gray
    Write-Host '  How would you like to sign in?' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  [1] Open a browser window to sign in (recommended for most users)' -ForegroundColor White
    Write-Host '      A login window will pop up in your default browser.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [2] Device code login  (enter a short code on a web page)' -ForegroundColor White
    Write-Host '      Use this if the browser popup is blocked or you are on a server.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Service principal and managed identity sign-in: use -AuthMethod with -NonInteractive.' -ForegroundColor DarkGray
    Write-Host ''
    $config.AuthMethod = if ((Get-IDNWizardMenuChoice -Min 1 -Max 2 -Default 1) -eq 2) { 'DeviceCode' } else { 'Interactive' }

    try {
        if (-not $SkipModuleValidation) { Import-IDNRequiredModulesToMemory -Modules $RequiredModules }
        Write-Host ''
        Write-Host '  Signing in to Azure...' -ForegroundColor Cyan
        $config.Azure = Connect-IDNAzure -Method $config.AuthMethod
        Clear-Host
        Write-Host ''
        Write-Host "  Tenant       : $($config.Azure.TenantName) ($($config.Azure.TenantId))" -ForegroundColor Green
        Write-Host "  Subscription : $(if ($config.Azure.SubscriptionId) { "$($config.Azure.SubscriptionName) ($($config.Azure.SubscriptionId))" } else { 'none  -  directory checks only' })" -ForegroundColor Green
        Write-Host ''
        $config.GraphAuthenticated = Connect-IDNGraphAccount -TenantId $config.Azure.TenantId
    } catch {
        Write-Host ''
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '  The wizard cannot continue without a tenant. Rerun when sign-in is possible.' -ForegroundColor Yellow
        throw
    }
    if (-not $config.GraphAuthenticated) { throw 'Microsoft Graph sign-in did not complete.' }
    $null = Read-Host '  Press ENTER to continue  '

    # -- STEP 2: Identity model ----------------------------------------------------
    Write-IDNWizardHeader -Title 'STEP 2 of 4  -  IDENTITY MODEL'
    Write-Host '  How will users and machines authenticate? Only this model is checked;' -ForegroundColor Gray
    Write-Host '  run the script again to check another.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  [1] Active Directory Domain Services (AD DS)' -ForegroundColor White
    Write-Host '      Machines join your AD domain; users are synced from AD DS to Entra ID.' -ForegroundColor DarkGray
    Write-Host '  [2] Microsoft Entra Domain Services' -ForegroundColor White
    Write-Host '      Machines join a Microsoft-managed domain built from Entra ID.' -ForegroundColor DarkGray
    Write-Host '  [3] Microsoft Entra ID' -ForegroundColor White
    Write-Host '      Machines are Entra joined; no domain. Cloud-only or synced users.' -ForegroundColor DarkGray
    Write-Host '  [4] Microsoft Entra ID with Entra Kerberos' -ForegroundColor White
    Write-Host '      Entra-joined machines, hybrid users, Azure Files through Entra Kerberos.' -ForegroundColor DarkGray
    Write-Host ''
    $config.IdentityModel = @('ADDS', 'EntraDS', 'EntraID', 'EntraIDKerberos')[(Get-IDNWizardMenuChoice -Min 1 -Max 4 -Default 3) - 1]

    # -- STEP 3: Resources ------------------------------------------------------------
    $subId = $config.Azure.SubscriptionId
    if ($subId -and $script:ArmToken) {
        $needVnet = $config.IdentityModel -in @('ADDS', 'EntraDS')
        Write-IDNWizardHeader -Title 'STEP 3 of 4  -  RESOURCES  (virtual network)'
        Write-Host $(if ($needVnet) { '  The virtual network the machines use: DNS must reach the domain.' } else { '  The virtual network the machines use (optional for this model).' }) -ForegroundColor Gray
        Write-Host ''
        try {
            $vnets = @(Invoke-IDNArmRequest -Path "/subscriptions/$subId/providers/Microsoft.Network/virtualNetworks?api-version=2023-09-01" -All | Sort-Object name)
            $pick = Select-IDNFromList -Items $vnets -Label { param($v) "{0}  ({1}, {2})" -f $v.name, $v.location, (Get-IDNResourceGroupScope -ResourceId $v.id).Split('/')[-1] } -SkipLabel 'Skip  -  do not check a virtual network' -Kind 'virtual networks' -SkippedChecks 'The DNS and peering checks' -SubscriptionName $config.Azure.SubscriptionName
            if ($pick) { $config.VNetId = [string]$pick.id }
        } catch { Write-Host "  Could not list virtual networks: $($_.Exception.Message)" -ForegroundColor Yellow; $null = Read-Host '  Press ENTER to continue  ' }

        Write-IDNWizardHeader -Title 'STEP 3 of 4  -  RESOURCES  (Azure Files storage account)'
        Write-Host '  An Azure Files storage account whose users sign in with this model' -ForegroundColor Gray
        Write-Host '  (for example, FSLogix profiles). Skip it if you do not use Azure Files.' -ForegroundColor Gray
        Write-Host ''
        try {
            $accounts = @(Invoke-IDNArmRequest -Path "/subscriptions/$subId/providers/Microsoft.Storage/storageAccounts?api-version=2023-01-01" -All | Sort-Object name)
            $pick = Select-IDNFromList -Items $accounts -Label { param($s) "{0}  ({1}, {2})" -f $s.name, $s.location, $s.kind } -SkipLabel 'Skip  -  do not check storage' -Kind 'storage accounts' -SkippedChecks 'The Azure Files identity and share permission checks' -SubscriptionName $config.Azure.SubscriptionName
            if ($pick) { $config.StorageAccountId = [string]$pick.id }
        } catch { Write-Host "  Could not list storage accounts: $($_.Exception.Message)" -ForegroundColor Yellow; $null = Read-Host '  Press ENTER to continue  ' }
    }

    Write-IDNWizardHeader -Title 'STEP 4 of 4  -  TEST USER'
    Write-Host '  A user who will sign in. The check confirms their identity source fits the model.' -ForegroundColor Gray
    Write-Host ''
    $me = [string]$config.Azure.Account
    Write-Host "  [1] Me  ($me)" -ForegroundColor White
    Write-Host '  [2] Another user  (you will type the UPN)' -ForegroundColor White
    Write-Host '  [3] Skip' -ForegroundColor DarkGray
    Write-Host ''
    switch (Get-IDNWizardMenuChoice -Min 1 -Max 3 -Default 1) {
        1 { $config.TestUserUpn = $me }
        2 { $config.TestUserUpn = (Read-Host '  User principal name').Trim() }
    }

    if ($config.IdentityModel -eq 'ADDS') {
        Write-IDNWizardHeader -Title 'STEP 4 of 4  -  AD DS DOMAIN'
        $suggested = ''
        if ($config.TestUserUpn) {
            try {
                $u = Invoke-IDNGraphRequest -Uri ("v1.0/users/{0}?`$select=onPremisesDomainName" -f [uri]::EscapeDataString($config.TestUserUpn))
                $suggested = [string]$u.onPremisesDomainName
            } catch { Write-Verbose $_.Exception.Message }
        }
        Write-Host '  The AD DS domain, used to find domain controllers from this machine.' -ForegroundColor Gray
        Write-Host ''
        if ($suggested) {
            Write-Host "  [1] $suggested  (the test user's on-premises domain)" -ForegroundColor White
            Write-Host '  [2] Another domain  (you will type it)' -ForegroundColor White
            Write-Host '  [3] Skip' -ForegroundColor DarkGray
            Write-Host ''
            switch (Get-IDNWizardMenuChoice -Min 1 -Max 3 -Default 1) {
                1 { $config.DomainName = $suggested }
                2 { $config.DomainName = (Read-Host '  Domain FQDN').Trim() }
            }
        } else {
            Write-Host '  [1] Enter the domain  (you will type it)' -ForegroundColor White
            Write-Host '  [2] Skip' -ForegroundColor DarkGray
            Write-Host ''
            if ((Get-IDNWizardMenuChoice -Min 1 -Max 2 -Default 1) -eq 1) { $config.DomainName = (Read-Host '  Domain FQDN').Trim() }
        }
    }

    return [PSCustomObject]$config
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
    & $writeBannerLine 'Identity Provisioning  -  Prerequisites Assessment'
    & $writeBannerLine "Version 1.0.0  |  PowerShell $psVer  |  READ-ONLY  -  No changes made"
    Write-Host "+$bar+" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  MINIMUM ROLES   : Reader (subscription) + Global Reader (Entra ID)' -ForegroundColor Gray
    Write-Host '  OPERATIONS      : READ-ONLY. Azure Resource Manager and Microsoft Graph GET requests.' -ForegroundColor Gray
    Write-Host "  RUN AS          : $env:USERNAME on $env:COMPUTERNAME" -ForegroundColor Gray
    Write-Host "  TIMESTAMP       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
    Write-Host ''
    Write-Host "  Identity model  : $($script:ModelNames[$IdentityModel])" -ForegroundColor White
    if ($TenantId)         { Write-Host "  Tenant          : $TenantId" -ForegroundColor White }
    if ($SubscriptionId)   { Write-Host "  Subscription    : $SubscriptionId" -ForegroundColor White }
    if ($VNetId)           { Write-Host "  Virtual network : $(($VNetId -split '/')[-1])" -ForegroundColor White }
    if ($StorageAccountId) { Write-Host "  Storage account : $(($StorageAccountId -split '/')[-1])" -ForegroundColor White }
    if ($TestUserUpn)      { Write-Host "  Test user       : $TestUserUpn" -ForegroundColor White }
    if ($DomainName)       { Write-Host "  AD DS domain    : $DomainName" -ForegroundColor White }
    Write-Host ''
}

#endregion

#region -- Module List & Permissions ------------------------------------------

$RequiredModules = @(
    @{ Name = 'Az.Accounts';                    MinVersion = '2.12.0'; Required = $true }
    @{ Name = 'ImportExcel';                    MinVersion = '7.0.0'; Required = $true }
)

$RequiredGraphScopes = @(
    'Organization.Read.All',
    'Directory.Read.All',
    'User.Read.All',
    'Policy.Read.All',
    'Application.Read.All',
    'OnPremDirectorySynchronization.Read.All'
)

#endregion

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

$script:ProcessExitCode = 0
$summary = $null

try {
    # Report export is always enabled and always written to script root.
    $ExportReport = $true
    if (-not $PSBoundParameters.ContainsKey('ReportPath')) { $ReportPath = $script:ReportRootPath }

    $graphScopes = @($RequiredGraphScopes)
    if ($CheckSsoConfiguration) { $graphScopes += 'Application-RemoteDesktopConfig.ReadWrite.All' }

    $graphReady = $false
    if (-not $NonInteractive) {
        $wizCfg = Invoke-IDNSetupWizard -Scopes $graphScopes
        $AuthMethod       = $wizCfg.AuthMethod
        $TenantId         = $wizCfg.Azure.TenantId
        $SubscriptionId   = $wizCfg.Azure.SubscriptionId
        $IdentityModel    = $wizCfg.IdentityModel
        $VNetId           = $wizCfg.VNetId
        $StorageAccountId = $wizCfg.StorageAccountId
        $TestUserUpn      = $wizCfg.TestUserUpn
        $DomainName       = $wizCfg.DomainName
        $graphReady       = [bool]$wizCfg.GraphAuthenticated
    } else {
        if (-not $AuthMethod)    { throw 'No authentication method specified. Pass -AuthMethod (Interactive, DeviceCode, ServicePrincipalCertificate, or ManagedIdentity).' }
        if (-not $IdentityModel) { throw 'No identity model specified. Pass -IdentityModel (ADDS, EntraDS, EntraID, or EntraIDKerberos).' }
        if (-not $TenantId -and $AuthMethod -ne 'ManagedIdentity') { throw 'Pass -TenantId with -NonInteractive.' }
    }

    Show-Banner

    # -- STEP 1: PowerShell Environment -------------------------------------------
    Write-IDNSection -Title 'POWERSHELL ENVIRONMENT'
    Add-IDNCheckResult -Category 'Environment' -CheckName 'PowerShell Version' -Result 'PASS' `
        -Details "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

    if (-not $SkipModuleValidation) {
        Test-IDNModuleAvailability -Modules $RequiredModules
        try {
            Import-IDNRequiredModulesToMemory -Modules $RequiredModules
        } catch {
            Add-IDNCheckResult -Category 'Modules' -CheckName 'Required Module Import' -Result 'FAIL' `
                -Details $_.Exception.Message `
                -Roadblock 'Required modules could not be loaded into the current PowerShell session.' `
                -HowToFix 'Close this shell and rerun the script in a fresh PowerShell window.'
            throw
        }
    }

    # -- STEP 2: Azure sign-in (non-interactive runs; the wizard already did it) --
    if ($NonInteractive) {
        Write-IDNSection -Title 'AZURE AUTHENTICATION'
        try {
            $azure = Connect-IDNAzure -Method $AuthMethod -TenantId $TenantId -SubscriptionId $SubscriptionId `
                -ApplicationId $ApplicationId -CertificateThumbprint $CertificateThumbprint -NonInteractive
            $TenantId = $azure.TenantId
            Write-IDNLog -Level 'PASS' -Message "Azure: $($azure.Account) | Tenant $($azure.TenantId) | Subscription $(if ($azure.SubscriptionId) { $azure.SubscriptionName } else { 'none' })"
        } catch {
            Add-IDNCheckResult -Category 'Authentication' -CheckName 'Azure Login' -Result 'FAIL' -Details $_.Exception.Message `
                -Roadblock 'Azure resources (managed domain, VNet, storage, role assignments) cannot be read.' `
                -HowToFix 'Check the sign-in method and that the account can see the tenant and subscription.'
            throw 'Azure authentication failed. Aborting remaining checks.'
        }
        $graphReady = Connect-IDNGraphAccount -TenantId $TenantId
    }

    if (-not $graphReady) {
        Add-IDNCheckResult -Category 'Authentication' -CheckName 'Microsoft Graph Login' -Result 'FAIL' `
            -Details 'Authentication did not produce a Microsoft Graph session.' `
            -Roadblock 'Directory settings (sync, users, applications, Conditional Access) cannot be read.' `
            -HowToFix 'Rerun and complete the Graph sign-in for the selected tenant.'
        throw 'Microsoft Graph authentication failed. Aborting remaining checks.'
    }

    # -- STEP 3: Permissions ------------------------------------------------------
    Test-IDNGraphPermissions -RequiredScopes $graphScopes
    if (-not $script:ArmToken) {
        Add-IDNCheckResult -Category 'Authentication' -CheckName 'Azure Resource Checks' -Result 'SKIP' `
            -Details 'No subscription selected: managed domain, VNet, storage and Azure role checks will be skipped.'
    }

    if ($VNetId -and $script:ArmToken) {
        try { $script:SelectedVNet = Invoke-IDNArmRequest -Path "$($VNetId)?api-version=2023-09-01" }
        catch { Add-IDNArmFailure -Category 'Network' -CheckName 'Virtual Network' -ErrorRecord $_ }
    }

    # -- STEP 4: Directory synchronization ----------------------------------------
    Test-IDNDirectorySync -Model $IdentityModel

    # -- STEP 5/6: Identity model (only the selected one runs) --------------------
    # Entra DS runs before the test user check, because the user check compares
    # the password change date with the managed domain's creation date.
    switch ($IdentityModel) {
        'ADDS'            { Test-IDNTestUser -Model 'ADDS' -UserPrincipalName $TestUserUpn; Test-IDNModelADDS -DomainName $DomainName -StorageAccountId $StorageAccountId }
        'EntraDS'         { Test-IDNModelEntraDS -SubscriptionId $SubscriptionId -DomainName $DomainName -StorageAccountId $StorageAccountId; Test-IDNTestUser -Model 'EntraDS' -UserPrincipalName $TestUserUpn }
        'EntraID'         { Test-IDNTestUser -Model 'EntraID' -UserPrincipalName $TestUserUpn; Test-IDNModelEntraID -SubscriptionId $SubscriptionId -StorageAccountId $StorageAccountId }
        'EntraIDKerberos' { Test-IDNTestUser -Model 'EntraIDKerberos' -UserPrincipalName $TestUserUpn; Test-IDNModelEntraIDKerberos -SubscriptionId $SubscriptionId -StorageAccountId $StorageAccountId }
    }

    # -- STEP 7: Single sign-on for RDP (Entra models) ----------------------------
    if ($IdentityModel -in @('EntraID', 'EntraIDKerberos')) {
        Test-IDNSsoConfiguration -Enabled:$CheckSsoConfiguration
    }

    # ==========================================================================
    # RESULTS SUMMARY
    # ==========================================================================

    $summary = Get-IDNValidationSummary

    $bar = '=' * 78
    Write-Host ''
    Write-Host "+$bar+" -ForegroundColor White
    Write-Host "|  VALIDATION SUMMARY                                                          |" -ForegroundColor White
    Write-Host "+$bar+" -ForegroundColor White
    Write-Host ''
    Write-Host "  Identity model : $($script:ModelNames[$IdentityModel])" -ForegroundColor White
    Write-Host "  TotalChecks    : $($summary.TotalChecks)" -ForegroundColor White
    Write-Host "  PassCount      : $($summary.PassCount)"   -ForegroundColor Green
    Write-Host "  FailCount      : $($summary.FailCount)"   -ForegroundColor Red
    Write-Host "  WarnCount      : $($summary.WarnCount)"   -ForegroundColor Yellow
    Write-Host "  SkipCount      : $($summary.SkipCount)"   -ForegroundColor Blue
    Write-Host "  InfoCount      : $($summary.InfoCount)"   -ForegroundColor Blue
    Write-Host ''

    if ($summary.FailCount -eq 0 -and $summary.WarnCount -eq 0) {
        Write-Host '  VERDICT: [PASS] Identity prerequisites for this model appear READY.' -ForegroundColor Green
    } elseif ($summary.FailCount -eq 0) {
        Write-Host "  VERDICT: [WARN] No blockers found but $($summary.WarnCount) warning(s) detected." -ForegroundColor Yellow
        Write-Host '           Review warnings before deploying.' -ForegroundColor Yellow
    } else {
        $script:ProcessExitCode = 1
        Write-Host "  VERDICT: [FAIL] $($summary.FailCount) BLOCKER(S) for this identity model." -ForegroundColor Red
        Write-Host '           These MUST be resolved before users can sign in.' -ForegroundColor Red
    }
    Write-Host ''

    $fails = @($summary.Results | Where-Object { $_.Result -eq 'FAIL' })
    if ($fails.Count -gt 0) {
        Write-Host "  -- CRITICAL FAILURES ($($summary.FailCount)) --" -ForegroundColor Red
        foreach ($f in $fails) {
            Write-Host "  [$($f.Category)] $($f.CheckName)" -ForegroundColor Red
            Write-Host "    $($f.Details)" -ForegroundColor Gray
            if ($f.Roadblock) { Write-Host "    ROADBLOCK : $($f.Roadblock)" -ForegroundColor DarkRed }
            if ($f.HowToFix)  { Write-Host "    HOW TO FIX: $($f.HowToFix)" -ForegroundColor Yellow  }
            Write-Host ''
        }
    }

    if (-not $CriticalOnly) {
        $warns = @($summary.Results | Where-Object { $_.Result -eq 'WARN' })
        if ($warns.Count -gt 0) {
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
            $exportPaths = Export-IDNValidationReport -OutputPath $ReportPath
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
    Add-IDNCheckResult -Category 'Execution' -CheckName 'Identity Check Execution' -Result 'FAIL' `
        -Details $executionError `
        -Roadblock 'The assessment did not complete, so identity readiness is unknown.' `
        -HowToFix 'Resolve the reported authentication, module, or runtime error and run the assessment again.'
    Write-Host "  EXECUTION FAILED: $executionError" -ForegroundColor Red
}
finally {
    $script:ArmToken = $null
    $script:GraphToken = $null
    Disconnect-IDNAzure
    if (-not $NoExport -and -not $script:ReportExported -and $script:ValidationResults.Count -gt 0 -and (Get-Command -Name Export-Excel -ErrorAction SilentlyContinue)) {
        try {
            $fallbackExport = Export-IDNValidationReport -OutputPath $ReportPath
            $script:ReportExported = $true
            Write-Host "  Excel (fallback): $($fallbackExport.ExcelPath)" -ForegroundColor Cyan
        } catch {
            Write-Host "  WARNING: Fallback report export failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    Invoke-IDNModuleCleanup -PreflightResult $preflight_Result
}

$global:LASTEXITCODE = $script:ProcessExitCode

# Return structured results for callers without terminating their PowerShell process.
if ($PassThru) {
    if ($null -eq $summary) {
        $summary = Get-IDNValidationSummary
    }
    return $summary
}

if ($NonInteractive) {
    exit $script:ProcessExitCode
}
