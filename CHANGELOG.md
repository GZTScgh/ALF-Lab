# Changelog

The version goes up with every change. It's shown at the top of the Lab Builder window,
in `VERSION.txt` and in the zip file name (`ALF-LabBuilder-v<version>.zip`).

## 2.0.16
- Simplify guest consoles to runnable setup cards (DC 4, Admin 1, Node 2), short descriptions and a handoff note, using the Host Console layout and green/blue status theme.
- Replace student confirmation with read-only configuration detection; keep restart/error indicators, process identity and execution receipts. Old confirmations are ignored, and incomplete prerequisites warn rather than gate progress.
- Detect generated node name/IP overrides and Arc bootstrap plus connected-agent target. Protect existing cluster storage from destructive setup reruns; optional AD OU/account creation is not claimed complete.
- Add an optional 1600 x 900 current-session display button on DC/Admin with supported-mode testing and client-controlled/unsupported warnings.
- Deliver/hash-check the new status/display helpers, add focused mock/layout cases and refresh matching rollout while preserving saved/private values and both desktop shortcuts.

## 2.0.15
- Add ALF Admin Console.lnk to the local Administrator desktop inside the planned admin station during host script 05 delivery, targeting C:\ISO\Launch-ALFAdminConsole.cmd.
- Reuse a shared shortcut helper for DC/admin while preserving the existing DC destination, launcher and description. Retry refreshes shortcuts without guest configuration; failures warn and temporary host shortcuts are cleaned up.
- Add focused DC/admin delivery and cleanup cases; preserve saved planning values, sanitized starter settings and compatible guest progress while refreshing matching rollout files.

## 2.0.14
- Make the host script 01 time-zone change optional, including Host Console step 1 with -DiskOnly. Any unavailable requested ID falls back to Eastern Standard Time; missing Eastern or lookup/set failures warn and continue. Actual disk/folder errors still fail normally.
- Apply the same general fallback to DC, admin-station and node configuration, replacing the Manitoba-only rule. Preserve the requested plan value, time-synchronization settings and student progress.
- Add mocked host/guest fallback cases and host -DiskOnly continuation checks; update guidance and matching rollout files.

## 2.0.13
- Place Host VM size (SKU) first in Planning Console section 2, including after plan migration/reload. Preserve the other fields' relative order and all selected values.
- Include the Custom (on-premises) option from the update below; retain manual CPU/RAM planning and safe Azure-host creation guards.

## 2.0.12
- Add Custom (on-premises) to the host-size selector, retaining it through Azure-size refreshes and plan reloads. Custom CPU/RAM is entered manually without Azure SKU ceilings or memory matching; existing minimums, guest budgets, reserve and actual host checks remain enforced.
- Mark the Azure host-creation command not applicable and prevent copying it for custom hosts; script 00 refuses this mode before Azure sign-in or resource creation. Other Azure cluster prerequisites and Azure-host behavior are unchanged.
- Preserve saved selections and guest progress, add focused custom-sizing cases and refresh matching rollout files.

## 2.0.11
- Move both Node IP range bounds and both Cluster resources range bounds from Planning Console section 3 (Lab network) to section 6 (Nodes), placed together after the node names.
- Preserve saved addresses, placeholder keys and subnet/range checks. Refresh matching release/rollout files without retargeting student settings; keep existing guest progress compatible.

## 2.0.10
- Add editable SuperHost RAM (96-GB minimum/default), host RAM reserve (16-GB default), and guest CPU/static-RAM allocations: DC 2/2 GB, admin 2/4 GB, each of two identically sized nodes 12/36 GB. Increase allocations within the host budget; missing fields migrate without retargeting saved plans.
- Show a live planning budget. Default 28 guest vCPUs share 20 host vCPUs with a warning; default guests use 78 GB and leave 18 GB for the host. Enforce guest minimums, individual guest CPU limits, RAM reserve and known Azure SKU-memory consistency while keeping CPU-support metadata advisory.
- Apply selected sizing in scripts 04dc, 04adm and 10; check actual host capacity before provisioning. Script 00 validates the whole budget before creating resources. Existing VMs are not resized automatically; Azure Local node creation now defaults to 12 instead of 8 CPUs.
- Add focused budget/migration/host-capacity cases, preserve prior guest-console state compatibility and refresh v2.0.10 rollout.

