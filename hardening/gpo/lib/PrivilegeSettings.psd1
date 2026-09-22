# PrivilegeSettings.psd1
#
# User Rights Assignment changes (Computer Configuration > Windows Settings >
# Security Settings > Local Policies > User Rights Assignment in secpol.msc /
# gpedit.msc). These are NOT Registry.pol/Administrative Template settings - they are
# applied via secedit.exe against a security template (.inf), which is the native,
# built-in Windows mechanism for this category (no external tool needed).
#
# Privilege assignment is inherently machine-wide (there is no per-user-group
# "Non-Administrators only" container for security policy the way there is for
# Registry.pol). The parent admin is still exempted here, but through group
# membership rather than scope: removing a SID from a privilege's holder list only
# removes rights from accounts that get the privilege *solely* through that SID.
# The parent keeps every privilege below via their Administrators (S-1-5-32-544)
# membership, which is never touched.
#
# Schema:
#   Id            short stable id
#   Issue         the GitHub sub-issue this implements
#   Privilege     the constant name (e.g. SeTimeZonePrivilege) as secedit/GptTmpl.inf uses it
#   DisplayName   human name as shown in secpol.msc
#   RemoveSids    well-known SIDs to remove from the privilege's holder list, IF PRESENT
#   KeepSids      well-known SIDs Apply-GpoLockdown.ps1 must confirm remain untouched
#                 (sanity check, not something it adds - the script errors out rather
#                 than proceeding if one of these would be dropped)
#   Why / Verify / Confidence   see GpoSettings.psd1 for meaning

@{
    Settings = @(
        @{
            Id          = 'GPO-28b'
            Issue       = 28
            Privilege   = 'SeTimeZonePrivilege'
            DisplayName = 'Change the time zone'
            RemoveSids  = @('S-1-5-32-545')   # Users (non-admins) - granted by default
            KeepSids    = @('S-1-5-32-544', 'S-1-5-19')  # Administrators, LOCAL SERVICE
            Why         = @'
Windows grants "Change the time zone" to the built-in Users group by default, so any
standard account - including the child's - can normally do this without elevation.
Removing Users (S-1-5-32-545) closes that; Administrators and LOCAL SERVICE keep the
right untouched, since only the SID being removed is edited.
'@
            Verify      = 'As the child account, try Settings > Time & language > Date & time > Time zone. Expect the control to be greyed out / an access-denied error. As the parent admin, it should work normally.'
            Confidence  = 'High - SeTimeZonePrivilege''s default holder list (Administrators, LOCAL SERVICE, Users) is documented and was corroborated by independent references in this pass; the script still reads the machine''s actual current holder list before editing rather than assuming this default (see Apply-GpoLockdown.ps1 -> Set-PrivilegeRestrictions).'
        }
        @{
            Id          = 'GPO-28c'
            Issue       = 28
            Privilege   = 'SeSystemtimePrivilege'
            DisplayName = 'Change the system time'
            RemoveSids  = @('S-1-5-32-545')   # only removed if actually present (see Why)
            KeepSids    = @('S-1-5-32-544', 'S-1-5-19')
            Why         = @'
Modern Windows 10/11 clean installs typically do NOT grant "Change the system time" to
the Users group by default (only Administrators and LOCAL SERVICE) - unlike the time
zone privilege above. This entry is included for completeness/defense-in-depth and is
a no-op on a stock Windows 11 install. The apply script checks the machine's actual
current holder list first and only removes Users if it is actually present, rather
than assuming a default that may already be correct - avoids an unnecessary change on
a setting that likely doesn't need one.
'@
            Verify      = 'As the child account, try to manually set the system clock (not just time zone) via Settings > Time & language > Date & time (turn off "Set time automatically" first, if needed to see the Change button). Expect it to be blocked/require admin credentials.'
            Confidence  = 'Medium - default holder list for this privilege varies by Windows version/edition; verify against the actual machine''s exported security template before assuming Users is present to remove.'
        }
    )
}
