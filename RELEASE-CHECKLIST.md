# ALF Lab Builder v2.1.1 - release checklist

- [ ] Planning Console group 4: **Azure Local image release** lists 2601 to 2611 (default 2608); rollout fills scripts 01/10 and the Host Console with `C:\ISO\AzureLocal-<release>.iso` and `https://aka.ms/hcireleaseimage/<release>`. An ISO already in `C:\ISO` for the same release is reused; an unpublished release (2611) fails the download visibly (tiny-file check) instead of creating nodes from a bad ISO.
- [ ] **Target solution version (optional)**: blank leaves script 14's pick list; a four-part value (for example `12.2610.1004.50`) reaches script 14 after rollout; a malformed value fails **Check values**. The Node Console override still wins on that node.
- [ ] Loading a v2.0.23 plan adds both rows after the cluster name without changing other values or the identifier.
- [ ] **[untested on guests]** Host Console step 10 delivers and hash-verifies eight files per node, including `AzureLocal-DeploymentTroubleshooter.ps1`. The Node Console **Deployment troubleshooter** button opens it in its own window that fits 1024 x 768; a missing file logs "Run step 10 again".
- [ ] **[untested on guests]** ALF Admin Console on adm1: **Windows Admin Center and Azure CLI** panel sits below the setup card at 1024 and 1300 widths. **WAC 2611: what's new** and **Download Windows Admin Center** open in Edge; **Install Azure CLI (winget)** opens a PowerShell window and `az version` works in a new window afterwards. Without winget the MSI link is logged. The Admin status card count stays 1. 08adm ends with the panel hint.

- [ ] Node Console: the override box is labeled **Target version (next Arc run)**; the gray line under it shows the `12.YYMM.Build.Revision` format with published examples and names the Microsoft Learn page *Azure Local release information*. Hover the box for the part-by-part tooltip.
- [ ] At a 1024 x 768 window the Arc card, both detail panels and the help line are visible without scrolling the task area; at 1300 x 850 nothing is clipped.
- [ ] Enter a well-formed version newer than the examples (for example from the Learn page), Apply, restart the console: it is retained and passed to script 14. A malformed value shows the `Major.YYMM.Build.Revision` message and is not saved.
- [ ] Same-role v2.0.23 node state (including a saved target override) loads without reset.

- [ ] Planning Console: **Management - Domain** and **Domain NetBIOS name** fill 07dc/08dc/08adm/09dc/12 on rollout; no `contosolab` literals remain when a different domain is planned. Older plans gain a `DomainNetbios` row derived from the domain's first label.
- [ ] **Check values** flags an OU path that does not end with the planned domain's DN, and a NetBIOS name that is not 1-15 valid characters.
- [ ] **Roll out scripts** is blocked when any secret value (passwords) contains a single quote; other values are unchanged.
- [ ] Script 15 policy review accepts only listed numeric choices, ignores duplicates and never indexes with text input.
- [ ] Host Console step 9: apply node names twice in one session; the second Apply succeeds (typed-null `File.Replace` backup argument).
- [ ] Host script 05 DC/Admin Public Desktop shortcuts carry no Internet zone mark (no `Zone.Identifier` stream).
- [ ] Run all nine `tests\*.Tests.ps1` in an approved STA PowerShell session from a checkout without a `Rollout` folder; all pass.

- [ ] Host VM size (SKU) is first in section 2 after load/migration/save; all other field order and values remain unchanged.

- [ ] Custom (on-premises) remains available after load and Azure-size refresh. Enter 64 CPUs/256 GB RAM without an Azure ceiling or memory warning; save/reload retains the selection and capacities. Returning to Azure restores SKU checks and the Azure command.
- [ ] On-premises guest sizing still enforces host/guest minimums, per-guest CPU limits, RAM reserve and actual host capacity; CPU sharing remains advisory. Rollout consumes custom declared capacities without querying Azure.
- [ ] Custom host creation command is Not applicable and cannot be copied; script 00 fails before Azure sign-in/resource creation. Azure prerequisites for Arc/cluster deployment are unchanged.
- [ ] Run focused HostSizing.Tests.ps1 and GuestSizing.Tests.ps1 in an approved STA PowerShell session; retain existing values and default Azure selection.


