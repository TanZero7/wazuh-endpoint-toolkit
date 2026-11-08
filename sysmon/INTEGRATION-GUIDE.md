# Sysmon: Endpoint Integration Guide

> Sysmon on a Windows endpoint, feeding Wazuh's built-in detection ruleset.

> **Install order: manager first, then endpoint, then verify**
>
> 1. **Manager side**: [wazuh-manager-toolkit → sysmon](https://github.com/TanZero7/wazuh-manager-toolkit/tree/main/sysmon).
>    Nothing to install there, just a quick check that Wazuh's built-in Sysmon ruleset is present.
> 2. **Endpoint side**: this guide, [section 3](#3-install-endpoint).
> 3. **Verify**: this guide, [section 4](#4-verification). Only after steps 1 and 2 are done.

| | |
|---|---|
| **Sysmon** | latest (auto-resolved from Sysinternals at install time) |
| **Config** | SwiftOnSecurity/sysmon-config, `sysmonconfig-export.xml` |
| **Wazuh** | 4.x, agent and manager (no version-matching constraint: this uses the standard eventchannel path, not a raw log file) |
| **Endpoint** | Windows 10 / 11 |
| **Verified** | 11 September 2026, Windows 11 Pro build 26200 |

## 1. Overview

Sysmon is a free Microsoft Sysinternals kernel-level monitor that logs
detailed process, network, file, and registry activity to a dedicated Windows
Event Log channel (`Microsoft-Windows-Sysmon/Operational`). This kit installs
it with a well-tested open-source baseline config and points the local Wazuh
agent at that channel. Wazuh ships an extensive built-in ruleset for Sysmon
out of the box, so unlike [Suricata](../suricata), **no custom manager-side
rules are required.**

## 2. Requirements

| Requirement | Why | Check |
|---|---|---|
| Manager side done | Confirms the built-in Sysmon ruleset exists before you rely on it | [wazuh-manager-toolkit → sysmon](https://github.com/TanZero7/wazuh-manager-toolkit/tree/main/sysmon) |
| Administrator rights | Installing a driver + service | `net session` |
| Windows 10/11 | Sysmon target OS | — |
| Internet access on the endpoint | Downloads Sysmon + config at install time | — |
| Wazuh agent already enrolled | The kit only adds a `<localfile>`, it doesn't install the agent | `Get-Service WazuhSvc` |
| ~50 MB disk | Sysmon binary + event log | — |

## 3. Install (endpoint)

Open **Command Prompt as Administrator** and run, one line at a time:

```bat
cd sysmon
powershell -ExecutionPolicy Bypass -File .\scripts\install-sysmon.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\wire-wazuh-agent.ps1
```

(`Run-Setup.cmd` runs the same two scripts plus the check in section 4.1.)

### What `install-sysmon.ps1` does

1. Downloads `Sysmon.zip` from `download.sysinternals.com` (Microsoft's own
   distribution, no third-party mirror).
2. Downloads `sysmonconfig-export.xml` from SwiftOnSecurity's GitHub repo.
3. Installs the service with `-accepteula -i <config>` (first run), or
   applies the config with `-c <config>` if Sysmon is already installed
   (idempotent, so safe to re-run to pick up a config update).

### What `wire-wazuh-agent.ps1` does

Inserts one block into the agent's `ossec.conf`:

```xml
<localfile>
  <location>Microsoft-Windows-Sysmon/Operational</location>
  <log_format>eventchannel</log_format>
</localfile>
```

then restarts `WazuhSvc`. Idempotent: if the block is already present it
leaves the file alone.

> **Rolling out to many machines?** The same `<localfile>` block can be pushed
> centrally from the manager instead. See
> [wazuh-manager-toolkit → sysmon](https://github.com/TanZero7/wazuh-manager-toolkit/tree/main/sysmon).

## 4. Verification

### 4.1 Confirm the install (PASS / FAIL)

```bat
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
```

A good install looks like this, ending in **"All checks passed."**:

```
==> VERDICT
    [PASS] Sysmon service running             Sysmon64 = Running
    [PASS] Sysmon driver registered           Start=...
    [PASS] Operational log enabled            records=...
    [PASS] Recent Sysmon events present       <timestamp>
    [PASS] Wazuh agent wired to Sysmon channel
    [PASS] Wazuh logcollector tailing the channel
```

> ⏳ **If any line shows `[FAIL]`, don't troubleshoot yet.** Wait **5–10 minutes
> after installation**, then run `verify.ps1` again. "Wazuh logcollector tailing
> the channel" reads `wazuh-logcollector.state`, which the agent only rewrites a
> few minutes after it restarts. Only treat it as broken if it still fails
> after the wait.

### 4.2 Live tests

Only once 4.1 shows all `[PASS]`:

| Test | Command | Expected |
|---|---|---|
| Process creation | any command in a fresh `cmd.exe` | EID 1 in the operational log within ~1s |
| Network connection | `Invoke-WebRequest https://example.com` | EID 3 |
| File creation | create a file anywhere Sysmon watches (default: everywhere) | EID 11 |
| Registry Run key | add a value under `HKCU\...\CurrentVersion\Run` | EID 13, and likely a Wazuh persistence-technique alert |

### 4.3 In the dashboard

**Threat Hunting**, index `wazuh-alerts-*` (set auto-refresh to 5–10 s):

| Query | Shows |
|---|---|
| `rule.groups:sysmon_event1` | process creation detections |
| `rule.groups:sysmon_event3` | network connection detections |
| `rule.groups:sysmon_event11` | file creation detections (includes "dropped in malware-common-folder" style rules) |
| `rule.groups:sysmon_event13` | registry Set-Value (persistence-hunting) |
| `rule.mitre.id:T1059*` | any command/scripting-interpreter technique |

| Result | Meaning |
|---|---|
| **PASS**: `sysmon_event1` alerts appear within seconds of the live tests | Sysmon is fully working |
| **FAIL**: events in the local operational log but nothing in the dashboard | Wait 5–10 minutes after installation and retry, then see section 7 |

## 5. Observed on a real deployment (11 Sep 2026)

| Metric | Observed |
|---|---|
| Rules loaded across EID 1/3/7/8/10/11/13/20 rule files | ~150 |
| Distinct MITRE technique IDs reachable | 40+ from Sysmon alone (70+ combined with the other capabilities in this toolkit) |
| First alert after service start | < 5 seconds |
| Noise on an idle developer workstation | Low; most volume comes from EID1 on tools that spawn `cmd.exe`/`powershell.exe` a lot (build systems, package managers) |

## 6. Day-to-day

**Updating the config**: re-run `install-sysmon.ps1` (idempotent: re-downloads
the config and applies it with `-c`).

**Is Sysmon running?**

```powershell
Get-Service Sysmon64
Get-Process Sysmon64
```

**Tuning noise**: edit `sysmonconfig.xml` in the Sysmon install directory
(`C:\Program Files\Sysmon\sysmonconfig.xml` by default) and re-apply with
`Sysmon64.exe -c sysmonconfig.xml`. SwiftOnSecurity's config is heavily
commented, so read the `<RuleGroup>` you want to change before editing it.

**Uninstall**:
```powershell
& 'C:\Program Files\Sysmon\Sysmon64.exe' -u
```
Then remove the `<localfile>` block from `ossec.conf` and restart the agent.

## 7. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `verify.ps1` shows `[FAIL]` right after setup | The logcollector-tailing check reads `wazuh-logcollector.state`, which only catches up a few minutes after the agent restarts | Wait 5–10 minutes and run `verify.ps1` again before troubleshooting further |
| `Get-Service Sysmon64` fails | Wrong binary name on 32-bit Windows | Use `Sysmon.exe` / service name `Sysmon` instead of `Sysmon64` |
| No events in the dashboard, but the operational log has entries locally | Agent not wired, or not restarted after wiring | Re-run `wire-wazuh-agent.ps1`; confirm `wazuh-logcollector.state` lists the channel |
| Still no dashboard alerts after that | Manager-side ruleset missing or customized | Run the manager check: [wazuh-manager-toolkit → sysmon](https://github.com/TanZero7/wazuh-manager-toolkit/tree/main/sysmon) |
| "Access denied" installing the driver | Not elevated | Run Command Prompt as Administrator (or the `.cmd`, which self-elevates via UAC if double-clicked) |
| Download fails / times out | No internet on the endpoint, or a proxy is required | Pre-stage `Sysmon.zip` and `sysmonconfig-export.xml` locally and point `-SysmonUrl`/`-ConfigUrl` at `file://` paths, or set `$env:HTTPS_PROXY` before running |
