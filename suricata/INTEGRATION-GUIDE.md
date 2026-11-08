# Suricata + Wazuh Integration Guide

> Step-by-step deployment of Suricata network IDS on a Windows endpoint, forwarding DNS, TLS and HTTP telemetry plus intrusion alerts to a Wazuh server.

| | |
|---|---|
| **Suricata** | 8.0.6 (Windows MSI) |
| **Wazuh** | 4.14.7 — manager and agent must match, or manager newer |
| **Npcap** | 1.87, WinPcap API-compatible mode |
| **Endpoint** | Windows 10 1803+ / Windows 11 |
| **Server** | Ubuntu 22.04+ with Wazuh manager, indexer, dashboard |
| **Mode** | IDS — observes and alerts, never blocks traffic |
| **Verified** | 20 August 2026 |


## 1. Overview

This guide deploys Suricata directly on a Windows endpoint so it inspects that machine's own network traffic, and forwards every event to a Wazuh server. It is a Windows adaptation of Wazuh's official Suricata Network IDS proof of concept.

**Scope.** One endpoint watching its own network adapters. No switch mirroring, no SPAN or TAP ports, no sensor appliance. Strictly **IDS** — nothing here blocks traffic.

**What you get when finished:**

- **Network visibility** — every domain resolved (DNS), every HTTPS site visited (TLS SNI), every cleartext URL (HTTP), plus JA3/JA4 TLS client fingerprints.
- **Intrusion detection** — roughly 52,000 Emerging Threats Open signatures plus local rules, graded by the severity Suricata assigns rather than flattened to one level.
- **Continuous operation** — capture on all physical adapters at once, automatic start at boot, and a watchdog that restarts capture if it stops or the adapter set changes.

> 🛑 **Read section 6 before you skip it**
>
> Wazuh's built-in Suricata rules for DNS, TLS and HTTP are level 0, which means decoded then discarded. Without the custom rules in section 6 you get signature alerts and NO network visibility at all, with no error to explain why. That step is not optional.


## 2. Infrastructure

| Role | System | Address | Components |
|---|---|---|---|
| Monitored endpoint | Windows 11 | DHCP or static | Suricata 8.0.6, Npcap 1.87, Wazuh agent |
| Wazuh server | Ubuntu 22.04+ | Static recommended | Wazuh manager, indexer, dashboard |

> ⚠️ **Give the server a static address**
>
> The agent connects to the manager by IP. If the server's address changes, every agent silently stops reporting until reconfigured. Use a static IP or a DHCP reservation. During this deployment the server's DHCP lease changed three times and each change broke the agent link until re-pointed.


## 3. Requirements


### On the Windows endpoint

| Requirement | Why | Check |
|---|---|---|
| Administrator rights | Installing services, editing Program Files | net session |
| Npcap in WinPcap API-compatible mode | Suricata's packet capture layer | See section 4.1 |
| Wazuh agent, version <= manager | A newer agent is refused by the manager | VERSION.json |
| Windows 10 1803 or later | Ships bsdtar, used to unpack the ruleset | tar --version |
| ~2 GB free disk | Ruleset, logs, rotated eve.json | — |
| ~250 MB RAM available | Suricata with 52k rules loaded | — |


### On the Wazuh server

- Wazuh manager 4.x running, with `wazuh-analysisd` and `wazuh-remoted` active.
- Root access, to install the custom rules file and restart the manager.
- TCP **1514** (agent events) and **1515** (enrollment) reachable from the endpoint.


### Version compatibility

Wazuh requires **manager version >= agent version**. A manager refuses an agent newer than itself, and the agent will appear enrolled but never report. Confirm the manager version first and match the agent to it:

```bash
sudo /var/ossec/bin/wazuh-control info
```


## 4. Endpoint installation

> ⚠️ **"Running scripts is disabled on this system"**
>
> PowerShell blocks .ps1 files by default. The kit ships .cmd launchers that pass -ExecutionPolicy Bypass for that one process, changing nothing permanently. To run a script directly instead, prefix it: powershell -ExecutionPolicy Bypass -File .\scripts\05-verify.ps1


### 4.1  Install Npcap

Download from npcap.com and install with **"Install Npcap in WinPcap API-compatible Mode"** ticked. Without that option Suricata cannot open the adapter. Verify:

