# FIM: File Integrity Monitoring (Desktop + Downloads)

Adds a standardized File Integrity Monitoring scope — Desktop and Downloads,
every user profile on the machine — to a Wazuh agent, realtime, with new-file
alerting on. This is the trigger event the other capabilities in this toolkit
(VirusTotal and YARA) key off.

---

## Start here

| If you want to... | Read |
|---|---|
| **Deploy this from scratch** | **[INTEGRATION-GUIDE.md](INTEGRATION-GUIDE.md)** |

## Folder layout

```
README.md
INTEGRATION-GUIDE.md      full deployment + troubleshooting guide
Run-Setup.cmd             runs the three scripts below in order
Run-Verify.cmd            health check, changes nothing
scripts/
  install-fim-scope.ps1   merges Desktop + Downloads into the agent's existing <syscheck>
  set-no-event-loss.ps1   disables the agent anti-flooding buffer (no dropped events)
  verify.ps1              [PASS]/[FAIL] checks
```

Nothing to *install* on the manager: Wazuh's built-in FIM rules (550
modified, 553 deleted, 554 added) handle alerting out of the box. The
`fim/check-fim-rules.sh` script in [wazuh-manager-toolkit](https://github.com/TanZero7/wazuh-manager-toolkit) only **verifies** that.

## Install

Follow **[../guides/ENDPOINT-SETUP-GUIDE.md § 1](../guides/ENDPOINT-SETUP-GUIDE.md#1-fim-file-integrity-monitoring)**
(elevated Command Prompt, one script at a time), or run `Run-Setup.cmd` as administrator.

## Check it's working

`scriptserify.ps1` (or `Run-Verify.cmd`), then create or edit a file in Desktop or
Downloads and watch the dashboard (`rule.groups:syscheck`). Expect an
alert within a couple of seconds.

## Known limitations

- Scope is intentionally narrow (Desktop + Downloads) to keep noise and
  scan time manageable — this is where a user or an attacker is most likely
  to drop a file, not a full-disk watch.
- Uses `realtime`, not `whodata` — see the header comment in
  `install-fim-scope.ps1` for why, and pair with [Sysmon](../sysmon) if you need
  "who made the change" attribution.
