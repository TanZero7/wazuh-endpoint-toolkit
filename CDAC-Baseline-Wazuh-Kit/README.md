# CDAC Security Baseline — Wazuh SCA Policy Kit

A custom Wazuh Security Configuration Assessment (SCA) policy implementing
the **CDAC "Security Baseline for Desktops/Laptops"** (30 controls) as
automated, scored checks — pure config, no new software to install.

Of the 30 controls, **21 are fully automated checks** in this policy and
**9 are genuinely not remotely checkable** (naming conventions, BIOS
password, scheduled-task/listening-port/software-inventory *approval*,
certificate lifecycle process, AD Group Policy compliance, new-system
issuance procedure) and stay manual/procedural — see section 4.

---

## Start here

| If you want to... | Read |
|---|---|
| **Deploy this from scratch** | **[INTEGRATION-GUIDE.md](INTEGRATION-GUIDE.md)** |
| See exactly what's automated vs. manual, and why | `docs/CDAC-Baseline-PoC.md` |

---

## Folder layout

```
INTEGRATION-GUIDE.md     HOW TO DEPLOY THIS  <- start here
docs/
  CDAC-Baseline-PoC.md        what's automated, what isn't, and why
endpoint/
  Run-Setup.cmd                full install, start to finish  <- double-click this
  Run-Verify.cmd                health check
  scripts/                     install-baseline-policy.ps1, verify.ps1
  config/
    cdac_win_baseline.yml        the policy itself — 30 checks, IDs 400001-400030
server/
  check-sca-rules.sh           verifies the built-in SCA alerting ruleset — nothing to install
```

Nothing to *install* on the Wazuh server — SCA policies run entirely on the
agent and report their results back automatically, using Wazuh's built-in
SCA alerting rules. `server/` exists to **verify** those are present, not to
add anything custom.

## Install

**Endpoint**: right-click `endpoint\Run-Setup.cmd` → *Run as administrator*.
**Server** (optional, confirms the built-in SCA ruleset is present): `sudo bash server/check-sca-rules.sh`.

## Check it's working

```
endpoint\Run-Verify.cmd
```

Then in the dashboard: **Agents → (this agent) → SCA tab** — you'll see a
score and a pass/fail list against "CDAC Security Baseline for
Desktops/Laptops".

## Deploying to another Windows machine

Copy `endpoint\`, run `Run-Setup.cmd`. For a fleet, push `config/cdac_win_baseline.yml`
to `ruleset/sca/` on every agent via your installer, and reference it from
each department group's `agent.conf` instead of editing every machine's
local `ossec.conf` by hand — see INTEGRATION-GUIDE.md section 6.

## Known limitations

- 9 of 30 controls are not remotely checkable at all (see docs/PoC) — those
  stay on a manual/procedural register, not in this policy.
- Command-based checks (`c:` rules) require `sca.remote_commands=1`, which
  this kit sets in `local_internal_options.conf` — a config file, not a
  registry key, so it does need the agent service restarted once to take
  effect (the install script does this for you).