- [ ] Node IP range first/last and cluster resources range first/last appear together under 6. Nodes, not 3. Lab network. Preserve their values, placeholders, validation rules and network checks after reload/save/rollout.

- [ ] Section 2 defaults: SuperHost 96 GB/20 available vCPUs, 16-GB host RAM reserve; DC 2/2 GB, Admin 2/4 GB, each node 12/36 GB. All fields persist and minimums are enforced.
- [ ] SuperHost available vCPUs 12 to 19 (try 16) passes with an amber *below the recommended 20* warning in the Planning Console, script 00 and host scripts 04dc/04adm/10; 11 is INVALID LAB SIZING; 20 shows no below-recommended warning. An older plan's "(min 20)" label becomes "(min 12, 20 recommended)" and keeps its value.
- [ ] **[untested on guests]** DC Console step 2 (07dc) creates the forest and restarts without asking for a DSRM password; its script window shows "Set a random DSRM password". After the restart, sign-in as `<NetBIOS>\Administrator` works and step 2 shows Done.
- [ ] Load a `LabValues.json` whose Template folder is a 2.1.0 folder (Rollout folder = its `Rollout`): the log notes the switch, both folder boxes show this Planning Console's folder and `Rollout`, and the rollout is 2.1.1 (16 vCPUs warns, not blocks). A 2.1.0 file placed in the template folder blocks rollout with its name and version; nothing is written.
- [ ] Default summary is 78/80 GB guest budget, 18 GB host headroom, 28 shared guest vCPUs/20 host vCPUs; CPU sharing warns and does not block. RAM over-allocation, a guest exceeding host CPUs or known SKU-memory mismatch blocks command copy/rollout.
- [ ] Choose a larger matching SKU and increase allocations; every applied node name (including overrides) receives identical selected sizes. New creation consumes the saved values; existing VMs are not automatically resized.
- [ ] Actual undersized SuperHost fails before guest disks/VMs are created; normal nominal-vs-OS RAM accounting is tolerated. Script 00 checks the budget before Azure resource creation.
- [ ] Run tests\GuestSizing.Tests.ps1 and tests\HostSizing.Tests.ps1 in an approved STA PowerShell session; preserve existing student values when loading older plans.


- [ ] Guest consoles have only runnable cards (DC 4, Admin 1, Node 2), concise descriptions, detected status and Run/Open script; keep the Host Console green/blue theme. No manual readiness/confirmation cards remain.
- [ ] Same-role v2.0.7 through v2.0.23 state retains process/receipt metadata, not old confirmation proof. Reject unsupported role/schema; verify PID plus UTC start time and visible launch/probe/receipt failures. Check compact layout at 1024- and 1300-pixel window widths.
- [ ] Windows PowerShell: create DC state, then save Forest progress into that existing file. Typed-null File.Replace must succeed and preserve Network progress; failed temporary writes must preserve the original. Accept v2.0.19 state and node overrides without a reset. Run console/status regressions normally in an approved session.
- [ ] Actual settings, not exit code alone, determine Done: DC identity/domain/DNS/optional DHCP; Admin identity/domain/tools; generated node identity/network/admin/storage; successful Arc bootstrap plus connected agent at the planned target. DC networking stays done after self-DNS configuration.
- [ ] Node-only read-only Arc values and NTP/domain time-status panels sit below the Arc card at 1024/1300 widths. Copyable tenant/subscription/RG/region/target version match the delivered script; machine is the actual node. Edited/pinned inputs refresh; a blank target prompts selection only during script execution. Time source/last sync/stratum come from `w32tm /query /status`, never a resync. Missing/unfilled/dynamic settings and failed/empty time queries are explicit; one failed panel does not hide the other.
- [ ] Node **Target version (next Arc run) / Apply** accepts four numeric version parts, saves only in that node's state and survives restart. Blank restores the delivered script default. Dirty edits block Arc Run; running steps disable editing. Verify exact named-parameter forwarding only to script 14, no automatic update or installed-version claim, malformed state failure and atomic save preservation. Run focused status/console tests normally.
- [ ] DC AD tools card checks module installation only; optional OU/account exercise and cross-VM/Azure/deployment prerequisites are not claimed verified.
- [ ] Node setup retains a destructive confirmation. Existing cluster membership disables rerun; deployed lab storage need not remain RAW. An unknown/failed cluster lookup must not allow disk cleanup.
- [ ] Four prepared RAW disks and no non-primordial storage pool report ready for cluster pooling. A primordial pool alone is normal; actual pools, wrong/non-RAW/offline/read-only disks and genuine provider failures remain visible.
- [ ] All five source and four rollout CMD launchers start with byte 0x40 (`@echo off`), contain no BOM, and stay ASCII after fresh rollout. PowerShell/text Unicode is preserved; a non-ASCII CMD template fails visibly without a lossy write.
- [ ] Run tests\LauncherEncoding.Tests.ps1 and tests\GuestStatus.Tests.ps1 normally in an approved PowerShell session. Preserve v2.0.16 process/receipt state; do not run actual guest disk cleanup during validation.
- [ ] **[untested on guests]** Opening DC/Admin consoles leaves the current local/domain user's resolution unchanged. Only clicking 1600 x 900 display requests a change. Already-correct modes are unchanged; unsupported/client-controlled sessions log/show a warning only after a manual request. Nodes remain unchanged; no logon tasks or validation-workstation display changes.
- [ ] Host step 05 creates ALF DC Console.lnk and ALF Admin Console.lnk on each intended VM's C:\Users\Public\Desktop, targeting matching C:\ISO launchers. Sign in with local and domain accounts to verify availability and existing elevation prompts. Retry updates public links without reconfiguring guests or deleting personal shortcuts; failures warn and temporary host shortcuts are removed.
- [ ] Run tests\GuestConsole.Tests.ps1, tests\GuestStatus.Tests.ps1 and tests\GuestDisplay.Tests.ps1 normally in an approved STA PowerShell session; all guest queries/display changes are mocked.


