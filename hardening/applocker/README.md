# AppLocker policy

Implements GitHub issue #29 "AppLocker" and its sub-issues (#30-#34). Step 6 of the
MVP1 critical path in
[`docs/adr/0001-mvp1-scope-and-critical-path.md`](../../docs/adr/0001-mvp1-scope-and-critical-path.md).
Per that ADR, this is the single highest-assurance control in MVP1: default-deny
execution for the non-admin child account, closing the gap left by "the child just
double-clicks the installer they downloaded."

## Directory convention (provisional - see note below)

```
hardening/
  applocker/
    README.md                       - this file
    policy-audit.xml                - the policy to import, in audit mode
    policy-rollback-disable.xml     - the "undo everything" policy
    scripts/
      Prepare-AppLockerPolicy.ps1   - resolves the child-group SID placeholder
      Deploy-AppLockerPolicy.ps1    - imports a resolved policy (the only script here that touches live policy)
      Review-AppLockerAuditLog.ps1  - summarises the AppLocker audit log for the review step
```

`hardening/<control-name>/` per control, each with its own `README.md` plus whatever
artifacts that control needs (policy XML, `.reg`, scripts). Reasoning: CLAUDE.md says no
layout has been chosen yet and defers that choice to the first Architect pass; this
Developer pass is running in parallel with three others (Smart App Control, GPO
lockdown, Edge policy) with no live coordination, so a flat top-level folder per control
- rather than one shared "policies/" dump or a layout nested under `docs/` - minimises
the chance of two passes editing the same file. It mirrors how the README already groups
the hardening plan (one subsection per control) and keeps each control's artifacts,
rollout docs and rollback together, which is exactly what needs reviewing as one unit in
a PR. **This is a proposal, not a ruling** - if the Architect's first pass picks a
different layout, this folder moves, not the reasoning behind it.

## Format choice: native AppLocker policy XML, not LGPO/GPO-embedded

This machine is a standalone (non-domain) Windows 11 Pro PC, so there is no domain GPO
to embed rules into in the first place - the "Local Group Policy" work in this project
(a separate hardening pass) already applies via `gpedit.msc`/`secedit`, which stores its
settings in `registry.pol`, a binary format that isn't diff-friendly. AppLocker rules are
different: Windows exposes them as their own native, human-readable XML schema via
`Get-AppLockerPolicy`/`Set-AppLockerPolicy`, independent of whether they're also mirrored
into a GPO. Using that native XML directly:

- needs no third-party tooling (`LGPO.exe` exists to convert *other* local security
  policy into text for source control - AppLocker doesn't need that detour, it's already
  text),
- is exactly the file `Set-AppLockerPolicy -XmlPolicy` and the Local Security Policy
  snap-in (`secpol.msc` → Application Control Policies → AppLocker → right-click → Import
  Policy...) both import/export as-is - no format conversion between "what's in git" and
  "what Windows applies",
- diffs cleanly in a PR, which is the whole point of "reviewable, reversible artifact."

If this machine is ever domain-joined, these same rule collections can be pasted into a
GPO's AppLocker node unchanged - the schema is identical either way.

## Assumption this depends on: the child account/group (issue #15)

**Issue #15 "Account structure" was not done as of this pass.** There is no real child
account or local group on the target machine yet, so `policy-audit.xml` cannot contain a
real SID for it (AppLocker rules are scoped by `UserOrGroupSid`, not by account name -
the XML format itself requires an actual SID string).

The policy file ships with every child-scoped rule using the literal placeholder text
`%%CHILD_GROUP_SID%%` instead of a SID, and assumes:

- the child's local account will be added to a **local group named `BoundaryKit-Child`**
  (not scoped directly to the user account) - group scoping means if the child's account
  is ever recreated (new SID) you re-add it to the group instead of re-editing every
  rule in this policy.
- `scripts/Prepare-AppLockerPolicy.ps1` resolves that group name to its real SID and
  writes a ready-to-import copy of the policy. It takes `-GroupName` if issue #15 lands
  with a different name than `BoundaryKit-Child`.

