<#
.SYNOPSIS
Creates an Azure Virtual Desktop (AVD) Scaling Plan baseline for pooled host pools.

.DESCRIPTION
This script creates an AVD scaling plan and (optionally) a default pooled schedule.
It follows the same interactive/non-interactive style used in the AVD automation scripts.

.PREREQS
- Az.Accounts
- Az.Resources
- Az.DesktopVirtualization

.EXAMPLE
.\21_AVD_Create_ScallingPlan.ps1 -SubscriptionId "<sub-id>" -ResourceGroupName "rg-avd" -HostPoolName "hp-prod" -ScalingPlanName "sp-hp-prod" -Verbose

.EXAMPLE
.\21_AVD_Create_ScallingPlan.ps1 -SubscriptionId "<sub-id>" -ResourceGroupName "rg-avd" -HostPoolName "hp-prod" -ScalingPlanName "sp-hp-prod" -TimeZone "Pacific Standard Time" -SkipSchedule -NonInteractive -WhatIf

.NOTES
Author: edthefixer
Version: 1.1.0
Last Updated: March 2026
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
	[Parameter(Mandatory = $false)]
	[string]$SubscriptionId,

	[Parameter(Mandatory = $false)]
	[string]$ResourceGroupName,

	[Parameter(Mandatory = $false)]
	[string]$HostPoolName,

	[Parameter(Mandatory = $false)]
	[string]$ScalingPlanName,

	[Parameter(Mandatory = $false)]
	[string]$Location,

	[Parameter(Mandatory = $false)]
	[string]$TimeZone,

	[Parameter(Mandatory = $false)]
	[ValidateSet('Pooled','Personal')]
	[string]$HostPoolType = 'Pooled',

	[Parameter(Mandatory = $false)]
	[string]$FriendlyName,

	[Parameter(Mandatory = $false)]
	[string]$Description = 'AVD Scaling Plan',

	[Parameter(Mandatory = $false)]
	[string]$ScheduleName = 'Weekdays',

	[Parameter(Mandatory = $false)]
	[switch]$SkipSchedule,

	[Parameter(Mandatory = $false)]
	[switch]$SkipPrereqValidation,

	[Parameter(Mandatory = $false)]
	[switch]$FailOnPrereqWarnings,

	[Parameter(HelpMessage = 'Run in non-interactive mode')]
	[switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

function Select-AuthenticationMethod {
	if ($NonInteractive) {
		Write-Host 'Non-interactive mode: using Interactive Browser Login.' -ForegroundColor Yellow
		return 'Interactive'
	}

	Write-Host ''
	Write-Host 'Please select your preferred Azure authentication method:' -ForegroundColor White
	Write-Host ''
	Write-Host '  1. Interactive Browser Login (Default)' -ForegroundColor White
	Write-Host '  2. Device Code Authentication' -ForegroundColor White
	Write-Host '  3. Managed Identity' -ForegroundColor White
	Write-Host ''

	do {
		$selection = Read-Host 'Please select an authentication method (1-3) [Default: 1]'
		if ([string]::IsNullOrWhiteSpace($selection)) {
			$selection = '1'
		}

		$selectionInt = 0
		$validSelection = [int]::TryParse($selection, [ref]$selectionInt) -and
			$selectionInt -ge 1 -and $selectionInt -le 3

		if (-not $validSelection) {
			Write-Host 'Invalid selection. Please enter a number between 1 and 3.' -ForegroundColor Red
		}
	} while (-not $validSelection)

	$authMethods = @{
		1 = 'Interactive'
		2 = 'DeviceCode'
		3 = 'ManagedIdentity'
	}

	return $authMethods[$selectionInt]
}

function Invoke-AzureAuthentication {
	param(
		[Parameter(Mandatory = $true)]
		[string]$AuthMethod
	)

	switch ($AuthMethod) {
		'Interactive' {
			Connect-AzAccount | Out-Null
		}
		'DeviceCode' {
			Connect-AzAccount -UseDeviceAuthentication | Out-Null
		}
		'ManagedIdentity' {
			Connect-AzAccount -Identity | Out-Null
		}
		default {
			throw "Unknown authentication method: $AuthMethod"
		}
	}
}

function Connect-AzureWithRetry {
	Write-Host ''
	Write-Host ('=' * 100) -ForegroundColor White
	Write-Host ' Azure Authentication ' -ForegroundColor White
	Write-Host ('=' * 100) -ForegroundColor White
	Write-Host ''

	try {
		Clear-AzContext -Force -ErrorAction SilentlyContinue
		Disconnect-AzAccount -ErrorAction SilentlyContinue
	}
	catch { }

	$selectedAuthMethod = Select-AuthenticationMethod

	try {
		Invoke-AzureAuthentication -AuthMethod $selectedAuthMethod
		$context = Get-AzContext
		if (-not $context) {
			throw 'Authentication succeeded but no Azure context was established.'
		}

		Write-Host '[SUCCESS] Authenticated to Azure.' -ForegroundColor Green
		Write-Host "  Account: $($context.Account.Id)" -ForegroundColor Gray
		Write-Host "  Tenant : $($context.Tenant.Id)" -ForegroundColor Gray
	}
	catch {
		Write-Host "[ERROR] Authentication failed: $($_.Exception.Message)" -ForegroundColor Red
		if (-not $NonInteractive) {
			$retry = Read-Host "Enter 'y' to retry, or any other key to exit"
			if ($retry.ToLower() -eq 'y') {
				Connect-AzureWithRetry
				return
			}
		}
		throw
	}
}

function Select-SubscriptionIfNeeded {
	if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
		return
	}

	$subscriptions = Get-AzSubscription
	if ($subscriptions.Count -eq 0) {
		throw 'No subscriptions found for the authenticated account.'
	}

	if ($subscriptions.Count -eq 1) {
		$script:SubscriptionId = $subscriptions[0].Id
		Write-Host "Using subscription: $($subscriptions[0].Name) ($SubscriptionId)" -ForegroundColor Green
		return
	}

	if ($NonInteractive) {
		$script:SubscriptionId = $subscriptions[0].Id
		Write-Host "Non-interactive mode: using first subscription $($subscriptions[0].Name) ($SubscriptionId)" -ForegroundColor Yellow
		return
	}

	Write-Host ''
	Write-Host 'Available subscriptions:' -ForegroundColor Cyan
	for ($i = 0; $i -lt $subscriptions.Count; $i++) {
		Write-Host "  $($i + 1). $($subscriptions[$i].Name)" -ForegroundColor White
		Write-Host "      ID: $($subscriptions[$i].Id)" -ForegroundColor Gray
	}

	do {
		$selection = Read-Host "Select subscription (1-$($subscriptions.Count))"
		$selectionInt = 0
		$validSelection = [int]::TryParse($selection, [ref]$selectionInt) -and
			$selectionInt -ge 1 -and $selectionInt -le $subscriptions.Count
		if (-not $validSelection) {
			Write-Host "Invalid selection. Please enter a number between 1 and $($subscriptions.Count)." -ForegroundColor Red
		}
	} while (-not $validSelection)

	$script:SubscriptionId = $subscriptions[$selectionInt - 1].Id
}

