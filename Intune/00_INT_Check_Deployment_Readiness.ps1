#Requires -Version 5.1

<#
.SYNOPSIS
    00_INT_Check_Deployment_Readiness.ps1 - Microsoft Intune deployment readiness check (standalone).
    Read-only. No tenant setting, policy, or device is created, modified, or deleted.
    All validation functions are self-contained - no external module file required.

.DESCRIPTION
    A self-contained PowerShell readiness assessment tool that validates the tenant
    prerequisites needed to enroll and manage devices with Microsoft Intune. The script
    is entirely read-only: it only issues GET requests to Microsoft Graph.

    HOW IT WORKS
    ------------
    When run interactively, a guided setup wizard walks the operator through every
    configuration choice (platforms, Windows Autopilot, authentication method) before
    the assessment starts. All settings can also be supplied directly as parameters to
    skip the wizard and run non-interactively (e.g. from a CI/CD pipeline).

    WHAT IT VALIDATES  (12 sequential check areas)
    -----------------------------------------------
        1  PowerShell environment (version, required modules)
        2  Microsoft Graph authentication and granted permissions
        3  Tenant and Intune service state (MDM authority, subscription state)
        4  Intune licensing (subscribed SKUs that carry an Intune service plan)
        5  Device registration and automatic enrollment (Entra join, MDM user scope)
        6  Enrollment configuration (device limit, platform restrictions, ESP)
        7  Compliance and configuration policies for the selected platforms
        8  Windows Autopilot (deployment profiles and registered devices)
        9  Apple and Android platform connectors (APNs, Managed Google Play)
        10 Conditional Access policies that require a compliant device
        11 Administrative roles (Intune Administrator coverage, signed-in account)
        12 Core Intune endpoint connectivity from this host

    RESULTS FORMAT
    --------------
    Every check produces one of: PASS / FAIL / WARN / INFO / SKIP.
    Every FAIL result includes:
        - WHY it is a deployment blocker (Roadblock)
        - HOW to fix it (exact steps or commands)
        - A link to the relevant Microsoft documentation

    REPORTS
    -------
    A timestamped Excel report is written to -ReportPath (default: the script folder),
    unless -NoExport is given. The workbook contains every check result with all
    Roadblock and HowToFix fields.

    AUTOMATION / PIPELINE USE
    -------------------------
    Use -PassThru to return a structured PSCustomObject that contains Results[],
    FailCount, WarnCount, and PassCount. Use -NonInteractive for unattended execution.
    Exit codes: 0 = no failures, 1 = one or more FAIL results, 2 = execution error.

    STANDALONE
    ----------
    This script has no external dependencies beyond Microsoft.Graph.Authentication and
    ImportExcel. Missing modules are staged in a temporary folder for this run only.

.PARAMETER Platform
    Platforms that will be enrolled: Windows, iOS, Android, macOS, or All.
    Platform-specific checks (APNs, Managed Google Play, policies) follow this choice.
    Default: Windows.

.PARAMETER IncludeAutopilot
    Validate Windows Autopilot deployment profiles and registered devices.

.PARAMETER TenantId
    Entra ID tenant ID or primary domain. Required for service principal sign-in.

.PARAMETER SkipConnectivityTests
    Skip the TCP tests to the core Intune endpoints. Run
    02_INT_Validate_Network_Configuration.ps1 for the complete endpoint assessment.

.PARAMETER NonInteractive
    Skip the setup wizard and all prompts.

.PARAMETER AuthMethod
    Interactive, DeviceCode, ServicePrincipalSecret, ServicePrincipalCertificate,
    ManagedIdentity, or ExistingContext. There is no default: the wizard asks on
    every run, and -NonInteractive requires this parameter. Every method except
    ExistingContext clears any cached Graph session and signs in fresh.
    ExistingContext reuses a session from Connect-MgGraph only when named
    explicitly, and in an interactive run shows the account and asks first.

.PARAMETER ApplicationId
    Application (client) ID for ServicePrincipalCertificate.

.PARAMETER CertificateThumbprint
    Certificate thumbprint for ServicePrincipalCertificate.

.PARAMETER ServicePrincipalCredential
    PSCredential (client ID as user name, secret as password) for ServicePrincipalSecret.

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
    .\00_INT_Check_Deployment_Readiness.ps1
    Runs the guided wizard.

.EXAMPLE
    .\00_INT_Check_Deployment_Readiness.ps1 -NonInteractive -AuthMethod Interactive -Platform Windows,iOS -IncludeAutopilot
    Signs in through the browser and validates Windows (with Autopilot) and iOS readiness.

.NOTES
    Author: etf
    Minimum role: Global Reader, or Intune Administrator plus Security Reader.
    Graph permissions (delegated or application), all read-only:
        DeviceManagementConfiguration.Read.All, DeviceManagementServiceConfig.Read.All,
        DeviceManagementManagedDevices.Read.All, DeviceManagementRBAC.Read.All,
        Organization.Read.All, Policy.Read.All, Directory.Read.All,
        RoleManagement.Read.Directory
#>

[CmdletBinding(SupportsShouldProcess=$false)]
param(
    # Windows, iOS, Android, macOS or All. Validated after parsing, because a
    # relaunched child process receives the list as one comma-separated string.
    [string[]]$Platform = @('Windows'),

    [switch]$IncludeAutopilot,

    [string]$TenantId,

    [switch]$SkipConnectivityTests,

    [switch]$NonInteractive,

    # No default on purpose: a cached session is never used unless asked for.
    [ValidateSet('ExistingContext','Interactive','DeviceCode','ServicePrincipalSecret','ServicePrincipalCertificate','ManagedIdentity')]
    [string]$AuthMethod,

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
# INT Module Preflight - Session-scoped ephemeral module loading
# ======================================================================
# Embedded so this script can be distributed as a single file.
# Missing modules are saved under $env:TEMP, imported for this run, then removed.
$env:PSModulePath = (($env:PSModulePath -split [IO.Path]::PathSeparator) |
    Where-Object { $_ -and $_ -notmatch '(?:^|[\\/])_modules(?:[\\/]|$)' }) -join [IO.Path]::PathSeparator
$script:INTTempPath = $null
$script:INTTempModuleNames = [System.Collections.Generic.List[string]]::new()
$script:INTImportedModuleNames = [System.Collections.Generic.List[string]]::new()

function Get-INTModuleTempPath {
    if (-not $script:INTTempPath) {
        $script:INTTempPath = Join-Path $env:TEMP ("INT_TempMod_{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:INTTempPath -Force -ErrorAction Stop | Out-Null
    }
    return $script:INTTempPath
}

function Resolve-INTBestLocalModule {
    param(
        [Parameter(Mandatory=$true)] [string]$Name,
        [version]$MinimumVersion = [version]'0.0'
    )

    return Get-Module -Name $Name -ListAvailable -ErrorAction SilentlyContinue |
        Where-Object { $_.ModuleBase -notmatch '(?:^|[\\/])_modules(?:[\\/]|$)' -and $_.Version -ge $MinimumVersion } |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

function Invoke-INTModulePreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable[]]$Modules
    )

    $script:INTTempPath = $null
    $script:INTTempModuleNames = [System.Collections.Generic.List[string]]::new()
    $script:INTImportedModuleNames = [System.Collections.Generic.List[string]]::new()

    Write-Host ''
    Write-Host ('=' * 100) -ForegroundColor White
    Write-Host 'Validating PowerShell modules installation' -ForegroundColor White
    Write-Host ('=' * 100) -ForegroundColor White
    Write-Host ''

    # Modules staged by an earlier run stay loaded until its window closes, so that run
    # cannot delete them. Remove those folders now. A rename fails while another window
    # still has the modules loaded, so only folders that can be renamed are deleted.
    Get-ChildItem -Path $env:TEMP -Directory -Filter 'INT_TempMod_*' -ErrorAction SilentlyContinue | ForEach-Object {
        $staleName = Join-Path $env:TEMP ('INT_Stale_{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        try { Rename-Item -LiteralPath $_.FullName -NewName (Split-Path $staleName -Leaf) -ErrorAction Stop } catch { return }
        Remove-Item -LiteralPath $staleName -Recurse -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem -Path $env:TEMP -Directory -Filter 'INT_Stale_*' -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

    $originalPSModulePath = $env:PSModulePath
    $needFetch = [System.Collections.Generic.List[string]]::new()

    foreach ($moduleRequirement in $Modules) {
        $moduleName = [string]$moduleRequirement.Name
        $minimumVersion = if ($moduleRequirement.MinVersion) { [version]$moduleRequirement.MinVersion } else { [version]'0.0' }
        $foundModule = Resolve-INTBestLocalModule -Name $moduleName -MinimumVersion $minimumVersion

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
        $tempPath = Get-INTModuleTempPath
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

                [void]$script:INTTempModuleNames.Add($moduleName)
                Write-Host ("Module Check - Pass: Fetched to temporary storage: {0} (Version: {1})" -f $moduleName, $manifest.Directory.Name) -ForegroundColor Green
            } catch {
                throw ("Module Fetch - Fail [{0}]: {1}" -f $moduleName, $_.Exception.Message)
            }
        }
    }

    if ($script:INTTempPath) {
        $env:PSModulePath = @($script:INTTempPath, $originalPSModulePath) -join [IO.Path]::PathSeparator
    }

    return [PSCustomObject]@{
        Success = $true
        TempPath = $script:INTTempPath
        OriginalPSModulePath = $originalPSModulePath
        TempModuleNames = $script:INTTempModuleNames.ToArray()
        ImportedModuleNames = $script:INTImportedModuleNames.ToArray()
    }
}

function Invoke-INTModuleCleanup {
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
    @{ Name = 'Microsoft.Graph.Authentication'; MinVersion = '2.0.0'; Required = $true }
    @{ Name = 'ImportExcel'; MinVersion = '7.0.0'; Required = $true }
)

$preflight_Result = $null
if (-not $SkipModuleValidation) {
    $preflight_Result = Invoke-INTModulePreflight -Modules $preflight_Modules
}

trap {
    Invoke-INTModuleCleanup -PreflightResult $preflight_Result
    throw $_
}
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Invoke-INTModuleCleanup -PreflightResult $preflight_Result
} -ErrorAction SilentlyContinue

# Always export reports to the script root using the script file name.
$script:ReportRootPath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:ReportScriptName = $env:INT_REPORT_SCRIPT_NAME
if ([string]::IsNullOrWhiteSpace($script:ReportScriptName)) {
    $script:ReportScriptName = if ($PSCommandPath) { [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath) } else { [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name) }
}
$script:ReportExported = $false
$script:RecoveredByChildProcess = $false
$script:TenantObjectId = $null

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