- [ ] Section 2 accepts 20 / 48 max without refreshing Azure and with missing/unlisted reduced-count metadata; show warnings and retain --v-cpus-available 20 through copy and rollout.

- [ ] All nested VMs (DC, admin station and every applied node) have Hyper-V Time Synchronization disabled after creation; Guest Service Interface remains enabled. Host steps 8/10 repair the same setting on existing VMs without recreation.
- [ ] Check w32tm /query /source in unjoined guests and after domain join; confirm the domain hierarchy and the DC's valid upstream source. No guest NTP peers or Windows Time policies are overwritten.

- [ ] Host Console step 1 and each guest role: any unavailable time-zone ID falls back to Eastern Standard Time. Missing Eastern, time-zone lookup failure and Set-TimeZone failure only warn and continue. Verify valid/already-selected zones and blank values; actual disk/folder errors must still fail. Run tests\GuestTimeZone.Tests.ps1 in an approved PowerShell session without running destructive node configuration solely to test display time.

- [ ] Step 10 accepts all eight normal hashtable delivery entries with zero extras and a unique extra file. Both status/display helpers require matching guest hashes; stale helper receipts stay incomplete. A case-insensitive duplicate destination reports the exact path and both sources.

- [ ] Section 2: default D48als_v7 and 20 available vCPUs; verify whole-number/max checks, nonblocking CPU-support warnings, selection persistence and command/script parameter parity.
- [ ] Failed queries or changed subscriptions must not falsely claim verified support or block the default 20-vCPU request. Invalid counts or unknown maxima for nondefault SKUs still block copy/rollout. Script 00 uses the same warning policy in its retained ArcRegion; Azure enforces CPU support during creation.
- [ ] Confirm no promise of compute-price or quota reduction; test actual Azure quota/capacity and supported counts before student deployment.

