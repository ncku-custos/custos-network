# Repo-Wide Reliability Exam — Implementation Runbook

Status: **runbook** (exam execution plan). This document turns
`docs/exam/plan.md` — the approved exam plan (tracks A–J, severity rubric
S1–S4, deliverables, execution order) — into a concrete, resumable,
step-by-step procedure. An executor (a Claude Code agent session or a
human) follows this document to *run* the exam. Nothing here changes the
code under audit.

**Iteration numbering.** `plan.md` folds exam execution *and* fixes into
"iteration 2". This runbook splits that: **iteration 2 = running the exam
(this document)**; **iteration 3 = the fix/CI/monitoring backlog** the exam
feeds (what plan.md §7 sketches). Where plan.md says "iteration 2 builds
the guards", read "iteration 3" here.

**Authoritative references.** The exam plan defines *what* to examine and
*why*; this runbook defines *how*. On any conflict, plan.md wins on
scope/severity/questions; this runbook wins on mechanics.

---

## 0. Progress checklist

The executor updates this checklist as part of each phase's commit. This is
the resume point for every new session: read this checklist, read the tail
of `findings.md`, continue at the first unchecked phase.

- [ ] Phase 0 — Environment setup + scaffolding committed
- [ ] Phase 1 — Track D (template rendering) complete, committed
- [ ] Phase 2 — Track G (shellcheck sweep) complete, committed
- [ ] Phase 3 — Track A (boot sequence & races) complete, committed
- [ ] Phase 4 — Track B (failure modes & recovery) complete, committed
- [ ] Phase 5 — Track C (idempotency & convergence) complete, committed
- [ ] Phase 6 — Track F (health-check coverage) complete, committed
- [ ] Phase 7 — Track J (field observability) complete, committed
- [ ] Phase 8 — Track E (secrets & vault) complete, committed
- [ ] Phase 9 — Track I (performance & docs drift) complete, committed
- [ ] Phase 10 — Track H (CI gap matrix) complete, committed
- [ ] Phase 11 — Calibration pass complete, committed
- [ ] Phase 12 — Quality gate passed, final commit pushed

---

## 1. Ground rules

### 1.1 Out-of-scope fence

- **No edits outside `docs/exam/`.** No fixes to tasks, templates, scripts,
  units, or docs — however obvious. Every defect becomes a finding, nothing
  more.
- **No CI changes.** `.github/workflows/ci.yml` and `.ansible-lint` are
  exam *subjects*, not exam outputs.
- **No real apply.** `ansible-playbook` runs are limited to
  `--syntax-check`, `--list-tasks`, `--list-tags`, and `--check` against
  the dummy inventory (§2.3). Never against `ansible/inventory.ini` hosts.