```bash
reg query "HKLM\SOFTWARE\WOW6432Node\Npcap" /v WinPcapCompatible
# expect: WinPcapCompatible    REG_DWORD    0x1
```


### 4.2  Install and enroll the Wazuh agent

Install the agent matching your manager version, then enroll it against your Wazuh
manager (<WAZUH_MANAGER_IP>) — confirm the manager's actual Wazuh version first
(`sudo /var/ossec/bin/wazuh-control info` on <WAZUH_MANAGER_IP>) and match the MSI version below to
it; the lab used 4.14.7, production may differ:

```bash
msiexec /i wazuh-agent-<version>-1.msi /q ^
  WAZUH_MANAGER="<WAZUH_MANAGER_IP>" ^
  WAZUH_AGENT_NAME="<real-hostname-or-naming-convention>"

net start WazuhSvc
```

Confirm on the server that the agent appears and is Active:

```bash
sudo /var/ossec/bin/agent_control -l
```


### 4.3  Run preflight

Read-only. Confirms Npcap, picks the capture adapters, derives HOME_NET, reports the agent version and which manager it targets, and tests reachability.

```powershell
cd suricata
powershell -ExecutionPolicy Bypass -File .\scripts\00-preflight.ps1
```

Resolve anything it reports before continuing.


### 4.4  Install Suricata and the ruleset

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\02-install-suricata.ps1
```

Installs the Suricata MSI, downloads roughly 52,000 Emerging Threats Open signatures, and **sanitises them for the Windows build**. The sanitise pass is essential:

- The official Windows build reports `Libmagic support: no`, so every rule using `file.magic` is a parse error. Nine ET rules are commented out.
- The stock config disables the DNP3, Modbus and ENIP parsers, and a rule for a disabled protocol is a **fatal** error, not a skipped rule. Those three SCADA rule files are disabled.

> 🛑 **Why this matters**
>
> Suricata does not skip unloadable rules. A handful of them aborts the entire ruleset with "Loading signatures failed", leaving you with zero detection.


### 4.5  Configure Suricata and start capture

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\03-configure-suricata.ps1 ^
  -HomeNet "192.168.0.0/16,10.0.0.0/8,172.16.0.0/12" 
```

This patches `suricata.yaml`, validates it with `suricata -T`, installs the capture launcher, and registers the scheduled tasks. Key settings and the reason for each:

| Setting | Value | Reason |
|---|---|---|
| HOME_NET | RFC1918 ranges | 88% of signatures reference $HOME_NET. A subnet-specific value goes stale on any DHCP change and silently disables most detection. |
| EXTERNAL_NET | any | Matches the official Wazuh PoC; broader matching. |
| pcap checksum-checks | no | NIC computes checksums in hardware, so Suricata sees zeros on outbound packets. Left on this produced ~14 GB/day of false alerts. |
| stream checksum-validation | no | Same cause; otherwise the stream engine refuses to reassemble outbound flows. |
| eve dns | requests: yes, responses: no, version: 2 | Queries only. See the warning below. |
| eve tls / http | extended: yes | Needed for SNI, JA3/JA4, URL and user-agent. |
| eve flow / netflow | disabled | One event per connection would dwarf everything else. |

> 🛑 **Never write types: [query] in the eve dns block**
>
> In Suricata 8 the dns "types:" key filters by DNS RECORD type (a, aaaa, cname...), not by query versus answer. types: [query] filters for a record type that does not exist and logs ZERO DNS events, silently, while DNS rules keep firing because the parser still works. It looks exactly like a DNS-over-HTTPS problem. Use requests: and responses: instead.


### 4.6  How capture stays working

The scheduled tasks do not run Suricata directly. They run a launcher that enumerates every physical adapter at start time and passes one `-i` per adapter:

| Task | Trigger | Purpose |
|---|---|---|
| Suricata IDS | System startup, +20s | Start capture after boot |
| Suricata IDS Watchdog | Every 5 minutes | Restart if stopped, or if the adapter set changed |

This means a machine with both Wi-Fi and Ethernet is captured on **both**. Switching between them, docking, or undocking needs no reconfiguration and creates no gap. Verified on Suricata 8.0.6: multiple `-i` flags are accepted and an adapter in Disconnected state does not abort startup — Suricata reports `Using 2 live device(s)` and `RX: 2`.