- [ ] Step 10 displays the applied VM destinations and actual console filenames. Verify successful guest hashes and per-VM summary; missing/stopped VM, wrong credentials, adapter error or failed/missing guest copy must leave the step incomplete. Generated host scripts alone cannot mark it done.
- [ ] Recreated VMs or changed source scripts invalidate delivery receipts. After deleting a guest file, rerun step 10 to detect/restore it; status explicitly shows the last verification time.
- [ ] Host Console step 9: apply Node3/Node4 names, restart the console, and verify the same names appear in creation, preparation and per-node configure scripts. Original plan/IP order remain unchanged.
- [ ] **[untested]** Planning Console: **Number of Azure Local nodes** offers 2-16 (default 2) just above the node vCPU/RAM rows. Set it to 3 on the default 96 GB host: the summary shows **INVALID LAB SIZING** naming 3 nodes, the reserve row shows **Invalid sizing** and copy/rollout is blocked; with **Custom (on-premises)** and 130 GB SuperHost RAM it passes and the summary reads *3 nodes: 114 / 114 GB guest RAM...*. Load a 2.1.0 plan: the row is added (value 2) before the node vCPUs and no other value changes. With the node IP range narrowed below the count, **Check values** flags it.
- [ ] **[untested on hosts]** With Number of Azure Local nodes = 3 and no saved step 9 selection, Host Console step 9 shows 3 name boxes (the third continues the numbering) and scripts 10/11 target 3 nodes; after applying a step 9 selection, that selection wins.
- [ ] **[untested on hosts]** Host Console step 9: **Number of nodes** offers 2-16 (default 2, or the saved count after restart). Raising it adds pre-filled, distinct name boxes; Apply with 3 nodes on a host large enough, then verify script 10 creates 3 VMs, script 11 assigns the first three node IPs in order and step 10 delivers to all three. On the default 96 GB host, script 10 must stop before creating any VM. With the default `.51 - .59` range, Apply must refuse 10 or more nodes.
- [ ] Reject duplicate/invalid/reserved names; block both node steps with unapplied edits and prevent changing names or the node count during a running host step.
- [ ] A previous selection's run history must not complete the newly selected nodes; existing VMs must not be renamed or deleted.
- [ ] Copy `ALFNodeSettings.ps1` with all v2.1.1 host files; retain the host-local `ALFHostConsole-Nodes.json` during refresh.

Complete these before publishing. Items marked **[untested]** were changed for the release
and haven't been run end to end yet.

## Test the release build
- [ ] **[untested on guests]** Graphical DC/admin/node consoles: WPF loads on the intended guest; if absent, startup reports failure and runs no configuration. Test Azure Local GUI compatibility from SConfig option 15
- [ ] Rollout contains guest console/runner/status/display helpers and three role launchers; script 05 delivers DC/admin dependencies and script 11 delivers the node dependencies plus its authoritative generated configure script.
- [ ] Guest setup uses short descriptions and a handoff note; no step runs automatically. Preserve script credential/sign-in/restart prompts and the dedicated destructive warning.
- [ ] Incomplete detected prerequisites warn with Run anyway. Successful receipts or old confirmations alone never mark Done; reopening after restart probes actual configuration.
- [ ] Running/interrupted/restart/error status remains visible; state/receipts contain execution metadata only.
- [ ] Guest launchers/delivery do not unblock files or bypass execution policy; missing, unfilled or version-mismatched scripts are not launched
- [ ] Section 2: **Azure CLI - create host VM** is immediately after **Azure VM name**; double-click copies a PowerShell-compatible command with the plan's subscription, host RG, VM name and administrator account
- [ ] Applying a student identifier updates the VM command; missing values show **Fill values**. VM region stays **southcentralus**, size **Standard_D48als_v7**; no password is embedded and **--nsg-rule NONE** keeps inbound RDP closed
- [ ] **[untested]** Deploy the new VM command only after verifying regional SKU availability, quota and nested virtualization; add approved restricted access and shutdown configuration separately. Do not also run script 00 to create the same VM
- [ ] Cluster identifier defaults to **2101** (version 2.1.1); typing alone leaves all numbered names unchanged and shows **Not applied**
- [ ] **Apply identifier** updates all eleven naming fields and CLI/command previews; no unrelated values change
- [ ] Save/reload and Export for sharing retain identifier and naming templates; leading zeros (e.g. **0042**) are preserved
- [ ] Invalid/partial/non-ASCII identifiers and unapplied changes block save, command copy/file generation, Azure preparation and rollout; close-and-save stays open
- [ ] Regenerated rollout uses the applied identifier everywhere; no stale 2105/1024 lab names remain (1024 GB disks are unchanged)
- [ ] Older plans load without retargeting names; applying a new identifier preserves prefixes/suffixes and nested OU parents
- [ ] **[untested]** Fresh PC: unblock the files, launch `Launch-ALFLabBuilder.cmd`; the version badge at the top shows *Version 2.1.1*
- [ ] **[untested]** Window titles and headings read `1. ALF Lab Builder - Planning Console` and `2. ALF Lab Builder - Host Console`
- [ ] Tenant ID and Subscription ID show **Missing** until filled in
- [ ] **Check values** - everything OK once the IDs are entered
- [ ] **[untested]** **Export for sharing** - `LabValues.shareable.json` has empty tenant/subscription IDs and folder paths
- [ ] **Roll out scripts** - no `{{...}}` left in the rollout folder: `Select-String -Path .\Rollout\* -Pattern '\{\{'`
- [ ] Azure buttons 1-3 run in a new window and finish without errors
- [ ] Full build 00 -> 15 on a clean host VM, then deploy from the portal
- [ ] **[untested]** Lab Builder: second local admin password - warning box on first edit, rule check, "Will ask" when empty, log warning on save
- [ ] **[untested]** Script 12 with the password set in the Lab Builder: uses it without asking, on every node
- [ ] **[untested]** Script 12 with it left empty: prompts twice, rejects a weak one, never shows it
- [ ] **[untested]** Export for sharing empties the second local admin password
- [ ] **[untested]** Script 11: shows the local admin reminder (no password)
- [ ] **[untested]** Script 09dc: shows and saves the OU and account name only - no password
- [ ] Confirm the Azure portal wizard labels in Planning Console section 7 match the current portal
- [ ] **[untested]** Planning Console section headers: larger white text on coloured bands - blue for 1, 2, 3 and 8 (Building the lab), purple for 4-7 (Building the cluster); Admin station is section 8, last
- [ ] **[untested]** Renamed scripts (04dc, 04adm, 08dc, 08adm): Host Console steps 6-7 find them; 05 copies 06dc, 07dc, 08dc, 09dc to the DC and 08adm to the admin station
- [ ] **[untested]** Time left at defaults: on the host `Get-VM | Get-VMIntegrationService -Name "Time Synchronization"` shows Enabled for every lab VM; `w32tm /query /source` on a node isn't the DC; node clocks match the host
- [ ] **[untested]** Roll out includes `ALFHostConsole.ps1` and `Launch-ALFHostConsole.cmd`, with the VM names filled in
- [ ] **[untested]** Host Console: starts elevated (UAC prompt), shows version, host summary and all 10 steps with the right status
- [ ] **[untested]** Host Console: each Run opens its script in a new window; the step shows Done / Last run failed when the window closes
- [ ] **[untested]** Host Console: both downloads show a moving progress bar, speed and time left; Cancel removes the partial file
- [ ] **[untested]** Host Console: close it during a download, open it again - the BITS download is picked up
- [ ] **[untested]** Host Console: after Install Hyper-V and the restart, the status reads Done
- [ ] **[untested]** `01.Host-PrepareDataDisk.ps1 -DiskOnly` stops after the folders; without it, still downloads both images

