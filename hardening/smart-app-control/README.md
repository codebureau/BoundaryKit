# Smart App Control — enable Strict mode and verify it

**Closes:** #19 (parent), #20 (enable Strict mode), #21 (verify reputation-based blocking)
**MVP1 critical path:** step 4, per [`docs/adr/0001-mvp1-scope-and-critical-path.md`](../../docs/adr/0001-mvp1-scope-and-critical-path.md) — after account setup (step 3), before Local GPO lockdown and AppLocker (steps 5–6).
**Type:** manual procedure. There is no supported Group Policy, MDM/Intune CSP, or provisioning-package path for Smart App Control on a non-domain-joined, non-Intune-managed consumer PC (which is what this machine is — see README "Account Structure"). It is a Windows Security app toggle. See "Why this is manual, not a script" below for the one registry key that does exist and why it isn't used here.

## Why this is manual, not a script

Every other hardening artifact in this project's plan (GPO, AppLocker, Edge policy) has a scriptable or importable configuration surface. Smart App Control does not, for this machine's configuration:

- **No Group Policy template.** Smart App Control ships no `.admx`. It isn't exposed under `gpedit.msc`.
- **No consumer-facing MDM/CSP path.** Microsoft does document an `ApplicationControl` CSP and "App Control for Business" policies, but those are Intune/enterprise-managed-device features (Windows Pro/Enterprise devices enrolled in Intune). This machine is deliberately *not* enterprise-managed — it's a personal Microsoft-account admin plus a local non-admin child account (see README "Account Structure") — so that path doesn't apply and enrolling the machine just to get it would be a bigger change than the control is worth.
- **One registry value exists, but flag it clearly: it's documented, but not for this.** Microsoft Learn documents `VerifiedAndReputablePolicyState` (`DWORD`) under `HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy`, values `0 = Off`, `1 = Enforce`, `2 = Evaluation`, applied by running `CiTool.exe -r` afterwards. This is a real, documented Microsoft key — not something reverse-engineered — but Microsoft's own docs frame it as existing *specifically so enterprises can proactively force Smart App Control OFF fleet-wide*, not as a general-purpose "set it to Strict from a script" mechanism for a single consumer PC. Source: [Application Control for Windows — Microsoft Learn](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/appcontrol) ("If you want to proactively turn off Smart App Control across your organization's endpoints, set the VerifiedAndReputablePolicyState...").

  Given that, and per CLAUDE.md's rule that every restriction needs a documented rollback and shouldn't rely on undocumented mechanisms: **this project uses the Windows Security UI toggle, not the registry key**, for actually setting the mode. The registry value is worth knowing about only as a *diagnostic* — if Smart App Control ever appears stuck or you want to confirm its current state matches the UI, you can read (not write) that value with `Get-ItemProperty`. Writing it is out of scope here.

## Real-world constraint that changed recently — read before you start

Historically, Smart App Control could only be turned on as part of a **clean Windows install** — if you turned it off, or never turned it on, the only way back was a full reinstall. That's the reasoning baked into ADR 0001's critical-path ordering ("must be enabled before other software touches the machine").