function Select-ResourceGroupIfNeeded {
	if (-not [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
		return
	}

	$resourceGroups = Get-AzResourceGroup | Sort-Object ResourceGroupName
	if ($resourceGroups.Count -eq 0) {
		throw 'No resource groups found in the selected subscription.'
	}

	if ($NonInteractive) {
		$script:ResourceGroupName = $resourceGroups[0].ResourceGroupName
		Write-Host "Non-interactive mode: using first resource group $ResourceGroupName" -ForegroundColor Yellow
		return
	}

	Write-Host ''
	Write-Host 'Available resource groups:' -ForegroundColor Cyan
	for ($i = 0; $i -lt $resourceGroups.Count; $i++) {
		Write-Host "  $($i + 1). $($resourceGroups[$i].ResourceGroupName)" -ForegroundColor White
		Write-Host "      Location: $($resourceGroups[$i].Location)" -ForegroundColor Gray
	}

	do {
		$selection = Read-Host "Select resource group (1-$($resourceGroups.Count))"
		$selectionInt = 0
		$validSelection = [int]::TryParse($selection, [ref]$selectionInt) -and
			$selectionInt -ge 1 -and $selectionInt -le $resourceGroups.Count
		if (-not $validSelection) {
			Write-Host "Invalid selection. Please enter a number between 1 and $($resourceGroups.Count)." -ForegroundColor Red
		}
	} while (-not $validSelection)

	$script:ResourceGroupName = $resourceGroups[$selectionInt - 1].ResourceGroupName
}

function Select-HostPoolIfNeeded {
	if (-not [string]::IsNullOrWhiteSpace($HostPoolName)) {
		return
	}

	$hostPools = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType 'Microsoft.DesktopVirtualization/hostPools' |
		Sort-Object Name

	if ($hostPools.Count -eq 0) {
		throw "No host pools found in resource group '$ResourceGroupName'."
	}

	if ($NonInteractive) {
		$script:HostPoolName = $hostPools[0].Name
		Write-Host "Non-interactive mode: using first host pool $HostPoolName" -ForegroundColor Yellow
		return
	}

	Write-Host ''
	Write-Host "Available host pools in '$ResourceGroupName':" -ForegroundColor Cyan
	for ($i = 0; $i -lt $hostPools.Count; $i++) {
		Write-Host "  $($i + 1). $($hostPools[$i].Name)" -ForegroundColor White
		Write-Host "      Location: $($hostPools[$i].Location)" -ForegroundColor Gray
	}

	do {
		$selection = Read-Host "Select host pool (1-$($hostPools.Count))"
		$selectionInt = 0
		$validSelection = [int]::TryParse($selection, [ref]$selectionInt) -and
			$selectionInt -ge 1 -and $selectionInt -le $hostPools.Count
		if (-not $validSelection) {
			Write-Host "Invalid selection. Please enter a number between 1 and $($hostPools.Count)." -ForegroundColor Red
		}
	} while (-not $validSelection)

	$script:HostPoolName = $hostPools[$selectionInt - 1].Name
}

function Select-TimeZoneIfNeeded {
	if (-not [string]::IsNullOrWhiteSpace($TimeZone)) {
		return
	}

	if ($NonInteractive) {
		$script:TimeZone = 'UTC'
		Write-Host 'Non-interactive mode: using default time zone UTC.' -ForegroundColor Yellow
		return
	}

	$tzList = [System.TimeZoneInfo]::GetSystemTimeZones() | Select-Object -ExpandProperty Id
	Write-Host ''
	Write-Host 'Select a time zone for the scaling plan.' -ForegroundColor White
	Write-Host 'Press Enter to use UTC, or type an exact Windows Time Zone Id.' -ForegroundColor Gray
	Write-Host ''
	Write-Host 'Example values:' -ForegroundColor Cyan
	$tzList | Select-Object -First 10 | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }

	$inputTz = Read-Host 'Time Zone [Default: UTC]'
	if ([string]::IsNullOrWhiteSpace($inputTz)) {
		$script:TimeZone = 'UTC'
		return
	}

	if ($tzList -contains $inputTz) {
		$script:TimeZone = $inputTz
		return
	}

	throw "Invalid time zone '$inputTz'. Provide a valid Windows Time Zone Id."
}