## Clean the package
- [ ] No tenant IDs, subscription IDs, user names, e-mail addresses or personal paths:
      `Select-String -Path .\* -Pattern '<your tenant id>','<your subscription id>','<your user name>'`
- [ ] No `Rollout` folder, `LabValues.shareable.json`, logs or CSV reports in the package
- [ ] `LabValues.json` Settings folders are empty and the second local admin password is empty
- [ ] **[pending]** Update the source guide `ALF-Lab-Build-Guide-v1.0.24.docx` with the new identifier workflow, then publish `ALF-Lab-Build-Guide-v2.1.1.docx` with matching title page, page header and Appendix D. Saved plans retain their chosen four-digit identifier; missing identifiers default to 2101.

## Version
- [ ] Version is the same everywhere: Lab Builder (`$ALFVersion`), `LabValues.json`, `VERSION.txt`, README, CHANGELOG, zip and folder name
- [ ] Every script header has the same version stamp: `Select-String -Path .\*.ps1,.\*.cmd,.\*.txt -Pattern 'Version: ALF Lab Builder' | Where-Object Line -notmatch '2\.1\.0'` returns nothing
- [ ] **[untested]** Roll out scripts with one script from an older release: the log shows a version WARNING for it

## Decide before publishing
- [ ] **Licence** - add a `LICENSE` file (e.g. MIT) so others know how they may use it
- [ ] **Where it's published** - GitHub repository, file share, or internal site
- [ ] **Support statement** - who to contact, and that it's provided as-is
- [ ] Default Host VM size (`Standard_D48als_v7`, Planning Console section 2, used by the CLI command and script 00) - keep, or change to the size you tested
