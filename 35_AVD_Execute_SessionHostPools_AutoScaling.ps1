# Add local _modules folder to PSModulePath for module discovery
$env:PSModulePath = "C:\Devops\PowerShell\Final\_modules;" + $env:PSModulePath

# --- Enhanced Module Validation ---
function Test-RequiredModules {
    $requiredModules = @(
        @{ Name = 'Az.Accounts'; MinVersion = '2.2.0' },
        @{ Name = 'Az.Compute'; MinVersion = '4.11.0' },
        @{ Name = 'Az.Resources'; MinVersion = '1.13.0' },
        @{ Name = 'Az.Network'; MinVersion = '2.2.0' },
        @{ Name = 'Az.DesktopVirtualization'; MinVersion = '3.0.0' }
    )
    $missing = @()
    $outdated = @()
    foreach ($mod in $requiredModules) {
        $found = Get-Module -ListAvailable -Name $mod.Name | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $found) {
            $missing += $mod.Name
        } elseif ([version]$found.Version -lt [version]$mod.MinVersion) {
            $outdated += "$($mod.Name) (found $($found.Version), need $($mod.MinVersion)+)"
        }
    }
    if ($missing.Count -gt 0) {
        Write-Host "[ERROR] Missing required modules: $($missing -join ', ')" -ForegroundColor Red
        Write-Host "Please install them using: Install-Module -Name <ModuleName> -Scope CurrentUser" -ForegroundColor Yellow
        exit 1
    }
    if ($outdated.Count -gt 0) {
        Write-Host "[ERROR] Outdated modules: $($outdated -join ', ')" -ForegroundColor Red
        Write-Host "Please update them using: Update-Module -Name <ModuleName> -Scope CurrentUser" -ForegroundColor Yellow
        exit 1
    }
    return $true
}

# Validate modules before anything else
Test-RequiredModules

# --- Interactive Region Selection (adapted from 01_AVD_Validate_VMSizeAndQuota.ps1) ---
function Select-AzureRegionMenu {
    Write-Host "";
    Write-Host ("="*60) -ForegroundColor White;
    Write-Host " REGION SELECTION " -ForegroundColor White;
    Write-Host ("="*60) -ForegroundColor White;
    Write-Host "";
    try {
        $locations = Get-AzLocation | Where-Object { $_.Providers -contains "Microsoft.Compute" } | Sort-Object DisplayName;
        if (-not $locations) {
            Write-Host "No available regions found." -ForegroundColor Red;
            return $null;
        }
        $popularRegions = @(
            "East US", "East US 2", "West US", "West US 2", "West US 3", "Central US", "South Central US",
            "North Europe", "West Europe", "UK South", "UK West",
            "Southeast Asia", "East Asia", "Australia East", "Australia Southeast",
            "Canada Central", "Canada East", "Japan East", "Japan West"
        );
        $displayRegions = @();
        $showAllRegions = $false;
        do {
            $displayRegions = @(); $displayCount = 0;
            if (-not $showAllRegions) {
                Write-Host "Top 10 Recommended Regions:" -ForegroundColor Green;
                $popularCount = 0;
                foreach ($regionName in $popularRegions) {
                    if ($displayCount -ge 10) { break }
                    $region = $locations | Where-Object { $_.DisplayName -eq $regionName };
                    if ($region) {
                        $displayCount++;
                        Write-Host "  $displayCount. $($region.DisplayName)" -ForegroundColor White;
                        $displayRegions += $region;
                        $popularCount++;
                    }
                }
                if ($displayCount -lt 10) {
                    $otherRegions = $locations | Where-Object { $_.DisplayName -notin $popularRegions } | Select-Object -First (10 - $displayCount);
                    foreach ($region in $otherRegions) {
                        $displayCount++;
                        Write-Host "  $displayCount. $($region.DisplayName)" -ForegroundColor White;
                        $displayRegions += $region;
                    }
                }
                Write-Host "";
                Write-Host "Options:" -ForegroundColor Yellow;
                Write-Host "  Enter 1-$displayCount to select a region" -ForegroundColor Gray;
                Write-Host "  Enter 'more' to see all available regions" -ForegroundColor Gray;
            } else {
                Write-Host "All Available Regions:" -ForegroundColor Green;
                Write-Host "\nPopular Regions:" -ForegroundColor Cyan;
                foreach ($regionName in $popularRegions) {
                    $region = $locations | Where-Object { $_.DisplayName -eq $regionName };
                    if ($region) {
                        $displayCount++;
                        Write-Host "  $displayCount. $($region.DisplayName)" -ForegroundColor White;
                        $displayRegions += $region;
                    }
                }
                Write-Host "\nOther Regions:" -ForegroundColor Cyan;
                $otherRegions = $locations | Where-Object { $_.DisplayName -notin $popularRegions };
                foreach ($region in $otherRegions) {
                    $displayCount++;
                    Write-Host "  $displayCount. $($region.DisplayName)" -ForegroundColor White;
                    $displayRegions += $region;
                }
                Write-Host "";
                Write-Host "Options:" -ForegroundColor Yellow;
                Write-Host "  Enter 1-$displayCount to select a region" -ForegroundColor Gray;
                Write-Host "  Enter 'less' to return to top 10 view" -ForegroundColor Gray;
            }
            Write-Host "";
            Write-Host "Please select an Azure region for AVD deployment:" -ForegroundColor Yellow;
            $selection = Read-Host "Enter your choice";
            if ($selection -eq "more" -and -not $showAllRegions) { $showAllRegions = $true; continue }
            elseif ($selection -eq "less" -and $showAllRegions) { $showAllRegions = $false; continue }
            elseif ([int]::TryParse($selection, [ref]$null)) {
                $selectedIndex = [int]$selection - 1;
                if ($selectedIndex -ge 0 -and $selectedIndex -lt $displayRegions.Count) { break }
                else { Write-Host "Invalid selection. Please enter a number between 1 and $($displayRegions.Count)." -ForegroundColor Red }
            } else {
                if (-not $showAllRegions) { Write-Host "Invalid input. Please enter a number (1-$($displayRegions.Count)) or 'more' to see all regions." -ForegroundColor Red }
                else { Write-Host "Invalid input. Please enter a number (1-$($displayRegions.Count)) or 'less' to return to top 10." -ForegroundColor Red }
            }
        } while ($true);
        $selectedLocation = $displayRegions[$selectedIndex];
        Write-Host "Selected region: $($selectedLocation.DisplayName) ($($selectedLocation.Location))" -ForegroundColor Green;
        return $selectedLocation.Location;
    } catch {
        Write-Host "Failed to select Azure region: $($_.Exception.Message)" -ForegroundColor Red;
        return $null;
    }
}

