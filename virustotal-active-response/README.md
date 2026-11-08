# VirusTotal Active Response (endpoint half)

> **Order:** [manager side](https://github.com/TanZero7/wazuh-manager-toolkit/tree/main/virustotal) **first** → then this endpoint folder → then verify ([INTEGRATION-GUIDE.md § 3](INTEGRATION-GUIDE.md)).
> Every check prints `[PASS]`/`[FAIL]`; if something shows `[FAIL]`, wait **5–10 minutes after installation** and run it again before troubleshooting.

Wazuh's VirusTotal integration looks up the hash of every file FIM sees added or
changed. On its own it only **alerts** (rule 87105). This folder adds the
endpoint half of **Active Response**: when VirusTotal reports a file as malicious,
the manager tells the agent to run `remove-threat.exe`, which **deletes the file
automatically**, with no human approval step.

Confirmed working end-to-end on live endpoints:

```
554 file added  →  87105 VirusTotal positive  →  657 Active Response fired  →  553 file deleted
```

> ⚠️ Active Response deletes files automatically and irreversibly. Keeping
> VirusTotal alert-only is a perfectly reasonable choice; only wire this up
> fleet-wide if automatic deletion is what you want.

## Folder layout

```
README.md
scripts/
  install-active-response.ps1     copies bin\remove-threat.exe into the agent's active-response\bin
bin/
  PUT-remove-threat.exe-HERE.txt  how to build remove-threat.exe (not committed to git)
```

## Prerequisites

1. **Manager side first**: [wazuh-manager-toolkit → virustotal](https://github.com/TanZero7/wazuh-manager-toolkit/tree/main/virustotal)
   (VirusTotal integration + the Active Response block).
2. **FIM** installed on the endpoint ([../fim](../fim)), because VirusTotal is triggered by FIM events.
3. **`remove-threat.exe`** placed in `bin\`. See
   [`bin/PUT-remove-threat.exe-HERE.txt`](bin/PUT-remove-threat.exe-HERE.txt).
   Build it once and reuse the same binary on every PC.

## Install (elevated Command Prompt)

```bat
cd virustotal-active-response
powershell -ExecutionPolicy Bypass -File .\scripts\install-active-response.ps1
```

Expect a line ending in: `[OK] remove-threat.exe installed (…bytes).`

## Verify

Confirm the PASS checks and run the EICAR end-to-end test:
[INTEGRATION-GUIDE.md § 3](INTEGRATION-GUIDE.md#3-verification).
If a check fails right after installing, wait 5–10 minutes and run it again
(the manager pushes the Active Response config on its own cycle).

Step-by-step context: [../guides/ENDPOINT-SETUP-GUIDE.md § 3](../guides/ENDPOINT-SETUP-GUIDE.md#3-virustotal-active-response).

## Excluded folders

Folders excluded with [`endpoint-control\exclude.ps1`](../endpoint-control) never
produce a FIM event, so they never reach VirusTotal or this Active Response.