**As of the April 2026 cumulative updates** (Windows 11 24H2 build 26100.8116+, 25H2 build 26200.8116+, or 26H1 build 2800.1896+), Microsoft removed that restriction: Smart App Control can now be turned on, off, and back on again from Windows Security at any time, with no reinstall required. Sources: [Microsoft Support — Smart App Control FAQ](https://support.microsoft.com/en-us/windows/security/threat-malware-protection/smart-app-control-frequently-asked-questions), [CIAOPS — Existing systems can now enable Windows Smart App Control](https://blog.ciaops.com/2026/04/16/existing-systems-can-now-enable-windows-smart-app-control-and-you-should/).

**What this means for this task:** if the target machine is on a current build (it should be, per checklist step 4 "Apply Windows updates" happening before this step), the "must be step 4, before anything else touches the machine" urgency from ADR 0001 is weaker than it was when that ADR was written — enabling Smart App Control late (or turning it off and back on later) no longer permanently forgoes the feature. **This doesn't change what to do here** — still enable it now, in this order, since evaluation mode benefits from starting clean and there's no cost to following the existing plan — but it's worth flagging to Matt/the Architect: the "irreversible if delayed" premise in ADR 0001 step 4 is out of date and could be revisited if the critical path ever needs reordering. I haven't edited the ADR; that's an Architect call.

## Prerequisites

- [ ] Windows 11 Pro, fully updated (checklist step 4, "Apply Windows updates," already done)
- [ ] You're signed in as the **parent admin account** (Microsoft account, Administrator) — changing this setting is a system-wide security control and Windows Security may prompt for admin approval
- [ ] Settings → Privacy & security → Diagnostics & feedback → **Send optional diagnostic data** is turned **on**. Smart App Control's cloud reputation lookups depend on this; historically the toggle stayed greyed out without it. Source: [xda-developers — Smart App Control was Windows 11's worst restriction, and Microsoft just quietly fixed it](https://www.xda-developers.com/smart-app-control-was-windows-11s-worst-restriction-and-microsoft-just-quietly-fixed-it/)
- [ ] No developer mode enabled (Settings → System → For developers → Developer Mode should be **off**) — Smart App Control disables itself for developer-mode machines
- [ ] Not domain-joined / not Intune-enrolled (should already be true per the account structure design)

## Part 1 — Enable Strict mode (closes #20)

1. Open **Settings** (`Win + I`).
2. Go to **Privacy & security** → **Windows Security** → click **Open Windows Security**.
3. In the Windows Security app, select **App & browser control** in the left-hand navigation.
4. Click **Smart App Control settings**.
5. You'll see one of three states: **Off**, **Evaluation**, or **On**.
   - **If it shows "Evaluation"**: this is normal on a recently-installed or recently-updated system — Windows is still deciding whether your app/data usage patterns are a good fit. You can wait for it to auto-resolve, or set it directly (step 6) — manually forcing it to **On** is supported and doesn't require waiting out evaluation.
   - **If it shows "Off"**: proceed to step 6.
   - **If it shows "On" already**: it's done — skip to Part 2 to verify it.
6. Set it to **On**. (There is no setting literally labeled "Strict" — Smart App Control's fully-enforcing state is called **On** in the UI; this project's README/issue titles use "Strict" to describe that same enforcing state, to distinguish it from "Evaluation." They're the same thing.)
7. Confirm any UAC/admin-approval prompt.
8. Restart if prompted (usually not required just to flip the toggle, but do so if Windows asks).

**What this one toggle actually covers.** The README's Windows Hardening Plan lists four separate bullets under "Smart App Control" (Set to Strict / Enable reputation-based protection / Block untrusted downloads / Block potentially unwanted apps). Worth noting for anyone following along: these are not four separate settings. Smart App Control has exactly one mode control (Off/Evaluation/On). Reputation-based evaluation, untrusted-download blocking, and PUA blocking are all *what "On" does* — Microsoft's Intelligent Security Graph reputation check plus signature verification, applied to everything that tries to run. There's nothing further to configure once step 6 is done.

## Part 2 — Verify it's actually blocking things (closes #21)

Do this immediately after enabling it, and re-check occasionally — Smart App Control can silently disable itself again if a prerequisite regresses (e.g. diagnostic data gets turned off, or the account becomes dev-mode).

### Check 1 — confirm the state stuck

Settings → Privacy & security → Windows Security → App & browser control → Smart App Control settings. Confirm it still reads **On**, not "Off" or "Evaluation." (It can silently revert — see prerequisites above.)

### Check 2 — safe PUA test file (tests Windows' reputation/PUA blocking path)

AMTSO (the Anti-Malware Testing Standards Organization) publishes a standard, industry-agreed **test file that behaves like a Potentially Unwanted Application without being malicious or harmful** — used precisely so people can confirm PUA-blocking is configured correctly without downloading a real PUA.

1. In Edge, go to: `https://www.amtso.org/feature-settings-check-potentially-unwanted-applications/`
2. Attempt the PUA test download offered on that page.
3. **Expected result:** the download is blocked or flagged before it completes — by Microsoft Defender SmartScreen, Smart App Control, or both (they share the same underlying reputation service, so a clean pass/fail line between them isn't always visible to the user). If the file downloads cleanly with no warning at all, something in the chain isn't configured — check Check 1 and the prerequisites again.

Treat this as supporting evidence, not proof specific to Smart App Control alone — it's the standard industry test for PUA-blocking broadly, and Windows has more than one layer (SmartScreen, Defender, Smart App Control) that can catch it.

### Check 3 — untrusted/unrecognized executable (tests Smart App Control specifically)

Smart App Control blocks unsigned or low-reputation executables it doesn't recognize, independent of whether they're actually malicious. The cleanest, safest way to trigger this deliberately:

1. On a *different* machine (or in a sandboxed/temp environment), compile a trivial "hello world" program (any language that produces an unsigned `.exe` — a two-line C# console app via `dotnet build` works well) and copy the resulting `.exe` to the target machine — e.g. via USB drive or a private file share, **not** via a well-known download source.
2. Because that binary is unsigned and has zero prevalence/reputation with Microsoft's cloud service, Smart App Control should refuse to run it.
3. Double-click it. **Expected result:** a Windows Security dialog: *"Smart App Control has blocked part of this app"* (or similar wording) with no option to bypass or run anyway. If it runs without any prompt, Smart App Control isn't enforcing — go back to Check 1.

This deliberately avoids downloading anything actually malicious. A self-compiled, unsigned, never-before-seen binary is exactly what Smart App Control is designed to catch (unrecognized code), and it's inherently safe since you wrote it.

### Check 4 — confirm the block was logged (Protection history)

Windows Security → **Virus & threat protection** → **Protection history**. Look for an entry mentioning **Smart App Control** / **Blocked app** corresponding to the Check 3 attempt. This is the easiest place for Matt to check later without digging into Event Viewer.

### Check 5 — optional, technical: Event Viewer confirmation

For a more precise/auditable record (useful if this ever needs to go in a "security report" per the README's collaborative-learning plan):

1. Open **Event Viewer** → **Applications and Services Logs** → **Microsoft** → **Windows** → **CodeIntegrity** → **Operational**.
2. Look for:
   - **Event ID 3077** — an app was blocked in enforcement mode (this is the one that matters once Smart App Control is "On")
   - **Event ID 3076** — an app *would have been* blocked (only fires in Evaluation mode)
   - **Event ID 3089** — signature/reputation details correlated with a 3076/3077 event
3. Confirm a 3077 event exists with a timestamp matching the Check 3 test.

Source for event IDs: [Understanding App Control event IDs — Microsoft Learn](https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/operations/event-id-explanations).

### Record the result

Once both checks pass, note the outcome under the README's "Notes & Decisions" running-notes section (per CLAUDE.md, that section is for testing results/issues found, not a full ADR) — Windows build number, date enabled, and which checks passed.

## Rollback

Smart App Control is turned off the same way it's turned on: Settings → Privacy & security → Windows Security → App & browser control → Smart App Control settings → **Off**.

- **This is now safely reversible.** Before the April 2026 update, turning Smart App Control off was a one-way door requiring a full Windows reinstall to get back to "On." That's no longer true on current builds (see "Real-world constraint" above) — it can be turned off and back on freely, so there's no lockout risk in experimenting with this setting, unlike the GPO/AppLocker controls later in the critical path.
- Turning it off does **not** touch anything else on the machine (no app is uninstalled, no other policy changes) — it only stops the reputation/signature check going forward.
- If Smart App Control ever blocks something Matt genuinely needs (e.g. a legitimate but obscure tool for the monitoring-tool build later in the plan), the options are: wait for its reputation to build, get it signed, or temporarily switch to Off/Evaluation, do the task, and switch back to On — there's no per-app exception list.

## Open questions / judgment calls for review

- **Directory placement:** moved to `hardening/smart-app-control/README.md` to match the `hardening/<cluster>/` convention the three parallel Developer passes (GPO, AppLocker, Edge) independently converged on — originally drafted at `docs/hardening/smart-app-control.md` before reconciliation.
- **ADR 0001's ordering rationale is partly outdated** (see "Real-world constraint" section above) — flagging for Matt/Architect, not changing the ADR myself.
- **The "Strict" naming**: I documented that Smart App Control has no mode literally called "Strict" (it's "On") and treated the README/issue title's "Strict" as this project's label for that state. If that's not what was intended, this is the place to correct it.