function Write-INTLog {
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

function Write-INTSection {
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

function Add-INTCheckResult {
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
    Write-INTLog -Level $logLevel -Message "[$Category] $CheckName"
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

function Get-INTValidationSummary {
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

function Export-INTValidationReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$OutputPath
    )

    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $excelPath = Join-Path $OutputPath ("$($script:ReportScriptName)_$ts.xlsx")

    $script:ValidationResults.ToArray() |
        Export-Excel -Path $excelPath -WorksheetName 'Validation Results' -AutoSize -FreezeTopRow -BoldTopRow

    return [PSCustomObject]@{ ExcelPath = $excelPath }
}

#endregion

#region -- Module Management ---------------------------------------------------

function Test-INTModuleAvailability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable[]]$Modules
    )

    Write-INTSection -Title 'POWERSHELL MODULE AVAILABILITY'

    foreach ($mod in $Modules) {
        $name       = $mod.Name
        $minVer     = if ($mod.MinVersion) { $mod.MinVersion } else { '0.0.0' }
        $isRequired = if ($null -ne $mod.Required) { [bool]$mod.Required } else { $true }

        try {
            $installed = Get-Module -Name $name -ErrorAction SilentlyContinue |
                         Sort-Object Version -Descending | Select-Object -First 1
            if ($null -eq $installed) {
                $installed = Resolve-INTBestLocalModule -Name $name
            }

            if ($null -eq $installed) {
                if ($isRequired) {
                    Add-INTCheckResult `
                        -Category 'Modules' `
                        -CheckName "Module: $name" `
                        -Result 'FAIL' `
                        -Details 'Not installed' `
                        -Roadblock "The module '$name' is required to query Microsoft Graph or write the report." `
                        -HowToFix "Rerun with network access so '$name' can be staged temporarily." `
                        -DocLink 'https://learn.microsoft.com/powershell/microsoftgraph/installation'
                } else {
                    Add-INTCheckResult `
                        -Category 'Modules' `
                        -CheckName "Module: $name (optional)" `
                        -Result 'WARN' `
                        -Details 'Not installed  -  checks requiring this module will be skipped' `
                        -HowToFix "Rerun with network access so '$name' can be staged temporarily."
                }
            } elseif ([System.Version]$installed.Version -lt [System.Version]$minVer) {
                Add-INTCheckResult `
                    -Category 'Modules' `
                    -CheckName "Module: $name" `
                    -Result 'WARN' `
                    -Details "Version $($installed.Version) installed; $minVer+ recommended" `
                    -HowToFix "Update-Module -Name '$name' -Force"
            } else {
                Add-INTCheckResult `
                    -Category 'Modules' `
                    -CheckName "Module: $name" `
                    -Result 'PASS' `
                    -Details "Version $($installed.Version) installed"
            }
        } catch {
            Add-INTCheckResult `
                -Category 'Modules' `
                -CheckName "Module: $name" `
                -Result 'WARN' `
                -Details "Error checking module: $($_.Exception.Message)"
        }
    }
}

function Import-INTRequiredModulesToMemory {
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

        $installed = Resolve-INTBestLocalModule -Name $name
        if ($null -eq $installed) {
            throw "Required module '$name' was validated but could not be resolved for import."
        }

        try {
            Import-Module -Name $installed.Path -Global -ErrorAction Stop -WarningAction SilentlyContinue
            [void]$script:INTImportedModuleNames.Add($name)
            if ($preflight_Result) { $preflight_Result.ImportedModuleNames = $script:INTImportedModuleNames.ToArray() }
        } catch {
            $importErr = $_
            if (Get-Module -Name $name -ErrorAction SilentlyContinue) {
                [void]$script:INTImportedModuleNames.Add($name)
                continue
            }
            if ($importErr.Exception.Message -match 'Assembly with same name is already loaded|Could not load file or assembly|Azure\.Identity|Microsoft\.Identity\.Client|multiple incompatible versions') {
                throw "INT_MODULE_CONFLICT: Failed to import required module '$name': assemblies from a prior script in this terminal are stuck in the process. Open a fresh PowerShell terminal and run again."
            }
            throw "Failed to import required module '$name': $($importErr.Exception.Message)"
        }
    }
}

function Invoke-INTFreshProcessRecovery {
    [CmdletBinding()]
    param(
        [string[]]$Platform,
        [switch]$IncludeAutopilot,
        [string]$TenantId,
        [string]$AuthMethod,
        [string]$ApplicationId,
        [string]$CertificateThumbprint,
        [string]$ReportPath,
        [switch]$CriticalOnly,
        [switch]$SkipConnectivityTests
    )

    # Avoid infinite relaunch loops.
    if ($env:INT00_FRESH_PROCESS_RETRY -eq '1') {
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

    # Same engine as this session (pwsh -> pwsh, powershell -> powershell), resolved
    # from $PSHOME: in PowerShell ISE this process is powershell_ise.exe.
    $pwshExe = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
    if ([string]::IsNullOrWhiteSpace($pwshExe) -or -not (Test-Path -Path $pwshExe)) {
        $pwshExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell.exe' }
    }

    # ExistingContext cannot cross a process boundary; the child signs in interactively.
    $childAuthMethod = if ([string]::IsNullOrWhiteSpace($AuthMethod) -or $AuthMethod -eq 'ExistingContext') { 'Interactive' } else { $AuthMethod }

    $argList = [System.Collections.Generic.List[string]]::new()
    foreach ($arg in @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-NonInteractive')) { [void]$argList.Add($arg) }
    if ($Platform) { [void]$argList.Add('-Platform'); [void]$argList.Add(($Platform -join ',')) }
    if ($IncludeAutopilot) { [void]$argList.Add('-IncludeAutopilot') }
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) { [void]$argList.Add('-TenantId'); [void]$argList.Add($TenantId) }
    [void]$argList.Add('-AuthMethod'); [void]$argList.Add($childAuthMethod)
    if (-not [string]::IsNullOrWhiteSpace($ApplicationId)) { [void]$argList.Add('-ApplicationId'); [void]$argList.Add($ApplicationId) }
    if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) { [void]$argList.Add('-CertificateThumbprint'); [void]$argList.Add($CertificateThumbprint) }
    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) { [void]$argList.Add('-ReportPath'); [void]$argList.Add($ReportPath) }
    if ($CriticalOnly) { [void]$argList.Add('-CriticalOnly') }
    if ($SkipConnectivityTests) { [void]$argList.Add('-SkipConnectivityTests') }

    $previousRetryFlag = $env:INT00_FRESH_PROCESS_RETRY
    $env:INT00_FRESH_PROCESS_RETRY = '1'
    try {
        Write-Host ''
        Write-Host '[ INFO ] Recovering from in-process assembly collision...' -ForegroundColor Yellow
        Write-Host "[ INFO ] Relaunching in clean child process: $pwshExe" -ForegroundColor Yellow
        $child = Start-Process -FilePath $pwshExe -ArgumentList $argList.ToArray() -Wait -PassThru -NoNewWindow
        $script:FreshProcessExitCode = $child.ExitCode
        return ($child.ExitCode -in @(0, 1))
    } catch {
        return $false
    } finally {
        if ($null -eq $previousRetryFlag) {
            Remove-Item Env:INT00_FRESH_PROCESS_RETRY -ErrorAction SilentlyContinue
        } else {
            $env:INT00_FRESH_PROCESS_RETRY = $previousRetryFlag
        }
    }
}

#endregion

#region -- Microsoft Graph Helpers ---------------------------------------------

function Invoke-INTGraphRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Uri,
        [switch]$All,
        [hashtable]$Headers
    )

    $requestParams = @{ Method = 'GET'; Uri = $Uri; OutputType = 'PSObject'; ErrorAction = 'Stop' }
    if ($Headers) { $requestParams['Headers'] = $Headers }

    $response = Invoke-MgGraphRequest @requestParams
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
        $response = Invoke-MgGraphRequest @requestParams
    }
    # Unrolled on purpose: callers wrap the call in @(...), and a comma-wrapped
    # return would nest the whole list inside a single element.
    return $items.ToArray()
}

function Get-INTGraphStatusCode {
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

function Add-INTGraphFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Category,
        [Parameter(Mandatory=$true)] [string]$CheckName,
        [Parameter(Mandatory=$true)] [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory=$true)] [string]$Permission,
        [string]$DocLink = ''
    )

    $status = Get-INTGraphStatusCode -ErrorRecord $ErrorRecord
    if ($status -eq 403 -or $status -eq 401) {
        Add-INTCheckResult `
            -Category $Category `
            -CheckName $CheckName `
            -Result 'WARN' `
            -Details "Access denied by Microsoft Graph (HTTP $status). This check could not run." `
            -HowToFix "Grant the read-only permission '$Permission' (admin consent) or sign in with a Global Reader or Intune Administrator account, then rerun." `
            -DocLink $DocLink
    } else {
        Add-INTCheckResult `
            -Category $Category `
            -CheckName $CheckName `
            -Result 'WARN' `
            -Details "Could not query Microsoft Graph: $($ErrorRecord.Exception.Message)" `
            -HowToFix 'Rerun the check. If it persists, confirm the tenant has an Intune subscription and that Graph is reachable from this host.' `
            -DocLink $DocLink
    }
}

function Get-INTPropertyValue {
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

#region -- Authentication Helpers ----------------------------------------------

function Select-INTAuthenticationMethod {
    [CmdletBinding()]
    param()

    Write-INTSection -Title 'AUTHENTICATION METHOD SELECTION'
    Write-Host "For security, you must select an authentication method for each execution." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1. Interactive Browser Login (Default)" -ForegroundColor White
    Write-Host "      - Opens browser for authentication" -ForegroundColor Gray
    Write-Host "      - Best for most users" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  2. Device Code Authentication" -ForegroundColor White
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
    Write-Host "      - For Azure VMs or automation with managed identity enabled" -ForegroundColor Gray
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
    Write-INTLog -Level 'PASS' -Message "Selected authentication method: $selectedMethod"
    return $selectedMethod
}

function Connect-INTGraphAccount {
    [CmdletBinding()]
    param(
        [string]$TenantId,
        [switch]$NonInteractive,
        [string]$RequestedAuthMethod,
        [string]$ApplicationId,
        [string]$CertificateThumbprint,
        [System.Management.Automation.PSCredential]$ServicePrincipalCredential,
        [Parameter(Mandatory=$true)] [string[]]$Scopes,
        # Set when the wizard signed in during this run; that session is not a cached one.
        [switch]$WizardSession
    )

    Write-INTSection -Title 'MICROSOFT GRAPH AUTHENTICATION'

    try {
        if ($WizardSession) {
            $wizardCtx = Get-MgContext -ErrorAction SilentlyContinue
            if ($null -ne $wizardCtx) {
                Write-INTLog -Level 'PASS' -Message "Authenticated in the wizard: $($wizardCtx.Account) (via $($wizardCtx.AppName))"
                Write-INTLog -Level 'INFO' -Message "Tenant: $($wizardCtx.TenantId) | Auth type: $($wizardCtx.AuthType)"
                return $true
            }
        }

        if ([string]::IsNullOrWhiteSpace($RequestedAuthMethod)) {
            if ($NonInteractive) {
                throw 'No authentication method specified. Pass -AuthMethod (Interactive, DeviceCode, ServicePrincipalSecret, ServicePrincipalCertificate, ManagedIdentity, or ExistingContext).'
            }
            $RequestedAuthMethod = Select-INTAuthenticationMethod
        }

        # A cached session is used only when explicitly requested, and an
        # operator at the console confirms the account before it is used.
        if ($RequestedAuthMethod -eq 'ExistingContext') {
            $existingCtx = Get-MgContext -ErrorAction SilentlyContinue
            if ($null -eq $existingCtx) {
                if ($NonInteractive) {
                    throw '-AuthMethod ExistingContext was requested but no Microsoft Graph session exists. Run Connect-MgGraph first or choose another method.'
                }
                Write-INTLog -Level 'WARN' -Message 'No existing Microsoft Graph session. Choose how to sign in.'
                $RequestedAuthMethod = Select-INTAuthenticationMethod
            } elseif ($TenantId -and $existingCtx.TenantId -ne $TenantId) {
                throw "The existing Graph session is for tenant $($existingCtx.TenantId), not $TenantId. Choose another method to sign in to $TenantId."
            } else {
                $who = if ($existingCtx.Account) { "$($existingCtx.Account) (via $($existingCtx.AppName))" } else { "app $($existingCtx.AppName) ($($existingCtx.ClientId))" }
                Write-INTLog -Level 'INFO' -Message "Existing Microsoft Graph session: $who | Tenant: $($existingCtx.TenantId) | Auth type: $($existingCtx.AuthType)"
                $useIt = $NonInteractive
                if (-not $NonInteractive) {
                    $answer = Read-Host "  Use this session for the assessment? (y/N)"
                    $useIt = $answer -match '^[yY]'
                }
                if ($useIt) {
                    Write-INTLog -Level 'PASS' -Message "Authenticated (existing session, confirmed): $who"
                    return $true
                }
                $RequestedAuthMethod = Select-INTAuthenticationMethod
            }
        }

        Write-INTLog -Level 'INFO' -Message 'Clearing any cached Graph session to ensure fresh authentication...'
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null

        # ContextScope Process: the token lives in memory for this run only. The
        # default (CurrentUser) caches it on disk, and the next run signs in silently.
        $connectParams = @{ ErrorAction = 'Stop'; NoWelcome = $true; ContextScope = 'Process' }
        if ($TenantId) { $connectParams['TenantId'] = $TenantId }

        switch ($RequestedAuthMethod) {
            'Interactive' {
                Write-INTLog -Level 'INFO' -Message 'Opening interactive browser login...'
                Connect-MgGraph @connectParams -Scopes $Scopes | Out-Null
            }
            'DeviceCode' {
                Write-INTLog -Level 'INFO' -Message 'Device code authentication - visit https://microsoft.com/devicelogin'
                Connect-MgGraph @connectParams -Scopes $Scopes -UseDeviceCode | Out-Null
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
                if (-not $TenantId) { $connectParams['TenantId'] = Read-Host 'Tenant ID' }
                Connect-MgGraph @connectParams -ClientSecretCredential $ServicePrincipalCredential | Out-Null
            }
            'ServicePrincipalCertificate' {
                if ($NonInteractive -and (-not $ApplicationId -or -not $CertificateThumbprint -or -not $TenantId)) {
                    throw 'ServicePrincipalCertificate requires -ApplicationId, -CertificateThumbprint, and -TenantId in non-interactive mode.'
                }
                if (-not $ApplicationId) { $ApplicationId = Read-Host 'Application (Client) ID' }
                if (-not $CertificateThumbprint) { $CertificateThumbprint = Read-Host 'Certificate Thumbprint' }
                if (-not $TenantId) { $connectParams['TenantId'] = Read-Host 'Tenant ID' }
                Connect-MgGraph @connectParams -ClientId $ApplicationId -CertificateThumbprint $CertificateThumbprint | Out-Null
            }
            'ManagedIdentity' {
                Write-INTLog -Level 'INFO' -Message 'Authenticating with Managed Identity...'
                $connectParams.Remove('TenantId')
                Connect-MgGraph @connectParams -Identity | Out-Null
            }
        }

        $ctx = Get-MgContext -ErrorAction Stop
        if ($null -ne $ctx) {
            $who = if ($ctx.Account) { "$($ctx.Account) (via $($ctx.AppName))" } else { "app $($ctx.AppName) ($($ctx.ClientId))" }
            Write-INTLog -Level 'PASS' -Message "Authenticated: $who"
            Write-INTLog -Level 'INFO' -Message "Tenant: $($ctx.TenantId) | Auth type: $($ctx.AuthType)"
            return $true
        }
        return $false
    } catch {
        Write-INTLog -Level 'FAIL' -Message "Authentication failed: $($_.Exception.Message)"
        return $false
    }
}

function Test-INTGraphPermissions {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)] [string[]]$RequiredScopes)

    Write-INTSection -Title 'GRAPH PERMISSIONS (READ-ONLY)'

    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    $granted = @()
    if ($null -ne $ctx -and $null -ne $ctx.Scopes) { $granted = @($ctx.Scopes) }

    Add-INTCheckResult `
        -Category 'Authentication' `
        -CheckName 'Graph Context' `
        -Result 'INFO' `
        -Details "Auth type: $($ctx.AuthType) | Tenant: $($ctx.TenantId) | $($granted.Count) permission(s) in the token"

    # Directory.Read.All and the *.ReadWrite.All variants also satisfy a narrower read scope.
    foreach ($scope in $RequiredScopes) {
        $writeVariant = $scope -replace '\.Read\.', '.ReadWrite.'
        $isGranted = ($granted -contains $scope) -or ($granted -contains $writeVariant)
        if ($isGranted) {
            Add-INTCheckResult `
                -Category 'Authentication' `
                -CheckName "Permission: $scope" `
                -Result 'PASS' `
                -Details 'Granted'
        } else {
            Add-INTCheckResult `
                -Category 'Authentication' `
                -CheckName "Permission: $scope" `
                -Result 'WARN' `
                -Details 'Not present in the token. Checks that need it will report access denied.' `
                -HowToFix "Sign in with -AuthMethod Interactive (the script requests every scope), or grant '$scope' with admin consent to the app registration used for sign-in." `
                -DocLink 'https://learn.microsoft.com/graph/permissions-reference'
        }
    }
}

#endregion

#region -- Tenant & Intune Service ---------------------------------------------

function Test-INTTenantReadiness {
    [CmdletBinding()]
    param()

    Write-INTSection -Title 'TENANT & INTUNE SERVICE STATE'

    try {
        $org = @(Invoke-INTGraphRequest -Uri 'v1.0/organization?$select=id,displayName,verifiedDomains,countryLetterCode' -All) | Select-Object -First 1
        $defaultDomain = @($org.verifiedDomains | Where-Object { $_.isDefault }) | Select-Object -First 1
        Add-INTCheckResult `
            -Category 'Tenant' `
            -CheckName 'Tenant Identity' `
            -Result 'PASS' `
            -Details "Name: '$($org.displayName)' | ID: $($org.id) | Default domain: $($defaultDomain.name) | Country: $($org.countryLetterCode)"
        $script:TenantObjectId = $org.id
    } catch {
        Add-INTGraphFailure -Category 'Tenant' -CheckName 'Tenant Identity' -ErrorRecord $_ -Permission 'Organization.Read.All'
    }

    # MDM authority: must be Intune. 'unknown' means it was never set.
    try {
        if ($script:TenantObjectId) {
            $orgBeta = Invoke-INTGraphRequest -Uri "beta/organization/$($script:TenantObjectId)?`$select=mobileDeviceManagementAuthority"
            $authority = [string](Get-INTPropertyValue -InputObject $orgBeta -Name 'mobileDeviceManagementAuthority')
            switch -Regex ($authority) {
                '^intune$' {
                    Add-INTCheckResult `
                        -Category 'Tenant' `
                        -CheckName 'MDM Authority' `
                        -Result 'PASS' `
                        -Details 'MDM authority is set to Intune'
                }
                '^(sccm|configurationManager)$' {
                    Add-INTCheckResult `
                        -Category 'Tenant' `
                        -CheckName 'MDM Authority' `
                        -Result 'WARN' `
                        -Details "MDM authority is '$authority' (hybrid MDM, retired by Microsoft)" `
                        -HowToFix 'Move to Intune standalone; hybrid MDM with Configuration Manager is no longer supported. Use co-management instead.' `
                        -DocLink 'https://learn.microsoft.com/mem/intune/fundamentals/mdm-authority-set'
                }
                '^office365$' {
                    Add-INTCheckResult `
                        -Category 'Tenant' `
                        -CheckName 'MDM Authority' `
                        -Result 'FAIL' `
                        -Details 'MDM authority is Basic Mobility and Security (Office 365)' `
                        -Roadblock 'Basic Mobility and Security cannot run Intune policies or apps. Devices enroll into the wrong service.' `
                        -HowToFix 'Intune admin center > Tenant administration > Tenant status, then switch the MDM authority to Intune. Existing Basic Mobility devices must re-enroll.' `
                        -DocLink 'https://learn.microsoft.com/mem/intune/fundamentals/mdm-authority-set'
                }
                default {
                    Add-INTCheckResult `
                        -Category 'Tenant' `
                        -CheckName 'MDM Authority' `
                        -Result 'FAIL' `
                        -Details "MDM authority is '$authority' (not set)" `
                        -Roadblock 'No device can enroll until the MDM authority is Intune.' `
                        -HowToFix 'Sign in to https://intune.microsoft.com once with an Intune Administrator account; the authority is set to Intune automatically. Otherwise use Tenant administration > Tenant status.' `
                        -DocLink 'https://learn.microsoft.com/mem/intune/fundamentals/mdm-authority-set'
                }
            }
        }
    } catch {
        Add-INTGraphFailure -Category 'Tenant' -CheckName 'MDM Authority' -ErrorRecord $_ -Permission 'Organization.Read.All' -DocLink 'https://learn.microsoft.com/mem/intune/fundamentals/mdm-authority-set'
    }

    try {
        $deviceManagement = Invoke-INTGraphRequest -Uri 'v1.0/deviceManagement?$select=subscriptionState,intuneAccountId,settings'
        $state = [string](Get-INTPropertyValue -InputObject $deviceManagement -Name 'subscriptionState')
        if ($state -eq 'active') {
            Add-INTCheckResult `
                -Category 'Tenant' `
                -CheckName 'Intune Subscription State' `
                -Result 'PASS' `
                -Details "Active | Intune account ID: $($deviceManagement.intuneAccountId)"
        } elseif ($state -eq 'warning') {
            Add-INTCheckResult `
                -Category 'Tenant' `
                -CheckName 'Intune Subscription State' `
                -Result 'WARN' `
                -Details 'Intune subscription is in a warning state (expiring or past due)' `
                -HowToFix 'Review the subscription in the Microsoft 365 admin center > Billing > Your products, and renew it before it is disabled.'
        } elseif ($state -notin @('disabled', 'deleted', 'blocked', 'lockedOut')) {
            # Graph reports 'pending' on tenants that are demonstrably running Intune,
            # so only the states that actually stop the service count as blockers.
            Add-INTCheckResult `
                -Category 'Tenant' `
                -CheckName 'Intune Subscription State' `
                -Result 'WARN' `
                -Details "Graph reports subscription state '$state'. The licensing, MDM authority and connector checks show whether the service is actually in use." `
                -HowToFix 'Confirm in Intune admin center > Tenant administration > Tenant status that the service is active and no service-health incident is listed.' `
                -DocLink 'https://learn.microsoft.com/mem/intune/fundamentals/tenant-status'
        } else {
            Add-INTCheckResult `
                -Category 'Tenant' `
                -CheckName 'Intune Subscription State' `
                -Result 'FAIL' `
                -Details "Intune subscription state: '$state'" `
                -Roadblock 'Enrollment and policy delivery stop while the Intune subscription is not active.' `
                -HowToFix 'Purchase or renew a plan that includes Microsoft Intune, then confirm in Intune admin center > Tenant administration > Tenant status.' `
                -DocLink 'https://learn.microsoft.com/mem/intune/fundamentals/licenses'
        }

        $settings = Get-INTPropertyValue -InputObject $deviceManagement -Name 'settings'
        if ($null -ne $settings) {
            $secureByDefault = [bool](Get-INTPropertyValue -InputObject $settings -Name 'secureByDefault')
            $validityDays = Get-INTPropertyValue -InputObject $settings -Name 'deviceComplianceCheckinThresholdDays'
            if ($secureByDefault) {
                Add-INTCheckResult `
                    -Category 'Tenant' `
                    -CheckName 'Devices Without a Compliance Policy' `
                    -Result 'PASS' `
                    -Details "Marked as not compliant | Compliance status validity: $validityDays day(s)"
            } else {
                Add-INTCheckResult `
                    -Category 'Tenant' `
                    -CheckName 'Devices Without a Compliance Policy' `
                    -Result 'WARN' `
                    -Details "Marked as compliant (tenant default) | Compliance status validity: $validityDays day(s)" `
                    -HowToFix 'Intune admin center > Devices > Compliance > Compliance settings: set "Mark devices with no compliance policy assigned as" to Not compliant, so Conditional Access cannot be satisfied by an unmanaged policy gap.' `
                    -DocLink 'https://learn.microsoft.com/mem/intune/protect/device-compliance-get-started#compliance-policy-settings'
            }
        }
    } catch {
        Add-INTGraphFailure -Category 'Tenant' -CheckName 'Intune Subscription State' -ErrorRecord $_ -Permission 'DeviceManagementServiceConfig.Read.All'
    }
}

