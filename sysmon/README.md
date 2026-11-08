# Sysmon: Windows Process Telemetry

> **Order:** [manager side](https://github.com/TanZero7/wazuh-manager-toolkit/tree/main/sysmon) **first** → then this endpoint folder → then verify ([INTEGRATION-GUIDE.md § 4](INTEGRATION-GUIDE.md)).
> Every check prints `[PASS]`/`[FAIL]`; if something shows `[FAIL]`, wait **5–10 minutes after installation** and run it again before troubleshooting.

Installs Microsoft Sysinternals Sysmon on a Windows endpoint with the
[SwiftOnSecurity](https://github.com/SwiftOnSecurity/sysmon-config) baseline
configuration, and wires the local Wazuh agent to read its event log. Wazuh's
**built-in** Sysmon ruleset does the rest, with no custom server-side rules needed.

Gives you:

1. **Rich process telemetry**: every process create/terminate with full
   command line and parent chain, network connections, file creates, registry
   Set-Value, image/driver loads, named-pipe creates, WMI event
   filters/consumers, process-access (credential-dumping patterns), raw disk
   access.
2. **~150 built-in Wazuh detections** across those event types, already
   mapped to MITRE ATT&CK (T1059 command interpreters, T1003 credential
   dumping, T1055 process injection, T1547 persistence, T1218 LOLBins, and
   more).

---

## Start here

| If you want to... | Read |
|---|---|
| **Deploy step by step** | **[../guides/SYSMON-YARA-SETUP-GUIDE.md § 1](../guides/SYSMON-YARA-SETUP-GUIDE.md#1-sysmon-endpoint)** |
| Full reference, verification, troubleshooting | [INTEGRATION-GUIDE.md](INTEGRATION-GUIDE.md) |

## Folder layout

```
README.md
INTEGRATION-GUIDE.md          full deployment + troubleshooting guide
Run-Setup.cmd                 runs the three scripts below in order
Run-Verify.cmd                health check, changes nothing
scripts/
  install-sysmon.ps1          downloads Sysmon + SwiftOnSecurity config, installs the service
  wire-wazuh-agent.ps1        adds the Sysmon event channel to the agent
  verify.ps1                  [PASS]/[FAIL] checks
```

Nothing to install on the manager: Wazuh's built-in Sysmon ruleset covers it.
`sysmon/check-sysmon-rules.sh` in
[wazuh-manager-toolkit](https://github.com/TanZero7/wazuh-manager-toolkit)
verifies that ruleset is present.

## Install (elevated Command Prompt)

```bat
cd sysmon
powershell -ExecutionPolicy Bypass -File .\scripts\install-sysmon.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\wire-wazuh-agent.ps1
```

Or right-click `Run-Setup.cmd` → *Run as administrator*.

## Check it's working

Run `scripts\verify.ps1` (or `Run-Verify.cmd`): every line `[PASS]`, ending in "All checks passed." Then in the Wazuh dashboard:
**Threat Hunting** → index `wazuh-alerts-*` → `rule.groups:sysmon_event1`
(or `_event3`, `_event11`, etc. for other event types).

## Deploying to another Windows machine

Nothing is hardcoded to one host. Copy this folder, run the scripts, done.
Prerequisite: a Wazuh agent already enrolled.

## Known limitations

- SwiftOnSecurity's config is a broad, moderate-noise baseline, so expect some
  tuning for your environment (exclude your own deployment/RMM tooling if it
  triggers `sysmon_event1` noise).
- Sysmon sees what runs on **this** endpoint; it is not a network sensor
  (pair with [Suricata](../suricata) for network visibility).
- Event ID 10 (ProcessAccess) is intentionally scoped down in the stock
  config to avoid extreme volume. This is standard practice, not a bug.