function Resolve-LocationIfNeeded {
	if (-not [string]::IsNullOrWhiteSpace($Location)) {
		return
	}

	$rg = Get-AzResourceGroup -Name $ResourceGroupName
	if (-not $rg) {
		throw "Resource group '$ResourceGroupName' not found."
	}

	$script:Location = $rg.Location
}

function Resolve-ScalingPlanNameIfNeeded {
	if (-not [string]::IsNullOrWhiteSpace($ScalingPlanName)) {
		return
	}

	$script:ScalingPlanName = "$HostPoolName-sp"
}

function Resolve-FriendlyNameIfNeeded {
	if (-not [string]::IsNullOrWhiteSpace($FriendlyName)) {
		return
	}

	$script:FriendlyName = $ScalingPlanName
}

function Test-RequiredModules {
	$requiredModules = @('Az.Accounts', 'Az.Resources', 'Az.DesktopVirtualization')
	foreach ($moduleName in $requiredModules) {
		if (-not (Get-Module -ListAvailable -Name $moduleName)) {
			throw "Required module '$moduleName' is not installed or available in PSModulePath."
		}
	}
}

function Add-PrereqResult {
	param(
		[Parameter(Mandatory = $true)]
		[object]$Results,
		[Parameter(Mandatory = $true)]
		[ValidateSet('Pass','Warn','Fail')]
		[string]$Status,
		[Parameter(Mandatory = $true)]
		[string]$Check,
		[Parameter(Mandatory = $true)]
		[string]$Message
	)

	$entry = [PSCustomObject]@{
		Status  = $Status
		Check   = $Check
		Message = $Message
	}

	if ($Results -is [System.Collections.IList]) {
		$Results.Add($entry) | Out-Null
		return
	}

	throw 'Add-PrereqResult expected a mutable list for parameter Results.'
}