#endregion

#region -- Licensing -----------------------------------------------------------

# Core Intune service plans (full device management). INTUNE_O365 is Basic
# Mobility and Security and does not count as an Intune license.
$script:IntuneCoreServicePlans = @('INTUNE_A', 'INTUNE_A_VL', 'INTUNE_EDU', 'INTUNE_SMBIZ', 'INTUNE_A_D')

function Test-INTLicensing {
    [CmdletBinding()]
    param()

    Write-INTSection -Title 'INTUNE LICENSING'

    try {
        $skus = @(Invoke-INTGraphRequest -Uri 'v1.0/subscribedSkus' -All)
        $intuneSkus = @($skus | Where-Object {
            @($_.servicePlans | Where-Object { $_.servicePlanName -in $script:IntuneCoreServicePlans }).Count -gt 0
        })
        $addOnSkus = @($skus | Where-Object {
            @($_.servicePlans | Where-Object { $_.servicePlanName -like 'INTUNE*' -and $_.servicePlanName -notin $script:IntuneCoreServicePlans -and $_.servicePlanName -ne 'INTUNE_O365' }).Count -gt 0
        } | Where-Object { $_ -notin $intuneSkus })

        if ($intuneSkus.Count -eq 0) {
            $basicOnly = @($skus | Where-Object { @($_.servicePlans | Where-Object { $_.servicePlanName -eq 'INTUNE_O365' }).Count -gt 0 }).Count -gt 0
            $detail = if ($basicOnly) { 'Only Basic Mobility and Security (INTUNE_O365) was found. No SKU includes full Microsoft Intune.' } else { 'No subscribed SKU includes a Microsoft Intune service plan.' }
            Add-INTCheckResult `
                -Category 'Licensing' `
                -CheckName 'Intune License Present' `
                -Result 'FAIL' `
                -Details $detail `
                -Roadblock 'Users without an Intune license cannot enroll devices.' `
                -HowToFix 'Purchase Microsoft Intune Plan 1 or a suite that includes it (Microsoft 365 E3/E5/F1/F3/Business Premium, EMS E3/E5) and assign it to users.' `
                -DocLink 'https://learn.microsoft.com/mem/intune/fundamentals/licenses'
            return
        }

        $totalEnabled = 0
        $totalConsumed = 0
        foreach ($sku in $intuneSkus) {
            $enabled = [int]$sku.prepaidUnits.enabled
            $consumed = [int]$sku.consumedUnits
            $totalEnabled += $enabled
            $totalConsumed += $consumed
            $result = if ($sku.capabilityStatus -eq 'Enabled') { 'PASS' } else { 'WARN' }
            Add-INTCheckResult `
                -Category 'Licensing' `
                -CheckName "SKU: $($sku.skuPartNumber)" `
                -Result $result `
                -Details "Status: $($sku.capabilityStatus) | Enabled: $enabled | Assigned: $consumed | Available: $($enabled - $consumed) | Warning: $($sku.prepaidUnits.warning) | Suspended: $($sku.prepaidUnits.suspended)" `
                -HowToFix $(if ($result -eq 'WARN') { 'Renew or reactivate this subscription in the Microsoft 365 admin center > Billing.' } else { '' })
        }

        $available = $totalEnabled - $totalConsumed
        if ($available -gt 0) {
            Add-INTCheckResult `
                -Category 'Licensing' `
                -CheckName 'Intune Seats Available' `
                -Result 'PASS' `
                -Details "$available of $totalEnabled Intune-bearing seat(s) unassigned across $($intuneSkus.Count) SKU(s). Run 01_INT_Validate_LicensingAndCapacity.ps1 to size against the target users."
        } else {
            Add-INTCheckResult `
                -Category 'Licensing' `
                -CheckName 'Intune Seats Available' `
                -Result 'WARN' `
                -Details "All $totalEnabled Intune-bearing seat(s) are assigned. New users cannot be licensed." `
                -HowToFix 'Buy additional seats or reclaim licenses from disabled accounts before onboarding new users.' `
                -DocLink 'https://learn.microsoft.com/mem/intune/fundamentals/licenses-assign'
        }

        foreach ($sku in $addOnSkus) {
            Add-INTCheckResult `
                -Category 'Licensing' `
                -CheckName "Add-on: $($sku.skuPartNumber)" `
                -Result 'INFO' `
                -Details "Intune add-on or related plan present (requires a core Intune license per user) | Enabled: $($sku.prepaidUnits.enabled) | Assigned: $($sku.consumedUnits)"
        }
    } catch {
        Add-INTGraphFailure -Category 'Licensing' -CheckName 'Subscribed SKUs' -ErrorRecord $_ -Permission 'Organization.Read.All' -DocLink 'https://learn.microsoft.com/mem/intune/fundamentals/licenses'
    }
}

