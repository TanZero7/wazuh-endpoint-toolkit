# File Integrity Monitoring — Integration Guide

> Desktop + Downloads, realtime, all user profiles — the trigger event for VirusTotal and YARA.

| | |
|---|---|
| **Wazuh** | 4.x agent (FIM ships with every agent — this just adds scope) |
| **Endpoint** | Windows 10/11 |
| **Mode** | realtime (ReadDirectoryChangesW), not whodata |
| **Verified** | 11 September 2026 — 550/554/553 all confirmed firing within 1-2 seconds of a real change |

## 1. Requirements

| Requirement | Why | Check |
|---|---|---|
| Administrator rights | Editing `ossec.conf` | `net session` |
| Wazuh agent already enrolled | This kit only adds scope | `Get-Service WazuhSvc` |

## 2. Install

### Endpoint

```powershell
cd fim
powershell -ExecutionPolicy Bypass -File .\scripts\install-fim-scope.ps1
```

Merges into the agent's **existing** `<syscheck>` block (every Windows Wazuh
agent ships with one by default — system directories, registry monitoring,
`synchronization`, `max_eps`, etc.) rather than adding a second, separate
block:
```xml
<directories check_all="yes" realtime="yes">C:\Users\*\Desktop</directories>
<directories check_all="yes" realtime="yes">C:\Users\*\Downloads</directories>
<alert_new_files>yes</alert_new_files>
<ignore type="sregex">\.tmp$|\.temp$|\.crdownload$|\.part$|\.partial$|\.~lock|desktop\.ini$|thumbs\.db$</ignore>
```
each piece added individually and idempotently (safe to re-run), then
restarts the agent, which triggers a fresh baseline scan.

> **Why merge instead of add a new block?** An earlier version of this
> script only checked whether the Desktop path already appeared anywhere in
> `ossec.conf`; if not, it inserted a brand-new `<syscheck>...</syscheck>`
> block right before `</ossec_config>`. Since every real machine already has
> its own default `<syscheck>` block, that produced **two** `<syscheck>`
> blocks — undefined/duplicated FIM behavior. Confirmed on a live endpoint
> during deployment and fixed: the script now finds the one existing
> `<syscheck>` block and edits into it, and refuses to run at all (rather
> than guessing) if it can't find a complete one.

> **Rolling this out to more than one machine?** Put this same `<syscheck>`
> block in the Wazuh group's `agent.conf` on the manager instead of editing
> every endpoint's local `ossec.conf` — one central place, pushed
> automatically. That's how this integration is actually run centrally on
> the production deployment; the local-`ossec.conf` script here is for a single
> machine or a first test.

### No-event-loss step (important for a real deployment)

`Run-Setup.cmd` also runs `scripts\set-no-event-loss.ps1`, which **disables
the agent's anti-flooding buffer**. By default the agent caps outgoing events
at 500/sec (max 1000) and silently *drops* anything above the cap — in production this was measured dropping **1,250 Suricata DNS/TLS events** on a
single endpoint. For a SOC that cannot miss logs, the buffer is turned off so
every event ships as generated.

Two things to know:
- This is a `<client_buffer>` setting that lives in the agent's **local
  `ossec.conf`**, not the manager's shared `agent.conf`, so it is **not
  pushed centrally** — it must be set per-agent. When you build the office
  installer, bake `<client_buffer><disabled>yes</disabled></client_buffer>`
  into the base `ossec.conf` it ships, so every enrolled machine has it from
  first boot.
- Trade-off: with anti-flooding off there is no per-agent rate limit shielding
  the manager from a runaway agent. On a large fleet, watch manager
  ingestion; if one endpoint ever floods, re-enable *that one* with a high cap
  (`events_per_second 1000`, `queue_size 100000`) via
  `set-no-event-loss.ps1 -Revert` then hand-edit, rather than accepting drops
  fleet-wide.

Verify no drops afterwards:
```powershell
$s = 'C:\Program Files (x86)\ossec-agent\wazuh-logcollector.state'
(Get-Content $s -Raw | ConvertFrom-Json).global.files |
  ForEach-Object { "{0}  drops={1}" -f $_.location, (($_.targets|Measure-Object drops -Sum).Sum) }
```
Every source should read `drops=0`.

### Server (optional — verification only)

> These files live in the `fim/` folder of the companion
> [wazuh-manager-toolkit](https://github.com/TanZero7/wazuh-manager-toolkit) repo.

```bash
cd wazuh-manager-toolkit/fim
sudo bash check-fim-rules.sh
```

There is nothing to *install* server-side — rules 550/553/554 and the rest
of the FIM alerting path ship with every Wazuh manager. This script exists
so you can confirm that's actually true on your install (a stripped-down or
heavily customized ruleset is the only case where it wouldn't be) rather
than just assuming it, the same way the vulnerability-detection check in the
manager toolkit verifies its own built-in capability.

## 3. Verification

```
Run-Verify.cmd
```

### Live test
```powershell
"test" | Set-Content "$env:USERPROFILE\Desktop\fimtest.txt"    # rule 554 (added)
"test2" | Add-Content "$env:USERPROFILE\Desktop\fimtest.txt"   # rule 550 (modified)
Remove-Item "$env:USERPROFILE\Desktop\fimtest.txt"              # rule 553 (deleted)
```
Each should appear as a Wazuh alert within 1-2 seconds.

## 4. A real gotcha found building this

**`whodata` was tried first and dropped.** It sets a SACL on every path the
wildcard `C:\Users\*\...` expands to — including Windows service/virtual
profiles that exist on real machines (`TEMP.Font Driver Host`, `UMFD-0`,
etc., not just real user accounts). On a real deployment this stretched the
first-run FIM baseline scan from ~1 minute to over 2.5 minutes, for zero
detection benefit on those synthetic profiles. `realtime` gives the same
add/modify/delete detection without that cost. If you need "who changed
this file" attribution specifically, get it from Sysmon (Event ID 11, file
create) instead of paying the whodata cost here — see the Sysmon kit.

## 5. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No alerts after a real file change | Realtime engine not up yet (baseline scan still running) | Check `ossec.log` for "Real-time file integrity monitoring started"; can take 1-3 min on first run |
| Baseline scan takes a very long time | whodata was manually re-enabled, or a huge number of files/profiles | Switch back to plain `realtime` |
| New files don't alert, only modifications do | `alert_new_files` missing or set to `no` | Confirm it's `yes` in the block above (default agent config has it off) |
| Script throws `No existing <syscheck> block found. Refusing to create a new one.` | `ossec.conf` genuinely has no `<syscheck>` block at all (unusual — every stock Windows agent ships one) | Add a minimal `<syscheck><disabled>no</disabled></syscheck>` block by hand first, then re-run the script |
| Script throws while copy/pasting it into a `.ps1` file (`Unexpected attribute 'CmdletBinding'` / `Unexpected token 'param'`) | Extra text (markdown fences, chat text) got pasted in ahead of the actual script | Open the file and make sure `[CmdletBinding()]` is the literal first line, nothing before it |
| `verify.ps1` shows `[FAIL]` right after setup finishes | The checks read `wazuh-logcollector.state` / `ossec.log`, which only catch up a few minutes after the agent restarts — not a real problem | Wait about 10 minutes and run `verify.ps1` again before troubleshooting further |
