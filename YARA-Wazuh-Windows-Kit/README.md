# YARA + Wazuh — Scan-on-Change Malware Detection Kit

Installs the YARA scanning engine and an open-source signature pack on a
Windows endpoint, and wires it to fire automatically — via Wazuh
**active-response** — every time File Integrity Monitoring sees a file
added or changed in a watched directory (Desktop/Downloads by default).
Content-based detection, running alongside hash-based (VirusTotal, offline
blocklist) checks on the same event.

Gives you:

1. **Content-based malware detection** — not just a hash lookup; YARA
   pattern-matches file *content*, catching variants a hash-only check would
   miss.
2. **416 curated open-source rules** from
   [Neo23x0/signature-base](https://github.com/Neo23x0/signature-base)
   (Florian Roth) — generic malware, webshells, suspicious patterns.
3. **Automatic, no polling** — driven by Wazuh's FIM realtime events, not a
   scheduled sweep.

---

## Start here

| If you want to... | Read |
|---|---|
| **Deploy this from scratch** | **[INTEGRATION-GUIDE.md](INTEGRATION-GUIDE.md)** |
| Understand what it does and how to read results | `docs/YARA-Wazuh-PoC.md` |

---

## Folder layout

```
INTEGRATION-GUIDE.md     HOW TO DEPLOY THIS  <- start here
docs/
  YARA-Wazuh-PoC.md            what it does + how to read results
endpoint/                 EVERYTHING THAT RUNS ON THE WINDOWS MACHINE
  Run-Setup.cmd                full install, start to finish  <- double-click this
  Run-Verify.cmd                health check
  scripts/                     install-yara.ps1, wire-active-response.ps1, verify.ps1
  active-response/              yara-scan.ps1 + .cmd -- deployed into the agent by wire-active-response.ps1
server/                   EVERYTHING THAT RUNS ON THE WAZUH SERVER
  install-manager-rules.sh     installs + validates the rules file
  local_rules_yara.xml          rules 100700 (match) / 100701 (clean)
  active-response-block.xml     paste this into ossec.conf by hand -- see its header for why
  logtest-samples/              proves the rules fire
```

---

## Install

**On the endpoint**: right-click `endpoint\Run-Setup.cmd` → *Run as
administrator*.

**On the Wazuh server**: copy the `server\` folder over, then
`sudo bash install-manager-rules.sh`, then paste `active-response-block.xml`
into `ossec.conf` by hand and restart the manager (the script tells you
exactly this at the end — it's the one step that stays manual on purpose).

Both halves are required — the endpoint alone won't do anything until the
manager knows to trigger it, and the manager alone has nothing to trigger.

## Check it's working

```
endpoint\Run-Verify.cmd
```

For a full live test (recommended — static checks alone don't prove the
active-response chain actually fires), see **INTEGRATION-GUIDE.md section 5**.

## Deploying to another Windows machine

Copy the `endpoint\` folder, run `Run-Setup.cmd`. The `server\` side is
installed once, centrally, and covers every endpoint that has the kit.

## Known limitations

- 416 generic rules is a solid baseline layer, not a commercial-grade feed —
  it will not catch everything. It's designed to sit *behind* VirusTotal and
  the offline hash blocklist, not replace them.
- Only scans files under Wazuh's FIM-watched directories (Desktop/Downloads
  by default) — it is not a full-disk on-access scanner.
- Read **INTEGRATION-GUIDE.md section 6 (Windows-specific gotchas)** before
  you debug a "nothing happens" symptom — two real, non-obvious bugs were
  found and fixed building this, and they will bite you again if you write
  your own active-response script from scratch instead of reusing this one.
