# Changelog

Fixes and additions found while rolling this toolkit out to production Windows
endpoints. Each fix is also marked inline in the affected file with a `[fix]` or
`[addition]` comment explaining what broke and why.

## 2026-11: production rollout release

### Added
- **Suricata network IDS** (`suricata/`): endpoint-side Suricata on Windows,
  forwarding DNS, TLS SNI, HTTP and ~52,000 ET Open signatures to Wazuh.
- **VirusTotal Active Response** (`virustotal-active-response/`): auto-delete a
  file once VirusTotal flags it. Chain confirmed live on two endpoints:
  `554 → 87105 → 657 → 553`.
- **Local admin setup** (`local-admin-setup/`): pre-install hardening step
  (single local `admin`, everyone else demoted, built-in Administrator disabled).
- **Step-by-step guides** (`guides/`): copy-paste endpoint setup guide, and a
  separate Sysmon & YARA guide covering both endpoint and manager steps.
- Manager-side scripts moved to the companion
  [wazuh-manager-toolkit](https://github.com/TanZero7/wazuh-manager-toolkit) repo.

### Fixed
- **FIM: duplicate `<syscheck>` block.** `install-fim-scope.ps1` only checked
  whether the Desktop path appeared anywhere in `ossec.conf` and otherwise added a
  *second* `<syscheck>` block. Every Windows agent already ships one, so this
  produced two. It now merges Desktop, Downloads, `alert_new_files` and the
  temp-file ignore into the existing block, and refuses to run if none is found.
  Verified on two endpoints (rules 550/553/554).
- **YARA: rule 100700 could never fire (critical).** The manager rule matched
  `yara_rule` against `\.+` (one or more *literal dots*). YARA rule names can't
  contain dots, so real malware matches never raised an alert while every other
  part of the pipeline looked healthy. Fixed to `.+` (lives in the manager repo).
- **YARA: false-positive matches on scan errors.** `yara-scan.ps1` parsed
  whatever `yara64.exe` printed as match lines without checking its exit code, so a
  locked file produced a 100700 alert with a garbage rule name. It now only parses
  output when the scan actually succeeded.
- **YARA: `-RefreshRulesOnly` on a machine without YARA** crashed with a
  confusing "not recognized" error. It now fails fast with a clear message.
- **YARA: broken doc references.** Scripts pointed at a non-existent
  `server\INSTALL.md` and the wrong guide section. Fixed.
- **YARA: self-test instructions.** The documented way to add the self-test rule
  (`-RefreshRulesOnly`) actually deletes every `.yar` before rebuilding the index,
  wiping the test rule. Docs now add it directly to `index.yar`.
- **Verify-script race after restart.** FIM, Sysmon and Suricata verify scripts
  read `wazuh-logcollector.state`, which isn't rewritten until a few minutes after
  an agent restart, so they could show `[FAIL]` on a healthy install. They now say
  to wait ~10 minutes and re-run; YARA's manager-push check got its own wording.
- **Suricata: decoder-event flood.** Suppressed SID 2200002 and 2200121, seen
  firing over a thousand times a minute on a healthy endpoint, in
  `config/threshold.config` (pending a root cause; see the comment in the file).

### Removed
- USB monitoring (not working reliably; may return later).
- Forensic-collection kit (not part of this release).
- `Run-Tests.cmd` for Suricata (its traffic generator isn't part of this release);
  use the manual triggers in `suricata/INTEGRATION-GUIDE.md` § 7.2.
