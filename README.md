# ALF Lab Builder v2.0.14

A guided, script-based way to build a **nested Azure Local lab inside a single Azure VM**:
a domain controller, an admin station and a 2-node Azure Local cluster, all running as
Hyper-V VMs on one Azure "super-host".

It has consoles at each level of the lab:

- **1. ALF Lab Builder - Planning Console** (on your PC) keeps track of every name, IP address and Azure
  setting the lab needs, checks them, and "rolls out" the lab scripts with those values filled in.
- **2. ALF Lab Builder - Host Console** (on the lab host VM) runs the host-side steps for you and
  downloads the two install images with a progress bar.
- **3. ALF Lab Builder - Guest Consoles** (inside the DC, admin station and each node) guide
  role-specific configuration and record the student's checks.

Every
script explains what it's doing and why (look for the `LEARN:` notes), so the lab doubles
as a training exercise.

> **Lab use only.** A virtual (nested) deployment of Azure Local is for education and
> demonstration. It isn't supported by Microsoft Support and isn't suitable for production.

---

## Lab build guide

The local development folder contains `ALF-Lab-Build-Guide-v1.0.24.docx`, covering the lab platform,
cluster deployment, challenges and troubleshooting. The guide is not included in this repository
pending privacy review. A matching 2.0.14 guide remains pending.

## What you get

```
Azure VM (super-host, Hyper-V)
 |
 |-- InternalSwitchNAT  192.168.44.0/24  (NAT to the internet)
 |     |-- ContosoDC1     .101  domain controller, DNS, optional DHCP
 |     |-- ContosoADM1    .102  admin station: Failover Cluster Manager, Hyper-V Manager, RSAT
 |     |-- Nodes          .51 - .59   Azure Local nodes (node 1 = .51, node 2 = .52...)
 |     `-- .61 - .69            cluster resources range (infrastructure IPs)
 |
 `-- StorageSwitch (private) - node-to-node storage traffic only
```

## Requirements

| Where | What |
|---|---|
| **Your PC** (runs the Planning Console) | Windows 10/11 or Windows Server, Windows PowerShell 5.1 (built in). The Azure CLI for the Azure buttons: `winget install -e --id Microsoft.AzureCLI` |
| **Azure** | A subscription you can create resources in, and **Owner** or **User Access Administrator** to assign the deployment roles |
| **Host VM** | A size that supports nested virtualization, with **at least 96 GB RAM and 20 available vCPUs** for 2 nodes, DC, admin station and host reserve, and a **1 TB data disk**. Avoid sizes with local temporary disks (a "d" in the name) - they're wiped when the VM stops. |
| **Images** (downloaded by script 01) | Windows Server 2025 evaluation VHDX, and the Azure Local ISO |

## Quick start

1. **Download** this folder to your PC and unblock it once (PowerShell, in the folder):
   ```powershell
   Get-ChildItem *.ps1, *.cmd | Unblock-File
   ```
   For a repository checkout, create your local planning file without replacing an existing plan:
   ```powershell
   if (-not (Test-Path -LiteralPath .\LabValues.json)) {
       Copy-Item -LiteralPath .\LabValues.example.json -Destination .\LabValues.json
   }
   ```
   The committed starter has private values and machine-specific folder paths cleared. Your live
   `LabValues.json`, generated `Rollout` files and console progress are ignored by Git; keep them local.
2. **Open the Planning Console:** double-click `Launch-ALFLabBuilder.cmd`.
3. **Choose your Cluster identifier** at the top of the Planning Console, then click **Apply identifier**.
   Saved plans retain their chosen identifier when upgrading; version changes do not rename the lab. If a plan has no identifier, the release-derived default is `2014` for 2.0.14 (2.0.14). Choose exactly four digits meaningful to you; leading zeros such as `0042` are kept.
   **Apply identifier** updates all eleven numbered lab names and refreshes the commands; typing alone does not apply a change.
   Fill in at least your **Tenant ID** and **Subscription ID** (group 1, "Getting started"). Key vault and storage account names must still be globally unique across Azure; a four-digit identifier alone does not guarantee availability.
   Select **Check values** until everything shows OK, then **Save values** to keep your identifier and plan.
