# Suricata: Windows Endpoint Network IDS

Runs Suricata directly on a Windows endpoint to watch that machine's own traffic, and
forwards everything to Wazuh. A Windows adaptation of Wazuh's official
[Suricata Network IDS proof of concept](https://documentation.wazuh.com/current/proof-of-concept-guide/integrate-network-ids-suricata.html).

Gives you two things:

1. **Network visibility** — every domain resolved (DNS), every HTTPS site visited (TLS SNI),
   every cleartext URL (HTTP), plus JA3/JA4 client fingerprints.
2. **Intrusion detection** — ~52,000 Emerging Threats Open signatures plus local rules,
   graded by severity.

Single endpoint watching its own NIC. No switch mirroring, no SPAN/TAP. IDS only —
nothing here blocks traffic.

---

## Start here

| If you want to... | Read |
|---|---|
| **Deploy step by step** | **[../guides/ENDPOINT-SETUP-GUIDE.md § 2](../guides/ENDPOINT-SETUP-GUIDE.md#2-suricata-network-monitoring)** |
| Full reference: requirements, verification, tuning, troubleshooting | [INTEGRATION-GUIDE.md](INTEGRATION-GUIDE.md) |

---

## Folder layout

```
README.md
INTEGRATION-GUIDE.md        full deployment + troubleshooting guide
Run-Setup.cmd               full install, start to finish
Run-Verify.cmd              health check, changes nothing
scripts/
  Get-Prerequisites.ps1     downloads Npcap, the Suricata MSI and the ET Open ruleset into prereqs/
  00-preflight.ps1          checks Npcap, agent version, adapters
  01-fix-agent-version.ps1  only if the agent is newer than the manager
  02-install-suricata.ps1   installs Suricata + ruleset (-RefreshRulesOnly for updates)
  03-configure-suricata.ps1 HOME_NET, interfaces, eve.json, boot task + watchdog
  04-wire-wazuh-agent.ps1   points the agent at eve.json
  05-verify.ps1             [PASS]/[FAIL] checks
  06-disable-doh.ps1        makes DNS visible (reversible with -Revert)
  lib/common.ps1            shared helpers
config/
  local.rules               local Suricata signatures
  threshold.config          noise suppression
  eve-log-block.yaml        eve.json output block
  suricata-launch.ps1       boot/watchdog launcher
```

`prereqs/`, `logs/` and `state/` appear in this folder once you run something.
They hold downloads, transcripts and derived facts, and are safe to delete.

The **manager-side rules** (100200–100232) live in `suricata/` of
[wazuh-manager-toolkit](https://github.com/TanZero7/wazuh-manager-toolkit).
**That step is not optional.** Wazuh's built-in Suricata rules for DNS, TLS and HTTP
are level 0, meaning "decode then discard", so without the custom rules you get
signature alerts and no network visibility at all.

---

## Install (elevated Command Prompt)

```bat
cd suricata\scripts
powershell -ExecutionPolicy Bypass -File .\Get-Prerequisites.ps1
```

Install Npcap from `prereqs\` by hand, ticking **"WinPcap API-compatible Mode"**, then:

```bat
cd ..
powershell -ExecutionPolicy Bypass -File .\scripts\00-preflight.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\02-install-suricata.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\03-configure-suricata.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\04-wire-wazuh-agent.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\05-verify.ps1
```

> **If you get "running scripts is disabled on this system"**: that's PowerShell's
> default execution policy. `-ExecutionPolicy Bypass` (or the `.cmd` launchers) apply
> to that one process only and change nothing permanently.

---

## Check it's working

```
Run-Verify.cmd
```

To generate test traffic, use the manual triggers in
[INTEGRATION-GUIDE.md § 7.2](INTEGRATION-GUIDE.md#72--manual-triggers).
Then in the Wazuh dashboard: **Threat Hunting** → index `wazuh-alerts-*` → search
`rule.groups:suricata`.

| Query | Shows |
|---|---|
| `rule.groups:suricata` | everything from this integration |
| `rule.id:100220` | every HTTPS site visited (TLS SNI) |
| `rule.id:100210` | every domain resolved |
| `rule.level:>=7` | only things worth investigating |
| `data.tls.sni:*google*` | wildcard search on visited hostnames |

> **Set the dashboard to auto-refresh.** Use the time picker at the top right (next to the
> date range) and pick 5s or 10s. Wazuh does **not** auto-refresh by default, which is the
> usual reason people think the pipeline is delayed when it isn't.

---

## How fast is it?

Measured on this deployment, packet on the wire to visible in the dashboard:

| Hop | Latency |
|---|---|
| Packet → `eve.json` (Suricata) | 0.01–0.03 s |
| `eve.json` → alert on manager | ~0.5 s |
| Manager → searchable in dashboard | 4–9 s (index `refresh_interval` is 5s) |
| **Total** | **~5–10 s** |

To make the last hop faster, lower `refresh_interval` on the `wazuh-alerts-*` index from
5s to 1s — at the cost of more indexing load. 5–10s is already comfortably realtime for
network monitoring.

---

## Day-to-day

**Update signatures** (worth scheduling daily). Both steps are required — Windows Suricata
can't expand globs, so the explicit rule-file list has to be regenerated:

```
powershell -ExecutionPolicy Bypass -File .\scripts\02-install-suricata.ps1 -RefreshRulesOnly
powershell -ExecutionPolicy Bypass -File .\scripts\03-configure-suricata.ps1
```

**Is Suricata running?** It runs as a **scheduled task, not a service** — its native
`--service-install` creates a service that won't start on this build, so this toolkit uses a
SYSTEM scheduled task instead. `Get-Service Suricata` will find nothing.

```powershell
Get-ScheduledTask -TaskName 'Suricata IDS'
Get-Process suricata
```

**Turn it off:**

```powershell
Stop-ScheduledTask -TaskName 'Suricata IDS'
```

**Reduce noise** — three levers, least to most blunt:
1. Suppress a specific signature in `config\threshold.config`.
2. Add `<options>no_full_log</options>` to rules 100210/100220 on the server.
3. Drop the visibility rules to level 2 so they're counted but not alerted.

---

## Deploying to another Windows machine

Nothing is hardcoded to one host — the capture interface, its NPF GUID and `HOME_NET` are
all re-derived per machine. Copy this folder, run the steps above, done. The manager-side rules
are installed once and cover every endpoint.

Prerequisites on a new endpoint:
- **Npcap** installed in **WinPcap API-compatible mode** ([npcap.com](https://npcap.com/#download))
- A **Wazuh agent** enrolled, at a version **no newer than the manager**

---

## Known limitations

- **HTTPS hides URLs.** You get the hostname from SNI, never the path.
- **DNS-over-HTTPS hides DNS.** Run `scripts\06-disable-doh.ps1` (reversible with `-Revert`),
  then fully restart browsers. TLS SNI works either way.
- **Loopback is invisible.** Traffic to 127.0.0.1 never reaches Npcap, so scan detection needs
  a second machine: `nmap -sS -p 1-1000 <endpoint-ip>`.
- **Bridged VMs are also captured.** Their traffic crosses the host NIC, so it appears under
  this agent. Scope `HOME_NET` to a `/32` if you don't want that.
- **IDS, not IPS.** Nothing here blocks traffic.
