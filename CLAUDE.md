# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

BoundaryKit is a clean rebuild of a Windows 11 PC used by a minor: a locked-down OS and browser, plus a custom C#/.NET monitoring tool. It is also a collaborative learning project with the child — framed as joint engineering, not punishment. [README.md](README.md) is the design document and working notebook; read it before making design decisions.

**Current state: docs only.** There is no code, solution, build, lint or test setup yet. Don't invent commands — when the .NET solution is created, add the real build/test/single-test commands to this file in the same change.

## Big picture

Two workstreams that must stay consistent with each other:

1. **Hardening (configuration, not code)** — Local Group Policy, AppLocker, Smart App Control, and Edge policies, applied to a Windows 11 Pro machine with a Microsoft-account admin (parent) and a local non-admin (child). The blocked set (`.exe`, `.msi`, `.zip`, `.bat`, `.cmd`, `.ps1`) is defined once in the README; policy rules and the monitor's detection list must match it.
2. **Monitoring tool (C#/.NET)** — watches download directories with `FileSystemWatcher`, plus EventLog watchers (ETW optional), and writes JSON logs. Later phases add Windows Event Log output, quarantine/blocking, hash/signature checks, a WPF/WinUI dashboard, and Windows Service mode. Phases are ordered in the README: watcher → logging → blocking/quarantine → dashboard → hardening → child-assisted testing.

Hardening is the primary control; the monitor is the detective/backstop layer. A restriction that only the monitor enforces is a weaker design than one the OS enforces — call that out when proposing one.

## Rules specific to this project

- **Never apply policy changes to the machine you are running on.** No `gpedit`/`secedit`/`LGPO`, AppLocker, registry, Defender, Edge-policy, or account changes on the dev box. Express them as reviewable, reversible artifacts in the repo (exported policy, `.reg`/PowerShell scripts, JSON policy files) and let Matt apply them on the target PC.
- **Every restriction needs a documented rollback and must leave the parent admin account able to undo it.** Lockout risk is the main way this project can go wrong (disabling PowerShell/CMD/Registry Editor/Task Manager, AppLocker default-deny rules). Prefer audit-mode/test rollout before enforcement.
- **Code is read by a learner.** Prefer plain, well-named C# over clever abstractions; the secondary goal is teaching (event-driven programming, Windows internals, threat modelling).
- **Significant design/policy/architecture decisions are ADRs in [`docs/adr/`](docs/adr/)** — `NNNN-title.md`, Context/Decision/Consequences, lighter-weight than a full spec (see [`docs/adr/0001-mvp1-scope-and-critical-path.md`](docs/adr/0001-mvp1-scope-and-critical-path.md) for the format and the current MVP1 scope). The README's "Notes & Decisions" section is only for lighter running notes that don't warrant a full ADR — testing results, issues found, improvements made.
- No directory layout for scripts/policies/source has been chosen yet. The first Architect pass should decide one and record it as an ADR.

## Git workflow

- Work on a feature branch (`feature/<slug>` or `issue-<n>-<slug>`) off the latest `main`; every change lands via a PR. Never commit or push directly to `main`.
- **Claude never merges a PR** — merging is always Matt's action, even if he says a PR is approved. Open the PR, summarise, stop.
- No force-push to `main`, no `--no-verify`. `.claude/settings.json` denies these and `gh pr merge`.
- Prefer new commits over amending.

## Multi-agent roles

Work is split into four role agents in [.claude/agents/](.claude/agents/): `product-manager` (backlog: turns the README's checklist/phases into GitHub issues, scope, priority — no code), `architect` (design, threat model, decision log — no source edits), `developer` (implements; hard-stops before git), and `tester` (independently verifies a draft PR — no source edits).

- **Only invoke a role when Matt asks for it.** You may suggest that a pass looks warranted; never spin one up unannounced, and roles never invoke each other.
- Developer/Architect/Tester passes are launched with the Agent tool's `isolation: "worktree"`. Claude provisions the worktree; the role agent works inside it and doesn't create its own. After the branch merges, Claude fast-forwards `main` and removes the worktree and local branch. Product Manager doesn't need one — it works against GitHub issues and small README-checklist edits directly.
- Reports come in two messages: the substantive report (what was built/decided/verified, with real command output) *before* any commit/PR/ready/issue-creation action, then a short confirmation message afterwards.
- Developer and Tester reports always include copy-pasteable manual-test steps for Matt.
- A Tester pass is never a substitute for Matt's review.
- Product Manager labels issues `type:` (`feature`/`task`/`bug`/`chore`/`docs`) and `area:` (`os-hardening`/`browser`/`monitor`/`account`/`testing`), plus `needs-design` to flag a task for an Architect pass before Developer starts.