> ℹ️ **Suricata runs as a scheduled task, not a service**
>
> Suricata's own --service-install creates a service that will not start on this build, so the kit uses a SYSTEM scheduled task instead. Get-Service Suricata will find nothing. Check with: Get-ScheduledTask -TaskName 'Suricata IDS'


### 4.7  Point the Wazuh agent at eve.json

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\04-wire-wazuh-agent.ps1
```

Inserts the localfile block into `C:\Program Files (x86)\ossec-agent\ossec.conf`:

```xml
<localfile>
  <log_format>json</log_format>
  <location>C:\Program Files\Suricata\log\eve.json</location>
</localfile>
```

> ⚠️ **events_per_second maximum is 1000**
>
> The agent default of 500 eps can be exceeded by DNS and TLS bursts, and the excess is dropped with only a log line ("Agent buffer is full"). Raise it with -EventsPerSecond 1000. Do NOT set a higher value: Wazuh rejects anything above 1000, the agent then fails config parsing and exits with "No client configured" -- the agent goes DOWN until corrected.


### 4.8  Make DNS visible

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\06-disable-doh.ps1
```

Chrome, Edge and Firefox default to DNS-over-HTTPS, which hides lookups inside TLS where Suricata cannot read them. This is the usual reason a DNS dashboard stays empty. Reversible with `-Revert`. **Restart browsers fully** — policy is read at startup. Skip this if you only need "which sites": TLS SNI works either way.

---


## 5. Files installed on the endpoint

| Path | Purpose |
|---|---|
| C:\Program Files\Suricata\suricata.yaml | Main config, patched by script 03 |
| C:\Program Files\Suricata\suricata.yaml.orig | Pristine backup; restore to undo |
| C:\Program Files\Suricata\suricata-launch.ps1 | Capture launcher run by the scheduled tasks |
| C:\Program Files\Suricata\threshold.config | Signature suppression and rate limiting |
| C:\Program Files\Suricata\rules\ | ET Open ruleset + local.rules |
| C:\Program Files\Suricata\log\eve.json | Event output, read by the Wazuh agent |
| C:\Program Files\Suricata\log\launcher.log | What the launcher decided to capture |
| C:\Program Files (x86)\ossec-agent\ossec.conf | Agent config, holds the localfile block |

> ℹ️ **The launcher is deliberately installed next to Suricata**
>
> Not run from the deployment kit. That way the kit folder can be moved or deleted without breaking a running deployment.


## 6. Wazuh server configuration