#endregion

#region -- Device Registration & Automatic Enrollment --------------------------

function Test-INTDeviceRegistration {
    [CmdletBinding()]
    param([string[]]$Platforms)

    Write-INTSection -Title 'DEVICE REGISTRATION & AUTOMATIC ENROLLMENT'

    try {
        $registration = Invoke-INTGraphRequest -Uri 'beta/policies/deviceRegistrationPolicy'
        $joinType = [string](Get-INTPropertyValue -InputObject (Get-INTPropertyValue -InputObject $registration.azureADJoin -Name 'allowedToJoin') -Name '@odata.type')
        $quota = Get-INTPropertyValue -InputObject $registration -Name 'userDeviceQuota'

        if ('Windows' -in $Platforms) {
            switch -Wildcard ($joinType) {
                '*allDeviceRegistrationMembership' {
                    Add-INTCheckResult `
                        -Category 'DeviceRegistration' `
                        -CheckName 'Users May Join Devices to Entra ID' `
                        -Result 'PASS' `
                        -Details 'All users'
                }
                '*enumeratedDeviceRegistrationMembership' {
                    Add-INTCheckResult `
                        -Category 'DeviceRegistration' `
                        -CheckName 'Users May Join Devices to Entra ID' `
                        -Result 'INFO' `
                        -Details 'Selected users or groups only. Users outside that scope cannot Entra-join (and therefore auto-enroll) Windows devices.' `
                        -DocLink 'https://learn.microsoft.com/entra/identity/devices/manage-device-identities#configure-device-settings'
                }
                '*noDeviceRegistrationMembership' {
                    Add-INTCheckResult `
                        -Category 'DeviceRegistration' `
                        -CheckName 'Users May Join Devices to Entra ID' `
                        -Result 'FAIL' `
                        -Details 'No user may join devices to Entra ID' `
                        -Roadblock 'Windows Autopilot and Entra join (the standard Windows enrollment path) are blocked.' `
                        -HowToFix 'Entra admin center > Devices > Device settings: set "Users may join devices to Microsoft Entra" to All or to the enrollment group.' `
                        -DocLink 'https://learn.microsoft.com/entra/identity/devices/manage-device-identities#configure-device-settings'
                }
                default {
                    Add-INTCheckResult `
                        -Category 'DeviceRegistration' `
                        -CheckName 'Users May Join Devices to Entra ID' `
                        -Result 'INFO' `
                        -Details "Setting returned an unrecognized value: '$joinType'"
                }
            }
        }

        Add-INTCheckResult `
            -Category 'DeviceRegistration' `
            -CheckName 'Entra Device Quota per User' `
            -Result 'INFO' `
            -Details "Maximum devices per user in Entra ID: $quota. 01_INT_Validate_LicensingAndCapacity.ps1 compares it with the planned devices per user."
    } catch {
        Add-INTGraphFailure -Category 'DeviceRegistration' -CheckName 'Entra Device Settings' -ErrorRecord $_ -Permission 'Policy.Read.All' -DocLink 'https://learn.microsoft.com/entra/identity/devices/manage-device-identities'
    }

    # MDM user scope: drives Windows automatic enrollment on Entra join.
    if ('Windows' -in $Platforms) {
        try {
            $mdmPolicies = @(Invoke-INTGraphRequest -Uri 'beta/policies/mobileDeviceManagementPolicies' -All)
            $intunePolicy = $mdmPolicies | Where-Object { $_.id -eq '0000000a-0000-0000-c000-000000000000' -or $_.displayName -eq 'Microsoft Intune' } | Select-Object -First 1
            if ($null -eq $intunePolicy) {
                Add-INTCheckResult `
                    -Category 'DeviceRegistration' `
                    -CheckName 'Windows Automatic Enrollment (MDM User Scope)' `
                    -Result 'FAIL' `
                    -Details 'The Microsoft Intune mobility (MDM and WIP) application was not found' `
                    -Roadblock 'Without it, Entra-joined Windows devices do not enroll in Intune automatically.' `
                    -HowToFix 'Intune admin center > Devices > Enrollment > Windows > Automatic Enrollment: configure Microsoft Intune with an MDM user scope of All or Some.' `
                    -DocLink 'https://learn.microsoft.com/mem/intune/enrollment/windows-enroll#enable-windows-automatic-enrollment'
            } else {
                switch ([string]$intunePolicy.appliesTo) {
                    'all' {
                        Add-INTCheckResult `
                            -Category 'DeviceRegistration' `
                            -CheckName 'Windows Automatic Enrollment (MDM User Scope)' `
                            -Result 'PASS' `
                            -Details 'MDM user scope: All'
                    }
                    'selected' {
                        Add-INTCheckResult `
                            -Category 'DeviceRegistration' `
                            -CheckName 'Windows Automatic Enrollment (MDM User Scope)' `
                            -Result 'INFO' `
                            -Details 'MDM user scope: Some (selected groups). Confirm the target users are in those groups.' `
                            -DocLink 'https://learn.microsoft.com/mem/intune/enrollment/windows-enroll#enable-windows-automatic-enrollment'
                    }
                    default {
                        Add-INTCheckResult `
                            -Category 'DeviceRegistration' `
                            -CheckName 'Windows Automatic Enrollment (MDM User Scope)' `
                            -Result 'FAIL' `
                            -Details "MDM user scope: $($intunePolicy.appliesTo)" `
                            -Roadblock 'Entra-joined Windows devices (including Autopilot and AVD session hosts) will not enroll in Intune automatically.' `
                            -HowToFix 'Intune admin center > Devices > Enrollment > Windows > Automatic Enrollment: set MDM user scope to All, or Some with the target group.' `
                            -DocLink 'https://learn.microsoft.com/mem/intune/enrollment/windows-enroll#enable-windows-automatic-enrollment'
                    }
                }
            }
        } catch {
            Add-INTGraphFailure -Category 'DeviceRegistration' -CheckName 'Windows Automatic Enrollment (MDM User Scope)' -ErrorRecord $_ -Permission 'Policy.Read.All' -DocLink 'https://learn.microsoft.com/mem/intune/enrollment/windows-enroll'
        }
    }
}

#endregion

#region -- Enrollment Configuration --------------------------------------------

function Test-INTEnrollmentConfiguration {
    [CmdletBinding()]
    param([string[]]$Platforms)

    Write-INTSection -Title 'ENROLLMENT CONFIGURATION'

    try {
        $configs = @(Invoke-INTGraphRequest -Uri 'beta/deviceManagement/deviceEnrollmentConfigurations' -All)

        $limitConfig = $configs | Where-Object { [string]$_.'@odata.type' -like '*deviceEnrollmentLimitConfiguration' } |
            Sort-Object { [int]$_.priority } | Select-Object -First 1
        if ($null -ne $limitConfig) {
            Add-INTCheckResult `
                -Category 'Enrollment' `
                -CheckName 'Device Limit (Default Restriction)' `
                -Result 'INFO' `
                -Details "Each user may enroll up to $($limitConfig.limit) device(s) under '$($limitConfig.displayName)'. Higher-priority restrictions may override this for some groups."
        }

        # Two shapes exist: the legacy all-platform object and the newer per-platform objects.
        $platformKeys = @{ Windows = 'windows'; iOS = 'ios'; Android = 'android'; macOS = 'macOS' }
        foreach ($p in $Platforms) {
            $key = $platformKeys[$p]
            $blocked = $false
            $personalBlocked = $false
            $source = ''

            $single = $configs | Where-Object {
                [string]$_.'@odata.type' -like '*deviceEnrollmentPlatformRestrictionConfiguration' -and [string]$_.platformType -like "$key*" -and [int]$_.priority -eq 0
            } | Select-Object -First 1
            if ($null -ne $single -and $null -ne $single.platformRestriction) {
                $blocked = [bool]$single.platformRestriction.platformBlocked
                $personalBlocked = [bool]$single.platformRestriction.personalDeviceEnrollmentBlocked
                $source = $single.displayName
            } else {
                $legacy = $configs | Where-Object { [string]$_.'@odata.type' -like '*deviceEnrollmentPlatformRestrictionsConfiguration' -and [int]$_.priority -eq 0 } | Select-Object -First 1
                $restriction = Get-INTPropertyValue -InputObject $legacy -Name ("{0}Restriction" -f $key)
                if ($null -ne $restriction) {
                    $blocked = [bool]$restriction.platformBlocked
                    $personalBlocked = [bool]$restriction.personalDeviceEnrollmentBlocked
                    $source = $legacy.displayName
                }
            }

            if ([string]::IsNullOrWhiteSpace($source)) {
                Add-INTCheckResult `
                    -Category 'Enrollment' `
                    -CheckName "Platform Restriction: $p" `
                    -Result 'INFO' `
                    -Details 'No default platform restriction was returned for this platform.'
            } elseif ($blocked) {
                Add-INTCheckResult `
                    -Category 'Enrollment' `
                    -CheckName "Platform Restriction: $p" `
                    -Result 'FAIL' `
                    -Details "Enrollment of $p is blocked by the default restriction '$source'" `
                    -Roadblock "Users not covered by a higher-priority restriction cannot enroll $p devices." `
                    -HowToFix "Intune admin center > Devices > Enrollment > Device platform restriction: allow $p in the default policy, or create a higher-priority policy that allows it for the enrollment group." `
                    -DocLink 'https://learn.microsoft.com/mem/intune/enrollment/enrollment-restrictions-set'
            } else {
                $personalText = if ($personalBlocked) { 'personally owned devices blocked' } else { 'personally owned devices allowed' }
                Add-INTCheckResult `
                    -Category 'Enrollment' `
                    -CheckName "Platform Restriction: $p" `
                    -Result 'PASS' `
                    -Details "Allowed by '$source' ($personalText)"
            }
        }

        if ('Windows' -in $Platforms) {
            $esp = @($configs | Where-Object { [string]$_.'@odata.type' -like '*windows10EnrollmentCompletionPageConfiguration' })
            $espDefault = $esp | Where-Object { [int]$_.priority -eq 0 } | Select-Object -First 1
            $espOn = ($null -ne $espDefault) -and [bool](Get-INTPropertyValue -InputObject $espDefault -Name 'showInstallationProgress')
            $customEsp = @($esp | Where-Object { [int]$_.priority -ne 0 }).Count
            Add-INTCheckResult `
                -Category 'Enrollment' `
                -CheckName 'Enrollment Status Page (Windows)' `
                -Result 'INFO' `
                -Details ("Default ESP shows progress: {0} | Custom ESP profiles: {1}" -f $espOn, $customEsp) `
                -DocLink 'https://learn.microsoft.com/mem/intune/enrollment/windows-enrollment-status'
        }
    } catch {
        Add-INTGraphFailure -Category 'Enrollment' -CheckName 'Enrollment Configurations' -ErrorRecord $_ -Permission 'DeviceManagementServiceConfig.Read.All' -DocLink 'https://learn.microsoft.com/mem/intune/enrollment/enrollment-restrictions-set'
    }
}

#endregion

#region -- Compliance & Configuration ------------------------------------------

function Get-INTPolicyPlatform {
    [CmdletBinding()]
    param([string]$ODataType, [string]$Platforms)

    $text = "$ODataType $Platforms"
    if ($text -match '(?i)windows') { return 'Windows' }
    if ($text -match '(?i)(\.|^|\s)ios') { return 'iOS' }
    if ($text -match '(?i)android|aosp') { return 'Android' }
    if ($text -match '(?i)macos') { return 'macOS' }
    return 'Other'
}

function Test-INTPolicyCoverage {
    [CmdletBinding()]
    param([string[]]$Platforms)

    Write-INTSection -Title 'COMPLIANCE & CONFIGURATION POLICIES'

    try {
        $compliance = @(Invoke-INTGraphRequest -Uri 'v1.0/deviceManagement/deviceCompliancePolicies?$expand=assignments' -All)
        foreach ($p in $Platforms) {
            $forPlatform = @($compliance | Where-Object { (Get-INTPolicyPlatform -ODataType $_.'@odata.type') -eq $p })
            $assigned = @($forPlatform | Where-Object { @($_.assignments).Count -gt 0 })
            if ($forPlatform.Count -eq 0) {
                Add-INTCheckResult `
                    -Category 'Policies' `
                    -CheckName "Compliance Policy: $p" `
                    -Result 'WARN' `
                    -Details "No $p compliance policy exists" `
                    -HowToFix "Create a $p compliance policy (Intune admin center > Devices > Compliance) and assign it before enforcing Conditional Access on compliance." `
                    -DocLink 'https://learn.microsoft.com/mem/intune/protect/create-compliance-policy'
            } elseif ($assigned.Count -eq 0) {
                Add-INTCheckResult `
                    -Category 'Policies' `
                    -CheckName "Compliance Policy: $p" `
                    -Result 'WARN' `
                    -Details "$($forPlatform.Count) $p compliance polic(ies) exist, none assigned" `
                    -HowToFix 'Assign the compliance policy to the user or device groups being enrolled.' `
                    -DocLink 'https://learn.microsoft.com/mem/intune/protect/create-compliance-policy'
            } else {
                Add-INTCheckResult `
                    -Category 'Policies' `
                    -CheckName "Compliance Policy: $p" `
                    -Result 'PASS' `
                    -Details "$($assigned.Count) of $($forPlatform.Count) $p compliance polic(ies) assigned"
            }
        }
    } catch {
        Add-INTGraphFailure -Category 'Policies' -CheckName 'Compliance Policies' -ErrorRecord $_ -Permission 'DeviceManagementConfiguration.Read.All'
    }

    try {
        $templates = @(Invoke-INTGraphRequest -Uri 'v1.0/deviceManagement/deviceConfigurations?$select=id,displayName' -All)
        $catalog = @()
        try {
            $catalog = @(Invoke-INTGraphRequest -Uri 'beta/deviceManagement/configurationPolicies?$select=id,name,platforms' -All)
        } catch {
            Write-INTLog -Level 'WARN' -Message "Settings catalog policies could not be read: $($_.Exception.Message)"
        }

        foreach ($p in $Platforms) {
            $count = @($templates | Where-Object { (Get-INTPolicyPlatform -ODataType $_.'@odata.type') -eq $p }).Count +
                     @($catalog | Where-Object { (Get-INTPolicyPlatform -Platforms ([string]$_.platforms)) -eq $p }).Count
            if ($count -gt 0) {
                Add-INTCheckResult `
                    -Category 'Policies' `
                    -CheckName "Configuration Profiles: $p" `
                    -Result 'PASS' `
                    -Details "$count $p configuration profile(s) (templates and settings catalog)"
            } else {
                Add-INTCheckResult `
                    -Category 'Policies' `
                    -CheckName "Configuration Profiles: $p" `
                    -Result 'WARN' `
                    -Details "No $p configuration profile exists. Enrolled devices would receive no settings." `
                    -HowToFix "Create a baseline $p profile (Intune admin center > Devices > Configuration) before enrolling production devices." `
                    -DocLink 'https://learn.microsoft.com/mem/intune/configuration/device-profile-create'
            }
        }
    } catch {
        Add-INTGraphFailure -Category 'Policies' -CheckName 'Configuration Profiles' -ErrorRecord $_ -Permission 'DeviceManagementConfiguration.Read.All'
    }
}

#endregion

#region -- Windows Autopilot ---------------------------------------------------

function Test-INTAutopilotReadiness {
    [CmdletBinding()]
    param()

    Write-INTSection -Title 'WINDOWS AUTOPILOT'

    try {
        $profiles = @(Invoke-INTGraphRequest -Uri 'beta/deviceManagement/windowsAutopilotDeploymentProfiles?$expand=assignments' -All)
        $assigned = @($profiles | Where-Object { @($_.assignments).Count -gt 0 })
        if ($profiles.Count -eq 0) {
            Add-INTCheckResult `
                -Category 'Autopilot' `
                -CheckName 'Deployment Profiles' `
                -Result 'FAIL' `
                -Details 'No Windows Autopilot deployment profile exists' `
                -Roadblock 'Registered devices run the consumer out-of-box experience instead of the Autopilot flow.' `
                -HowToFix 'Intune admin center > Devices > Enrollment > Windows > Deployment profiles: create a profile and assign it to the Autopilot device group.' `
                -DocLink 'https://learn.microsoft.com/autopilot/profiles'
        } elseif ($assigned.Count -eq 0) {
            Add-INTCheckResult `
                -Category 'Autopilot' `
                -CheckName 'Deployment Profiles' `
                -Result 'WARN' `
                -Details "$($profiles.Count) profile(s) exist, none assigned" `
                -HowToFix 'Assign the deployment profile to a device group that contains the Autopilot devices (for example a dynamic group on ZTDId).' `
                -DocLink 'https://learn.microsoft.com/autopilot/profiles'
        } else {
            Add-INTCheckResult `
                -Category 'Autopilot' `
                -CheckName 'Deployment Profiles' `
                -Result 'PASS' `
                -Details "$($assigned.Count) of $($profiles.Count) profile(s) assigned: $((@($assigned | Select-Object -ExpandProperty displayName) -join ', '))"
        }
    } catch {
        Add-INTGraphFailure -Category 'Autopilot' -CheckName 'Deployment Profiles' -ErrorRecord $_ -Permission 'DeviceManagementServiceConfig.Read.All' -DocLink 'https://learn.microsoft.com/autopilot/profiles'
    }

    try {
        # deploymentProfileAssignmentStatus exists only in beta; v1.0 answers 400 for it.
        $identities = @(Invoke-INTGraphRequest -Uri 'beta/deviceManagement/windowsAutopilotDeviceIdentities' -All)
        $unassigned = @($identities | Where-Object { [string]$_.deploymentProfileAssignmentStatus -match '^(notAssigned|failed|unknown)' }).Count
        $result = if ($identities.Count -eq 0) { 'WARN' } elseif ($unassigned -gt 0) { 'WARN' } else { 'PASS' }
        Add-INTCheckResult `
            -Category 'Autopilot' `
            -CheckName 'Registered Devices' `
            -Result $result `
            -Details "$($identities.Count) device(s) registered | $unassigned without an assigned profile" `
            -HowToFix $(if ($result -eq 'WARN') { 'Import hardware hashes (or have the OEM/reseller register devices), then confirm each shows an assigned profile before shipping.' } else { '' }) `
            -DocLink 'https://learn.microsoft.com/autopilot/add-devices'
    } catch {
        Add-INTGraphFailure -Category 'Autopilot' -CheckName 'Registered Devices' -ErrorRecord $_ -Permission 'DeviceManagementServiceConfig.Read.All' -DocLink 'https://learn.microsoft.com/autopilot/add-devices'
    }
}