**If #15 used a different name, or scoped directly to the user instead of a group,
update `-GroupName` (or `Prepare-AppLockerPolicy.ps1`'s default) before doing anything
else here** - do not hand-edit the SID into `policy-audit.xml` itself, so the file stays
usable against whatever the real group ends up being called.

`Deploy-AppLockerPolicy.ps1` refuses to import a file that still contains the
`%%CHILD_GROUP_SID%%` placeholder, so a forgotten substitution fails loudly instead of
silently applying a rule to nobody (or, worse, to a SID nothing points at).

## What's in `policy-audit.xml`

All rule collections import as `EnforcementMode="AuditOnly"` - nothing blocks anything
until you deliberately flip a collection to `Enabled` (see "Audit-mode-first rollout"
below).

| Collection | Default | Child gets |
|---|---|---|
| **Exe** (#30) | Deny | Narrow allow-list: approved folders (#32) + approved publisher (#33) |
| **Msi** (#30) | Deny | Nothing configured yet (empty scaffold - see below) |
| **Script** (#31, covers ps1/vbs/js/bat/cmd) | Deny | Nothing configured yet (empty scaffold - see below) |
| Dll, Appx | Not configured | Out of scope for #29's sub-issues |

**Every collection also has an unconditional `Allow *` rule for `BUILTIN\Administrators`
(SID `S-1-5-32-544`, a well-known SID - no placeholder needed) and for `NT
AUTHORITY\SYSTEM` (`S-1-5-18`, needed so Windows servicing/updates aren't audit-flagged
or blocked).** This is the in-policy half of the rollback guarantee: whatever else is
misconfigured, the parent admin account is never restricted by this file, in any
collection, in either audit or enforced mode.

### Why Msi and Script start with an empty allow-list scaffold, not a populated one

The README's Windows Hardening Plan says "Block all `.msi` installers" and "Block
scripts" with no stated exception, but "Block all `.exe` except whitelisted apps" -
explicitly conditional. Matt confirmed on review (2026-09-22) that a narrow allow-list
mechanism should exist for both, matching Exe's shape, but that nothing specific needs
allowing yet - so both collections default-deny for the child today, with a ready-to-use
template at the bottom of each collection's comment (identical pattern to the `Exe`
publisher/path rules) for whenever a real need shows up - e.g. a specific signed
installer, or a folder for scripts built together as part of the collaborative-learning
goal. Extending either is a small, self-contained XML addition, not a policy redesign.

### Approved folders (#32) and approved publisher (#33) are placeholders

- **Folders:** `%PROGRAMFILES%\*`, `%OSDRIVE%\Program Files (x86)\*`, `%WINDIR%\*`.
- **Publisher:** any Microsoft-signed binary (`O=MICROSOFT CORPORATION, L=REDMOND,
  S=WASHINGTON, C=US`, any product, any version) - verified against this dev machine's
  real, currently-installed `notepad.exe` publisher string (see "What was verified"
  below), not guessed.

**Matt needs to review and extend this list for whatever legitimate apps the child
actually needs** - a game, a specific launcher, etc. that isn't Microsoft-signed and
isn't under Program Files/Windows won't run until it's added. `policy-audit.xml` has a
copy-paste template (an XML comment, at the bottom of the `Exe` collection) for adding
one more `FilePublisherRule`. Prefer a publisher rule over a path rule when the app is
signed - it survives the app updating itself; a path rule breaks if the install folder
changes.

### Deny carve-outs inside the folder allow-list

A broad "allow anything under Program Files / Windows" rule is a known, documented
AppLocker weak spot: several subfolders under those trees are user-writable (`%WINDIR
%\Temp`, `%WINDIR%\Tasks`, `%WINDIR%\System32\spool\drivers\color`), so a downloaded
payload dropped there would match the folder allow rule. `policy-audit.xml` adds explicit
`Deny` rules for those paths, plus for the child's own profile Downloads/AppData (where a
browser download or an extracted archive actually lands). AppLocker's Deny action always
wins over a broader Allow for the same user, regardless of rule order - **this was
verified directly** (see below), not assumed from documentation.

## Audit-mode-first rollout

1. **Complete issue #15** (child account + `BoundaryKit-Child` local group, or whatever
   name is chosen - update `Prepare-AppLockerPolicy.ps1 -GroupName` if different).
2. On the target PC, elevated PowerShell:
   ```powershell
   cd hardening\applocker
   .\scripts\Prepare-AppLockerPolicy.ps1
   ```
   Writes `policy-audit.resolved.xml` next to the source file, with the real SID
   substituted in. Review the diff between placeholder and resolved file before going
   further - it should be a pure find/replace, nothing else.
3. **Confirm the Application Identity service is running** - AppLocker (audit or
   enforced) does nothing without it:
   ```powershell
   Get-Service AppIDSvc
   Set-Service AppIDSvc -StartupType Automatic
   Start-Service AppIDSvc
   ```
4. Import in audit mode:
   ```powershell
   .\scripts\Deploy-AppLockerPolicy.ps1 -XmlPolicy .\policy-audit.resolved.xml
   ```
   This is the whole point of shipping the file with `EnforcementMode="AuditOnly"` on
   every collection - nothing is blocked yet, only logged as "would have been blocked."
5. **Let the child use the machine normally for a representative period** (a
   few days to a week - long enough to cover the apps/games/homework tools actually in
   regular use, not just a five-minute smoke test) before touching enforcement.

### Audit-mode review (closes #34, gates the flip to Enforce)

1. Review what would have been blocked:
   ```powershell
   .\scripts\Review-AppLockerAuditLog.ps1 -Hours 168
   ```
   Reads the real AppLocker event log channels (`Microsoft-Windows-AppLocker/EXE and
   DLL`, `Microsoft-Windows-AppLocker/MSI and Script`), groups "would have been blocked"
   hits (event ID 8003) by file path, and prints a plain summary. Read-only - it does not
   change policy or touch the log.

   You can also read the raw log directly: Event Viewer → Applications and Services Logs
   → Microsoft → Windows → AppLocker → each of the four channels shown there.
2. For every distinct file path that shows up:
   - **Legitimate app the child needs** → add a rule for it to `policy-audit.xml` (prefer
     `FilePublisherRule`, see the template comment), re-run
     `Prepare-AppLockerPolicy.ps1`, re-import in audit mode, and give it another
     observation period before enforcing.
   - **Correctly caught** (an installer, a script, something outside the approved set) →
     leave it. This is the policy working as intended.
3. Only once a full observation period shows no more "should have been allowed" hits for
   a given collection, flip **that collection only** to enforced - not all three at once.
   Edit `EnforcementMode="AuditOnly"` → `EnforcementMode="Enabled"` for just that
   `RuleCollection` in `policy-audit.xml` (keep the others in audit until they've each had
   their own clean review), then repeat steps 2-4 of the rollout to re-resolve and
   re-import.
4. Re-run the audit-log review periodically even after enforcing - `Review-
   AppLockerAuditLog.ps1` still reports event ID 8004 ("blocked", fires once enforced) so
   you can see what's actually being stopped in practice, not just in theory.

## Rollback

The parent admin account is **never** affected by this policy in the first place - every
collection has an unconditional `Allow *` rule for `BUILTIN\Administrators`, so there is
no scenario where a misconfiguration here locks the parent out. Rollback exists for
"something legitimate for the child got wrongly caught," not for admin lockout recovery.

**Surgical (preferred):** if one collection is causing a problem post-enforcement, flip
just that collection's `EnforcementMode` back to `AuditOnly` in `policy-audit.xml`,
re-resolve, re-import. This keeps the other collections' protection intact while you fix
the one rule that's wrong.

**Full rollback:** to remove AppLocker's effect entirely:
```powershell
cd hardening\applocker
.\scripts\Deploy-AppLockerPolicy.ps1 -XmlPolicy .\policy-rollback-disable.xml -Force
```
This replaces the applied policy with one where every collection is
`EnforcementMode="NotConfigured"` and no rules - functionally identical to AppLocker
never having been configured. Verified directly (see below) to result in
`AllowedByDefault` for a non-admin user, i.e. genuinely no restriction, not just an empty
allow-list under a still-enforced deny.

If AppLocker rules were ever also configured by hand via `gpedit.msc`/`secpol.msc`
instead of (or in addition to) `Set-AppLockerPolicy`, clear them there too: Local
Computer Policy → Computer Configuration → Windows Settings → Security Settings →
Application Control Policies → AppLocker → right-click each rule collection → "Delete
all rules...".

If somehow the Application Identity service itself becomes the problem (not the rules),
`Stop-Service AppIDSvc; Set-Service AppIDSvc -StartupType Disabled` stops all AppLocker
enforcement immediately regardless of what policy is loaded - a blunter, faster kill
switch than reimporting a policy, useful if something is actively broken and you need it
stopped right now rather than correctly.

## What was verified, and how

This was authored and checked in a git worktree on a development machine, never applied
to it - **no `Set-AppLockerPolicy` call, no AppIDSvc changes, no account/group changes
were made on this machine.** Verification split into what's automatable without touching
real policy, and what genuinely needs the target machine:

**Automated / verified here:**
- Both XML files are well-formed and free of the XML-comment double-hyphen bug that
  silently truncates comments (`grep -n -- '--'` over both files, no false hits outside
  `<!--`/`-->`).
- Both parse as valid `AppLockerPolicy` documents and report the expected rule
  collections/counts (`[xml]` parse + XPath count: Exe 11 rules, Msi 2, Script 2, Dll/Appx
  0/NotConfigured - matches what was authored by hand).
- **Schema/semantic validation against the real AppLocker engine**, via
  `Test-AppLockerPolicy` (a read-only simulate-only cmdlet - it never calls
  `Set-AppLockerPolicy` and does not touch the machine's applied policy):
  - `BUILTIN\Administrators` → `Allowed` for real system EXEs (`notepad.exe`,
    `explorer.exe`), confirming the admin-never-locked-out rule actually works, not just
    reads plausibly.
  - `Everyone` (a SID this policy deliberately never grants) → `DeniedByDefault` for the
    same files, confirming this is a real default-deny policy and not accidentally
    permissive.
  - Using `BUILTIN\Users` as a stand-in for the not-yet-created child group (a real,
    always-present SID, so the simulation engine can fully evaluate it - a fabricated SID
    made the engine error out on identity lookup rather than evaluating the rules, so this
    substitution was necessary for a meaningful test): folder-allow files (`notepad.exe`,
    `explorer.exe` under `%WINDIR%`) → `Allowed`; files outside the approved folders
    (real files already present in `Downloads`/`AppData\Local` on this dev machine) →
    `Denied`.
  - **Deny-beats-broader-Allow precedence** was verified directly, not assumed: an
    isolated test policy with a broad `Allow` on a scratch folder and a narrower `Deny` on
    a subfolder inside it, tested against a real file placed in that subfolder →
    `Denied`. This is exactly the mechanism the Program-Files/Windows-folder carve-outs
    depend on.
  - The rollback policy, simulated the same way → `AllowedByDefault` for a non-admin
    user, confirming it truly removes restriction rather than leaving an empty deny in
    place.
  - The Microsoft publisher string used in the publisher allow-list
    (`O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US`) was cross-checked against
    `Get-AppLockerFileInformation` run on this machine's real, currently-installed
    `notepad.exe` - it matches exactly, so it's not a guessed/typo'd DN.
- All three PowerShell scripts: parsed clean with
  `[System.Management.Automation.Language.Parser]::ParseFile` (no syntax errors) and
  linted clean with PSScriptAnalyzer (only `PSAvoidUsingWriteHost` warnings, which are
  expected/accepted - these are interactive console scripts meant to give the person
  running them colored status output, not library functions meant for a pipeline).
- `Review-AppLockerAuditLog.ps1` was actually executed against this machine's real (but
  currently unconfigured, 0-record) AppLocker event log channels and ran cleanly,
  confirming the channel names/event IDs it queries are correct for this Windows build
  and that it doesn't error on an empty result.
- `Prepare-AppLockerPolicy.ps1`'s substitution logic was exercised (via `sed`, mirroring
  what the script's `-replace` does) against the real policy file and confirmed zero
  `%%CHILD_GROUP_SID%%` occurrences remain afterward.

**Genuinely needs the real target machine (not done here, not fakeable):**
- Actually running `Prepare-AppLockerPolicy.ps1` against a real `BoundaryKit-Child`
  group once issue #15 exists (this pass could only prove the regex-replace mechanism
  works, not resolve a real group SID that doesn't exist yet).
- Actually running `Deploy-AppLockerPolicy.ps1` / `Set-AppLockerPolicy` to import the
  policy - deliberately not done on this dev machine per project rules.
- Whether audit-mode logging actually populates correctly end-to-end under the real
  child account doing real things (this pass verified the *query* side of the audit log
  works against this build's channels; it can't generate real child-session audit events
  without a live import).
- The actual flip to `Enabled` and confirming legitimate child use isn't broken -
  needs a real audit-log observation period on the real machine, which is the whole
  point of the audit-mode-first design.
- Whether `%OSDRIVE%` resolves as expected in practice on the target machine (it should
  be `C:` on essentially any single-drive Windows install, but this dev machine's own
  drive letter wasn't assumed to necessarily match the target PC's).
