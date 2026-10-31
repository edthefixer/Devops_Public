# Azure, Intune and Identity Validation Scripts

PowerShell scripts that check whether an environment is ready before anything is deployed: Azure Virtual Desktop (AVD), Microsoft Intune, and identity provisioning across cloud and on-premises.

Every script is self-contained: one `.ps1` file, no other file from this repository required. They report what is wrong, why it matters and how to fix it.

**They change nothing in your environment unless you explicitly ask.** The one script that can make a change, `02`, says so below. Signing in is the one side effect on the computer you run them from: some scripts sign out the Azure PowerShell account saved there first, as noted for each.

| Folder | Script | Checks |
| --- | --- | --- |
| `AVD` | `00_AVD_Check_Deployment_Readiness.ps1` | Broad AVD pre-deployment readiness |
| `AVD` | `01_AVD_Validate_VMSizeAndQuota.ps1` | VM size and quota (English, Spanish, Portuguese) |
| `AVD` | `02_AVD_Validate_Network_Configuration.ps1` | AVD network configuration (English, Spanish, Portuguese) |
| `Intune` | `00_INT_Check_Deployment_Readiness.ps1` | Microsoft Intune deployment readiness |
| `Identity` | `00_IDN_Check_Identity_Prerequisites.ps1` | Identity provisioning prerequisites |

Every script has full help, every parameter included. Read it before running:

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

Every script runs in the window you start it from: Windows PowerShell 5.1, PowerShell 7 or **PowerShell ISE**. In ISE, type that line in the console pane before pressing F5, and open the script from its file rather than pasting it into a new tab.

## Signing in

Sign in to **your own** tenant and subscription. Never use credentials belonging to the repository owner or another organization.

Run any script with no parameters for a guided setup that asks how to sign in, or pass `-NonInteractive` with the settings shown below for unattended runs.

Three scripts take an `-AuthMethod` parameter:

| Value | Sign-in | `00_AVD` | `00_INT` | `00_IDN` |
| --- | --- | --- | --- | --- |
| `ExistingContext` | The Az session you already have (`Connect-AzAccount`); the default where offered | ✓ | ✓ | |
| `Interactive` | Browser sign-in | ✓ | ✓ | ✓ |
| `DeviceCode` | Device code sign-in | ✓ | ✓ | ✓ |
| `ServicePrincipalSecret` | App registration with a client secret | ✓ | ✓ | |
| `ServicePrincipalCertificate` | App registration with a certificate | ✓ | ✓ | ✓ |
| `ManagedIdentity` | The managed identity of the machine running the script | ✓ | ✓ | ✓ |

`01` and `02` have no `-AuthMethod`. They always sign in afresh, with a choice of methods in the guided setup and browser sign-in when unattended.

A read-only role such as **Reader** is a reasonable start; identity, networking, storage and directory checks can need more.

## AVD

### `00_AVD_Check_Deployment_Readiness.ps1`

Fifteen check areas: PowerShell environment, sign-in, subscription, resource providers, Entra ID, RBAC, network, endpoint connectivity, compute quota and VM SKU, storage and FSLogix, identity model (AD DS, Entra ID join, Entra ID Kerberos, Entra Domain Services), monitoring, Key Vault, existing AVD resources, and images. Read-only. English.

Choosing `Interactive` or `DeviceCode` sign-in first signs out the account Azure PowerShell currently holds on the computer; `ExistingContext` leaves it alone.

```powershell
.\AVD\00_AVD_Check_Deployment_Readiness.ps1 `
    -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
    -TenantId "YOUR-TENANT-ID" `
    -TargetRegion "eastus2" `
    -VmSku "Standard_D4s_v5" `
    -PlannedSessionHosts 10 `
    -IdentityModel All `
    -AuthMethod Interactive `
    -NonInteractive
