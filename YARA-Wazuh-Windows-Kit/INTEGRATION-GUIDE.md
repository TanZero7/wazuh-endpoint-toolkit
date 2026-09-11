# YARA + Wazuh Integration Guide

> Content-based malware scanning, triggered automatically by Wazuh FIM via active-response.

| | |
|---|---|
| **YARA** | 4.5.5 (newest release with a prebuilt win64 zip — VirusTotal/yara stopped shipping Windows binaries from 4.5.6 onward; the install script walks releases backwards to find one that has them) |
| **Rule pack** | Neo23x0/signature-base, 416 of ~440 rules survive compilation on this build |
| **Wazuh** | 4.x manager + agent |
| **Endpoint** | Windows 10/11 |
| **Trigger** | Wazuh FIM rules 550 (modified) / 554 (added) |
| **Verified** | 11 September 2026, Windows 11 Pro |

## 1. Overview

This is not a scheduled scanner. It is wired directly into Wazuh's active-response
subsystem: every time FIM detects a file added or changed in a watched
directory, the manager tells the *same agent* to run YARA against *that
specific file*, and the result (match or clean) comes back as a Wazuh alert.

```
  File added/changed in a FIM-watched dir
              │
              ▼
   Wazuh FIM realtime  ──►  rule 550/554 alert
              │
              ▼ manager: active-response (location=local, rules_id=550,554)
   wazuh-execd on the SAME agent runs yara-scan.cmd
              │
              ▼ yara64.exe -r index.yar <changed file>
   result written to yara-results.log (JSON, one line)
              │
              ▼ Wazuh agent tails that log
   rule 100700 (match) / 100701 (clean) on the manager
```

## 2. Requirements

| Requirement | Why | Check |
|---|---|---|
| Administrator rights (endpoint) | Installing to Program Files, writing ossec.conf | `net session` |
| Root (manager) | Installing rules, editing ossec.conf | — |
| Internet access on the endpoint | Downloads YARA + the rule pack at install time | — |
| Wazuh agent enrolled, FIM already watching some directory | The AR trigger is FIM rules 550/554 | see the FIM kit in this family |
| ~150 MB disk (endpoint) | YARA binary + rule pack | — |

## 3. Install

### Endpoint

```powershell
cd YARA-Wazuh-Windows-Kit\endpoint
powershell -ExecutionPolicy Bypass -File .\scripts\install-yara.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\wire-active-response.ps1
```
Or `Run-Setup.cmd` as administrator, which does both plus verify.

### Manager

```bash
cd server
sudo bash install-manager-rules.sh
```

Then **paste `active-response-block.xml` into `/var/ossec/etc/ossec.conf`
by hand** (inside `<ossec_config>`, near the other `<command>` blocks),
config-test, and restart:

```bash
/var/ossec/bin/wazuh-analysisd -t
systemctl restart wazuh-manager
```

> **Why this one step isn't scripted**: `install-manager-rules.sh` only ever
> touches its own dedicated rules file — a mistake there breaks one rules
> file. `ossec.conf` is the manager's main config, shared with every other
> integration on the box; an automated merge that gets it wrong can take the
> whole manager down. Pasting one 12-line block by hand, with a
> config-test before restarting, is the safe way to do this — it's the same
> reason Wazuh's own official docs ask for this step manually too.

## 4. Verification

```
endpoint\Run-Verify.cmd
```

This only proves the pieces are in place (binaries present, rules pushed,
log wired). **It does not prove the trigger chain actually fires** — for
that, do a real end-to-end test:

### 4.1 Live end-to-end test (recommended)

On the endpoint, in a FIM-watched directory (e.g. `Downloads`):

```powershell
"WAZUHKIT_YARA_SELFTEST_MARKER_4f8a1c" | Set-Content .\selftest.txt
```