## 2.0.9
- Add a local Administrator desktop shortcut inside ContosoDC1 during host script 05 delivery, pointing to C:\ISO\Launch-ALFDCConsole.cmd. Repeat delivery refreshes it without running DC configuration; shortcut failures warn and temporary host files are cleaned up.
- Include the guest-theme update below, preserve same-role v2.0.7/v2.0.8 progress and retain all student values while refreshing matching release/rollout files.

## 2.0.8
- Match DC, Admin Station and Azure Local Node consoles to the Host Console: blue headings/version badge, white step cards, numbered blue indicators turning green only after student confirmation, a separate status column and aligned action buttons.
- Use the Host Console's blue running, green confirmed, amber check-result and red failure status colors. Keep result labels, learning/check instructions, explicit confirmation, prerequisite gating and restart-aware execution unchanged.
- Retain the v2.0.7 progress schema for the appearance-only update. This update is included with the v2.0.9 shortcut change rather than published separately.

## 2.0.7
- Fix overstrict host CPU validation: allow the requested 20 vCPUs on Standard_D48als_v7 using its documented 48-vCPU maximum, without requiring a live SKU refresh. Missing or unlisted reduced-core metadata now produces a warning rather than blocking planning, command copy or rollout.
- Retain positive whole-number and maximum checks. Nondefault SKUs need metadata to establish their maximum; never silently replace 20 with the full count. Script 00 follows the same policy and Azure remains authoritative for CPU-option support, capacity and quota during creation.
- Invalidate stale discovery context after failed refreshes; show requested/max counts separately from support warnings. Add focused regression cases and preserve student selections while incrementing release metadata.

## 2.0.6
- Disable Hyper-V Time Synchronization when creating the DC, admin station and both Azure Local nodes; keep Guest Service Interface enabled. Windows Time guest settings are not replaced: unjoined guests retain their configured source and domain members follow the domain hierarchy unless overridden by policy.
- Apply the same setting to existing DC/admin VMs during host step 8 and selected nodes during host step 10. Existing nodes encountered by creation script 10 also receive the integration setting without recreation.
- Correct time-source guidance; distinguish optional display time zones from synchronization and note the DC's upstream source still needs verification. Preserve student names/settings and increment release stamps to 2.0.6.

## 2.0.5
- Make time-zone changes optional in DC, admin-station and Azure Local node configuration. Unavailable Manitoba Standard Time falls back to Eastern Standard Time; if lookup or setting fails, print a warning and continue configuring the guest.
- Empty/unfilled values are skipped and already-selected zones are left alone. Other configuration errors still fail normally. Update guest guidance and add mocked regression cases for all three roles.
- Retain the requested time-zone value and other student settings; increment release metadata and refresh rollout.

## 2.0.4
- Fix Host Console step 10 falsely detecting duplicate destinations in the normal five-file node delivery with zero extra files. The copy list contains hashtables: group by each entry's Dest value explicitly, not by a named property.
- Real destination collisions remain blocked, case-insensitively, and now identify the conflicting guest path and source files. Add regression cases for normal delivery, unique extras and actual launcher collisions.
- Preserve student selections, IPs and sizing settings; increment all release stamps and regenerate rollout.