# --- Interactive VM Size Selection ---
function Select-VMSizeMenu {
    param([string]$Location)
    Write-Host "";
    Write-Host ("="*60) -ForegroundColor White;
    Write-Host " VM SIZE SELECTION " -ForegroundColor White;
    Write-Host ("="*60) -ForegroundColor White;
    Write-Host "";
    try {
        if (-not $Location -or $Location -eq "") {
            Write-Host "[ERROR] No region provided for VM size selection. Aborting." -ForegroundColor Red
            return $null
        }
        $vmSizes = Get-AzVMSize -Location $Location | Sort-Object NumberOfCores, MemoryInMB;
        if (-not $vmSizes) {
            Write-Host "No VM sizes found for region $Location." -ForegroundColor Red;
            return $null;
        }
        $displayCount = 0;
        foreach ($vm in $vmSizes) {
            $displayCount++;
            Write-Host ("  {0}. {1} - {2} vCPUs, {3} GB RAM" -f $displayCount, $vm.Name, $vm.NumberOfCores, [math]::Round($vm.MemoryInMB/1024,1)) -ForegroundColor White;
            if ($displayCount -ge 20) { break } # Show only first 20 by default
        }
        Write-Host "";
        Write-Host "Options:" -ForegroundColor Yellow;
        Write-Host "  Enter 1-$displayCount to select a VM size" -ForegroundColor Gray;
        Write-Host "  Enter 'more' to see all available VM sizes" -ForegroundColor Gray;
        $showAll = $false;
        do {
            $selection = Read-Host "Enter your choice";
            if ($selection -eq "more" -and -not $showAll) {
                $showAll = $true;
                $displayCount = 0;
                foreach ($vm in $vmSizes) {
                    $displayCount++;
                    Write-Host ("  {0}. {1} - {2} vCPUs, {3} GB RAM" -f $displayCount, $vm.Name, $vm.NumberOfCores, [math]::Round($vm.MemoryInMB/1024,1)) -ForegroundColor White;
                }
                Write-Host "";
                Write-Host "Enter 1-$displayCount to select a VM size" -ForegroundColor Gray;
                continue;
            }
            elseif ([int]::TryParse($selection, [ref]$null)) {
                $selectedIndex = [int]$selection - 1;
                if ($selectedIndex -ge 0 -and $selectedIndex -lt $vmSizes.Count) { break }
                else { Write-Host "Invalid selection. Please enter a number between 1 and $($vmSizes.Count)." -ForegroundColor Red }
            } else {
                Write-Host "Invalid input. Please enter a number (1-$($vmSizes.Count)) or 'more' to see all sizes." -ForegroundColor Red
            }
        } while ($true);
        $selectedVM = $vmSizes[$selectedIndex];
        Write-Host "Selected VM size: $($selectedVM.Name) - $($selectedVM.NumberOfCores) vCPUs, $([math]::Round($selectedVM.MemoryInMB/1024,1)) GB RAM" -ForegroundColor Green;
        return $selectedVM.Name;
    } catch {
        Write-Host "Failed to select VM size: $($_.Exception.Message)" -ForegroundColor Red;
        return $null;
    }
}
#---------------------------------------------#
# Session Host Scaling Functions (Production) #
#---------------------------------------------#
function Invoke-SessionHostScaleUp {
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$HostPoolName,
        [Parameter(Mandatory)] [int]$Count,
        [Parameter(Mandatory)] [string]$VMSize,
        [Parameter(Mandatory)] [string]$Location,
        [string]$ConfigJsonPath = $null,
        [hashtable]$ConfigSettings = $null
    )
    # --- Interactive region and VM size selection if not provided ---
    if (-not $Location -or $Location -eq "") {
        $Location = Select-AzureRegionMenu
        if (-not $Location) { Write-Host "Aborting: No region selected." -ForegroundColor Red; return }
    }
    if (-not $VMSize -or $VMSize -eq "") {
        $VMSize = Select-VMSizeMenu -Location $Location
        if (-not $VMSize) { Write-Host "Aborting: No VM size selected." -ForegroundColor Red; return }
    }
    # If config settings provided, use them to override parameters
    $defaultVnetResourceGroup = $null
    if ($ConfigSettings) {
        if ($ConfigSettings.VMSize) { $VMSize = $ConfigSettings.VMSize }
        if ($ConfigSettings.Location) { $Location = $ConfigSettings.Location }
        if ($ConfigSettings.VNet) { $defaultVnet = $ConfigSettings.VNet }
        if ($ConfigSettings.Subnet) { $defaultSubnet = $ConfigSettings.Subnet }
        if ($ConfigSettings.VNetResourceGroup) { $defaultVnetResourceGroup = $ConfigSettings.VNetResourceGroup }
        if ($ConfigSettings.ImageURN) { $imageURN = $ConfigSettings.ImageURN } else { $imageURN = "MicrosoftWindowsServer:WindowsServer:2022-datacenter:latest" }
        if ($ConfigSettings.ResourceGroupName) { $ResourceGroupName = $ConfigSettings.ResourceGroupName }
        $mimicTags = $null; if ($ConfigSettings.Tags) { $mimicTags = $ConfigSettings.Tags }
        $mimicIdentityType = $null; if ($ConfigSettings.IdentityType) { $mimicIdentityType = $ConfigSettings.IdentityType }
        $mimicUserAssignedIdentities = $null; if ($ConfigSettings.UserAssignedIdentities) { $mimicUserAssignedIdentities = $ConfigSettings.UserAssignedIdentities }
    } else {
        # $validProviders = @('Entra ID','Entra ID Kerberos','AD DS')
        $mimicTags = $null; $mimicIdentityType = $null; $mimicUserAssignedIdentities = $null
    }

    # --- Robust Quota Check for VM Family ---
    try {
        $quotaFamily = Get-VMQuotaFamilyName -SkuName $VMSize
        if ($quotaFamily) {
            $quota = Get-AzVMUsage -Location $Location | Where-Object { $_.Name.Value -eq $quotaFamily }
            if ($quota) {
                $current = $quota.CurrentValue
                $limit = $quota.Limit
                $coreCount = Get-VMCoreCount -SkuName $VMSize
                $needed = $Count * $coreCount
                if (($current + $needed) -gt $limit) {
                    Write-Host ("[WARNING] This operation would exceed your quota for {0} in {1}. Current: {2}, Limit: {3}, Needed: {4}." -f $quotaFamily, $Location, $current, $limit, $needed) -ForegroundColor Yellow
                    Write-Host "[HINT] Request a quota increase at: https://aka.ms/ProdportalCRP" -ForegroundColor Yellow
                    Write-Host "Aborting scale-up due to quota limits." -ForegroundColor Red
                    return
                }
            } else {
                Write-Host "[ERROR] Could not determine quota for $VMSize ($quotaFamily) in $Location." -ForegroundColor Red
                Write-Host "[HINT] Check Azure Portal for quota details or request increase: https://aka.ms/ProdportalCRP" -ForegroundColor Yellow
                return
            }
        } else {
            Write-Host "[ERROR] Could not map quota family for $VMSize. Please check SKU and try again." -ForegroundColor Red
            return
        }
    } catch {
        Write-Host "[WARN] Could not check quota for VM family. If you encounter quota errors, check your Azure limits." -ForegroundColor Yellow
    }
    # Helper: Get-VMQuotaFamilyName
    function Get-VMQuotaFamilyName {
        param([string]$SkuName)
        switch -Regex ($SkuName) {
            '^Standard_D\d+as_v5'  { return 'standardDASv5Family' }
            '^Standard_D\d+s_v5'   { return 'standardDSv5Family'  }
            '^Standard_D\d+as_v4'  { return 'standardDASv4Family' }
            '^Standard_D\d+s_v4'   { return 'standardDSv4Family'  }
            '^Standard_D\d+s_v3'   { return 'standardDSv3Family'  }
            '^Standard_E\d+s_v5'   { return 'standardESv5Family'  }
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
    # Helper: Get-VMCoreCount
    function Get-VMCoreCount {
        param([string]$SkuName)
        switch -Regex ($SkuName) {
            '^Standard_B2ms'   { return 2 }
            '^Standard_B4ms'   { return 4 }
            '^Standard_D2s_v3' { return 2 }
            '^Standard_D4s_v3' { return 4 }
            '^Standard_D2s_v5' { return 2 }
            '^Standard_D4s_v5' { return 4 }
            '^Standard_E2s_v3' { return 2 }
            '^Standard_E4s_v3' { return 4 }
            '^Standard_E2s_v5' { return 2 }
            '^Standard_E4s_v5' { return 4 }
            '^Standard_F2s_v2' { return 2 }
            '^Standard_F4s_v2' { return 4 }
            default            { return 2 } # Fallback, adjust as needed
        }
    }
    Write-Host "[INFO] Starting scale UP operation for $Count session hosts in pool $HostPoolName..." -ForegroundColor Cyan
    # --- Robust Pre-checks ---
    # 1. Check required Az modules
    $requiredModules = @('Az.Accounts','Az.Compute','Az.Resources','Az.Network','Az.DesktopVirtualization')
    foreach ($mod in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            Write-Host "[ERROR] Required module $mod is not installed. Please run 'Install-Module $mod -Scope CurrentUser' and restart the script." -ForegroundColor Red
            return
        }
    }
    # 2. Check Azure context and permissions
    try {
        $context = Get-AzContext
        if (-not $context) { throw "No Azure context found. Please authenticate." }
            # $sub = Get-AzSubscription -SubscriptionId $context.Subscription.Id -ErrorAction Stop
    } catch {
        Write-Host "[ERROR] Unable to get Azure context or subscription. Please check your login and permissions." -ForegroundColor Red
        return
    }
    # 3. Check for required permissions (VM Contributor, Network Contributor, Desktop Virtualization Contributor)
    try {
        $roleAssignments = Get-AzRoleAssignment -ObjectId $context.Account.Id -ErrorAction Stop
        $roles = $roleAssignments | Select-Object -ExpandProperty RoleDefinitionName
        $requiredRoles = @('Virtual Machine Contributor','Contributor','Owner','Desktop Virtualization Contributor','Network Contributor')
        $hasRole = $false
        foreach ($r in $requiredRoles) { if ($roles -contains $r) { $hasRole = $true; break } }
        if (-not $hasRole) {
            Write-Host "[ERROR] Your account does not have sufficient permissions (VM Contributor, Network Contributor, or Desktop Virtualization Contributor) in this subscription. Please contact your Azure admin." -ForegroundColor Red
            return
        }
    } catch {
        Write-Host "[WARN] Could not verify role assignments. If you encounter permission errors, check your Azure RBAC roles." -ForegroundColor Yellow
    }
    # 4. Check service provider registration
    $providers = @('Microsoft.Compute','Microsoft.Network','Microsoft.DesktopVirtualization')
    foreach ($prov in $providers) {
        $provState = (Get-AzResourceProvider -ProviderNamespace $prov).RegistrationState
        if ($provState -ne 'Registered') {
            Write-Host "[ERROR] Resource provider $prov is not registered. Please run 'Register-AzResourceProvider -ProviderNamespace $prov' as a user with Owner rights." -ForegroundColor Red
            return
        }
    }
    # Get registration token for the host pool
    $token = Get-AVDRegistrationToken -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName
    if (-not $token -or [string]::IsNullOrWhiteSpace($token)) {
        Write-Host "[ERROR] Registration token for host pool is missing or empty. Cannot proceed with VM registration." -ForegroundColor Red
        Write-Host "[HINT] Ensure you have permission to generate registration tokens and the host pool is healthy." -ForegroundColor Yellow
        return
    } else {
        $maskedToken = if ($token.Length -gt 8) { $token.Substring(0,4) + '...' + $token.Substring($token.Length-4,4) } else { '[short/hidden]' }
        Write-Host "[DEBUG] Registration token to be used (masked): $maskedToken" -ForegroundColor DarkGray
    }
    # Try to discover VNet/Subnet from config or existing VM in the pool
    if (-not $defaultVnet -or -not $defaultSubnet) {
        $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName
        foreach ($sh in $sessionHosts) {
            $vmName = ($sh.Name -split '/')[-1]
            try {
                $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -ErrorAction Stop
                $nicId = $vm.NetworkProfile.NetworkInterfaces[0].Id
                $nic = Get-AzNetworkInterface -ResourceId $nicId
                $ipConfig = $nic.IpConfigurations[0]
                $subnetId = $ipConfig.Subnet.Id
                $subnetParts = $subnetId -split '/'
                $defaultVnet = $subnetParts[8]
                $defaultSubnet = $subnetParts[10]
                $defaultVnetResourceGroup = $subnetParts[4]
                break
            } catch {}
        }
    }
    # Menu-driven or defaulted VNet/Subnet selection
    if (-not $defaultVnet) {
        Write-Host "[INFO] No default VNet detected. Searching all resource groups for available VNets."
        $vnets = Get-AzVirtualNetwork
        if ($vnets.Count -gt 0) {
            $defaultVnet = $vnets[0].Name
            $defaultVnetResourceGroup = $vnets[0].ResourceGroupName
            Write-Host ("[INFO] Using VNet: {0} (Resource Group: {1})" -f $defaultVnet, $vnets[0].ResourceGroupName)
        } else {
            Write-Host "[ERROR] No VNets found in any resource group. Aborting." -ForegroundColor Red
            return
        }
    }
    if (-not $defaultSubnet) {
        $vnetObj = Get-AzVirtualNetwork -ResourceGroupName $defaultVnetResourceGroup -Name $defaultVnet
        if ($vnetObj.Subnets.Count -gt 0) {
            $defaultSubnet = $vnetObj.Subnets[0].Name
            Write-Host ("[INFO] Using Subnet: {0}" -f $defaultSubnet)
        } else {
            Write-Host "[ERROR] No subnets found in VNet $defaultVnet. Aborting." -ForegroundColor Red
            return
        }
    }
    #-------------------#
    # JSON Config Parsing Utility #
    #-------------------#
    function Get-AVDConfigFromJson {
        param([string]$JsonPath)
        if (-not (Test-Path $JsonPath)) {
            Write-Host "[ERROR] JSON config file not found: $JsonPath" -ForegroundColor Red
            return $null
        }
        try {
            $json = Get-Content $JsonPath -Raw | ConvertFrom-Json
            $settings = @{}
            if ($json.SessionHosts.VMSize) { $settings.VMSize = $json.SessionHosts.VMSize }
            if ($json.AzureContext.Location) { $settings.Location = $json.AzureContext.Location }
            if ($json.Networking.VNet) { $settings.VNet = $json.Networking.VNet }
            if ($json.Networking.Subnet) { $settings.Subnet = $json.Networking.Subnet }
            if ($json.SessionHosts.ImageURN) { $settings.ImageURN = $json.SessionHosts.ImageURN }
            return $settings
        } catch {
            Write-Host "[ERROR] Failed to parse JSON config: $($_.Exception.Message)" -ForegroundColor Red
            return $null
        }
    }
    # Define VM base name
    # Determine VM base name from existing session hosts for consistent naming
    $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName
    $existingVmNames = @()
    foreach ($sh in $sessionHosts) {
        $vmName = (($sh.Name -split '/')[-1] -split '\.')[0]
        $existingVmNames += $vmName
    }
    # Try to extract base pattern and numeric suffix (e.g., prefix, separator, 001, 002, ...)
    $baseName = "$HostPoolName-sh-" # default
    $numericSuffix = $false
    $maxNum = 0
    $suffixWidth = 3
    if ($existingVmNames.Count -gt 0) {
        # Look for names ending in a numeric suffix (e.g., ...-001, ...0001)
        $nameMatches = $existingVmNames | ForEach-Object {
            if ($_ -match '^(.*?)(\d+)$') {
                [PSCustomObject]@{
                    Prefix = $Matches[1]
                    Num    = [int]$Matches[2]
                    Width  = $Matches[2].Length
                }
            }
        }
        if ($nameMatches -and $nameMatches.Count -gt 0) {
            $baseName = ($nameMatches | Group-Object Prefix | Sort-Object Count -Descending | Select-Object -First 1).Name
            $numericSuffix = $true
            $prefixMatches = $nameMatches | Where-Object { $_.Prefix -eq $baseName }
            $widthGroup = $prefixMatches | Group-Object Width | Sort-Object Count -Descending | Select-Object -First 1
            if ($widthGroup) { $suffixWidth = [int]$widthGroup.Name }
            if ($suffixWidth -lt 1) { $suffixWidth = 3 }
            $nums = $prefixMatches | Select-Object -ExpandProperty Num
            if ($nums -and $nums.Count -gt 0) {
                $maxNum = ($nums | Measure-Object -Maximum).Maximum
                if (-not $maxNum) { $maxNum = 0 }
            } else {
                $maxNum = 0
            }
        } else {
            # Fallback to previous logic (hex/other)
            $patterns = $existingVmNames | ForEach-Object { $_ -replace '[0-9a-fA-F]{6,}$','' } | ForEach-Object { $_ -replace '[-_]+$','' }
            $baseName = ($patterns | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
            if ($baseName -and $baseName -notmatch '[-_]$') { $baseName = "$baseName-" }
            if (-not $baseName) { $baseName = "$HostPoolName-sh-" }
        }
    }

    # Prompt for local admin credentials ONCE
    $cred = Get-Credential -Message "Enter local admin credentials for all new session hosts"
    # Prompt for identity provider (Entra ID, Entra ID Kerberos, AD DS)
    $identityProvider = $null
    $validProviders = @('Entra ID','Entra ID Kerberos','AD DS')
    # Try to auto-detect identity provider from config or context
    if ($ConfigSettings -and $ConfigSettings.IdentityProvider) {
        $identityProvider = $ConfigSettings.IdentityProvider
        Write-Host ("[INFO] Detected identity provider from config: {0}. This will be used for this run." -f $identityProvider) -ForegroundColor Cyan
    } else {
        # Default to Entra ID if known (e.g., from host pool or context)
        $defaultProvider = 'Entra ID'
        Write-Host ("[INFO] Defaulting to identity provider: {0} (based on detected context)." -f $defaultProvider) -ForegroundColor Cyan
        $identityProvider = $defaultProvider
        # If you want to prompt only if not Entra ID, comment out the next line and uncomment the prompt block
        # do {
        #     Write-Host "Select identity provider for new session hosts:" -ForegroundColor Cyan
        #     Write-Host "  1. Entra ID (Azure AD Join)" -ForegroundColor Green
        #     Write-Host "  2. Entra ID Kerberos" -ForegroundColor Yellow
        #     Write-Host "  3. AD DS (Active Directory Domain Services)" -ForegroundColor White
        #     $idChoice = Read-Host "Enter your choice (1, 2, or 3) [Default: 1]"
        #     if ([string]::IsNullOrWhiteSpace($idChoice)) { $idChoice = '1' }
        #     if ($idChoice -in '1','2','3') { $identityProvider = $validProviders[[int]$idChoice-1] }
        # } while (-not $identityProvider)
    }

    for ($i = 1; $i -le $Count; $i++) {
        # Use numeric incrementing naming with inferred width if detected, else fallback to hex
        $vmName = $null
        $suffix = $null
        try {
            if ($numericSuffix) {
                $nextNum = [int]($maxNum + $i)
                if ($nextNum -lt 1) { $nextNum = 1 }
                $suffix = ("{0:D$($suffixWidth)}" -f $nextNum)
                $vmName = "$baseName$suffix"
            } else {
                # Find next available hex suffix for VM name
                $escapedBaseName = [regex]::Escape($baseName)
                $existingSuffixes = $existingVmNames | ForEach-Object { $_ -replace "^$escapedBaseName", '' }
                $usedNumbers = $existingSuffixes | Where-Object { $_ -match '^[0-9a-fA-F]+$' } | ForEach-Object { [convert]::ToInt32($_,16) } | Sort-Object
                $nextNum = 1
                while ($usedNumbers -contains $nextNum) { $nextNum++ }
                $suffix = ('{0:x8}' -f $nextNum)
                if ($baseName -match '[-_]$') { $vmName = "$baseName$suffix" }
                else { $vmName = "$baseName-$suffix" }
            }
        } catch {
            Write-Host "[WARN] Could not determine numeric VM naming pattern. Falling back to default." -ForegroundColor Yellow
            $vmName = "$HostPoolName-sh-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
            $suffix = $vmName -replace '^.*-',''
        }
        # Set computer name to match VM name for consistency between Azure VM and AVD Session Host Pool
        $computerName = $vmName
        Write-Host "[INFO] Creating VM: $vmName ($VMSize) in $Location..." -ForegroundColor Yellow
        # Parse image URN (Publisher:Offer:Sku:Version)
        $imgParts = $imageURN -split ':'
        if ($imgParts.Count -ne 4) {
            Write-Host "[ERROR] Invalid image URN: $imageURN" -ForegroundColor Red
            return
        }
        # Ensure VNet resource group is set
        if (-not $defaultVnetResourceGroup -and $ConfigSettings -and $ConfigSettings.VNetResourceGroup) {
            $defaultVnetResourceGroup = $ConfigSettings.VNetResourceGroup
        }
        if (-not $defaultVnetResourceGroup) {
            Write-Host "[ERROR] VNet resource group is not set. Cannot create NIC/VM. Please check mimic logic or provide VNet resource group manually." -ForegroundColor Red
            return
        }
        # Create NIC first
        $nicName = "nic-$vmName"
        $nic = New-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName -Location $Location -SubnetId (
            (Get-AzVirtualNetwork -Name $defaultVnet -ResourceGroupName $defaultVnetResourceGroup).Subnets | Where-Object { $_.Name -eq $defaultSubnet }
        ).Id -ErrorAction Stop
        # Build VM config with explicit OS disk and image
        $vmConfig = New-AzVMConfig -VMName $vmName -VMSize $VMSize |
            Set-AzVMOperatingSystem -Windows -ComputerName $computerName -Credential $cred -ProvisionVMAgent -EnableAutoUpdate |
            Set-AzVMSourceImage -PublisherName $imgParts[0] -Offer $imgParts[1] -Skus $imgParts[2] -Version $imgParts[3] |
            Set-AzVMOSDisk -StorageAccountType "Standard_LRS" -CreateOption FromImage |
            Add-AzVMNetworkInterface -Id $nic.Id
        $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Disable
        # Do NOT set -SecurityType to avoid Trusted Launch errors
        try {
            $vm = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vmConfig -ErrorAction Stop
            Write-Host "[SUCCESS] VM $vmName created (ComputerName: $computerName)." -ForegroundColor Green
            # Post-creation: Identity and Extensions
            if ($identityProvider -eq 'Entra ID' -or $identityProvider -eq 'Entra ID Kerberos') {
                # Enable system-assigned managed identity
                try {
                    $vmObj = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -ErrorAction Stop
                    Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vmObj -IdentityType SystemAssigned -ErrorAction Stop | Out-Null
                    Write-Host "[INFO] Managed Identity enabled for $vmName" -ForegroundColor Cyan
                } catch { Write-Host "[WARN] Could not enable managed identity: $($_.Exception.Message)" -ForegroundColor Yellow }
                # Install AADLoginForWindows extension
                try {
                    Set-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $vmName -Name 'AADLoginForWindows' -Publisher 'Microsoft.Azure.ActiveDirectory' -ExtensionType 'AADLoginForWindows' -TypeHandlerVersion '2.0' -Location $Location -ErrorAction Stop | Out-Null
                    Write-Host "[INFO] AADLoginForWindows extension installed for $vmName" -ForegroundColor Cyan
                } catch { Write-Host "[WARN] Could not install AADLoginForWindows extension: $($_.Exception.Message)" -ForegroundColor Yellow }
            } elseif ($identityProvider -eq 'AD DS') {
                # Install domain join extension (if needed)
                try {
                    Set-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $vmName -Name 'joindomain' -Publisher 'Microsoft.Compute' -ExtensionType 'JsonADDomainExtension' -TypeHandlerVersion '1.3' -Location $Location -Settings @{ 'Name' = '<YOUR_DOMAIN>'; 'OUPath' = '<YOUR_OU>'; 'User' = '<DOMAIN_USER>'; 'Restart' = 'true' } -ProtectedSettings @{ 'Password' = '<DOMAIN_PASSWORD>' } -ErrorAction Stop | Out-Null
                    Write-Host "[INFO] Domain join extension installed for $vmName (update settings as needed)" -ForegroundColor Cyan
                } catch { Write-Host "[WARN] Could not install domain join extension: $($_.Exception.Message)" -ForegroundColor Yellow }
            }
            # Register VM with AVD host pool (AVD agent registration)
            try {
                $dscPublicSettings = @{
                    modulesUrl = 'https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_1.0.02714.342.zip'
                    configurationFunction = 'Configuration.ps1\AddSessionHost'
                    properties = @{ hostPoolName = $HostPoolName; aadJoin = ($identityProvider -ne 'AD DS') }
                }
                $dscProtectedSettings = @{ properties = @{ registrationInfoToken = $token } }
                if (-not $token -or [string]::IsNullOrWhiteSpace($token)) {
                    Write-Host "[ERROR] Registration token is missing or empty. Skipping DSC extension for $vmName." -ForegroundColor Red
                } else {
                    $maskedToken = if ($token.Length -gt 8) { $token.Substring(0,4) + '...' + $token.Substring($token.Length-4,4) } else { '[short/hidden]' }
                    Write-Host "[DEBUG] Passing registration token to DSC extension for $vmName (masked): $maskedToken" -ForegroundColor DarkGray
                    Set-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $vmName -Name 'DSC' -Publisher 'Microsoft.Powershell' -ExtensionType 'DSC' -TypeHandlerVersion '2.83' -Settings $dscPublicSettings -ProtectedSettings $dscProtectedSettings -Location $Location -ErrorAction Stop | Out-Null
                    Write-Host "[INFO] AVD DSC agent installed for $vmName (host pool registration)" -ForegroundColor Cyan
                }
            } catch {
                Write-Host "[WARN] Could not register VM with AVD host pool: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "[HINT] Check DSC extension logs on the VM and ensure configurationFunction is a string. See https://aka.ms/VMExtensionDSCWindowsTroubleshoot for troubleshooting." -ForegroundColor Yellow
            }
        } catch {
            Write-Host ("[ERROR] Failed to create VM {0}: {1}" -f $vmName, $_.Exception.Message) -ForegroundColor Red
            # Clean up NIC if VM creation fails
            try { Remove-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    Write-Host "[INFO] Scale UP operation completed." -ForegroundColor Cyan
}

function Invoke-SessionHostScaleDown {
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$HostPoolName,
        [Parameter(Mandatory)] [int]$Count
    )
    Write-Host "[INFO] Starting scale DOWN operation for $Count session hosts in pool $HostPoolName..." -ForegroundColor Cyan
    # Get all session hosts in the pool
    $hosts = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName | Where-Object { $_.AllowNewSession -eq $true }
    if (-not $hosts -or $hosts.Count -eq 0) {
        Write-Host "[WARN] No available session hosts to remove." -ForegroundColor Yellow
        return
    }
    $toRemove = $hosts | Select-Object -First $Count
    foreach ($sessionHost in $toRemove) {
        Write-Host "[INFO] Removing session host: $($sessionHost.Name)" -ForegroundColor Yellow
        try {
            Remove-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -Name $sessionHost.Name -Force -ErrorAction Stop
            Write-Host "[SUCCESS] Session host $($sessionHost.Name) removed from host pool." -ForegroundColor Green
            # Optionally, delete the underlying VM
            # $vmName = ($sessionHost.Name -split '/')[1]
            # Remove-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -Force
        } catch {
            Write-Host "[ERROR] Failed to remove session host $($sessionHost.Name): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Write-Host "[INFO] Scale DOWN operation completed." -ForegroundColor Cyan
}
#-------------------#
# Prerequisite Validation Function (Reusable) #
#-------------------#
function Test-AVDPrerequisites {
    param([string]$Location)
    Write-Host "[INFO] Running AVD prerequisite validation..." -ForegroundColor Cyan
    $modulesOk = Test-PowerShellModules
    if (-not $modulesOk) {
        throw "Required PowerShell modules validation failed. Please install missing modules and retry."
    }
    $regionOk = $false
    try {
        $locations = Get-AzLocation | Where-Object { $_.Providers -contains "Microsoft.Compute" }
        $regionOk = $locations | Where-Object { $_.Location -eq $Location -or $_.DisplayName -eq $Location }
    } catch {
        Write-Host "Failed to validate region: $($_.Exception.Message)" -ForegroundColor Red
    }
    if (-not $regionOk) {
        throw "Invalid or inaccessible Azure region: $Location"
    }
    Write-Host "[INFO] All AVD prerequisites satisfied." -ForegroundColor Green
    return $true
}
#-------------------#
# Authentication Method Selection Function (Reusable) #
#-------------------#
function Select-AuthenticationMethod {
    Write-Host ""
    Write-Host "Please select your preferred Azure authentication method:" -ForegroundColor White
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
    $authMethods = @{
        1 = "Interactive"
        2 = "DeviceCode"
        3 = "ServicePrincipalSecret"
        4 = "ServicePrincipalCertificate"
        5 = "ManagedIdentity"
    }
    $selectedMethod = $authMethods[$selectionInt]
    Write-Host "Selected authentication method: $selectedMethod" -ForegroundColor Green
    return $selectedMethod
}
#-------------------#
# AVD Registration Token Functions (Reusable) #
#-------------------#

function Get-AVDRegistrationToken {
    param(
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$HostPoolName
    )
    # Try to get the current registration info
    $regInfo = Get-AzWvdRegistrationInfo -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -ErrorAction SilentlyContinue
    $now = Get-Date
    $token = $null
    if ($regInfo -and $regInfo.Token -and $regInfo.ExpirationTime -gt $now.AddMinutes(10)) {
        Write-Host "Existing registration token is valid until $($regInfo.ExpirationTime)." -ForegroundColor Green
        $token = $regInfo.Token
    } else {
        Write-Host "No valid registration token found or token is expiring soon. Renewing token..." -ForegroundColor Yellow
        $regInfo = New-AzWvdRegistrationInfo -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -ExpirationTime $now.AddDays(1)
        $token = $regInfo.Token
        Write-Host "New registration token generated, valid until $($regInfo.ExpirationTime)." -ForegroundColor Green
    }
    return $token
}
#-------------------#
# Interactive Region Selection Function (Reusable) #
#-------------------#

function Select-AzureRegion {
    Write-Host ""
    Write-Host ("="*80) -ForegroundColor White
    Write-Host " Azure Virtual Desktop - Region Selection " -ForegroundColor White
    Write-Host ("="*80) -ForegroundColor White
    Write-Host ""
    $locations = Get-AzLocation | Where-Object { $_.Providers -contains "Microsoft.Compute" } | Sort-Object DisplayName
    if (-not $locations) {
        Write-Host "No available regions found for Virtual Machines." -ForegroundColor Red
        return $null
    }
    $popularRegions = @(
        "East US", "East US 2", "West US", "West US 2", "West US 3", "Central US", "South Central US",
        "North Europe", "West Europe", "UK South", "UK West",
        "Southeast Asia", "East Asia", "Australia East", "Australia Southeast",
        "Canada Central", "Canada East", "Japan East", "Japan West"
    )
    $displayRegions = @()
    $showAllRegions = $false
    do {
        $displayRegions = @()
        $displayCount = 0
        if (-not $showAllRegions) {
            Write-Host "Top 10 Recommended Regions:" -ForegroundColor Green
            $popularCount = 0
            foreach ($regionName in $popularRegions) {
                if ($displayCount -ge 10) { break }
                $region = $locations | Where-Object { $_.DisplayName -eq $regionName }
                if ($region) {
                    $displayCount++
                    Write-Host "  $displayCount. $($region.DisplayName)" -ForegroundColor White
                    $displayRegions += $region
                    $popularCount++
                }
            }
            if ($displayCount -lt 10) {
                $otherRegions = $locations | Where-Object { $_.DisplayName -notin $popularRegions } | Select-Object -First (10 - $displayCount)
                foreach ($region in $otherRegions) {
                    $displayCount++
                    Write-Host "  $displayCount. $($region.DisplayName)" -ForegroundColor White
                    $displayRegions += $region
                }
            }
            Write-Host ""
            Write-Host "Options:" -ForegroundColor Yellow
            Write-Host "  Enter 1-$displayCount to select a region" -ForegroundColor Gray
            Write-Host "  Enter 'more' to see all available regions" -ForegroundColor Gray
        }
        else {
            Write-Host "All Available Regions:" -ForegroundColor Green
            Write-Host "Popular Regions:" -ForegroundColor Cyan
            foreach ($regionName in $popularRegions) {
                $region = $locations | Where-Object { $_.DisplayName -eq $regionName }
                if ($region) {
                    $displayCount++
                    Write-Host "  $displayCount. $($region.DisplayName)" -ForegroundColor White
                    $displayRegions += $region
                }
            }
            Write-Host "Other Regions:" -ForegroundColor Cyan
            $otherRegions = $locations | Where-Object { $_.DisplayName -notin $popularRegions }
            foreach ($region in $otherRegions) {
                $displayCount++
                Write-Host "  $displayCount. $($region.DisplayName)" -ForegroundColor White
                $displayRegions += $region
            }
            Write-Host ""
            Write-Host "Options:" -ForegroundColor Yellow
            Write-Host "  Enter 1-$displayCount to select a region" -ForegroundColor Gray
            Write-Host "  Enter 'less' to return to top 10 view" -ForegroundColor Gray
        }
        Write-Host ""
        Write-Host "Please select an Azure region for AVD deployment:" -ForegroundColor Yellow
        $selection = Read-Host "Enter your choice"
        if ($selection -eq "more" -and -not $showAllRegions) {
            $showAllRegions = $true
            continue
        } elseif ($selection -eq "less" -and $showAllRegions) {
            $showAllRegions = $false
            continue
        } elseif ([int]::TryParse($selection, [ref]$null)) {
            $selectedIndex = [int]$selection - 1
            if ($selectedIndex -ge 0 -and $selectedIndex -lt $displayRegions.Count) {
                break
            } else {
                Write-Host "Invalid selection. Please enter a number between 1 and $($displayRegions.Count)." -ForegroundColor Red
            }
        } else {
            if (-not $showAllRegions) {
                Write-Host "Invalid input. Please enter a number (1-$($displayRegions.Count)) or 'more' to see all regions." -ForegroundColor Red
            } else {
                Write-Host "Invalid input. Please enter a number (1-$($displayRegions.Count)) or 'less' to return to top 10." -ForegroundColor Red
            }
        }
    } while ($true)
    $selectedLocation = $displayRegions[$selectedIndex]
    Write-Host "Selected region: $($selectedLocation.DisplayName) ($($selectedLocation.Location))" -ForegroundColor Green

    return $selectedLocation.Location
}

#-------------------#
# Prerequisite Validation Functions (Reusable) #
#-------------------#

# Required Azure PowerShell modules with minimum versions
$RequiredModules = @(
    @{ Name = "Az.Accounts"; MinVersion = "2.6.0"; Description = "Azure authentication and context management" },
    @{ Name = "Az.Compute"; MinVersion = "6.0.0"; Description = "Virtual machine and compute resource management" },
    @{ Name = "Az.Resources"; MinVersion = "6.0.0"; Description = "Resource management and metadata access" }
)
function Test-PowerShellModules {
    Write-Host "Validating Required PowerShell Modules..."
    $required = @('Az.Accounts','Az.Compute','Az.Resources','Az.Network','Az.DesktopVirtualization')
    $missing = @()
    foreach ($mod in $required) {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            $missing += $mod
        } else {
            Import-Module $mod -ErrorAction SilentlyContinue
        }
    }
    if ($missing.Count -gt 0) {
        Write-Host ("[ERROR] Missing required modules: {0}" -f ($missing -join ', ')) -ForegroundColor Red
        Write-Host "Please install them using: Install-Module -Name <ModuleName> -Scope CurrentUser" -ForegroundColor Yellow
        return $false
    }
    return $true
}
function Invoke-AzureAuthentication {
    param(
        [string]$AuthMethod,
        [string]$TenantId
    )
    Write-Host "Initiating Azure authentication using: $AuthMethod" -ForegroundColor Yellow
    Write-Host ""
    try {
        switch ($AuthMethod) {
            "Interactive" {
                if ($TenantId) {
                    Write-Host "Opening browser for interactive login to tenant: $TenantId" -ForegroundColor Yellow
                    $authResult = Connect-AzAccount -TenantId $TenantId
                } else {
                    Write-Host "Opening browser for interactive login..." -ForegroundColor Yellow
                    $authResult = Connect-AzAccount
                }
            }
            "DeviceCode" {
                Write-Host "Starting device code authentication..." -ForegroundColor Yellow
                Write-Host "You will see a device code that you need to enter at https://microsoft.com/devicelogin" -ForegroundColor Cyan
                if ($TenantId) {
                    $authResult = Connect-AzAccount -UseDeviceAuthentication -TenantId $TenantId
                } else {
                    $authResult = Connect-AzAccount -UseDeviceAuthentication
                }
            }
            "ServicePrincipalSecret" {
                Write-Host "Service Principal authentication with client secret..." -ForegroundColor Yellow
                $appId = Read-Host "Enter Application (Client) ID"
                $clientSecret = Read-Host "Enter Client Secret" -AsSecureString
                $tenantForAuth = if ($TenantId) { $TenantId } else { Read-Host "Enter Tenant ID" }
                $credential = New-Object System.Management.Automation.PSCredential($appId, $clientSecret)
                $authResult = Connect-AzAccount -ServicePrincipal -Credential $credential -TenantId $tenantForAuth
            }
            "ServicePrincipalCertificate" {
                Write-Host "Service Principal authentication with certificate..." -ForegroundColor Yellow
                $appId = Read-Host "Enter Application (Client) ID"
                $certThumbprint = Read-Host "Enter Certificate Thumbprint"
                $tenantForAuth = if ($TenantId) { $TenantId } else { Read-Host "Enter Tenant ID" }
                $authResult = Connect-AzAccount -ServicePrincipal -ApplicationId $appId -CertificateThumbprint $certThumbprint -TenantId $tenantForAuth
            }
            "ManagedIdentity" {
                Write-Host "Authenticating using Managed Identity..." -ForegroundColor Yellow
                $authResult = Connect-AzAccount -Identity
            }
            default {
                throw "Unknown authentication method: $AuthMethod"
            }
        }
        if (-not $authResult) {
            throw "Authentication failed - no result returned"
        }
        Write-Host "Authentication successful!" -ForegroundColor Green
                    return $authResult
                } catch {
                    Write-Host "Authentication failed: $($_.Exception.Message)" -ForegroundColor Red
                    throw $_
                }
            }
            function Connect-AzureWithSelection {
                Write-Host ""
                Write-Host "$(('='*80))" -ForegroundColor White
                Write-Host " AZURE AUTHENTICATION " -ForegroundColor White
                Write-Host "$(('='*80))" -ForegroundColor White
                Write-Host ""
                try {
                    $currentContext = Get-AzContext
                    if ($currentContext -and -not $TenantId -and -not $SubscriptionId -and -not $ForceReauth) {
                        Write-Host "Current Azure Context:" -ForegroundColor Yellow
                        Write-Host "  Account: $($currentContext.Account.Id)" -ForegroundColor White
                        Write-Host "  Tenant: $($currentContext.Tenant.Id)" -ForegroundColor White
                        Write-Host "  Subscription: $($currentContext.Subscription.Name) ($($currentContext.Subscription.Id))" -ForegroundColor White
                        Write-Host ""
                        if (-not $NonInteractive) {
                            $useExisting = Read-Host "Use existing connection? (Y/n)"
                            if ($useExisting -eq "" -or $useExisting -eq "Y" -or $useExisting -eq "y") {
                                Write-Host "Using existing Azure connection." -ForegroundColor Green
                                return $true
                            }
                        } else {
                            Write-Host "Non-interactive mode: Using existing Azure connection." -ForegroundColor Green
                            return $true
                        }
                    }
                    if ($ForceReauth -and $currentContext) {
                        Write-Host "Force re-authentication requested. Clearing existing context..." -ForegroundColor Yellow
                        Clear-AzContext -Force -ErrorAction SilentlyContinue
                        Disconnect-AzAccount -ErrorAction SilentlyContinue
                    }
                    $authMethod = Select-AuthenticationMethod
                    $authResult = Invoke-AzureAuthentication -AuthMethod $authMethod -TenantId $TenantId
                    if (-not $authResult) {
                        throw "Failed to authenticate with Azure"
                    }
                    Write-Host "Azure connection established successfully!" -ForegroundColor Green
                    return $true
                } catch {
                    Write-Host "Failed to establish Azure connection: $($_.Exception.Message)" -ForegroundColor Red
                    if (-not $NonInteractive) {
                        Write-Host ""
                        $retry = Read-Host "Would you like to try a different authentication method? (Y/n)"
                        if ($retry -eq "" -or $retry -eq "Y" -or $retry -eq "y") {
                            Write-Host "Retrying authentication..." -ForegroundColor Yellow
                            return Connect-AzureWithSelection
                        }
                    }
                    return $false
                }
            }

            #-------------------#
            # AVD Registration Token Functions (Reusable) #
            #-------------------#
            function Get-AVDRegistrationToken {
                param(
                    [Parameter(Mandatory)] [string]$ResourceGroupName,
                    [Parameter(Mandatory)] [string]$HostPoolName
                )
                $regInfo = Get-AzWvdRegistrationInfo -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -ErrorAction SilentlyContinue
                $now = Get-Date
                $token = $null
                if ($regInfo -and $regInfo.Token -and $regInfo.ExpirationTime -gt $now.AddMinutes(10)) {
                    Write-Host "Existing registration token is valid until $($regInfo.ExpirationTime)." -ForegroundColor Green
                    $token = $regInfo.Token
                } else {
                    Write-Host "No valid registration token found or token is expiring soon. Renewing token..." -ForegroundColor Yellow
                    $regInfo = New-AzWvdRegistrationInfo -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -ExpirationTime $now.AddDays(1)
                    $token = $regInfo.Token
                    Write-Host "New registration token generated, valid until $($regInfo.ExpirationTime)." -ForegroundColor Green
                }
                return $token
            }


            #-------------------#
            # Utility Functions #
            #-------------------#
            function Show-Explanation {
                param([string]$Message)
                Write-Host "`n[INFO] $Message" -ForegroundColor Cyan
            }
            function Get-AVDSessionHostPools {
                Show-Explanation "Fetching all available AVD session host pools in your subscription..."
                Get-AzWvdHostPool
            }

            function Get-VMQuotaFamilyNameForPrecheck {
                param([string]$SkuName)
                switch -Regex ($SkuName) {
                    '^Standard_D\d+as_v5'  { return 'standardDASv5Family' }
                    '^Standard_D\d+s_v5'   { return 'standardDSv5Family'  }
                    '^Standard_D\d+as_v4'  { return 'standardDASv4Family' }
                    '^Standard_D\d+s_v4'   { return 'standardDSv4Family'  }
                    '^Standard_D\d+s_v3'   { return 'standardDSv3Family'  }
                    '^Standard_E\d+s_v5'   { return 'standardESv5Family'  }
                    '^Standard_E\d+s_v4'   { return 'standardESv4Family'  }
                    '^Standard_E\d+s_v3'   { return 'standardESv3Family'  }
                    '^Standard_F\d+s_v2'   { return 'standardFSv2Family'  }
                    '^Standard_B\d+'       { return 'standardBSFamily'    }
                    '^Standard_NV\d+s_v3'  { return 'standardNVSv3Family' }
                    '^Standard_NV\d+'      { return 'standardNVFamily'    }
                    '^Standard_NC\d+s_v3'  { return 'standardNCSv3Family' }
                    '^Standard_NC\d+'      { return 'standardNCFamily'    }
                    '^Standard_ND\d+'      { return 'standardNDFamily'    }
                    default                 { return $null                 }
                }
            }

            function Test-VMSizeQuantityAvailability {
                param(
                    [Parameter(Mandatory)] [string]$Location,
                    [Parameter(Mandatory)] [string]$VMSize,
                    [Parameter(Mandatory)] [int]$Count
                )

                Write-Host ("[INFO] Running precheck for {0} x {1} in {2}..." -f $Count, $VMSize, $Location) -ForegroundColor Cyan

                $normalizedLocation = $Location
                try {
                    $locObj = Get-AzLocation | Where-Object { $_.Location -eq $Location -or $_.DisplayName -eq $Location } | Select-Object -First 1
                    if ($locObj -and $locObj.Location) { $normalizedLocation = $locObj.Location }
                } catch {}

                $sku = $null
                try {
                    $sku = Get-AzComputeResourceSku | Where-Object {
                        $_.ResourceType -eq 'virtualMachines' -and
                        $_.Name -eq $VMSize -and
                        ($_.Locations -contains $normalizedLocation)
                    } | Select-Object -First 1
                } catch {
                    Write-Host ("[WARN] Could not query VM SKU metadata: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                }

                if (-not $sku) {
                    Write-Host ("[ERROR] VM size {0} is not available in region {1} (or not available for this subscription)." -f $VMSize, $normalizedLocation) -ForegroundColor Red
                    return $false
                }

                $blockingRestriction = $sku.Restrictions | Where-Object {
                    $_.ReasonCode -eq 'NotAvailableForSubscription' -or
                    $_.Type -eq 'Location'
                }
                if ($blockingRestriction) {
                    Write-Host ("[ERROR] VM size {0} is currently restricted for this subscription in {1}." -f $VMSize, $normalizedLocation) -ForegroundColor Red
                    return $false
                }

                $vmCoreCount = 1
                try {
                    $vCpuCapability = $sku.Capabilities | Where-Object { $_.Name -eq 'vCPUs' } | Select-Object -First 1
                    if ($vCpuCapability -and $vCpuCapability.Value) {
                        $parsed = 0
                        if ([int]::TryParse($vCpuCapability.Value, [ref]$parsed)) {
                            $vmCoreCount = $parsed
                        }
                    }
                } catch {}
                if ($vmCoreCount -lt 1) { $vmCoreCount = 1 }

                $neededCores = $Count * $vmCoreCount

                try {
                    $usage = Get-AzVMUsage -Location $normalizedLocation
                    $regionalCoreQuota = $usage | Where-Object {
                        $_.Name.Value -eq 'cores' -or $_.Name.LocalizedValue -match 'Total Regional vCPUs'
                    } | Select-Object -First 1

                    if ($regionalCoreQuota) {
                        $current = [int]$regionalCoreQuota.CurrentValue
                        $limit = [int]$regionalCoreQuota.Limit
                        $remainingRegionalCores = [Math]::Max(0, $limit - $current)
                        $maxRegionalHosts = [Math]::Floor($remainingRegionalCores / $vmCoreCount)
                        if (($current + $neededCores) -gt $limit) {
                            Write-Host ("[ERROR] Requested quantity exceeds regional vCPU quota in {0}. Current: {1}, Limit: {2}, Additional Required: {3}." -f $normalizedLocation, $current, $limit, $neededCores) -ForegroundColor Red
                            Write-Host ("[HINT] Max hosts currently allowed by regional quota for {0} is {1} (each host uses {2} vCPU)." -f $VMSize, $maxRegionalHosts, $vmCoreCount) -ForegroundColor Yellow
                            return $false
                        }
                    }

                    $quotaFamily = Get-VMQuotaFamilyNameForPrecheck -SkuName $VMSize
                    if ($quotaFamily) {
                        $familyQuota = $usage | Where-Object { $_.Name.Value -eq $quotaFamily } | Select-Object -First 1
                        if ($familyQuota) {
                            $familyCurrent = [int]$familyQuota.CurrentValue
                            $familyLimit = [int]$familyQuota.Limit
                            $remainingFamilyCores = [Math]::Max(0, $familyLimit - $familyCurrent)
                            $maxFamilyHosts = [Math]::Floor($remainingFamilyCores / $vmCoreCount)
                            if (($familyCurrent + $neededCores) -gt $familyLimit) {
                                Write-Host ("[ERROR] Requested quantity exceeds VM family quota ({0}) in {1}. Current: {2}, Limit: {3}, Additional Required: {4}." -f $quotaFamily, $normalizedLocation, $familyCurrent, $familyLimit, $neededCores) -ForegroundColor Red
                                Write-Host ("[HINT] Max hosts currently allowed by {0} is {1} (each host uses {2} vCPU)." -f $quotaFamily, $maxFamilyHosts, $vmCoreCount) -ForegroundColor Yellow
                                Write-Host ("[HINT] Increase quota at: https://aka.ms/ProdportalCRP" ) -ForegroundColor Yellow
                                return $false
                            }
                        }
                    }
                } catch {
                    Write-Host ("[WARN] Could not complete quota-based precheck: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                }

                Write-Host "[INFO] Precheck passed. SKU is eligible in-region and requested quantity fits current quota limits." -ForegroundColor Green
                Write-Host "[NOTE] Azure capacity can still change at deployment time; this precheck reduces, but cannot fully eliminate, allocation failures." -ForegroundColor Yellow
                return $true
            }


            #-------------------#
            # Main Script Logic #
            #-------------------#

            # 1. Authenticate with Azure (force re-authentication every time)
            $Global:ForceReauth = $true
            try {
                Connect-AzureWithSelection
            } catch {
                Write-Host "[ERROR] Azure authentication failed: $($_.Exception.Message)" -ForegroundColor Red
                exit 1
            }

            # 2. Interactive region selection (menu only, no Read-Host prompt)
            $Region = Select-AzureRegion
            if (-not $Region) {
                Write-Host "[ERROR] No region selected. Exiting script." -ForegroundColor Red
                exit 1
            }

            # 3. Run prerequisite validation with error handling
            try {
                Test-AVDPrerequisites -Location $Region
            } catch {
                Write-Host "[ERROR] Prerequisite validation failed: $($_.Exception.Message)" -ForegroundColor Red
                exit 1
            }

            # 4. Main autoscale logic
            Show-Explanation "Welcome to the Azure Virtual Desktop Session Host Pool Autoscaler."


            # 4.1 Select Host Pool
            $pools = Get-AVDSessionHostPools
            if (-not $pools -or $pools.Count -eq 0) {
                Write-Host "[ERROR] No AVD session host pools found in your subscription for the selected region. Exiting script." -ForegroundColor Red
                exit 1
            }
            Write-Host "Available AVD Session Host Pools:" -ForegroundColor Yellow
            $i = 1
            foreach ($pool in $pools) {
                Write-Host ("  {0}. {1}" -f $i, $pool.Name) -ForegroundColor White
                $i++
            }
            do {
                $selection = Read-Host ("Select a host pool by number (1-{0})" -f ($pools.Count))
                $valid = [int]::TryParse($selection, [ref]$null) -and $selection -ge 1 -and $selection -le $pools.Count
                if (-not $valid) {
                    Write-Host "Invalid selection. Please enter a number between 1 and $($pools.Count)." -ForegroundColor Red
                }
            } while (-not $valid)
            $selectedPool = $pools[[int]$selection - 1]
            Write-Host ("Selected host pool: {0}" -f $selectedPool.Name) -ForegroundColor Green

            # 4.2 Choose Scale Operation

            Show-Explanation "Would you like to scale UP or scale DOWN session hosts in the selected pool?"
            $operation = $null
            do {
                Write-Host "  1. Scale UP (add session hosts)" -ForegroundColor Green
                Write-Host "  2. Scale DOWN (remove session hosts)" -ForegroundColor Yellow
                $opChoice = Read-Host "Enter your choice (1 for UP, 2 for DOWN)"
                if ($opChoice -eq '1') { $operation = 'up' }
                elseif ($opChoice -eq '2') { $operation = 'down' }
                else { Write-Host "Invalid selection. Please enter 1 or 2." -ForegroundColor Red }
            } while (-not $operation)

            # Gather parameters and execute scaling

            $rg = $selectedPool.ResourceGroupName
            $poolName = $selectedPool.Name
            $location = $selectedPool.Location

            # Discover current VM sizes in the host pool
            $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $rg -HostPoolName $poolName
            $vmSizeMap = @{}
            foreach ($sh in $sessionHosts) {
                $vmName = ($sh.Name -split '/')[-1]
                try {
                    $vm = Get-AzVM -ResourceGroupName $rg -Name $vmName -ErrorAction Stop
                    $size = $vm.HardwareProfile.VmSize
                    if ($size) { $vmSizeMap[$size] = $vmSizeMap[$size] + 1 }
                    else { $vmSizeMap[$size] = 1 }
                } catch {}
            }
            $suggestedVmSize = $null
            if ($vmSizeMap.Count -gt 0) {
                $suggestedVmSize = ($vmSizeMap.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1).Key
                Write-Host "[INFO] Current VM sizes in this host pool:" -ForegroundColor Cyan
                foreach ($kv in $vmSizeMap.GetEnumerator()) {
                    Write-Host ("  {0}: {1} VM(s)" -f $kv.Key, $kv.Value) -ForegroundColor White
                }
                Write-Host ("[INFO] Suggested VM size for scaling up: {0}" -f $suggestedVmSize) -ForegroundColor Green
            } else {
                Write-Host "[WARN] Could not determine current VM sizes in the host pool. Please enter a VM size manually." -ForegroundColor Yellow
            }

            if ($operation -eq 'up') {
                Show-Explanation "You chose to scale UP. Please provide the following details."
                # Offer navigation: use .json config, mimic existing, or manual
                Write-Host "How would you like to configure new session hosts?" -ForegroundColor Cyan
                Write-Host "  1. Use a .json config file (mimic deployment template)" -ForegroundColor Green
                Write-Host "  2. Mimic existing session host configuration" -ForegroundColor Yellow
                Write-Host "  3. Manual entry (prompt for all values)" -ForegroundColor White
                do {
                    $configChoice = Read-Host "Enter your choice (1, 2, or 3)"
                } while ($configChoice -notin '1','2','3')
                $configSettings = $null
                if ($configChoice -eq '1') {
                    $jsonPath = Read-Host "Enter path to .json config file (e.g., avd-accelerator-sample-config.json)"
                    $configSettings = Get-AVDConfigFromJson -JsonPath $jsonPath
                    if (-not $configSettings) {
                        Write-Host "[WARN] Could not parse config file. Falling back to manual entry." -ForegroundColor Yellow
                    }
                } elseif ($configChoice -eq '2') {
                    # Enhanced mimic logic: search all resource groups for the VM if not found in current
                    $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $rg -HostPoolName $poolName
                    $allResourceGroups = (Get-AzResourceGroup).ResourceGroupName
                    $foundVm = $false
                    foreach ($sh in $sessionHosts) {
                        $vmName = ($sh.Name -split '/')[-1]
                        Write-Host ("[DEBUG] Looking for VM: {0} in resource group: {1}" -f $vmName, $rg) -ForegroundColor DarkGray
                        $vm = $null
                        $vmRg = $rg  # Always preserve original host pool RG
                        try {
                            $vm = Get-AzVM -ResourceGroupName $rg -Name $vmName -ErrorAction Stop
                        } catch {
                            # Not found in current RG, search all RGs
                            foreach ($otherRg in $allResourceGroups) {
                                if ($otherRg -eq $rg) { continue }
                                Write-Host ("[DEBUG] Looking for VM: {0} in resource group: {1}" -f $vmName, $otherRg) -ForegroundColor DarkGray
                                try {
                                    $vm = Get-AzVM -ResourceGroupName $otherRg -Name $vmName -ErrorAction Stop
                                    $vmRg = $otherRg
                                    break
                                } catch {}
                            }
                        }
                        if ($vm) {
                            $nicId = $vm.NetworkProfile.NetworkInterfaces[0].Id
                            $nic = Get-AzNetworkInterface -ResourceId $nicId
                            $ipConfig = $nic.IpConfigurations[0]
                            $subnetId = $ipConfig.Subnet.Id
                            $subnetParts = $subnetId -split '/'
                            Write-Host ("[DEBUG] Mimic: subnetId = {0}" -f $subnetId) -ForegroundColor DarkGray
                            $vnetResourceGroup = $null
                            if ($subnetParts.Length -ge 9) {
                                $vnetResourceGroup = $subnetParts[4]
                                Write-Host ("[DEBUG] Mimic: Extracted vnetResourceGroup = {0}" -f $vnetResourceGroup) -ForegroundColor DarkGray
                            }
                            $vnetName = $subnetParts[8]
                            # Fallback: If vnetResourceGroup is empty, search all VNets for a match
                            if (-not $vnetResourceGroup -or $vnetResourceGroup -eq "") {
                                Write-Host "[DEBUG] vnetResourceGroup not found in subnetId, searching all VNets for VNet name match..." -ForegroundColor DarkGray
                                $allVNets = Get-AzVirtualNetwork
                                $matchedVNet = $allVNets | Where-Object { $_.Name -eq $vnetName }
                                if ($matchedVNet) {
                                    $vnetResourceGroup = $matchedVNet.ResourceGroupName
                                    Write-Host ("[DEBUG] Found VNet '{0}' in resource group '{1}' via discovery." -f $vnetName, $vnetResourceGroup) -ForegroundColor DarkGray
                                } else {
                                    Write-Host ("[ERROR] Could not find VNet '{0}' in any resource group." -f $vnetName) -ForegroundColor Red
                                }
                            }
                            $configSettings = @{
                                VMSize = $vm.HardwareProfile.VmSize
                                Location = $vm.Location
                                VNet = $vnetName
                                Subnet = $subnetParts[10]
                                VNetResourceGroup = $vnetResourceGroup
                                ImageURN = ($vm.StorageProfile.ImageReference.Publisher + ':' + $vm.StorageProfile.ImageReference.Offer + ':' + $vm.StorageProfile.ImageReference.Sku + ':' + $vm.StorageProfile.ImageReference.Version)
                            }
                            Write-Host ("[INFO] Mimicked config from VM: {0} in resource group: {1}, VNet RG: {2}" -f $vmName, $vmRg, $vnetResourceGroup) -ForegroundColor Green
                            break
                        }
                    }
                    if (-not $configSettings) {
                        Write-Host "[WARN] Could not mimic existing session host in any resource group. Falling back to manual entry." -ForegroundColor Yellow
                    }
                }
                if ($configSettings) {
                    $vmSize = $configSettings.VMSize
                    $location = $configSettings.Location
                } else {
                    # Offer a menu of available VM sizes in the selected region
                    Write-Host "Fetching available VM sizes in region: $location ..." -ForegroundColor Cyan
                    Import-Module Az.Compute -ErrorAction SilentlyContinue
                    # Try Get-AzVMSize with -Location, fallback to -ResourceGroupName, then Get-AzComputeResourceSku
                    $availableSizes = $null
                    $vmSizeError = $null
                    try {
                        $params = (Get-Command Get-AzVMSize).Parameters.Keys
                        if ($params -contains 'Location') {
                            $availableSizes = Get-AzVMSize -Location $location | Sort-Object -Property Name
                        } elseif ($params -contains 'VMName') {
                            # Only use VMName parameter if VMs exist; never prompt for VMName interactively
                            $vms = Get-AzVM -ResourceGroupName $rg
                            Write-Host ("[DEBUG] VMs found in resource group {0}: {1}" -f $rg, ($vms | ForEach-Object { $_.Name } | Sort-Object | ForEach-Object { $_ } -join ', ')) -ForegroundColor DarkGray
                            if (-not $vms -or $vms.Count -eq 0) {
                                Write-Host "[ERROR] No VMs found in resource group $rg to query VM sizes. Cannot use -VMName parameter without a VM. Aborting without prompt." -ForegroundColor Red
                                Write-Host "[HINT] If you have session hosts, but no VMs are found here, check if the VMs are in a different resource group or have been deleted. The script will not prompt for VMName." -ForegroundColor Yellow
                                exit 1
                            }
                            # Always select the first VM automatically for automation; never prompt
                            $selectedVM = $vms[0].Name
                            Write-Host ("[INFO] Using VM: {0} to query available sizes (auto-selected, never prompted)." -f $selectedVM) -ForegroundColor Green
                            $availableSizes = Get-AzVMSize -Location $location -VMName $selectedVM | Sort-Object -Property Name
                        }
                    } catch {
                        $vmSizeError = $_.Exception.Message
                    }
                    if (-not $availableSizes -or $availableSizes.Count -eq 0) {
                        # Fallback to Get-AzComputeResourceSku for region-based query
                        try {
                            $availableSizes = Get-AzComputeResourceSku | Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Locations -contains $location } | Select-Object -Property Name -Unique | Sort-Object -Property Name
                        } catch {
                            $vmSizeError = $_.Exception.Message
                        }
                    }
                    if (-not $availableSizes -or $availableSizes.Count -eq 0) {
                        Write-Host "[ERROR] No VM sizes found for region $location. Please check your Azure permissions, region availability, or module version." -ForegroundColor Red
                        if ($vmSizeError) { Write-Host "[DEBUG] $vmSizeError" -ForegroundColor DarkGray }
                        exit 1
                    }
                    $defaultIndex = 0
                    if ($suggestedVmSize) {
                        $defaultIndex = ($availableSizes | Select-Object -ExpandProperty Name).IndexOf($suggestedVmSize)
                        if ($defaultIndex -lt 0) { $defaultIndex = 0 }
                    }
                    Write-Host "Available VM Sizes:" -ForegroundColor Yellow
                    for ($i = 0; $i -lt $availableSizes.Count; $i++) {
                        $size = $availableSizes[$i]
                        $isDefault = ($i -eq $defaultIndex)
                        $defaultMark = if ($isDefault) { "<-- Default" } else { "" }
                        Write-Host ("  {0}. {1,-20} vCPUs: {2,-2} RAM: {3,4} MB {4}" -f ($i+1), $size.Name, $size.NumberOfCores, $size.MemoryInMB, $defaultMark) -ForegroundColor White
                    }
                    # Always select default VM size (first in list or suggested)
                    $sizeChoice = $defaultIndex+1
                    $vmSize = $availableSizes[$defaultIndex].Name
                }
            }

            # Prompt for number of session hosts to add
            $hostCount = 0
            do {
                $hostCountInput = Read-Host "Enter the number of session hosts to add (1-100)"
                $validCount = [int]::TryParse($hostCountInput, [ref]$hostCount) -and $hostCount -ge 1 -and $hostCount -le 100
                if (-not $validCount) {
                    Write-Host "Invalid input. Please enter a number between 1 and 100." -ForegroundColor Red
                }
            } while (-not $validCount)

            # Call scaling function with discovered/mimicked/manual config
            Write-Host ("[INFO] Scaling up {0} session host(s) in pool {1}..." -f $hostCount, $poolName) -ForegroundColor Cyan
            Invoke-SessionHostScaleUp -ResourceGroupName $rg -HostPoolName $poolName -Count $hostCount -VMSize $vmSize -Location $location -ConfigSettings $configSettings

