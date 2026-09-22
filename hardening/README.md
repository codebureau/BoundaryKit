# Hardening artifacts

Reviewable, reversible artifacts for the OS/browser hardening half of BoundaryKit (see
CLAUDE.md's "Big picture" and the Windows/Browser Hardening Plan sections of the
top-level [README.md](../README.md)). Nothing here is ever applied to the machine it's
authored on - these are exported policy/scripts for Matt to run on the target PC.

## Directory convention

```
hardening/
  README.md          <- this file
  gpo/                <- Local Group Policy (issue #22, gpedit.msc-level settings)
  applocker/          <- AppLocker (exe/msi/script default-deny + allow-lists) [step 6]
  smart-app-control/  <- Smart App Control strict + reputation config [step 4]
  edge/               <- Edge policy hardening (JSON policies)              [step 7]
```

One subdirectory per MVP1 critical-path control cluster
([docs/adr/0001](../docs/adr/0001-mvp1-scope-and-critical-path.md)), matching that
ADR's "one parent GitHub issue per cluster" issue-granularity decision. Each
subdirectory is expected to be self-contained and follow roughly the same internal
shape established here by `gpo/` (adjust as each control's actual mechanism demands -
this is a starting convention, not a rigid template):

- `README.md` - what each setting does, why, how to verify it, and its rollback story.
- An apply script (and an undo/rollback script, or a documented manual undo if the
  control's own tooling already provides one - e.g. AppLocker's audit-mode-first
  workflow from ADR 0001).
- Any settings data (declarative catalog, exported policy, JSON) the apply script
  reads, kept separate from the script logic so the doc can be generated from - or at
  least cross-checked against - the same source the script uses, rather than the two
  silently drifting apart.
- A `tests/` folder for whatever can be verified without touching a real machine
  (structural/round-trip tests, dry runs against a scratch directory) - see `gpo/tests/`
  for the pattern this pass used.

## Why this shape

- **No layout existed before this pass** - CLAUDE.md flagged it as an open Architect
  decision, not yet made. This pass (Local GPO lockdown, issue #22) needed one, and
  three other Developer passes (Smart App Control, AppLocker, Edge policy) were
  reported to be running concurrently in separate worktrees with no way to coordinate
  live. Checked `git log`/branches for any convention one of them might have already
  committed - none had (all sibling worktrees were still at the same base commit as
  this one when checked). So this is a proposed, not negotiated, convention.
- **Top-level `hardening/`, not nested under `docs/` or `src/`** - these are operational
  artifacts to run on a specific machine, not documentation and not (yet) part of a
  buildable solution; giving them their own top-level root keeps that distinction
  visible and leaves room for the future `.NET` solution to get its own root
  (`src/` or similar) without the two colliding.
- **One subdirectory per critical-path cluster**, named to match ADR 0001's own
  cluster names (`gpo`, `applocker`, `smart-app-control`, `edge`) rather than per
  individual setting/sub-issue - composes directly with however each sibling pass
  chose to structure its own subdirectory's internals, since this only commits to the
  top-level split, not to what's inside `applocker/` or `edge/`.
- **This is a judgment call, not a ratified decision.** CLAUDE.md is explicit that
  layout decisions belong to an Architect pass and should be recorded as an ADR. This
  Developer pass made a reasonable choice under instruction to do so (see the task
  that produced `gpo/`) because no Architect pass had run yet and blocking on one
  wasn't an option. **Once the concurrent Smart App Control/AppLocker/Edge passes have
  landed, Matt or an Architect pass should look at all four together, confirm or
  adjust this convention, and record it as an ADR** - if a sibling pass picked a
  meaningfully different shape, reconciling that is better done by looking at the
  real, competing options side by side than by this pass guessing at what they chose.

See [`gpo/README.md`](gpo/README.md) for the Local GPO lockdown itself.