## 2.0.3
- Add section 2 **Host VM size (SKU)** selector with **Refresh Azure sizes**, plus **Available vCPUs**, defaulting to Standard_D48als_v7 and 20. Validate maximum and supported reduced counts against subscription/region SKU metadata before rollout or copying the create command.
- Parameterize the section 2 CLI command and script 00 with these selections. Script 00 retains the plan's ArcRegion and validates that region independently; the copyable command remains in South Central US.
- Azure discovery filters for nested virtualization, Premium SSD, at least 80 GiB RAM and no temporary local disk. Quota/capacity remain separate checks and the base VM price is unchanged by constrained cores.
- Preserve saved student identifiers and values on upgrade; older plans receive missing sizing fields. Update release metadata to 2.0.3.

## 2.0.2
- Clarify step 10 with the applied destination VM names, guest folder and exact node console filenames. The launcher uses the shared `ALFGuestConsole.ps1` in Node mode.
- Fail node preparation on missing/stopped VMs, guest sign-in/adapter/copy errors or failed guest hash verification; summarize success/failure by VM. Mark Prepare done only from verified-delivery receipts, not host-side generated files. Invalidate receipts for recreated VMs or changed source scripts.
- Add two editable node-name fields and **Apply node names** to Host Console step 9. The host-local selection persists across console restarts and is shared by creation, preparation, status checks and generated per-node configure scripts.
- Keep the original Planning Console plan, cluster identifier and node IP ordering unchanged. Applying names does not rename/delete existing VMs or add nodes to an existing cluster.
- Validate distinct Windows-compatible names, block unapplied edits and changes during a host step, and prevent old node-run history from completing a different selected pair.
- Update release stamps to 2.0.2 and include `ALFNodeSettings.ps1` in rollout. Preserve saved student values when upgrading.

## 2.0.1
- Add graphical **Domain Controller**, **Admin Station** and **Azure Local Node** guest consoles with educational ordered steps, prerequisite checkpoints, explicit run/confirmation actions and persistent restart-aware progress. All roles attempt WPF; Server Core compatibility remains a guest-VM trial, with a clear error if GUI components are absent.
- Rollout includes the shared guest console/step runner and three launchers. Host steps 05 and 11 deliver the correct role launcher and scripts; host console handoff text is updated. Guest delivery no longer unblocks node files or recommends an execution-policy bypass.
- Add **Azure CLI - create host VM** immediately after **Azure VM name** in Planning Console section 2: Standard_D48als_v7 in southcentralus, using the plan's subscription, host resource group, VM name and admin account. Password is prompted; no inbound RDP rule is opened. Existing script 00 remains unchanged.
- Start the 2.0.1 development release from v1.0.24; update console versions, script stamps, configuration metadata and release documentation.
- Add a four-digit **Cluster identifier** field and explicit **Apply identifier** button to the Planning Console. Apply updates all eleven numbered lab names and command previews; Save values and Roll out scripts persist/generate the plan afterward.
- Bundle default identifier **2001** (2.0.01); students choose their own four digits, including leading zeros. Save/reload and shareable export retain the identifier and naming templates; older plans retain their existing names on load.
- Reject invalid or unapplied identifiers before saving or generating/copying commands. Only numbered naming fields change; unrelated IDs, IPs, passwords and disk sizes are preserved. Existing Azure resources are not renamed.
- Relocate template and rollout paths to the writable project and regenerate bundled rollout for 2001.
- Carry forward the v1.0.24 build guide; its matching 2.0.1 update is pending.

## 1.0.24
- **Planning Console section headers** are now coloured bands with larger text: **blue** for building the lab (sections 1, 2, 3 and 8) and **purple** for building the cluster (sections 4-7), with a "Building the lab" / "Building the cluster" tag so colour isn't the only cue
- **Admin station moved to the end:** it's now section 8, and the Azure portal deployment wizard is section 7
- README, release checklist and lab build guide updated for the new section numbers
- Default numbering **1024** to match the version

## 1.0.23
- The **lab build guide** now ships with the release: `ALF-Lab-Build-Guide-v1.0.23.docx` (guide version 1.0.23, shown on the title page, in the page header and in its Appendix D history)
- README has a Lab build guide section; the release checklist checks the guide version
- Default numbering **1023** to match the version

