# YARA: Endpoint Integration Guide

> Content-based malware scanning, triggered automatically by Wazuh FIM via active-response.

> **Install order: manager first, then endpoint, then verify**
>
> 1. **Manager side**: [wazuh-manager-toolkit → yara](https://github.com/TanZero7/wazuh-manager-toolkit/tree/main/yara).
>    Installs rules 100700/100701 and the active-response block that tells agents to scan.
> 2. **Endpoint side**: this guide, [section 3](#3-install-endpoint).
> 3. **Verify**: this guide, [section 4](#4-verification). Only after steps 1 and 2 are done.
>
> Doing the manager first means the endpoint check "Manager has pushed yara-scan
> into ar.conf" can pass on the first run instead of failing until the manager is done.

| | |
|---|---|
| **YARA** | 4.5.5 (newest release with a prebuilt win64 zip: VirusTotal/yara stopped shipping Windows binaries from 4.5.6 onward; the install script walks releases backwards to find one that has them) |
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
| Manager side done | Rules + active-response block must exist for anything to fire | [wazuh-manager-toolkit → yara](https://github.com/TanZero7/wazuh-manager-toolkit/tree/main/yara) |
| [FIM](../fim) already installed on this endpoint | The trigger is FIM rules 550/554 | `fim\scripts\verify.ps1` all `[PASS]` |
| Administrator rights | Installing to Program Files, writing `ossec.conf` | `net session` |
| Internet access on the endpoint | Downloads YARA + the rule pack at install time | — |
| ~150 MB disk | YARA binary + rule pack | — |

## 3. Install (endpoint)

Open **Command Prompt as Administrator** and run, one line at a time:

```bat
cd yara
powershell -ExecutionPolicy Bypass -File .\scripts\install-yara.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\wire-active-response.ps1
```

(`Run-Setup.cmd` runs the same two scripts plus the check in section 4.1.)

- `install-yara.ps1` downloads `yara64.exe` and the signature-base pack, test-compiles
  every rule file (auto-disabling any that fail), and builds `rules\index.yar`.
  Watch its output for `OK -- index compiles clean`.
- `wire-active-response.ps1` copies `active-response\yara-scan.ps1/.cmd` into the
  agent's `active-response\bin\`, creates `C:\ProgramData\wazuh-toolkit\yara\`,
  and adds the results log as a `<localfile>` in `ossec.conf`.

## 4. Verification

### 4.1 Confirm the install (PASS / FAIL)

```bat
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
```

A good install looks like this, ending in **"All static checks passed."**:

```
==> VERDICT
    [PASS] YARA installed                              C:\Program Files\YARA\yara64.exe
    [PASS] Rule index present                          C:\Program Files\YARA\rules\index.yar
    [PASS] Index compiles + scans without error        exit=0
    [PASS] yara-scan.cmd deployed
    [PASS] yara-scan.ps1 deployed
    [PASS] Manager has pushed yara-scan into ar.conf
    [PASS] Results log exists                          C:\ProgramData\wazuh-toolkit\yara\yara-results.log
    [PASS] Agent wired to read the results log
```

> ⏳ **If any line shows `[FAIL]`, don't troubleshoot yet.** Wait **5–10 minutes
> after installation**, then run `verify.ps1` again. "Manager has pushed yara-scan
> into ar.conf" depends on the **manager** pushing its config out on its own
> cycle; it doesn't happen the instant anything restarts. Only treat it as broken
> if it still fails after the wait. If it keeps failing, the manager side isn't
> done yet: [wazuh-manager-toolkit → yara](https://github.com/TanZero7/wazuh-manager-toolkit/tree/main/yara).

### 4.2 Live end-to-end test (recommended)

4.1 only proves the pieces are in place. **It does not prove the trigger chain
actually fires**, so do this once 4.1 is all `[PASS]`.

**Step 1: add a self-test rule** so the marker file is guaranteed to match
(without it, the marker scans **clean** and you'll get rule 100701, not 100700).
In an elevated Command Prompt:

```bat
cd "C:\Program Files\YARA\rules"
powershell -Command "'rule Deployment_Selftest { strings: $m = \"WAZUHKIT_YARA_SELFTEST_MARKER_4f8a1c\" condition: $m }' | Set-Content .\deployment_selftest.yar -Encoding ascii"
powershell -Command "'include \"deployment_selftest.yar\"' | Add-Content .\index.yar -Encoding ascii"
```

The scan compiles `index.yar` fresh every time, so this is live immediately.
Don't use `install-yara.ps1 -RefreshRulesOnly` for this: it deletes every
`.yar` file in `rules\` before rebuilding, which wipes the self-test rule (and
also means the next refresh cleans it up for you).

**Step 2: drop a marker file** in a FIM-watched folder:

```bat
cd "%USERPROFILE%\Downloads"
powershell -Command "'WAZUHKIT_YARA_SELFTEST_MARKER_4f8a1c' | Set-Content .\selftest.txt"
```

**Step 3: check the result** within ~15–20 seconds, in the dashboard
(**Threat Hunting**, index `wazuh-alerts-*`, auto-refresh 5–10 s): search `rule.id:100700`.

| Result | Meaning |
|---|---|
| **PASS**: a rule **100700** alert (level 12, MITRE T1204.002) for `selftest.txt` | The full chain works: FIM → manager → YARA scan → alert |
| **FAIL**: only rule **100701** (clean) | The chain works but the self-test rule wasn't loaded; redo step 1 |
| **FAIL**: nothing at all | Wait 5–10 minutes after installation and repeat steps 2–3, then see sections 6 and 8 |

Clean up afterwards: `del "%USERPROFILE%\Downloads\selftest.txt"`.

### 4.3 In the dashboard

| Query | Shows |
|---|---|
| `rule.groups:yara_alert` | confirmed matches |
| `rule.id:100700` | matches only |
| `rule.id:100701` | clean scans (proves the whole chain ran even with no hit) |
| `data.yara_scanned_file:*` | searchable file path field |

## 5. Observed on a real deployment (11 Sep 2026)

3 independent files, each containing a deliberate marker string, all
produced correctly-classified rule 100700 alerts within seconds of being
written to Downloads, confirming the full chain end to end.

## 6. Windows-specific gotchas (found and fixed during this build)

None of these are documented anywhere obvious; all cost real debugging time
and are already fixed in this kit. If you ever rewrite the affected file from
scratch, you will hit them again.

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | Script runs, logs "done", but the results file never gets a new line, and later runs seem to silently stop happening entirely | `Add-Content` to the results log throws "being used by another process" (Wazuh's logcollector holds it open to tail it), and under `$ErrorActionPreference='SilentlyContinue'` that error is swallowed completely, with no trace anywhere | Open the file explicitly: `[System.IO.File]::Open($logFile, 'Append', 'Write', [System.IO.FileShare]::ReadWrite)` instead of `Add-Content` (in `active-response/yara-scan.ps1`) |
| 2 | The manager confirms (in debug logs) it sent the active-response command, but **nothing ever happens on the agent**, for every single trigger from then on, even much later ones | The AR script reads stdin with `[Console]::In.ReadToEnd()`, which blocks forever: `wazuh-execd` keeps the pipe open (in case a later revert/"delete" message follows for timeout-based commands) and never sends EOF. The hung process then occupies execd's worker slot, silently blocking **every subsequent** active-response trigger until it's killed or the agent restarts | Use `[Console]::In.ReadLine()`: the AR payload is one newline-terminated JSON line, with no need to wait for the stream to close (in `active-response/yara-scan.ps1`) |
| 3 | A script written against generic Wazuh AR examples checks `if ($json.command -ne 'add') { exit }` and never runs | Those examples are for timeout/revert-style commands, where `command` really is `"add"`/`"delete"`. For a plain command with no `<timeout>` in the active-response block (this kit's design), the `command` field is the **AR name itself with a numeric suffix** (e.g. `"yara-scan0"`), not the literal string `"add"` | Don't filter on `command == 'add'`. If you ever add a `<timeout>` and need to ignore the revert call, match `$json.command -match '^delete'` instead (in `active-response/yara-scan.ps1`) |
| 4 | Everything on the endpoint passes and `yara-results.log` fills with real `"match"` lines, but **no rule 100700 alert ever appears** | Manager-side regex mistake: in Wazuh's OS_Regex a bare `.` is a *literal dot*, so `<field name="yara_rule">.+</field>` can never match a real YARA rule name | Manager side: the pattern must be `\.+` (OS_Regex for "any non-empty value"). See [wazuh-manager-toolkit → yara](https://github.com/TanZero7/wazuh-manager-toolkit/tree/main/yara) |
| 5 | An occasional rule-100700 alert with a nonsense `yara_rule` value (something like `error:` or `yara:`, not a real signature-base rule name) shows up for a file that clearly wasn't malicious | The AR script decided match-vs-clean from whatever text `yara64.exe` printed, without checking its exit code. If YARA fails to actually scan the file (most often because it's still open/locked by whatever created it: a large copy into Downloads, an installer still writing, AV holding a transient lock), it writes an error line to stderr instead of a clean "no match", and that error text got parsed as if it were a real match line | Check `$LASTEXITCODE` after the scan; only parse `$out` as match lines when it's `0`. When the scan didn't actually complete, emit nothing rather than guessing (in `active-response/yara-scan.ps1`) |

If your AR script seems "not firing" and none of the above explains
it, check for a stuck process first. Bug #2 above leaves a permanently
hung `cmd.exe` -> `powershell.exe` pair that silently jams every future
trigger:

```powershell
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'yara-scan' } |
    Select-Object ProcessId,CreationDate,CommandLine
```

Kill any that are more than a few seconds old, then restart `WazuhSvc`.

## 7. Day-to-day

**Refresh the rule pack** (worth scheduling monthly-ish, since signature-base
updates periodically):
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-yara.ps1 -RefreshRulesOnly
```

> ⚠️ A refresh **deletes every `*.yar*` file in `C:\Program Files\YARA\rules\`**
> (including any `.disabled` ones), re-copies the pack, and rebuilds `index.yar`
> from scratch. Anything you added or disabled by hand in that folder is undone.

**Add your own rule**: keep it *outside* the rules folder so a refresh can't
delete it, e.g. `C:\Program Files\YARA\custom\my_rule.yar`, then append an
include to the index:
```powershell
Add-Content 'C:\Program Files\YARA\rules\index.yar' 'include "C:/Program Files/YARA/custom/my_rule.yar"' -Encoding ascii
```
Live immediately. Re-append that line after every refresh, because the refresh
rebuilds `index.yar`.

**Tuning false positives**: signature-base rules occasionally fire on
legitimate admin/pentest tooling (that's largely the point of some of them,
e.g. Mimikatz-family detections). Rename the noisy file in `rules\` to
`<name>.yar.disabled` and remove its `include` line from `index.yar`. Redo
this after every refresh.

**Excluding a folder from scanning**: `yara-scan.ps1` reads
`C:\ProgramData\wazuh-toolkit\exclusions.txt` (one absolute folder per line) before
every scan and skips any file under a listed folder. No restart needed; it
takes effect on the next trigger. Manage the list with
`endpoint-control\exclude.ps1 -Add "D:\path\to\folder"`,
which also pushes the same exclusion into FIM (so it stops triggering the
YARA active-response in the first place). See [endpoint-control](../endpoint-control).

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `verify.ps1` shows "Manager has pushed yara-scan into ar.conf" = `[FAIL]` | Manager pushes `ar.conf` on its own cycle, or the manager side isn't done | Wait 5–10 minutes and re-run `verify.ps1`; if still failing, complete [the manager side](https://github.com/TanZero7/wazuh-manager-toolkit/tree/main/yara) |
| `install-yara.ps1` fails to find a win64 release | GitHub API rate limit (unauthenticated, ~60 req/hour per source IP, which can matter when rolling out to many endpoints behind the same egress address in a short window), or a future release also drops binaries | Wait for the rate limit to reset and re-run, or manually download a win64 build and place `yara64.exe` at `C:\Program Files\YARA\yara64.exe` before running the script; it skips the GitHub check once that file exists |
| Rules fail to compile | A rule needs an external variable this kit doesn't define | The install script auto-disables (`.disabled`) any rule file that fails to compile; check the "disabled(bad)" count in its output |
| Live test gives 100701 (clean) instead of 100700 | Self-test rule not loaded | Redo section 4.2 step 1 |
| Endpoint log has `"match"` lines but no 100700 alert | Manager rule pattern (see gotcha #4) | Re-run the manager installer from [wazuh-manager-toolkit → yara](https://github.com/TanZero7/wazuh-manager-toolkit/tree/main/yara) and confirm `[ OK ] yara-match.json -> rule 100700` |
| Nothing happens on a real file change | See section 6: almost always bug #2 (stuck process) if it worked once and then stopped | Kill stuck processes, restart `WazuhSvc` |
| High CPU during a scan | Scanning a very large file against 416 rules | The AR script already skips files >100MB; lower that threshold in `yara-scan.ps1` if needed |