4. **Prepare Azure** (group 4 has the resource group, region and copyable CLI commands) or use the Azure buttons:
   **1. Create resource groups**, **2. Assign roles on RG**, **3. Review Azure Policy**.
5. **Roll out scripts.** The filled-in scripts are written to the `Rollout` folder.
6. **Create the host VM** with `00.Workstation-CreateHostVM.ps1`, then copy everything in the `Rollout` folder to `C:\ISO` on the host VM.
7. **On the host, start the Host Console** (`Launch-ALFHostConsole.cmd` in `C:\ISO`) and work down its steps. Or run the scripts in order (below) yourself.

## Build order

| # | Script | Runs on | What it does |
|---|---|---|---|
| 00 | `00.Workstation-CreateHostVM.ps1` | Your PC / Cloud Shell | Creates the Azure host VM with a 1 TB data disk; RDP open to your IP only |
| 01 | `01.Host-PrepareDataDisk.ps1` | Host VM | Creates `C:\ISO`, formats the data disk as `F:`, downloads both images |
| 02 | `02.Host-InstallHyperV.ps1` | Host VM | Installs Hyper-V and its tools (asks before restarting) |
| 03 | `03.Host-CreateVMSwitches.ps1` | Host VM | Creates the NAT switch, the storage switch and the gateway firewall rule |
| 04dc | `04dc.Host-CreateDCVM.ps1` | Host VM | Creates ContosoDC1 from the evaluation VHDX |
| 04adm | `04adm.Host-CreateAdminStationVM.ps1` | Host VM | Creates the admin station VM |
| 05 | `05.Host-CopyScriptsToVM.ps1` | Host VM | Copies the DC and admin station scripts into those VMs (no network needed) |
| 06dc | `06dc.DC-SetNameAndIP.ps1` | ContosoDC1 | Static IP, time zone, computer name |
| 07dc | `07dc.DC-CreateForest.ps1` | ContosoDC1 | Installs AD DS and DNS, creates the `contosolab.local` forest |
| 08dc | `08dc.DC-PostConfig.ps1` | ContosoDC1 | DNS forwarders, reverse zone, optional DHCP |
| 08adm | `08adm.Admin-Configure.ps1` | Admin station | IP, DNS, management tools, rename and domain join |
| 09dc | `09dc.DC-PrepareADForAzureLocal.ps1` | ContosoDC1 | Installs the AD preparation module; optionally creates the cluster OU and LCM account |
| 10 | `10.Host-CreateNodeVMs.ps1` | Host VM | Creates the node VMs (vTPM, nested virtualization, 4 data disks, 4 NICs) and boots the ISO |
| - | *Install the Azure Local OS on each node and set the Administrator password* | Node console | |
| 11 | `11.Host-PrepareNodes.ps1` | Host VM | Renames the NICs inside each node and copies each node its own filled-in scripts |
| 12 | `12.Node-Configure.ps1` | Each node | IP, DNS, time zone, second local admin, cleans the data disks, RDP, name |
| 13 | `13.Workstation-AzurePrereqs.ps1` | Your PC / Cloud Shell | Resource providers, roles, and a policy review (same as the Azure buttons) |
| 14 | `14.Node-ArcRegister.ps1` | Each node | Registers the node with Azure Arc (device code sign-in) |
| 15 | `15.Workstation-PolicyReview.ps1` | Your PC / Cloud Shell | Shows which Azure Policies act on the registered nodes; optional approved exemptions |
| - | *Deploy Azure Local from the Azure portal* | Browser | Values are in Planning Console section 7 |

**Script names:** the suffix after the number says where a script runs or what it's for - `dc` for
the domain controller (ContosoDC1: 06dc, 07dc, 08dc, 09dc, plus 04dc, which creates it on the host)
and `adm` for the admin station (08adm, plus 04adm, which creates it on the host). In File Explorer
`08adm` sorts above `08dc`; run 08dc first, because 08adm needs the domain controller finished.

Every script checks before it acts and is **safe to run again**.

### Section 2: SuperHost and guest allocations

Start with **SuperHost RAM** (default/minimum **96 GB**) and **SuperHost available vCPUs** (default/minimum **20**). Keep **Reserve RAM for SuperHost** at **16 GB** by default, or adjust the reserve. CPU/RAM values are positive whole numbers; GB here means the binary unit used by PowerShell/Hyper-V.

