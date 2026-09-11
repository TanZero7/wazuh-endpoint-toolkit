# Endpoint Forensic Snapshot — Wazuh Collection Kit

Runs a broad, read-only forensic snapshot on a Windows endpoint every few
hours, saves the full detail to disk as an evidence trail, and ships a
one-line JSON summary to Wazuh so an investigation started *after* an
incident already has a "before" picture instead of starting cold.

Collects (read-only, changes nothing):

- Running processes (full command lines) and services
- TCP/UDP connections
- Logged-on users / sessions
- ARP and DNS cache
- SMB shares
- Persistence surface: Run/RunOnce registry keys, scheduled tasks, Startup folders
- 150 most-recently-touched files in Desktop/Downloads
- USB storage history (USBSTOR registry)
- Defender exclusions and firewall profile state

---

## Start here

| If you want to... | Read |
|---|---|
| **Deploy this from scratch** | **[INTEGRATION-GUIDE.md](INTEGRATION-GUIDE.md)** |
| Understand what it does and how to read results | `docs/Forensic-Collection-PoC.md` |

---

## Folder layout

```
INTEGRATION-GUIDE.md     HOW TO DEPLOY THIS  <- start here
docs/
  Forensic-Collection-PoC.md   what it does + how to read results
endpoint/
  Run-Setup.cmd                 full install  <- double-click this
  Run-Verify.cmd                 health check
  scripts/                      forensic-collect.ps1 (the collector) + wire-collector.ps1 + verify.ps1
server/                    OPTIONAL — makes snapshot summaries show up as Wazuh alerts
  install-manager-rules.sh
  local_rules_forensics.xml     rules 100800/100801
  logtest-samples/
```

---

## Install

**Endpoint** (required): `endpoint\Run-Setup.cmd` as administrator.

**Server** (optional but recommended): `sudo bash server/install-manager-rules.sh`.
Without this, the collector still runs and still saves the full evidence
trail to disk on the endpoint — you just won't see a summary alert per run
in the dashboard.

## Check it's working

```
endpoint\Run-Verify.cmd
```

## Deploying to another Windows machine

Copy `endpoint\`, run `Run-Setup.cmd`. The server side is installed once.

## Known limitations

- This is a **snapshot**, not continuous forensic capture — between runs
  (default every 6h), short-lived processes/connections won't be in any
  snapshot. Pair with Sysmon (this kit family) for continuous process/network
  telemetry.
- Snapshots are kept locally on the endpoint for 14 days by default (see
  `$retDays` in the collector script) — this is local evidence, not backed
  up automatically. Point the Log-Backup-Wazuh-Kit's script (or your own) at
  `C:\ProgramData\wazuh-toolkit\forensics\` if you want these off the endpoint too.
