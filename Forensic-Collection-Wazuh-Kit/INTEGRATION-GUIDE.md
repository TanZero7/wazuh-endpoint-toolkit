# Endpoint Forensic Snapshot — Integration Guide

> Continuous background evidence collection via a Wazuh command wodle.

| | |
|---|---|
| **Mechanism** | Wazuh `<wodle name="command">`, manager-pushable but installed locally here |
| **Interval** | 6 hours + on every agent start (`run_on_start=yes`) — configurable |
| **Retention** | 14 days locally on the endpoint (configurable in the script) |
| **Verified** | 11 September 2026 — 2 snapshots confirmed with 12 data files each |

## 1. Overview

```
   every 6h + on agent start
              │
              ▼
   forensic-collect.ps1 runs as SYSTEM
              │
       ┌──────┴───────────────────────────┐
       ▼                                    ▼
   C:\ProgramData\wazuh-toolkit\forensics\<ts>\   one JSON summary line
   (full detail, 12+ files, kept 14d)    printed to stdout
                                              │
                                              ▼ Wazuh wodle output capture
                                    rule 100800/100801 on the manager
                                    (if server\ is installed)
```

Each collector run is entirely read-only and resilient by design: every
individual data source is wrapped so one failing collector (e.g.
`Get-LocalGroupMember` throwing on a machine with an orphaned SID — a real,
documented .NET bug) never stops the rest of the run or the summary line
from being produced. A failed sub-collector writes a `<name>.ERROR.txt`
file in that run's snapshot folder instead of silently vanishing.

## 2. Requirements

| Requirement | Why | Check |
|---|---|---|
| Administrator rights | Writing to `active-response\bin\`, editing `ossec.conf` | `net session` |
| Wazuh agent already enrolled | This kit only adds a wodle | `Get-Service WazuhSvc` |
| ~50-200 MB disk over 14 days | Snapshot JSON files (small; mostly text) | — |

## 3. Install

```powershell
cd Forensic-Collection-Wazuh-Kit\endpoint
powershell -ExecutionPolicy Bypass -File .\scripts\wire-collector.ps1
```

This deploys the collector, sets `wazuh_command.remote_commands=1` (required
for any manager-pushed `<wodle name="command">` — Wazuh disables these by
default as a safety measure), adds the wodle block to `ossec.conf`, and
restarts the agent (which triggers the first run immediately via
`run_on_start=yes`).

**Server** (optional): `sudo bash server/install-manager-rules.sh`.

## 4. Verification

```
endpoint\Run-Verify.cmd
```

Checks the collector is deployed, the required local_internal_options
setting is present, the wodle is registered, at least one snapshot exists
with a reasonable number of files in it, and the module actually ran
according to the agent's own log.

### Manual check

```powershell
Get-ChildItem 'C:\ProgramData\wazuh-toolkit\forensics' -Directory | Sort LastWriteTime -Descending | Select -First 1 |
    Get-ChildItem | Select Name,Length
```

### In the dashboard (if the server side is installed)

| Query | Shows |
|---|---|
| `rule.groups:forensic_snapshot` | every collection run |
| `rule.id:100801` | runs where the local-admins list is populated (searchable via `data.local_admins`) |

## 5. Day-to-day

**Change the interval**: re-run `wire-collector.ps1 -Interval 2h` (or any
Wazuh-valid interval string) — it detects the existing wodle block and you'll
need to remove the old block first (delete the `<wodle name="command">...
wazuh-toolkit-forensic-snapshot...</wodle>` block from `ossec.conf`) since the script
only inserts, it doesn't currently replace.

**Change retention**: edit `$retDays` at the top of
`endpoint\scripts\forensic-collect.ps1` and re-run `wire-collector.ps1`
to redeploy the updated script (it copies from the kit's `scripts\` folder
into the agent's `active-response\bin\` each time).

**Investigating an incident**: pull the `snapshot_dir` from the alert, or
just browse `C:\ProgramData\wazuh-toolkit\forensics\` for the run closest to the
incident time. Each snapshot's `processes.json`/`nettcp.json`/`logons.json`
etc. give you what was running and connected at that point without needing
to be on the box live.

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No snapshots at all | wodle not registered, or agent never restarted after wiring | Check `ossec.conf` for the wodle block; restart `WazuhSvc` |
| Snapshot folder has `<name>.ERROR.txt` files | That one sub-collector failed (permissions, a known .NET cmdlet bug, etc.) | Read the error text; the rest of the snapshot is still valid |
| No alert in the dashboard, but files are on disk | Server-side rules not installed | `sudo bash server/install-manager-rules.sh` |
| Snapshots pile up past 14 days | Prune step failing (disk/permissions) | Check `ossec.log` around a collector run for errors; the prune step is best-effort and silently continues on failure by design (never blocks the actual collection) |