This is the step that makes network visibility work. Copy the `suricata/` folder of the companion [wazuh-manager-toolkit](https://github.com/TanZero7/wazuh-manager-toolkit) repo to the Wazuh server, then:

```bash
sudo bash install-manager-rules.sh
```

The script reports the manager version, backs up any existing copy, installs to `/var/ossec/etc/rules/local_rules_suricata.xml`, validates every rule with `wazuh-logtest` **before** restarting, then restarts the manager.

> ⚠️ **Validation runs before the restart on purpose**
>
> A malformed rules file prevents wazuh-manager from starting at all. Validating first means a bad file is caught while the manager is still up.

Expected output:

```
==> Validate rules with wazuh-logtest (before restarting)
    [ OK ] dns-query.json          -> rule 100210 (as expected)
    [ OK ] dns-tunnel.json         -> rule 100211 (as expected)
    [ OK ] tls-sni.json            -> rule 100220 (as expected)
    [ OK ] http-request.json       -> rule 100230 (as expected)
    [ OK ] http-exe-download.json  -> rule 100231 (as expected)
    [ OK ] alert-high.json         -> rule 100200 (as expected)
    [ OK ] All 6/6 rule validations passed
```


### Why the custom rules are required

Wazuh's built-in Suricata ruleset (`0475-suricata_rules.xml`) contains exactly five rules:

| Rule | Level | Matches | Reaches dashboard? |
|---|---|---|---|
| 86600 | 0 | any decoded eve event | no |
| 86601 | 3 | event_type: alert | yes |
| 86602 | 0 | event_type: http | NO |
| 86603 | 0 | event_type: dns | NO |
| 86604 | 0 | event_type: tls | NO |

In Wazuh, **level 0 means decode then discard**. The custom ruleset chains child rules onto those level-0 parents and re-grades them to level 3 so the events survive:

```xml
<rule id="100220" level="3">
  <if_sid>86604</if_sid>                    <!-- parent: event_type tls -->
  <field name="tls.sni">\.+</field>          <!-- presence check, see below -->
  <description>Suricata: TLS connection to $(tls.sni) by $(src_ip)</description>
  <group>suricata_tls,network_visibility,tls,</group>
</rule>
```

> ⚠️ **Two traps when writing your own rules**
>
> \.+ is NOT "one or more dots". Wazuh's <field> uses OS_Regex by default, where \. means any character, so this is the idiomatic "field exists" test. And sibling rules under one <if_sid> are NOT evaluated in file order -- a catch-all sibling will shadow a specific one. Use negate="yes" to make them mutually exclusive rather than order-dependent.


### Rules installed

| Rule | Level | Fires on |
|---|---|---|
| 100200 | 12 | High-severity signature (alert.severity 1) |
| 100201 | 7 | Medium-severity signature (alert.severity 2) |
| 100202 | 4 | Low-severity signature (alert.severity 3) |
| 100205 | 10 | 8+ alerts from one source in 60s (scan) |
| 100210 | 3 | DNS query — visibility |
| 100211 | 8 | DNS tunnelling: abnormally long label |
| 100212 | 5 | Frequently abused TLD |
| 100220 | 3 | TLS SNI — visibility |
| 100221 | 4 | TLS with no SNI |
| 100230 | 3 | HTTP request — visibility |
| 100231 | 7 | Executable or archive over cleartext HTTP |
| 100232 | 6 | Scripted HTTP client (curl, PowerShell, BITS) |

---


## 7. Verification


### 7.1  Automated

```
Run-Verify.cmd    :: health check only, changes nothing
```

`Run-Verify.cmd` gives a pass/fail verdict per stage and is the thing to run after any change:

```
==> VERDICT
    [PASS] Suricata running           1 process(es)
    [PASS] eve.json growing           +28571 bytes
    [PASS] DNS visibility             472 events
    [PASS] TLS visibility             169 events
    [PASS] Agent tailing eve.json     present in logcollector state
    [PASS] Agent connected            status=connected
```


### 7.2  Manual triggers

| Test | Command on the endpoint | Expected rule |
|---|---|---|
| DNS visibility | Resolve-DnsName github.com | 100210 |
| TLS SNI | Invoke-WebRequest https://example.com | 100220 |
| DNS tunnelling | Resolve-DnsName ("a"*45 + ".example.com") | 100211 |
| Abused TLD | Resolve-DnsName testing123.xyz | 100212 |
| Scripted client | curl.exe http://testmynids.org/ | 100232 |

> ⚠️ **Scan detection needs a second machine**
>
> Loopback traffic never reaches Npcap, so you cannot scan yourself. From another host on the LAN:  nmap -sS -p 1-1000 <endpoint-ip>


### 7.3  Confirm both adapters are captured

```powershell
powershell -Command "Get-Content 'C:\Program Files\Suricata\log\suricata.log' | Select-String 'live device'"
# expect: Using 2 live device(s).   (one per physical adapter)
```


### 7.4  Expected latency

| Hop | Latency |
|---|---|
| Packet to eve.json (Suricata) | 0.01-0.03 s |
| eve.json to alert on the manager | ~0.5 s |
| Manager to searchable in the dashboard | 4-9 s (index refresh_interval) |
| Total | ~5-10 s |

> ⚠️ **The dashboard does not auto-refresh by default**
>
> Set a refresh interval of 5 or 10 seconds in the time picker at the top right. This is almost always why people think the pipeline is delayed when it is not.


## 8. Viewing results in Wazuh

Dashboard, then **Threat Hunting** (or **Discover**), index pattern `wazuh-alerts-*`:

| Query | Shows |
|---|---|
| rule.groups:suricata | Everything this integration produces |
| rule.groups:network_visibility | DNS / TLS / HTTP only, no signature noise |
| rule.id:100220 | Every HTTPS site visited |
| rule.id:100210 | Every domain resolved |
| rule.level:>=7 | Only what needs investigating |
| data.tls.sni:*google* | Wildcard on visited hostnames |
| data.src_ip:<endpoint-ip> | Scope to one endpoint |

For a browsing-history view: filter `rule.id:100220`, then add `data.tls.sni`, `data.dest_ip` and `agent.name` as columns and save the search.


### From the command line

```
# live tail of Suricata alerts, on the server
tail -f /var/ossec/logs/alerts/alerts.json | grep --line-buffered '"suricata"'

# which custom rules have fired
grep -o '"id":"1002[0-9][0-9]"' /var/ossec/logs/alerts/alerts.json | sort | uniq -c | sort -rn

# agent connectivity
/var/ossec/bin/agent_control -l
```


## 9. Operations


### Updating signatures

Worth scheduling daily. **Both** commands are required: Windows Suricata cannot expand globs, so the explicit rule-file list in suricata.yaml must be regenerated after a refresh.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\02-install-suricata.ps1 -RefreshRulesOnly
powershell -ExecutionPolicy Bypass -File .\scripts\03-configure-suricata.ps1
```


### Controlling capture

```powershell
Get-ScheduledTask -TaskName 'Suricata IDS'        # status
Start-ScheduledTask  -TaskName 'Suricata IDS'      # start
Stop-ScheduledTask   -TaskName 'Suricata IDS'      # stop
Get-Content 'C:\Program Files\Suricata\log\launcher.log' -Tail 20
```


### Tuning noise

1. Suppress a specific signature in `C:\Program Files\Suricata\threshold.config`.
2. Add `<options>no_full_log</options>` to rules 100210/100220 on the server — keeps indexed fields, drops the raw event.
3. Drop the visibility rules to level 2 so they are counted but not alerted, then raise only what you need.

`threshold.config` as shipped already suppresses two decoder-event floods
found during field deployment: SID 2200002 ("IPv4 total length smaller than
header size") and SID 2200121 ("Ethertype unknown"), both of which were
observed firing over a thousand times a minute on a healthy, otherwise
normal endpoint. The root cause was investigated (NIC offloads, adapter
selection, and capture drops were all ruled out) but never conclusively
identified — see the comment above those two `suppress` lines in
`threshold.config` for what was checked. They're suppressed as noise
control, not because the underlying behavior is understood; revisit if you
ever get a packet-level capture that explains it.

**Applying an updated `threshold.config` to an endpoint that's already
running** doesn't need a full reconfigure — Suricata only reads the file at
startup, so copy it over and restart capture:
```powershell
Copy-Item '<KitRoot>\config\threshold.config' 'C:\Program Files\Suricata\threshold.config' -Force
powershell -ExecutionPolicy Bypass -File 'C:\Program Files\Suricata\suricata-launch.ps1'
```
(or just re-run `03-configure-suricata.ps1`, which does this as one of its steps anyway and is safe to re-run).


### Resource usage

| Metric | Observed |
|---|---|
| Suricata RAM | 50-200 MB steady state (peaks ~1 GB while loading rules) |
| Suricata CPU | ~0% of one core when idle, 16-core machine |
| eve.json | ~14 MB/day after the checksum fix |
| Rotated logs | Pruned automatically after 7 days by the launcher |


### Uninstall / revert

```powershell
Stop-ScheduledTask   -TaskName 'Suricata IDS'
Unregister-ScheduledTask -TaskName 'Suricata IDS' -Confirm:$false
Unregister-ScheduledTask -TaskName 'Suricata IDS Watchdog' -Confirm:$false
Copy-Item 'C:\Program Files\Suricata\suricata.yaml.orig' 'C:\Program Files\Suricata\suricata.yaml' -Force
powershell -ExecutionPolicy Bypass -File .\scripts\06-disable-doh.ps1 -Revert
# On the server: remove /var/ossec/etc/rules/local_rules_suricata.xml and restart wazuh-manager
```

---


## 10. Troubleshooting

Every entry below was encountered during this deployment. Several fail **silently**, so the visible symptom points somewhere other than the cause.

| Symptom | Cause | Fix |
|---|---|---|
| Signature alerts appear but no DNS/TLS/HTTP | Built-in rules 86602-86604 are level 0 (decode then discard) | Install local_rules_suricata.xml (section 6) |
| Zero DNS events, but DNS rules still fire | eve dns types: filters by DNS record type; [query] matches nothing | Use requests: yes / responses: no |
| Few DNS events from browsing | Browser DNS-over-HTTPS | 06-disable-doh.ps1, then fully restart browsers |
| Flood of invalid checksum alerts; huge eve.json | NIC checksum offload; auto does not detect it on Npcap | checksum-checks: no and stream.checksum-validation: no |
| Loading signatures failed -- no rules at all | A few unloadable rules abort the whole ruleset (file.magic, disabled protocols) | Re-run 02-install-suricata.ps1 to sanitise |
| opening rule file ...\*.rules: Invalid argument | Windows Suricata cannot expand globs | List files explicitly; re-run 03 after every refresh |
| Signature missing required value "sid" at line 1 | UTF-8 BOM makes the leading # stop being a comment | Write rule files as UTF-8 without BOM |
| Every TLS event says "no SNI" | Sibling rule order is not guaranteed; catch-all shadowed the specific rule | Make them mutually exclusive with negate="yes" |
| Agent connected but events missing | Agent buffer throttling at 500 eps | 04-wire-wazuh-agent.ps1 -EventsPerSecond 1000 |
| Agent will not start after editing ossec.conf | events_per_second above 1000 is rejected; agent exits "No client configured" | Set 1000 or lower; validate the XML before restarting |
| Get-Service Suricata finds nothing | Capture runs as a scheduled task, not a service | Get-ScheduledTask -TaskName 'Suricata IDS' |
| Running scripts is disabled on this system | PowerShell execution policy | Use the .cmd launchers, or -ExecutionPolicy Bypass |
| Dashboard looks frozen / delayed | Wazuh dashboard does not auto-refresh by default | Set refresh interval in the time picker to 5s or 10s |
| Agent stopped reporting after a network change | Manager IP changed (DHCP) | Give the server a static IP; update <address> in ossec.conf |
| `05-verify.ps1` shows `[FAIL]` on "Agent tailing eve.json" right after `04-wire-wazuh-agent.ps1` | Reads `wazuh-logcollector.state`, which only catches up a few minutes after `WazuhSvc` restarts — not a real problem. `ossec.log` will already show `Analyzing file: '...eve.json'` even while the state file lags. | Wait about 10 minutes and run `05-verify.ps1` again before troubleshooting further |
| wazuh-logtest reports 0/N when rules are fine | -q suppresses all output including the Phase 3 result | Use -v alone, never -q -v |
| Massive volume of level-3 alerts, SID 2200002 ("IPv4 total length smaller than header size") or 2200121 ("Ethertype unknown"), drowning out real alerts | Decoder-level capture artifact, root cause not conclusively identified (NIC offloads, adapter selection, and capture drops were all checked and ruled out) | Already suppressed by default in the shipped `threshold.config` — see "Tuning noise" above if you're seeing this on an endpoint whose `threshold.config` predates this fix |


### Server VM will not get an IPv4 address

Seen on a bridged VMware guest. Symptoms and how to tell them apart:

- **NetworkManager reports "connection profile failed"** and the interface has only an fe80:: address. Note that Ubuntu's network indicator can show "connected" on IPv6 alone, so the icon does not prove IPv4 works.
- **If DHCP times out but the gateway is pingable after setting a static address**, layer 2 bridging is fine and the DHCP server is not answering. Assign a static IP.
- **If the gateway is not pingable even with a static address**, the bridge itself is not carrying frames. Check that VMware Bridge Protocol is enabled on the correct physical adapter, and that VMnet0 is not auto-bridged to a disconnected NIC.

```
# inside the guest -- distinguish the two cases
ip -br a show ens33
journalctl -u NetworkManager -b | grep -iE 'dhcp4|Activation'
ping -c3 <gateway>
```


## 11. Known limitations

- **HTTPS hides URLs.** You get the hostname from SNI, never the path. Full URL visibility needs TLS interception, which is out of scope.
- **Encrypted Client Hello will eventually hide SNI too.** Not yet widespread; when it arrives, hostname visibility degrades to IP-only.
- **Loopback is invisible.** Traffic to 127.0.0.1 never reaches Npcap.
- **Shared-medium traffic appears.** On Wi-Fi, broadcast and multicast from other devices is captured. Filter on data.src_ip to scope to one endpoint.
- **Bridged VMs on the same host are captured** — their traffic crosses the host NIC and appears under this agent's name.
- **One endpoint only.** Watching other devices needs switch mirroring, which this design excludes.
- **IDS, not IPS.** Nothing blocks traffic. Inline mode on Windows requires WinDivert and a different architecture.

