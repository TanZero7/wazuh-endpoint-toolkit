# USB Storage Monitor — Integration Guide

> Turning Windows' own disk-connection logging into a readable Wazuh alert.

| | |
|---|---|
| **Source channel** | `Microsoft-Windows-Partition/Diagnostic`, Event ID 1006 |
| **Filter field** | `win.eventdata.busType` = `7` (USB) |
| **Wazuh** | 4.x agent + manager |
| **Endpoint** | Windows 10/11 |

## 1. Overview

Every time Windows enumerates a disk — at boot, or when one is connected —
it logs a detailed event (ID 1006) to `Microsoft-Windows-Partition/Diagnostic`,
including bus type, model, serial number, and capacity. This fires for
**every disk**, internal SATA/NVMe drives included, not just removable ones
— the bus type field (`7` = USB) is what separates "a real USB stick was
plugged in" from "the machine booted and enumerated its own SSD."

## 2. Requirements

| Requirement | Why | Check |
|---|---|---|
| Administrator rights | `wevtutil sl`, editing `ossec.conf` | `net session` |
| Wazuh agent already enrolled | This kit only adds a `<localfile>` | `Get-Service WazuhSvc` |

## 3. Install

```powershell
cd USB-Monitor-Wazuh-Kit\endpoint
powershell -ExecutionPolicy Bypass -File .\scripts\wire-usb-channel.ps1
```

Server:
```bash
cd server
sudo bash install-manager-rules.sh
```

## 4. Verification

```
endpoint\Run-Verify.cmd
```

This proves the channel is on and the agent is reading it — **it cannot
prove the rule actually fires**, because (see the note in
`server/install-manager-rules.sh`) `wazuh-logtest` doesn't run the same
eventchannel pre-decoding pass a live agent does, so there's no reliable way
to synthetically test this one. The only real proof:

1. Plug a USB flash drive into the endpoint.
2. Within a few seconds, check the manager:
   ```bash
   grep -a "USB storage connected" /var/ossec/logs/alerts/alerts.json
   ```
   or in the dashboard: `rule.groups:usb_connected`.

## 5. In the dashboard

| Query | Shows |
|---|---|
| `rule.groups:usb_connected` | every USB storage connect event |
| `rule.id:100600` | the device-details alert (model, serial, capacity) |
| `data.win.eventdata.serialNumber:*` | searchable device serial field |

## 6. Optional: also track it in the registry

Windows also records every USB mass-storage device it has *ever* seen under
`HKLM\SYSTEM\CurrentControlSet\Enum\USBSTOR`. If you also run FIM registry
monitoring on that key (add it to your `<syscheck>` config with
`<windows_registry>` — not included in this kit by default, since it's a
historical record rather than a live connect/disconnect signal), rule
100601 in this kit's ruleset will pick up the first-time appearance of a new
device there too.

## 7. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Channel won't enable | Not elevated | Run as Administrator |
| Alert never fires despite a real USB insert | Agent not wired, or manager rules not installed | Re-run both `wire-usb-channel.ps1` and `server/install-manager-rules.sh` |
| Alert fires for a device you know is NOT USB | `busType` numbering can vary slightly by driver/chipset in rare cases | Check `data.win.eventdata.busType` in the raw alert and adjust the rule's filter if your hardware reports differently |
