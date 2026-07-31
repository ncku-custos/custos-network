# Repo-Wide Reliability Exam — Plan

Status: **plan only** (iteration 1). This document defines a systematic audit
("exam") of the custos-network repository. Executing the exam — and any fixes
that come out of it — is iteration 2. Nothing in this document changes code.

Priorities, in order:

1. **Reliability** (primary): the flight link must come up unattended on every
   boot path, survive every plausible perturbation, and recover autonomously.
2. **Speed** (secondary): boot critical-path latency and in-flight
   latency/jitter levers.
3. **Hygiene** (secondary): CI coverage, script robustness, secrets handling,
   docs-vs-code drift.

## 1. Objectives, scope, and non-goals

### Why this exam

This repo provisions the single most safety-relevant subsystem of the
platform — the drone-to-ground flight link — and its design thesis
(`docs/rationale.md`) is *reliability by subtraction*. Two properties of the
tree shape the whole exam:

- **The comments are the informal test suite.** Roughly 40% of
  `ansible/roles/custos_network/tasks/main.yml` and most of the
  udev/tune/unit files are comments encoding real field incidents: the udev
  add→move rename race, the 90 s `DefaultDeviceTimeoutSec` stall, hostapd
  exiting 0 on interface-init failure, the RTL8822BU >900-byte black hole,
  the boot-time regulatory race. Nothing automated guards any of them.
- **CI is lint-only.** `.github/workflows/ci.yml` runs ansible-lint and a
  playbook syntax check. There is no shellcheck (despite in-tree shellcheck
  directives), no check-mode run, no template render validation, no tests.

The exam verifies that the code actually delivers the guarantees its comments
claim, and produces a findings register plus an invariant catalog that
iteration 2 turns into fixes and automated guards.

### Scope

All files in the repository: playbook, role (tasks, handlers, defaults,
templates, files), group/host vars, shell scripts, systemd units and
drop-ins, udev rules, nftables template, journald/sysctl configs, CI
workflow, and docs (README, rationale, intro, D2 diagrams).

### Non-goals (this exam iteration)

- **No fixes.** Findings carry a *fix sketch* only.
- **No new tests or CI changes.** Gaps are recorded as findings; building the
  guards is iteration 2.
- **No hardware validation.** No drone board, ground laptop, or USB radio is
  assumed available. Checks whose truth depends on real kernel/udev/radio
  behavior are still analyzed statically, but tagged `HW-ONLY` with a bench
  validation procedure for later.
- **No re-architecture.** The "subtraction" thesis is taken as given; the
  exam audits execution against it. Contradictions between thesis and code
  are in scope as drift findings.

## 2. Exam tracks

Ten tracks. Each lists what to examine, the key files, the questions to
answer, and what a finding looks like.

### Track A — Boot sequence & race conditions (reliability core)

Reconstruct the complete boot dependency graph on paper for both roles
(AP/drone, STA/ground), from udev coldplug through associated link, and hunt
for ordering gaps, races, and single points of no-retry.

Files: `templates/99-custos-flight.rules.j2`,
`templates/custos-hostapd.service.j2`, `files/custos-wifi-tune@.service`,
`files/10-custos-tune.conf`, `templates/flight.network.j2`,
`files/custos-wifi-tune`, `files/var-log-journal.mount`, plus the ordering
commentary in `tasks/main.yml`.

Questions:

- Draw the actual `Wants=`/`After=`/`BindsTo=` graph from the unit text (not
  the comments). Does every path from "device appears" to "daemon associates"
  pass through `custos-wifi-tune@`? Is there any start path (manual
  `systemctl start`, `networkctl reconfigure`) that reaches
  hostapd/wpa_supplicant on an untuned radio?
- Walk the documented add→move rename race step by step against the udev rule
  text: does matching `NAME` *or* `ENV{INTERFACE}` genuinely cover both
  events for (i) a renamed USB stick, (ii) an onboard `wlan0` never renamed,
  (iii) an adapter with predictable naming disabled? Are `change`/`bind`
  events harmless, or can `SYSTEMD_WANTS+=` queue duplicate start jobs?
  Verify the AND-semantics reading of the `NAME!=`, `ENV{INTERFACE}!=`,
  `GOTO` skip line.
