# Sysmon & YARA Setup Guide (endpoint)

**Sysmon · YARA: endpoint steps and verification**

> **Install order: manager first, then endpoint, then verify**
>
> 1. **Manager side first**: [MANAGER-SETUP-GUIDE.md](https://github.com/TanZero7/wazuh-manager-toolkit/blob/main/guides/MANAGER-SETUP-GUIDE.md)
>    in wazuh-manager-toolkit (Sysmon: a quick rules check; YARA: rules + active-response block).
> 2. **Endpoint**: this guide, sections 1 and 2.
> 3. **Verify**: this guide, section 3.

Do every step in this guide, in order. Every command is written out exactly as it
should be typed or pasted, so nothing needs changing unless a step specifically
says so. Commands never run on their own: you run each one yourself, one line at
a time.

> **If a command shows an error, stop and get help before moving on.**
>
> ⏳ **PASS / FAIL rule:** if a check shows `[FAIL]`, wait **5–10 minutes after
> installation** and run the same check again before treating it as broken. Some
> checks read status files that only catch up a few minutes after a restart, and
> YARA's "Manager has pushed yara-scan into ar.conf" waits on the manager's own
> push cycle.

---

## How the commands in this guide work

Every command below is typed or pasted into **one Command Prompt window, opened
once as Administrator**, and kept open for the rest of this guide.

1. Click **Start**, type `cmd`.
2. Right-click **Command Prompt** in the results, click **Run as administrator**.
3. Click **Yes** on the Windows prompt that appears.

Copy and paste each line rather than retyping it, to avoid typos.

## Before you start

- [ ] **Manager side done** for Sysmon and YARA:
      [MANAGER-SETUP-GUIDE.md](https://github.com/TanZero7/wazuh-manager-toolkit/blob/main/guides/MANAGER-SETUP-GUIDE.md).
- [ ] Signed in on this PC as `admin`.
- [ ] This repository is at exactly this location on the PC:
      ```
      C:\Users\admin\Desktop\wazuh-endpoint-toolkit
      ```
- [ ] **FIM is already set up on this PC**, with all checks `[PASS]`. YARA's scan is
      triggered by FIM's own alerts (file added/changed in Desktop or Downloads), so
      do [ENDPOINT-SETUP-GUIDE.md § 1](ENDPOINT-SETUP-GUIDE.md#1-fim-file-integrity-monitoring) first.
- [ ] An internet connection on this PC, at least for part of this guide (Sysmon
      downloads its program and config; YARA downloads the YARA program and its
      rule pack).

---

## 1. Sysmon (endpoint)

Installs Sysinternals Sysmon with a well-tested open-source baseline config
(SwiftOnSecurity), watching process, network, file, and registry activity in
detail. Wazuh's built-in Sysmon ruleset on the manager does the detection.

**▸ Command Prompt (Run as administrator)**

```bat
cd "C:\Users\admin\Desktop\wazuh-endpoint-toolkit\sysmon"
powershell -ExecutionPolicy Bypass -File .\scripts\install-sysmon.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\wire-wazuh-agent.ps1
```

---

## 2. YARA (endpoint)

Content-based malware scanning. Every time FIM detects a file added or changed in
Desktop or Downloads, this PC automatically scans that specific file with YARA
against a curated open-source rule pack, and the result comes back as a Wazuh
alert: **rule 100700** for a match, **100701** for a clean scan. Unlike
VirusTotal Active Response, this only scans and reports. It does not delete or
move anything on its own.

**▸ Command Prompt (Run as administrator)**

```bat
cd "C:\Users\admin\Desktop\wazuh-endpoint-toolkit\yara"
powershell -ExecutionPolicy Bypass -File .\scripts\install-yara.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\wire-active-response.ps1
```

> `install-yara.ps1` needs internet: it downloads the YARA program itself and an
> open-source malware-rule pack. Look for `OK -- index compiles clean` near the end.

---

## 3. Verification

### 3.1 Sysmon: confirm the install (PASS / FAIL)

**▸ Command Prompt (Run as administrator)**

```bat
cd "C:\Users\admin\Desktop\wazuh-endpoint-toolkit\sysmon"
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
```

Expected, ending in **"All checks passed."**:

```
    [PASS] Sysmon service running
    [PASS] Sysmon driver registered
    [PASS] Operational log enabled
    [PASS] Recent Sysmon events present
    [PASS] Wazuh agent wired to Sysmon channel
    [PASS] Wazuh logcollector tailing the channel
```

If any line is `[FAIL]`: wait 5–10 minutes after installation and run it again.

Then run any command in a fresh `cmd.exe` and check the dashboard
(**Threat Hunting**, auto-refresh 5–10 s) for `rule.groups:sysmon_event1`.
**PASS** = alerts appear within seconds.

### 3.2 YARA: confirm the install (PASS / FAIL)

**▸ Command Prompt (Run as administrator)**

```bat
cd "C:\Users\admin\Desktop\wazuh-endpoint-toolkit\yara"
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
```

Expected, ending in **"All static checks passed."**:

```
    [PASS] YARA installed
    [PASS] Rule index present
    [PASS] Index compiles + scans without error
    [PASS] yara-scan.cmd deployed
    [PASS] yara-scan.ps1 deployed
    [PASS] Manager has pushed yara-scan into ar.conf
    [PASS] Results log exists
    [PASS] Agent wired to read the results log
```

If any line is `[FAIL]`: wait 5–10 minutes after installation and run it again.
If **"Manager has pushed yara-scan into ar.conf"** still fails after that, the
manager-side YARA steps aren't finished; go back to the
[manager guide](https://github.com/TanZero7/wazuh-manager-toolkit/blob/main/guides/MANAGER-SETUP-GUIDE.md).

### 3.3 YARA: live detection test

Only once 3.2 is all `[PASS]`. First add a one-line self-test rule so the marker
file is guaranteed to match (without it, the test file scans **clean** and you'll
see rule 100701 instead of 100700):

**▸ Command Prompt (Run as administrator)**

```bat
cd "C:\Program Files\YARA\rules"
powershell -Command "'rule Deployment_Selftest { strings: $m = \"WAZUHKIT_YARA_SELFTEST_MARKER_4f8a1c\" condition: $m }' | Set-Content .\deployment_selftest.yar -Encoding ascii"
powershell -Command "'include \"deployment_selftest.yar\"' | Add-Content .\index.yar -Encoding ascii"
```

> The scan compiles `index.yar` fresh on every file, so the new rule is live
> immediately. Don't use `install-yara.ps1 -RefreshRulesOnly` for this: it
> deletes every `.yar` in the rules folder and rebuilds `index.yar` from the
> downloaded pack, which wipes the self-test rule. (That also means the next
> rule refresh removes it automatically, so there's nothing to clean up later.)

Then drop a marker file into Downloads:

```bat
cd "%USERPROFILE%\Downloads"
powershell -Command "'WAZUHKIT_YARA_SELFTEST_MARKER_4f8a1c' | Set-Content .\selftest.txt"
```

Within about 15–20 seconds, search the dashboard for `rule.id:100700`.

| Result | Meaning |
|---|---|
| **PASS**: a rule **100700** alert for `selftest.txt` | Full chain works: FIM → manager → YARA scan → alert |
| **FAIL**: only **100701** (clean) | Chain works but the self-test rule wasn't loaded; redo the first block above |
| **FAIL**: nothing | Wait 5–10 minutes after installation and repeat with a new marker file; then see [yara/INTEGRATION-GUIDE.md](../yara/INTEGRATION-GUIDE.md#8-troubleshooting) |

Then clean up the test file:

```bat
cd "%USERPROFILE%\Downloads"
del selftest.txt
```

---

## 4. Finished: checklist

- [ ] Manager side done ([manager guide](https://github.com/TanZero7/wazuh-manager-toolkit/blob/main/guides/MANAGER-SETUP-GUIDE.md))
- [ ] Sysmon `verify.ps1`: "All checks passed."
- [ ] Sysmon alerts visible in the dashboard (`rule.groups:sysmon_event1`)
- [ ] YARA `verify.ps1`: "All static checks passed." (including the ar.conf line)
- [ ] YARA live test: rule 100700 alert seen for the marker file