If you want a guaranteed match without waiting on ruleset coverage, add this
rule to `C:\Program Files\YARA\rules\` and re-run `install-yara.ps1
-RefreshRulesOnly` to fold it into `index.yar`:

```yara
rule Deployment_Selftest { strings: $m = "WAZUHKIT_YARA_SELFTEST_MARKER_4f8a1c" condition: $m }
```

Within ~15-20 seconds, on the manager:

```bash
grep -a "WAZUHKIT_YARA_SELFTEST" /var/ossec/logs/alerts/alerts.json
```

Expect a rule **100700** alert, level 12, MITRE T1204.002.

### 4.2 In the dashboard

| Query | Shows |
|---|---|
| `rule.groups:yara_alert` | confirmed matches |
| `rule.id:100700` | matches only |
| `rule.id:100701` | clean scans (proves the whole chain ran even with no hit) |
| `data.yara_scanned_file:*` | searchable file path field |

## 5. Observed on a real deployment (11 Sep 2026)

3 independent files, each containing a deliberate marker string, all
produced correctly-classified rule 100700 alerts within seconds of being
written to Downloads — full chain confirmed working end to end.

## 6. Windows-specific gotchas (found and fixed during this build)

None of these are documented anywhere obvious; both cost real debugging time
and are already fixed in `active-response/yara-scan.ps1` in this kit — but
if you ever rewrite this script from scratch, you will hit them again.

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | Script runs, logs "done", but the results file never gets a new line, and later runs seem to just silently stop happening entirely | `Add-Content` to the results log throws "being used by another process" (Wazuh's logcollector holds it open to tail it) — and under `$ErrorActionPreference='SilentlyContinue'` that error is swallowed completely, no trace anywhere | Open the file explicitly: `[System.IO.File]::Open($logFile, 'Append', 'Write', [System.IO.FileShare]::ReadWrite)` instead of `Add-Content` |
| 2 | The manager confirms (in debug logs) it sent the active-response command, but **nothing ever happens on the agent**, for every single trigger from then on, even much later ones | The AR script reads stdin with `[Console]::In.ReadToEnd()`, which blocks forever — `wazuh-execd` keeps the pipe open (in case a later revert/"delete" message follows for timeout-based commands) and never sends EOF. The hung process then occupies execd's worker slot, silently blocking **every subsequent** active-response trigger until it's killed or the agent restarts | Use `[Console]::In.ReadLine()` — the AR payload is one newline-terminated JSON line; no need to wait for the stream to close |
| 3 | A script written against generic Wazuh AR examples checks `if ($json.command -ne 'add') { exit }` and never runs | Those examples are for timeout/revert-style commands, where `command` really is `"add"`/`"delete"`. For a plain command with no `<timeout>` in the active-response block (this kit's design), the `command` field is the **AR name itself with a numeric suffix** (e.g. `"yara-scan0"`), not the literal string `"add"` | Don't filter on `command == 'add'`. If you ever add a `<timeout>` and need to ignore the revert call, match `$json.command -match '^delete'` instead |

If you find your own AR script "not firing" and none of the above explains
it, check for a stuck process first — bug #2 above leaves a permanently
hung `cmd.exe` -> `powershell.exe` pair that silently jams every future
trigger:

```powershell
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'yara-scan' } |
    Select-Object ProcessId,CreationDate,CommandLine
```

Kill any that are more than a few seconds old, then restart `WazuhSvc`.

## 7. Day-to-day

**Refresh the rule pack** (worth scheduling monthly-ish — signature-base
updates periodically):
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-yara.ps1 -RefreshRulesOnly
```

**Add your own rule**: drop a `.yar` file into `C:\Program Files\YARA\rules\`,
then re-run with `-RefreshRulesOnly` to fold it into `index.yar` (the
install script rebuilds the index every time it runs).

**Tuning false positives**: signature-base rules occasionally fire on
legitimate admin/pentest tooling (that's largely the point of some of them —
e.g. Mimikatz-family detections). Move a noisy rule file to
`<name>.yar.disabled` and re-run with `-RefreshRulesOnly`.

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `install-yara.ps1` fails to find a win64 release | GitHub API rate limit, or a future release also drops binaries | Wait a few minutes (rate limit), or pin a known-good `-Version` |
| Rules fail to compile | A rule needs an external variable this kit doesn't define | The install script auto-disables (`.disabled`) any rule file that fails to compile — check the "disabled(bad)" count in its output |
| `verify.ps1` shows "Manager has pushed yara-scan into ar.conf" = FAIL | Server-side `active-response-block.xml` not pasted in yet, or manager not restarted after | Complete section 3's manager steps |
| Nothing happens on a real file change | See section 6 — almost always bug #2 (stuck process) if it worked once and then stopped | Kill stuck processes, restart `WazuhSvc` |
| High CPU during a scan | Scanning a very large file against 416 rules | The AR script already skips files >100MB; lower that threshold in `yara-scan.ps1` if needed |
