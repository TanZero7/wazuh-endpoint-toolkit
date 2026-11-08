# VirusTotal Active Response (endpoint half)

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

1. **Manager side first**, from `virustotal/` in
   [wazuh-manager-toolkit](https://github.com/TanZero7/wazuh-manager-toolkit):
   `add-virustotal-integration.sh <API_KEY>`, then `add-virustotal-active-response.sh`,
   and optionally `install-manager-rules.sh` (rules 100092/100093: clear
   success/failure alerts with the file path).
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

Step-by-step context: [../guides/ENDPOINT-SETUP-GUIDE.md § 3](../guides/ENDPOINT-SETUP-GUIDE.md#3-virustotal-active-response).

## Excluded folders

Folders excluded with [`endpoint-control\exclude.ps1`](../endpoint-control) never
produce a FIM event, so they never reach VirusTotal or this Active Response.