| Guest | Default/minimum vCPUs | Default/minimum static RAM |
|---|---:|---:|
| ContosoDC1 | 2 | 2 GB |
| Planned admin station (ContosoADM1) | 2 | 4 GB |
| Each Azure Local node | 12 | 36 GB |

All allocations can increase when the host can accommodate them. The two nodes share one sizing choice, counted twice; host-console node-name overrides retain this allocation. The live summary shows guest RAM, allocatable RAM after reserve, RAM left for the host and combined guest CPUs. The defaults use **78 GB guest RAM**, leave **18 GB** for the host and assign **28 shared guest vCPUs** on **20 host vCPUs**. CPU overcommit warns rather than blocking; a single guest cannot exceed the host CPU count. Guest RAM plus reserve exceeding host RAM is an error and blocks host-command copying and rollout. Saving an unfinished plan is still allowed.

**SuperHost RAM is a planning declaration, not an Azure memory setting.** For the default D48als_v7, RAM must remain 96 GB; to use more RAM, select a matching larger SKU and enter its memory. Refreshed metadata checks other known SKUs. Unknown SKU RAM produces a warning; the declared RAM is used for budgeting until verified. Changing available vCPUs does not change a SKU's memory.

Rollout includes `ALFGuestSizing.ps1`; keep it beside the Planning Console, script 00 and the guest-creation scripts. Scripts **04dc**, **04adm** and **10** use the planned CPU/RAM at VM creation and check actual SuperHost capacity before creating disks/VMs. Script 00 checks the whole budget and known SKU memory before creating Azure resources. **Existing VMs are not resized automatically**; the planning choices apply to new guest creation. Upgrades add missing sizing fields without changing existing student values, names or paths. The node default is now **12 vCPUs**, not the previous hard-coded 8.

### SuperHost SKU and Azure CPU options

**Host VM size (SKU)** is the first field in section 2, so choose the host type before entering its capacity.

**On-premises SuperHost:** choose **Custom (on-premises)** in **Host VM size (SKU)**, then enter the host's available logical processors in **SuperHost available vCPUs** and memory in **SuperHost RAM**. No Azure SKU refresh, 48-vCPU ceiling or SKU-memory matching is applied to this choice. The 20-CPU/96-GB lab minimums, guest minimums, CPU-sharing warning, RAM reserve and actual host-capacity checks still apply. Save and roll out normally; the choice remains available after Azure-size refreshes and reloads.

Use an existing Windows/Hyper-V SuperHost with the lab's required storage and virtual switches. Copy the rollout to its `C:\ISO` and use the host-side steps; **skip script 00**. The Azure host-creation command shows **Not applicable** and cannot be copied for this choice; script 00 stops before Azure sign-in or resource creation. This option does not provision or resize an on-premises host. Azure prerequisites for Arc and cluster deployment remain unchanged.

The **Host VM size (SKU)** row has an editable selector and **Refresh Azure sizes** button. The initial choice is **Standard_D48als_v7** (48 maximum vCPUs, 96 GiB RAM); **Available vCPUs** initially requests **20**. A saved selection is retained when refreshing or upgrading.

1. Sign in to Azure CLI using your organization's approved process and enter the subscription ID in section 1.
2. Optionally click **Refresh Azure sizes** in section 2. This read-only query lists subscription-accessible South Central US sizes advertising nested virtualization, Premium SSD, at least 96 GiB RAM and 20 maximum vCPUs and no temporary local disk. It does not guarantee capacity or quota. The default Standard_D48als_v7 can be planned offline using its documented maximum of 48; other sizes need metadata to establish their maximum.
3. Choose a size, edit **Available vCPUs**, then **Check values**. Positive whole-number requests up to the known SKU maximum pass local validation. Default **20 / 48 max** remains allowed even without an Azure refresh or a reduced-count list. Missing or unlisted CPU-option metadata shows **Check Azure** and a warning; it is not a planning error. Azure may still reject that count during creation.
4. **Save values**, then copy the create command or **Roll out scripts**. Metadata warnings do not block either action or substitute 48 for your requested 20. Invalid/nonpositive counts, counts above the maximum, and unknown maxima for nondefault sizes still block copy/rollout. Azure capability results are not persisted as a permanent availability guarantee.

