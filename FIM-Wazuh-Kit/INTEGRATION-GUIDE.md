# File Integrity Monitoring — Integration Guide

> Desktop + Downloads, realtime, all user profiles — the trigger event for VirusTotal, the offline hash blocklist, and YARA.

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
cd FIM-Wazuh-Kit\endpoint
powershell -ExecutionPolicy Bypass -File .\scripts\install-fim-scope.ps1
```

Adds:
```xml
<syscheck>
  <alert_new_files>yes</alert_new_files>
  <directories check_all="yes" realtime="yes">C:\Users\*\Desktop</directories>
  <directories check_all="yes" realtime="yes">C:\Users\*\Downloads</directories>
  <ignore type="sregex">\.tmp$|\.temp$|\.crdownload$|\.part$|\.partial$|\.~lock|desktop\.ini$|thumbs\.db$</ignore>
  <max_eps>100</max_eps>
</syscheck>
```

and restarts the agent, which triggers a fresh baseline scan.

> **Rolling this out to more than one machine?** Put this same `<syscheck>`
> block in the Wazuh group's `agent.conf` on the manager instead of editing
> every endpoint's local `ossec.conf` — one central place, pushed
> automatically. That's how this integration is actually run centrally on
> the WAZUH TOOLKIT build; the local-`ossec.conf` script here is for a single
> machine or a first test.

### No-event-loss step (important for a real deployment)

`Run-Setup.cmd` also runs `scripts\set-no-event-loss.ps1`, which **disables
the agent's anti-flooding buffer**. By default the agent caps outgoing events
at 500/sec (max 1000) and silently *drops* anything above the cap — on the
WAZUH TOOLKIT build this was measured dropping **1,250 Suricata DNS/TLS events** on a
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

```bash
cd server
sudo bash check-fim-rules.sh
```

There is nothing to *install* server-side — rules 550/553/554 and the rest
of the FIM alerting path ship with every Wazuh manager. This script exists
so you can confirm that's actually true on your install (a stripped-down or
heavily customized ruleset is the only case where it wouldn't be) rather
than just assuming it, the same way `Hash-Blocklist-Wazuh-Kit` and
`Vulnerability-Detection-Wazuh-Kit` in this family verify their own
built-in capabilities.

## 3. Verification

```
endpoint\Run-Verify.cmd
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
