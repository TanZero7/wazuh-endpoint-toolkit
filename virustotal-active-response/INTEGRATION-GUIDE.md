# VirusTotal Active Response: Endpoint Integration Guide

> Puts `remove-threat.exe` on the agent so a file VirusTotal flags as malicious is deleted automatically, and verifies the whole VirusTotal chain end to end.

> **Install order: manager first, then endpoint, then verify**
>
> 1. **Manager side**: [wazuh-manager-toolkit → virustotal](https://github.com/TanZero7/wazuh-manager-toolkit/tree/main/virustotal).
>    Adds the VirusTotal integration (alert-only) and, for auto-delete, the Active Response block.
> 2. **Endpoint side**: this guide, [section 2](#2-install-endpoint). Only needed for Active Response.
> 3. **Verify**: this guide, [section 3](#3-verification). Works for alert-only too.

| | |
|---|---|
| **Wazuh** | 4.x agent |
| **Endpoint** | Windows 10/11 |
| **Trigger chain** | FIM 554/550 → VirusTotal 87105 → Active Response 657 → file deleted 553 |
| **Verified** | Confirmed end to end on two live endpoints |

> ⚠️ Active Response deletes files **automatically and irreversibly**. Keeping
> VirusTotal alert-only (skip section 2) is a perfectly reasonable choice.

## 1. Requirements

| Requirement | Why | Check |
|---|---|---|
| Manager side done | The integration + AR block live on the manager | [wazuh-manager-toolkit → virustotal](https://github.com/TanZero7/wazuh-manager-toolkit/tree/main/virustotal) |
| [FIM](../fim) installed on this endpoint | FIM events trigger the VirusTotal lookup | `fim\scripts\verify.ps1` all `[PASS]` |
| `remove-threat.exe` in `bin\` | It's what actually deletes the file (not committed to git) | See [`bin/PUT-remove-threat.exe-HERE.txt`](bin/PUT-remove-threat.exe-HERE.txt) |
| Administrator rights | Writing to the agent's `active-response\bin` | `net session` |

## 2. Install (endpoint)

Open **Command Prompt as Administrator**:

```bat
cd virustotal-active-response
powershell -ExecutionPolicy Bypass -File .\scripts\install-active-response.ps1
```

## 3. Verification

### 3.1 Confirm the install (PASS / FAIL)

The install script itself should end with:

```
[OK] remove-threat.exe installed (… bytes).
```

Then confirm the manager has pushed the Active Response config to this agent:

```powershell
Select-String remove-threat 'C:\Program Files (x86)\ossec-agent\shared\ar.conf'
```

| Result | Meaning |
|---|---|
| **PASS**: `[OK] remove-threat.exe installed` **and** `ar.conf` contains `remove-threat` | Ready to test |
| **FAIL**: `remove-threat.exe not found at …` | Build/copy it into `bin\` first (see Requirements) |
| **FAIL**: `ar.conf` has no `remove-threat` line | Wait **5–10 minutes after installation** and check again (the manager pushes `ar.conf` on its own cycle). Still missing: the manager-side Active Response step isn't done |

### 3.2 Live test with EICAR

Only once 3.1 passes. EICAR is a standard, industry-wide benign test string every
AV engine recognises as "this is a test", not real malware, so it's safe to use.

1. Temporarily exclude a throwaway test folder from Defender (it would otherwise
   quarantine the file before FIM/VirusTotal ever see it):
   ```powershell
   $t = "$env:USERPROFILE\Downloads\vt_test"; New-Item -ItemType Directory -Force $t
   Add-MpPreference -ExclusionPath $t
   ```
2. Write the EICAR test string to a file in that folder (get the exact string
   from https://www.eicar.org/download-anti-malware-testfile/).
3. Wait ~15–30 seconds and check the dashboard (**Threat Hunting**, index
   `wazuh-alerts-*`, auto-refresh 5–10 s).
4. Clean up: remove the folder and the Defender exclusion.
   ```powershell
   Remove-Item $t -Recurse -Force
   Remove-MpPreference -ExclusionPath $t
   ```

| Result | Meaning |
|---|---|
| **PASS (alert-only)**: rule **87105** (level 12, with a positives/total ratio and VT permalink) | VirusTotal integration works |
| **PASS (Active Response)**: 87105, then **657**, then **553**, and **100092** if the outcome rules are installed; the file is gone from the folder | Auto-delete works end to end |
| **FAIL**: no alert at all | Wait 5–10 minutes after installation and repeat with a fresh file; then see section 4 |
| **FAIL**: 87105 but no 657/553 | `remove-threat.exe` missing on this agent, or `ar.conf` not pushed yet (re-check 3.1) |

### 3.3 In the dashboard

| Query | Shows |
|---|---|
| `rule.groups:virustotal` | every VT lookup result |
| `rule.id:87105` | actual positive hits |
| `rule.id:87103` or `87104` | lookups that ran but found nothing (proves the pipeline works even with no hit) |
| `rule.id:100092` / `100093` | Active Response success / failure, with file path |

## 4. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No alert at all after the EICAR test | Defender ate the file before FIM saw it, or FIM isn't watching that folder | Confirm the exclusion applied (`Get-MpPreference`), and that [FIM](../fim) watches that path |
| Lookups run but come back as errors (`rule.id:87101`) | API key / rate-limit problem on the manager | See [manager troubleshooting](https://github.com/TanZero7/wazuh-manager-toolkit/blob/main/virustotal/INTEGRATION-GUIDE.md#6-troubleshooting-manager) |
| 87105 appears but the file isn't deleted | `remove-threat.exe` missing, or AR config not pushed to this agent yet | Re-run section 3.1; wait 5–10 minutes for `ar.conf` |
| A folder you excluded with `endpoint-control\exclude.ps1` never triggers anything | By design: no FIM event, so no lookup and no deletion | — |