#endregion

#region -- Platform Connectors -------------------------------------------------

function Test-INTPlatformConnectors {
    [CmdletBinding()]
    param([string[]]$Platforms)

    Write-INTSection -Title 'PLATFORM CONNECTORS'

    if ('iOS' -in $Platforms -or 'macOS' -in $Platforms) {
        $apnsDoc = 'https://learn.microsoft.com/mem/intune/enrollment/apple-mdm-push-certificate-get'
        try {
            $apns = Invoke-INTGraphRequest -Uri 'v1.0/deviceManagement/applePushNotificationCertificate'
            $expiry = Get-INTPropertyValue -InputObject $apns -Name 'expirationDateTime'
            if ($null -eq $expiry) {
                Add-INTCheckResult `
                    -Category 'Connectors' `
                    -CheckName 'Apple MDM Push Certificate' `
                    -Result 'FAIL' `
                    -Details 'No Apple MDM push certificate is configured' `
                    -Roadblock 'iOS, iPadOS and macOS devices cannot enroll without an APNs certificate.' `
                    -HowToFix 'Intune admin center > Devices > Enrollment > Apple > Apple MDM Push certificate: create it with a company Apple ID (not a personal one).' `
                    -DocLink $apnsDoc
            } else {
                $daysLeft = [int]((Get-Date $expiry).ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalDays
                if ($daysLeft -lt 0) {
                    Add-INTCheckResult `
                        -Category 'Connectors' `
                        -CheckName 'Apple MDM Push Certificate' `
                        -Result 'FAIL' `
                        -Details "Expired $([math]::Abs($daysLeft)) day(s) ago | Apple ID: $($apns.appleIdentifier)" `
                        -Roadblock 'Apple devices stop checking in. Renewing with a different Apple ID forces every Apple device to re-enroll.' `
                        -HowToFix "Renew the existing certificate at https://identity.apple.com with the same Apple ID ($($apns.appleIdentifier)), then upload it in Intune." `
                        -DocLink $apnsDoc
                } elseif ($daysLeft -le 30) {
                    Add-INTCheckResult `
                        -Category 'Connectors' `
                        -CheckName 'Apple MDM Push Certificate' `
                        -Result 'WARN' `
                        -Details "Expires in $daysLeft day(s) | Apple ID: $($apns.appleIdentifier)" `
                        -HowToFix "Renew now at https://identity.apple.com with the same Apple ID ($($apns.appleIdentifier))." `
                        -DocLink $apnsDoc
                } else {
                    Add-INTCheckResult `
                        -Category 'Connectors' `
                        -CheckName 'Apple MDM Push Certificate' `
                        -Result 'PASS' `
                        -Details "Valid for $daysLeft more day(s) | Apple ID: $($apns.appleIdentifier)"
                }
            }
        } catch {
            if ((Get-INTGraphStatusCode -ErrorRecord $_) -eq 404) {
                Add-INTCheckResult `
                    -Category 'Connectors' `
                    -CheckName 'Apple MDM Push Certificate' `
                    -Result 'FAIL' `
                    -Details 'No Apple MDM push certificate is configured' `
                    -Roadblock 'iOS, iPadOS and macOS devices cannot enroll without an APNs certificate.' `
                    -HowToFix 'Intune admin center > Devices > Enrollment > Apple > Apple MDM Push certificate: create it with a company Apple ID.' `
                    -DocLink $apnsDoc
            } else {
                Add-INTGraphFailure -Category 'Connectors' -CheckName 'Apple MDM Push Certificate' -ErrorRecord $_ -Permission 'DeviceManagementServiceConfig.Read.All' -DocLink $apnsDoc
            }
        }
    }

    if ('Android' -in $Platforms) {
        $googleDoc = 'https://learn.microsoft.com/mem/intune/enrollment/connect-intune-android-enterprise'
        try {
            $google = Invoke-INTGraphRequest -Uri 'beta/deviceManagement/androidManagedStoreAccountEnterpriseSettings'
            $bind = [string](Get-INTPropertyValue -InputObject $google -Name 'bindStatus')
            if ($bind -eq 'boundAndValidated' -or $bind -eq 'bound') {
                Add-INTCheckResult `
                    -Category 'Connectors' `
                    -CheckName 'Managed Google Play' `
                    -Result 'PASS' `
                    -Details "Bind status: $bind | Owner: $($google.ownerUserPrincipalName) | Last app sync: $($google.lastAppSyncDateTime)"
            } else {
                Add-INTCheckResult `
                    -Category 'Connectors' `
                    -CheckName 'Managed Google Play' `
                    -Result 'FAIL' `
                    -Details "Bind status: '$bind'" `
                    -Roadblock 'Android Enterprise enrollment (work profile, fully managed, dedicated) needs the tenant bound to Managed Google Play.' `
                    -HowToFix 'Intune admin center > Devices > Enrollment > Android > Managed Google Play: link a company Google account.' `
                    -DocLink $googleDoc
            }
        } catch {
            Add-INTGraphFailure -Category 'Connectors' -CheckName 'Managed Google Play' -ErrorRecord $_ -Permission 'DeviceManagementConfiguration.Read.All' -DocLink $googleDoc
        }
    }

    if ('iOS' -notin $Platforms -and 'macOS' -notin $Platforms -and 'Android' -notin $Platforms) {
        Add-INTCheckResult `
            -Category 'Connectors' `
            -CheckName 'Platform Connectors' `
            -Result 'SKIP' `
            -Details 'No Apple or Android platform selected'
    }
}

