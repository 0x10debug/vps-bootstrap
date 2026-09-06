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
