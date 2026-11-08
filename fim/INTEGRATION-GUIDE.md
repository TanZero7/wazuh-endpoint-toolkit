# FIM (File Integrity Monitoring): Endpoint Integration Guide

> Desktop + Downloads, realtime, all user profiles. The trigger event for VirusTotal and YARA.

> **Install order: manager first, then endpoint, then verify**
>
> 1. **Manager side**: [wazuh-manager-toolkit → fim](https://github.com/TanZero7/wazuh-manager-toolkit/tree/main/fim).
>    Nothing to install there, just a quick check that Wazuh's built-in FIM rules are present.
> 2. **Endpoint side**: this guide, [section 2](#2-install-endpoint).
> 3. **Verify**: this guide, [section 3](#3-verification). Only after steps 1 and 2 are done.

| | |
|---|---|
| **Wazuh** | 4.x agent (FIM ships with every agent; this just adds scope) |
| **Endpoint** | Windows 10/11 |
| **Mode** | realtime (ReadDirectoryChangesW), not whodata |
| **Verified** | 11 September 2026: 550/554/553 all confirmed firing within 1-2 seconds of a real change |

## 1. Requirements

| Requirement | Why | Check |
|---|---|---|
| Manager side done | Confirms the alerting rules exist before you rely on them | [wazuh-manager-toolkit → fim](https://github.com/TanZero7/wazuh-manager-toolkit/tree/main/fim) |
| Administrator rights | Editing `ossec.conf` | `net session` |
| Wazuh agent already enrolled | This kit only adds scope | `Get-Service WazuhSvc` |

## 2. Install (endpoint)

Open **Command Prompt as Administrator** and run, one line at a time:

```bat
cd fim
powershell -ExecutionPolicy Bypass -File .\scripts\install-fim-scope.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\set-no-event-loss.ps1
```

(`Run-Setup.cmd` runs the same two scripts plus the check in section 3.1.)

### What `install-fim-scope.ps1` does

Merges into the agent's **existing** `<syscheck>` block (every Windows Wazuh
agent ships with one by default: system directories, registry monitoring,
`synchronization`, `max_eps`, etc.) rather than adding a second, separate
block:
```xml
<directories check_all="yes" realtime="yes">C:\Users\*\Desktop</directories>
<directories check_all="yes" realtime="yes">C:\Users\*\Downloads</directories>
<alert_new_files>yes</alert_new_files>
<ignore type="sregex">\.tmp$|\.temp$|\.crdownload$|\.part$|\.partial$|\.~lock|desktop\.ini$|thumbs\.db$</ignore>
```
Each piece is added individually and idempotently (safe to re-run), then the
agent restarts, which triggers a fresh baseline scan.

> **Why merge instead of add a new block?** An earlier version of this
> script only checked whether the Desktop path already appeared anywhere in
> `ossec.conf`; if not, it inserted a brand-new `<syscheck>...</syscheck>`
> block right before `</ossec_config>`. Since every real machine already has
> its own default `<syscheck>` block, that produced **two** `<syscheck>`
> blocks, which is undefined/duplicated FIM behavior. Confirmed on a live endpoint
> during deployment and fixed: the script now finds the one existing
> `<syscheck>` block and edits into it, and refuses to run at all (rather
> than guessing) if it can't find a complete one.

> **Rolling out to many machines?** The same scope can be pushed centrally from
> the manager instead. See
> [wazuh-manager-toolkit → fim](https://github.com/TanZero7/wazuh-manager-toolkit/tree/main/fim).

### What `set-no-event-loss.ps1` does (important for a real deployment)

It **disables the agent's anti-flooding buffer**. By default the agent caps
outgoing events at 500/sec (max 1000) and silently *drops* anything above the
cap. In production this was measured dropping **1,250 Suricata DNS/TLS events**
on a single endpoint. For a SOC that cannot miss logs, the buffer is turned off
so every event ships as generated.

Two things to know:
- This is a `<client_buffer>` setting that lives in the agent's **local
  `ossec.conf`**, not the manager's shared `agent.conf`, so it is **not
  pushed centrally**. It must be set per-agent. If you build an office
  installer, bake `<client_buffer><disabled>yes</disabled></client_buffer>`
  into the base `ossec.conf` it ships, so every enrolled machine has it from
  first boot.
- Trade-off: with anti-flooding off there is no per-agent rate limit shielding
  the manager from a runaway agent. On a large fleet, watch manager
  ingestion; if one endpoint ever floods, re-enable *that one* with a high cap
  (`events_per_second 1000`, `queue_size 100000`) via
  `set-no-event-loss.ps1 -Revert` then hand-edit, rather than accepting drops
  fleet-wide.

## 3. Verification

### 3.1 Confirm the install (PASS / FAIL)

Before testing anything, confirm the install is healthy:

```bat
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
```

A good install looks like this, ending in **"All checks passed."**:

```
==> VERDICT
    [PASS] ossec.conf has the FIM scope
    [PASS] Realtime engine started (recent log)  ... Real-time file integrity monitoring started
    [PASS] Agent confirms watching a Desktop path
```

> ⏳ **If any line shows `[FAIL]`, don't troubleshoot yet.** Wait **5–10 minutes
> after installation**, then run `verify.ps1` again. The agent restarts during
> install and runs a fresh baseline scan, and these checks read `ossec.log`,
> which only shows the "realtime started" lines once that scan finishes. Only
> treat it as broken if it still fails after the wait.

Also confirm no events are being dropped:
```powershell
$s = 'C:\Program Files (x86)\ossec-agent\wazuh-logcollector.state'
(Get-Content $s -Raw | ConvertFrom-Json).global.files |
  ForEach-Object { "{0}  drops={1}" -f $_.location, (($_.targets|Measure-Object drops -Sum).Sum) }
```
Every source should read `drops=0`.

### 3.2 Live test

Only once 3.1 shows all `[PASS]`:

```powershell
"test" | Set-Content "$env:USERPROFILE\Desktop\fimtest.txt"    # rule 554 (added)
"test2" | Add-Content "$env:USERPROFILE\Desktop\fimtest.txt"   # rule 550 (modified)
Remove-Item "$env:USERPROFILE\Desktop\fimtest.txt"              # rule 553 (deleted)
```

In the Wazuh dashboard (**Threat Hunting**, index `wazuh-alerts-*`), search
`rule.groups:syscheck`. Each change should appear as an alert within 1–2 seconds
(set the dashboard to auto-refresh every 5–10 s; it doesn't by default).

| Result | Meaning |
|---|---|
| **PASS**: 554, 550 and 553 all appear | FIM is fully working |
| **FAIL**: nothing appears | Wait 5–10 minutes after installation and repeat the test. The realtime engine only starts after the first baseline scan. Then see section 5. |

## 4. A real gotcha found building this

**`whodata` was tried first and dropped.** It sets a SACL on every path the
wildcard `C:\Users\*\...` expands to, including Windows service/virtual
profiles that exist on real machines (`TEMP.Font Driver Host`, `UMFD-0`,
etc., not just real user accounts). On a real deployment this stretched the
first-run FIM baseline scan from ~1 minute to over 2.5 minutes, for zero
detection benefit on those synthetic profiles. `realtime` gives the same
add/modify/delete detection without that cost. If you need "who changed
this file" attribution specifically, get it from [Sysmon](../sysmon) (Event ID 11,
file create) instead of paying the whodata cost here.

## 5. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `verify.ps1` shows `[FAIL]` right after setup | The checks read `ossec.log`, which only catches up once the agent has restarted and finished its baseline scan | Wait 5–10 minutes and run `verify.ps1` again before troubleshooting further |
| No alerts after a real file change | Realtime engine not up yet (baseline scan still running) | Check `ossec.log` for "Real-time file integrity monitoring started"; can take 1-3 min on first run |
| Baseline scan takes a very long time | whodata was manually re-enabled, or a huge number of files/profiles | Switch back to plain `realtime` |
| New files don't alert, only modifications do | `alert_new_files` missing or set to `no` | Confirm it's `yes` in the block above (default agent config has it off) |
| Script throws `No existing <syscheck> block found. Refusing to create a new one.` | `ossec.conf` genuinely has no `<syscheck>` block at all (unusual: every stock Windows agent ships one) | Add a minimal `<syscheck><disabled>no</disabled></syscheck>` block by hand first, then re-run the script |
| Script throws while copy/pasting it into a `.ps1` file (`Unexpected attribute 'CmdletBinding'` / `Unexpected token 'param'`) | Extra text (markdown fences, chat text) got pasted in ahead of the actual script | Open the file and make sure `[CmdletBinding()]` is the literal first line, nothing before it |
| Alerts appear on the endpoint's `ossec.log` but never in the dashboard | Manager-side rules missing or customized | Run the manager check: [wazuh-manager-toolkit → fim](https://github.com/TanZero7/wazuh-manager-toolkit/tree/main/fim) |
