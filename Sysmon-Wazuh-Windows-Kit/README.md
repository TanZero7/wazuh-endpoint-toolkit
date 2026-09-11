# Sysmon + Wazuh — Windows Endpoint Process Telemetry Kit

Installs Microsoft Sysinternals Sysmon on a Windows endpoint with the
[SwiftOnSecurity](https://github.com/SwiftOnSecurity/sysmon-config) baseline
configuration, and wires the local Wazuh agent to read its event log. Wazuh's
**built-in** Sysmon ruleset does the rest — no custom server-side rules needed.

Gives you:

1. **Rich process telemetry** — every process create/terminate with full
   command line and parent chain, network connections, file creates, registry
   Set-Value, image/driver loads, named-pipe creates, WMI event
   filters/consumers, process-access (credential-dumping patterns), raw disk
   access.
2. **~150 built-in Wazuh detections** across those event types, already
   mapped to MITRE ATT&CK (T1059 command interpreters, T1003 credential
   dumping, T1055 process injection, T1547 persistence, T1218 LOLBins, and
   more — see `docs/Sysmon-Wazuh-PoC.md` for the full breakdown observed on a
   real deployment).

---

## Start here

| If you want to... | Read |
|---|---|
| **Deploy this from scratch** | **[INTEGRATION-GUIDE.md](INTEGRATION-GUIDE.md)** |
| Understand what it does and how to read results | `docs/Sysmon-Wazuh-PoC.md` |

---

## Folder layout

```
INTEGRATION-GUIDE.md     HOW TO DEPLOY THIS  <- start here
docs/
  Sysmon-Wazuh-PoC.md         what it does + how to read results
endpoint/                 EVERYTHING THAT RUNS ON THE WINDOWS MACHINE
  Run-Setup.cmd               full install, start to finish  <- double-click this
  Run-Verify.cmd               health check, changes nothing
  scripts/                     the individual stages
server/                   nothing to install — Wazuh's built-in ruleset covers it
  check-sysmon-rules.sh        verifies that ruleset is actually present
```

---

## Install

**Endpoint**: right-click **`endpoint\Run-Setup.cmd`** → *Run as administrator*. It downloads
Sysmon + the SwiftOnSecurity config from their official sources, installs the
service, wires the local Wazuh agent, and verifies.

**Server** (optional, confirms the built-in ruleset is present): `sudo bash server/check-sysmon-rules.sh`.

> **If you get "running scripts is disabled on this system"** — the `.cmd`
> launcher passes `-ExecutionPolicy Bypass` for that one process; nothing
> about the machine's security posture changes permanently.

## Check it's working

```
endpoint\Run-Verify.cmd
```

Then in the Wazuh dashboard: **Threat Hunting** → index `wazuh-alerts-*` →
`rule.groups:sysmon_event1` (or `_event3`, `_event11`, etc. for other event
types).

## Deploying to another Windows machine

Nothing is hardcoded to one host. Copy the folder, run `Run-Setup.cmd`, done.
Prerequisite: a Wazuh agent already enrolled.

## Known limitations

- SwiftOnSecurity's config is a broad, moderate-noise baseline — expect some
  tuning for your environment (exclude your own deployment/RMM tooling if it
  triggers `sysmon_event1` noise).
- Sysmon sees what runs on **this** endpoint; it is not a network sensor
  (pair with the Suricata kit for network visibility).
- Event ID 10 (ProcessAccess) is intentionally scoped down in the stock
  config to avoid extreme volume — this is standard practice, not a bug.