#endregion

#region -- Conditional Access ---------------------------------------------------

function Test-INTConditionalAccess {
    [CmdletBinding()]
    param()

    Write-INTSection -Title 'CONDITIONAL ACCESS (DEVICE COMPLIANCE)'

    $caDoc = 'https://learn.microsoft.com/mem/intune/protect/create-conditional-access-intune'
    try {
        $policies = @(Invoke-INTGraphRequest -Uri 'v1.0/identity/conditionalAccess/policies' -All)
        $compliancePolicies = @($policies | Where-Object { @($_.grantControls.builtInControls) -contains 'compliantDevice' })
        $enforced = @($compliancePolicies | Where-Object { $_.state -eq 'enabled' })
        $reportOnly = @($compliancePolicies | Where-Object { $_.state -eq 'enabledForReportingButNotEnforced' })

        if ($compliancePolicies.Count -eq 0) {
            Add-INTCheckResult `
                -Category 'ConditionalAccess' `
                -CheckName 'Require Compliant Device' `
                -Result 'INFO' `
                -Details "$($policies.Count) Conditional Access polic(ies); none requires a compliant device. Intune compliance is reported but not enforced at sign-in." `
                -DocLink $caDoc
        } else {
            Add-INTCheckResult `
                -Category 'ConditionalAccess' `
                -CheckName 'Require Compliant Device' `
                -Result 'INFO' `
                -Details ("Enforced: {0} | Report-only: {1} | Off: {2} | Enforced policies: {3}" -f $enforced.Count, $reportOnly.Count, ($compliancePolicies.Count - $enforced.Count - $reportOnly.Count), ((@($enforced | Select-Object -ExpandProperty displayName)) -join '; ')) `
                -DocLink $caDoc
        }

        # A compliance requirement on all cloud apps that is enforced before users
        # have enrolled locks new devices out; report-only first is the safe rollout.
        $allApps = @($enforced | Where-Object { @($_.conditions.applications.includeApplications) -contains 'All' })
        if ($allApps.Count -gt 0) {
            Add-INTCheckResult `
                -Category 'ConditionalAccess' `
                -CheckName 'Compliance Enforced on All Cloud Apps' `
                -Result 'WARN' `
                -Details "$($allApps.Count) enforced polic(ies) require compliance for all cloud apps: $((@($allApps | Select-Object -ExpandProperty displayName)) -join '; ')" `
                -HowToFix 'Confirm new users can enroll before these policies apply to them: scope them to enrolled groups, or exclude the enrollment group during rollout and run them in report-only mode first.' `
                -DocLink 'https://learn.microsoft.com/entra/identity/conditional-access/policy-all-users-device-compliance'
        }
    } catch {
        Add-INTGraphFailure -Category 'ConditionalAccess' -CheckName 'Conditional Access Policies' -ErrorRecord $_ -Permission 'Policy.Read.All' -DocLink $caDoc
    }
}

#endregion

#region -- Administrative Roles ------------------------------------------------

function Test-INTAdministrativeRoles {
    [CmdletBinding()]
    param()

    Write-INTSection -Title 'ADMINISTRATIVE ROLES'

    $roleDoc = 'https://learn.microsoft.com/mem/intune/fundamentals/role-based-access-control'
    $intuneAdminRoleId = '3a2c62db-5318-420d-8d74-23affee5d9d5'

    try {
        $assignments = @(Invoke-INTGraphRequest -Uri "v1.0/roleManagement/directory/roleAssignments?`$filter=roleDefinitionId eq '$intuneAdminRoleId'" -All)
        if ($assignments.Count -eq 0) {
            Add-INTCheckResult `
                -Category 'Roles' `
                -CheckName 'Intune Administrator Assignments' `
                -Result 'WARN' `
                -Details 'No account holds the Intune Administrator role. Day-to-day Intune work would run as Global Administrator.' `
                -HowToFix 'Assign Intune Administrator (ideally eligible through PIM) to the people who run Intune, and keep Global Administrator for break-glass use.' `
                -DocLink $roleDoc
        } else {
            Add-INTCheckResult `
                -Category 'Roles' `
                -CheckName 'Intune Administrator Assignments' `
                -Result 'PASS' `
                -Details "$($assignments.Count) active assignment(s) of Intune Administrator"
        }
    } catch {
        Add-INTGraphFailure -Category 'Roles' -CheckName 'Intune Administrator Assignments' -ErrorRecord $_ -Permission 'RoleManagement.Read.Directory' -DocLink $roleDoc
    }

    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    if ($null -ne $ctx -and [string]$ctx.AuthType -eq 'Delegated') {
        try {
            $myRoles = @(Invoke-INTGraphRequest -Uri 'v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole?$select=displayName,roleTemplateId' -All)
            $names = @($myRoles | Select-Object -ExpandProperty displayName)
            $canManage = @($myRoles | Where-Object { $_.roleTemplateId -in @($intuneAdminRoleId, '62e90394-69f5-4237-9190-012177145e10') }).Count -gt 0
            if ($canManage) {
                Add-INTCheckResult `
                    -Category 'Roles' `
                    -CheckName 'Signed-in Account Roles' `
                    -Result 'PASS' `
                    -Details "Can manage Intune: $($names -join ', ')"
            } else {
                Add-INTCheckResult `
                    -Category 'Roles' `
                    -CheckName 'Signed-in Account Roles' `
                    -Result 'INFO' `
                    -Details "Active roles: $(if ($names.Count) { $names -join ', ' } else { 'none' }). Enough to read this report; deploying Intune needs Intune Administrator." `
                    -DocLink $roleDoc
            }
        } catch {
            Add-INTGraphFailure -Category 'Roles' -CheckName 'Signed-in Account Roles' -ErrorRecord $_ -Permission 'Directory.Read.All' -DocLink $roleDoc
        }
    }
}

#endregion

#region -- Endpoint Connectivity -----------------------------------------------

function Test-INTEndpointConnectivity {
    [CmdletBinding()]
    param()

    Write-INTSection -Title 'CORE INTUNE ENDPOINT CONNECTIVITY (from this host)'

    $endpoints = @(
        @{ Host = 'login.microsoftonline.com';               Port = 443; Desc = 'Entra ID sign-in'                }
        @{ Host = 'enterpriseregistration.windows.net';      Port = 443; Desc = 'Entra device registration'       }
        @{ Host = 'enrollment.manage.microsoft.com';         Port = 443; Desc = 'Intune enrollment'               }
        @{ Host = 'enterpriseenrollment-s.manage.microsoft.com'; Port = 443; Desc = 'Intune enrollment (Windows)' }
        @{ Host = 'manage.microsoft.com';                    Port = 443; Desc = 'Intune service'                  }
        @{ Host = 'graph.microsoft.com';                     Port = 443; Desc = 'Microsoft Graph'                 }
    )

    foreach ($ep in $endpoints) {
        $client = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $connect = $client.BeginConnect($ep.Host, $ep.Port, $null, $null)
            $reach = $connect.AsyncWaitHandle.WaitOne(5000, $false) -and $client.Connected
            if ($reach) {
                Add-INTCheckResult `
                    -Category 'Connectivity' `
                    -CheckName "Endpoint $($ep.Host):$($ep.Port)" `
                    -Result 'INFO' `
                    -Details "$($ep.Desc)  -  reachable from this host; device connectivity is not proven"
            } else {
                Add-INTCheckResult `
                    -Category 'Connectivity' `
                    -CheckName "Endpoint $($ep.Host):$($ep.Port)" `
                    -Result 'WARN' `
                    -Details "$($ep.Desc)  -  not reachable from this host within 5 s" `
                    -HowToFix 'Run 02_INT_Validate_Network_Configuration.ps1 on a device in the network being enrolled; review firewall, proxy, and TLS inspection for *.manage.microsoft.com.' `
                    -DocLink 'https://learn.microsoft.com/mem/intune/fundamentals/intune-endpoints'
            }
        } catch {
            Add-INTCheckResult `
                -Category 'Connectivity' `
                -CheckName "Endpoint $($ep.Host):$($ep.Port)" `
                -Result 'WARN' `
                -Details "Connection error: $($_.Exception.Message)" `
                -DocLink 'https://learn.microsoft.com/mem/intune/fundamentals/intune-endpoints'
        } finally {
            if ($null -ne $client) { $client.Close() }
        }
    }
}

#endregion

# ==============================================================================
# INTERACTIVE SETUP WIZARD
# ==============================================================================

#region -- Setup Wizard --------------------------------------------------------

function Get-INTWizardMenuChoice {
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

function Invoke-INTWizardSignIn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Method,
        [string]$TenantId,
        [Parameter(Mandatory=$true)] [string[]]$Scopes
    )

    # The wizard signs in before the main flow imports modules, so import the
    # staged copies first; otherwise Connect-MgGraph would autoload any version.
    if (-not $SkipModuleValidation) { Import-INTRequiredModulesToMemory -Modules $RequiredModules }

    # ContextScope Process keeps the token in memory for this run only; the
    # default (CurrentUser) writes it to disk and the next run reuses it silently.
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    $connectParams = @{ Scopes = $Scopes; ContextScope = 'Process'; NoWelcome = $true; ErrorAction = 'Stop' }
    if ($TenantId) { $connectParams['TenantId'] = $TenantId }
    if ($Method -eq 'DeviceCode') { $connectParams['UseDeviceCode'] = $true }
    Connect-MgGraph @connectParams | Out-Null
    return (Get-MgContext -ErrorAction Stop)
}

