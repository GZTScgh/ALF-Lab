# ALF Lab Builder v2.0.14 - release checklist

- [ ] Host VM size (SKU) is first in section 2 after load/migration/save; all other field order and values remain unchanged.

- [ ] Custom (on-premises) remains available after load and Azure-size refresh. Enter 64 CPUs/256 GB RAM without an Azure ceiling or memory warning; save/reload retains the selection and capacities. Returning to Azure restores SKU checks and the Azure command.
- [ ] On-premises guest sizing still enforces host/guest minimums, per-guest CPU limits, RAM reserve and actual host capacity; CPU sharing remains advisory. Rollout consumes custom declared capacities without querying Azure.
- [ ] Custom host creation command is Not applicable and cannot be copied; script 00 fails before Azure sign-in/resource creation. Azure prerequisites for Arc/cluster deployment are unchanged.
- [ ] Run focused HostSizing.Tests.ps1 and GuestSizing.Tests.ps1 in an approved STA PowerShell session; retain existing values and default Azure selection.


- [ ] Node IP range first/last and cluster resources range first/last appear together under 6. Nodes, not 3. Lab network. Preserve their values, placeholders, validation rules and network checks after reload/save/rollout.

- [ ] Section 2 defaults: SuperHost 96 GB/20 available vCPUs, 16-GB host RAM reserve; DC 2/2 GB, Admin 2/4 GB, each node 12/36 GB. All fields persist and minimums are enforced.
- [ ] Default summary is 78/80 GB guest budget, 18 GB host headroom, 28 shared guest vCPUs/20 host vCPUs; CPU sharing warns and does not block. RAM over-allocation, a guest exceeding host CPUs or known SKU-memory mismatch blocks command copy/rollout.
- [ ] Choose a larger matching SKU and increase allocations; both node names (including overrides) receive identical selected sizes. New creation consumes the saved values; existing VMs are not automatically resized.
- [ ] Actual undersized SuperHost fails before guest disks/VMs are created; normal nominal-vs-OS RAM accounting is tolerated. Script 00 checks the budget before Azure resource creation.
- [ ] Run tests\GuestSizing.Tests.ps1 and tests\HostSizing.Tests.ps1 in an approved STA PowerShell session; preserve existing student values when loading older plans.


- [ ] All guest roles match the Host Console: blue headings/version badge, numbered blue/green indicators, white cards, status column and right-hand actions. Only student-confirmed steps turn green; running is blue, results needing checks amber and script errors red.
- [ ] Retain each role's v2.0.7/v2.0.8 progress in v2.0.14 without losing confirmations/receipts. Reject other-role or unsupported-release state; keep explicit confirmation and restart behavior. Check layout at 1024- and 1300-pixel window widths.
- [ ] Host step 05 creates ALF DC Console.lnk on the DC local Administrator's default desktop, targeting C:\ISO\Launch-ALFDCConsole.cmd. Retry updates the shortcut without reconfiguring the DC; failures warn and the temporary host shortcut is removed.
- [ ] Run tests\GuestConsole.Tests.ps1 in an approved STA PowerShell session; no guest configuration should be launched.


- [ ] Section 2 accepts 20 / 48 max without refreshing Azure and with missing/unlisted reduced-count metadata; show warnings and retain --v-cpus-available 20 through copy and rollout.

- [ ] All four nested VMs have Hyper-V Time Synchronization disabled after creation; Guest Service Interface remains enabled. Host steps 8/10 repair the same setting on existing VMs without recreation.
- [ ] Check w32tm /query /source in unjoined guests and after domain join; confirm the domain hierarchy and the DC's valid upstream source. No guest NTP peers or Windows Time policies are overwritten.

- [ ] Host Console step 1 and each guest role: any unavailable time-zone ID falls back to Eastern Standard Time. Missing Eastern, time-zone lookup failure and Set-TimeZone failure only warn and continue. Verify valid/already-selected zones and blank values; actual disk/folder errors must still fail. Run tests\GuestTimeZone.Tests.ps1 in an approved PowerShell session without running destructive node configuration solely to test display time.

- [ ] Step 10 accepts all five normal hashtable delivery entries with zero extras and a unique extra file. A case-insensitive duplicate destination must report the exact path and both sources.

- [ ] Section 2: default D48als_v7 and 20 available vCPUs; verify whole-number/max checks, nonblocking CPU-support warnings, selection persistence and command/script parameter parity.
- [ ] Failed queries or changed subscriptions must not falsely claim verified support or block the default 20-vCPU request. Invalid counts or unknown maxima for nondefault SKUs still block copy/rollout. Script 00 uses the same warning policy in its retained ArcRegion; Azure enforces CPU support during creation.
- [ ] Confirm no promise of compute-price or quota reduction; test actual Azure quota/capacity and supported counts before student deployment.

