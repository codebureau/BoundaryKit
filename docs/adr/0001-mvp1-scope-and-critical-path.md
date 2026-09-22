# 0001 — MVP1 scope: threat model, critical path, and boundaries

**Date:** 2026-09-22
**Status:** Accepted

## Context

Decided via a `/grill-me` session to determine the minimal control set giving the highest overall safety assurance, before turning the plan into GitHub issues/milestones.

## Decision

- **Primary threat model: intentional bypass by the child**, not accidental content exposure or external malware. The account/AppLocker/GPO controls are anti-bypass by design; malware resistance is a side effect of that, not a separate MVP1 goal. Accidental exposure (content filtering) and external-actor threats are real but deferred.
- **MVP1 is hardening-only.** The C#/.NET monitoring tool (watcher, logging, dashboard) is entirely deferred to MVP2. Prevention (non-admin account + AppLocker default-deny + GPO lockdown) is where the actual safety comes from; detection/logging adds visibility on top of that but isn't required to call the machine safe.
- **Boot-level/firmware security, added — not in the original README plan.** Nothing in the OS/browser hardening plan survives a live-USB boot: it gets full disk access and can reset the local admin password, bypassing every OS-level control at once. MVP1 adds **BIOS/UEFI lockdown** (Secure Boot enabled, boot order locked to the internal drive, supervisor/BIOS password set) as a first-class item — a precondition for the rest of the plan actually holding, not an optional extra.
- **MVP1 critical path, in dependency order** (Smart App Control must be enabled before other software touches the machine; AppLocker/GPO must be scoped to the child account, so accounts precede them; AppLocker goes through an audit-mode window before enforce, per CLAUDE.md's rollback rule):
  1. Windows reinstall & baseline (manual)
  2. BIOS/UEFI lockdown
  3. Account structure (manual: parent admin, child non-admin)
  4. Smart App Control (Strict + reputation)
  5. Local GPO lockdown
  6. AppLocker (audit mode → review → enforce)
  7. Edge policy hardening
  8. Verification pass (Tester-agent + manual)
- **Explicitly deferred, not dropped** — each tracked as its own backlog issue outside MVP1: website allow/deny list (content filtering, not bypass-prevention), Family Safety enrollment (likely redundant with the above for this threat model), time limits/usage boundaries (a separate usage-boundary feature, not bypass-prevention), and child-involved bypass testing (valuable for the secondary collaborative-learning goal, but not a gate on the safety milestone).
- **MVP1's Definition of Done does not require a child-involved testing session.** It closes on Tester-agent verification (policy/config correctness) plus a manual pass by Matt. Gating the safety milestone on a collaborative session would tie two goals with different pacing (safety assurance vs. teaching/trust) to one critical path.
- **Issue granularity**: one parent GitHub issue per cluster above (e.g. "AppLocker"), decomposed into native sub-issues per control or small logical group (e.g. exe/msi default-deny, script blocking, folder allow-list, publisher allow-list) — not one flat issue per cluster, not one issue per individual setting.

## Consequences

- The GitHub milestone "MVP1 — Baseline Safety" and its issues/sub-issues are scoped directly from this decision.
- The monitoring tool, website allow-list, Family Safety, time limits, and child-involved testing exist as unmilestoned backlog issues, not silently dropped.
- Any future change to this scope (e.g. pulling the monitor into MVP1) should be recorded as a superseding ADR, not a silent edit here.
