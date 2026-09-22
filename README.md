# Project Overview

A clean rebuild of a Windows PC used by a minor, with the goal of creating a stable, predictable, secure environment. The project includes:

- Reinstalling Windows
- Creating a safe account structure
- Hardening the OS
- Hardening the browser
- Implementing download controls
- Building a custom monitoring tool
- Creating a collaborative learning experience

This notebook is the working document for designing, implementing, and testing the system.

## Goals

### Primary Goals

- Clean, stable Windows installation
- Predictable behaviour
- Reliable time limits and usage boundaries
- Blocking or reporting downloads of `.exe`, `.msi`, `.zip`, `.bat`, `.cmd`, `.ps1`
- Browser hardening
- Preventing installation of unauthorised software
- Preventing bypasses of parental controls
- Logging and monitoring of key events

### Secondary Goals

- Turn the rebuild into a collaborative engineering project
- Teach security fundamentals
- Teach Windows internals
- Teach responsible computing
- Build trust and autonomy

## System Architecture

### Account Structure

- Parent account: Microsoft account, Administrator
- Child account: Local account (non-admin)
- Optional: Add child to Family Safety after hardening
- No additional accounts allowed
- No password changes allowed by child
- No Microsoft Store access

### OS Baseline

- Windows 11 clean install
- Latest updates applied
- Drivers installed
- No OEM bloatware
- No preinstalled third-party apps
- No additional browsers installed (Edge only)

## Windows Hardening Plan

### Local Group Policy (`gpedit.msc`)

Implement policies to disable:

- CMD
- PowerShell
- Registry Editor
- Task Manager
- Control Panel
- Settings pages (selectively)
- USB storage
- Microsoft Store
- Running unknown apps
- Installing software
- Changing time/date
- Adding/removing accounts

### AppLocker (Windows 11 Pro)

- Block all `.exe` except whitelisted apps
- Block all `.msi` installers
- Block scripts (`.ps1`, `.vbs`, `.bat`, `.cmd`)
- Allow only approved folders
- Allow only approved publishers

### Smart App Control

- Set to Strict
- Enable reputation-based protection
- Block untrusted downloads
- Block potentially unwanted apps

## Browser Hardening Plan

### Edge Policies

Configure via Group Policy or registry:

- Disable downloads
- Disable developer tools
- Disable extensions
- Disable InPrivate mode
- Force SafeSearch
- Block specific URLs (TikTok, YouTube, Discord, etc.)
- Block executable downloads
- Force Family Safety mode
- Disable profile switching
- Disable sign-in to Edge

### Allowed Websites

- Define a whitelist
- Block everything else
- Optional: allow educational sites only

## Monitoring & Logging System

### Goals

Build a lightweight monitoring tool that:

- Watches download directories
- Detects `.exe`, `.msi`, `.zip`, `.bat`, `.cmd`, `.ps1`
- Logs events
- Optionally blocks or quarantines files
- Provides a simple dashboard
- Teaches event-driven programming

### Architecture

- Language: C# (.NET)
- Components:
  - `FileSystemWatcher`
  - EventLog watchers
  - Optional ETW (Event Tracing for Windows)
  - JSON log output
  - Optional UI (WPF or WinUI)
  - Optional service mode (Windows Service)

### Features

- Real-time detection
- Logging to file
- Logging to event viewer
- Optional email or webhook alerts
- Optional quarantine folder
- Optional hash checking
- Optional signature checking

### Development Plan

- Phase 1: Basic watcher
- Phase 2: Logging
- Phase 3: Blocking/quarantine
- Phase 4: Dashboard
- Phase 5: Hardening
- Phase 6: Child-assisted testing

## Collaborative Learning Plan

### Framing

This is a joint engineering project, not a punishment.

### Learning Modules

- Windows internals
- File system events
- Security fundamentals
- Threat modelling
- Logging and monitoring
- UI design
- Testing and debugging
- Hardening techniques

### Activities

- Build the watcher together
- Test bypass attempts
- Improve detection logic
- Add features
- Document findings
- Create a “security report”
- Celebrate improvements

## Implementation Checklist

A step-by-step checklist for the rebuild:

1. Reinstall Windows
2. Create parent admin account
3. Create child local account
4. Apply Windows updates
5. Install drivers
6. Apply Group Policy restrictions
7. Configure AppLocker
8. Configure Smart App Control
9. Harden Edge
10. Disable Store
11. Disable USB storage
12. Configure Family Safety (optional)
13. Install monitoring tool
14. Test restrictions
15. Document results
16. Begin collaborative development

## Testing Plan

### Test Categories

- Browser restrictions
- Download blocking
- AppLocker enforcement
- Script blocking
- Account restrictions
- Time limits
- Monitoring tool detection
- Attempted bypasses

### Child-involved Testing

He attempts:

- Downloading `.exe`
- Installing apps
- Running scripts
- Changing settings
- Using alternative browsers
- Using USB drives
- Using portable apps

He then helps fix the weaknesses.

## Future Extensions

- Network-level filtering (Pi-hole, AdGuard Home)
- DNS-based blocking
- Router-level time limits
- Windows Defender custom rules
- Custom browser extension
- Full zero-trust model
- Exportable logs
- Cloud dashboard
- Machine learning anomaly detection (optional fun)

## Notes & Decisions

Significant design/policy/architecture decisions live as ADRs in [`docs/adr/`](docs/adr/), not here — see [`docs/adr/0001-mvp1-scope-and-critical-path.md`](docs/adr/0001-mvp1-scope-and-critical-path.md) for the MVP1 threat model, critical path, and scope boundaries.

This section is for lighter running notes that don't warrant a full ADR:

- Testing results
- Issues found
- Improvements made
- Future ideas

## Appendix

- Useful commands
- Useful registry keys
- Useful Group Policy paths
- AppLocker rule examples
- C# code snippets
- ETW provider references
- Browser policy JSON examples