- **Permitted side effects** (exam container only): apt/pip tool installs
  (§2.1); rendered files and logs under the scratch dir (§1.3); a possible
  `.vault-pass` minted by `vault-pass.sh` when ansible first runs
  (git-ignored; observing this mint is itself Track E evidence — record it,
  don't prevent it).

### 1.2 Deliverables

| Artifact | Location | Origin |
|---|---|---|
| Findings register | `docs/exam/findings.md` | plan §5.1 |
| Invariant catalog | `docs/exam/invariants.md` | plan §5.2 |
| CI coverage matrix | appendix A in findings.md | plan §5.3 |
| Field signal inventory | appendix B in findings.md | plan §5.4 |
| **This runbook** | `docs/exam/implementation.md` | new |
| **Render harness** | `docs/exam/harness/` | new — committed so the iteration-3 CI render step can reuse it verbatim (plan §7 wants the Track D harness as the CI seed). Only harness *source* is committed; rendered outputs stay in scratch. |
| **Long-form traces** | `docs/exam/traces.md` | new — the Track A boot-graph and Track B scenario walkthroughs are multi-page evidence; keeping them out of findings.md keeps the register scannable. Findings cite trace anchors. |

`docs/exam/` stays outside the role tree, so ansible-lint (production
profile) never sees any of it — CI must remain green on every exam commit.

### 1.3 Scratch discipline

All rendered output, validator logs, and extracted shell snippets go under
a scratch directory *outside* the repo:

```sh
export EXAM_SCRATCH="${EXAM_SCRATCH:-/tmp/custos-exam}"
mkdir -p "$EXAM_SCRATCH"
```

Scratch is disposable and regenerable (re-run the harness). Canonical exam
state lives **only** in committed `docs/exam/` files — this is what makes
the exam resumable across agent sessions.

### 1.4 Git workflow

- Execute on a branch cut from the plan branch (e.g.
  `claude/repo-reliability-exam-run`), or continue on the plan branch if
  plan and execution share a PR.
- **One commit per completed phase**, message pattern:
  `docs(exam): track D execution — EX-D01..EX-D07, INV-01..INV-09`.
  Each commit contains: new findings/invariants appended, the tick in §0,
  and (Phase 0 only) the harness + skeletons.
- Never rewrite an already-committed finding except during Phase 11
  (calibration) and Phase 12 (quality-gate corrections).

### 1.5 Finding and invariant bookkeeping

- **IDs.** `EX-<track><nn>` (e.g. `EX-D01`), allocated sequentially per
  track at write time, never renumbered. A finding later judged wrong is
  marked `status: withdrawn` — the ID slot is kept so uniqueness and
  sequence checks stay trivial. Invariants: `INV-<nn>`, one global
  sequence.
- **Severity is provisional until Phase 11.** Tag every severity
  `(provisional)` at write time; the calibration pass removes the tag or
  re-ranks.
- Formats are fixed once, in the Phase 0 skeletons (§2.4). Do not improvise
  per-track formats.

---

## 2. Phase 0 — Environment setup + scaffolding

Every later phase depends on the toolchain, the harness, and the skeleton
files; front-loading them makes each track phase self-contained and cheap
to resume.

### 2.1 Toolchain install (mirror CI pins where they exist)

```sh
# 1. Ansible toolchain — EXACTLY the CI pins (.github/workflows/ci.yml:27):
python3 -m pip install ansible-core==2.21.1 ansible-lint==26.4.0

# 2. shellcheck — apt first, static binary fallback:
sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y shellcheck \
  || { curl -fsSL https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.linux.x86_64.tar.xz \
       | tar -xJ -C "$EXAM_SCRATCH" && export PATH="$EXAM_SCRATCH/shellcheck-v0.10.0:$PATH"; }

# 3. Daemon parsers + udev (validator substitutes, see §2.2.3):
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends hostapd wpasupplicant udev
```

Already present and sufficient: `nft` (for `nft -c -f`), `systemd-analyze`
(for `verify`), `python3` + `jinja2`. Absent and deliberately **not**
installed: nothing else — yamllint and checkbashisms are not in CI and not
in the plan's methodology; do not widen the toolchain.

If the hostapd/wpasupplicant install fails (container postinst quirks are
possible), do **not** fight it: fall back to grammar-table-only validation
(§2.2.3) and record the substitution in findings evidence.

**Environment record.** Capture `nft --version`, `systemd-analyze
--version`, `shellcheck --version`, `hostapd -v` (prints version to
stderr), `wpa_supplicant -v`, `python3 -c 'import jinja2;
print(jinja2.__version__)'`, `ansible --version`, `ansible-lint --version`
into a "Toolchain record" section at the top of `findings.md`. Every piece
of validator evidence is reproducible only relative to these versions — and
`hostapd -v` directly feeds the Track D "2.10 vs 2.11 option set" question.

### 2.2 Render harness — `docs/exam/harness/`

Committed layout (source only; outputs go to `$EXAM_SCRATCH/render/`):

```
docs/exam/harness/
  render.py          # renders all templates across the matrix
  matrix.py          # cell definitions (data only, imported by render.py)
  checkers.py        # udev-rule lexer, INI-shape lexer, env-fragment checker
  inventory-exam/
    hosts.ini        # dummy localhost inventory for Track C (see §2.3)
  README.md          # 10 lines: how to run, how iteration-3 CI should call it
```

#### 2.2.1 `render.py` requirements

- Jinja2 `Environment(undefined=StrictUndefined, trim_blocks=True,
  lstrip_blocks=True)` — an undefined variable must crash the render, and
  each crash is an immediate Track D finding.
- Must emulate the two Ansible-isms the templates use (verified: `| bool`
  ×4, `| comment` ×1, and `ansible_managed` in
  `99-custos-flight.rules.j2`): a `bool` filter with Ansible's truthy
  semantics (true/yes/on/1 strings), a `comment` filter prefixing each line
  with `# `, and `ansible_managed = "Ansible managed — exam render"`.
  `default()` is a Jinja2 builtin. **Record in findings evidence that
  renders came from this harness, not Ansible** — filter emulation is a
  known fidelity limit, cross-checked in Phase 5 (§3.5, the `--check
  --diff` fidelity probe).
- CLI: `python3 docs/exam/harness/render.py --outdir "$EXAM_SCRATCH/render"
  [--cell CELL_ID]`. One directory per cell, one rendered file per
  applicable template. Exit nonzero if any render fails.
- Base variables = `ansible/roles/custos_network/defaults/main.yml` values.
  Note `custos_network_role` and `custos_network_ap_bssid` are
  deliberately **not** defaulted (the role asserts them) — the matrix
  supplies them per cell. The PSK is set to the sentinel
  `EXAM-SENTINEL-PSK-a1` so Track E can grep all *non-secret* rendered
  files to prove the PSK never leaks into e.g. `custos-network.env`.

#### 2.2.2 The matrix (`matrix.py`)

Full cross — 16 base cells, ID pattern `{role}-nat{0|1}-{vht|ht40}-{iface}`:

| Axis | Values |
|---|---|
| role | `ap` / `sta` (sta adds `custos_network_ap_bssid: 00:11:22:33:44:55`) |
| nat | `false` / `true` (true adds `custos_network_uplink_iface: eth0`) |
| vht | `true` / `false` (the HT40 escape hatch) |
| iface | `wlan0` / `wlx001122334455` |

Plus targeted overlay cells:

| Cell ID | Delta on base | Probes |
|---|---|---|
| `o-country-us` | ap-nat0-vht-wlan0 + `country: US` | non-default country rendering |
| `o-psk-special-ap`, `o-psk-special-sta` | PSK containing quote, dollar, hash, space, backtick, backslash | the S1 PSK-quoting candidate: hostapd and wpa_supplicant quoting rules diverge |
| `o-alt-triple` | ap, `channel: 36, freq: 5180, vht_seg0: 42`, both vht values | channel/freq/seg0 arithmetic coherence (the valid triples are enumerated at `defaults/main.yml:16-17`) |
| `o-uplink-usb0` | sta-nat1 + `uplink_iface: usb0` | nft render with a tether-style uplink name |

Per-cell template applicability (confirm against `tasks/main.yml` and
`tasks/nat.yml` before finalizing `matrix.py`; record any surprise as a
finding):

- All cells: `99-custos-flight.rules.j2`, `99-custos-unmanaged.conf.j2`,
  `custos-network.env.j2`, `flight.network.j2`
- `ap` cells: `hostapd.conf.j2`, `custos-hostapd.service.j2`
- `sta` cells: `wpa_supplicant.conf.j2`
- `nat1` cells: `custos-nat.nft.j2`

#### 2.2.3 Validator assignments (substitution decisions, settled here)

The environment lacks several native validators; these substitutions are
**decided now** so execution doesn't relitigate them:

| Rendered/static file | Primary validator | Notes / justification |
|---|---|---|
| `custos-nat.nft` | `nft -c -f <file>` | Native dry-run; run as root if permission errors appear. |
| `custos-hostapd.service` (rendered) + static units `files/custos-wifi-tune@.service`, `files/custos-nat.service`, `files/var-log-journal.mount` | `systemd-analyze verify --man=no <path>` | Copy all units into one scratch dir per cell so cross-references resolve. Verify the template unit as an instance: `cp custos-wifi-tune@.service $d/custos-wifi-tune@wlan0.service` and verify that path (the basename supplies `%i`). Missing-ExecStart-binary warnings disappear once hostapd/wpasupplicant are installed (§2.1); disposition every remaining warning explicitly (finding, or "benign, because …"). |
| `hostapd.conf` | Parse smoke test: `hostapd -dd <conf>` | **Decision:** hostapd has **no official config-test flag** (`-t` only timestamps debug output — do not present it as a config check). Pragmatic dry-run: hostapd fully parses the config *before* driver init, so run it against the rendered conf on this radio-less box and classify the failure — `Line N: …` config errors are a finding; failure at interface/driver init means grammar passed. **Mandatory regardless of smoke-test result:** an option-by-option grammar table checked against the shipped reference (`zcat /usr/share/doc/hostapd/examples/hostapd.conf.gz`, or the w1.fi reference for the recorded version). |
| `wpa_supplicant.conf` | Parse smoke test: `wpa_supplicant -c <conf> -i exam0 -dd` | **Stated explicitly: wpa_supplicant configs cannot be dry-run validated — no such official mode exists.** The smoke test (the config is read before the nonexistent interface fails) plus a manual option-by-option review against `wpa_supplicant.conf(5)` is the accepted substitute, and findings evidence must say so. |
| `99-custos-flight.rules` | `checkers.py` udev lexer (committed) | **Decision:** the committed Python lexer is the required check; `udevadm verify` is an optional bonus if the `udev` package installed *and* provides it (needs systemd ≥ 254). Rationale: the lexer is deterministic, version-independent, and reusable verbatim by iteration-3 CI, which may also lack a new-enough udevadm. Lexer scope: token structure `KEY<op>"value"` with ops `==`, `!=`, `=`, `+=`; comma separation; balanced quotes; `GOTO`/`LABEL` targets resolve; known key names (`ACTION`, `SUBSYSTEM`, `NAME`, `ENV{…}`, `TAG`, `GOTO`, `LABEL`). It is a *lexer sanity check*, not udev semantics — the semantic audit (the AND-vs-OR reading, event coverage) is Track A paper work. |
| `flight.network`, `99-custos-unmanaged.conf`, static `10-custos-tune.conf`, `50-custos-journal.conf`, `90-custos-nat.conf` | `checkers.py` INI-shape lexer + manual directive review | No official validators exist for networkd `.network` files, NM `conf.d`, journald conf, or `sysctl.d` (`systemd-analyze verify` covers *units* only). The lexer checks section and `Key=Value` shape and duplicate-key tolerance; the manual review checks every directive name against `systemd.network(5)` / `journald.conf(5)` / `sysctl.d(5)` / NM documentation and records a per-directive verdict table. |
| `custos-network.env` | `env -i sh -uec '. <file>; echo OK'` + CRLF grep + sentinel grep | Exercises the real consumer contract: `scripts/lib.sh` and `files/custos-wifi-tune` source this under `set -u` on the boot path (plan Track D). Also inspect the quoting of every rendered value by eye — the template writes values unquoted. |

### 2.3 Dummy inventory — `docs/exam/harness/inventory-exam/hosts.ini`

```ini
# Exam-only inventory: local connection, never a real host, never inventory.ini.
[drone]
exam-drone ansible_connection=local ansible_host=127.0.0.1

[ground]
exam-ground ansible_connection=local ansible_host=127.0.0.1

[custos:children]
drone
ground
```

Design notes: distinct hostnames (`exam-*`) so nothing can collide with a
real operator checkout carrying git-ignored `host_vars/<host>.yml`; group
names match the real topology so the committed
`ansible/group_vars/{drone,ground,custos}` files load exactly as in
production (intentional — it exercises the real var chain). Selected only
ever via an explicit `-i ../docs/exam/harness/inventory-exam/hosts.ini`,
which overrides `ansible.cfg`'s `inventory = inventory.ini` — the real
inventory is never touched.

### 2.4 Skeleton files (formats fixed here, used everywhere)

**`docs/exam/findings.md`** — create with: title; toolchain record (§2.1);
a register index table `| ID | Sev | Modifiers | Track | Title | Status |`
(kept sorted by severity from Phase 11 onward); empty appendix A (CI
coverage matrix) and appendix B (field signal inventory); then one
subsection per finding:

```markdown
## EX-D01 — <one-line title>
- **Severity:** S2 (provisional) · Modifiers: HW-ONLY, LATENT
- **Track:** D · **Status:** open
- **Evidence:** <file:line refs; rendered-file quote + cell ID; validator output excerpt; trace anchor>
- **In-tree comment:** "<verbatim quote>" (<file:line>) — or "none"
- **Failure scenario:** <concrete: initial state → event → wrong outcome>
- **Fix sketch:** <2–4 lines, non-binding>
- **Test sketch:** <what the iteration-3 guard asserts>
- **HW-ONLY bench procedure:** <one line, only if HW-ONLY>
```

**`docs/exam/invariants.md`** — create with title plus one table:

```markdown
| ID | Invariant (one sentence) | Source (file:line + quoted comment) | Class | Guard today | Findings |
```

`Class` ∈ `code-enforced` / `testable-untested` / `HW-ONLY` / `unguarded`
(plan §5.2). `Guard today` names the CI step or code construct, or `none`.

**`docs/exam/traces.md`** — create with title and empty sections
`## Track A — boot dependency graph & start-path traces` and
`## Track B — scenario traces` with ten numbered stubs (B-1 … B-10)
matching plan Track B's catalog.

### 2.5 Phase 0 exit criteria

- Toolchain installed; versions recorded in findings.md.
- `render.py` runs end-to-end: every cell renders, or every failure is
  understood (StrictUndefined crashes logged for Track D).
- `ansible-playbook site.yml --syntax-check` succeeds from `ansible/` with
  the pinned toolchain (smoke test only — analysis belongs to Phase 5).
- Skeletons + harness committed as the Phase 0 commit.

---

## 3. Track phases

Order (per plan §6, unchanged): **D → G → A → B → C → F → J → E → I → H**.
Mechanical and rendering phases run first so the paper walkthroughs argue
from real rendered text; J follows F because it consumes the A/B invariant
catalog and F's observation inventory; H is last because it is pure
aggregation. Every phase ends with findings and invariants appended, traces
updated if applicable, the checklist ticked, and one commit.

Common per-phase loop:

1. Re-read the track's section in `plan.md` — its question list is the test
   sheet; every question gets a written verdict somewhere (finding,
   invariant note, or trace paragraph).
2. Execute the procedure below; keep raw outputs in
   `$EXAM_SCRATCH/track<X>/`.
3. Write findings and invariants in the skeleton format; cite evidence with
   file:line that resolves against HEAD.
4. Commit.

### Phase 1 — Track D: template & rendering correctness

**Inputs:** all 8 `templates/*.j2`, the static `files/*` configs and units,
the harness.

**Procedure:**

1. `python3 docs/exam/harness/render.py --outdir "$EXAM_SCRATCH/render"` —
   all cells from §2.2.2.
2. Run every validator from the §2.2.3 table over every applicable
   rendered/static file; tee outputs to `$EXAM_SCRATCH/trackD/`.
3. Close-reading passes keyed to plan Track D's questions, against rendered
   text (not template source): VHT80/HT40 branch coherence including the
   `o-alt-triple` cells; PSK rendering in the `o-psk-special-*` cells
   (byte-for-byte comparison of how `wpa_passphrase=` and `psk="…"` carry
   the sentinel-with-specials, against each daemon's documented quoting
   rules); `bgscan=""` semantics; `[Match]` on `wlx…` names; the MSS clamp
   direction and the declare-delete-define atomicity claim in the rendered
   nft file; env-fragment quoting and CRLF; option names against the
   recorded hostapd/wpa_supplicant versions.
4. Every validator warning or error gets an explicit disposition line
   (finding, or justified-benign) in
   `$EXAM_SCRATCH/trackD/dispositions.md`, summarized into findings
   evidence.

**Outputs:** findings `EX-D*`; the first tranche of invariants (each
template's implicit contracts); validator evidence.

**Exit criteria:** every applicable (template × cell) pair rendered and
validated with output recorded; all plan-D questions answered in writing;
zero undispositioned validator complaints.

### Phase 2 — Track G: shell robustness sweep

**Inputs:** `files/custos-wifi-tune`, `scripts/health-check.sh`,
`scripts/lib.sh`, `ansible/vault-pass.sh`; inline shell in YAML; ExecStart
lines.

**Procedure:**

1. Detect each script's dialect from its shebang, then per file:
   `shellcheck -x -S style <file>`, plus `bash -n` or `sh -n` to match.
2. Extract every inline shell block from the YAML (grep for `shell:`,
   `cmd:`, and argv-style `bash -c` / `sh -c` payloads in `tasks/*.yml`)
   into `$EXAM_SCRATCH/trackG/inline/NN-<taskname>.sh` with a header
   comment citing file:line; run shellcheck with the correct `-s` dialect
   (the apt-probe payload near `tasks/main.yml:64` is `bash -c` with
   `/dev/tcp` — bash dialect; the pre-stage probe must pass under `-s sh`,
   POSIX, per plan).
3. ExecStart lines are **not** shell — manually check each for shell
   metacharacters that systemd would pass literally; record verdicts.
4. Verify the specific plan-G claims: the `rfkill unblock "${idx:-wlan}"`
   fallback at `files/custos-wifi-tune:25-27` against the invariant comment
   at line 20 (the script-contradicts-its-own-comment candidate); every
   `awk '{…; exit}'` pipeline for SIGPIPE-under-pipefail; whether the
   in-tree `# shellcheck` directives are still accurate.
5. Save full shellcheck output as evidence for Track H's CI-gap finding.

**Outputs:** `EX-G*`; invariants for documented shell contracts.

**Exit criteria:** every script and every extracted inline block has
recorded shellcheck and `-n` output; every warning dispositioned; plan-G
questions answered.

### Phase 3 — Track A: boot sequence & race conditions

**Inputs:** Track D's rendered units and rules (argue from rendered text),
the static units, the ordering commentary in `tasks/main.yml`.

**Procedure — the written-trace contract.** All work lands in
`traces.md § Track A`, which must contain:

1. **Edge table:** every `Wants=` / `After=` / `BindsTo=` / `Requires=` /
   `PartOf=` / `WantedBy=` / `SYSTEMD_WANTS` edge in the rendered and
   static unit text, one row each with file:line — built from unit text
   only, never from comments.
2. **Start-path enumeration:** every path that can start each daemon (udev
   coldplug, udev hotplug add→move, manual `systemctl start`, `networkctl
   reconfigure`, `Restart=` re-execution, dependency propagation), each
   traced event-by-event to "daemon associates" or to a dead end, for both
   AP and STA.
3. **Per-question verdicts** for every plan-A bullet, each a short
   paragraph ending in an explicit verdict plus citation. The
   tune-timeout-versus-`Wants=` question (plan's "single most important
   what-if") and the `Restart=always`-versus-start-limit question are
   written first and in the most detail (front-load S1 candidates, plan
   §6).
4. `HW-ONLY` tagging wherever a conclusion depends on real kernel, udev, or
   radio timing, each with a one-line bench procedure.

**Outputs:** `EX-A*` (the expected home of the S1 candidates); the core of
the invariant catalog (every ordering guarantee the comments claim).

**Exit criteria:** edge table complete; all start paths traced; every
plan-A question has a verdict; every A-invariant classified in
invariants.md.

### Phase 4 — Track B: failure modes & autonomous recovery

**Inputs:** Track A's graph and traces; rendered configs; task files.

**Procedure:** for each of the ten catalogued scenarios (plan Track B),
write a numbered trace in `traces.md § Track B` with the fixed shape:
*initial state → perturbation → event-by-event system response (file:line
cited at every step) → end state → verdict: recovers autonomously /
recovers with operator / stuck (severity per rubric)*.

Scenario 10 (the five `failed_when: false` sites) is a five-row sub-table —
swallowed failure × downstream catch (file:line, or "none"). The sites at
HEAD are `tasks/main.yml:66`, `tasks/main.yml:103`, `tasks/journal.yml:21`,
`tasks/journal.yml:46`, `tasks/journal.yml:62`; re-verify the exact lines at
execution time rather than trusting these numbers, and note that each is
paired with a nearby `check_mode: false` (`main.yml:68`, `main.yml:105`,
`journal.yml:23`, `journal.yml:48`) whose read-only status Phase 5 must
confirm.

**Outputs:** `EX-B*`; recovery invariants.

**Exit criteria:** all ten scenarios traced to an end state; every
`failed_when: false` site dispositioned; every "stuck" end state has a
finding.

### Phase 5 — Track C: Ansible idempotency, convergence & handler ordering

**Inputs:** `tasks/*.yml`, `handlers/main.yml`, `site.yml`, `defaults`,
`group_vars`, `ansible.cfg`, the dummy inventory.

**Procedure** (run from `ansible/`, so `ansible.cfg` applies as in CI; tee
everything to `$EXAM_SCRATCH/trackC/`):

```sh
ansible-playbook site.yml --syntax-check
ansible-playbook -i ../docs/exam/harness/inventory-exam/hosts.ini site.yml --list-tasks
ansible-playbook -i ../docs/exam/harness/inventory-exam/hosts.ini site.yml --list-tags
ansible-playbook -i ../docs/exam/harness/inventory-exam/hosts.ini site.yml --list-tasks --tags nat
```

**Before any `--check` run:** grep the role for `check_mode: false` and
confirm by reading each hit that it is genuinely read-only. At HEAD there
are five: `tasks/main.yml:68`, `tasks/main.yml:105`, `tasks/nat.yml:25`,
`tasks/journal.yml:23`, `tasks/journal.yml:48`. This is also a plan-C
question — record a verdict per site. Only then:

```sh
ansible-playbook -i ../docs/exam/harness/inventory-exam/hosts.ini site.yml --check --diff -vv
ansible-playbook -i ../docs/exam/harness/inventory-exam/hosts.ini site.yml --check --diff -vv --tags nat
```

Expectations to record, not fix: `vault-pass.sh` may mint `.vault-pass`
(git-ignored — Track E evidence); on a non-Debian container the apt branch
skips via its `ansible_os_family` guard (record which branch ran); some
tasks may fail in `--check` on a virgin host — each such failure is exactly
the evidence plan-C's check-mode question wants.

Then the paper analyses: full notify→handler chain enumeration with a
declaration-order proof that daemon-reload precedes every restart across
both `flush_handlers` barriers (`tasks/main.yml:173`, `tasks/main.yml:293`)
plus the "alphabetized handlers" counterfactual; the tag-closure audit for
`--tags nat` from the `--list-tasks --tags nat` output; re-run convergence
**statically** (every `command`/`shell` task's `changed_when`/`creates` — a
real apply-twice is out of scope per the plan's methodology; record the
containerized double-apply as an iteration-3 test sketch); the
`ansible_host`-hostname validation hole at `tasks/main.yml:24-27`; and a
variable-hygiene sweep (every `custos_network_*` var has a default or an
assert — note `custos_network_role` and `custos_network_ap_bssid` are
intentionally undefaulted per `defaults/main.yml:49-52` — plus the
`custos_network_env` unset-in-a-fork case).

**Fidelity probe:** compare at least `flight.network` from the `--check
--diff` output against the harness render for the matching cell; note any
divergence as a harness-fidelity caveat in findings.

**Outputs:** `EX-C*`; handler, tag, and variable invariants.

**Exit criteria:** all commands above ran and outputs archived; every
plan-C question has a written verdict; the notify-chain table is complete.

### Phase 6 — Track F: health-check & verification coverage

**Inputs:** `scripts/health-check.sh`, `scripts/lib.sh`, the invariants
from A and B.

**Procedure:** build a check-by-check audit table (check → mechanism →
false-pass risk → false-fail risk → verdict). Test each suspect grep
empirically with synthetic input, e.g.:

```sh
printf '3: wlan0: <BROADCAST,MULTICAST,LOWER_UP> ...' | grep -qw UP; echo $?
printf 'inet 192.168.4.21/24 ...' | grep -qw 192.168.4.2; echo $?
```

(the dot-as-word-boundary and `LOWER_UP` probes from plan-F). Verify the
no-`-e` pipeline-masking claim by tracing each pipeline's exit-status
consumption. Then the coverage-gap cross-reference: for every A/B
invariant, does any health check observe it? (tune-oneshot success,
crash-loop visibility, a large-ping MTU probe, journal persistence,
machine-readable exit identity — each absent check is a finding feeding
iteration 3.) Finally the `lib.sh` fallback-defaults question (a partial
pass on an unprovisioned box).

**Outputs:** `EX-F*`; the "what the acceptance gate observes" inventory
(input to Track J).

**Exit criteria:** every check in the script has a table row; every grep
suspicion resolved empirically; the coverage cross-reference is complete.

### Phase 7 — Track J: field observability & monitoring

**Inputs:** the A/B invariant catalog (especially HW-ONLY entries), F's
observation inventory, `files/50-custos-journal.conf`, `tasks/journal.yml`,
`files/var-log-journal.mount`, unit logging directives, daemon-config
logger settings, the README Gotchas section (the incident source list).

**Procedure:** build the **signal inventory** as findings.md appendix B —
one row per field-incident class or HW-ONLY invariant, with columns:
incident, detecting/diagnosing signal, signal source
(journal/udev/networkd/ground-side probe), classification
(`diagnosable-from-current-logs` / `needs-new-probe` / `undetectable`).
Then the four audits from plan-J: log-content sufficiency at default
verbosities (inspect the rendered hostapd/wpa_supplicant logger settings
from Track D output, plus networkd and udev defaults); 50 M retention
versus crash-loop journal spam (rate-limit settings against the cap, a
back-of-envelope eviction window — show the numbers); point-in-time →
continuous candidates with an explicit subtraction-thesis budget check per
candidate (no off-channel scans, no TCP on the flight link, bounded CPU and
eMMC — a violating monitor proposal is itself recorded as such); the
ground-side versus drone-side observability split; and the harvest-path
existence check (expected: none — that is a finding).

**Outputs:** `EX-J*`; appendix B complete (this is the iteration-3
monitoring-toolkit requirements document).

**Exit criteria:** every incident class from the README Gotchas and every
HW-ONLY invariant has a classified row; all five plan-J question groups
answered in writing.

### Phase 8 — Track E: secrets & vault handling

**Inputs:** `ansible/vault-pass.sh`, `ansible.cfg`, `.gitignore`,
`group_vars/custos/*`, the PSK-bearing tasks.

**Procedure:** close-read `vault-pass.sh` (the first-run mint asymmetry,
the post-`tr` entropy floor, the concurrent-first-run race — plan-E).
Evidence runs:

```sh
git log --all --full-history --oneline -- .vault-pass ansible/group_vars/custos/vault.yml
git log --all -p -S 'vault_wifi_psk' -- . | head -100        # history spot-check
grep -rn 'no_log\|diff: false' ansible/
grep -rl 'EXAM-SENTINEL-PSK-a1' "$EXAM_SCRATCH/render"       # leak check: must match ONLY hostapd.conf / wpa_supplicant.conf renders
```

The sentinel grep is the mechanical proof for "the world-readable
`/etc/custos-network.env` never carries the PSK". Audit `no_log` coverage
on every PSK-bearing template and assert task, and whether task *failure*
output can embed rendered PSK content. Record the Phase 5 `.vault-pass`
mint observation (did a `--check` run mint it, and with what permissions?).

**Outputs:** `EX-E*`.

**Exit criteria:** all plan-E questions verdicted; history spot-check
recorded; sentinel grep result recorded.

### Phase 9 — Track I: performance / boot latency & docs drift

**Inputs:** everything rendered; `README.md`, `docs/rationale.md`,
`docs/intro.md`, `docs/*.d2`.

**Procedure:**

- **(a)** Paper boot-latency budget table: coldplug → udev → tune (0–10 s
  poll ceiling) → daemon start → association; mark serial segments that
  could overlap; assess the 10 s ceiling against hostapd's restart-retry
  (correctness stays Track A's).
- **(b)** `timeout`-type survival: inspect the rendered argv for the apt
  probe (`custos_network_apt_probe_timeout`, `defaults/main.yml:47`,
  templated into `timeout`).
- **(c)** Journald write-amplification assessment on the 50 M and
  rate-limit settings.
- **(d)** MSS/MTU arithmetic against VHT80/HT40 and the >900-byte black
  hole across the rendered nft and hostapd combinations.
- **(e)** Docs drift sweep: extract every concrete claim (file, unit, IP,
  option, behavior) from the four doc sources and the D2 diagrams into a
  claims table; verify each with `git grep` or file inspection; a claim
  that names something nonexistent or misstates behavior becomes a finding,
  severity by operational blast radius (the "docs imply boot-enabled units"
  class is the S3 archetype per plan).

**Outputs:** `EX-I*`.

**Exit criteria:** latency table written; claims table complete with a
verdict per claim.

### Phase 10 — Track H: CI & automation gap matrix

**Inputs:** the finished invariants.md, all track findings, `ci.yml`,
`.ansible-lint`.

**Procedure:**

- **(a)** Reproduce the lint-discovery gotcha as evidence: `ansible-lint`
  from the repo root (expect >0 files — record the count) versus from
  `ansible/` (expect 0 files — the documented gotcha at `ci.yml:29-30`).
- **(b)** Review the pins (ansible-core 2.21.1, ansible-lint 26.4.0;
  optionally `pip index versions` for staleness context).
- **(c)** Build findings.md **appendix A**: rows = every invariant in
  invariants.md; columns = `ansible-lint`, `syntax-check`, and each
  proposed iteration-3 guard (shellcheck job, harness render step, `--check`
  container run, invariant-test script, field monitor per appendix B); each
  cell: catches / misses / partial. Every all-miss row for a
  `testable-untested` or `unguarded` invariant becomes (or joins) a finding
  in the plan's "process gap protecting an S1 behavior" shape. Cross-check
  the field-detectability column against appendix B.

**Outputs:** `EX-H*`; appendix A complete.

**Exit criteria:** the matrix has a row for every invariant and no empty
cells; lint-discovery evidence recorded.

---

## 4. Phase 11 — Calibration pass

A single sitting, whole register at once:

1. Re-read every finding against the S1–S4 rubric (plan §4), **comparing
   findings to each other**, not just to the rubric text; re-rank for
   consistency; remove every `(provisional)` tag.
2. Verify modifier usage: every `HW-ONLY` has a bench line; every `DOC`
   finding re-examines whether the documented acceptance still holds; every
   `LATENT` names its second precondition.
3. Cross-link: every finding lists the invariants it evidences; every
   invariant lists its findings.
4. Sort the register index table S1→S4; verify per-track ID sequences have
   no gaps (withdrawn entries hold their slots).
5. Merge or split duplicates discovered across tracks (keep both IDs; one
   becomes `status: merged-into EX-XNN`).

Commit as the calibration commit.

## 5. Phase 12 — Wrap-up & quality gate

A quality gate on the exam's own output (N = max(8, 20% of findings)):

1. **Evidence spot-check:** for N sampled findings, open every cited
   file:line at HEAD and confirm the line exists and the quoted text
   matches verbatim (`sed -n '<N>p' <file>`); confirm cited rendered
   excerpts match a re-run of the harness.
2. **ID integrity:** `grep -oE 'EX-[A-J][0-9]{2}' docs/exam/findings.md |
   sort | uniq -d` returns nothing; per-track sequences are complete.
3. **Fence audit:** `git diff <base>...HEAD --name-only` shows only
   `docs/exam/**`.
4. **CI green:** the branch's CI run passes (docs-only changes must not
   perturb ansible-lint or the syntax check).
5. Fix any quality-gate failures (evidence corrections only — no
   re-scoping), tick the final checklist box, push.

## 6. Definition of done (whole exam)

- [ ] Every applicable template × matrix cell rendered; every validator
      output recorded and dispositioned.
- [ ] Track A edge table and start-path traces complete; every plan-A
      question verdicted.
- [ ] All ten Track B scenarios traced to an end state; all five
      `failed_when: false` sites dispositioned.
- [ ] Every plan question in every track (C, E, F, G, I, J) has a written
      verdict.
- [ ] Every invariant classified (`code-enforced` / `testable-untested` /
      `HW-ONLY` / `unguarded`); every HW-ONLY has a one-line bench
      procedure.
- [ ] Every finding has evidence, a failure scenario, a fix sketch, and a
      test sketch; severities calibrated (no `(provisional)` remains).
- [ ] Appendix A (CI matrix) covers every invariant; appendix B (signal
      inventory) covers every incident class.
- [ ] Quality gate passed; CI green; all commits pushed.

## 7. Effort & session plan

Plan §6 estimates ~6 focused human days for the tracks plus calibration;
this runbook adds ~0.5 day of Phase 0, so **~6.5 human days** total:
Phase 0 (0.5) · D 0.5 · G 0.25 · A 1 · B 1 · C 0.75 · F 0.5 · J 0.5 ·
E 0.25 · I 0.5 · H 0.25 · calibration and gate 0.5.

**Agent execution.** The hard dependency spine is **Phase 0 → D → A → B →
(F) → J → H → calibration** (~4.25 day-equivalents of the total): A and B
must argue from D's rendered unit text, J needs the A/B invariant catalog
plus F's observation inventory, and H aggregates everything. G, C, E, and
most of I are independent after Phase 0 and can interleave or run in
parallel sessions. Suggested session boundaries, each ending on a committed
phase so resume cost stays near zero: S1 = Phase 0 + D; S2 = G (optionally
with E); S3 = A; S4 = B; S5 = C + F; S6 = J + I; S7 = H + calibration +
quality gate. Wall-clock will beat 6.5 days with an agent, but per-commit
human review remains the throttle — do not batch multiple phases into one
commit to "save time".

## 8. Iteration-3 handoff (sketch only — not executed in this iteration)

- **Fix backlog:** filter the findings.md index (already severity-sorted)
  to S1 and S2; batch by file to minimize churn in the comment-dense files
  (`tasks/main.yml`, `custos-wifi-tune`); each batch cites its findings.
- **CI additions** come straight from appendix A's all-miss rows: a
  shellcheck job (the Phase 2 command lines are the job spec); a
  template-render step reusing `docs/exam/harness/` verbatim (`render.py`
  plus validators — this is why the harness is committed); a containerized
  `--check` run reusing `inventory-exam/`; an invariant-test script
  generated from the `testable-untested` rows of invariants.md.
- **health-check.sh hardening** from Track F's gap findings; the **field
  monitoring toolkit** from appendix B's `needs-new-probe` rows, under the
  subtraction-thesis budgets recorded in Phase 7.
- **Bench-day runbook:** collect every HW-ONLY bench line from findings.md
  into one document.
- **Docs refresh:** the Track I claims-table drift rows.
