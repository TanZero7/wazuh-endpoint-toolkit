# Sysmon + Wazuh Integration Guide

> Step-by-step deployment of Sysmon on a Windows endpoint, feeding Wazuh's built-in detection ruleset.

| | |
|---|---|
| **Sysmon** | latest (auto-resolved from Sysinternals at install time) |
| **Config** | SwiftOnSecurity/sysmon-config, `sysmonconfig-export.xml` |
| **Wazuh** | 4.x, agent and manager (no version-matching constraint — this uses the standard eventchannel path, not a raw log file) |
| **Endpoint** | Windows 10 / 11 |
| **Server** | any Wazuh manager — nothing to install server-side (verify only, see `server/`) |
| **Verified** | 11 September 2026, Windows 11 Pro build 26200 |

## 1. Overview

Sysmon is a free Microsoft Sysinternals kernel-level monitor that logs
detailed process, network, file, and registry activity to a dedicated Windows
Event Log channel (`Microsoft-Windows-Sysmon/Operational`). This kit installs
it with a well-tested open-source baseline config and points a local Wazuh
agent at that channel. Wazuh ships an extensive built-in ruleset for Sysmon
out of the box — unlike the Suricata integration in this same kit family,
**no custom manager-side rules are required.**

## 2. Requirements

| Requirement | Why | Check |
|---|---|---|
| Administrator rights | Installing a driver + service | `net session` |
| Windows 10/11 | Sysmon target OS | — |
| Internet access on the endpoint | Downloads Sysmon + config at install time | — |
| Wazuh agent already enrolled | The kit only adds a `<localfile>`, it doesn't install the agent | `Get-Service WazuhSvc` |
| ~50 MB disk | Sysmon binary + event log | — |

## 3. Install

### Endpoint

```powershell
cd Sysmon-Wazuh-Windows-Kit\endpoint
powershell -ExecutionPolicy Bypass -File .\scripts\install-sysmon.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\wire-wazuh-agent.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
```

Or just run `Run-Setup.cmd` as administrator, which does all three.

### Server (optional — verification only)

```bash
cd server
sudo bash check-sysmon-rules.sh
```

Nothing to *install* — the Sysmon ruleset (event IDs 1,3,7,8,10,11,13,20,
~150 rules) ships with every Wazuh manager. This script confirms that's
true on your install rather than assuming it.

### What `install-sysmon.ps1` does

1. Downloads `Sysmon.zip` from `download.sysinternals.com` (Microsoft's own
   distribution — no third-party mirror).
2. Downloads `sysmonconfig-export.xml` from SwiftOnSecurity's GitHub repo.
3. Installs the service with `-accepteula -i <config>` (first run), or
   applies the config with `-c <config>` if Sysmon is already installed
   (idempotent — safe to re-run to pick up a config update).

### What `wire-wazuh-agent.ps1` does

Inserts one block into the agent's `ossec.conf`:

```xml
<localfile>
  <location>Microsoft-Windows-Sysmon/Operational</location>
  <log_format>eventchannel</log_format>
</localfile>
```

then restarts `WazuhSvc`. Idempotent — if the block is already present it
leaves the file alone.

> **Rolling this out to more than one machine?** Put this same `<localfile>`
> block in the Wazuh **group's `agent.conf`** on the manager instead of each
> endpoint's local `ossec.conf` — one central place, pushed automatically to
> every agent in the group, instead of touching each machine's `ossec.conf`
> by hand. That's what this same integration used centrally on the WAZUH TOOLKIT
> build; the local-`ossec.conf` approach here is for a single ad-hoc machine
> or a first test.

## 4. Verification

```
endpoint\Run-Verify.cmd
```

Checks: service running, driver registered, operational log enabled and has
recent events, agent config references the channel, and the agent's
logcollector confirms it's tailing the channel.

### Manual triggers

| Test | Command | Expected |
|---|---|---|
| Process creation | any command in a fresh `cmd.exe` | EID 1 in the operational log within ~1s |
| Network connection | `Invoke-WebRequest https://example.com` | EID 3 |
| File creation | create a file anywhere Sysmon watches (default: everywhere) | EID 11 |
| Registry Run key | add a value under `HKCU\...\CurrentVersion\Run` | EID 13, and likely a Wazuh persistence-technique alert |

### In the dashboard

| Query | Shows |
|---|---|
| `rule.groups:sysmon_event1` | process creation detections |
| `rule.groups:sysmon_event3` | network connection detections |
| `rule.groups:sysmon_event11` | file creation detections (includes "dropped in malware-common-folder" style rules) |
| `rule.groups:sysmon_event13` | registry Set-Value (persistence-hunting) |
| `rule.mitre.id:T1059*` | any command/scripting-interpreter technique |

## 5. Observed on a real deployment (11 Sep 2026)

| Metric | Observed |
|---|---|
| Rules loaded across EID 1/3/7/8/10/11/13/20 rule files | ~150 |
| Distinct MITRE technique IDs reachable | 40+ from Sysmon alone (70+ combined with the rest of this kit family — see the attack-coverage report) |
| First alert after service start | < 5 seconds |
| Noise on an idle developer workstation | Low; most volume comes from EID1 on tools that spawn `cmd.exe`/`powershell.exe` a lot (build systems, package managers) |

## 6. Day-to-day

**Updating the config**: re-run `install-sysmon.ps1` (idempotent — re-downloads
the config and applies it with `-c`).

**Is Sysmon running?**

```powershell
Get-Service Sysmon64
Get-Process Sysmon64
```

**Tuning noise**: edit `sysmonconfig.xml` in the Sysmon install directory
(`C:\Program Files\Sysmon\sysmonconfig.xml` by default) and re-apply with
`Sysmon64.exe -c sysmonconfig.xml`. SwiftOnSecurity's config is heavily
commented — read the `<RuleGroup>` you want to change before editing it.

**Uninstall**:
```powershell
& 'C:\Program Files\Sysmon\Sysmon64.exe' -u
```
Then remove the `<localfile>` block from `ossec.conf` (or the group
`agent.conf`) and restart the agent.

## 7. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Get-Service Sysmon64` fails | Wrong binary name on 32-bit Windows | Use `Sysmon.exe` / service name `Sysmon` instead of `Sysmon64` |
| No events in the dashboard, but the operational log has entries locally | Agent not wired, or not restarted after wiring | Re-run `wire-wazuh-agent.ps1`; confirm `wazuh-logcollector.state` lists the channel |
| "Access denied" installing the driver | Not elevated | Run the `.cmd` as Administrator (it self-elevates via UAC if double-clicked) |
| Download fails / times out | No internet on the endpoint, or a proxy is required | Pre-stage `Sysmon.zip` and `sysmonconfig-export.xml` locally and point `-SysmonUrl`/`-ConfigUrl` at `file://` paths, or set `$env:HTTPS_PROXY` before running |
