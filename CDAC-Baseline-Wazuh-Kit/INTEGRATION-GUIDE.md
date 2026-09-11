# CDAC Security Baseline — Wazuh SCA Integration Guide

> Deploying a custom Security Configuration Assessment policy for the CDAC 30-control baseline.

| | |
|---|---|
| **Wazuh** | 4.x agent (SCA module ships with every agent, no manager change needed) |
| **Endpoint** | Windows 10/11 |
| **Policy ID** | `cdac_win_baseline` |
| **Checks** | 21 automated (IDs 400001-400030, with gaps for skipped manual controls) |
| **Verified** | 11 September 2026, score 60% (18 pass / 12 fail) on a non-domain-joined dev workstation — the fails are real gaps, not policy bugs |

## 1. Overview

Wazuh's SCA module can load any number of custom policies alongside its
built-in CIS benchmarks. This kit adds one more: a direct implementation of
CDAC's own 30-control baseline document, so the same dashboard that shows
CIS compliance also shows CDAC compliance, scored the same way.

## 2. Requirements

| Requirement | Why | Check |
|---|---|---|
| Administrator rights | Editing `ossec.conf`, `local_internal_options.conf` | `net session` |
| Wazuh agent already enrolled | This kit only adds a policy, not the agent | `Get-Service WazuhSvc` |

## 3. Install

```powershell
cd CDAC-Baseline-Wazuh-Kit\endpoint
powershell -ExecutionPolicy Bypass -File .\scripts\install-baseline-policy.ps1
```

This: copies `cdac_win_baseline.yml` to `ruleset\sca\`, sets
`sca.remote_commands=1` in `local_internal_options.conf` (required — about
half the checks run a command like `net accounts` or a `Get-*` PowerShell
cmdlet, and Wazuh disables remotely-pushed command checks by default as a
safety measure), adds an `<sca><policies>` block to `ossec.conf`, and
restarts the agent.

### Server (optional — verification only)

```bash
cd server
sudo bash check-sca-rules.sh
```

There is nothing to *install* server-side — the policy itself is entirely
agent-side, and turning its results into dashboard alerts (a summary alert
plus one alert per check) uses Wazuh's built-in SCA ruleset, which ships
with every manager. This script confirms that's true on your install.

## 4. What's automated vs. manual

| Control | Automated? | Notes |
|---|---|---|
| 1 Password Policy | yes (3 checks: length, history, complexity) | |
| 2 Password Rotation | yes | same data as max-age |
| 3 Account Lockout | yes (2 checks: threshold, duration) | |
| 4 Administrative Access | yes (2 checks: Guest disabled, no broad principals in Administrators) | full membership list still needs human review against your approved register |
| 5 User Naming Convention | manual | no way to know your naming standard remotely |
| 6 BitLocker | yes | |
| 7 Secure Boot | yes (Secure Boot only) | BIOS password is not remotely readable |
| 8 Defender + Firewall | yes (2 checks) | |
| 9 System Restore | yes | |
| 10 OS Licensing | yes | |
| 11 Services/features | yes (Telnet, TFTP) | |
| 12 Scheduled Tasks | manual | "only approved" needs an approved-list comparison |
| 13 RDP / WinRM | yes (2 checks) | |
| 14 NTP | yes | checks for `samay1.nic.in` specifically |
| 15 SMB Hardening | yes (2 checks: SMBv1, signing) | |
| 16 SSH Hardening | yes | only meaningful if OpenSSH server is installed |
| 17 Certificate Management | manual | lifecycle process, not a point-in-time check |
| 18 SNMP | yes | |
| 19 IP Forwarding | yes | |
| 20 Listening Ports | manual | needs an approved-ports list |
| 21 Advanced Audit Policy | yes | 5 subcategories combined into one check |
| 22 Auth Failure Logging | yes | |
| 23 Centralized Log Forwarding | yes | checks the Wazuh agent itself is installed+running |
| 24 Log Retention | yes (proxy check) | checks local Security log is sized generously; **actual 90-day retention is a SIEM-side setting** — see the Log-Retention-Wazuh-Kit in this family |
| 25 Software Inventory | yes (proxy check) | confirms syscollector is enabled; "remove unsupported software" itself is a process |
| 26 Shared Folder Permissions | manual | least-privilege review needs human judgment |
| 27 AD Membership | yes | |
| 28 Group Policy Compliance | manual | requires a domain to even evaluate |
| 29 Hostname Naming Convention | manual | |
| 30 New System Issuance | manual | procedural, happens before the machine is even on the network |

## 5. Verification

```
endpoint\Run-Verify.cmd
```

Then check the dashboard: **Agents -> (agent) -> SCA** tab. Expect a score and
a full pass/fail/not-applicable breakdown against "CDAC Security Baseline
for Desktops/Laptops".

## 6. Rolling this out to more than one machine

Don't repeat `install-baseline-policy.ps1` by hand on every endpoint.
Instead:

1. Push `config/cdac_win_baseline.yml` to `ruleset/sca/` on each agent as
   part of your installer/imaging process (or copy it once into a Wazuh
   group's `etc/shared/<group>/` folder — same effect, centrally managed).
2. Add the `<sca><policies>` block to that group's `agent.conf` on the
   manager instead of each agent's local `ossec.conf`.
3. Set `sca.remote_commands=1` in the baseline image / installer so every
   new machine has it from day one.

## 7. A real debugging note worth keeping

Several checks (BitLocker, Defender real-time protection, System Restore,
SMBv1, SMB signing, Security event-log sizing) initially came back
**"not applicable"** instead of a real pass/fail — not because those
controls weren't real, but because a raw `not r:<registry path>` rule
reports "not applicable" (not "pass") when the whole registry *path*
doesn't exist, which is common for settings that are only ever set when
someone has explicitly configured them one way. Rewriting those specific
checks to run an actual `Get-BitLockerVolume` / `Get-MpComputerStatus` /
`Get-SmbServerConfiguration` PowerShell command instead of a bare registry
lookup fixed all six — confirmed by checking the real state of each control
on the test machine first (`docs/CDAC-Baseline-PoC.md` has the ground-truth
numbers), then verifying the check now matches reality. **If you extend
this policy with more registry-based checks, prefer a real command over a
"file/key doesn't exist = compliant" assumption** — it's the difference
between a false "not applicable" and a real answer.

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| SCA tab shows no CDAC policy at all | Policy not loaded, or ossec.conf edit missing | Check `ossec.log` for "Loaded policy...cdac_win_baseline" |
| All command-based checks show "not applicable" | `sca.remote_commands` not set (or agent not restarted after setting it) | Re-run `install-baseline-policy.ps1`; confirm the setting in `local_internal_options.conf` and restart `WazuhSvc` |
| A check you'd expect to pass shows "not applicable" | The underlying registry path genuinely doesn't exist on this Windows build/edition | Verify manually first (see section 7's approach) before assuming the check is wrong |