function Get-INTSignedInTenant {
    [CmdletBinding()]
    param()
    # Name and default domain of the tenant the Graph session is signed in to.
    try {
        $org = Invoke-MgGraphRequest -Method GET -Uri 'v1.0/organization?$select=displayName,verifiedDomains' -OutputType PSObject -ErrorAction Stop
        $first = @($org.value)[0]
        $domain = @($first.verifiedDomains | Where-Object { $_.isDefault })[0].name
        return [PSCustomObject]@{ Name = [string]$first.displayName; DefaultDomain = [string]$domain }
    } catch {
        return [PSCustomObject]@{ Name = ''; DefaultDomain = '' }
    }
}

function Invoke-INTSetupWizard {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)] [string[]]$Scopes)

    Clear-Host

    $line70 = '-' * 70
    $eq70   = '=' * 70

    Write-Host ''
    Write-Host "  $eq70" -ForegroundColor Cyan
    Write-Host '  MICROSOFT INTUNE  -  READINESS ASSESSMENT WIZARD' -ForegroundColor Cyan
    Write-Host "  $eq70" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Welcome! This wizard will guide you through a quick, read-only assessment' -ForegroundColor White
    Write-Host '  of your tenant to confirm it is ready to enroll devices in Microsoft Intune.' -ForegroundColor White
    Write-Host ''
    Write-Host '  WHAT DOES THIS TOOL DO?' -ForegroundColor Cyan
    Write-Host '  It reads tenant settings through Microsoft Graph and flags anything that' -ForegroundColor Gray
    Write-Host '  would block enrollment or policy delivery. Nothing is changed.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  HOW TO USE THIS WIZARD' -ForegroundColor Cyan
    Write-Host '  Answer 4 simple questions below. Press ENTER at any prompt to accept' -ForegroundColor Gray
    Write-Host '  the suggested default shown in [square brackets].' -ForegroundColor Gray
    Write-Host ''
    Write-Host "  $line70" -ForegroundColor DarkGray
    Write-Host ''
    $null = Read-Host '  Press ENTER to begin  '

    $config = [ordered]@{
        AuthMethod            = 'Interactive'
        WizardAuthenticated   = $false
        TenantId              = ''
        Platform              = @('Windows')
        IncludeAutopilot      = $false
    }

    # =========================================================================
    # STEP 1  -  SIGN IN
    # =========================================================================
    Clear-Host
    Write-Host ''
    Write-Host "  $line70" -ForegroundColor White
    Write-Host '  STEP 1 of 4  -  SIGN IN' -ForegroundColor White
    Write-Host "  $line70" -ForegroundColor White
    Write-Host ''
    Write-Host '  To assess your tenant, this tool needs to read its settings. You sign in' -ForegroundColor Gray
    Write-Host '  to Microsoft Graph with read-only permissions, then confirm the tenant on' -ForegroundColor Gray
    Write-Host '  the next screen.' -ForegroundColor Gray
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
    Write-Host '      Use this if you have already run Connect-MgGraph in this window.' -ForegroundColor DarkGray
    Write-Host '      You will be shown the account and asked to confirm it.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Service principal and managed identity sign-in: use -AuthMethod with -NonInteractive.' -ForegroundColor DarkGray
    Write-Host ''
    $authChoice = Get-INTWizardMenuChoice -Min 1 -Max 3 -Default 1
    switch ($authChoice) {
        1 { $config.AuthMethod = 'Interactive'     }
        2 { $config.AuthMethod = 'DeviceCode'      }
        3 { $config.AuthMethod = 'ExistingContext' }
    }

    $ctx = $null
    try {
        if (-not $SkipModuleValidation) { Import-INTRequiredModulesToMemory -Modules $RequiredModules }

        if ($config.AuthMethod -eq 'ExistingContext') {
            $existingCtx = Get-MgContext -ErrorAction SilentlyContinue
            if ($null -ne $existingCtx) {
                Write-Host ''
                Write-Host "  Existing session  -  signed in as: $($existingCtx.Account)$(if (-not $existingCtx.Account) { "app $($existingCtx.AppName)" })" -ForegroundColor White
                Write-Host "  Tenant: $($existingCtx.TenantId)" -ForegroundColor DarkGray
                $answer = Read-Host '  Use this session for the assessment? (y/N)'
                if ($answer -match '^[yY]') {
                    $ctx = $existingCtx
                    $config.WizardAuthenticated = $true
                } else {
                    $config.AuthMethod = 'Interactive'
                }
            } else {
                Write-Host ''
                Write-Host '  No existing session found. Opening browser for sign-in...' -ForegroundColor Yellow
                $config.AuthMethod = 'Interactive'
            }
        }

        if ($null -eq $ctx) {
            Write-Host ''
            if ($config.AuthMethod -eq 'DeviceCode') {
                Write-Host '  Starting device code sign-in...' -ForegroundColor Cyan
                Write-Host '  Follow the instructions below to visit the URL and enter the code shown.' -ForegroundColor Gray
                Write-Host ''
            } else {
                Write-Host '  Opening browser window  -  please complete the sign-in in your browser...' -ForegroundColor Cyan
            }
            $ctx = Invoke-INTWizardSignIn -Method $config.AuthMethod -Scopes $Scopes
            $config.WizardAuthenticated = $true
        }
    } catch {
        Write-Host ''
        Write-Host "  Sign-in did not complete: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '  You can still enter a tenant domain or ID on the next screen.' -ForegroundColor Yellow
        $null = Read-Host '  Press ENTER to continue  '
    }

    # =========================================================================
    # STEP 2  -  CONFIRM TENANT
    # =========================================================================
    Clear-Host
    Write-Host ''
    Write-Host "  $line70" -ForegroundColor White
    Write-Host '  STEP 2 of 4  -  YOUR MICROSOFT 365 TENANT' -ForegroundColor White
    Write-Host "  $line70" -ForegroundColor White
    Write-Host ''
    Write-Host '  A tenant is your organization in Microsoft 365 and Entra ID: it holds your' -ForegroundColor Gray
    Write-Host '  users, devices and Intune settings.' -ForegroundColor Gray
    Write-Host ''

    $selectedTenant = ''
    $otherTenant = $false
    if ($null -ne $ctx) {
        $tenantInfo = Get-INTSignedInTenant
        Write-Host "  Signed in as : $(if ($ctx.Account) { $ctx.Account } else { "app $($ctx.AppName)" })" -ForegroundColor White
        Write-Host "  Tenant       : $(if ($tenantInfo.Name) { "$($tenantInfo.Name)  ($($tenantInfo.DefaultDomain))" } else { $ctx.TenantId })" -ForegroundColor White
        Write-Host "  ID: $($ctx.TenantId)" -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  [1] Continue with this tenant' -ForegroundColor White
        Write-Host '  [2] Another tenant  (you will type its domain, for example contoso.com)' -ForegroundColor White
        Write-Host ''
        if ((Get-INTWizardMenuChoice -Min 1 -Max 2 -Default 1) -eq 1) {
            $selectedTenant = [string]$ctx.TenantId
        } else {
            $otherTenant = $true
        }
    } else {
        $otherTenant = $true
    }

    if ($otherTenant) {
        Write-Host ''
        $selectedTenant = (Read-Host '  Tenant domain or ID (for example contoso.com)').Trim()
        if ($selectedTenant) {
            if ($config.AuthMethod -eq 'ExistingContext') { $config.AuthMethod = 'Interactive' }
            Write-Host ''
            Write-Host '  Signing in to Microsoft Graph for this tenant (read-only permissions)...' -ForegroundColor Cyan
            Write-Host '  Your browser usually completes this step without asking again.' -ForegroundColor DarkGray
            try {
                $ctx = Invoke-INTWizardSignIn -Method $config.AuthMethod -TenantId $selectedTenant -Scopes $Scopes
                $config.WizardAuthenticated = $true
                $selectedTenant = [string]$ctx.TenantId
                $tenantInfo = Get-INTSignedInTenant
                Write-Host "  Signed in to $(if ($tenantInfo.Name) { "$($tenantInfo.Name)  ($($tenantInfo.DefaultDomain))" } else { $selectedTenant }) as $($ctx.Account)" -ForegroundColor Green
            } catch {
                $config.WizardAuthenticated = $false
                Write-Host "  Graph sign-in did not complete: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host '  The assessment will attempt sign-in again during execution.' -ForegroundColor Yellow
            }
        }
    }
    $config.TenantId = $selectedTenant
    $null = Read-Host '  Press ENTER to continue  '

    # =========================================================================
    # STEP 3  -  PLATFORMS
    # =========================================================================
    Clear-Host
    Write-Host ''
    Write-Host "  $line70" -ForegroundColor White
    Write-Host '  STEP 3 of 4  -  DEVICE PLATFORMS' -ForegroundColor White
    Write-Host "  $line70" -ForegroundColor White
    Write-Host ''
    Write-Host '  Which kinds of devices will you enroll in Intune? Platform-specific checks' -ForegroundColor Gray
    Write-Host '  (Apple push certificate, Managed Google Play, policies) follow this choice.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  [1] Windows only' -ForegroundColor White
    Write-Host '  [2] Windows, iOS/iPadOS and Android' -ForegroundColor White
    Write-Host '  [3] iOS/iPadOS and Android (mobile only)' -ForegroundColor White
    Write-Host '  [4] All platforms (Windows, iOS/iPadOS, Android, macOS)' -ForegroundColor White
    Write-Host ''
    $choice = Get-INTWizardMenuChoice -Min 1 -Max 4 -Default 1
    $config.Platform = switch ($choice) {
        1 { @('Windows') }
        2 { @('Windows', 'iOS', 'Android') }
        3 { @('iOS', 'Android') }
        4 { @('Windows', 'iOS', 'Android', 'macOS') }
    }

    # =========================================================================
    # STEP 4  -  WINDOWS AUTOPILOT
    # =========================================================================
    if ('Windows' -in $config.Platform) {
        Clear-Host
        Write-Host ''
        Write-Host "  $line70" -ForegroundColor White
        Write-Host '  STEP 4 of 4  -  WINDOWS AUTOPILOT' -ForegroundColor White
        Write-Host "  $line70" -ForegroundColor White
        Write-Host ''
        Write-Host '  Windows Autopilot sets up new PCs straight from the box: the user signs in' -ForegroundColor Gray
        Write-Host '  and the device enrolls and configures itself. Will you use it?' -ForegroundColor Gray
        Write-Host ''
        Write-Host '  [1] Yes  -  check Autopilot profiles and registered devices' -ForegroundColor White
        Write-Host '  [2] No' -ForegroundColor White
        Write-Host ''
        $config.IncludeAutopilot = (Get-INTWizardMenuChoice -Min 1 -Max 2 -Default 1) -eq 1
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
    & $writeBannerLine 'Microsoft Intune  -  Tenant Readiness Assessment'
    & $writeBannerLine "Version 1.0.0  |  PowerShell $psVer  |  READ-ONLY  -  No changes made"
    Write-Host "+$bar+" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  MINIMUM ROLE REQUIRED : Global Reader (Entra ID)' -ForegroundColor Gray
    Write-Host '  OPERATIONS            : READ-ONLY. Only Microsoft Graph GET requests are made.' -ForegroundColor Gray
    Write-Host "  RUN AS                : $env:USERNAME on $env:COMPUTERNAME" -ForegroundColor Gray
    Write-Host "  TIMESTAMP             : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
    Write-Host ''
    Write-Host "  Platforms          : $($Platform -join ', ')" -ForegroundColor White
    Write-Host "  Windows Autopilot  : $IncludeAutopilot" -ForegroundColor White
    if ($TenantId) { Write-Host "  Tenant             : $TenantId" -ForegroundColor White }
    Write-Host ''
}