```

Add `-PassThru -NoExport` to use the result in a pipeline: it returns `Results`, `FailCount`, `WarnCount` and `PassCount`.

### `01_AVD_Validate_VMSizeAndQuota.ps1`

VM size and quota suitability: region and size discovery, minimum CPU and memory, workload category, deployment-ready sizes, optional pricing and accelerated networking. Read-only. Choose the language with `-Language English`, `Spanish` or `Portuguese`, or from the menu.

Every run signs in afresh, and first signs out the Azure PowerShell sign-in saved on the computer, so other Azure PowerShell sessions there will need to sign in again. Unattended runs need `-TenantId`, `-SubscriptionId` and `-Location`:

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

Optional: `-IncludePricing`, `-IncludeOnlyAccelerated`. `-DeploymentReadyOnly $false` also lists the sizes the subscription cannot deploy yet, marked as not ready.

### `02_AVD_Validate_Network_Configuration.ps1`

Virtual networks and subnets, the NSG rules AVD needs, DNS and private DNS zones, VNet peering, routing and latency, plus what the session host join type and profile storage authentication require of the network. Language as for `01`.

Every run signs in afresh, and first signs out the Azure PowerShell sign-in saved on the computer, as `01` does.

```powershell
.\AVD\02_AVD_Validate_Network_Configuration.ps1 `
    -Language English `
    -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
    -SessionHostJoinType MicrosoftEntraID `
    -ProfileStorageAuthentication MicrosoftEntraKerberos `
    -NonInteractive
```

Optional: `-SkipDNSValidation`, `-SkipPeeringValidation`, `-SkipLatencyTest`.

It is read-only unless you ask for changes. `-EnableRemediation` offers to fix what it found (a missing NSG rule, a missing private DNS zone, a peering problem, a blocking route), asking before each change. `-AutoFixAll` with it makes every fix **without asking**: run without either first and review the findings.

## Intune

### `00_INT_Check_Deployment_Readiness.ps1`

Microsoft Intune deployment readiness in twelve areas: PowerShell environment, Graph sign-in and permissions, tenant and MDM authority, licensing, device registration and automatic enrollment, enrollment restrictions, compliance and configuration policies for the chosen platforms, optional Windows Autopilot, Apple and Android connectors, Conditional Access that requires a compliant device, admin roles, and endpoint connectivity. Read-only: it only reads from Microsoft Graph. The guided setup shows the tenant you signed in to, and lets you continue with it or name another by its domain. Its sign-in lasts for the run only and leaves other sessions on the computer alone. English.

```powershell
.\Intune\00_INT_Check_Deployment_Readiness.ps1 `
    -NonInteractive `
    -AuthMethod Interactive `
    -Platform Windows,iOS `
    -IncludeAutopilot
```

## Identity

### `00_IDN_Check_Identity_Prerequisites.ps1`

Every prerequisite Microsoft documents for one identity model, the way users and machines authenticate: `ADDS` (Active Directory Domain Services), `EntraDS` (Microsoft Entra Domain Services), `EntraID` (Microsoft Entra join) or `EntraIDKerberos` (Entra join with hybrid users and Entra Kerberos for Azure Files). One model per run; run it again to check another.

It checks directory synchronization, whether a test user has the right identity source, and the model's own dependencies: domain and DNS, Azure Files identity, sign-in roles and Conditional Access, as the model requires. `-CheckSsoConfiguration` adds single sign-on for RDP. Anything that cannot be read from Azure or Graph is reported with the exact command to check it by hand. Product-specific identity items, such as an AVD host pool's sign-in settings, are checked by that product's script.

The Excel report opens on a **Summary** sheet: the model checked, the tenant, who ran it and when, the verdict and the counts. Every requirement after it links to the Microsoft documentation it comes from, so it can be checked against the source. Read-only. One Azure sign-in reads both Azure and Microsoft Graph. It lasts for the run only: nothing is saved to disk, and an Azure PowerShell sign-in the window already had is put back afterwards. English.

```powershell
.\Identity\00_IDN_Check_Identity_Prerequisites.ps1 `
    -IdentityModel EntraID `
    -TenantId "YOUR-TENANT-ID" `
    -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
    -AuthMethod Interactive `
    -NonInteractive
```

## Reports

Every script writes an Excel report, by default beside the script. `00_AVD`, `00_INT` and `00_IDN` take a folder in `-ReportPath`; `02` takes a file name in `-ReportPath` and always writes beside the script. `-NoExport` turns the report off in `00_AVD`, `01`, `00_INT` and `00_IDN`.

Reports contain tenant, subscription, resource and network details: review them before sharing, and do not commit them to a repository.

## Security and privacy

- Never commit passwords, client secrets, private keys, certificates or exported credentials.
- Use the client's own Azure tenant, subscription and identity.
- Review any remediation option before allowing a change to an environment.

## License

MIT. See [LICENSE](LICENSE).