function Test-AVDScalingPlanPrerequisites {
	param(
		[Parameter(Mandatory = $true)]
		[object]$HostPoolResource
	)

	Write-Host ''
	Write-Host ('=' * 100) -ForegroundColor White
	Write-Host ' Prerequisite Validation ' -ForegroundColor White
	Write-Host ('=' * 100) -ForegroundColor White
	Write-Host ''

	$results = New-Object 'System.Collections.Generic.List[object]'

	$requiredProviders = @(
		'Microsoft.DesktopVirtualization',
		'Microsoft.Compute',
		'Microsoft.Network'
	)

	foreach ($providerNamespace in $requiredProviders) {
		try {
			$provider = Get-AzResourceProvider -ProviderNamespace $providerNamespace -ErrorAction Stop
			if ($provider.RegistrationState -eq 'Registered') {
				Add-PrereqResult -Results $results -Status 'Pass' -Check "Provider $providerNamespace" -Message 'Registered'
			}
			else {
				Add-PrereqResult -Results $results -Status 'Fail' -Check "Provider $providerNamespace" -Message "Not registered (current state: $($provider.RegistrationState))."
			}
		}
		catch {
			Add-PrereqResult -Results $results -Status 'Fail' -Check "Provider $providerNamespace" -Message "Unable to query provider state: $($_.Exception.Message)"
		}
	}

	$avdServicePrincipal = $null
	try {
		$avdServicePrincipal = Get-AzADServicePrincipal -DisplayName 'Azure Virtual Desktop' -ErrorAction SilentlyContinue
		if (-not $avdServicePrincipal) {
			$avdServicePrincipal = Get-AzADServicePrincipal -DisplayName 'aadapp_AzureVirtualDesktop' -ErrorAction SilentlyContinue
		}
		if (-not $avdServicePrincipal) {
			$avdServicePrincipal = Get-AzADServicePrincipal -All | Where-Object {
				$_.DisplayName -match 'Azure Virtual Desktop|aadapp_AzureVirtualDesktop'
			} | Select-Object -First 1
		}

		if ($avdServicePrincipal -is [System.Array]) {
			$avdServicePrincipal = $avdServicePrincipal[0]
		}

		if ($avdServicePrincipal) {
			Add-PrereqResult -Results $results -Status 'Pass' -Check 'Enterprise app' -Message "Found service principal '$($avdServicePrincipal.DisplayName)' ($($avdServicePrincipal.Id))."
		}
		else {
			Add-PrereqResult -Results $results -Status 'Fail' -Check 'Enterprise app' -Message 'Azure Virtual Desktop service principal was not found in Entra ID.'
		}
	}
	catch {
		Add-PrereqResult -Results $results -Status 'Warn' -Check 'Enterprise app' -Message "Could not fully validate service principal: $($_.Exception.Message)"
	}

	$scopeHostPool = $HostPoolResource.ResourceId
	$scopeResourceGroup = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
	$scopeSubscription = "/subscriptions/$SubscriptionId"
	$rbacScopes = @($scopeHostPool, $scopeResourceGroup, $scopeSubscription)

	$requiredAvdSpRoles = @('Desktop Virtualization Contributor', 'Desktop Virtualization Power On Off Contributor')
	if ($avdServicePrincipal) {
		try {
			$spAssignments = @()
			foreach ($scope in $rbacScopes) {
				$scopeAssignments = Get-AzRoleAssignment -ObjectId $avdServicePrincipal.Id -Scope $scope -ErrorAction SilentlyContinue
				if ($scopeAssignments) {
					$spAssignments += $scopeAssignments
				}
			}

			$matchedSpRole = $spAssignments | Where-Object { $_.RoleDefinitionName -in $requiredAvdSpRoles } | Select-Object -First 1
			if ($matchedSpRole) {
				Add-PrereqResult -Results $results -Status 'Pass' -Check 'AVD enterprise app RBAC' -Message "Role '$($matchedSpRole.RoleDefinitionName)' found at scope '$($matchedSpRole.Scope)'."
			}
			else {
				Add-PrereqResult -Results $results -Status 'Warn' -Check 'AVD enterprise app RBAC' -Message 'No Desktop Virtualization role assignment was found for the AVD enterprise app at host pool/RG/subscription scope.'
			}
		}
		catch {
			Add-PrereqResult -Results $results -Status 'Warn' -Check 'AVD enterprise app RBAC' -Message "Could not validate role assignments for AVD enterprise app: $($_.Exception.Message)"
		}
	}

	$ctx = Get-AzContext
	$signedInAccountId = $ctx.Account.Id
	$signedInObjectId = $null

	try {
		if ($ctx.Account.Type -eq 'User') {
			$userObject = Get-AzADUser -UserPrincipalName $signedInAccountId -ErrorAction SilentlyContinue
			if ($userObject) {
				$signedInObjectId = $userObject.Id
			}
		}
		elseif ($ctx.Account.Type -eq 'ServicePrincipal') {
			$spObject = Get-AzADServicePrincipal -ApplicationId $signedInAccountId -ErrorAction SilentlyContinue
			if ($spObject) {
				$signedInObjectId = $spObject.Id
			}
		}
	}
	catch {
		Add-PrereqResult -Results $results -Status 'Warn' -Check 'Signed-in principal lookup' -Message "Could not resolve object id for signed-in account '$signedInAccountId': $($_.Exception.Message)"
	}

	if (-not $signedInObjectId) {
		Add-PrereqResult -Results $results -Status 'Warn' -Check 'Signed-in principal lookup' -Message "Could not resolve object id for signed-in account '$signedInAccountId'. RBAC check for current identity was skipped."
	}
	else {
		$requiredExecutorRoles = @('Owner', 'Contributor', 'Desktop Virtualization Contributor')
		try {
			$executorAssignments = @()
			foreach ($scope in $rbacScopes) {
				$scopeAssignments = Get-AzRoleAssignment -ObjectId $signedInObjectId -Scope $scope -ErrorAction SilentlyContinue
				if ($scopeAssignments) {
					$executorAssignments += $scopeAssignments
				}
			}

			$matchedExecutorRole = $executorAssignments | Where-Object { $_.RoleDefinitionName -in $requiredExecutorRoles } | Select-Object -First 1
			if ($matchedExecutorRole) {
				Add-PrereqResult -Results $results -Status 'Pass' -Check 'Current identity RBAC' -Message "Role '$($matchedExecutorRole.RoleDefinitionName)' found at scope '$($matchedExecutorRole.Scope)'."
			}
			else {
				Add-PrereqResult -Results $results -Status 'Fail' -Check 'Current identity RBAC' -Message "No required role (Owner/Contributor/Desktop Virtualization Contributor) found for '$signedInAccountId' at host pool/RG/subscription scope."
			}
		}
		catch {
			Add-PrereqResult -Results $results -Status 'Warn' -Check 'Current identity RBAC' -Message "Could not validate role assignments for signed-in account: $($_.Exception.Message)"
		}
	}

	Write-Host 'Validation results:' -ForegroundColor Cyan
	foreach ($item in $results) {
		switch ($item.Status) {
			'Pass' { Write-Host "  [PASS] $($item.Check): $($item.Message)" -ForegroundColor Green }
			'Warn' { Write-Host "  [WARN] $($item.Check): $($item.Message)" -ForegroundColor Yellow }
			'Fail' { Write-Host "  [FAIL] $($item.Check): $($item.Message)" -ForegroundColor Red }
		}
	}

	$failCount = ($results | Where-Object { $_.Status -eq 'Fail' }).Count
	$warnCount = ($results | Where-Object { $_.Status -eq 'Warn' }).Count

	if ($failCount -gt 0) {
		throw "Prerequisite validation failed with $failCount error(s). Resolve failures before creating the scaling plan."
	}

	if ($FailOnPrereqWarnings -and $warnCount -gt 0) {
		throw "Prerequisite validation produced $warnCount warning(s) and -FailOnPrereqWarnings is enabled."
	}

	if ($warnCount -gt 0) {
		Write-Host "[INFO] Prerequisite validation completed with $warnCount warning(s)." -ForegroundColor Yellow
	}
	else {
		Write-Host '[SUCCESS] All prerequisite checks passed.' -ForegroundColor Green
	}
}