- **The single most important what-if:** `custos-wifi-tune` polls
  `iw reg get` 50×0.2 s (`files/custos-wifi-tune:42-45`). At timeout the
  oneshot exits 1 — does anything retry it? Since the daemons only `Wants=`
  (not `Requires=`) the tune unit, does hostapd then start against
  regulatory domain 00 anyway, reproducing the exact incident the script
  exists to prevent?
- `custos-hostapd.service.j2` uses `Restart=always` *because* hostapd exits 0
  on interface-init failure. Check `RestartSec` / `StartLimitIntervalSec` /
  `StartLimitBurst`: can a persistently failing radio hit the start limit and
  leave the unit permanently `failed` (no autonomous recovery = S1)?
- Trace the hostapd↔networkd carrier race: what does networkd do to
  192.168.4.x when hostapd restarts and the interface bounces carrier, given
  `ConfigureWithoutCarrier` + `BindsTo`? Does the STA `.network` behave
  identically?
- With the udev-pull design (`enabled: false` everywhere), confirm nothing
  still carries `WantedBy=multi-user.target` on a device-bound unit — one
  leftover reintroduces the 90 s boot stall.

Finding shape: "Start path P reaches daemon D without the tune oneshot
having succeeded → association on domain 00; S1; statically demonstrable
from unit text, `HW-ONLY` to reproduce."

### Track B — Failure modes & autonomous recovery

Adversarial what-if walkthroughs of runtime failures, focused on "does the
system recover with nobody at the console." Each scenario gets a written
trace with file:line citations.

Scenario catalog:

1. USB adapter absent at boot; arrives minutes later (the recorded 3 m 20 s
   enumeration incident).
2. USB adapter re-enumerates mid-flight — do tune + daemon restart in the
   right order, and does the static IP return?
3. Power loss mid-`apt`, mid-template-write, mid-`nft -f` reload — what
   partial state survives, and does the next boot still bring the link up?
4. rfkill soft-block present at boot; `/dev/rfkill` absent (vendor kernel).
5. regulatory.db firmware missing entirely — the poll loop can never
   succeed; what is the end state?
6. Ground station reboots while drone stays up, and vice versa — does the
   STA reassociate without bgscan?
7. hostapd crash loop vs. start-limit settings (overlaps Track A).
8. NAT: uplink NIC absent or renamed; `nft -f` fails partway — is the old
   ruleset really retained, and is the bare link unaffected by
   `custos-nat.service` failure (it must be, per design)?
9. Journald: `/var/log/journal` bind-mount source missing; eMMC full despite
   `SystemMaxUse=50M`.
10. The five deliberate `failed_when: false` sites (`tasks/main.yml:66`,
    `tasks/main.yml:103`, `tasks/journal.yml:21`, `tasks/journal.yml:46`,
    `tasks/journal.yml:62`): for each, what real failure does it swallow,
    and does a downstream consumer (assert, register check) catch it?

### Track C — Ansible idempotency, convergence & handler ordering

Files: `tasks/main.yml`, `tasks/nat.yml`, `tasks/journal.yml`,
`handlers/main.yml`, `site.yml`, `defaults/main.yml`, `group_vars/*`,
`ansible.cfg`.

Questions:

- Handler ordering is declaration-order-dependent. Enumerate every notify
  chain and verify daemon-reload precedes every restart of a freshly
  templated unit, across both `meta: flush_handlers` barriers
  (`tasks/main.yml:173`, `tasks/main.yml:293`). What happens if a future
  contributor alphabetizes the handlers file? (No guard exists.)
- `--tags nat` partial run: verify the shared tasks tagged `nat` really
  close the gap, that their notified handlers run in a tag-scoped run, and
  that nothing `nat.yml` depends on is untagged.
- `--check` mode on a virgin host: do asserts that consume registered
  results still behave when the producing task was skipped? Are the
  `check_mode: false` command tasks all genuinely read-only? Is the
  "default rc to 0 when undefined" pattern for the pre-stage probe the safe
  default, or does it let an offline, unprestaged box pass `--check`?
- Re-run convergence: confirm no task reports `changed` on every run,
  keeping the role idempotent as its comments claim.
