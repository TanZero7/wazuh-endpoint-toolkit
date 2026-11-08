# Screenshot shot list

Screenshots that will be embedded in each folder's README. Capture them from a
**lab setup** (test VM + test manager), never a production environment.

## Before you capture: redaction checklist

- [ ] No real IP addresses (manager, agents, gateways). A lab range like `192.168.56.x` is fine.
- [ ] No real hostnames, usernames or agent names. Use names like `WIN-LAB-01`.
- [ ] No organisation names, logos, browser tabs or bookmarks in frame.
- [ ] No API keys (VirusTotal key in `ossec.conf`!) or passwords.
- [ ] Dashboard time range shows recent test activity only.

Save as PNG, about 1400 px wide, into `docs/images/` with the exact filename below.

## Shots

| # | Filename | Folder | What to capture |
|---|---|---|---|
| 1 | `fim-verify-pass.png` | fim | `verify.ps1` output with all `[PASS]` lines |
| 2 | `fim-alerts.png` | fim | Dashboard, `rule.groups:syscheck`, showing 554 / 550 / 553 for the test file |
| 3 | `sysmon-verify-pass.png` | sysmon | `verify.ps1` output with all `[PASS]` lines |
| 4 | `sysmon-alerts.png` | sysmon | Dashboard, `rule.groups:sysmon_event1`, one alert expanded showing the command line and MITRE ID |
| 5 | `yara-verify-pass.png` | yara | `verify.ps1` output with all 8 `[PASS]` lines |
| 6 | `yara-100700-alert.png` | yara | Dashboard, `rule.id:100700` for the self-test marker file, alert expanded |
| 7 | `suricata-verify-pass.png` | suricata | `05-verify.ps1` VERDICT block, all `[PASS]` |
| 8 | `suricata-visibility.png` | suricata | Dashboard, `rule.groups:network_visibility`, columns `data.tls.sni` / `data.dns.rrname` |
| 9 | `suricata-signature-alert.png` | suricata | A signature alert (e.g. from `curl.exe http://testmynids.org/`) expanded |
| 10 | `virustotal-87105.png` | virustotal-active-response | Dashboard, EICAR test: 87105 alert expanded (positives / permalink) |
| 11 | `virustotal-ar-chain.png` | virustotal-active-response | Dashboard timeline showing 554 → 87105 → 657 → 553 (→ 100092) |
| 12 | `endpoint-control-status.png` | endpoint-control | `wazuh-control.ps1 -Status` output, ACTIVE |
| 13 | `local-admin-verify-pass.png` | local-admin-setup | `Run-Verify.cmd` output ending in the green `PASS:` line |
| 14 | `manager-suricata-install.png` | (manager repo) suricata | `install-manager-rules.sh` output, `[ OK ]` lines + restart |
| 15 | `manager-yara-logtest.png` | (manager repo) yara | `install-manager-rules.sh` showing `All 2/2 rule validations passed` |
| 16 | `dashboard-overview.png` | top-level README | Wazuh dashboard overview / threat-hunting page with alerts from several capabilities |

Once the images are in `docs/images/`, each README gets a **Screenshots** section
showing them.
