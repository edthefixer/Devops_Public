# Azure Virtual Desktop Validation Scripts

This repository contains three self-contained PowerShell launchers for validating Azure Virtual Desktop (AVD) deployment readiness.

Each launcher contains its validation engine internally and does not require another script from this repository.

## Language support

All three scripts support the following languages:

| Language | Accepted values |
| --- | --- |
| English | `English`, `en-US` |
| Spanish | `Spanish`, `es-VE` |
| Portuguese | `Portuguese`, `pt-BR` |

You can choose a language in either of two ways:

- Provide the `-Language` parameter.
- Omit `-Language` during an interactive run and select the language from the menu.

For unattended or repeatable runs, provide `-Language` and `-NonInteractive`. If `-NonInteractive` is used without `-Language`, English is selected by default.

Examples:

```powershell
# English
.\00_AVD_Check_Deployment_Readiness_Launcher.ps1 -Language English

# Spanish
.\00_AVD_Check_Deployment_Readiness_Launcher.ps1 -Language Spanish

# Portuguese
.\00_AVD_Check_Deployment_Readiness_Launcher.ps1 -Language Portuguese
```

The language selection applies to the validation messages and generated output supported by each embedded validation engine.

## Scripts

### `00_AVD_Check_Deployment_Readiness_Launcher.ps1`

Performs a broad AVD pre-deployment readiness validation, including checks related to:

- Azure subscription and target region
- Planned session hosts and VM SKU
- Identity model
- Resource group, virtual network, subnet, and storage configuration
- Connectivity and Active Directory validation

### `01_AVD_Validate_VMSizeAndQuota_Launcher.ps1`

Validates VM size and quota suitability for an AVD deployment, including:

- Azure region and VM size discovery
- Minimum CPU and memory requirements
- Workload category
- Deployment-ready VM sizes
- Optional pricing and accelerated-networking information

### `02_AVD_Validate_Network_Configuration_Launcher.ps1`

Validates AVD network configuration, including:

- DNS
- VNet peering
- Network latency
- Session host join type
- Profile storage authentication

This script also exposes optional remediation switches. Review the proposed changes carefully before using `-EnableRemediation` or `-AutoFixAll`.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- Windows operating system
- An Azure account or service principal with access to the target environment
- Azure permissions sufficient for the checks being performed
- Network access to Azure from the computer running the script

The scripts stage required modules in temporary, operating-system-managed directories when needed and clean up temporary files after execution.

## Download the scripts

From GitHub, select **Code → Download ZIP**, extract the archive, and open PowerShell in the extracted directory.

Alternatively, clone the repository with Git:

```powershell
git clone https://github.com/edthefixer/Devops_Public.git
cd Devops_Public
```

## Authentication

The person running the script must authenticate to the Azure environment being checked. Do not use credentials belonging to the repository owner or another organization.

The launchers expose several authentication methods, including:

- `ExistingContext`
- `Interactive`
- `DeviceCode`
- `ServicePrincipalSecret`
- `ServicePrincipalCertificate`
- `ManagedIdentity`

For an interactive run, use `-AuthMethod Interactive` if supported by the selected validation engine. For an already authenticated Azure session, use `-AuthMethod ExistingContext`.

If using an existing Az PowerShell context, an example login is:

```powershell
Connect-AzAccount -Tenant "YOUR-TENANT-ID"
Set-AzContext -Subscription "YOUR-SUBSCRIPTION-ID"
```

Authentication and required permissions depend on the checks being performed. A read-only role such as **Reader** may be a suitable starting point, but additional permissions can be required for identity, networking, storage, or directory checks.

## Run the readiness validation

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

.\00_AVD_Check_Deployment_Readiness_Launcher.ps1 `
    -Language English `
    -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
    -TenantId "YOUR-TENANT-ID" `
    -TargetRegion "eastus2" `
    -VmSku "Standard_D4s_v5" `
    -PlannedSessionHosts 10 `
    -IdentityModel All `
    -AuthMethod Interactive `
    -NonInteractive `
    -ExportReport
```

Replace the subscription ID, tenant ID, and region with values from the environment being checked.

To run this validation in Spanish or Portuguese, change the language parameter:

```powershell
-Language Spanish
```

or:

```powershell
-Language Portuguese
```

## Run the VM size and quota validation

```powershell
.\01_AVD_Validate_VMSizeAndQuota_Launcher.ps1 `
    -Language English `
    -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
    -TenantId "YOUR-TENANT-ID" `
    -Location "eastus2" `
    -MinCores 4 `
    -MinMemoryGB 16 `
    -WorkloadType All `
    -DeploymentReadyOnly $true `
    -NonInteractive
```

Optional switches include:

```powershell
-IncludePricing
-IncludeOnlyAccelerated
```

Use `-Language Spanish` or `-Language Portuguese` to run this validation in those languages.

## Run the network validation

```powershell
.\02_AVD_Validate_Network_Configuration_Launcher.ps1 `
    -Language English `
    -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
    -AuthMethod ExistingContext `
    -NonInteractive
```

Optional validation switches include:

```powershell
-SkipDNSValidation
-SkipPeeringValidation
-SkipLatencyTest
```

The network launcher supports these session host join types:

```text
MicrosoftEntraID
ActiveDirectoryDomainServices
NotAssessed
```

It supports these profile storage authentication values:

```text
MicrosoftEntraKerberos
ActiveDirectoryDomainServices
NotAssessed
```

Use `-Language Spanish` or `-Language Portuguese` to run this validation in those languages.

## Reports

Some validations export an Excel report by default. Reports are written beside the launcher unless a different report path is supplied. Review reports for environment-specific information before sharing them.

## Security and privacy

- Never commit passwords, client secrets, private keys, certificates, or exported credentials.
- Use the client’s own Azure tenant, subscription, and identity.
- Review generated reports before sharing them because they may contain tenant, subscription, resource, or network details.
- These scripts are provided for validation purposes. Review any remediation option before allowing changes to an Azure environment.

## License

See [LICENSE](LICENSE).