- The documented validation hole (`tasks/main.yml:27`): an `ansible_host`
  set to a *hostname* that resolves to a flight IP passes the string
  comparison guard. Confirm the hole, assess likelihood against real
  inventories, and evaluate whether a facts-based comparison could close it.
- Variable hygiene: every `custos_network_*` variable has a default or an
  assert; host_vars examples satisfy the freq/channel arithmetic; the
  dev-PSK gate's reliance on `custos_network_env` is sound when a fork
  forgets to set `env` at all.

### Track D — Template & rendering correctness (do first; highest yield/hour)

Render all eight templates in `templates/` locally for a matrix of inputs:
AP defaults, STA defaults, NAT on/off, VHT80 vs the HT40 escape hatch,
non-default country, iface names `wlan0` and `wlx001122334455`. Validate
rendered output where a local validator exists: `nft -c -f` for the nftables
file, `systemd-analyze verify` for units, hostapd/wpa_supplicant grammar
against the man pages.

Questions:

- `hostapd.conf.j2`: does the VHT80→HT40 escape hatch render a *coherent*
  config in both branches (ieee80211ac / vht_oper_chwidth /
  vht_oper_centr_freq_seg0_idx / ht_capab consistency with ch149)?
- `wpa_supplicant.conf.j2`: does `bgscan=""` actually disable bgscan; is the
  fixed `frequency=` correct; and — key S1 candidate — how does a PSK
  containing shell/config-special characters (`"`, `$`, `#`) render? hostapd
  and wpa_supplicant have different quoting rules; a PSK legal in one and
  not the other means link-down-after-rotation.
- `flight.network.j2`: `[Match]` semantics on transient names;
  carrier-related settings vs. the Track A race.
- `custos-nat.nft.j2`: MSS clamp value and direction; the
  declare-delete-define transaction really is atomic on reload.
- `custos-network.env.j2`: must be a valid shell fragment under `set -u`
  sourcing — both `scripts/lib.sh` and `files/custos-wifi-tune` source the
  installed copy on the boot path. Check quoting, missing keys, CRLF risk.
- Template ↔ consumer version assumptions (networkd directive names,
  hostapd option names across 2.10/2.11).

### Track E — Secrets & vault handling

Files: `ansible/vault-pass.sh`, `ansible/ansible.cfg`, `.gitignore`,
`group_vars/custos/*`, PSK-bearing template tasks in `tasks/main.yml`.

Questions:

- `vault-pass.sh` mints a random password on first run with only a stderr
  warning. Failure mode to examine: fresh clone, playbook run *before* the
  team `vault.yml` is copied in → divergent `.vault-pass` → confusing
  decryption failure later. The script guards the inverse case; is the
  asymmetry justified? Also review the post-`tr` entropy floor and the
  concurrent-first-run race.
- Does the PSK ever reach output? `diff: false` suppresses diffs, but task
  *failure* output can embed rendered content — check `no_log` coverage on
  the PSK-bearing template tasks, and that no assert `fail_msg` echoes it.
- `.gitignore` covers `.vault-pass` and `vault.yml`; spot-check git history
  for leaked secrets on those paths.
- Confirm the world-readable `/etc/custos-network.env` never carries the PSK.

### Track F — Health-check & verification coverage

Treat `scripts/health-check.sh` as the acceptance spec and audit it for
(a) correctness of each check, (b) coverage gaps vs. the invariants from
Tracks A/B, (c) shell robustness.

Questions:

- Grep fragility: does `grep -qw UP` on `ip link` output false-match inside
  `LOWER_UP`? Does `grep -qw` on an IP treat dots as word boundaries and
  match a longer address? Does the rfkill check false-FAIL a multi-radio
  ground laptop with a deliberately blocked second radio — contradicting the
  tune script's carefully phy-scoped unblock?
- The deliberate `set -uo pipefail` without `-e`: confirm no check silently
  passes because a pipeline's exit status is masked.
- Coverage gaps (each becomes a finding feeding iteration 2): no check that
  the tune oneshot succeeded; no crash-loop detection (`systemctl is-active`
  returns `active` during the up-phase of a flap — the highest-frequency
  field failure is invisible to the acceptance gate); no large-ping probe
  (`ping -s 1000 -M do` is exactly the regression test the >900-byte
  black-hole incident wants); no journal-persistence check; exit code loses
  *which* check failed (machine-readability gap).