#endregion

#region -- Module List & Permissions ------------------------------------------

$RequiredModules = @(
    @{ Name = 'Microsoft.Graph.Authentication'; MinVersion = '2.0.0'; Required = $true }
    @{ Name = 'ImportExcel';                    MinVersion = '7.0.0'; Required = $true }
)

$RequiredGraphScopes = @(
    'DeviceManagementConfiguration.Read.All',
    'DeviceManagementServiceConfig.Read.All',
    'DeviceManagementManagedDevices.Read.All',
    'DeviceManagementRBAC.Read.All',
    'Organization.Read.All',
    'Policy.Read.All',
    'Directory.Read.All',
    'RoleManagement.Read.Directory'
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
    $WizardSession = $false

    if (-not $NonInteractive) {
        $wizCfg = Invoke-INTSetupWizard -Scopes $RequiredGraphScopes
        if ($null -ne $wizCfg) {
            $Platform         = $wizCfg.Platform
            $IncludeAutopilot = [bool]$wizCfg.IncludeAutopilot
            $AuthMethod       = $wizCfg.AuthMethod
            $WizardSession    = [bool]$wizCfg.WizardAuthenticated
            if ($wizCfg.TenantId) { $TenantId = $wizCfg.TenantId }
        }
    }

    $validPlatforms = @('Windows', 'iOS', 'Android', 'macOS')
    $Platform = @($Platform | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($Platform -contains 'All') { $Platform = $validPlatforms }
    foreach ($p in $Platform) {
        if ($p -notin $validPlatforms) { throw "Unsupported -Platform value '$p'. Use Windows, iOS, Android, macOS or All." }
    }
    # Normalize casing to the canonical names used by the checks.
    $Platform = @($validPlatforms | Where-Object { $_ -in $Platform })

    Show-Banner

    # -- STEP 1: PowerShell Environment -------------------------------------------
    Write-INTSection -Title 'POWERSHELL ENVIRONMENT'

    $psVersion = $PSVersionTable.PSVersion
    if ($psVersion.Major -lt 5 -or ($psVersion.Major -eq 5 -and $psVersion.Minor -lt 1)) {
        Add-INTCheckResult `
            -Category 'Environment' `
            -CheckName 'PowerShell Version' `
            -Result 'FAIL' `
            -Details "Running on PS $psVersion. Minimum required: 5.1" `
            -Roadblock 'Microsoft.Graph modules require PowerShell 5.1 or later.' `
            -HowToFix 'Install PowerShell 7.x from https://aka.ms/powershell'
    } else {
        Add-INTCheckResult `
            -Category 'Environment' `
            -CheckName 'PowerShell Version' `
            -Result 'PASS' `
            -Details "PowerShell $psVersion ($($PSVersionTable.PSEdition))"
    }

    if (-not $SkipModuleValidation) {
        Test-INTModuleAvailability -Modules $RequiredModules
        try {
            Import-INTRequiredModulesToMemory -Modules $RequiredModules
        } catch {
            $importErrText = $_.Exception.Message
            if ($importErrText -match 'INT_MODULE_CONFLICT') {
                $recovered = Invoke-INTFreshProcessRecovery `
                    -Platform $Platform `
                    -IncludeAutopilot:$IncludeAutopilot `
                    -TenantId $TenantId `
                    -AuthMethod $AuthMethod `
                    -ApplicationId $ApplicationId `
                    -CertificateThumbprint $CertificateThumbprint `
                    -ReportPath $ReportPath `
                    -CriticalOnly:$CriticalOnly `
                    -SkipConnectivityTests:$SkipConnectivityTests

                if ($recovered) {
                    $script:RecoveredByChildProcess = $true
                    $script:ReportExported = $true
                    $script:ProcessExitCode = $script:FreshProcessExitCode
                    Write-Host ''
                    Write-Host '[ INFO ] Recovery run in clean process completed successfully.' -ForegroundColor Green
                    return
                }
            }

            Add-INTCheckResult `
                -Category 'Modules' `
                -CheckName 'Required Module Import' `
                -Result 'FAIL' `
                -Details $importErrText `
                -Roadblock 'Required modules could not be loaded into the current PowerShell session.' `
                -HowToFix 'Close this shell and rerun the script in a fresh process.'
            Write-Host ''
            Write-Host '[ ABORT ] Required module import failed. Cannot proceed with validation.' -ForegroundColor Red
            throw
        }
    }

    # -- STEP 2: Authentication ---------------------------------------------------
    $authOk = Connect-INTGraphAccount `
        -TenantId $TenantId `
        -NonInteractive:$NonInteractive `
        -RequestedAuthMethod $AuthMethod `
        -ApplicationId $ApplicationId `
        -CertificateThumbprint $CertificateThumbprint `
        -ServicePrincipalCredential $ServicePrincipalCredential `
        -Scopes $RequiredGraphScopes `
        -WizardSession:$WizardSession

    if (-not $authOk) {
        Add-INTCheckResult `
            -Category 'Authentication' `
            -CheckName 'Microsoft Graph Login' `
            -Result 'FAIL' `
            -Details 'Authentication did not produce a valid Microsoft Graph context. All tenant checks will be skipped.' `
            -Roadblock 'Without an authenticated Graph session, no tenant setting can be read.' `
            -HowToFix 'Run: Connect-MgGraph -TenantId <tenant> -Scopes Directory.Read.All,DeviceManagementServiceConfig.Read.All  then rerun, or pass -AuthMethod Interactive.'

        Write-Host ''
        Write-Host '[ ABORT ] Authentication failed. Cannot proceed with tenant validation.' -ForegroundColor Red
        throw 'Authentication failed. Aborting remaining checks.'
    }

    Test-INTGraphPermissions -RequiredScopes $RequiredGraphScopes

    # -- STEP 3: Tenant & Intune Service ------------------------------------------
    Test-INTTenantReadiness

    # -- STEP 4: Licensing --------------------------------------------------------
    Test-INTLicensing

    # -- STEP 5: Device Registration & Automatic Enrollment -----------------------
    Test-INTDeviceRegistration -Platforms $Platform

    # -- STEP 6: Enrollment Configuration -----------------------------------------
    Test-INTEnrollmentConfiguration -Platforms $Platform

    # -- STEP 7: Compliance & Configuration Policies ------------------------------
    Test-INTPolicyCoverage -Platforms $Platform

    # -- STEP 8: Windows Autopilot ------------------------------------------------
    if ($IncludeAutopilot -and 'Windows' -in $Platform) {
        Test-INTAutopilotReadiness
    } else {
        Write-INTSection -Title 'WINDOWS AUTOPILOT [SKIPPED]'
        Add-INTCheckResult `
            -Category 'Autopilot' `
            -CheckName 'Windows Autopilot' `
            -Result 'SKIP' `
            -Details 'Skipped  -  pass -IncludeAutopilot (with Windows selected) to validate Autopilot'
    }

    # -- STEP 9: Platform Connectors ----------------------------------------------
    Test-INTPlatformConnectors -Platforms $Platform

    # -- STEP 10: Conditional Access ----------------------------------------------
    Test-INTConditionalAccess

    # -- STEP 11: Administrative Roles --------------------------------------------
    Test-INTAdministrativeRoles

    # -- STEP 12: Endpoint Connectivity -------------------------------------------
    if (-not $SkipConnectivityTests) {
        Test-INTEndpointConnectivity
    } else {
        Write-INTSection -Title 'CORE INTUNE ENDPOINT CONNECTIVITY [SKIPPED]'
        Add-INTCheckResult `
            -Category 'Connectivity' `
            -CheckName 'Endpoint Connectivity Tests' `
            -Result 'SKIP' `
            -Details 'Skipped via -SkipConnectivityTests'
    }

    # ==========================================================================
    # RESULTS SUMMARY
    # ==========================================================================

    $summary = Get-INTValidationSummary

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
    Write-Host ''

    if ($summary.FailCount -eq 0 -and $summary.WarnCount -eq 0) {
        Write-Host '  VERDICT: [PASS] ALL CHECKS PASSED  -  Tenant appears READY for Intune enrollment.' -ForegroundColor Green
    } elseif ($summary.FailCount -eq 0) {
        Write-Host "  VERDICT: [WARN] No critical blockers found but $($summary.WarnCount) warning(s) detected." -ForegroundColor Yellow
        Write-Host '           Review warnings before enrolling production devices.' -ForegroundColor Yellow
    } else {
        $script:ProcessExitCode = 1
        Write-Host "  VERDICT: [FAIL] $($summary.FailCount) CRITICAL FAILURE(S) detected." -ForegroundColor Red
        Write-Host '           These MUST be resolved before devices can enroll in Intune.' -ForegroundColor Red
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
            $exportPaths = Export-INTValidationReport -OutputPath $ReportPath
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
    Add-INTCheckResult `
        -Category 'Execution' `
        -CheckName 'Readiness Check Execution' `
        -Result 'FAIL' `
        -Details $executionError `
        -Roadblock 'The readiness assessment did not complete, so Intune readiness is unknown.' `
        -HowToFix 'Resolve the reported authentication, module, or runtime error and run the assessment again.'
    Write-Host "  EXECUTION FAILED: $executionError" -ForegroundColor Red
}
finally {
    if (-not $NoExport -and -not $script:ReportExported -and -not $script:RecoveredByChildProcess -and $script:ValidationResults.Count -gt 0 -and (Get-Command -Name Export-Excel -ErrorAction SilentlyContinue)) {
        try {
            $fallbackExport = Export-INTValidationReport -OutputPath $script:ReportRootPath
            $script:ReportExported = $true
            Write-Host "  Excel (fallback): $($fallbackExport.ExcelPath)" -ForegroundColor Cyan
        } catch {
            Write-Host "  WARNING: Fallback report export failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    Invoke-INTModuleCleanup -PreflightResult $preflight_Result
}

$global:LASTEXITCODE = $script:ProcessExitCode

# Return structured results for callers without terminating their PowerShell process.
if ($PassThru) {
    if ($null -eq $summary) {
        $summary = Get-INTValidationSummary
    }
    return $summary
}

if ($NonInteractive) {
    exit $script:ProcessExitCode
}