function Invoke-AVDScalingPlanBaseline {
	[CmdletBinding(SupportsShouldProcess = $true)]
	param()

	$hostPoolResource = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType 'Microsoft.DesktopVirtualization/hostPools' -Name $HostPoolName -ErrorAction SilentlyContinue
	if (-not $hostPoolResource) {
		throw "Host pool '$HostPoolName' was not found in resource group '$ResourceGroupName'."
	}

	$existingPlan = Get-AzWvdScalingPlan -ResourceGroupName $ResourceGroupName -Name $ScalingPlanName -ErrorAction SilentlyContinue
	if ($existingPlan) {
		Write-Host "[INFO] Scaling plan already exists: $ScalingPlanName" -ForegroundColor Yellow
	}
	else {
		$hostPoolReference = @(@{
				HostPoolArmPath    = $hostPoolResource.ResourceId
				ScalingPlanEnabled = $true
			})

		if ($PSCmdlet.ShouldProcess($ScalingPlanName, 'Create AVD scaling plan')) {
			New-AzWvdScalingPlan -ResourceGroupName $ResourceGroupName -Name $ScalingPlanName `
				-Location $Location -FriendlyName $FriendlyName -Description $Description `
				-HostPoolType $HostPoolType -HostPoolReference $hostPoolReference `
				-TimeZone $TimeZone -ErrorAction Stop | Out-Null

			Write-Host "[SUCCESS] Scaling plan created: $ScalingPlanName" -ForegroundColor Green
		}
	}

	if ($SkipSchedule) {
		Write-Host '[INFO] Schedule creation skipped by parameter.' -ForegroundColor Yellow
		return
	}

	$existingSchedule = Get-AzWvdScalingPlanPooledSchedule -ResourceGroupName $ResourceGroupName -ScalingPlanName $ScalingPlanName -ScalingPlanScheduleName $ScheduleName -ErrorAction SilentlyContinue
	if ($existingSchedule) {
		Write-Host "[INFO] Schedule already exists: $ScheduleName" -ForegroundColor Yellow
		return
	}

	if ($HostPoolType -ne 'Pooled') {
		Write-Host '[INFO] Baseline schedule creation currently targets pooled host pools. Use -SkipSchedule for personal pools.' -ForegroundColor Yellow
		return
	}

	if ($PSCmdlet.ShouldProcess($ScheduleName, 'Create pooled scaling schedule')) {
		New-AzWvdScalingPlanPooledSchedule `
			-ResourceGroupName $ResourceGroupName `
			-ScalingPlanName $ScalingPlanName `
			-ScalingPlanScheduleName $ScheduleName `
			-DaysOfWeek @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday') `
			-RampUpStartTimeHour 7 `
			-RampUpStartTimeMinute 0 `
			-PeakStartTimeHour 9 `
			-PeakStartTimeMinute 0 `
			-RampDownStartTimeHour 18 `
			-RampDownStartTimeMinute 0 `
			-OffPeakStartTimeHour 20 `
			-OffPeakStartTimeMinute 0 `
			-RampUpLoadBalancingAlgorithm 'BreadthFirst' `
			-PeakLoadBalancingAlgorithm 'BreadthFirst' `
			-RampDownLoadBalancingAlgorithm 'DepthFirst' `
			-OffPeakLoadBalancingAlgorithm 'DepthFirst' `
			-RampUpMinimumHostsPct 20 `
			-RampDownMinimumHostsPct 10 `
			-RampUpCapacityThresholdPct 60 `
			-RampDownCapacityThresholdPct 90 `
			-RampDownForceLogoffUser:$false `
			-RampDownWaitTimeMinute 30 `
			-RampDownNotificationMessage 'Session ending in 30 minutes.' `
			-ErrorAction Stop | Out-Null

		Write-Host "[SUCCESS] Pooled schedule created: $ScheduleName" -ForegroundColor Green
	}
}

Write-Host ''
Write-Host ('=' * 100) -ForegroundColor White
Write-Host ' AVD Scaling Plan Baseline ' -ForegroundColor White
Write-Host ('=' * 100) -ForegroundColor White
Write-Host ''

Test-RequiredModules
Connect-AzureWithRetry
Select-SubscriptionIfNeeded
Set-AzContext -Subscription $SubscriptionId | Out-Null
Select-ResourceGroupIfNeeded
Select-HostPoolIfNeeded
Resolve-ScalingPlanNameIfNeeded
Resolve-FriendlyNameIfNeeded
Resolve-LocationIfNeeded
Select-TimeZoneIfNeeded

$hostPoolResource = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType 'Microsoft.DesktopVirtualization/hostPools' -Name $HostPoolName -ErrorAction SilentlyContinue
if (-not $hostPoolResource) {
	throw "Host pool '$HostPoolName' was not found in resource group '$ResourceGroupName'."
}

if (-not $SkipPrereqValidation) {
	Test-AVDScalingPlanPrerequisites -HostPoolResource $hostPoolResource
}
else {
	Write-Host '[INFO] Prerequisite validation was skipped by parameter.' -ForegroundColor Yellow
}

Write-Host 'Execution parameters:' -ForegroundColor Cyan
Write-Host "  SubscriptionId : $SubscriptionId" -ForegroundColor Gray
Write-Host "  ResourceGroup  : $ResourceGroupName" -ForegroundColor Gray
Write-Host "  HostPoolName   : $HostPoolName" -ForegroundColor Gray
Write-Host "  ScalingPlan    : $ScalingPlanName" -ForegroundColor Gray
Write-Host "  HostPoolType   : $HostPoolType" -ForegroundColor Gray
Write-Host "  Location       : $Location" -ForegroundColor Gray
Write-Host "  TimeZone       : $TimeZone" -ForegroundColor Gray
Write-Host "  ScheduleName   : $ScheduleName" -ForegroundColor Gray
Write-Host "  SkipSchedule   : $SkipSchedule" -ForegroundColor Gray
Write-Host "  SkipPrereqVal  : $SkipPrereqValidation" -ForegroundColor Gray
Write-Host "  FailOnWarn     : $FailOnPrereqWarnings" -ForegroundColor Gray

Invoke-AVDScalingPlanBaseline

Write-Host ''
Write-Host ('=' * 100) -ForegroundColor White
Write-Host ' Script Completed ' -ForegroundColor White
Write-Host ('=' * 100) -ForegroundColor White
