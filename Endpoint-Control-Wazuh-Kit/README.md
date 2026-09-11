# Endpoint Control — Wazuh Operator Tools Kit

Two operator utilities for a Wazuh-monitored Windows endpoint. Unlike the other
kits in this family (which *add* detection), these *control* what the endpoint's
Wazuh stack does — for the times you need a folder left alone, or the whole
stack paused.

| Tool | What it does |
|---|---|
| `wazuh-control.ps1` | **Pause / resume** everything Wazuh on this PC (agent + Suricata capture), with a Resume that restores it exactly. One switch, for heavy work / gaming / privacy windows. |
| `exclude.ps1` | Mark a **folder off-limits** to every capability — FIM, VirusTotal, hash blocklist, YARA and the forensic snapshot all skip it (Sysmon's include-only config already never logs ordinary files there). Nothing checks, scans, hashes, lists, or touches it. |

---

## Start here

| If you want to... | Read |
|---|---|
| **Use / deploy these** | **[INTEGRATION-GUIDE.md](INTEGRATION-GUIDE.md)** |

## Folder layout
```
INTEGRATION-GUIDE.md
docs/Endpoint-Control-PoC.md
endpoint/
  wazuh-control.ps1     pause / resume / status
  exclude.ps1           add / remove / list / apply folder exclusions
```

## Quick use (elevated PowerShell)
```powershell
# Pause everything, do your work, then resume
powershell -ExecutionPolicy Bypass -File wazuh-control.ps1 -Pause
powershell -ExecutionPolicy Bypass -File wazuh-control.ps1 -Resume
powershell -ExecutionPolicy Bypass -File wazuh-control.ps1 -Status

# Leave a folder completely alone
powershell -ExecutionPolicy Bypass -File exclude.ps1 -Add "D:\Games\CS2"
powershell -ExecutionPolicy Bypass -File exclude.ps1 -List
powershell -ExecutionPolicy Bypass -File exclude.ps1 -Remove "D:\Games\CS2"
```

## Two honest notes
- **Sysmon can't be *stopped* during a pause** — it runs tamper-protected (Access
  Denied even to admin; only `Sysmon64.exe -u` removes it). It's left running, but
  with the Wazuh agent stopped **nothing it logs is collected or sent**, so the PC
  is effectively unmonitored and its footprint is negligible (~0.6% CPU, no network).
- **Exclusions stop *monitoring*, never protect data** — nothing in this build ever
  deletes files anyway (FIM/YARA/VirusTotal/hash only alert). An exclusion just also
  stops the folder being watched/scanned. **Process execution and network activity
  from an excluded folder stay visible on purpose** — a folder that could run code
  invisibly would be a security hole. Ask if you want those excluded too.

Both tools were built and validated on a live, production Wazuh-monitored Windows endpoint.