- `scripts/lib.sh` fallback defaults: can the health check partially "pass"
  against defaults on an unprovisioned box with a missing
  `/etc/custos-network.env`?

### Track G — Shell script robustness (shellcheck sweep)

Run shellcheck and `bash -n`/`sh -n` on `files/custos-wifi-tune`,
`scripts/health-check.sh`, `scripts/lib.sh`, `ansible/vault-pass.sh`, plus
every inline shell block in the YAML and every `ExecStart` line.

Questions:

- `custos-wifi-tune` under `set -euo pipefail`: at
  `files/custos-wifi-tune:25-27`, a failed or empty phy lookup falls through
  to `rfkill unblock "${idx:-wlan}"` — the type-wide unblock the comment at
  line 20 says must never happen on a multi-radio box. Verify this reading;
  if correct it is a real finding (script contradicts its own documented
  invariant).
- Audit each `awk '{...; exit}'` pipeline for SIGPIPE-under-pipefail.
- Confirm the offline pre-stage inline script in `tasks/main.yml` is
  POSIX-clean for `sh`.
- The in-tree `# shellcheck` directives imply shellcheck was once run
  manually; CI never runs it. Produce current shellcheck output as exam
  evidence and hand the CI gap to Track H.

### Track H — CI & automation gap matrix (do last; pure aggregation)

For every invariant catalogued by Tracks A–G and J, answer: could *any*
current CI step catch its regression — and if not CI, is it at least
field-detectable per the Track J signal inventory? Current CI = ansible-lint (production profile) +
syntax check. Known-absent guards to size: shellcheck job; template-render
step (the Track D harness is a ready-made seed) with `nft -c`,
`systemd-analyze verify`, `udevadm verify`; `ansible-playbook --check`
against a synthetic inventory in a container; an invariant-test script — the
comment-suite made executable. Also verify ansible-lint actually lints >0
files at the current paths, and review the pinned toolchain versions.

Finding shape: "Invariant I (udev rule covers `move`) has no automated
guard; a one-character revert to `ACTION==\"add\"` ships green; S2 process
gap protecting an S1 behavior."

### Track I — Performance / boot latency & docs drift (secondary priority)

- Boot-path latency budget: device coldplug → udev → tune (0–10 s poll
  ceiling) → daemon start → association. What runs serially that could
  overlap; is the 10 s ceiling the right trade against hostapd's own
  restart-based retry (Track A owns correctness; this track owns latency)?
- Apt-mirror probe: bounded at `timeout 5` per run — acceptable; verify the
  timeout variable's type survives templating into `timeout`.
- Journald on eMMC: `SystemMaxUse=50M` plus rate limiting — write
  amplification assessment.
- MSS/MTU arithmetic vs. VHT80/HT40 and the >900-byte black hole: does any
  config combination re-expose it?
- Docs drift: every statement in `README.md`, `docs/rationale.md`,
  `docs/intro.md`, and the D2 diagrams that names a file, unit, IP, option,
  or behavior gets checked against the tree. Drift with operational blast
  radius (e.g. a doc implying units are boot-enabled, tempting an operator
  to "fix" `enabled: false` and reintroduce the 90 s stall) is a finding.

### Track J — Field observability & monitoring tooling

The repo's hardest failures are niche and machine-specific — the RTL8822BU
>900-byte black hole, mid-flight USB re-enumeration, crash loops whose
period exceeds any one-shot check, the add→move race that reproduces "maybe
half the time." These cannot be caught on a bench day alone; they need field
data. Everything else in this exam is point-in-time (an operator-invoked
health check, a bench runbook). This track audits whether the system, as
provisioned, would **capture enough data in the field to detect and diagnose
those failures after the fact** — and produces the requirements list for the
monitoring tooling iteration 2 builds.

Files: `files/50-custos-journal.conf`, `tasks/journal.yml`,
`files/var-log-journal.mount`, logging-related directives in every unit
file, `templates/hostapd.conf.j2` (logger levels),
`templates/wpa_supplicant.conf.j2`, `scripts/health-check.sh`,
`README.md` (the Gotchas section is the incident source list).

Questions:

