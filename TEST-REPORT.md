# TEST-REPORT

Living per-iteration test report, maintained per the Testing Discipline iron
rule (main repo AGENTS.md, 2026-09-06).

Layer definitions: L1 static (bash -n, shellcheck, gitleaks, no-Chinese scan),
L2 config validation, L3 runtime smoke in a disposable environment, L4
host-level lifecycle.

---

## 2026-09-06T20:12:01Z — commit 3411970 + test-list fix (Round 2 Day 10-11 backfill: CI pipeline, legacy autoupdate removal, profiles groundwork)

**Layers executed: L1, L2, L3 (module suite). L4 not run.**

| Check | Result |
|---|---|
| L1 bash -n sweep (26 files + mb) | PASS |
| L1 shellcheck -S warning gate | PASS (0 findings; 18 fixed in iter/bootstrap-ci-tests) |
| L1 gitleaks history scan | PASS (exit 0) |
| L1 no-Chinese content scan | PASS |
| L2 config YAML parse (default/example/minimal) | PASS |
| L3 tests/test-modules.sh (Docker containers per module: syntax/source/function for 14 modules) | PASS after fix (exit 0) |

Defects found and fixed in this cycle:

- iter/bootstrap-ci-tests (pre-push, CI-verified): legacy `autoupdate` module
  removed alongside its duplicate implementation; 7 shellcheck warnings fixed.
- **This backfill cycle**: `tests/test-modules.sh` still listed the removed
  legacy `autoupdate` module, so the Docker suite failed its syntax check -
  a test-code drift that the static CI cannot catch. Fixed by dropping the
  module from the harness list; suite re-run green (14 modules).

Known issues (open):

- `autoupdate` help/audit references were audited clean at removal time; no
  further residue found in this cycle's greps.

Untested (honest boundaries):

- tests/test-idempotent.sh and tests/test-rollback.sh (full-init and rollback
  scenarios) not executed in this backfill cycle - they boot full init runs
  and are scheduled as L3 evidence for the profiles branch (iter/bootstrap-
  profiles) where init behavior actually changes.
- L4 host-level: SSH/firewall/kernel behavior on a real host not run - no
  disposable VM provisioned; blocked, not passed. Container tests do not
  exercise SSH survival or firewall semantics.

---

## 2026-09-11T18:38:22Z — commit eb1f9bf (Round 2 Day 12: iter/bootstrap-profiles)

**Layers executed: L1, L2, L3. L4 not run.**

| Check | Result |
|---|---|
| L1 bash -n (mb + all scripts) | PASS |
| L1 shellcheck -S warning gate (mb after --profile additions) | PASS (0 findings) |
| L2 profile YAML files parse (3 presets) | PASS (same loader as config files) |
| L3 Docker ubuntu:22.04, mb init --dry-run module resolution: minimal=4, standard=11, strict=14 modules; --module overrides profile; config/minimal.yaml toggles yield 4; unknown profile errors listing available; non-boolean toggle errors | PASS (7/7 cases) |

Defects found this cycle: none new. (Pre-existing finding addressed by this
iteration: config module toggles were parsed but never consumed - the
standard profile now makes them meaningful; fixed in eb1f9bf.)

Untested (honest boundaries):

- No module was actually executed with a profile on a real host (L4);
  dry-run proves selection, not module behavior.
- Interactive-mode behavior with profiles (non-interactive is forced by
  --profile) not re-tested beyond the dry-run path.

---

## 2026-09-11T19:37:03Z — commit e0bae4a (Round 2 Day 12: iter/bootstrap-rhel-family)

**Layers executed: L1, L2, L3 (real module execution on Rocky 9 + Debian regression suites). L4 not run.**

| Check | Result |
|---|---|
| L1 bash -n + shellcheck gate (mb, lib/, 7 touched modules) | PASS |
| L3 Rocky 9 container: OS detection (rhel/dnf), fail-fast on Rocky 8, minimal-profile selection, REAL system-module execution: all base packages installed (sudo/jq/chrony/gnupg2/policycoreutils-python-utils/htop/curl-minimal/weg/git), timezone set, exit 0 | PASS |
| L3 Debian regression: tests/test-modules.sh 14/14; tests/test-idempotent.sh 3x full init, all DONE and idempotent (errexit change does not break the Debian flow) | PASS |

Defects found and fixed in this cycle (all caught by actually executing
the module on Rocky 9, none visible to static gates):

1. **Silent module-failure swallowing** (all distros, high severity): the
   init dispatcher ran modules under `if ! func`, which suppresses errexit
   for the entire call chain - a failed package batch still marked the
   module done ("Succeeded: 1" with nothing installed). Modules now run in
   a subshell outside condition context with set -e enforced, exit code
   captured and reported.
2. `dnf/yum check-update` exit 100 (updates available) misread as failure
   in mb_pkg_update; normalized to success.
3. Rocky 9 curl-minimal vs curl package conflict broke the base-tool
   batch (also hidden by defect 1); tools are now family-specific, EPEL
   enables htop with metadata refresh, and timezone setup requires a
   running systemd bus rather than the mere presence of timedatectl.

Untested (honest boundaries):

- firewalld, crowdsec rpm, docker dnf, and motd.d branches were reviewed
  and syntax-verified but not executed end-to-end (no systemd in the test
  containers; docker install not pulled to keep the cycle time-boxed) -
  recorded as implemented_unverified at runtime.
- L4 host-level (SSH survival across firewalld/SELinux port changes on a
  real RHEL host) not run - blocked on a disposable VM.
