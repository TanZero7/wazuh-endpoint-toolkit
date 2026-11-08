# Endpoint Setup Guide

**FIM · Suricata · VirusTotal Active Response**

Do every step in this guide, in order, on each PC. Every command is written out
exactly as it should be typed or pasted, so nothing needs changing unless a step
specifically says so. Commands never run on their own: you run each one yourself,
one line at a time.

> **If a command shows an error, stop and get help before moving on.**
> Exception: if a verify command ends with a red `[FAIL]` line, wait about
> 10 minutes and run that same command again before treating it as broken. Some
> checks read a status file that takes a few minutes to catch up right after a
> restart.

Sysmon and YARA have their own guide: [SYSMON-YARA-SETUP-GUIDE.md](SYSMON-YARA-SETUP-GUIDE.md).

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

- [ ] Signed in on this PC as `admin`. If that account doesn't exist yet, run
      [`local-admin-setup`](../local-admin-setup) first.
- [ ] A Wazuh agent is installed and enrolled against your manager
      (see [suricata/INTEGRATION-GUIDE.md § 4.2](../suricata/INTEGRATION-GUIDE.md)
      for the enrollment command).
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

Watches Desktop and Downloads for file changes. Set this up before Suricata.

**▸ Command Prompt (Run as administrator)**

```bat
cd "C:\Users\admin\Desktop\wazuh-endpoint-toolkit\fim"
powershell -ExecutionPolicy Bypass -File .\scripts\install-fim-scope.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\set-no-event-loss.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
```

The last command prints a list of `[PASS]`/`[FAIL]` lines, ending in
**"All checks passed."** if everything is correct. If it shows `[FAIL]` instead,
wait about 10 minutes and run just that last command again before treating it as
broken.

---

## 2. Suricata (network monitoring)

This one has a manual install screen partway through, because Npcap cannot be
installed silently.

The manager-side rules for Suricata are installed once, separately, from the
`suricata/` folder of
[wazuh-manager-toolkit](https://github.com/TanZero7/wazuh-manager-toolkit).
Without them you get signature alerts but no DNS/TLS/HTTP visibility.

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
powershell -ExecutionPolicy Bypass -File .\scripts\05-verify.ps1
```

> Run these five lines **one at a time, in this order**, and let each one finish
> before starting the next. This section takes longer than the others, because
> installing Suricata and loading the detection ruleset takes a few minutes.
> The last line prints `[PASS]`/`[FAIL]` lines, ending in
> **"Endpoint side is fully working."** if everything is correct. If it shows
> `[FAIL]` instead, wait about 10 minutes and run just the last line
> (`05-verify.ps1`) again before treating it as broken.

---

## 3. VirusTotal Active Response

The moment VirusTotal reports a file as malicious, this **deletes that file
automatically** on this PC, with no separate approval step.

Two prerequisites:

- The manager side is installed from the `virustotal/` folder of
  [wazuh-manager-toolkit](https://github.com/TanZero7/wazuh-manager-toolkit)
  (`add-virustotal-integration.sh`, then `add-virustotal-active-response.sh`).
- `remove-threat.exe` is in `virustotal-active-response\bin\`. It is not
  committed to this repo. See
  [`PUT-remove-threat.exe-HERE.txt`](../virustotal-active-response/bin/PUT-remove-threat.exe-HERE.txt)
  for how to build it once and reuse it on every PC.

**▸ Command Prompt (Run as administrator)**

```bat
cd "C:\Users\admin\Desktop\wazuh-endpoint-toolkit\virustotal-active-response"
powershell -ExecutionPolicy Bypass -File .\scripts\install-active-response.ps1
```

Expect a line ending in: `[OK] remove-threat.exe installed (…bytes).`

---

## 4. Finished: checklist for this PC

- [ ] FIM setup finished ("All checks passed.")
- [ ] Npcap installed, WinPcap-compatible mode ticked
- [ ] Suricata setup finished ("Endpoint side is fully working.")
- [ ] VirusTotal Active Response installed ("[OK] remove-threat.exe installed")
