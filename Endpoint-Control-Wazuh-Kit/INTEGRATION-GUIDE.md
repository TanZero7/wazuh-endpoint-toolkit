# Endpoint Control — Integration Guide

> Two operator tools: pause/resume the whole Wazuh stack, and exclude a folder from every capability.

| | |
|---|---|
| **Runs on** | Windows endpoint with this build's Wazuh agent (+ Suricata, Sysmon) |
| **Privilege** | Elevated (Administrator) |
| **Scope** | Local to the endpoint; nothing on the manager changes |
| **Verified** | 11 September 2026 on a live test workstation — pause/resume cycle and folder exclusion both confirmed end to end |

## 1. Install

Copy `endpoint\wazuh-control.ps1` and `endpoint\exclude.ps1` anywhere on
the endpoint (e.g. `C:\ProgramData\wazuh-toolkit\`). No install step; they act on the
already-deployed Wazuh/Suricata/Sysmon. Run from an elevated PowerShell.

## 2. Pause / resume — `wazuh-control.ps1`

```powershell
wazuh-control.ps1 -Pause     # stop everything Wazuh on this PC
wazuh-control.ps1 -Resume    # put it all back exactly
wazuh-control.ps1 -Status    # show current state
```

**Pause** stops the Wazuh agent (FIM, SCA, syscollector, vulnerability inventory,
the YARA active-response trigger, and the 6-hourly forensic snapshot all go with
it), stops the Suricata capture task + watchdog + process, and sets those to not
auto-start — so a reboot during a pause does **not** silently re-enable monitoring.
A marker file (`C:\ProgramData\wazuh-toolkit\wazuh-paused.marker`) records the paused state.

**Resume** reverses all of it: services back to Automatic and started, Suricata
tasks re-enabled and capture restarted, marker cleared.

> **While paused this PC is genuinely unmonitored** — the agent is off, so events
> during the pause are not collected (not merely buffered). Use `-Resume` as soon
> as the work is done. This is a deliberate security trade-off; use it knowingly.

**Sysmon during pause:** Sysmon is tamper-protected (a protected process — even an
elevated admin gets Access Denied trying to stop it; only `Sysmon64.exe -u`
removes it). The tool leaves it running and says so. That is harmless: with the
agent stopped, nothing collects or ships Sysmon's events, and Sysmon idles at
~0.6% CPU with no network use. If you need Sysmon fully off too, uninstall it
(`Sysmon64.exe -u force`) and reinstall from the Sysmon kit afterwards — not done
automatically here because a failed reinstall would leave the endpoint without it.

## 3. Folder exclusion — `exclude.ps1`

```powershell
exclude.ps1 -Add "D:\Games\CS2"      # exclude a folder, apply everywhere
exclude.ps1 -Remove "D:\Games\CS2"   # stop excluding it
exclude.ps1 -List                    # show current exclusions
exclude.ps1 -Apply                   # re-push the current list to all configs
```

One source of truth: `C:\ProgramData\wazuh-toolkit\exclusions.txt` (one absolute folder
path per line). What an exclusion covers:

| Capability | How it's excluded |
|---|---|
| FIM (file integrity) | `<ignore>` added to the agent's local `ossec.conf` — folder not watched |
| VirusTotal | triggered by FIM → excluded automatically (no FIM event, no lookup) |
| Offline hash blocklist | triggered by FIM → excluded automatically |
| YARA | active-response script skips any file under an excluded folder (reads the list at runtime) |
| Forensic snapshot | excluded files left out of the snapshot (reads the list at runtime) |
| Sysmon | nothing to do — the SwiftOnSecurity config logs only specific file patterns (executables, Startup, script drops), so ordinary data/game files in the folder are never file-logged to begin with. (A separate exclude rule is redundant here and Sysmon normalises it away.) |

**What stays monitored on purpose:** process execution and network activity
*from* an excluded folder. A folder that could run code with no telemetry is a
security hole, so those events are deliberately kept. (In testing, creating a file
in an excluded folder produced zero FIM/file alerts — the only hits were Sysmon
*process-create* events for the shell used to create it, which is exactly this
intended behaviour.)

**Nothing is ever deleted.** No capability in this build deletes files — FIM,
YARA, VirusTotal and the hash blocklist only alert. Exclusion just also stops the
folder being watched or scanned.

## 4. Verification

```powershell
wazuh-control.ps1 -Status         # ACTIVE with all components running
exclude.ps1 -List                 # shows your folders

# prove an exclusion: exclude a subfolder of Downloads, drop a file in it and one
# directly in Downloads, then on the manager only the non-excluded file alerts:
#   grep -a "<your filename>" /var/ossec/logs/alerts/alerts.json
```

## 5. Office fleet notes
- The FIM `<ignore>` entries live in each agent's **local `ossec.conf`** (not the
  manager's shared `agent.conf`), so exclusions are per-endpoint. That's correct —
  each machine has its own folders to exclude. If you want a fleet-wide exclusion,
  add it to the group `agent.conf` on the manager instead.
- Pausing is per-endpoint and local; the manager will show a paused agent as
  disconnected for the duration (expected).
