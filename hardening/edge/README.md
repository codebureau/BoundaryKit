# Edge policy hardening

Implements GitHub issue [#35](https://github.com/codebureau/BoundaryKit/issues/35 "Edge policy hardening")
and its sub-issues [#36](https://github.com/codebureau/BoundaryKit/issues/36)
(disable downloads/dev tools/extensions/InPrivate), [#37](https://github.com/codebureau/BoundaryKit/issues/37)
(force SafeSearch + block executable downloads), [#38](https://github.com/codebureau/BoundaryKit/issues/38)
(disable Edge sign-in and profile switching). Step 7 of the MVP1 critical path
([docs/adr/0001-mvp1-scope-and-critical-path.md](../../docs/adr/0001-mvp1-scope-and-critical-path.md)).

## What this is

Microsoft Edge (Chromium) policies, expressed as registry values under
`HKLM\SOFTWARE\Policies\Microsoft\Edge`. This is the same registry hive that Local Group
Policy (`gpedit.msc` → Administrative Templates → Microsoft Edge) writes to — on this
project's non-domain, local-GPO-only setup, setting these values directly has an
identical effect to applying the ADMX policy through gpedit, and is what CLAUDE.md and
the README call for ("exported policy, `.reg`/PowerShell scripts").

Two equivalent, interchangeable delivery forms are provided; use whichever is more
convenient, they are not meant to both be applied:

| File | Use when you want... |
|---|---|
| `apply-edge-policies.ps1` / `rollback-edge-policies.ps1` | A dry run first (`-WhatIf`), a readback/verification printout, and one idempotent script you can re-run safely. **Recommended.** |
| `edge-policies.reg` / `edge-policies-rollback.reg` | A plain double-click import, or to read the exact values in the most minimal, tool-independent form (e.g. for a GPO admin who wants to eyeball raw `.reg` diffs). |

Both require an elevated (Administrator) session/import, because they write to
`HKEY_LOCAL_MACHINE`. For the `.reg` files, either double-click-and-confirm as an admin,
or the more reliable/scriptable route: `reg import edge-policies.reg` from an elevated
prompt.

## Directory convention (proposed)

No hardening-artifact directory layout existed yet (per CLAUDE.md: "No directory layout
for scripts/policies/source has been chosen yet"). This pass proposes and uses:

```
hardening/
  edge/            <- this directory (Edge browser policy)
  gpo/             <- (parallel pass) Local GPO lockdown
  applocker/       <- (parallel pass) AppLocker rules
  smart-app-control/  <- (parallel pass) Smart App Control config
```

One top-level `hardening/<domain>/` directory per control surface, each self-contained
with its own apply/rollback scripts and a README documenting exact policy
names/values/rationale/rollback — mirroring how the monitoring tool will later get its
own top-level directory for C# source. This was made as an isolated Developer pass
running in parallel with three other Developer passes (Smart App Control, GPO lockdown,
AppLocker) with no live coordination available, so it's a reasonable default, not a
ratified decision — **an Architect pass should confirm/reconcile this convention** once
all four passes land, in case another pass picked a different shape (e.g. a flatter
`hardening/*.ps1` layout, or an `edge-policy.json` per CLAUDE.md's other suggested
format).

## Policy reference

All ten policies below were checked against Microsoft's current Edge enterprise policy
documentation (learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/&lt;name&gt;,
pages last updated 2026-05 through 2026-08) via live fetch during this pass — every name,
registry path, value type, and accepted value below is a real, current, non-deprecated
Edge policy, not invented or guessed.

All values live under `HKLM\SOFTWARE\Policies\Microsoft\Edge` unless noted.

| # | Policy (GP unique name) | Value | Type | Meaning | Issue |
|---|---|---|---|---|---|
| 1 | `DownloadRestrictions` | `2` | `REG_DWORD` | `BlockPotentiallyDangerousDownloads` — blocks SmartScreen-flagged/dangerous file types; ordinary downloads (e.g. homework PDFs) go through | #36 |
| 2 | `DeveloperToolsAvailability` | `2` | `REG_DWORD` | `DeveloperToolsDisallowed` — F12/Inspect/view-source all blocked | #36 |
| 3 | `ExtensionInstallBlocklist\1` (subkey) | `"*"` | `REG_SZ` (list) | Wildcard blocks all extensions; none are allowlisted alongside it | #36 |
| 4 | `InPrivateModeAvailability` | `1` | `REG_DWORD` | `Disabled` — InPrivate windows cannot be opened | #36 |
| 5 | `ForceBingSafeSearch` | `2` | `REG_DWORD` | `BingSafeSearchStrictMode` — Edge's default search engine is Bing | #37 |
| 6 | `ForceGoogleSafeSearch` | `1` | `REG_DWORD` (bool) | Enforced in case the user switches default search engine or visits google.com directly | #37 |
| 7 | `SmartScreenEnabled` | `1` | `REG_DWORD` (bool) | Baseline Defender SmartScreen phishing/malware protection | #37 |
| 8 | `SmartScreenPuaEnabled` | `1` | `REG_DWORD` (bool) | Blocks potentially-unwanted-app downloads specifically | #37 |
| 9 | `BrowserSignin` | `0` | `REG_DWORD` | `Disable` — cannot sign in to Edge with any Microsoft/work account | #38 |
| 10 | `BrowserGuestModeEnabled` | `0` | `REG_DWORD` (bool) | Guest browsing profile unavailable | #38 |
| 11 | `BrowserAddProfileEnabled` | `0` | `REG_DWORD` (bool) | Cannot create additional profiles from the Identity flyout/Settings | #38 |

### Why these specific policies answer "block executable downloads" and "profile switching"

- **Block executable downloads (#37):** Edge has no single "block .exe downloads" policy
  name. `DownloadRestrictions = 2` blocks SmartScreen-flagged/dangerous downloads
  (including most executables) while letting ordinary files through — the primary control
  is layered with `SmartScreenEnabled` + `SmartScreenPuaEnabled`, which is what's actually
  doing the file-type-aware blocking here. AppLocker (a separate control) is still the
  real backstop against *running* an executable that does slip through, matching
  CLAUDE.md's framing of Edge policy as one layer, not the sole control.
- **Profile switching (#38):** Edge doesn't expose a single "ProfileSwitching" policy
  name either. The combination of `BrowserSignin = 0` (no signing into an account),
  `BrowserGuestModeEnabled = 0` (no guest profile), and `BrowserAddProfileEnabled = 0`
  (no creating new profiles) together removes every way to get more than the one local
  profile that's already there — so there's nothing to switch *to*.

### Excluded from this pass (deliberately — see issue #35 and ADR 0001)

- **Force Family Safety mode** — inert without Family Safety enrollment, which is itself
  a deferred backlog item. Not implemented, not referenced beyond this note.
- **Website allow/deny list** ("Allowed Websites" in the README) — content filtering, not
  bypass-prevention; a separate deferred backlog issue. Not implemented, not referenced
  beyond this note.

Neither exclusion is represented anywhere in these scripts/`.reg` files.

## Judgment calls made

1. **`DownloadRestrictions = 2` (`BlockPotentiallyDangerousDownloads`) rather than `3`
   (block *all* downloads).** Originally implemented as `3`, the literal reading of the
   README bullet ("Disable downloads") and issue #36's title — Matt confirmed on review
   (2026-09-22) that `2` is the right call: it still blocks SmartScreen-flagged/dangerous
   file types (including most executables) while letting ordinary downloads (e.g. homework
   PDFs) through, avoiding hand-delivering every legitimate file via the parent account.
   The stricter `3` is a one-line change in both the script and the `.reg` file if this
   ever proves too permissive in practice.
2. **Both `ForceBingSafeSearch` and `ForceGoogleSafeSearch` set**, not just one. Edge
   defaults to Bing, but Google is reachable directly regardless of default search
   engine, so both are enforced for defense-in-depth at negligible cost.
3. **`SmartScreenEnabled`/`SmartScreenPuaEnabled` included** — per judgment call #1, these
   are now the primary file-type-aware download control, not just defense-in-depth behind
   a full `DownloadRestrictions = 3` block.
4. **Directory layout** (`hardening/edge/`) — see "Directory convention" above; proposed,
   not architect-ratified, due to no live coordination with the parallel GPO/AppLocker/Smart
   App Control passes.
5. **No `NonRemovableProfileEnabled` / `RestrictSigninToPattern` policies added.** Microsoft's
   own `BrowserSignin` docs mention pairing `BrowserSignin=Disable` with
   `NonRemovableProfileEnabled=Disabled` in the *opposite* scenario (forcing sign-in, not
   disabling it) — not applicable here. Left out to keep this pass scoped to exactly what
   issue #35/#36/#37/#38 ask for; can be added later if a real gap shows up in manual testing.

## Verification

### What was verified during this pass (no real Windows machine touched)

- Every policy name, registry path, value type, and accepted value above was checked
  live against Microsoft's current Edge enterprise policy documentation
  (`learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/<name>`) — confirmed
  real, current (2026), and not deprecated.
- `DefaultExtensionsInstallBlocked` (one of the names suggested in the task) does **not**
  appear to be a real, current Edge/Chromium policy name — `ExtensionInstallBlocklist`
  (confirmed real) is the correct policy for blocking extension installation and is what's
  implemented.
- `apply-edge-policies.ps1` and `rollback-edge-policies.ps1` parse cleanly
  (`powershell -NoProfile -Command "[ScriptBlock]::Create((Get-Content -Raw <file>))"`,
  which parses the script without executing any of it) — see the Developer report for the
  exact command and output.
- Both `.reg` files were checked by eye against the exact same names/values as the
  scripts, line for line.

### What genuinely needs the real machine (cannot be verified here)

- That importing the `.reg` / running the `.ps1` actually writes the values (this session
  never touches the machine it runs on, per CLAUDE.md).
- That Edge actually honours each policy as documented once applied (restart Edge, open
  `edge://policy`, confirm each name above shows the expected value and "Policy source:
  Platform").
- Behavioural checks: downloads are blocked, F12/dev tools are blocked, extensions page
  shows nothing installable, InPrivate menu item is grayed out, bing.com/google.com
  SafeSearch is locked to strict/on and the toggle is disabled in the UI, no sign-in
  option appears in the profile icon menu, no "Add profile"/"Guest" options appear.
- That rollback actually restores default behaviour (re-run the manual checks above after
  rollback and confirm everything is available again).

## Manual test instructions (for Matt, on the real target machine)

1. Open an elevated PowerShell window (Administrator).
2. Dry run first: `cd hardening\edge; .\apply-edge-policies.ps1 -WhatIf` — review the
   list of values it would set.
3. Apply for real: `.\apply-edge-policies.ps1` — it prints back every value it set.
4. Restart Edge completely (close all windows, or `edge://restart`).
5. Open `edge://policy`, click **Reload policies**, and confirm all 10 names in the table
   above appear with **Policy source: Platform** and the values listed.
6. Manually confirm in the browser UI:
   - Try to download an ordinary file (e.g. a PDF) → goes through. Try to download a
     SmartScreen-flagged/known-dangerous file type (e.g. an `.exe` from a low-reputation
     source) → blocked. (`DownloadRestrictions = 2` blocks dangerous types only, not
     everything — see "Judgment calls" above.)
   - Press F12 / right-click → Inspect → nothing opens.
   - Go to `edge://extensions` → cannot install anything from the store.
   - `Ctrl+Shift+N` (InPrivate) → menu item is disabled/unavailable.
   - Search "test" on bing.com and google.com → SafeSearch is strict/on and the setting
     is locked/greyed out.
   - Click the profile icon → no "Sign in", "Guest", or "Add profile" options.
7. To roll back: `.\rollback-edge-policies.ps1` (or import
   `edge-policies-rollback.reg`), restart Edge, re-check `edge://policy` shows each name
   as **not set**, and re-run step 6 to confirm everything is available again.
8. Confirm the parent (Administrator) Windows account itself is untouched throughout —
   these are Edge-only policies, no Windows account/sign-in changes are made by this
   artifact.

## Rollback

Two equivalent options (pick the one matching how you applied it):

- `rollback-edge-policies.ps1` — same `-WhatIf` dry-run support, prints nothing left
  behind that it's responsible for.
- `edge-policies-rollback.reg` — removes the same 10 values plus the
  `ExtensionInstallBlocklist` subkey, and only those; it does not delete the parent
  `...\Edge` key, so it's safe even if other Edge policies get added there later by
  something else.

Removing a policy value (rather than writing an "off" value) returns Edge to
**Not Configured**, i.e. ordinary out-of-the-box Edge behaviour for that setting. Nothing
here ever touches a Windows account, sign-in, or the parent admin's ability to log in —
these are Edge browser policies only.