- [ ] Step 10 displays the applied VM destinations and actual console filenames. Verify successful guest hashes and per-VM summary; missing/stopped VM, wrong credentials, adapter error or failed/missing guest copy must leave the step incomplete. Generated host scripts alone cannot mark it done.
- [ ] Recreated VMs or changed source scripts invalidate delivery receipts. After deleting a guest file, rerun step 10 to detect/restore it; status explicitly shows the last verification time.
- [ ] Host Console step 9: apply Node3/Node4 names, restart the console, and verify the same pair appears in creation, preparation and per-node configure scripts. Original plan/IP order remain unchanged.
- [ ] Reject duplicate/invalid/reserved names; block both node steps with unapplied edits and prevent changing names during a running host step.
- [ ] A previous pair's run history must not complete the newly selected pair; existing VMs must not be renamed or deleted.
- [ ] Copy `ALFNodeSettings.ps1` with all v2.0.14 host files; retain the host-local `ALFHostConsole-Nodes.json` during refresh.

Complete these before publishing. Items marked **[untested]** were changed for the release
and haven't been run end to end yet.

## Test the release build
- [ ] **[untested on guests]** Graphical DC/admin/node consoles: WPF loads on the intended guest; if absent, startup reports failure and runs no configuration. Test Azure Local GUI compatibility from SConfig option 15
- [ ] Rollout contains ALFGuestConsole.ps1, ALFGuestStepRunner.ps1 and three role launchers; host step 05 copies DC/admin launchers and step 11 copies the node launcher plus node-specific configure script
- [ ] Guest step cards explain purpose, changes, prerequisites, destructive storage actions and restarts; no step runs automatically
- [ ] Prerequisite confirmations gate execution; a returned script is not marked completed without student checking; rerun clears downstream confirmations
- [ ] Reopen after restart or console close: progress is preserved, running step is recognized, interrupted step requests result checks, and no credentials enter state/receipts
- [ ] Guest launchers/delivery do not unblock files or bypass execution policy; missing, unfilled or version-mismatched scripts are not launched
- [ ] Section 2: **Azure CLI - create host VM** is immediately after **Azure VM name**; double-click copies a PowerShell-compatible command with the plan's subscription, host RG, VM name and administrator account
- [ ] Applying a student identifier updates the VM command; missing values show **Fill values**. VM region stays **southcentralus**, size **Standard_D48als_v7**; no password is embedded and **--nsg-rule NONE** keeps inbound RDP closed
- [ ] **[untested]** Deploy the new VM command only after verifying regional SKU availability, quota and nested virtualization; add approved restricted access and shutdown configuration separately. Do not also run script 00 to create the same VM
- [ ] Cluster identifier defaults to **2001** (version 2.0.01); typing alone leaves all numbered names unchanged and shows **Not applied**
- [ ] **Apply identifier** updates all eleven naming fields and CLI/command previews; no unrelated values change
- [ ] Save/reload and Export for sharing retain identifier and naming templates; leading zeros (e.g. **0042**) are preserved
- [ ] Invalid/partial/non-ASCII identifiers and unapplied changes block save, command copy/file generation, Azure preparation and rollout; close-and-save stays open
- [ ] Regenerated rollout uses the applied identifier everywhere; no stale 2105/1024 lab names remain (1024 GB disks are unchanged)
- [ ] Older plans load without retargeting names; applying a new identifier preserves prefixes/suffixes and nested OU parents
- [ ] **[untested]** Fresh PC: unblock the files, launch `Launch-ALFLabBuilder.cmd`; the version badge at the top shows *Version 2.0.14*
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
- [ ] **[pending]** Update the source guide `ALF-Lab-Build-Guide-v1.0.24.docx` with the new identifier workflow, then publish `ALF-Lab-Build-Guide-v2.0.14.docx` with matching title page, page header and Appendix D. Saved plans retain their chosen four-digit identifier; missing identifiers default to 2014.

## Version
- [ ] Version is the same everywhere: Lab Builder (`$ALFVersion`), `LabValues.json`, `VERSION.txt`, README, CHANGELOG, zip and folder name
- [ ] Every script header has the same version stamp: `Select-String -Path .\*.ps1,.\*.cmd,.\*.txt -Pattern 'Version: ALF Lab Builder' | Where-Object Line -notmatch '2\.0\.1'` returns nothing
- [ ] **[untested]** Roll out scripts with one script from an older release: the log shows a version WARNING for it

## Decide before publishing
- [ ] **Licence** - add a `LICENSE` file (e.g. MIT) so others know how they may use it
- [ ] **Where it's published** - GitHub repository, file share, or internal site
- [ ] **Support statement** - who to contact, and that it's provided as-is
- [ ] Host VM size in script 00 (`Standard_E16s_v5`) - keep, or change to the size you tested