## 1.0.22
- **Script numbering:** every script that runs on the domain controller now ends in `dc`, and every script that runs on the admin station ends in `adm`:
  `06.DC-SetNameAndIP.ps1` -> `06dc.DC-SetNameAndIP.ps1`, `07.DC-CreateForest.ps1` -> `07dc.DC-CreateForest.ps1`,
  `09.DC-PrepareADForAzureLocal.ps1` -> `09dc.DC-PrepareADForAzureLocal.ps1` (08dc and 08adm already followed this)
- Every reference updated: scripts' "Next" and "run ... first" messages, value "Used in" lists and descriptions, README
- Default numbering **1022** to match the version

## 1.0.21
- **Script numbering:** where the domain controller and the admin station have matching scripts, the suffix now says which machine it's for instead of a/b:
  `04.Host-CreateDCVM.ps1` -> `04dc.Host-CreateDCVM.ps1`, `04b.Host-CreateAdminStationVM.ps1` -> `04adm.Host-CreateAdminStationVM.ps1`,
  `08.DC-PostConfig.ps1` -> `08dc.DC-PostConfig.ps1`, `08b.Admin-Configure.ps1` -> `08adm.Admin-Configure.ps1`
- Every reference updated: scripts' "Next" messages, the Host Console steps, value "Used in" lists, README
- Default numbering **1021** to match the version

## 1.0.20
- **Time configuration is left at the defaults.** The lab no longer turns off Hyper-V time synchronization (04, 04b, 10) or sets NTP sources (08 on the DC, 12 on the nodes). Every VM takes its clock from the host; only the time zone is set
- README, LEARN notes and the domain controller IP description updated to match
- Default numbering **1020** to match the version

## 1.0.19
- Console titles: **1. ALF Lab Builder - Planning Console** (was "ALF Lab Builder") and **2. ALF Lab Builder - Host Console** (was "ALF Host Console") - window title, heading and message boxes
- Scripts, README and launchers refer to the Planning Console and Host Console by these names
- Default numbering **1019** to match the version

## 1.0.18
- New **ALF Host Console** (`ALFHostConsole.ps1` + `Launch-ALFHostConsole.cmd`): a window on the lab host that runs the host-side steps (01, 02, 03, 04, 04b, 05, 10, 11) and shows which are done
- The two image downloads are separate steps in the Host Console, with a progress bar, size, speed and time left (BITS, with a direct-download fallback)
- `01.Host-PrepareDataDisk.ps1` has a new `-DiskOnly` switch (time zone, data disk and folders only)
- Roll out now includes the Host Console and its launcher
- Default numbering **1018** to match the version

## 1.0.17
- **Lab time zone** renamed **Your time zone** and moved to group 1 (Getting started), after the Subscription ID
- Default numbering **1017** to match the version

## 1.0.16
- Every script (and the launcher and command template) now has a **version stamp** in its header: `# Version: ALF Lab Builder 1.0.16`. If one file is replaced on its own, its version is known
- **Roll out scripts** warns when a script is from a different version, or has no stamp
- Default numbering **1016** to match the version

## 1.0.15
- **Lab time zone** now defaults to the time zone of the PC running the Lab Builder (filled in when the value is empty; Save to keep it). Export for sharing clears it, so each user gets their own
- 01 now sets the **Azure host VM** to the lab time zone too (Azure VMs start in UTC)
- Default numbering **1015** to match the version

## 1.0.14
- New **Lab time zone** value (group 3, Lab network), default `Central Standard Time`. Used by 06 (DC), 08b (admin station) and now 12 (nodes, which also set their time zone). Check values confirms it is a valid Windows time zone ID
- Default numbering **1014** to match the version

## 1.0.13
- Default numbering now matches the release version: **1013** = v1.0.13 (`LABHOST1013`, `LABHOST1013-rg`, `LABCLUSTER1013-rg`, `LABcluster1013`, `LCMaccount1013`, `AzL1013Node1/2`, Key vault and witness storage names)

