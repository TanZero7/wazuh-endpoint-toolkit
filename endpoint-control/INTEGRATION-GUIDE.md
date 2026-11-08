# Endpoint Control: Integration Guide

> Two operator tools: pause/resume the whole Wazuh stack on a PC, and exclude a folder from every capability.

> **Install order**
>
> There is **no manager side** for this folder: both tools act only on this endpoint.
> They assume the other capabilities are already installed on the endpoint
> ([FIM](../fim), [Sysmon](../sysmon), [YARA](../yara), [Suricata](../suricata)),
> each of which was set up **manager first, then endpoint**.

| | |
|---|---|
| **Runs on** | Windows endpoint with this toolkit's Wazuh agent (+ Suricata, Sysmon) |
| **Privilege** | Elevated (Administrator) |
| **Scope** | Local to the endpoint; nothing on the manager changes |
| **Verified** | 11 September 2026 on a live production endpoint: pause/resume cycle and folder exclusion both confirmed end to end |

## 1. Install

Copy `wazuh-control.ps1` and `exclude.ps1` anywhere on
the endpoint (e.g. `C:\ProgramData\wazuh-toolkit\`). No install step; they act on the
already-deployed Wazuh/Suricata/Sysmon. Run them from an **elevated PowerShell**.

## 2. Pause / resume: `wazuh-control.ps1`

```powershell
.\wazuh-control.ps1 -Pause     # stop everything Wazuh on this PC
.\wazuh-control.ps1 -Resume    # put it all back exactly
.\wazuh-control.ps1 -Status    # show current state
```

**Pause** stops the Wazuh agent (FIM, SCA, syscollector, vulnerability inventory,
and the YARA and VirusTotal active-response triggers all go with
it), stops the Suricata capture task + watchdog + process, and sets those to not
auto-start, so a reboot during a pause does **not** silently re-enable monitoring.
A marker file (`C:\ProgramData\wazuh-toolkit\wazuh-paused.marker`) records the paused state.

**Resume** reverses all of it: services back to Automatic and started, Suricata
tasks re-enabled and capture restarted, marker cleared.

> **While paused this PC is genuinely unmonitored.** The agent is off, so events
> during the pause are not collected (not merely buffered). Use `-Resume` as soon
> as the work is done. This is a deliberate security trade-off; use it knowingly.

**Sysmon during pause:** Sysmon is tamper-protected (a protected process: even an
elevated admin gets Access Denied trying to stop it; only `Sysmon64.exe -u`
removes it). The tool leaves it running and says so. That is harmless: with the
agent stopped, nothing collects or ships Sysmon's events, and Sysmon idles at
~0.6% CPU with no network use. If you need Sysmon fully off too, uninstall it
(`Sysmon64.exe -u force`) and reinstall from [sysmon](../sysmon) afterwards. That
isn't done automatically, because a failed reinstall would leave the endpoint without it.

## 3. Folder exclusion: `exclude.ps1`

```powershell
.\exclude.ps1 -Add "D:\Games\CS2"      # exclude a folder, apply everywhere
.\exclude.ps1 -Remove "D:\Games\CS2"   # stop excluding it
.\exclude.ps1 -List                    # show current exclusions
.\exclude.ps1 -Apply                   # re-push the current list to all configs
```

One source of truth: `C:\ProgramData\wazuh-toolkit\exclusions.txt` (one absolute folder
path per line). What an exclusion covers:

| Capability | How it's excluded |
|---|---|
| FIM (file integrity) | `<ignore>` added to the agent's local `ossec.conf`: folder not watched |
| VirusTotal (+ Active Response) | triggered by FIM → excluded automatically (no FIM event, no lookup, no deletion) |
| YARA | active-response script skips any file under an excluded folder (reads the list at runtime) |
| Sysmon | nothing to do: the SwiftOnSecurity config logs only specific file patterns (executables, Startup, script drops), so ordinary data/game files in the folder are never file-logged to begin with. (A separate exclude rule is redundant here and Sysmon normalises it away.) |

**What stays monitored on purpose:** process execution and network activity
*from* an excluded folder. A folder that could run code with no telemetry is a
security hole, so those events are deliberately kept. (In testing, creating a file
in an excluded folder produced zero FIM/file alerts; the only hits were Sysmon
*process-create* events for the shell used to create it, which is exactly the
intended behaviour.)

**Excluded folders are never touched.** FIM, YARA and VirusTotal (alert-only)
only alert. The one capability that deletes files, the optional VirusTotal Active
Response, is triggered by FIM, so an excluded folder never generates the event
that could lead to a deletion.

## 4. Verification

### 4.1 Confirm the state (PASS / FAIL)

```powershell
.\wazuh-control.ps1 -Status
```

Normal (monitoring on) looks like this:

```
==== Wazuh monitoring status ====
State        : ACTIVE
WazuhSvc     : Running  (startup: Automatic)
Sysmon64     : Running  (startup: Automatic)
Suricata     : running (pid ...)
  task Suricata IDS           Running
  task Suricata IDS Watchdog  Ready
```

| Result | Meaning |
|---|---|
| **PASS**: `State: ACTIVE`, `WazuhSvc` Running, Suricata running | Monitoring is on |
| **PASS** (after `-Pause`): `State: PAUSED (since …)`, `WazuhSvc` Stopped, Suricata stopped | Pause worked |
| **FAIL**: `ACTIVE` but Suricata `stopped` right after `-Resume` | Wait 5–10 minutes and run `-Status` again: capture restarts via the scheduled task and its watchdog runs every 5 minutes. Then see [Suricata troubleshooting](../suricata/INTEGRATION-GUIDE.md#8-troubleshooting) |

A component that was never installed on this PC shows `not installed`; that's expected, not a failure.

### 4.2 Prove an exclusion works

1. `.\exclude.ps1 -Add "$env:USERPROFILE\Downloads\excluded-test"` and create that folder.
2. Drop one file in `Downloads\excluded-test\` and one directly in `Downloads\`.
3. In the dashboard, search `rule.groups:syscheck` (auto-refresh 5–10 s).

| Result | Meaning |
|---|---|
| **PASS**: only the file directly in `Downloads` alerts | Exclusion works |
| **FAIL**: both files alert | Wait 5–10 minutes (the agent restarts to apply the `<ignore>`) and retry with new files; then run `.\exclude.ps1 -Apply` |

Clean up with `.\exclude.ps1 -Remove "$env:USERPROFILE\Downloads\excluded-test"`.

## 5. Fleet notes
- The FIM `<ignore>` entries live in each agent's **local `ossec.conf`**, so
  exclusions are per-endpoint. That's correct, since each machine has its own
  folders to exclude. Fleet-wide exclusions belong on the manager (group
  `agent.conf`) instead.
- Pausing is per-endpoint and local; the manager will show a paused agent as
  disconnected for the duration (expected).