- **Signal inventory** (the core deliverable): for every field incident and
  `HW-ONLY` invariant catalogued by Tracks A/B, name the signal that would
  have detected or diagnosed it in the field — udev event log for the
  rename race, periodic large-ping for the black hole, `NRestarts` for
  crash loops, networkd events for carrier bounces, `iw reg get` at
  association time for the regulatory race, `iw station dump`
  RSSI/retry/MCS trends for RF degradation. Classify each incident:
  `diagnosable-from-current-logs` / `needs-new-probe` / `undetectable`.
- **Log content sufficiency**: are default daemon verbosities (hostapd
  logger settings, wpa_supplicant, networkd, udev) enough for post-incident
  forensics from the persisted journal? The journal work made logs
  *survive* reboot; nothing has audited whether the right things are *in*
  them.
- **Journal retention vs incident window**: can the 50 M `SystemMaxUse` cap
  evict the incident before anyone harvests it — especially if a crash loop
  is spamming the journal at the time? Are rate-limit settings coherent
  with that cap?
- **Point-in-time → continuous**: which health-check assertions should
  become on-box continuous monitors (systemd timer + small recorder), and —
  critically — can they run without violating the subtraction thesis: no
  off-channel scans, no TCP on the flight link, bounded CPU, bounded eMMC
  writes? A monitor that adds jitter or wear is itself an S2 finding.
- **Ground-side monitoring as the primary channel**: when a drone-side unit
  permanently fails in flight (start-limit hit, tune timeout), there is no
  operator-visible signal on the drone. Can the ground station carry the
  monitoring burden instead — continuous RTT/loss trend, periodic
  `-s 1000 -M do` probe, `iw station dump` signal recording — since it has
  the disk, power, and an operator? What can only be observed drone-side?
- **Harvest path**: is there any defined procedure to pull journals/metrics
  off the drone post-flight? (Likely none — that absence is itself a
  finding.)

Finding shape: "Field incident class X (mid-flight re-enumeration) leaves
no persisted evidence distinguishable from a clean reboot; monitoring gap;
S2 (verification gap for an S1 behavior); fix sketch: udev-event logger +
link-flap recorder on a timer, ground-side RTT trend log."

## 3. Methodology

All methods are local and read-only against the repo; scratch artifacts live
outside the tree:

1. **Static close-reading** against the invariant catalog (Tracks A, B, C,
   E, I).
2. **Render-and-inspect**: local Jinja2 harness rendering all templates
   across the variable matrix; validate with `nft -c -f`,
   `systemd-analyze verify`, `udevadm verify` where tools exist (Track D).
3. **shellcheck + `bash -n`/`sh -n`** on scripts and extracted inline shell
   (Tracks F, G).
4. **`ansible-playbook --syntax-check` / `--list-tasks` / `--list-tags` /
   `--check`** against a localhost dummy inventory — check mode only, never
   a real apply (Track C).
5. **Written adversarial walkthroughs** of the Track B scenario catalog,
   each a numbered trace with file:line citations.
6. **Coverage matrix** cross-referencing invariants × guards (Track H).

**`HW-ONLY` constraint:** anything requiring real kernel/udev/radio behavior
— the add→move race timing, actual `iw reg set` latency, RTL8822BU
re-enumeration and the >900-byte black hole, real boot timings
(`systemd-analyze critical-chain`), carrier-bounce behavior, rfkill
phy-index mapping on multi-radio boxes — is analyzed statically for logic
defects, and its end-to-end confirmation is written up as a one-line bench
procedure tagged `HW-ONLY` in the findings register.

## 4. Severity rubric (flight-link tailored)

| Severity | Definition | Examples |
|---|---|---|
| **S1** | Flight link fails to come up, drops in flight, or fails to recover **autonomously**; or provisioning can strand a fielded box. | Daemon starting on domain 00 with no retry; start-limit permanently failing the AP unit; PSK escaping bug after rotation. |
| **S2** | Link up but degraded (latency/jitter/throughput affecting control or telemetry); **or** a verification/CI gap that would let an S1 regression ship undetected. | Power-save re-enabled on one path; MTU black hole re-exposed; health check blind to crash loops; CI green on an `ACTION=="add"` revert. |
| **S3** | Operational/maintainability risk: partial-run breakage, confusing failure modes, docs drift with operational blast radius, secrets-workflow footguns, handler-order fragility. | Divergent vault-pass minting; alphabetized handlers breaking reload-before-restart; stale diagrams. |
| **S4** | Hygiene: lint, machine-readability, style, dead vars. | Exit code losing failure identity; shellcheck info-level notes. |

