# Azure, Intune and Identity Validation Scripts

PowerShell scripts that check whether an environment is ready before anything is deployed: Azure Virtual Desktop (AVD), Microsoft Intune, and identity provisioning across cloud and on-premises.

Every script is self-contained: one `.ps1` file, no other file from this repository required. The one exception is `AVD\03_AVD_Check_Platform_Prerequisites.ps1`, which runs `00_AVD_Check_Deployment_Readiness.ps1` as part of its check, so keep the two in the same folder. They report what is wrong, why it matters and how to fix it. **They change nothing unless you explicitly ask**, and the scripts that can offer a change say so below.

| Folder | Script | Checks |
| --- | --- | --- |
| `AVD` | `00_AVD_Check_Deployment_Readiness.ps1` | Broad AVD pre-deployment readiness |
| `AVD` | `01_AVD_Validate_VMSizeAndQuota.ps1` | VM size and quota (English, Spanish, Portuguese) |
| `AVD` | `02_AVD_Validate_Network_Configuration.ps1` | AVD network configuration (English, Spanish, Portuguese) |
| `AVD` | `03_AVD_Check_Platform_Prerequisites.ps1` | Tenant-wide AVD platform prerequisites |
| `Intune` | `00_INT_Check_Deployment_Readiness.ps1` | Microsoft Intune deployment readiness |
| `Identity` | `00_IDN_Check_Identity_Prerequisites.ps1` | Identity provisioning prerequisites |

Every script has full help. Read it before running:

```powershell
Get-Help .\AVD\00_AVD_Check_Deployment_Readiness.ps1 -Full
```

## Requirements

- Windows PowerShell 5.1 or PowerShell 7, on Windows
- An account, service principal or managed identity with access to the environment being checked
- Network access to Azure and Microsoft Graph from the computer running the script

Missing Az or Microsoft Graph modules are staged in a temporary, operating-system-managed folder for the run and removed afterwards.

## Download

From GitHub, select **Code → Download ZIP**, extract it, and open PowerShell in the extracted folder. Or clone it:

```powershell
git clone https://github.com/edthefixer/Devops_Public.git
cd Devops_Public
```

Downloaded scripts may need to be allowed for the current session:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

In **PowerShell ISE**, type that line in the console pane before pressing F5, and open the script from its file rather than pasting it into a new tab. The script then continues in a new PowerShell window, because ISE cannot show their output.

## Authentication

Sign in to **your own** tenant and subscription. Never use credentials belonging to the repository owner or another organization.

Run any script with no parameters for a guided setup, or pass `-NonInteractive` with the settings below for unattended runs. The `-AuthMethod` values are:

| Value | Sign-in |
| --- | --- |
| `ExistingContext` | The Az session you already have (`Connect-AzAccount`) |
| `Interactive` | Browser sign-in |
| `DeviceCode` | Device code sign-in |
| `ServicePrincipalSecret` | App registration with a client secret |
| `ServicePrincipalCertificate` | App registration with a certificate |
| `ManagedIdentity` | The managed identity of the machine running the script |

Not every script offers every method: `Get-Help <script> -Parameter AuthMethod` lists the ones it accepts. A read-only role such as **Reader** is a reasonable start; identity, networking, storage and directory checks can need more.

## AVD

### `00_AVD_Check_Deployment_Readiness.ps1`

Fifteen check areas: PowerShell environment, sign-in and subscription, resource providers, Entra ID, RBAC, network, endpoint connectivity, compute quota and VM SKU, storage and FSLogix, identity model (AD DS, Entra ID, Entra ID Kerberos, Entra Domain Services), monitoring, Key Vault, existing AVD resources and images. Read-only. English.

```powershell
.\AVD\00_AVD_Check_Deployment_Readiness.ps1 `
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

Add `-PassThru -NoExport` to use the result in a pipeline: it returns `Results`, `FailCount`, `WarnCount` and `PassCount`.

### `01_AVD_Validate_VMSizeAndQuota.ps1`

VM size and quota suitability: region and size discovery, minimum CPU and memory, workload category, deployment-ready sizes, optional pricing and accelerated networking. Choose the language with `-Language English`, `Spanish` or `Portuguese`, or from the menu.

```powershell
.\AVD\01_AVD_Validate_VMSizeAndQuota.ps1 `
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

Optional: `-IncludePricing`, `-IncludeOnlyAccelerated`.

### `02_AVD_Validate_Network_Configuration.ps1`

DNS, VNet peering, latency, session host join type and profile storage authentication. Language as for `01`.

```powershell
.\AVD\02_AVD_Validate_Network_Configuration.ps1 `
    -Language English `
    -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
    -AuthMethod ExistingContext `
    -NonInteractive
```

Optional: `-SkipDNSValidation`, `-SkipPeeringValidation`, `-SkipLatencyTest`. It also has remediation switches, `-EnableRemediation` and `-AutoFixAll`: review the proposed changes before using either.

### `03_AVD_Check_Platform_Prerequisites.ps1`

Platform-level AVD readiness for the whole tenant, whatever the deployment method (portal, ARM, Bicep, Terraform): subscription, resource providers, the AVD service principal and its roles, region and availability zones, Active Directory, the identity model, and VM SKU restrictions and quota, with alternatives when a SKU is blocked. English.

By default it asks before each change it could make (for example registering a resource provider), and the default answer is no. For a run that only reports:

```powershell
.\AVD\03_AVD_Check_Platform_Prerequisites.ps1 `
    -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
    -TargetRegion "eastus2" `
    -RemediationMode AssessOnly `
    -NonInteractive
```

To preview the safe changes without making them: `-RemediationMode Guided -ApplySafeRemediations -WhatIf`.

## Intune

### `00_INT_Check_Deployment_Readiness.ps1`

Microsoft Intune deployment readiness in twelve areas: Graph sign-in and permissions, tenant and MDM authority, licensing, device registration and automatic enrollment, enrollment restrictions, compliance and configuration policies for the chosen platforms, optional Windows Autopilot, Apple and Android connectors, Conditional Access that requires a compliant device, admin roles, and endpoint connectivity. Read-only: it only reads from Microsoft Graph. English.

```powershell
.\Intune\00_INT_Check_Deployment_Readiness.ps1 `
    -NonInteractive `
    -AuthMethod Interactive `
    -Platform Windows,iOS `
    -IncludeAutopilot `
    -ExportReport
```

## Identity

### `00_IDN_Check_Identity_Prerequisites.ps1`

Identity provisioning prerequisites for one identity model (`ADDS`, `EntraDS`, `EntraID` or `EntraIDKerberos`): directory synchronization, whether a test user has the right identity source, and the model's own dependencies. With `-Product AVD` (the default) it adds AVD's identity items: service principal, application group assignments, host pool sign-in properties, VM sign-in roles and FSLogix storage identity. `-CheckSsoConfiguration` adds single sign-on. Anything that cannot be read from Azure or Graph is reported with the exact command to check it by hand. Read-only. English.

```powershell
.\Identity\00_IDN_Check_Identity_Prerequisites.ps1 `
    -IdentityModel EntraID `
    -TenantId "YOUR-TENANT-ID" `
    -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
    -AuthMethod Interactive `
    -NonInteractive `
    -ExportReport
```

## Reports

`-ExportReport` writes an Excel report beside the script, or to `-ReportPath`. Reports contain tenant, subscription, resource and network details: review them before sharing.

## Security and privacy

- Never commit passwords, client secrets, private keys, certificates or exported credentials.
- Use the client's own Azure tenant, subscription and identity.
- Review any remediation option before allowing a change to an environment.

## License

MIT. See [LICENSE](LICENSE).