## 1.0.12
- Lab Builder: **Azure CLI - create host VM resource group** moved to group 2 (Azure host VM), right after "Resource group for host VM"

## 1.0.11
- Lab Builder: **Azure CLI - create host VM resource group** moved to group 1, "Getting started"

## 1.0.10
- Lab Builder: the cluster resource group, region, the Azure CLI rows (create host VM resource group, assign deployment roles) and the Azure prep commands file moved to group 4, Azure Local cluster. Group 1, "Getting started", now holds the tenant and subscription only

## 1.0.9
- Lab Builder: **Azure subscription and Arc registration** is now group 1, "Getting started"; Azure host VM is group 2 and Lab network group 3

## 1.0.8
- Lab Builder group 3: new **Azure CLI - assign deployment roles on the cluster resource group** row (after the resource group command). One line, double-click to copy; assigns only the 6 resource group roles

## 1.0.7
- Lab Builder: **Cluster resources first/last IP** renamed **Cluster resources range**; default is now 192.168.44.61 - 192.168.44.69 (9 addresses)

## 1.0.6
- Lab Builder: **Node 1 IP** and **Node 2 IP** replaced by a **Node IP range** (192.168.44.51 - 192.168.44.59) in group 2 (Lab network); node 1 gets the first address, node 2 the next
- Network checks cover every range: big enough, nothing else inside it, and no two ranges overlap
- `11.Host-PrepareNodes.ps1` works out each node's IP from the range

## 1.0.5
- Lab Builder: **Node 1 IP** and **Node 2 IP** moved from group 2 (Lab network) to group 4 (Azure Local cluster)

## 1.0.4
- Version number shown at the top of the Lab Builder window; `VERSION.txt` added; zip and folder named with the version
- Lab Builder notes when `LabValues.json` comes from a different version

## 1.0.3
- Lab Builder: **Lab network** moved to group 2; later groups renumbered (Azure subscription 3, cluster 4, Active Directory 5, Nodes 6)

## 1.0.2
- Second local admin password can be entered in the Lab Builder, saved in `LabValues.json` (plain text, with a warning) and injected into `12.Node-Configure.ps1`; left empty, script 12 asks for it
- Export for sharing empties it

## 1.0.1
- Default numbering changed to **1055** (10 = version 1.0, 55 = release): `LABHOST1055`, `LABcluster1055`, `LCMaccount1055`, `AzL1055Node1`...

## 1.0.0 - first public release

**ALF Lab Builder**
- Window for tracking and checking every lab value: names, Azure settings, network, accounts
  and Azure portal deployment wizard settings
- Rule, duplicate and network checks (lab subnet, cluster resources pool, DHCP range)
- Roll out: fills `{{Placeholders}}` into the scripts and command files
- Azure buttons: create resource groups, assign deployment roles, review Azure Policy
- One-line Azure CLI rows (double-click to copy)
- Password reminder rows; the second local admin password can optionally be stored (plain text, with a warning) and injected into script 12
- Export for sharing - removes private values and folder paths
- Saving keeps the descriptions and rules from the newest values file

**Lab scripts (00 - 15)**
- Host VM, data disk and automatic image downloads
- Hyper-V, NAT and storage switches
- Domain controller (ContosoDC1) and admin station (ContosoADM1)
- Active Directory preparation for Azure Local (OU and LCM account per cluster)
- Node VMs with vTPM, nested virtualization, MAC spoofing, VLAN trunking and 4 data disks
- Per-node configuration generated from one template and copied in over VMBus
- Arc registration with pre-flight checks
- Azure Policy review before and after registration, with optional time-limited exemptions

**Security changes for the public release**
- Removed every hard-coded or displayed password; scripts prompt, except the optional second local admin password set in the Lab Builder
- Removed tenant and subscription IDs and personal folder paths from the defaults
