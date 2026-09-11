# Wazuh Endpoint Toolkit

One self-contained deployment kit per capability, each built the same way —
a `README.md` + `INTEGRATION-GUIDE.md` at the top, `docs/` with a
Proof-of-Concept writeup, and an `endpoint/` and/or `server/` folder holding
the actual scripts, config, and (where relevant) rules to install. Every kit
is independent — copy just the one folder you need to a new machine or
manager.

This repo covers the **Windows endpoint side** of a larger multi-capability
Wazuh SIEM deployment: seven kits, each independently designed, built, and
validated end-to-end on a live production Wazuh-monitored Windows endpoint
before being carried into production rollouts (600+ and 130+ endpoint
deployments). A matching set of **server-side/manager integrations**
(VirusTotal enrichment, an offline hash blocklist, vulnerability detection,
log retention, and log backup) and a separate **Suricata network-IDS kit**
were built as part of the same toolkit family and follow the same design —
they're maintained in a separate repo.

Every kit's `docs/` folder also has a polished **PDF and DOCX** version of
its Integration Guide and Proof-of-Concept writeup, built with a small
custom Markdown → PDF/DOCX rendering pipeline — see
[`_doc-toolkit/`](_doc-toolkit) for the shared tooling and how to regenerate
them after an edit.

| Kit | What it adds | Endpoint? | Server? |
|---|---|---|---|
| [FIM-Wazuh-Kit](FIM-Wazuh-Kit) | Desktop+Downloads file integrity monitoring, realtime | ✅ | verify only |
| [YARA-Wazuh-Windows-Kit](YARA-Wazuh-Windows-Kit) | Content-based malware scan on every FIM change | ✅ | ✅ install |
| [Sysmon-Wazuh-Windows-Kit](Sysmon-Wazuh-Windows-Kit) | Deep process/network/registry telemetry, ~150 built-in detections | ✅ | verify only |
| [CDAC-Baseline-Wazuh-Kit](CDAC-Baseline-Wazuh-Kit) | 21 of the CDAC 30-control baseline as a scored SCA policy | ✅ | verify only |
| [USB-Monitor-Wazuh-Kit](USB-Monitor-Wazuh-Kit) | Alert on USB storage device connection | ✅ | ✅ install |
| [Forensic-Collection-Wazuh-Kit](Forensic-Collection-Wazuh-Kit) | Continuous background evidence snapshots | ✅ | optional install |
| [Endpoint-Control-Wazuh-Kit](Endpoint-Control-Wazuh-Kit) | Operator tools: pause/resume all of Wazuh, and exclude a folder from every capability | ✅ | — |

"Verify only" means the manager-side alerting already ships with a stock
Wazuh install (built-in rules for FIM, Sysmon, and SCA respectively) — the
kit's `server/` folder confirms that rather than installing anything
custom. Every kit that has a manager-side component has a `server/` folder,
even if all it does is confirm one.

## Recommended install order

If you're setting up a **new endpoint from scratch**, this order matches
what several kits assume (later ones build on FIM's events):

1. FIM — everything else that watches "a file changed" depends on this
2. YARA — a content-based check on the same FIM event (VirusTotal and an
   offline hash blocklist run the same way, from the companion server-side repo)
3. Sysmon — independent, install any time
4. CDAC-Baseline — independent, install any time
5. USB-Monitor — independent, install any time
6. Forensic-Collection — independent, install any time

The companion **Suricata network-IDS kit** and the **server-only**
integrations (VirusTotal, offline hash blocklist, vulnerability detection,
log retention, log backup) live in a separate repo — the server-only ones
install once on the manager and cover every endpoint automatically, no
per-endpoint step.

## Fleet-wide: no dropped events

For a SOC that must not miss logs, the Wazuh agent's **anti-flooding buffer is
disabled** — by default it caps outgoing events at 500/sec and silently drops
the excess (measured: 1,250 Suricata events lost on one endpoint). The FIM
kit's `set-no-event-loss.ps1` turns it off (run automatically by that kit's
`Run-Setup.cmd`). Because it's a local-`ossec.conf` setting that the manager
does **not** push centrally, the office installer must bake
`<client_buffer><disabled>yes</disabled></client_buffer>` into the base
`ossec.conf` so every enrolled machine has it from first boot. See the FIM
kit's INTEGRATION-GUIDE for the trade-off and how to verify `drops=0`.

The FIM `<syscheck>` scope also uses `max_eps=1000` (raised from 100) so a
mass file operation is reported without backlog.

## What's deliberately NOT in these kits

**No installer/packaging work, by design.** Every kit here assumes a Wazuh
agent is already enrolled and does capability work only — wrapping all of
this into a single onboarding installer (three prompts: manager IP, agent
name, department) was built as a separate, later-phase project on top of
this kit family, once each capability had proven stable independently.

Also not included here: automated response actions (deferred until the
capability set proved stable) and the fleet-wide attack-coverage summary
report generated from this telemetry — both one-off/downstream artifacts
rather than repeatable kits.
