# Sysmon & YARA Setup Guide

**Sysmon · YARA: endpoint and server, in that order**

Do every step in this guide, in order. Every command is written out exactly as it
should be typed or pasted, so nothing needs changing unless a step specifically
says so. Commands never run on their own: you run each one yourself, one line at
a time.

Both capabilities need work on **two machines**: this PC (the endpoint) and the
Wazuh manager (the server). Every command block below is tagged with which one it
goes on.

| Runs on | Comes from |
|---|---|
| Endpoint (Windows) | this repo: `sysmon/`, `yara/` |
| Manager (Linux) | [wazuh-manager-toolkit](https://github.com/TanZero7/wazuh-manager-toolkit): `sysmon/`, `yara/` |

> **If a command shows an error, stop and get help before moving on.**
> Exception: if a verify command ends with a red `[FAIL]` line, wait about
> 10 minutes and run that same command again before treating it as broken. Some
> checks read a status file that only catches up a few minutes after a restart.
> (YARA's manager-push check has its own version of this; see that section.)

---

## How the commands in this guide work

### On this PC (endpoint)

Every Windows command below is typed or pasted into **one Command Prompt window,
opened once as Administrator**, and kept open for the rest of this guide.

1. Click **Start**, type `cmd`.
2. Right-click **Command Prompt** in the results, click **Run as administrator**.
3. Click **Yes** on the Windows prompt that appears.

Keep that window open. Each section shows exactly which folder to move into first
(a `cd` command) and which commands to run there, in order, pressing Enter
after each line.

### On the Wazuh manager (server)

Open a terminal and connect to the manager once, then keep that session open for
the rest of this guide:

```bash
ssh <your-admin-login>@<WAZUH_MANAGER_IP>
```

Every manager command below already has `sudo` in front of it where it's needed.
Type your password when asked. Copy and paste each line rather than retyping it,
to avoid typos, on either machine.

## Before you start

- [ ] Signed in on this PC as `admin`.
- [ ] This repository is at exactly this location on the PC:
      ```
      C:\Users\admin\Desktop\wazuh-endpoint-toolkit
      ```
- [ ] **FIM is already set up on this PC.** YARA's scan is triggered by FIM's own
      alerts (file added/changed in Desktop or Downloads). If FIM isn't done yet on
      this machine, do that first ([ENDPOINT-SETUP-GUIDE.md § 1](ENDPOINT-SETUP-GUIDE.md#1-fim-file-integrity-monitoring)).
- [ ] An internet connection on this PC, at least for part of this guide (Sysmon
      downloads its program and config; YARA downloads the YARA program and its
      rule pack).
- [ ] SSH access to the Wazuh manager with `sudo` rights.
- [ ] On the manager, the server repo is cloned into your home folder:
      ```bash
      cd ~
      git clone https://github.com/TanZero7/wazuh-manager-toolkit.git
      ```
      (`~` is your home folder on the manager, wherever you land right after
      ssh'ing in.) Every manager command in this guide uses `~/wazuh-manager-toolkit`.

---

## 1. Sysmon

Installs Sysinternals Sysmon with a well-tested open-source baseline config
(SwiftOnSecurity), watching process, network, file, and registry activity in
detail. Wazuh already ships an extensive built-in ruleset for Sysmon, so there
is nothing custom to install on the manager for this one, only to confirm it's
there.

### 1.1 Endpoint

**▸ Command Prompt (Run as administrator)**

```bat
cd "C:\Users\admin\Desktop\wazuh-endpoint-toolkit\sysmon"
powershell -ExecutionPolicy Bypass -File .\scripts\install-sysmon.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\wire-wazuh-agent.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
```

The last command prints `[PASS]`/`[FAIL]` lines, ending in
**"All checks passed."** if everything is correct. If it shows `[FAIL]` instead,
wait about 10 minutes and run just that last command again before treating it as
broken.

### 1.2 Server (verification only, nothing to install)

The Sysmon detection rules ship with every Wazuh manager already. This just
confirms that's actually true on yours.

**▸ Wazuh manager (terminal via SSH, sudo required)**

```bash
cd ~/wazuh-manager-toolkit/sysmon
sudo bash check-sysmon-rules.sh
```

Expect it to report the built-in Sysmon rule files present and
`wazuh-analysisd` running.

---

## 2. YARA

Content-based malware scanning. Every time FIM detects a file added or changed in
Desktop or Downloads, this PC automatically scans that specific file with YARA
against a curated open-source rule pack, and the result (match or clean) comes
back as a Wazuh alert: **rule 100700** for a match, **100701** for a clean scan.
Unlike VirusTotal Active Response, this only scans and reports. It does not
delete or move anything on its own.

### 2.1 Endpoint

**▸ Command Prompt (Run as administrator)**

```bat
cd "C:\Users\admin\Desktop\wazuh-endpoint-toolkit\yara"
powershell -ExecutionPolicy Bypass -File .\scripts\install-yara.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\wire-active-response.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
```

> `install-yara.ps1` needs internet: it downloads the YARA program itself and an
> open-source malware-rule pack. The last command's
> **"Manager has pushed yara-scan into ar.conf"** line is expected to show
> `[FAIL]` at this point. It only turns `[PASS]` after the server steps below
> are done. Every other line should already show `[PASS]`.

### 2.2 Server: install the detection rules

**▸ Wazuh manager (terminal via SSH, sudo required)**

```bash
cd ~/wazuh-manager-toolkit/yara
sudo bash install-manager-rules.sh
```

This installs and validates the rules file only. Nothing fires yet: one more
manual step below actually connects FIM to YARA.

### 2.3 Server: wire the active-response block (manual step)

This one edit has to be done by hand, unlike the rules step above. It touches
the manager's main config file, which every other integration on the box also
depends on, so an automated edit here carries more risk than it's worth for one
12-line block.

1. On the manager, open the config file:

   **▸ Wazuh manager (terminal via SSH, sudo required)**

   ```bash
   cd /var/ossec/etc
   sudo nano ossec.conf
   ```

2. Inside the `<ossec_config>` section, near the other `<command>` definitions,
   paste this block exactly (it's also in `yara/active-response-block.xml` in the
   server repo):

   ```xml
   <command>
     <name>yara-scan</name>
     <executable>yara-scan.cmd</executable>
     <timeout_allowed>no</timeout_allowed>
   </command>
   <active-response>
     <disabled>no</disabled>
     <command>yara-scan</command>
     <location>local</location>
     <rules_id>550,554</rules_id>
   </active-response>
   ```

3. Save and exit (in nano: `Ctrl+O`, then `Enter`, then `Ctrl+X`).

Then **test the config before restarting**. Don't restart with a broken config:

**▸ Wazuh manager (terminal via SSH, sudo required)**

```bash
cd /var/ossec/etc
sudo /var/ossec/bin/wazuh-analysisd -t
sudo systemctl restart wazuh-manager
```

The first line should end by saying the configuration is OK. If it reports an
error instead, fix the pasted block before running the restart line.

### 2.4 Verify end-to-end

Back on this PC, run the same verify command from step 2.1 again:

**▸ Command Prompt (Run as administrator)**

```bat
cd "C:\Users\admin\Desktop\wazuh-endpoint-toolkit\yara"
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
```

> The **"Manager has pushed yara-scan into ar.conf"** line should now show
> `[PASS]`. The manager pushes this out on its own cycle, not instantly on
> restart. If it still shows `[FAIL]` right after the restart above, wait about
> 10 minutes and run `verify.ps1` again before treating it as broken.

#### Live detection test

To confirm a real detection actually reaches the manager, first add a one-line
self-test rule so the marker file is guaranteed to match (without it, the test
file scans **clean** and you'll see rule 100701 instead of 100700):

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

Then drop a marker file into Downloads on this PC:

**▸ Command Prompt (Run as administrator)**

```bat
cd "%USERPROFILE%\Downloads"
powershell -Command "'WAZUHKIT_YARA_SELFTEST_MARKER_4f8a1c' | Set-Content .\selftest.txt"
```

Within about 15–20 seconds, check the manager for the resulting alert:

**▸ Wazuh manager (terminal via SSH, sudo required)**

```bash
cd ~
grep -a "WAZUHKIT_YARA_SELFTEST" /var/ossec/logs/alerts/alerts.json
```

Expect a **rule 100700** alert. Then clean up the test file:

**▸ Command Prompt (Run as administrator)**

```bat
cd "%USERPROFILE%\Downloads"
del selftest.txt
```

---

## 3. Finished: checklist

- [ ] Sysmon endpoint setup finished ("All checks passed.")
- [ ] Sysmon manager check confirms the built-in rules are present
- [ ] YARA endpoint setup finished, including "Manager has pushed yara-scan into ar.conf" = `[PASS]`
- [ ] YARA manager rules installed (`install-manager-rules.sh`)
- [ ] YARA active-response block pasted into `ossec.conf`, config-tested clean, `wazuh-manager` restarted
- [ ] YARA live test confirmed: rule 100700 alert seen on the manager for the test marker file
