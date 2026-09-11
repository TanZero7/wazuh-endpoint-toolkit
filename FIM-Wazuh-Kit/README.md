# File Integrity Monitoring (Desktop + Downloads) — Wazuh Kit

Adds a standardized File Integrity Monitoring scope — Desktop and Downloads,
every user profile on the machine — to a Wazuh agent, realtime, with new-file
alerting on. This is the trigger event three other kits in this family
(VirusTotal, Offline Hash Blocklist, YARA) all key off.

---

## Start here

| If you want to... | Read |
|---|---|
| **Deploy this from scratch** | **[INTEGRATION-GUIDE.md](INTEGRATION-GUIDE.md)** |
| Understand what it does | `docs/FIM-PoC.md` |

## Folder layout

```
INTEGRATION-GUIDE.md
docs/FIM-PoC.md
endpoint/
  Run-Setup.cmd    <- double-click this
  Run-Verify.cmd
  scripts/         install-fim-scope.ps1, verify.ps1
server/
  check-fim-rules.sh   verifies the built-in FIM ruleset — nothing to install
```

Nothing to *install* on the server — Wazuh's built-in FIM rules (550
modified, 553 deleted, 554 added) handle alerting out of the box. `server/`
exists to **verify** that, not to add anything custom.

## Install

**Endpoint**: `endpoint\Run-Setup.cmd` as administrator.
**Server** (optional, confirms the built-in rules are present): `sudo bash server/check-fim-rules.sh`.

## Check it's working

`endpoint\Run-Verify.cmd`, then create or edit a file in Desktop or
Downloads and watch the dashboard (`rule.groups:syscheck`) — expect an
alert within a couple of seconds.

## Known limitations

- Scope is intentionally narrow (Desktop + Downloads) to keep noise and
  scan time manageable — this is where a user or an attacker is most likely
  to drop a file, not a full-disk watch.
- Uses `realtime`, not `whodata` — see the header comment in
  `install-fim-scope.ps1` for why, and pair with the Sysmon kit if you need
  "who made the change" attribution.
