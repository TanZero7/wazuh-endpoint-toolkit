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
cd yara
powershell -ExecutionPolicy Bypass -File .\scripts\install-yara.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\wire-active-response.ps1
```
Or `Run-Setup.cmd` as administrator, which does both plus verify.

### Manager

> These files live in the `yara/` folder of the companion
> [wazuh-manager-toolkit](https://github.com/TanZero7/wazuh-manager-toolkit) repo.

```bash
cd wazuh-manager-toolkit/yara
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
Run-Verify.cmd
```

This only proves the pieces are in place (binaries present, rules pushed,
log wired). **It does not prove the trigger chain actually fires** — for
that, do a real end-to-end test:

### 4.1 Live end-to-end test (recommended)

On the endpoint, in a FIM-watched directory (e.g. `Downloads`):

```powershell
"WAZUHKIT_YARA_SELFTEST_MARKER_4f8a1c" | Set-Content .\selftest.txt
```

If you want a guaranteed match without waiting on ruleset coverage, save this
rule as `C:\Program Files\YARA\rules\deployment_selftest.yar` and append
`include "deployment_selftest.yar"` to `index.yar` in the same folder (the
scan compiles `index.yar` on every run, so it's live immediately). Do **not**
use `install-yara.ps1 -RefreshRulesOnly` for this: it deletes every `.yar` in
the rules folder before rebuilding the index, which wipes the self-test rule:

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

None of these are documented anywhere obvious; all cost real debugging time
and are already fixed in this kit — but if you ever rewrite the affected
file from scratch, you will hit them again.

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | Script runs, logs "done", but the results file never gets a new line, and later runs seem to just silently stop happening entirely | `Add-Content` to the results log throws "being used by another process" (Wazuh's logcollector holds it open to tail it) — and under `$ErrorActionPreference='SilentlyContinue'` that error is swallowed completely, no trace anywhere | Open the file explicitly: `[System.IO.File]::Open($logFile, 'Append', 'Write', [System.IO.FileShare]::ReadWrite)` instead of `Add-Content` (in `active-response/yara-scan.ps1`) |
| 2 | The manager confirms (in debug logs) it sent the active-response command, but **nothing ever happens on the agent**, for every single trigger from then on, even much later ones | The AR script reads stdin with `[Console]::In.ReadToEnd()`, which blocks forever — `wazuh-execd` keeps the pipe open (in case a later revert/"delete" message follows for timeout-based commands) and never sends EOF. The hung process then occupies execd's worker slot, silently blocking **every subsequent** active-response trigger until it's killed or the agent restarts | Use `[Console]::In.ReadLine()` — the AR payload is one newline-terminated JSON line; no need to wait for the stream to close (in `active-response/yara-scan.ps1`) |
| 3 | A script written against generic Wazuh AR examples checks `if ($json.command -ne 'add') { exit }` and never runs | Those examples are for timeout/revert-style commands, where `command` really is `"add"`/`"delete"`. For a plain command with no `<timeout>` in the active-response block (this kit's design), the `command` field is the **AR name itself with a numeric suffix** (e.g. `"yara-scan0"`), not the literal string `"add"` | Don't filter on `command == 'add'`. If you ever add a `<timeout>` and need to ignore the revert call, match `$json.command -match '^delete'` instead (in `active-response/yara-scan.ps1`) |
| 4 | Every static check in `verify.ps1` and the whole endpoint chain (Add-Content fix, stdin fix, command filter fix — all correct) passes, `yara-results.log` fills up with real `"yara_scan_result":"match"` lines, and **still no rule 100700 alert ever appears on the manager**, on any endpoint, for any file | `server/local_rules_yara.xml` rule 100700 matched `<field name="yara_rule">\.+</field>` — one-or-more **literal dots**, not "any value". YARA rule identifiers can only contain letters/digits/underscore (the YARA language itself forbids a `.` in a rule name), so that pattern could never match a real `yara_rule` value, ever, regardless of how correctly everything else was built | Use `.+` (any non-empty value), not `\.+`. `server/install-manager-rules.sh`'s own embedded `wazuh-logtest` self-check against `logtest-samples/yara-match.json` would have caught this — re-run it after applying the fix and confirm it now reports `[ OK ] yara-match.json -> rule 100700` |
| 5 | An occasional rule-100700 alert with a nonsense `yara_rule` value (something like `error:` or `yara:`, not a real signature-base rule name) shows up for a file that clearly wasn't malicious | The AR script decided match-vs-clean from whatever text `yara64.exe` printed, without checking its exit code. If YARA fails to actually scan the file — most often because it's still open/locked by whatever created it (a large copy into Downloads, an installer still writing, AV holding a transient lock) — it writes an error line to stderr instead of a clean "no match", and that error text got parsed as if it were a real match line | Check `$LASTEXITCODE` after the scan; only parse `$out` as match lines when it's `0`. When the scan didn't actually complete, emit nothing rather than guessing (in `active-response/yara-scan.ps1`) |

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

**Excluding a folder from scanning**: `yara-scan.ps1` reads
`C:\ProgramData\wazuh-toolkit\exclusions.txt` (one absolute folder per line) before
every scan and skips any file under a listed folder — no restart needed,
takes effect on the next trigger. Manage the list with
`endpoint-control\exclude.ps1 -Add "D:\path\to\folder"`,
which also pushes the same exclusion into FIM (so it stops triggering the
YARA active-response in the first place) — see that kit's own docs.

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `install-yara.ps1` fails to find a win64 release | GitHub API rate limit (unauthenticated, ~60 req/hour per source IP -- can matter when rolling out to many endpoints behind the same corporate egress address in a short window), or a future release also drops binaries | Wait a while for the rate limit to reset and re-run, or manually download a win64 build yourself and place `yara64.exe` at `C:\Program Files\YARA\yara64.exe` before running the script -- it skips the GitHub check entirely once that file already exists |
| Rules fail to compile | A rule needs an external variable this kit doesn't define | The install script auto-disables (`.disabled`) any rule file that fails to compile — check the "disabled(bad)" count in its output |
| `verify.ps1` shows "Manager has pushed yara-scan into ar.conf" = FAIL | Server-side `active-response-block.xml` not pasted in yet, or manager not restarted after | Complete section 3's manager steps |
| Nothing happens on a real file change | See section 6 — almost always bug #2 (stuck process) if it worked once and then stopped | Kill stuck processes, restart `WazuhSvc` |
| High CPU during a scan | Scanning a very large file against 416 rules | The AR script already skips files >100MB; lower that threshold in `yara-scan.ps1` if needed |