Per-finding modifiers: `HW-ONLY` (validation deferred to bench), `DOC` (a
documented, deliberately accepted risk — the finding then re-examines
whether the acceptance is still justified), `LATENT` (needs a second
precondition to bite).

## 5. Deliverables (written by the exam execution, locations fixed now)

1. **`docs/exam/findings.md`** — the findings register. One row + one
   subsection per finding: ID (`EX-<track><nn>`), severity + modifiers,
   track, title, evidence (file:line, rendered excerpts, shellcheck output,
   walkthrough trace), the quoted in-tree comment it relates to (if any),
   concrete failure scenario, a 2–4 line non-binding fix sketch, a test
   sketch for the iteration-2 guard, and status (`open`).
2. **`docs/exam/invariants.md`** — every comment-encoded field-incident
   invariant, numbered, classified `code-enforced` / `testable-untested` /
   `HW-ONLY` / `unguarded`. This is the durable artifact even if individual
   findings are disputed.
3. **CI coverage matrix** — appendix in findings.md: invariant ×
   {ansible-lint, syntax-check, each proposed guard}.
4. **Field signal inventory** — appendix in findings.md (from Track J):
   each field-incident class × the signal that detects/diagnoses it ×
   current status (`diagnosable-from-current-logs` / `needs-new-probe` /
   `undetectable`). This is the requirements document for the iteration-2
   monitoring toolkit.

`docs/exam/` keeps audit artifacts versioned next to the docs they
cross-reference and out of the role tree that ansible-lint scans.

## 6. Execution order & effort

Mechanical/rendering tracks run first so the paper walkthroughs argue from
real rendered text, not memory. Within Tracks A/B, front-load the S1
candidates: tune-timeout-vs-`Wants=` semantics, start-limit vs
`Restart=always`, PSK escaping, udev match-key logic.

| # | Track | Effort |
|---|---|---|
| 1 | D — Template rendering | 0.5 day |
| 2 | G — shellcheck sweep | 0.25 day |
| 3 | A — Boot sequence & races | 1 day |
| 4 | B — Failure modes & recovery | 1 day |
| 5 | C — Idempotency & convergence | 0.75 day |
| 6 | F — Health-check coverage | 0.5 day |
| 7 | J — Field observability & monitoring | 0.5 day |
| 8 | E — Secrets & vault | 0.25 day |
| 9 | I — Performance & docs drift | 0.5 day |
| 10 | H — CI gap matrix | 0.25 day |
| — | Register write-up & severity calibration pass | 0.5 day |

Total: ~6 focused days. Track J runs right after F because it needs the
A/B invariant catalog and F's inventory of what the health check already
observes.

## 7. Iteration 2 (what the exam feeds — sketch only)

- **Fix backlog**: findings sorted S1→S4, batched by file to minimize churn
  in the comment-dense files.
- **CI additions** from the Track H matrix: shellcheck job; template-render
  step reusing the Track D harness (`nft -c`, `systemd-analyze verify`,
  `udevadm verify`); containerized `--check` run against a synthetic
  inventory for both roles; an invariant-test script asserting the udev rule
  covers non-remove actions, handler order, and `enabled: false` presence.
- **health-check.sh hardening**: on-box probes the exam identifies (large
  ping for the MTU black hole, `systemctl show -p NRestarts` crash-loop
  detection), machine-readable output.
- **Field monitoring toolkit** (from the Track J signal inventory): on-box
  continuous monitors under the subtraction-thesis constraints (link-flap
  recorder, udev-event logger, `NRestarts` alarm on a timer); ground-side
  link-quality recorder (RTT/loss trend, periodic large-ping,
  `iw station dump` capture); a post-flight journal/metrics harvest
  procedure; journal retention settings sized so incidents survive until
  harvest.
- **Bench-day runbook**: the collected `HW-ONLY` procedures.
- **Docs refresh**: Track I drift findings applied to README, rationale, and
  diagrams.
