# Endpoint Setup Guide

**FIM · Suricata · VirusTotal Active Response: endpoint steps and verification**

> **Install order: manager first, then endpoint, then verify**
>
> 1. **Manager side first**: [MANAGER-SETUP-GUIDE.md](https://github.com/TanZero7/wazuh-manager-toolkit/blob/main/guides/MANAGER-SETUP-GUIDE.md)
>    in wazuh-manager-toolkit (FIM check, Suricata rules, VirusTotal integration).
> 2. **Endpoint**: this guide, sections 1–3, on each PC.
> 3. **Verify**: section 4, after the endpoint installs are done.

Sysmon and YARA have their own guide: [SYSMON-YARA-SETUP-GUIDE.md](SYSMON-YARA-SETUP-GUIDE.md).

Do every step in this guide, in order, on each PC. Every command is written out
exactly as it should be typed or pasted, so nothing needs changing unless a step
specifically says so. Commands never run on their own: you run each one yourself,
one line at a time.

> **If a command shows an error, stop and get help before moving on.**
>
> ⏳ **PASS / FAIL rule:** if a verify check shows `[FAIL]`, wait **5–10 minutes
> after installation** and run the same check again before treating it as broken.
> Several checks read status files that only catch up a few minutes after the
> agent restarts.

---

## How the commands in this guide work

Every command below is typed or pasted into **one Command Prompt window, opened
once as Administrator**, and kept open for the rest of this guide.

1. Click **Start**, type `cmd`.
2. Right-click **Command Prompt** in the results, click **Run as administrator**.
3. Click **Yes** on the Windows prompt that appears.

Keep that window open. Each section below shows exactly which folder to move into
first (a `cd` command) and which commands to run there, in order, pressing
Enter after each line. Copy and paste each line rather than retyping it, to avoid
typos.

> Each folder also has a `Run-Setup.cmd` that runs the same scripts in one go.
> This guide deliberately types each script by hand instead, because the `.cmd`
> wrappers were seen not to fire reliably on double-click in the field.

## Before you start

- [ ] **Manager side done**:
      [MANAGER-SETUP-GUIDE.md](https://github.com/TanZero7/wazuh-manager-toolkit/blob/main/guides/MANAGER-SETUP-GUIDE.md).
      Note the **manager version** its Suricata step prints: the agent on this PC
      must be no newer.
- [ ] Signed in on this PC as `admin`. If that account doesn't exist yet, run
      [`local-admin-setup`](../local-admin-setup) first.
- [ ] A Wazuh agent is installed and enrolled against your manager
      (see [suricata/INTEGRATION-GUIDE.md § 3.2](../suricata/INTEGRATION-GUIDE.md#32--install-and-enroll-the-wazuh-agent)).
- [ ] This repository is at exactly this location:
      ```
      C:\Users\admin\Desktop\wazuh-endpoint-toolkit
      ```
      If it isn't there yet, copy it there now. Every command in this guide uses
      this exact location.
- [ ] An internet connection, at least for part of this guide (needed in
      Section 2 to fetch Suricata's installer files).

---

## 1. FIM (File Integrity Monitoring)

Watches Desktop and Downloads for file changes. Set this up first: YARA and
VirusTotal are both triggered by FIM.

**▸ Command Prompt (Run as administrator)**

```bat
cd "C:\Users\admin\Desktop\wazuh-endpoint-toolkit\fim"
powershell -ExecutionPolicy Bypass -File .\scripts\install-fim-scope.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\set-no-event-loss.ps1
```

---

## 2. Suricata (network monitoring)

This one has a manual install screen partway through, because Npcap cannot be
installed silently.

### 2.1 Download Suricata's installer files

This needs internet on this PC. It downloads a few files (including the Npcap
installer) into a new `prereqs` folder.

**▸ Command Prompt (Run as administrator)**

```bat
cd "C:\Users\admin\Desktop\wazuh-endpoint-toolkit\suricata\scripts"
powershell -ExecutionPolicy Bypass -File .\Get-Prerequisites.ps1
```

Wait for it to finish. It lists each file as "downloaded" or "present". This
can take a few minutes depending on the connection.

### 2.2 Install Npcap (manual step)

1. Open File Explorer, paste this into the address bar, then press Enter:
   ```
   C:\Users\admin\Desktop\wazuh-endpoint-toolkit\suricata\prereqs
   ```
2. Double-click the Npcap installer (`npcap-<version>.exe`).
3. Click through the installer. On the options screen, tick
   **"Install Npcap in WinPcap API-compatible Mode."** Leave every other option
   as-is.
4. Click **Install**, then **Finish**.

### 2.3 Install and start Suricata

**▸ Command Prompt (Run as administrator)**

```bat
cd "C:\Users\admin\Desktop\wazuh-endpoint-toolkit\suricata"
powershell -ExecutionPolicy Bypass -File .\scripts\00-preflight.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\02-install-suricata.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\03-configure-suricata.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\04-wire-wazuh-agent.ps1
```

> Run these four lines **one at a time, in this order**, and let each one finish
> before starting the next. This section takes longer than the others, because
> installing Suricata and loading the detection ruleset takes a few minutes.
> Resolve anything `00-preflight.ps1` reports before continuing.

---

## 3. VirusTotal Active Response

The moment VirusTotal reports a file as malicious, this **deletes that file
automatically** on this PC, with no separate approval step. Skip this section
to keep VirusTotal alert-only.

Prerequisite: `remove-threat.exe` is in `virustotal-active-response\bin\`. It is
not committed to this repo; see
[`PUT-remove-threat.exe-HERE.txt`](../virustotal-active-response/bin/PUT-remove-threat.exe-HERE.txt)
for how to build it once and reuse it on every PC.

**▸ Command Prompt (Run as administrator)**

```bat
cd "C:\Users\admin\Desktop\wazuh-endpoint-toolkit\virustotal-active-response"
powershell -ExecutionPolicy Bypass -File .\scripts\install-active-response.ps1
```

---

## 4. Verification

Run these only after sections 1–3 are done.

### 4.1 FIM (PASS / FAIL)

```bat
cd "C:\Users\admin\Desktop\wazuh-endpoint-toolkit\fim"
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
```

Expected, ending in **"All checks passed."**:

```
    [PASS] ossec.conf has the FIM scope
    [PASS] Realtime engine started (recent log)
    [PASS] Agent confirms watching a Desktop path
```

If any line is `[FAIL]`: wait 5–10 minutes after installation and run it again.
Then create a file on the Desktop and check the dashboard for `rule.id:554`.

### 4.2 Suricata (PASS / FAIL)

```bat
cd "C:\Users\admin\Desktop\wazuh-endpoint-toolkit\suricata"
powershell -ExecutionPolicy Bypass -File .\scripts\05-verify.ps1
```

Expected, ending in **"Endpoint side is fully working."**:

```
    [PASS] Suricata running
    [PASS] eve.json growing
    [PASS] DNS visibility
    [PASS] TLS visibility
    [PASS] Agent tailing eve.json
    [PASS] Agent connected
```

If any line is `[FAIL]`: wait 5–10 minutes after installation and run it again.
Then browse to any website and check the dashboard for `rule.groups:suricata`.

### 4.3 VirusTotal Active Response (PASS / FAIL)

The install step should have printed `[OK] remove-threat.exe installed (…bytes).`
Then confirm the manager has pushed the config to this PC:

```bat
powershell -Command "Select-String remove-threat 'C:\Program Files (x86)\ossec-agent\shared\ar.conf'"
```

**PASS** = a line containing `remove-threat`. If nothing prints, wait 5–10 minutes
after installation and run it again. For the full EICAR end-to-end test, see
[virustotal-active-response/INTEGRATION-GUIDE.md § 3.2](../virustotal-active-response/INTEGRATION-GUIDE.md#32-live-test-with-eicar).

---

## 5. Finished: checklist for this PC

- [ ] Manager side done ([manager guide](https://github.com/TanZero7/wazuh-manager-toolkit/blob/main/guides/MANAGER-SETUP-GUIDE.md))
- [ ] FIM `verify.ps1`: "All checks passed."
- [ ] Npcap installed, WinPcap-compatible mode ticked
- [ ] Suricata `05-verify.ps1`: "Endpoint side is fully working."
- [ ] VirusTotal Active Response: `[OK] remove-threat.exe installed` and `remove-threat` present in `ar.conf`
