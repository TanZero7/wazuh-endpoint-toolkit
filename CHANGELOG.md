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
- **YARA: rule 100700 could never fire (critical, manager repo).** During
  rollout the rule's `yara_rule` pattern was "fixed" from `\.+` to `.+`, on the
  belief that `\.+` meant literal dots. It's the other way round: Wazuh's `<field>`
  uses OS_Regex, where `\.` means *any character* and a bare `.` is a *literal
  dot*. `.+` therefore only matches a name made of dots, which YARA forbids, so
  real matches never alerted. Restored to `\.+` (confirmed against Wazuh's regex
  documentation and an OS_Regex emulator); the installer's `wazuh-logtest` check
  catches it.
- **YARA: false-positive matches on scan errors.** `yara-scan.ps1` parsed
  whatever `yara64.exe` printed as match lines without checking its exit code, so a
  locked file produced a 100700 alert with a garbage rule name. It now only parses
  output when the scan actually succeeded.
- **YARA: `-RefreshRulesOnly` on a machine without YARA** crashed with a
  confusing "not recognized" error. It now fails fast with a clear message.
- **YARA: broken doc references.** Scripts pointed at a non-existent
  `server\INSTALL.md` and the wrong guide section. Fixed.
- **YARA: rule-management instructions.** The docs said to add the self-test
  rule, add custom rules, or disable noisy ones and then run `-RefreshRulesOnly`.
  But a refresh deletes every `*.yar*` in the rules folder and rebuilds the index,
  undoing all three. Docs now add rules via `include` lines in `index.yar` (custom
  rules kept outside the rules folder) and warn that a refresh resets manual changes.
- **Verify-script race after restart.** FIM, Sysmon and Suricata verify scripts
  read `wazuh-logcollector.state`, which isn't rewritten until a few minutes after
  an agent restart, so they could show `[FAIL]` on a healthy install. They now say
  to wait ~10 minutes and re-run; YARA's manager-push check got its own wording.
- **Suricata: decoder-event flood.** Suppressed SID 2200002 and 2200121, seen
  firing over a thousand times a minute on a healthy endpoint, in
  `config/threshold.config` (pending a root cause; see the comment in the file).

### Changed
- **Each repo now holds only its own side.** Integration guides here are
  endpoint-only; everything that runs on the manager moved to
  [wazuh-manager-toolkit](https://github.com/TanZero7/wazuh-manager-toolkit), with
  links both ways. Every guide states the order: **manager first, then endpoint,
  then verify** (verification always runs from the endpoint).
- Every capability now shows its expected `[PASS]` output, a PASS/FAIL table for
  live tests, and the rule to wait 5–10 minutes after installation before re-running
  a failed check.

### Removed
- USB monitoring (not working reliably; may return later).
- Forensic-collection kit (not part of this release).
- `Run-Tests.cmd` for Suricata (its traffic generator isn't part of this release);
  use the manual triggers in `suricata/INTEGRATION-GUIDE.md` § 5.2.
