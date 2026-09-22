# 0002 — Hardening artifact directory convention

**Date:** 2026-09-22
**Status:** Accepted

## Context

CLAUDE.md flagged the directory layout for hardening scripts/policies as an open decision, to be made by the first Architect pass. Four Developer passes ran concurrently (Smart App Control #19, Local GPO lockdown #22, AppLocker #29, Edge policy hardening #35, per [ADR-0001](0001-mvp1-scope-and-critical-path.md)'s critical path), each in its own isolated worktree with no way to coordinate live, and each had to pick a location to write its artifacts to.

## Decision

Three of the four (GPO, AppLocker, Edge) independently converged on the same shape without coordination. The fourth (Smart App Control) was reconciled to match. Ratifying it here:

```
hardening/
  README.md            <- index + convention rationale
  gpo/                  <- Local Group Policy (issue #22)
  applocker/            <- AppLocker (issue #29)
  smart-app-control/    <- Smart App Control (issue #19)
  edge/                 <- Edge policy hardening (issue #35)
```

- **Top-level `hardening/`, not nested under `docs/` or `src/`.** These are operational artifacts meant to be run on the target machine, not documentation and not (yet) part of a buildable solution. Keeps room for a future `src/` (the .NET monitor, MVP2) without collision.
- **One subdirectory per MVP1 critical-path cluster**, named to match ADR-0001's own cluster names — matches that ADR's "one parent issue per cluster" issue-granularity decision.
- **Each subdirectory is self-contained**, roughly: `README.md` (what/why/verify/rollback), an apply script + undo/rollback (or a documented manual undo where the control's own tooling provides one, e.g. AppLocker's audit-mode-first flip), any settings data kept separate from script logic so docs and code can be cross-checked rather than drifting apart, and a `tests/` folder for whatever can be verified without touching a real machine. Not a rigid template — each control's actual mechanism can demand a different internal shape.

## Consequences

- Future hardening work (the deferred website allow-list, Family Safety, etc., if picked up later) follows this same top-level split.
- `hardening/gpo/tests/` established a real pattern — round-trip/structural tests + dry-run simulation against scratch paths — worth reusing rather than treating hardening artifacts as untestable just because they can't touch a real machine from CI/a dev box.
