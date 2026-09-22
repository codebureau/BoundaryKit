# Local GPO lockdown

Implements GitHub issue [#22](../../../../issues/22) "Local GPO lockdown" and its
sub-issues #23-#28, step 5 of the MVP1 critical path
([docs/adr/0001](../../docs/adr/0001-mvp1-scope-and-critical-path.md)). Locks down
`gpedit.msc`-level settings so the child cannot flip a restriction back or re-enable
something AppLocker/Smart App Control don't cover directly.

**Threat model:** intentional bypass by the child (see ADR 0001), not external
malware. Every setting below is chosen and scoped with that in mind.

## How this works, and why

Three mechanisms are used, matched to what each kind of setting actually needs:

1. **Registry.pol** (Administrative Template settings - most of the catalog). Written
   directly as bytes, in plain PowerShell (`lib/PolFile.psm1`), instead of shelling out
   to Microsoft's LGPO.exe. That keeps the whole pipeline - from the settings catalog
   to the bytes on disk - as plain, reviewable source in this repo, with no external
   binary to download, trust, or vendor into git, and lets it be round-trip tested
   against a scratch file with nothing more than PowerShell itself (see `tests/`).

2. **Multiple Local Group Policy (MLGPO) - Non-Administrators container.** Windows
   supports more than one local GPO: alongside the usual "Local Computer Policy"
   (Machine + a default User side that applies to *everyone*), it also supports a
   **Non-Administrators-only** local GPO, keyed by the well-known SID of the built-in
   Users group (`S-1-5-32-545`). Settings written there apply to every local account
   that is *not* a member of Administrators - i.e. exactly the child's account - and
   never touch the parent admin account at all. This is why most settings below are
   scoped `NonAdminUser`: it's a structural exemption, not a "please don't touch the
   admin" convention that could be gotten wrong.

   A few settings have no per-user equivalent in the Administrative Templates
   (PowerShell execution policy, Store removal, SmartScreen, removable storage was
   deliberately kept user-scoped - see GPO-27a's note) and are scoped `Machine`
   instead - meaning they also apply to the parent admin. Each one says so explicitly
   and explains why that's an acceptable trade-off.

3. **User Rights Assignment**, for "change the system time/time zone" (#28), via
   `secedit.exe` against a minimal, targeted `.inf` - the native, built-in Windows
   mechanism for this category; there's no Registry.pol equivalent. Privilege
   assignment is inherently machine-wide, but the parent keeps every privilege here
   through Administrators-group membership, which is never touched - only the
   Users-group (545) entry is removed from specific privileges.

### What this pass could verify, and what it couldn't

Executed and passing in this repo, against scratch files/directories only - **never**
against this machine's real registry, `System32`, or Group Policy state:

- `tests/Test-PolFile.ps1` - the Registry.pol binary format reader/writer, round-tripped
  byte-for-byte, including the full real settings catalog.
- `tests/Test-PrivilegeParsing.ps1` - the `[Privilege Rights]` .inf parsing/diff logic
  used to decide what to remove from `SeTimeZonePrivilege`/`SeSystemtimePrivilege`.
- `tests/Test-ApplyAndUndo.ps1` - end-to-end: `Apply-GpoLockdown.ps1` and
  `Undo-GpoLockdown.ps1` run for real, against a fake `-TargetRoot` under `%TEMP%`.
  Covers the bootstrap precondition check, backup, idempotent re-apply, chained
  snapshot rollback, and the best-effort fallback rollback (including that it leaves
  an unrelated hand-added registry value alone).

**Not, and cannot be, verified in this pass** - genuinely needs the real target PC:

- Whether Windows' actual Group Policy engine recognises and applies a hand-placed
  `Registry.pol` inside the Non-Administrators container the same way it does one
  written through the MMC console. The mechanism is documented and the file format is
  correct (see above), but this specific combination was not exercised against a real
  Group Policy Client service anywhere in this pass.
- The `secedit.exe`/`gpupdate.exe` calls themselves - never invoked in this sandbox
  (CLAUDE.md: never apply policy on the dev box). `Set-PrivilegeRestrictions`'s
  *text-processing* logic is tested (above); the two `secedit.exe` invocations inside
  it are code-reviewed only.
- Whether each individual setting actually produces the described effect on a real
  Windows 11 Pro child session (the "Verify" step per setting below).
- A couple of settings are flagged **Medium** confidence in the table below where a
  registry path/scope was documented but not independently confirmed against a real
  Group Policy engine - read those notes before relying on them.

## One-time setup (do this once, before the first `Apply-GpoLockdown.ps1` run)

The Non-Administrators local GPO container doesn't exist until it's created - Windows
only creates it through its own UI, and `Apply-GpoLockdown.ps1` deliberately refuses to
fabricate it from scratch (so its structure is guaranteed to be one Windows itself
recognises, not a guess). On the target PC, as the parent admin:

1. Win+R -> `mmc` -> Enter.
2. File > Add/Remove Snap-in... > select **Group Policy Object Editor** > Add.
3. In the wizard, click **Browse...**, go to the **Users** tab, select
   **Non-Administrators**, click **OK**, then **Finish**, then **OK**.
4. You'll see "Local Computer\Non-Administrators Policy" in the console. Right-click
   it and choose **Save**, or just close the console and save when prompted - you
   don't need to configure anything through this UI; the point is to have Windows
   create the container (`%WinDir%\System32\GroupPolicyUsers\S-1-5-32-545\`) so the
   script has somewhere real to write into.
5. Confirm it exists: `Test-Path "$env:WinDir\System32\GroupPolicyUsers\S-1-5-32-545\GPT.INI"` should be `True`.

This only needs doing once, ever, per machine.

## Applying

From an elevated PowerShell, on the target PC (never on a dev machine - see CLAUDE.md):

```powershell
cd hardening\gpo

# Preview first - shows every file that would be written/changed, changes nothing:
.\Apply-GpoLockdown.ps1 -WhatIf

# Apply the Registry.pol settings and a policy refresh, without the User Rights
# Assignment (secedit) step, so you can review Registry.pol-driven behaviour first:
.\Apply-GpoLockdown.ps1 -SkipPrivileges

# Apply everything, including the time/time-zone privilege restriction:
.\Apply-GpoLockdown.ps1
```

Each run backs up whatever was there before it into `hardening\gpo\backups\<timestamp>\`
(gitignored - point `-BackupRoot` at external/removable storage if you want that kept
outside the repo working tree) and writes a `manifest.json` there that
`Undo-GpoLockdown.ps1` uses to restore exactly that prior state.

## Rolling back

```powershell
# Preview:
.\Undo-GpoLockdown.ps1 -WhatIf

# Restore from the most recent backup (snapshot restore - exact, preferred):
.\Undo-GpoLockdown.ps1

# Restore from a specific backup:
.\Undo-GpoLockdown.ps1 -BackupDir 'hardening\gpo\backups\20260101-120000'

# No backup available (shouldn't happen if Apply- ran first, but): best-effort -
# removes just this catalog's own registry values, leaves anything else alone,
# and does NOT touch User Rights Assignment (see the warning it prints):
.\Undo-GpoLockdown.ps1 -Force
```

To fully undo several `Apply-GpoLockdown.ps1` runs, call `Undo-GpoLockdown.ps1`
repeatedly (each call unwinds the single most recent change, same as an undo stack) -
or pass `-BackupDir` pointing at the *earliest* backup you want to return to.

Rollback for the User Rights Assignment step restores the entire pre-apply
`secedit /export /areas USER_RIGHTS` snapshot (not just the two privileges this
catalog touches), so it can't leave behind an unrelated half-applied change.

## Settings catalog

Source of truth: `lib/GpoSettings.psd1` (Registry.pol settings) and
`lib/PrivilegeSettings.psd1` (User Rights Assignment). This table is generated from
that data with `tests/Export-SettingsTable.ps1` - regenerate it if the catalog
changes, rather than hand-editing both.

### Sub-issue #23 - Disable CMD and PowerShell

**GPO-23a - Disable Command Prompt** (scope: NonAdminUser)

*Why:* Cmd.exe is a general-purpose escape hatch: it can run arbitrary commands, batch scripts, and reach most of what AppLocker is meant to block. "Prevent access to the command prompt" set to 2 also blocks .bat/.cmd processing via cmd.exe, not just the interactive shell.

*Registry values:*
- `HKCU\Software\Policies\Microsoft\Windows\System` -> `DisableCMD` (DWord) = `2`

*Verify:* As the child account, open cmd.exe (Start menu or Win+R). Expect: "The command prompt has been disabled by your administrator."

*Confidence:* High - documented ADMX (System.admx, policy "DisableCMD").

**GPO-23b - Restrict PowerShell script execution** (scope: Machine)

*Why:* Sets the machine-wide PowerShell execution policy to Restricted (no .ps1 scripts run at all, from any account). Documented as a known partial control: there is no Administrative Template "prevent access to PowerShell" equivalent to DisableCMD - this setting stops script execution but not the interactive powershell.exe host itself. Blocking the executable from launching at all is AppLocker's job (MVP1 critical path step 6, tracked separately) - that gap is intentional, not an oversight.

*Registry values:*
- `HKLM\Software\Policies\Microsoft\Windows\PowerShell` -> `EnableScripts` (DWord) = `0`

*Verify:* As any account, run `Get-ExecutionPolicy -List`; the MachinePolicy scope should read Restricted. Confirm a .ps1 file refuses to run.

*Confidence:* Medium - documented ADMX ("Turn on Script Execution", PowerShellExecutionPolicy.admx), but it is Computer-Configuration-only (no per-user equivalent exists), so it also restricts the parent admin's script execution machine-wide. Reversible; flagged here as a trade-off.

### Sub-issue #24 - Disable Registry Editor and Task Manager

**GPO-24a - Disable Registry Editor** (scope: NonAdminUser)

*Why:* Regedit.exe (and the reg.exe CLI, and scripted registry edits via .reg double-click) is how several of these same lockdown settings could otherwise be flipped back. Value 1 (rather than the silent value 2) shows a message when blocked, keeping the block visible rather than mysteriously silent - fits the household's "joint engineering, not punishment" framing.

*Registry values:*
- `HKCU\Software\Policies\Microsoft\Windows\System` -> `DisableRegistryTools` (DWord) = `1`

*Verify:* As the child account, run regedit.exe. Expect: "Registry editing has been disabled by your administrator."

*Confidence:* High - documented ADMX (System.admx, policy "DisableRegistryTools").

**GPO-24b - Disable Task Manager** (scope: NonAdminUser)

*Why:* Task Manager can end the monitoring tool's process (MVP2) and is a normal place to poke around for ways to interfere with restrictions. Note this value lives under a different, legacy key path than most of the other System.admx settings above - a known Windows quirk, not a typo.

*Registry values:*
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System` -> `DisableTaskMgr` (DWord) = `1`

*Verify:* As the child account, press Ctrl+Shift+Esc or Ctrl+Alt+Del -> Task Manager. Expect: "Task Manager has been disabled by your administrator."

*Confidence:* High - long-documented policy, widely referenced.

### Sub-issue #25 - Lock Control Panel and Settings pages (selective)

**GPO-25a - Hide User Accounts and Date/Time Control Panel applets** (scope: NonAdminUser)

*Why:* Legacy Control Panel still offers a path to some of the same settings as Settings app pages. Hidden rather than the blanket "Prohibit access to Control Panel" - keeps the rest of Control Panel (e.g. Ease of Access, Sound) usable, matching the "selectively" scope of this sub-issue.

*Registry values:*
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer` -> `DisallowCpl` (DWord) = `1`
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowCpl` -> `1` (String) = `Microsoft.UserAccounts`
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowCpl` -> `2` (String) = `Microsoft.DateAndTime`

*Verify:* As the child account, open Control Panel. "User Accounts" and "Date and Time" should not be listed.

*Confidence:* High - documented ADMX (ControlPanel.admx, policy "DisallowCpl").

**GPO-25b - Hide the Settings pages that add accounts or change the clock** (scope: NonAdminUser)

*Why:* Modern Settings app equivalents of the Control Panel applets above: "Family & other users" and "Email & accounts" both have "Add account" affordances; "Date & time" is the immersive-UI clock page. Deliberately narrow - only the pages with an actual add-account or change-clock affordance are hidden, not the whole Settings app or unrelated pages like sign-in options, so the child can still manage e.g. their own PIN.

*Registry values:*
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer` -> `SettingsPageVisibility` (String) = `hide:dateandtime;otherusers;emailandaccounts`

*Verify:* As the child account, open Settings > Accounts; "Family & other users" and "Email & accounts" should be missing, as should Settings > Time & language > Date & time. Typing `start ms-settings:dateandtime` should bounce to the Settings home page.

*Confidence:* High - documented policy (Explorer.admx, "Settings Page Visibility"); page ids taken from the published ms-settings URI list.

### Sub-issue #26 - Disable Microsoft Store and block installing/running unknown apps

**GPO-26a - Turn off the Microsoft Store** (scope: Machine)

*Why:* README's account structure explicitly says "No Microsoft Store access". Store-only ADMX policy, Computer-Configuration-only, so it also removes Store access for the admin account on this machine - acceptable since this is a dedicated child PC and the setting is trivially reversible.

*Registry values:*
- `HKLM\Software\Policies\Microsoft\WindowsStore` -> `RemoveWindowsStore` (DWord) = `1`

*Verify:* As any account, try to open the Store app; it should refuse to launch or show a policy-restricted message.

*Confidence:* High - documented ADMX (WindowsStore.admx, "RemoveWindowsStore"). Some references report this is not fully enforced against a signed-in Microsoft account on Pro editions in every Windows build - treat as one layer, not the only one (Smart App Control, step 4, and the account itself being local-only, are the others).

**GPO-26b - Block unrecognised/unsigned apps via SmartScreen** (scope: Machine)

*Why:* Belt-and-suspenders behind Smart App Control (step 4, already Strict): SmartScreen's app/file reputation check additionally blocks (not just warns on) unrecognised apps and files, and is a GPO-level setting the child cannot toggle off from Windows Security, unlike the interactive SmartScreen setting.

*Registry values:*
- `HKLM\Software\Policies\Microsoft\Windows\System` -> `EnableSmartScreen` (DWord) = `1`
- `HKLM\Software\Policies\Microsoft\Windows\System` -> `ShellSmartScreenLevel` (String) = `Block`

*Verify:* As the child account, download and try to run an unsigned/unrecognised .exe. Expect it to be blocked outright, not just shown a "Run anyway" prompt.

*Confidence:* Medium - documented ADMX (Explorer.admx, "Configure Windows Defender SmartScreen", registry path per admx.help); applied at Machine scope for reliability rather than the User-Configuration duplicate of this policy, whose exact precedence behaviour on this Windows build was not independently confirmed in this pass - verify on the real machine.

**GPO-26c - Hide "Apps & features" / "Programs and Features"** (scope: NonAdminUser)

*Why:* Reduces self-service install/uninstall surface for the child account. Defense-in-depth alongside AppLocker (step 6), which is the authoritative execution blocker for unapproved software - this only removes the convenient UI, it is not itself a security boundary.

*Registry values:*
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowCpl` -> `3` (String) = `Microsoft.ProgramsAndFeatures`

*Verify:* As the child account, Settings > Apps > Installed apps and the Control Panel "Programs and Features" applet should both be hidden/inaccessible.

*Confidence:* High - documented policy (same DisallowCpl mechanism as GPO-25a, applied to a different applet).

### Sub-issue #27 - Disable USB storage

**GPO-27a - Deny all removable storage access** (scope: NonAdminUser)

*Why:* Closes the most obvious bypass for the download-control goal: copying a blocked file type in via USB instead of downloading it, or relocating files to dodge the monitor. Deliberately applied at User (Non-Administrators) scope only, not also at Computer scope, both to keep the parent admin's USB drives working and to avoid the exact Computer-vs-User policy conflict Microsoft's own guidance warns about when the same setting is set at both levels at once.

*Registry values:*
- `HKCU\Software\Policies\Microsoft\Windows\RemovableStorageDevices` -> `Deny_All` (DWord) = `1`

*Verify:* As the child account, insert a USB flash drive; it should not mount / should be denied access. As the parent admin, the same drive should work normally.

*Confidence:* Medium-High - documented ADMX (RemovableStorageAdmin.admx, "All Removable Storage classes: Deny all access" / value "Deny_All"), confirmed to exist at both HKLM and HKCU by multiple independent references; the User-Configuration variant's exact behaviour was not exercised against a real Group Policy engine in this pass.

### Sub-issue #28 - Disable changing time/date and adding/removing accounts

**GPO-28a - Block launching restricted executables from Explorer (defense-in-depth)** (scope: NonAdminUser)

*Why:* Covers tools relevant to the tamper/bypass concern that are not already blocked by a dedicated policy above: netplwiz (account management UI) and mmc.exe (hosts lusrmgr.msc, secpol.msc, gpedit.msc, services.msc - none of which the child account needs). cmd.exe/powershell.exe/powershell_ise.exe/pwsh.exe are included too, layered on top of DisableCMD and the execution-policy restriction above. regedit.exe and taskmgr.exe are deliberately left out - DisableRegistryTools and DisableTaskMgr already block them more strongly (including non-Explorer launch paths), so listing them here would be redundant. Known limitation: "Don't run specified Windows applications" only intercepts launches started via Explorer (Start menu, Run box, desktop icons) - a renamed copy of the executable, or one launched from a script/other process, is not caught. It is a UI-level speed bump, not a security boundary - AppLocker (step 6) is the boundary.

*Registry values:*
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer` -> `DisallowRun` (DWord) = `1`
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowRun` -> `1` (String) = `cmd.exe`
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowRun` -> `2` (String) = `powershell.exe`
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowRun` -> `3` (String) = `powershell_ise.exe`
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowRun` -> `4` (String) = `pwsh.exe`
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowRun` -> `5` (String) = `netplwiz.exe`
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\DisallowRun` -> `6` (String) = `mmc.exe`

*Verify:* As the child account, try Start menu / Win+R for netplwiz, mmc, cmd, powershell. Expect: "This operation has been cancelled due to restrictions in effect on this computer."

*Confidence:* High - documented ADMX (Explorer.admx, "Don't run specified Windows applications" / DisallowRun), well-known limitations as noted above.

**GPO-28b - Change the time zone** (User Rights Assignment, via secedit; machine-wide by nature, admin exempted via group membership)

*Why:* Windows grants "Change the time zone" to the built-in Users group by default, so any standard account - including the child's - can normally do this without elevation. Removing Users (S-1-5-32-545) closes that; Administrators and LOCAL SERVICE keep the right untouched, since only the SID being removed is edited.

*Change:* remove S-1-5-32-545 from `SeTimeZonePrivilege` if present; keep S-1-5-32-544, S-1-5-19.

*Verify:* As the child account, try Settings > Time & language > Date & time > Time zone. Expect the control to be greyed out / an access-denied error. As the parent admin, it should work normally.

*Confidence:* High - SeTimeZonePrivilege's default holder list (Administrators, LOCAL SERVICE, Users) is documented and was corroborated by independent references in this pass; the script still reads the machine's actual current holder list before editing rather than assuming this default (see `Apply-GpoLockdown.ps1` -> `Set-PrivilegeRestrictions`).

**GPO-28c - Change the system time** (User Rights Assignment, via secedit; machine-wide by nature, admin exempted via group membership)

*Why:* Modern Windows 10/11 clean installs typically do NOT grant "Change the system time" to the Users group by default (only Administrators and LOCAL SERVICE) - unlike the time zone privilege above. This entry is included for completeness/defense-in-depth and is a no-op on a stock Windows 11 install. The apply script checks the machine's actual current holder list first and only removes Users if it is actually present, rather than assuming a default that may already be correct - avoids an unnecessary change on a setting that likely doesn't need one.

*Change:* remove S-1-5-32-545 from `SeSystemtimePrivilege` if present; keep S-1-5-32-544, S-1-5-19.

*Verify:* As the child account, try to manually set the system clock (not just time zone) via Settings > Time & language > Date & time (turn off "Set time automatically" first, if needed to see the Change button). Expect it to be blocked/require admin credentials.

*Confidence:* Medium - default holder list for this privilege varies by Windows version/edition; verify against the actual machine's exported security template before assuming Users is present to remove.

**Adding/removing accounts:** no additional User Rights Assignment change - a standard
account already cannot add/remove Windows accounts without an admin-credential
elevation prompt, so the real backstop here is the account model itself (child is
non-admin, per README's account structure), not a GPO setting that doesn't otherwise
exist. GPO-25a/25b (hiding the Accounts Control Panel applet and Settings pages) and
GPO-28a (hiding netplwiz from Explorer launch) remove the convenient self-service UI
surface for this, which is this sub-issue's actual GPO-level contribution.

## Known limitations (read before relying on this alone)

- **PowerShell isn't fully blocked by GPO** - only script execution is (GPO-23b). The
  interactive `powershell.exe`/`pwsh.exe` executables are blocked from *Explorer*
  launch only (GPO-28a, easily bypassed by launching them another way). Full
  executable-level blocking is AppLocker's job (MVP1 critical path step 6). This is a
  deliberate scope boundary, not an oversight - see GPO-23b's Why.
- **DisallowRun (GPO-28a) only intercepts Explorer-initiated launches.** It's a UI
  speed bump, not a security boundary.
- **Machine-scope settings (GPO-23b, 26a, 26b) also apply to the parent admin.** All
  three are trivially reversible via `Undo-GpoLockdown.ps1` if that's ever a problem
  in practice.
- **The Non-Administrators container mechanism has not been confirmed against a real
  Group Policy engine in this pass** (see "What this pass could verify" above) - the
  first real-machine run should be followed by `gpresult /r` (or `/h report.html`) as
  both accounts, to confirm the settings actually took effect, before treating this as
  done.

## Directory convention for hardening artifacts

No layout existed yet for hardening artifacts before this pass (CLAUDE.md: "No
directory layout for scripts/policies/source has been chosen yet. The first Architect
pass should decide one and record it as an ADR."). Sibling Developer passes are
implementing Smart App Control, AppLocker, and Edge policy hardening concurrently in
separate worktrees, with no live coordination possible - see the top-level
[`hardening/README.md`](../README.md) for the proposed convention this pass chose and
why, so the four pieces land in a consistent shape. **That choice is not yet ratified
by an ADR** - Matt/an Architect pass should confirm or adjust it once all the
concurrent passes are visible together.
