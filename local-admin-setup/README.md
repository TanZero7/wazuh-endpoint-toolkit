# Local Admin Setup (run this FIRST, before any other folder)

Pre-install step for every endpoint. Run it once per PC, before
installing the Wazuh agent or running anything else in this repo.

## What it does

1. Creates a local account named **`admin`** (or resets its password if
   it already exists) and makes it a local Administrator.
2. Removes every **other** local account from the Administrators group.
   Nothing is deleted or disabled — people keep their accounts and keep
   logging in exactly as before, they just lose admin rights.
3. Disables the built-in **Administrator** account (Windows' own default
   admin account, separate from the new `admin` one), even if it had
   been enabled.
4. Prints a summary table of who's an admin now, so you can confirm on
   screen before moving on.

It's ordered so a PC is never left with zero administrators: `admin` is
created/confirmed as an administrator in step 1, and only afterward does
it touch anyone else's admin rights.

## How to run it

On each PC: copy this `local-admin-setup` folder over (or the whole
repo), then double-click **`Run-Setup.cmd`**. It asks for
admin elevation (UAC prompt) automatically, then asks you to type a
password for the `admin` account (twice, to confirm — minimum 12
characters). The password is never written to disk or logged anywhere;
it only lives in memory for the few seconds the script needs it, so
**write it down somewhere safe yourself** — this account becomes the
only local admin on that machine.

## Confirm it worked (PASS / REVIEW)

Run **`Run-Verify.cmd`** (read-only, never asks for the password, safe to run any
time). It prints the Administrators group and every local account, then one verdict:

```
PASS: 'admin' is the only enabled local administrator; built-in Administrator is disabled.
```

| Result | Meaning |
|---|---|
| **PASS** line (green) | Done. Install the Wazuh agent next |
| **REVIEW NEEDED** (yellow) + reasons | Read the listed reason (`'admin' account is missing…`, `built-in Administrator account is still enabled`, `unexpected admin(s): …`) and re-run `Run-Setup.cmd` |

This step has no manager side and no waiting period: the result is immediate.

## Before you run this on every PC

Pilot it on one or two non-critical machines first. Confirm you can log
in as `admin` with the password you set, and that the regular user can
still log in as a standard user, before rolling it out further.

## If something goes wrong

Log in as `admin` — it's always created/enabled before anything else is
touched, so it's always available as a way back in. From there:

- To restore someone else's admin rights: Computer Management → Local
  Users and Groups → Groups → Administrators → Add, or
  `Add-LocalGroupMember -Group Administrators -Member <name>` in an
  elevated PowerShell.
- To re-enable the built-in Administrator account if you ever need it:
  `Enable-LocalUser -Name Administrator` in an elevated PowerShell.

## Notes

- This only touches **local** accounts — these are standalone/workgroup
  PCs, not domain-joined, so there's no Active Directory angle here.
- `admin`'s password is set to never expire, consistent with it being a
  shared IT/admin utility account rather than a personal login.
- Everyone's own account is left exactly as it was otherwise (same
  password, same files, same apps) — the only change is Administrator
  group membership.
