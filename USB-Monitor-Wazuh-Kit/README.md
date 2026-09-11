# USB Storage Monitor — Wazuh Kit

Points Wazuh at a Windows event channel that already logs every disk
connection (internal and removable), and adds a rule that filters it down
to USB mass-storage devices only, formatted as a readable alert with the
device model, serial number, and capacity.

No new agent, no new driver — this is Windows' own existing logging,
switched on and read.

---

## Start here

| If you want to... | Read |
|---|---|
| **Deploy this from scratch** | **[INTEGRATION-GUIDE.md](INTEGRATION-GUIDE.md)** |
| Understand what it does | `docs/USB-Monitor-PoC.md` |

---

## Folder layout

```
INTEGRATION-GUIDE.md     HOW TO DEPLOY THIS  <- start here
docs/
  USB-Monitor-PoC.md
endpoint/
  Run-Setup.cmd             <- double-click this
  Run-Verify.cmd
  scripts/                  wire-usb-channel.ps1, verify.ps1
server/
  install-manager-rules.sh
  local_rules_usb.xml        rules 100600/100601
```

## Install

**Endpoint**: `endpoint\Run-Setup.cmd` as administrator.
**Server**: `sudo bash server/install-manager-rules.sh`.

## Check it's working

```
endpoint\Run-Verify.cmd
```

**This integration can only be fully proven with a real USB device** — plug
one in, then check `rule.groups:usb_connected` in the dashboard.

## Known limitations

- Fires on **connect**, not disconnect — Windows' Partition/Diagnostic
  channel doesn't log removal events the same way.
- "Basic" by design: model/serial/capacity, not file-level tracking of what
  was copied to/from the device. Pair with the FIM kit if you also want to
  know what files moved.