Both the copyable command and script 00 pass `--size` and `--v-cpus-available`. Script 00 retains the plan's **ArcRegion**; it checks the maximum, reports metadata warnings and lets Azure enforce CPU-option support during creation. A failed SKU query can fall back to the documented default maximum, but it cannot guess another size's maximum. The copyable command remains fixed to **southcentralus**. Use one creation method, not both. Keep `ALFHostSizing.ps1` beside script 00 and the Planning Console.

Constrained vCPUs retain the base SKU's memory/I/O and **do not reduce its base VM price**. Do not assume the requested available count equals regional/family quota usage; verify usage/limits with Azure's Quotas page or `az vm list-usage --subscription <subscription> --location southcentralus -o table`. Azure may reject a deployment despite valid SKU metadata because quota or capacity is insufficient. See [VM vCore customization](https://learn.microsoft.com/en-us/azure/virtual-machines/vm-customization) and [vCPU quotas](https://learn.microsoft.com/en-us/azure/virtual-machines/quotas).

## 1. ALF Lab Builder - Planning Console (on your PC)

| Area | What it does |
|---|---|
| **Cluster identifier + Apply identifier** | Enter four digits, then apply them across the host/cluster resource groups, host VM, cluster, OU, LCM account, both nodes, key vault, custom location and witness storage account. Commands refresh immediately; Save values and Roll out scripts afterward | 
| **Coloured sections** | Blue sections (1-3 and 8) are for building the lab; purple sections (4-7) are for building the Azure Local cluster |
| **Values table** | Every lab value, grouped, with a help panel explaining what it is, its rules and where it's used |
| **Status column** | `OK`, `Missing`, `Check rule`, `Duplicate`, `Not in network`, `In a range`, `Too small`... |
| **Network checks** | Every IP inside the lab network, no duplicates, nothing inside the node, cluster resources or DHCP ranges, no overlapping ranges, cluster resources range of at least 6 addresses |
| **Password rows** | Reminders only - except the optional second local admin password, saved in plain text if you enter it |
| **Azure CLI rows** | Double-click to copy resource-group commands or the host VM creation command immediately after Azure VM name in section 2 |
| **Azure buttons** | Create the resource groups, assign the deployment roles, review Azure Policy - each in its own PowerShell window |
| **Roll out scripts** | Copies every script to the rollout folder with `{{Placeholders}}` replaced by your values |
| **Export for sharing** | Writes `LabValues.shareable.json` with private values (tenant ID, subscription ID) and folder paths removed |

**Section 2 host VM command:** the **Azure CLI - create host VM** row immediately after **Azure VM name** creates a Windows Server 2025 Gen2 VM with **Standard_D48als_v7** in **southcentralus**. It uses the selected subscription, the host resource group created above, VM name and administrator account. Double-click to copy, then run in interactive PowerShell after signing in with `az login --tenant <tenant ID>`, or Azure Cloud Shell (PowerShell). The administrator password is prompted, not recorded in the plan. The command includes a 256 GB OS disk and 1024 GB data disk on Premium SSD. Check SKU availability, quota and nested-virtualization support in your subscription before deploying.

Use that command **or** script 00 to create the host. The new command leaves inbound RDP closed and does not configure nightly shutdown; those are additional steps in script 00, which still uses Standard_E16s_v5. Before connecting, add an approved RDP rule restricted to your source address or use your organization's approved access method. The command's region stays southcentralus even if the cluster Region value changes.

**Section 6 - Nodes ranges:** the first/last **Node IP range** and first/last **Cluster resources range** fields are grouped under **6. Nodes**, not **3. Lab network**. Their placeholders, saved IP values and subnet/range-overlap validation are unchanged.

**Applying an identifier changes the plan, not existing Azure resources.** Regenerate the rollout before using it for a new cluster. Invalid or unapplied identifiers block saving, command copying/generation, Azure preparation and rollout so an old identifier is not used accidentally. Prefixes, suffixes and OU parent paths containing the previous identifier are retained. If you remove the identifier from a numbered name manually, applying a new identifier regenerates that name from its stored naming template. Other values, including IDs, IP addresses, passwords and disk sizes, are not changed.

The chosen identifier and naming templates are saved in `LabValues.json` and retained by **Export for sharing**. Older plans without this metadata keep their existing names on load; the identifier is inferred from a four-digit cluster-name suffix when available.

To add a value: add an entry to `LabValues.json`, then put `{{YourKey}}` in the scripts.

## 3. ALF Lab Builder - Guest consoles (inside the nested VMs)

After **Roll out scripts**, copy the complete rollout to the host's `C:\ISO`. Host step **05** delivers the DC/admin consoles with their scripts; host step **11** delivers the node console to each node alongside its own generated configure script.

| Guest | Launcher in `C:\ISO` | Guided order |
|---|---|---|
| Domain controller | `Launch-ALFDCConsole.cmd` | Windows setup checkpoint -> 06dc name/network -> 07dc forest/promotion -> 08dc DNS/DHCP -> 09dc cluster OU and LCM account |
| Admin station | `Launch-ALFAdminConsole.cmd` | DC readiness checkpoint -> 08adm network, management tools, name and domain join -> domain sign-in/management checkpoint |
| Each Azure Local node | `Launch-ALFNodeConsole.cmd` | OS/host step 11 checkpoint -> 12 node configuration -> Azure/other-node prerequisite checkpoint -> 14 Arc registration -> policy/portal handoff |

These are three role-specific graphical views of the shared `ALFGuestConsole.ps1`, with `ALFGuestStepRunner.ps1` running a selected script in a separate PowerShell window. Each step explains **why**, **what changes**, **prerequisites**, **restart behavior**, and **checks afterward**. Existing scripts are not split or run automatically: 08adm and 12 still perform their multiple stages in one script. **Node step 12 cleans eligible data disks and removes old storage pools; read its destructive-operation warning carefully.**

All three guest views use the Host Console theme: blue headings and version badge, white step cards, numbered blue circles that turn green only after **student confirmation**, a separate status column and right-hand action buttons. Running status is blue; unresolved results are amber; script errors are red. Text labels remain visible so color is not the only indicator. A successful script return alone never turns a circle green.

**Refreshing an existing guest:** v2.0.14 accepts saved progress from v2.0.7/v2.0.8/v2.0.9/v2.0.10/v2.0.11/v2.0.12 for the same role. Close the guest console and deliver the matching v2.0.14 files to its `C:\ISO`, retaining its `ALFGuestConsole-<Role>-State.json` and execution receipts. Host step 05 can redeliver DC/admin files and step 11 can redeliver each node's correct files, or copy the matching role files manually. Do not copy a different node's configure script or rerun destructive node configuration merely to update the console's appearance.

**DC desktop shortcut:** host script `05.Host-CopyScriptsToVM.ps1` creates `C:\Users\Administrator\Desktop\ALF DC Console.lnk` inside ContosoDC1, pointing directly to `C:\ISO\Launch-ALFDCConsole.cmd`. This targets the local Administrator's default desktop, not a domain account's separate profile or the host desktop. Rerunning host step 05 refreshes the shortcut without running DC configuration. If shortcut delivery fails, a warning is shown and the launcher remains accessible in `C:\ISO`.

Choose **Run step**, answer that script's credential/sign-in prompts, and check its output. After any required restart, sign back in and reopen the same launcher. Choose **Check and confirm** only after personally verifying the listed results. The console distinguishes **Running**, **Script returned - check result**, **Last run failed**, **Interrupted / restarted - check result**, and **Student confirmed**. A successful script exit is not proof of correct configuration. Prerequisites are gated by student confirmations, and rerunning a step clears downstream confirmations. Cross-VM and Azure prerequisites are explicit student checkpoints, not automatic health claims.

Role-specific state (`ALFGuestConsole-<Role>-State.json`) and per-run execution receipts stay beside the scripts and contain no credentials. Reopening the console preserves progress and recognizes an already-running step by process identity. Closing the console does not stop its script. Do not copy a node-specific configure script or another machine's state into a different node. The last node checkpoint means ready for workstation policy review and portal deployment, **not** that a cluster was deployed.

**GUI compatibility trial:** at your request, all three roles attempt WPF. Azure Local/Server Core installations may lack the required WPF components. Start from SConfig option 15: `cd C:\ISO`, then `.\Launch-ALFNodeConsole.cmd`. If WPF cannot load/create a window, the console reports the problem and runs no configuration; report that result and use the numbered scripts individually. No GUI features are installed automatically. New guest launchers do not bypass execution policy or unblock files. If execution is blocked, follow your organization's approved script-signing process rather than weakening Windows protections.

## 2. ALF Lab Builder - Host Console (on the lab host)

`Launch-ALFHostConsole.cmd` opens a window on the host VM that runs the host-side steps for you.
It asks for administrator rights and expects to run from `C:\ISO`, with the rolled-out scripts.

| Step | What it runs |
|---|---|
| 1. Prepare the data disk | `01.Host-PrepareDataDisk.ps1 -DiskOnly` - time zone, `F:`, `C:\ISO`, `F:\VMs` |
| 2. Download the Windows Server 2025 evaluation VHDX | Downloads in the console, with a progress bar |
| 3. Download the Azure Local ISO | Downloads in the console, with a progress bar |
| 4. Install Hyper-V | `02.Host-InstallHyperV.ps1` (restarts the host - open the console again afterwards) |
| 5. Create the virtual switches | `03.Host-CreateVMSwitches.ps1` |
| 6. Create the domain controller VM | `04dc.Host-CreateDCVM.ps1` |
| 7. Create the admin station VM | `04adm.Host-CreateAdminStationVM.ps1` |
| 8. Copy the scripts into the DC and admin station | `05.Host-CopyScriptsToVM.ps1` |
| 9. Create the Azure Local node VMs | `10.Host-CreateNodeVMs.ps1` |
| 10. Prepare the nodes | `11.Host-PrepareNodes.ps1` - shows the exact step-9 destination VM names and verifies console/script copies inside each VM |

- **Step 9 node names:** edit **First node name** and **Second node name**, then click **Apply node names** before Run. For example, change `AzL2001Node1` / `AzL2001Node2` to `AzL2001Node3` / `AzL2001Node4`. Both node steps are disabled while edits are unapplied. Names must be distinct, 1-15 letters/digits/hyphens, start with a letter/digit, and not be entirely numeric; they cannot match the host, DC or admin station.
- The applied pair is saved on the host in `ALFHostConsole-Nodes.json` beside the scripts. **Steps 9 and 10**, their status checks, and scripts 10/11 run manually all use it. Script 11 generates each node's configure script with the selected name. The first field retains the first planned node IP; the second retains the second IP. This remains a two-node lab, not an add-two-more-nodes feature.
- **Step 10 destinations and console:** the card shows the two applied VM names and the files copied to `C:\ISO` **inside each selected VM**. Look for `Launch-ALFNodeConsole.cmd`, `ALFGuestConsole.ps1`, `ALFGuestStepRunner.ps1`, `12.Node-Configure.ps1` and `14.Node-ArcRegister.ps1`. There is no standalone `ALFNodeConsole.ps1`; the launcher opens the shared console with `-Role Node`.
- Step 10 uses PowerShell Direct to verify every delivered file's SHA-256 against the host copy. Missing/stopped VMs, failed guest sign-in, adapter errors, copy failures or missing/mismatched guest files make the step fail, with per-VM results. A verified-delivery receipt is saved to `C:\ISO\Generated\<VMName>\ALFNodeDelivery.json` **on the host** only after verification. The Host Console no longer treats a generated host script as proof of delivery. Status reports the last verification time; it is not continuous monitoring of guest files. If files disappear later, rerun step 10 to verify/deliver again. Old generated folders without receipts require a rerun.
- **v2.0.14 fixes a false duplicate-destination error** in step 10 even with zero extra files. Refresh the host scripts and rerun step 10; do not delete NodeFiles contents merely because an older version reported a duplicate. A genuine collision now names the guest path and both source files.
- When troubleshooting, keep the complete current rollout in host `C:\ISO`, retain `ALFHostConsole-Nodes.json`, check the applied VM names in step 9, then rerun step 10 and read its per-VM summary. Do not rerun guest configuration step 12 merely to obtain the console; that step can clean data disks.
- Applying does **not** rename/delete existing VMs, change the Planning Console plan, or change cluster/resource names. Node run history is tied to the selected pair. To revert, re-enter the planned names and Apply (or close the console and remove `ALFHostConsole-Nodes.json`). Keep this host-local file when refreshing rollout files. The v2.0.14 helper `ALFNodeSettings.ps1` must be copied with the host scripts.
- **Run** opens the script in its own PowerShell window, so you can read its output and answer its
  questions. The console marks the step done when the window closes.
- **Status** is read from the host itself (is `F:` there, is Hyper-V installed, does the VM exist),
  so it's right even if you ran a script by hand. **Refresh status** checks again.
- **Downloads** use BITS, show size, speed and time left, and carry on if you close the console -
  open it again to see the progress. If BITS fails, the console switches to a direct download.
  The image names and links come from `01.Host-PrepareDataDisk.ps1`; **Open page** opens the
  download page if a link has expired.
- Steps that should be done first are checked, and you're warned (not blocked) if they aren't.
- A yellow banner warns if the scripts aren't rolled out, aren't in `C:\ISO`, or are from a different version.


**Host and guest time zones are optional:** scripts 01, 06dc, 08adm and 12 attempt the planned Windows time-zone ID. Any ID unavailable on the destination, including `Manitoba Standard Time`, falls back to `Eastern Standard Time`. If Eastern is also unavailable, or lookup/setting fails, a warning is printed and setup continues. Blank/unfilled values keep the current zone. Host Console step 1 (`-DiskOnly`) follows the same rule; actual disk/folder errors still fail normally. This changes display time only, not time synchronization, and the requested plan value is retained. Do not rerun the complete node-configure script just to change its time zone, because its storage cleanup is destructive.

Scripts ask for passwords when they're needed: the host VM admin (00), DSRM (07dc), the LCM
account (09dc) and the nodes' built-in Administrator (11). They're never saved or displayed.

**One exception, by choice:** the **second local admin password** (Lab Builder group 6) can be
entered in the Lab Builder. It's then saved in **plain text** in `LabValues.json` and injected
into `12.Node-Configure.ps1` (and the per-node copies script 11 makes), so the nodes are configured
without typing it. Leave it empty and script 12 asks for it on each node instead.
**The security of the JSON file and the rolled-out scripts is your responsibility.**
`Export for sharing` empties it.

**Choosing and remembering passwords is your responsibility.**

## Things to know

- **Hyper-V Time Synchronization is disabled for all four nested VMs** (ContosoDC1, the admin station and both selected Azure Local nodes) by creation scripts 04dc/04adm/10. Guest Service Interface remains enabled for file delivery. Windows Time inside the guest retains its configured source; domain members normally follow the domain hierarchy (ContosoDC1 in this single-DC lab). The lab does not set manual NTP peers or change Windows Time policy. The DC's upstream source still needs to be valid/reachable; disabling integration does not by itself configure upstream NTP. Check `w32tm /query /source` in each guest after startup/domain join. Time-zone selection is a separate optional display setting.
- **Existing VMs:** after refreshing host rollout files, host step **8** (script 05) disables Time Synchronization for DC/admin and step **10** (script 11) disables it for the applied node pair, without recreating VMs or running guest storage cleanup. To change only this integration setting, untick **Time synchronization** in Hyper-V Manager for each of those four VMs; leave other integration services unchanged. Do not rerun creation scripts to recreate the DC/admin.

- **Azure Policy in customer tenants.** Inherited policies can act on the nodes as soon as they
  register with Arc - the symptom is nodes showing *Connected* while deployment operations time
  out. Review policies before and after registration (Azure button 3, scripts 13 and 15) and
  agree any exemptions with the customer.
- **Globally unique names.** Key vault and storage account names are unique across all of Azure.
  Deleted Key vaults keep their name for up to 90 days unless purged.
- **Spot VMs** are cheap for building, but can be evicted during the ~2.5-hour deployment.
  A Spot VM can't be switched to regular pricing - it has to be recreated from its disks.
- **Licences.** The Windows Server evaluation lasts 180 days; the Azure Local download includes a
  60-day trial.

## Version

**2.0.14** - see `CHANGELOG.md`. The version is shown at the top of the Lab Builder window, in `VERSION.txt`, in the zip file name and in the header of every script (`# Version: ALF Lab Builder x.y.z`), so a single file copied in on its own can be identified. **Roll out scripts** warns about any script from a different version. It goes up with every change.
