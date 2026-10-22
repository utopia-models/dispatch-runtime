#!/usr/bin/env bash
# sweep-dispatch.sh — THE CONSUMER OF `Status=Todo`. (#3418 · Feature #3415 · phase 2 of #3691)
#
# Until this file existed, nothing in the fleet dispatched work. Verified at the source, twice:
# `grep -rl dispatch.sh` across every workflow, timer, service, hook and script returned only
# documentation and registry prose. Every scheduled job OBSERVED the board — reconcile-board,
# board-linter, board-snapshot-publish, stuck-pr-sweep, hung-agent-detector — and not one ACTED on it.
# The scheduler was a human typing a command: 60/169 runs (36%) were re-dispatches across 28 issues,
# and 19 of those 28 (68%) needed a human comment between attempts to unstick them.
#
# ── WHAT IT IS NOT ────────────────────────────────────────────────────────────────────────────────
#   · NOT a new scheduling mechanism. It is a second ExecStart on bravo's EXISTING `reconcile-board`
#     oneshot (`OnUnitActiveSec=5min`) — see _infra/systemd/reconcile-board.service.d/. That timer
#     already wakes every 5 minutes and already reads this board; this is the one thing it was missing.
#     The drop-in re-declares BOTH ExecStart lines with a `-` prefix so neither job can suppress the
#     other: a failing reconciler used to mean the sweep would never run at all.
#   · NOT a GitHub Action. `ubuntu-latest` cannot reach the masters behind Tailscale, and Actions was
#     dead for 64 hours on 2026-08-01 (startup_failure before any YAML parsed).
#   · NOT a reimplementation of dispatch. It decides WHICH issue and WHICH master, then shells out to
#     `dispatch.sh` — the one place that knows how to start a run.
#   · NOT a closer. It starts work; the VERIFY tasks judge it. It never closes an issue or a Feature.
#   · NOT silent about what it refuses. Since #4182 it also ANNOUNCES the four rejection classes that mean
#     NOBODY IS COMING — see "THE ANNOUNCER" near the bottom of this file.
#
# ── THE PREDICATE ─────────────────────────────────────────────────────────────────────────────────
# An issue is dispatched only when ALL of these hold. Every one of them is a bound something already
# lost money on; none is decoration.
#   1. board Status == Todo                     — the field, read live, never a label or a marker
#   2. Lane ∈ alpha|bravo|charlie|delta or BLANK      — agent is off-box (the Architect's own laptop); a lane
#                                                 this box cannot reach is not a lane this box may
#                                                 dispatch. A BLANK Lane IS routable. Izzu's box has no
#                                                 valid lane value at all — the fleet does not route
#                                                 work to it (access stays, routing does not).
#   3. parent Feature is OPEN (or none)         — never drive a sub-issue of a closed Feature
#   4. every `blockedBy` dependency is CLOSED   — native GitHub issue dependencies, landed by #3693.
#                                                 Without this the sweep would have read #3641 as
#                                                 unblocked and dispatched it into #3637's live file.
#   5. no live `task-<n>-*` unit on any box     — the real anti-double-dispatch check, probed per cycle
#   6. last run-marker ∉ { ▶ , ✔ , ⛔ , ⚠ }          — ▶ = a run holds it (a VANISHED ▶ is #3419's job to
#                                                 convert, not this one's); ✔ = it shipped; ⛔ = the run
#                                                 declared a human-only step, and re-dispatching that is
#                                                 how a machine argues with a human; ⚠ = no-op (run exited
#                                                 cleanly but produced no artifact), NOT retryable indefinitely.
#                                                 ⚠ A ✔ on an OPEN issue is the TOMBSTONE (#4181): the
#                                                 success marker makes that issue permanently
#                                                 undispatchable and holds everything chained behind it.
#                                                 Flipping ✔ to non-terminal outright would re-dispatch
#                                                 genuinely finished work, so the fix is at the SOURCE
#                                                 (task-runner.sh verifies its own close landed) plus
#                                                 DETECTION here: `--explain | grep ✔-TOMBSTONE`.
#                                                 🔴 ONE narrowing (#4392): markers are read from the last
#                                                 REOPEN forward (`live_marks`). A reopen is an explicit
#                                                 "not finished" written AFTER the marker that said it
#                                                 was, so a ✔ older than it is the last word of a
#                                                 lifecycle that already ended. Finished work is not
#                                                 reopened, so this cannot re-dispatch it.
#                                                 ⚠ NOT every ✔ here is the tombstone (#4395, #4828), and
#                                                 the dividing line is PARENT-vs-LEAF, not the marker's
#                                                 wording. The tombstone's harm — permanently
#                                                 undispatchable, whole chain held — is a statement about
#                                                 a dispatchable LEAF. A parent Feature is closed by
#                                                 `stuck-pr-sweep.yml`, never by dispatch, so a ✔ sitting
#                                                 on one strands nothing. Explain therefore prints
#                                                 `✔-ROLLUP-ATTESTED` / `✔-ON-PARENT-FEATURE` for a
#                                                 parent and reserves `✔-TOMBSTONE` for leaves; the
#                                                 announcer gives the parent case its own class with its
#                                                 own measured threshold.
#   7. ▶-count < SWEEP_MAX_ATTEMPTS             — the attempt cap, counted from the issue's OWN ▶
#                                                 comments. No state file: the fleet's architecture
#                                                 forbids stored copies of state, and the board already
#                                                 carries the count.
#   8. no ⏸ comment                             — the cap's terminal marker, written exactly once. The
#                                                 latch matches the GLYPH alone: it first matched the
#                                                 literal "⏸ parked" while the comment it was latching on
#                                                 says "⏸ **Parked by the sweeper", so the second cycle
#                                                 parked the same issue again. Caught live on #3737.
#   9. no human is on it                        — an assignee outside the master accounts, or any of the
#                                                 hold labels below, means a person owns this issue, or
#                                                 the issue is deliberately not workable. `test-fixture`
#                                                 is in that list for a REAL burn: on 2026-08-03 this
#                                                 sweep dispatched #3782 and #3789 — throwaway probes
#                                                 whose own bodies read "The change: None. Throwaway;
#                                                 closed immediately" — as two full master runs. A
#                                                 fixture is indistinguishable from work by every other
#                                                 predicate here (Status=Todo, Lane=bravo, open parent,
#                                                 no blockers, no marks), so the ONLY thing that can
#                                                 hold it is its author saying so. See #3789.
#  10. the master is not unhealthy               — `pick_master()` (:~1227) enforces exactly ONE gate
#                                                 before launching: the master is not in `ALL_UNHEALTHY`
#                                                 (quota-cooldown or live-quota derived). "Unhealthy" is
#                                                 a CLOSED three-word enum — `quota-exhausted`,
#                                                 `entitlement-dark`, `rate-limited` — with no arm for a
#                                                 master merely running work: that is not a gate condition,
#                                                 ever (#7160, the operator 2026-08-28). There is no
#                                                 per-master, fleet-wide, or per-cycle concurrency cap —
#                                                 `INFLIGHT[]` is counted for the log line only and is
#                                                 read nowhere as a gate (#6962): a master with runs
#                                                 already going is exactly as eligible as an idle one.
#                                                 AND SINCE #7162 THERE IS NO THROTTLE ON CONCURRENT
#                                                 LAUNCHES AT ALL: `DISPATCH_ACCOUNT_CAP` is DELETED
#                                                 (tombstone `dispatch.sh:2231`); nothing replaced it.
#  11. zero OPEN sub-issues                     — a grouper is not the work; its children are. Read from
#                                                 `subIssuesSummary{total completed}` on the page already
#                                                 fetched. See the block below.
#  12. not a childless root filed in the last   — a Feature is created BEFORE its children, and for those
#      SWEEP_FEATURE_SETTLE_MINUTES (15)          seconds nothing distinguishes it from a finished leaf.
#                                                 See "WHY #12 EXISTS" below.
#
# ⚠ THE NUMBERS ABOVE ARE LOAD-BEARING CROSS-FILE REFERENCES — do not renumber to insert a check.
# `file-issue.sh:287` cites predicate 4, `dispatch.sh:712-713` cite 6 and 8, this file's own :241 cites 5,
# and two specs under `wi/work/specs/` cite 5. #11 is appended out of logical order (it is a
# candidate-filter check, not a launch check) for exactly that reason: a silently-invalidated reference is
# the fleet's most-repeated failure, and renumbering would invalidate five of them at once.
#
# ── WHY #11 EXISTS: THE GROUPER COLLISION (#4063) ─────────────────────────────────────────────────
# On 2026-08-03 this sweep dispatched Feature #4034 and its own sub-issue #4036 to bravo **12 seconds
# apart** (▶ at 04:50:10Z and 04:50:22Z), and both runs took the same work to completion. One merged
# (#4056); the other's identical `file-issue.sh` edit was thrown away, and its board actions — re-laning
# #3990/#4005 and REOPENING Features #3989 and #4004 at 04:56–04:57Z — raced the winner's dispositions
# seconds after it had closed them. Two Features flickered open on the operator's board and had to be re-closed
# by hand. Both runs were correct in isolation; neither could see the other.
#
# Nothing here excluded a Feature. Predicate 3's `or none` arm — written to admit a legitimately
# parentless Task — admits a root Feature identically, and a Feature carries no other tell: Status=Todo,
# a master Lane, no blockers, no marks. The distinguishing fact is that it HAS CHILDREN.
#
# THE RULE (decided in #4063):
# **an issue with >=1 OPEN sub-issue is not dispatched.** Not "has sub-issues" — OPEN ones. That matters
# three ways:
#   · it keys on children, not on `parent == null`, so a mid-tier issue that has BOTH a parent and
#     children (a sub-Feature) is held too;
#   · it is SELF-RELEASING. When the last child closes the grouper becomes dispatchable again, so a
#     Feature carrying residual work no child covered is still picked up autonomously. A blanket
#     "never dispatch anything with sub-issues" would strand that work forever, silently;
#   · it does not touch predicate 3, so a Task whose parent Feature is OPEN keeps dispatching normally —
#     suppressing the children along with the grouper would have been the worse bug.
#
# ── WHY #12 EXISTS: THE FEATURE DISPATCHED BEFORE ITS CHILDREN (#8670) ────────────────────────────
# #11 holds a grouper only once it HAS open children. `file-issue.sh --feature` creates the Feature in
# one call and its children in a later one, and in between the Feature is Status=Todo, parentless,
# childless and unmarked — every predicate above passes. Measured 2026-10-05 on Feature #8659:
#   Feature created 17:45:56Z · this sweep started task-8659 on charlie at 17:46:40Z (44 s later) ·
#   first child #8660 created 17:48:04Z (128 s) · tenth and last child #8669 at 17:49:25Z (209 s).
# The run was a grouper run with nothing of its own to do and had to be stopped by hand.
#
# Nothing on the issue says "Feature": the org's issue types are unset on these (`issueType` read back
# null on #8659 and #8670), there is no label, and a title is not evidence. What IS on the page already
# fetched is `parent`, `subIssuesSummary.total` and `createdAt`. So:
# **a parentless issue with NO sub-issues at all is not dispatched until it is
# SWEEP_FEATURE_SETTLE_MINUTES old.** Once the first child exists #11 takes over, so the window only has
# to cover Feature → first child: 128 s measured, and 15 minutes is 7× that.
#   · it is SELF-RELEASING and needs no marker: a Feature that really has no children (its body IS the
#     work) dispatches on the first cycle after the window, having lost at most 15 minutes;
#   · it keys on `parent == null`, so a Task under a Feature — the normal unit of work — is never
#     delayed. `file-issue.sh` refuses a parentless Task, so in practice the rule reaches Features and
#     the machine-filed root reports (an alarm, a STALLED report), which lose the same 15 minutes;
#   · an issue the API returns no `createdAt` for is NOT held — fail open, same reasoning as #11.
#
# ── THE KILL SWITCH ───────────────────────────────────────────────────────────────────────────────
#   `touch ~/.claude/state/SWEEPER-OFF`  on bravo            → every cycle halts, no code edit.
#   an OPEN issue titled `SWEEPER: OFF`  in the board repo  → the same, from a phone, one tap.
# The file is checked first and needs nothing but the box (GitHub was unreachable for 64h this week).
# The title switch costs zero extra API calls — it is read out of the board page already fetched.
# `rm` the file / close the issue to resume. Both are reported in the heartbeat line.
#
# ── WHY IT ALWAYS WRITES A HEARTBEAT ──────────────────────────────────────────────────────────────
# "nothing to do" and "not running" look identical from the outside, and that ambiguity is precisely
# what hid the 64-hour Actions outage. Every cycle — including a halted one and a failed one — writes
# `~/.claude/state/sweep-dispatch.last`. `sweep-dispatch.sh --status` prints it.
#
# USAGE
#   sweep-dispatch.sh                 # DRY RUN (default, safe): print what it would dispatch
#   sweep-dispatch.sh --apply         # act — what the timer runs
#   sweep-dispatch.sh --issue N       # consider only #N (how the attempt cap is exercised)
#   sweep-dispatch.sh --status        # print the last cycle's heartbeat line
#   sweep-dispatch.sh --explain       # DIAGNOSTIC (read-only): per-Todo-issue reason it is/isn't dispatchable.
#                                     #   `--explain | grep ✔-TOMBSTONE` is the ✔-tombstone report (#4181).
#                                     #   `✔-ROLLUP-ATTESTED` is the OTHER ✔ and is not a defect (#4395).
#   sweep-dispatch.sh --no-announce   # dispatch only; file no stall announcements this cycle (#4182).
#                                     #   Silences BOTH halves of the channel — no report is filed and
#                                     #   none is reaped (#5556). The reaper only ever closes a report
#                                     #   whose own cause it has positively re-read as cleared.
#
# Dry-run-by-default mirrors `~/.claude/ops/reconcile-board-status.sh`, the unit this one rides.
set -uo pipefail
# ops-script-portability: an explicit PATH so bare `gh`/`ssh` resolve in the minimal systemd-timer env
# (gh lives in ~/.local/bin on this box, not /usr/bin).
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

REPO_OWNER="${SWEEP_BOARD_OWNER:-example-org}"
REPO_NAME="${SWEEP_BOARD_REPO:-knowledge}"
REPO="$REPO_OWNER/$REPO_NAME"

# Board mode: query the GitHub project board directly instead of repository issues.
# Default: project (GraphQL query bug fixed in #5408 - now works correctly).
SWEEP_BOARD_MODE="${SWEEP_BOARD_MODE:-project}"
_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="${SWEEP_DISPATCH_BIN:-$_SD/dispatch.sh}"
FILE_ISSUE="${SWEEP_FILE_ISSUE_BIN:-$_SD/file-issue.sh}"   # the announcer files through the ONE filer (#4182)
BRAVO="${SWEEP_NOVA_IP:-192.0.2.10}"     # the box every non-agent master runs on (dispatch.sh:16)

STATE_DIR="$HOME/.claude/state"
KILL_FILE="${SWEEP_OFF_FILE:-$STATE_DIR/SWEEPER-OFF}"
HEARTBEAT="${SWEEP_HEARTBEAT:-$STATE_DIR/sweep-dispatch.last}"
LOG="${SWEEP_LOG:-$HOME/.claude/logs/sweep-dispatch.log}"

# Caps. The burn-loop hazard is REAL (2026-07-30: three runs died on their FIRST request with a 529,
# consuming zero turns) — but the defence is the ATTEMPT cap and the quota cooldown, not a small
# concurrency ceiling. Those two bound *wasted* starts; concurrency only bounds *useful* ones.
#
# 🔴 2026-08-03: the old values (per-master 1, in-flight 4, per-cycle 2) throttled the fleet to ~8% of
# proven capacity. The sweeper reported `32 dispatchable · held=30` with THREE masters fully idle —
# every lane held for lack of an eligible master while fleet-host sat at load 2.29 on 12 cores with 26G free
# (commit 15954bb6, evidenced in its own message). ⚠ That commit ALSO claimed "this box sustained 45
# concurrent runs on 2026-08-02" — searched for evidence on 2026-08-27 (#6962): no journal, log, or OCC
# feed reaches that date (journald here starts 2026-08-14), and no other artifact was found. STRUCK as
# unverified; do not re-cite it. A master is a `claude -p` process, not a build: it is network-bound, so
# per-box concurrency is bounded by the API, which the quota filter already tracks. There is no per-master,
# fleet-wide or per-cycle concurrency cap below (see predicate 10 above, #6962) — and since #7162 (commit
# 23981f64f, 2026-08-28T17:03:12Z) no enforced concurrency throttle anywhere: `ACCOUNT_CAP` is gone (#7214).
MAX_ATTEMPTS="${SWEEP_MAX_ATTEMPTS:-3}"        # ▶ comments on one issue before it is parked — the burn-loop guard
# QUOTA_COOLDOWN_H — how long a 🪫 board marker keeps counting against its master (#6963).
# 🔴 MEASURED 2026-08-27, and the measurement says the constant does not match the thing it stands in for.
# The provider states its own reset time in the text this marker captures, so the ground truth exists:
#   bash _infra/scripts/measure-sweeper-constants.sh quota      # 2026-08-28T00:30Z, 600 issues sampled
#   ── 🪫 capture → provider-stated reset, hours (basis for QUOTA_COOLDOWN_H)
#   n=16  min=0.44  p50=0.67  p90=0.81  p99=8.21  max=8.21
#     13 of 16 stated a reset LESS THAN ONE HOUR out; one stated 8.21 h. A fixed 3 h therefore over-holds
#     a master by ~2.3 h in the common case and releases it ~5 h early in the tail.
# ⚠ THE VALUE IS DELIBERATELY UNCHANGED, and this is not the defect it looks like: this constant governs
#   only the INDIRECT board-marker signal. The AUTHORITATIVE one is `dispatch.sh --quota-dark`, which
#   reads each master's own `quota-status.json` and honours its machine-readable `resetsAt` (see
#   QUOTA_DARK below, #3906) — so a master whose reset has passed is released by that path regardless of
#   this window, and a master still dark inside 8 h is held by it regardless too. 3 h is the retention
#   of a lagging hint, not a capacity ceiling.
# To retire the constant entirely: parse the `until **<ISO>**` the 🪫 body already carries and expire the
#   marker at that instant. That is a behaviour change to the quota path and is OUT of #6963's scope fence.
FEATURE_SETTLE_MIN="${SWEEP_FEATURE_SETTLE_MINUTES:-15}"   # predicate 12 — measured basis in "WHY #12 EXISTS" above
case "$FEATURE_SETTLE_MIN" in ''|*[!0-9]*) FEATURE_SETTLE_MIN=15 ;; esac
QUOTA_COOLDOWN_H="${SWEEP_QUOTA_COOLDOWN_HOURS:-3}"   # skip a master that hit 🪫 this recently — basis above
# NEVER_STARTED_S - a ✘ "produced no artifact" that died within this many seconds did not consume an attempt
# (#7969). Measured: #7968 and #7969 itself - every auth/quota death was 5-103s (6s, 5s, 6s here); a run that
# reads a brief and does real work does not finish in under 30s. The attempt cap still bounds the loop for
# slower failures.
NEVER_STARTED_S="${SWEEP_NEVER_STARTED_SECONDS:-30}"
MASTERS="alpha bravo charlie delta"

# ── The announcer's own bounds (#4182). Full reasoning at "THE ANNOUNCER" below. ──────────────────
# 🔴 THIS BLOCK USED TO OPEN "EVERY NUMBER HERE IS AN ESTIMATE, NOT A MEASUREMENT." It no longer does
# (#6963). Each bound below now carries either a measurement or an explicit statement that it is still
# unmeasured AND the command that would settle it. Doctrine: *"a limit is a measurement, never a
# precaution"* — and a bare number implying evidence is the thing that rule exists to stop.
#
# ⚠ NO VALUE BELOW CHANGED IN #6963. Measuring a number and re-tuning it are different jobs; this phase
# did the first only, and its scope fence forbade the second. Where a measurement argues for a different
# value, the block says so in place rather than acting on it.
#
# The one command behind all of it — reads only public board data, changes nothing, gates nothing:
#   bash _infra/scripts/measure-sweeper-constants.sh [runs|quota|announce|all]
#
# ── ANNOUNCE_PARENT — NOT A LIMIT. It is an issue number (the standing stall bucket), so there is
#    nothing to measure. Its one invariant is that it must be an OPEN issue, and that is not documented
#    here — it is CHECKED, at "ANNOUNCER OFF" below, which halts announcing and says so when it is not.
#
# ── ANNOUNCE_MAX_PER_CYCLE = 3 — 🔴 MEASURED, and it has BOUND, and the held remainder drained.
#    Every report the announcer files is a public board issue, so its own output is the measurement:
#      bash _infra/scripts/measure-sweeper-constants.sh announce     # 2026-08-28T00:30Z
#      reports=49  bursts(gap<=180s, i.e. one sweeper cycle)=36  max reports in one burst=5
#    Sustained rate is 2.08 reports/day over 23 days — the cap is nowhere near it. The bursts are what
#    matters, and only two ever reached the ceiling of 3 outside the fixture window recorded below:
#      2026-08-05T06:24:48/59, 06:25:09Z  (#4390 #4391 #4392) → next report #4395 at 06:35:46Z
#      2026-08-14T17:59:31/43/55Z         (#5556 #5558 #5560) → next report #5580 at 18:08:40Z
#    🔴 THE SECOND ONE IS THE PROOF THE HOLD IS CORRECT, NOT JUST THE CAP: 5556/5558/5560 announce
#    parent-closed on #5526/#5527/#5528, and the very next report, 9 minutes and a cycle later, is
#    #5529 — the next issue in that same consecutive run. The 4th candidate was HELD, not dropped, and
#    the following cycle filed it. That is exactly the contract the comment claims ("the remainder is
#    LOGGED, never silent") and it is now observed rather than asserted.
#    The only burst of 5 is 2026-08-04T21:12–21:15Z, inside the fixture window below — excluded.
#
# ── ANNOUNCE_STALL_MIN = 15 — ⚠ MEASURED AGAINST ITS OWN STATED BASIS, AND THE BASIS IS TOO STRONG.
#    The report prose at `tombstone` below claims 15 minutes is enough "so a PR that merges seconds
#    after its ✔ never trips it." Measured over every closed issue whose LAST marker before the close
#    is a ✔ — which is precisely the population the tombstone class draws from:
#      bash _infra/scripts/measure-sweeper-constants.sh announce     # 2026-08-28T00:30Z, n=600 issues
#      n=62  min=0.00  p50=7.08  p90=41.62  p99=4291.12  max=4291.12
#      ANNOUNCE_STALL_MIN=15 → below 15: 41/62 (66.1%)
#    So 15 minutes covers the MEDIAN normal close and not the p90. It is a real bound on the common
#    transient, not on the transient.
#    🔴 STILL UNMEASURED: the FALSE-POSITIVE RATE, which is the number that would actually justify
#    15 or replace it. The class fired 6 times in 23 days; every one of those 6 subjects closed AFTER
#    its report (88 seconds to 8.8 hours later), and the board cannot distinguish "the report caused
#    the close" from "the close was already in flight" — 3 of the 6 are inside the fixture window below
#    and ran with STALL_MIN=0 anyway. TO MEASURE IT: run the announcer for a week at
#    SWEEP_ANNOUNCE_STALL_MIN=15 with a second shadow pass at 45, and count the subjects the 15-minute
#    pass named that the 45-minute pass did not — those, and only those, are its false positives.
#
# ── ANNOUNCE_RUN_MIN = 120 — 🔴 MEASURED. It is the WEAK half of the run-vanished test (the strong
#    half is predicate 5's live-unit probe); its only job is never to call a genuinely long run dead.
#    There is NO wall-clock ceiling on a run — `dispatch.sh` caps TURNS (200), not seconds — so the
#    observed distribution is the only bound that exists:
#      bash _infra/scripts/measure-sweeper-constants.sh runs         # 2026-08-28T00:30Z, n=600 issues
#      n=296  min=0.30  p50=10.45  p90=24.60  p99=57.98  max=59.53   (minutes, ▶→✔/✘ on one issue)
#    🔴 ZERO runs of 296 reached even 60 minutes. 120 is 2.0× the longest run ever observed and
#    2.1× p99 — it cannot fire on a real run, which is the whole requirement. Re-derive if the turn
#    cap rises or a wall-clock timeout is added; both would move this distribution.
#
# ── FIRST FIELD OBSERVATION (#4300, 2026-08-04T21:12–21:43Z — the announcer's first 31 minutes) ────
# Recorded so the next reader does not mistake this window for the re-derivation above. It is not one.
#   · 8 reports filed. ZERO false positives — every one named a genuine instance of its class — and
#     ZERO duplicates: 8 distinct (issue, class) keys, and a second pass over #4299 filed nothing.
#     Property 1 (idempotence by title) holds in the field.
#   · 🔴 BUT 7 of those 8 subjects were MANUFACTURED FIXTURES (`[FIXTURE #4182]` ×5, `SWEEPER TEST
#     (#4178)` ×2), created seconds before the report that named them. Exactly ONE (#4276, about
#     #4231) was a real unmanufactured stall. n=1 is not a filing rate.
#   · 🔴 AND the two #4178 probes ran with SWEEP_ANNOUNCE_STALL_MIN=0, so NO report in this window was
#     produced by the shipped default of 15. This window says nothing about whether 15 is right.
# So: the announcer is CORRECT, and STALL_MIN is still UNMEASURED. The re-derivation #4182 asked for
# needs a day of steady-state board traffic with no fixtures in it — do not close it out on this data.
# ⚠ #6963 UPDATE: 23 days of unmanufactured traffic have since accumulated and are measured in the
# STALL_MIN block above. They settle the LATENCY the threshold sits against; they do NOT settle the
# false-positive rate #4182 asked for, which still needs the shadow-pass experiment named there.
#
ANNOUNCE_PARENT="${SWEEP_ANNOUNCE_PARENT:-5292}"          # the standing stall bucket every report parents to
ANNOUNCE_MAX_PER_CYCLE="${SWEEP_ANNOUNCE_MAX_PER_CYCLE:-3}"  # storm bound; the remainder is LOGGED, never silent
ANNOUNCE_STALL_MIN="${SWEEP_ANNOUNCE_STALL_MIN:-15}"      # parent-closed · tombstone (dead-lane has its own, below)
ANNOUNCE_RUN_MIN="${SWEEP_ANNOUNCE_RUN_MIN:-120}"         # run-vanished (▶-only Doing)
# ── ANNOUNCE_DEADLANE_MIN = 60 — MEASURED, and the 15 it replaces was below every observation (#9295).
# A lane-`agent` issue is executed by a subagent in the Architect's own session (deliberately, e.g.
# PLAN-394 while the masters were exhausted), and that session posts no ▶ — so for the whole run the
# issue looks exactly like a dead lane. Measured 2026-10-19 on Feature #9257, the only chain of its kind
# on the board: P2 #9259 created 17:59:17Z → closed 18:21:31Z (22 min) · P5 #9261 17:59:40Z → 18:25:08Z
# (26 min). Both were announced dead-lane mid-run (#9286, #9287) and both disposed as noise; 2/2 live
# Architect runs outlasted 15. And #9265 was announced 4 minutes after its ONLY blocker closed, because
# the clock counted from createdAt while P2 was the hold. So the clock below starts at the later of
# creation and the last blocker closing, an issue with an OPEN blocker is never dead-lane (the blocker
# is the hold, and it gets its own report), and the threshold is 60: >2x the longest observed run. A
# truly dead chain link waits 45 more minutes to be reported; a live one stops filing noise.
ANNOUNCE_DEADLANE_MIN="${SWEEP_ANNOUNCE_DEADLANE_MIN:-60}"  # dead-lane, from max(createdAt, last blocker closedAt)
# rollup-unclosed. 🔴 THE FIRST NUMBER HERE THAT WAS MEASURED (#4395) — for a long time the only one;
# #6963 measured MAX_PER_CYCLE, RUN_MIN and QUOTA_COOLDOWN_H above and stated what STALL_MIN still
# lacks, so this is no longer the exception it was written as. It is not a
# taste call: it is the observed latency of `stuck-pr-sweep.yml`, the ONLY thing that closes an n/n
# parent Feature, so anything below it announces work the closer is simply on its way to.
#   gh run list --workflow stuck-pr-sweep.yml --limit 200 --json createdAt,event  # schedule events only
#   n=103 gaps over 2026-07-25..08-05: min 59 · p50 104 · p90 203 · max 3888 minutes.
# The workflow DECLARES `cron: 17,47` = a 30-minute period. GitHub delivers a median of 104. Both
# numbers matter and only the second is real — see "why a rollup-attested Feature is not a tombstone".
# 300 sits above p90 (203) and above 102 of 103 observed gaps. The single 3888-minute gap was an
# Actions outage, and announcing during one is CORRECT: there the closer genuinely is not coming.
# 🔴 WHAT IT IS MEASURED AGAINST CHANGED (#6233): the 300 minutes run from the moment the Feature
# reached n/n, never from the ✔. A closer latency is only latency once the closer is ELIGIBLE, and it
# is not eligible while a child is open. See Property 1c in the filing loop for the measurement.
ANNOUNCE_ROLLUP_MIN="${SWEEP_ANNOUNCE_ROLLUP_MIN:-300}"   # rollup-unclosed (n/n Feature awaiting the auto-closer)
ANNOUNCE_PREFIX="STALLED #"                               # the idempotence key's prefix — see below

# ── The load-bearing warner's two constants (its function is ~80 lines below) ─────────────────────
# EMERGENCY_BUCKET was read at the filing site as `${EMERGENCY_BUCKET:-4835}` from the environment and
# assigned NOWHERE in this file, while the LOAD_BEARING table listed it as a real reference — the
# self-check validating a variable that existed only in the table describing it (#7157). It is a real
# variable now, with the same `SWEEP_`-prefixed override every other knob here has.
EMERGENCY_BUCKET="${SWEEP_EMERGENCY_BUCKET:-4835}"        # fallback parent when $ANNOUNCE_PARENT is closed too
# The load-bearing report's idempotence key, the announcer's Property 1 applied to the other filer in
# this file. The title carries a COUNT after this prefix, so the prefix is what is matched.
LOAD_BEARING_PREFIX="⚠ LOAD-BEARING ISSUE CLOSED"
# A machine-readable record of WHICH references were closed when the report was written. It is what
# makes "update, not duplicate" idempotent: the update is posted only when the live closed set differs
# from every set the open report already names.
LOAD_BEARING_MARK="<!-- load-bearing-refs: "

# ── announce_subject_of TITLE → "<owner/repo> <n>", or nothing ────────────────────────────────────
# The inverse of the report title `STALLED #<owner/repo>:<n> · <class> — <head>`, used by the reaper
# below to find the issue a report is ABOUT. It is a separate function for one reason: it is the only
# place in this file that turns a STRING back into an issue to act on, and #5497 is what that costs
# when it is wrong — a report that named `example-org/kb:317` for a product-a subject sent
# every remedy at a different, unrelated, already-closed issue. So it fails CLOSED: anything that is
# not exactly `<owner>/<repo>:<digits>` yields nothing and the caller skips the report untouched.
# Pinned by `_infra/tests/sweep-announce-reaper.sh` (extracted from these bytes, never copied).
announce_subject_of() {
  local t="${1#"$ANNOUNCE_PREFIX"}" r n
  case "$t" in "$1") return 1 ;; esac      # the prefix was not there at all
  r="${t%%:*}"; n="${t#*:}"; n="${n%% *}"
  case "$r" in */*/*|*/|/*) return 1 ;; */*) ;; *) return 1 ;; esac
  case "$r" in *[!A-Za-z0-9._/-]*) return 1 ;; esac
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s %s' "$r" "$n"
}

# Accounts the masters dispatch AS (dispatch.sh's own switch). An assignee outside this set is a person.
MASTER_LOGINS='["gh-account1","gh-account2","gh-account3","gh-account4","example-fleet","example-fleet[bot]","gh-account5"]'
# Labels that mean "a human owns this, or it is deliberately not workable now". `workflow:*` issues are
# driven by their own GitHub Actions workflow; dispatching those would run the work twice.
# `test-fixture` = an issue that exists to exercise machinery, not to be worked (#3789). It carries no
# other tell — a probe filed by `file-issue.sh` is fielded exactly like real work — so the label is the
# whole mechanism: every test that files a board issue MUST apply it at filing time.
#   TWO gates honour the label, and a change here must be ported to both: this sweeper (holds it out of
#   dispatch) and `~/.claude/scripts/issue-hygiene-lint.sh` (exempts it from field-drift / fake-block /
#   done-still-blocked, and prints the count). The lint was added to that contract on 2026-08-03 under
#   #3986/#3993, after fixture #3913 — unfielded BY DESIGN — failed the nightly audit on bravo AND charlie.
# 🔴 NO LABEL HERE MAY NAME A HUMAN, AND NONE MAY MEAN "not triaged yet" (#6618/#6624). Five were
#   deleted on 2026-08-23: `needs:triage` (the DoR gate — it held 32 of 36 open rows, 31 of them for a
#   blank Lane alone, so 89% of the board was out of dispatch while `blank Lane is routable` (#6579)
#   moved nothing), plus `blocked:the operator`, `decision:the operator`, `needs:the operator` and `laptop-batch` — gates by
#   name, encoding the model the operator rejected, that a master can be stopped waiting on him. All four
#   matched zero open rows on the day they were removed, so nothing can strand on them later either.
#   A label may still MARK a row for attention. It must not PREVENT the work.
#   The four load-bearing fixtures (#4835/#4836/#4837/#4838) were held by `needs:triage` alone; they now
#   carry `test-fixture`, which is what the paragraph above says every fixture must carry at filing time.
HOLD_LABELS='["backlog","waiting:event","wontfix","next-iteration","needs:bigger-model","test-fixture"]'

APPLY=0; ONLY_ISSUE=""; SHOW_STATUS=0; EXPLAIN_MODE=0; ANNOUNCE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)  APPLY=1; shift ;;
    --issue)  ONLY_ISSUE="${2:?--issue needs a number}"; shift 2 ;;
    --status) SHOW_STATUS=1; shift ;;
    --explain) EXPLAIN_MODE=1; shift ;;
    --no-announce) ANNOUNCE=0; shift ;;
    -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$STATE_DIR" "$(dirname "$LOG")" 2>/dev/null || true
ts() { date -u +%FT%TZ; }
log() { printf '%s %s\n' "$(ts)" "$*" >> "$LOG" 2>/dev/null || true; printf '%s\n' "$*"; }

if [ "$SHOW_STATUS" = 1 ]; then
  if [ -f "$HEARTBEAT" ]; then cat "$HEARTBEAT"; else echo "no heartbeat at $HEARTBEAT — the sweep has never run on this box"; fi
  exit 0
fi

# The heartbeat is written on EVERY exit path, including the halted and failed ones. A sweep that cannot
# be distinguished from a sweep that is not installed is the failure mode this line exists to remove.
beat() { printf '%s %s\n' "$(ts)" "$*" > "$HEARTBEAT" 2>/dev/null || true; }
finish() { local m="$1"; beat "$m"; log "$m"; exit 0; }

# ── Load-bearing issue check ───────────────────────────────────────────────────────────────────────
# Check all hardcoded issue references used as defaults in fleet scripts. When these are closed,
# machinery fails silently. This check files a visible warning so the operator knows without reading logs.
#
# WHY IT EXISTS. On 2026-08-09 issue #4241 — the announcer's standing parent bucket — was closed in a
# board cleanup. The announcer went dark for ~20 minutes with no visible signal, because the failure
# mode of a dead announcer is SILENCE, which looks exactly like health. A title saying "never close
# this" is not a mechanism; this is. The bucket was recreated as #5292.
#
# 🔴 IT IS A FILER, SO IT OBEYS THE FILER RULES (#7157). Both were missing and both are now here:
#   1. `--apply` GUARD. The header at :142 calls a no-argument run "DRY RUN (default, safe)" and :146
#      calls `--explain` "DIAGNOSTIC (read-only)". This function filed a live P0 from either mode, so
#      both claims were false for eight weeks. Every write below is behind the guard.
#   2. IDEMPOTENT BY TITLE, against $BOARD — the announcer's Property 1 (~1400 lines below), which
#      exists to stop exactly the self-amplifying storm this function could produce: one closed
#      fixture, a new P0 every five minutes, forever. A later cycle UPDATES the open report instead.
# Both are pinned by `_infra/tests/sweep-load-bearing-guard.sh`, which runs THESE bytes.
#
# EXTENDING THE TABLE. Add the row (`variable|issue|script|what reads it`) and make sure the variable
# is really assigned somewhere — `EMERGENCY_BUCKET` sat in this table for eight weeks describing a
# variable that existed nowhere but the table (#7157). The four fixtures #4835-#4838 carry
# `test-fixture` so dispatch holds them out; closing one is what this check is for.
check_load_bearing_issues() {
  [ -f "$BOARD" ] || return 0
  [ "${N_ISSUES:-0}" -gt 0 ] || return 0

  # All known load-bearing issue references from _infra/scripts/*.sh
  # Format: "variable_name|issue_number|script_path|description"
  local LOAD_BEARING=(
    "EMERGENCY_BUCKET|4835|_infra/scripts/sweep-dispatch.sh|Emergency parent for load-bearing warnings"
    "PROBE_ISSUE|4836|_infra/scripts/gh-upgrade-fleet-host.sh|Test fixture for gh upgrade verification"
    "PROBE_ISSUE|4837|_infra/scripts/verify-mention-comms.sh|Test fixture for mention comms verification"
    "TEST_FIXTURE_ISSUE|4838|_infra/scripts/test-fixture-load-bearing.sh|Test fixture for load-bearing issue detection"
  )

  local closed_issues=()

  for entry in "${LOAD_BEARING[@]}"; do
    IFS='|' read -r var_name issue_num script_path description <<< "$entry"

    # Check if this issue is OPEN on the current board
    local is_open="$(jq --argjson p "$issue_num" '[.[] | select(.number == $p)] | length' "$BOARD" 2>/dev/null || echo 0)"

    if [ "$is_open" -eq 0 ]; then
      closed_issues+=("$var_name|$issue_num|$script_path|$description")
    fi
  done

  # If any load-bearing issues are closed, file a warning
  if [ "${#closed_issues[@]}" -gt 0 ]; then
    # The closed set, canonically ordered. Two things read it: the dry-run line below (so a read-only
    # run still SAYS what it found) and the update check (so a report is refreshed when the set moves).
    local closed_key
    closed_key="$(printf '%s\n' "${closed_issues[@]}" | cut -d'|' -f2 | sort -n | paste -sd, -)"

    # ── Property 1, borrowed from the announcer 1400 lines below: IDEMPOTENT BY TITLE ────────────
    # One open report, however many cycles the condition survives. Without it a single closed fixture
    # files a fresh P0 every 5 minutes forever — the self-amplifying storm the announcer's own
    # Property 1 exists to prevent, in the same file (#7157). It reads $BOARD, never the search API,
    # for the reason stated there: the search index lags and a lagging idempotence check double-files.
    local existing
    existing="$(jq -r --arg k "$LOAD_BEARING_PREFIX" \
      '[.[] | select(.title | startswith($k)) | .number] | first // empty' "$BOARD" 2>/dev/null || true)"

    # ── The --apply guard. EVERY write below this line is behind it ──────────────────────────────
    # `sweep-dispatch.sh` with no arguments calls itself "DRY RUN (default, safe)" at :142 and
    # `--explain` calls itself "DIAGNOSTIC (read-only)" at :146. Both claims were false for this one
    # function, which filed a live P0 from either mode (#7157). Same shape as the announcer's and the
    # reaper's guards: say what would happen, write nothing.
    if [ "${APPLY:-0}" != 1 ]; then
      if [ -n "$existing" ]; then
        log "  ⚠ would update load-bearing report #$existing — ${#closed_issues[@]} reference(s) closed: $closed_key"
      else
        log "  ⚠ would file load-bearing warning — ${#closed_issues[@]} reference(s) closed: $closed_key"
      fi
      return 0
    fi

    # Use #4835 (the emergency bucket) as parent for warnings, or ANNOUNCE_PARENT if it's open
    local warn_parent="$EMERGENCY_BUCKET"
    local parent_open="$(jq --argjson p "$warn_parent" '[.[] | select(.number == $p)] | length' "$BOARD" 2>/dev/null || echo 0)"

    # If ANNOUNCE_PARENT is different and open, use it instead
    if [ "$ANNOUNCE_PARENT" != "$warn_parent" ]; then
      local announce_open="$(jq --argjson p "$ANNOUNCE_PARENT" '[.[] | select(.number == $p)] | length' "$BOARD" 2>/dev/null || echo 0)"
      if [ "$announce_open" -gt 0 ]; then
        warn_parent="$ANNOUNCE_PARENT"
        parent_open=1
      fi
    fi

    # Build the issue body
    local body_file="$(mktemp)"
    cat > "$body_file" <<BODYEOF
**⚠ LOAD-BEARING ISSUE CLOSED — fleet machinery may be silently broken.**

The following hardcoded issue references used by fleet scripts are CLOSED:
BODYEOF

    for entry in "${closed_issues[@]}"; do
      IFS='|' read -r var_name issue_num script_path description <<< "$entry"
      cat >> "$body_file" <<ENTRYEOF

- **#${issue_num}** — \`${var_name}\` in \`${script_path}\`
  - $description
ENTRYEOF
    done

    cat >> "$body_file" <<BODYEOF

**What this means:** When these issues are closed, the scripts that reference them as defaults
may fail silently or behave incorrectly. Unlike normal work issues, these are **load-bearing
configuration values** that the fleet depends on.

**How to fix:**
1. Check if the close was intentional — if this is a deprecated reference, update the script.
2. If the issue should remain open, re-open it: \`gh issue reopen <number>\`
3. Update this check in \`check_load_bearing_issues()\` to remove or update the reference.

**This issue was filed automatically** by \`sweep-dispatch.sh\` detecting closed load-bearing
references. Once all references are fixed, this issue can be closed. It is filed ONCE and updated in
place by later cycles — one open report per condition, not one per cycle (#7157).

${LOAD_BEARING_MARK}${closed_key} -->
BODYEOF

    # ── An open report exists: UPDATE it, never file a second ───────────────────────────────────
    # The update is itself idempotent — the report carries $LOAD_BEARING_MARK naming the set it was
    # written about, so a comment is posted only the first cycle the live set differs from every set
    # already recorded. A condition that does not move therefore costs one read and no write.
    if [ -n "$existing" ]; then
      if gh issue view "$existing" --repo "$REPO" --json body,comments \
           --jq '.body, (.comments[].body)' 2>/dev/null \
         | grep -qF "$LOAD_BEARING_MARK$closed_key -->"; then
        log "  · load-bearing report #$existing already names the closed set ($closed_key) — not filing a second"
      elif gh issue comment "$existing" --repo "$REPO" </dev/null --body-file "$body_file" >/dev/null 2>&1; then
        log "  ⚠ updated load-bearing report #$existing — closed set is now $closed_key"
      else
        log "  ✘ Failed to update load-bearing report #$existing (closed set $closed_key)"
      fi
      rm -f "$body_file"
      return 0
    fi

    # File the issue if we have a valid parent.
    # 🔴 `--lane alpha`, not `wi` (#4828). `wi` is a PORTFOLIO; file-issue.sh:464 accepts only
    # agent|delta|alpha|bravo|charlie and exits 2 with a bare `bad lane`. This warner therefore printed
    # `✘ Failed to file load-bearing warning: bad lane` on every cycle where a load-bearing reference was
    # closed, and filed NOTHING — observed live on 2026-08-09, which is how it was found. A detector that
    # cannot file is silence with a log line, the exact failure mode the announcer below exists to end.
    if [ "$parent_open" -gt 0 ]; then
      local title="$LOAD_BEARING_PREFIX — ${#closed_issues[@]} reference(s) broken"
      if AOUT="$(bash "$FILE_ISSUE" --title "$title" --body-file "$body_file" \
                  --lane alpha --priority P0 --portfolio wi --parent "$warn_parent" \
                  --parallel --repo "$REPO" </dev/null 2>&1)"; then
        log "  ⚠ Filed load-bearing warning: $(printf '%s' "$AOUT" | grep -o 'https://github.com/[^ ]*' | tail -1)"
      else
        log "  ✘ Failed to file load-bearing warning: $(printf '%s' "$AOUT" | tail -2 | tr '\n' ' ')"
      fi
    else
      log "  ⚠ LOAD-BEARING ISSUE CLOSED but cannot file warning (bucket #$warn_parent is also closed)"
      local entry_list=""
      for entry in "${closed_issues[@]}"; do
        IFS='|' read -r var_name issue_num script_path description <<< "$entry"
        entry_list="$entry_list #$issue_num ($var_name in $script_path)"
      done
      log "    Closed references:$entry_list"
    fi

    rm -f "$body_file"
  fi
}

# ── Kill switch, half 1: the file. Checked before anything reaches the network. ───────────────────
# The halt line carries the file's REASON (its contents) and its AGE. On 2026-08-03 this file appeared
# empty, with no journal entry naming its author, and stopped the whole fleet mid-drain. Deciding whether
# to remove it took a human round-trip that a one-line reason would have answered outright — and the
# switch turned out to be a test fixture that cleared itself. An unexplained global stop is the one state
# nobody can safely act on: removing it blind risks overriding a real emergency, leaving it blind risks
# halting the fleet indefinitely over nothing.
# Whoever sets it SHOULD write why:  echo "reason" > ~/.claude/state/SWEEPER-OFF
# An empty file still halts — the switch must never depend on the setter remembering — but it now says so.
if [ -f "$KILL_FILE" ]; then
  _kf_why="$(head -c 200 "$KILL_FILE" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')"
  _kf_age="$(( ( $(date +%s) - $(stat -c %Y "$KILL_FILE" 2>/dev/null || date +%s) ) / 60 ))"
  finish "HALTED kill-switch-file=$KILL_FILE dispatched=0 · set ${_kf_age}m ago · reason: ${_kf_why:-(NONE RECORDED — whoever set this left no reason; echo one into the file next time)} (rm it to resume)"
fi

# ── The board, in ONE paginated GraphQL read ─────────────────────────────────────────────────────
# 7 points per 100 issues (measured 2026-08-02); re-measured 2026-08-03 at **8 points** for a 62-issue
# page that did not paginate (`hasNextPage: false`), so a 5-minute cycle costs 8 of the 5000/hr budget.
# Per-issue REST would exhaust core and then dispatch nothing, silently — that is how the 2026-08-01
# sweep ended at 0/5000. `comments(last:25)` is what the ▶-count, the last-marker and the ⏸ check all
# read; 25 covers the worst case in the dataset (#2288: 5 attempts, 6 interleaved human comments).
#
# `createdAt` and `parent.closedAt` are SCALARS on nodes this query already fetches, so they cost nothing
# (same reasoning as `subIssuesSummary` below). They are the announcer's clock: #4182 forbids a state file,
# so "how long has this been stuck" is derived from the board's own timestamps, never from a stored copy.
#
# `timelineItems(last:1, itemTypes:[REOPENED_EVENT])` is the ONLY thing that can date a reopen, and a reopen
# is what makes a terminal marker stale (#4392 — see `live_marks` below). Measured on the live board
# 2026-08-05, same page, back to back, with `rateLimit{cost nodeCount}` inline:
#   without it → {"cost":8,"nodeCount":13900}      with it → {"cost":9,"nodeCount":14000}
# One point and 100 nodes per page against a 5000/hr budget that sat at 4271 remaining when measured.
# `subIssuesSummary` (predicate 11) is deliberately NOT `subIssues(first:N)`: a connection adds nodes to
# the cost calculation, and per-issue REST is what took core to 0/5000 on 2026-08-01. The summary is a
# scalar object, so it is FREE — measured against the live board 2026-08-03, same page, back to back:
#   without it → {"cost":8,"nodeCount":13900}      with it → {"cost":8,"nodeCount":13900}
# Its `completed` counts EVERY closed child, including ones closed `not planned` — verified on #4050
# (1/1) and #4015 (3/3), both all-NOT_PLANNED, and on all 8 open parents on the board, where
# `total - completed` equalled the actual OPEN-child count in 8/8. So open children = total - completed.
QUERY_REPO='query($o:String!,$r:String!,$a:String){
  repository(owner:$o,name:$r){ issues(states:OPEN,first:100,after:$a,orderBy:{field:UPDATED_AT,direction:DESC}){
    pageInfo{hasNextPage endCursor}
    nodes{
      number title
      createdAt
      updatedAt
      labels(first:20){nodes{name}}
      assignees(first:10){nodes{login}}
      parent{number state closedAt}
      subIssuesSummary{total completed}
      blockedBy(first:20){nodes{number state closedAt}}
      comments(last:25){nodes{body createdAt author{login}}}
      timelineItems(last:1,itemTypes:[REOPENED_EVENT]){nodes{... on ReopenedEvent{createdAt}}}
      projectItems(first:3){nodes{fieldValues(first:20){nodes{... on ProjectV2ItemFieldSingleSelectValue{name field{... on ProjectV2FieldCommon{name}}}}}}}
    } } } }'

# QUERY_PROJECT is defined as a here-document to avoid shell quoting issues with complex GraphQL syntax
# The query is written to a temp file and passed to gh api graphql via -f query="$(cat $temp_file)"
QUERY_PROJECT_FILE="$(mktemp)"
cat > "$QUERY_PROJECT_FILE" << 'GQLEOF'
query($org:String!,$num:Int!,$a:String){
  organization(login:$org){
    projectV2(number:$num){
      items(first:100,after:$a){
        pageInfo{
          hasNextPage
          endCursor
        }
        nodes{
          isArchived
          fieldValues(first:20){
            nodes{
              ...on ProjectV2ItemFieldSingleSelectValue{
                name
                field{
                  ...on ProjectV2FieldCommon{
                    name
                  }
                }
              }
            }
          }
          content{
            ...on Issue{
              number
              title
              state
              createdAt
              updatedAt
              repository{
                name
                owner{
                  login
                }
              }
              labels(first:20){
                nodes{
                  name
                }
              }
              assignees(first:10){
                nodes{
                  login
                }
              }
              parent{
                number
                state
                closedAt
              }
              subIssuesSummary{
                total
                completed
              }
              blockedBy(first:20){
                nodes{
                  number
                  state
                  closedAt
                }
              }
              comments(last:25){
                nodes{
                  body
                  createdAt
                  author{login}
                }
              }
              timelineItems(last:1,itemTypes:[REOPENED_EVENT]){
                nodes{
                  ...on ReopenedEvent{
                    createdAt
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
GQLEOF

# 🔴 The pages are accumulated through FILES, never through argv. A single page of 100 issues with their
# comments is ~2 MB of JSON; `jq --argjson` on that silently dies at ARG_MAX, which read here exactly like
# an empty board — the sweep's own fail-closed path, firing on a board it had actually read fine.
PAGES="$(mktemp)"; BOARD="$(mktemp)"
trap 'rm -f "$PAGES" "$BOARD" "${QUERY_PROJECT_FILE:-}" 2>/dev/null || true' EXIT
AFTER=null; PAGE=0

if [ "$SWEEP_BOARD_MODE" = "project" ]; then
  # Board mode: query the GitHub project board directly.
  # Board number for knowledge repo is 1 (the org's planning board).
  BOARD_NUM="${SWEEP_BOARD_NUM:-1}"
  while [ "$PAGE" -lt 5 ]; do
    RESP="$(gh api graphql -F org="$REPO_OWNER" -F num="$BOARD_NUM" -F a="$AFTER" -f query="$(cat "$QUERY_PROJECT_FILE")" 2>/dev/null)" || RESP=""
    [ -n "$RESP" ] || break
    printf '%s' "$RESP" | jq -c '.data.organization.projectV2.items.nodes // []' >> "$PAGES" 2>/dev/null || break
    [ "$(printf '%s' "$RESP" | jq -r '.data.organization.projectV2.items.pageInfo.hasNextPage')" = "true" ] || break
    AFTER="$(printf '%s' "$RESP" | jq -r '.data.organization.projectV2.items.pageInfo.endCursor')"
    PAGE=$((PAGE+1))
  done
  jq -s -c 'add // []' "$PAGES" > "$BOARD" 2>/dev/null || printf '[]' > "$BOARD"

  # Transform board query result to match the expected shape for candidate filtering.
  # Three critical filters that have no board equivalent:
  # 1. isArchived — archived items ARE returned by default
  # 2. .content.number != null — content can be a Draft issue or a PR
  # 3. .content.state == "OPEN" — there is no states:OPEN argument on board items
  BOARD_NEW="$(mktemp)"
  jq -c '[.[] |
    select(.isArchived == false) |
    select(.content.number != null) |
    select(.content.state == "OPEN") |
    .content + {
      repo: (.content.repository.owner.login + "/" + .content.repository.name),
      projectItems: {nodes: [{fieldValues: .fieldValues}]}
    } |
    del(.repository)]' "$BOARD" > "$BOARD_NEW" 2>/dev/null || printf '[]' > "$BOARD_NEW"
  mv "$BOARD_NEW" "$BOARD"
else
  # Repo mode: query repository issues (original behavior).
  while [ "$PAGE" -lt 5 ]; do
    RESP="$(gh api graphql -F o="$REPO_OWNER" -F r="$REPO_NAME" -F a="$AFTER" -f query="$QUERY_REPO" 2>/dev/null)" || RESP=""
    [ -n "$RESP" ] || break
    printf '%s' "$RESP" | jq -c '.data.repository.issues.nodes // []' >> "$PAGES" 2>/dev/null || break
    [ "$(printf '%s' "$RESP" | jq -r '.data.repository.issues.pageInfo.hasNextPage')" = "true" ] || break
    AFTER="$(printf '%s' "$RESP" | jq -r '.data.repository.issues.pageInfo.endCursor')"
    PAGE=$((PAGE+1))
  done
  jq -s -c 'add // []' "$PAGES" > "$BOARD" 2>/dev/null || printf '[]' > "$BOARD"
fi

N_ISSUES="$(jq 'length' "$BOARD" 2>/dev/null || echo 0)"
if [ "${N_ISSUES:-0}" -eq 0 ]; then
  # Fail CLOSED, loudly. An unreadable board cannot produce an eligibility decision, and guessing one is
  # how a dispatcher starts the wrong work. Nothing is dispatched and the heartbeat says why.
  finish "ERROR board-unreadable (GraphQL returned no issues) dispatched=0"
fi

# ── Kill switch, half 2: the board-side one, out of the page already fetched (zero extra calls) ───
if [ "$(jq '[.[] | select(.title | test("^\\s*SWEEPER:\\s*OFF"; "i"))] | length' "$BOARD")" -gt 0 ]; then
  SW="$(jq -r '[.[] | select(.title | test("^\\s*SWEEPER:\\s*OFF"; "i")) | .number] | join(",")' "$BOARD")"
  finish "HALTED kill-switch-issue=#$SW dispatched=0 (close it to resume)"
fi

# ── Load-bearing issue check ───────────────────────────────────────────────────────────────────────
# Check all hardcoded issue references and warn if any are closed. This must run AFTER the board is
# loaded but BEFORE the announcer logic, so we can file warnings even if ANNOUNCE_PARENT itself is closed.
check_load_bearing_issues

# ── Live task units per master — the anti-double-dispatch probe ──────────────────────────────────
# dispatch.sh counts in-flight runs AFTER launching, purely to refresh a display cache; it has no limit
# check at all. This is the same probe (`systemctl --user list-units 'task-*'`), read HERE to build
# `LIVE_ISSUES` — the set an issue number must NOT already be in before this dispatches it again
# (predicate 5). `INFLIGHT[]` below is a byproduct, counted for the log line only; it gates nothing.
# One ssh for all four masters. -n is load-bearing: without it ssh eats this script's stdin.
UNITS="$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "bravo@$BRAVO" \
  'for M in alpha bravo charlie delta; do sudo -n -u $M XDG_RUNTIME_DIR=/run/user/$(id -u $M) \
     systemctl --user list-units --state=active --no-legend --plain "task-*" 2>/dev/null \
     | while read -r U _; do echo "$M $U"; done; done' 2>/dev/null)" || UNITS=""
if [ -z "$UNITS" ] && ! ssh -n -o BatchMode=yes -o ConnectTimeout=10 "bravo@$BRAVO" true 2>/dev/null; then
  # Fail-closed reasoning: with no live-unit read, `LIVE_ISSUES` is empty and predicate 5 — the ONLY
  # thing standing between this cycle and dispatching a SECOND run onto an issue that already has one
  # live — cannot fire. That double-dispatch, not a concurrency cap (none exists, #6962), is the real
  # hazard `--apply` cannot risk blind.
  # 🔴 But that hazard is only real when `--apply` actually dispatches. Killing the read-only modes here
  # made `--explain` — the fleet's only window into why an issue is not moving — unavailable from every
  # box that cannot ssh to fleet-host, which is how VERIFY #6615 graded criterion 4 with no output at
  # all: `ERROR master-probe-unreachable (ssh bravo@…) dispatched=0` and nothing else (#6624). A dry run
  # reports; it cannot double-dispatch. So the probe failure stays fatal for `--apply` and is a WARNING
  # otherwise, with in-flight counts reported as 0 and said out loud so nobody reads them as measured.
  if [ "$APPLY" = 1 ]; then
    finish "ERROR master-probe-unreachable (ssh bravo@$BRAVO) dispatched=0"
  fi
  log "WARN master-probe-unreachable (ssh bravo@$BRAVO) — read-only run continues; in-flight counts below are UNMEASURED (shown as 0)"
fi

declare -A INFLIGHT
for M in $MASTERS; do INFLIGHT[$M]=0; done
LIVE_ISSUES=" "
while read -r M UNIT; do
  [ -n "${UNIT:-}" ] || continue
  case " $MASTERS " in *" $M "*) INFLIGHT[$M]=$(( ${INFLIGHT[$M]} + 1 )) ;; *) continue ;; esac
  # `dispatch.sh:815` builds the unit name: task-<issue>-<epoch>-<RANDOM>.service. The suffix after the
  # issue number is OPAQUE HERE ON PURPOSE — match the issue number and ignore the rest.
  # 🔴 This pattern used to be `^task-([0-9]+)-[0-9]+\.service$`, an exact two-segment match, and on
  # 2026-08-02 `9d006cbc` ("add entropy to the unit name — same-second dispatches collided") appended a
  # third segment to every unit dispatch.sh creates. Nothing failed: the extraction just stopped matching,
  # LIVE_ISSUES went permanently empty, and predicate 5 — the anti-double-dispatch check — silently could
  # not fire. Measured on #3816 at 2026-08-03T02:37Z: 11 live units across three boxes, 0 extracted, and
  # #3895 was running CONCURRENTLY on product and charlie with five ▶ markers on it.
  I="$(printf '%s' "$UNIT" | sed -nE 's/^task-([0-9]+)(-.*)?\.service$/\1/p')"
  [ -n "$I" ] && LIVE_ISSUES="$LIVE_ISSUES$I "
done <<< "$UNITS"
TOTAL_INFLIGHT=0; for M in $MASTERS; do TOTAL_INFLIGHT=$(( TOTAL_INFLIGHT + ${INFLIGHT[$M]} )); done

# ── The regression detector the last one lacked ───────────────────────────────────────────────────
# The failure above was invisible because a dead guard and a quiet board look identical. Units seen but
# no issue number recovered from any of them means the naming and this parser have diverged again — say
# so loudly rather than dispatching into live runs, and carry it into the heartbeat so it is legible from
# `--status` without reading the log.
UNIT_PARSE_BROKEN=0
if [ "$TOTAL_INFLIGHT" -gt 0 ] && [ "$LIVE_ISSUES" = " " ]; then
  UNIT_PARSE_BROKEN=1
  log "  ⚠ UNIT-NAME PARSE FAILED — $TOTAL_INFLIGHT live task unit(s), 0 issue numbers recovered."
  log "    The anti-double-dispatch check cannot fire. Reconcile this parser with dispatch.sh's unit name."
fi

# ── Live quota utilization from the OCC — read BEFORE reading reactive markers ─────────────────
# Fail OPEN: if the API is unreachable, we still dispatch. A silent halt is worse than a wasted run.
# The OCC publishes per-account 5h/7d utilization at /api/fleet-accounts, and each row already carries
# its OWN `.agents[]` — which masters share that account. That is read live in the loop below; NEVER
# hardcode which masters share an account, because it drifts (#6962): alpha, bravo, charlie and delta were
# believed to hold separate accounts and in fact ALL FOUR resolved to one shared account
# (`ops@example.com`) as of 2026-08-27 — confirmed both by `.agents[]` on this same endpoint and by
# `_infra/occ-feeds/usage/<master>.json`'s `.account` field, republished every ~10 min. Only `agent`
# (architect) holds a separate account. Read the derivation, never restate the current grouping here.
# We skip a master if its account is at/above the threshold on the 5h window.
#
# 🔴 QUOTA_THRESHOLD = 95 — ⚠ NOT MEASURED, AND "~95% is the natural line" WAS A PREFERENCE, NOT
# EVIDENCE (#6963). What IS measured is what the threshold can possibly buy, which is very little:
#   · The feeds carry a utilization history, so the approach to a real exhaustion is observable:
#       jq -c '.utilHistory[] | select(.fh>=90)' _infra/occ-feeds/usage/{alpha,bravo,charlie,delta}.json
#     Over 2026-08-26T00:00Z .. 2026-08-28T00:05Z (n=44..59 samples per master), the shared account
#     crossed 95 exactly once. The highest reading strictly BELOW exhaustion was bravo's `fh=99` at
#     2026-08-27T23:10:02Z; the first 🪫 capture on that account is 2026-08-27T23:11:19Z (#6930).
#     🔴 SEVENTY-SEVEN SECONDS. Every later sample reads 100.
#   · Sampling is ~10-15 minutes apart. The last sub-95 reading is `fh=91` at 23:00:01Z, so the true
#     95-crossing lies in (23:00:01, 23:10:02] and the honest bound is: **the threshold leads the hard
#     limit by between 77 seconds and 11 minutes**, against a 5-minute cycle. It detects; it does not
#     pre-empt. The full approach that night, one line per sample: 22:05 fh=56 · 22:20 64 · 22:30 69 ·
#     22:32 70 · 22:45 75 · 23:00 91 · 23:10 99 · 23:12 100.
# So 95 is not defensible as tuned, and — critically — the resolution above cannot tell 95 from 90, so
# LOWERING IT WOULD BE THE SAME UNMEASURED GUESS IN THE OTHER DIRECTION. Left at 95 deliberately.
# ⚠ AND ITS INPUT IS KNOWN-UNRELIABLE: on 2026-08-03 this same API reported only `product charlie` while ALL
#   FOUR masters were hard-limited (see QUOTA_DARK below) — a false negative no threshold can fix. That
#   is why the authoritative signal is `quota-status.json`, not this one. This is a cheap early hint.
# TO MEASURE IT: sample /api/fleet-accounts every 60 s (not 10-15 min) across one week, and for each
#   🪫 capture record the utilization 1/5/15 minutes before it. The threshold is worth setting to the
#   highest value that still leads the capture by more than one 5-minute cycle; if no such value exists,
#   the right change is to delete the check rather than to tune it.
QUOTA_THRESHOLD="${SWEEP_QUOTA_THRESHOLD:-95}"  # percent on 5h window — unmeasured; basis + how to measure above

fetch_live_quota() {
  local util_json="" api_url="https://example.com/api/fleet-accounts"
  util_json="$(curl -s --connect-timeout 5 --max-time 10 "$api_url" 2>/dev/null)" || util_json=""
  [ -n "$util_json" ] && printf '%s' "$util_json" | jq -e '.accounts' >/dev/null 2>&1 || util_json=""
  printf '%s' "$util_json"
}

# Parse live utilization and build list of masters whose accounts are over threshold
LIVE_QUOTA_UNHEALTHY=""
LIVE_QUOTA_API_OK=0
if LIVE_JSON="$(fetch_live_quota)"; then
  LIVE_QUOTA_API_OK=1
  # Parse each account's 5h utilization
  while IFS= read -r line; do
    acct_id="$(printf '%s' "$line" | jq -r '.account_id // empty' | tr '._' '_')"
    util_5h="$(printf '%s' "$line" | jq -r '.util.five_hour // empty' | sed 's/%//')"
    agents="$(printf '%s' "$line" | jq -r '.agents[]? // empty' 2>/dev/null)"

    if [ -n "$util_5h" ] && [ "$util_5h" -ge "$QUOTA_THRESHOLD" ] 2>/dev/null; then
      # This account is over threshold - add all its masters to unhealthy list
      for agent in $agents; do
        # Map agent name to master name (delta→delta, charlie→charlie, etc.)
        case "$agent" in
          delta) LIVE_QUOTA_UNHEALTHY="$LIVE_QUOTA_UNHEALTHY delta" ;;
          charlie) LIVE_QUOTA_UNHEALTHY="$LIVE_QUOTA_UNHEALTHY charlie" ;;
          agent) LIVE_QUOTA_UNHEALTHY="$LIVE_QUOTA_UNHEALTHY agent" ;;
          bravo) LIVE_QUOTA_UNHEALTHY="$LIVE_QUOTA_UNHEALTHY bravo" ;;
          alpha) LIVE_QUOTA_UNHEALTHY="$LIVE_QUOTA_UNHEALTHY alpha" ;;
        esac
      done
    fi
  done <<< "$(printf '%s' "$LIVE_JSON" | jq -c '.accounts[]? // empty' 2>/dev/null)"
else
  # API unreachable - we will dispatch anyway (fail open)
  LIVE_QUOTA_API_OK=0
fi

# ── Backend health: prefer a master that is not currently rate-limited ───────────────────────────
# Derived from the board's own 🪫 markers, which carry the master in the run signature (`bravo@fleet-host`).
# Not a probe and not a stored copy — the same comments the attempt cap is counted from. On 2026-07-30 an
# upstream 529 took out every master that shared the affected account at once; a sweep that cannot see that
# fans the whole backlog onto a dark upstream.
UNHEALTHY="$(jq -r --argjson h "$QUOTA_COOLDOWN_H" --argjson now "$(date +%s)" '
  [ .[].comments.nodes[]
    | select(.body | test("^\\s*🪫"))
    | select(($now - (.createdAt|fromdateiso8601)) <= ($h*3600))
    | (.body | capture("`(?<m>[a-z0-9]+)@") | .m) ] | unique | join(" ")' "$BOARD" 2>/dev/null || true)"

# ── AUTHORITATIVE quota state: the master's OWN quota-status.json (#3906) ────────────────────────
# 🔴 2026-08-03: the two signals above are both INDIRECT and both missed a total fleet blackout. The live
# utilization API reported only `product charlie` while ALL FOUR masters were hard-limited, and the 🪫 markers
# lag by however long it takes a run to fail and comment. The sweeper dispatched 14 runs into dark
# accounts inside ten minutes; every one exited status=1 in ~14s having done nothing, and each burned an
# attempt against MAX_ATTEMPTS — so a quota outage was silently spending issues' retry budget.
#
# `task-runner.sh` already writes the ground truth at $HOME/.claude/state/quota-status.json the moment it
# captures a 429 — with a machine-readable `resetsAt`, and it DELETES the file after a clean run, so it is
# self-healing rather than a stored copy that can drift. Read it directly and honour the expiry.
# One ssh for all four masters, mirroring the live-unit probe above. Fails OPEN: an unreadable file must never
# stop the fleet, only a positively-read live exhaustion may.
#
# 🔴 #3906 — THE PROBE MOVED TO dispatch.sh, IT DID NOT GET COPIED. This block used to carry its own
# ssh+sudo+jq reader. dispatch.sh now needs the identical answer for its own pre-flight (a HAND dispatch
# into a dark master burned runs just as the sweep did), and two readers of one file drift — so the
# reader lives in the one place every dispatch path already passes through, and this calls it. Same ssh,
# same fail-open rule, same output contract: dark master names, which `tr` flattens into the
# space-separated word list everything below already consumes. `|| true` keeps a probe failure from
# killing the cycle under `set -euo pipefail`, exactly as before.
# DISPATCH_NOVA_IP is passed through so this script's own SWEEP_NOVA_IP override keeps meaning something
# — the probe now runs inside dispatch.sh, which has its own default for the same box.
QUOTA_DARK="$(DISPATCH_NOVA_IP="$BRAVO" "$DISPATCH" --quota-dark 2>/dev/null | tr "\n" " " || true)"
# "<master><TAB>quota-exhausted|entitlement-dark" for every name in QUOTA_DARK above — read by
# unhealthy_reason() below so a held lane's log line names the real condition, never running-vs-idle (#7160).
# Same reader, same fail-open rule as QUOTA_DARK; a second ssh round trip would drift the two apart.
QUOTA_DARK_REASON="$(DISPATCH_NOVA_IP="$BRAVO" "$DISPATCH" --quota-dark-detail 2>/dev/null || true)"

# ── The candidate set ────────────────────────────────────────────────────────────────────────────
CANDIDATES="$(jq -c \
  --argjson masters '["alpha","bravo","charlie","delta"]' \
  --argjson mlogins "$MASTER_LOGINS" \
  --argjson hold "$HOLD_LABELS" --argjson nsec "$NEVER_STARTED_S" \
  --argjson now "$(date +%s)" --argjson settle "$FEATURE_SETTLE_MIN" \
  --arg repo "$REPO" '
  # Predicate 12 (#8670) - a parentless issue with no sub-issues at all, younger than the settle window.
  def settling: (.parent == null) and ((.subIssuesSummary.total // 0) == 0) and (.createdAt != null)
    and (($now - (.createdAt | fromdateiso8601)) < ($settle * 60));
  def fields: [.projectItems.nodes[]?.fieldValues.nodes[]?];
  def field($n): [fields[] | select(.field.name==$n) | .name] | first;
  def marks: [.comments.nodes[] | select((.author.login // "") != "gh-account1") | {createdAt, body: (.body | sub("^[ \\t]*#{1,6}[ \\t]+";""))} | select(.body | test("^\\s*(▶|✔|✘|⚠|⛔|🪫|⏹|🔓)"))];
  # 🔴 THE `sub` IS THE MARKER TEST, NOT COSMETIC (#5650). A LEADING MARKDOWN HEADING HID THE GLYPH.
  # Every marker this fleet writes by SCRIPT is bare — task-runner.sh posts `▶ started`, `✔ ROLLUP
  # VERIFIED`, `✘ FAILURE` with the glyph in column 1. Every marker a MASTER writes by hand is a heading:
  # `## ✔ ROLLUP VERIFIED — 8/8 acceptance criteria met`. Anchored on the glyph, this def saw the first
  # and was blind to the second, so a Feature could carry a full per-criterion attestation and still
  # present to this program as an issue with ZERO markers.
  # Measured 2026-08-15 over every ROLLUP comment on the board: 22 of 51 carry the heading form (43%).
  # It is load-bearing in one narrow window — an n/n Feature at Status=Todo that `stuck-pr-sweep.yml` has
  # not closed yet — and #5650 hit it: attestation posted 14:00:33Z, this sweeper selected the Feature and
  # dispatched a master onto finished work at 14:04:50Z, four minutes later. The comment at the term_glyph
  # branch below already said the quiet part — *"the ✔ is the only thing keeping it out of the queue"*
  # (#5587) — which is exactly why the ✔ has to be legible in the form masters actually write it.
  # The strip happens ONCE, here, and `marks` hands the demoted body downstream, so `live_marks`,
  # `last_marker`, `term_glyph`, `term_rollup`, `term_pr` and `count_non_quota_attempts` all inherit it
  # with no second regex to keep in sync. `{1,6}` + REQUIRED trailing space is ATX heading syntax: it
  # cannot eat a `#` that is part of prose, and `#5650 shipped` (no space after the run of #) is untouched.
  # Deliberately NOT changed here: the ⏸/⛔ latches below read `.comments.nodes` directly and stay
  # heading-blind. Same defect, different blast radius — filed as #5765, not smuggled into this diff.
  # Measured there: #5709 carries `## ⛔ VERIFY #5710 — verdict FAIL · 0 of 4`, the ⛔ latch counts 0.
  # 🔓 — THE MARK THAT SAYS "THIS RUN ENDED AND THE ISSUE IS STILL YOURS TO TAKE" (#5598).
  # strip_headings — remove markdown heading prefix (1-6 # symbols with whitespace) so heading-form
  # markers like `## ⛔ VERIFY #5710` are recognized the same as bare-form `⛔ blocked — …`. Added in
  # #5765 to fix the ⏸/⛔ latches that read .comments.nodes directly; the `marks` definition above was
  # fixed by #5650 but these latches were deliberately left unchanged.
  def strip_headings: sub("^[ \t]*#{1,6}[ \t]+"; "");
  # NOTE: this jq program is inside a SINGLE-QUOTED shell string, so no apostrophes in these comments.
  # task-runner.sh finish() posts a ✔ for the ship, and then — when the run deliberately left its issue
  # open (the PR carries no closing reference, or a reopen has already overruled the close) — a second
  # comment beginning `🔓 Left OPEN deliberately`, and sets Status back to Todo. That comment used to be
  # invisible here, so `live_marks | last` was the ✔ and predicate 6 rejected the issue forever: Todo on
  # the board, unreachable by any sweep, under a runner comment asserting it "stays visible and
  # dispatchable". A ✔ TOMBSTONE (#4181) built by the very guard that exists to protect a deliberate hold.
  # Reproduced against the text of THIS program before the fix, by `_infra/scripts/test-leave-open-mark.sh`,
  # which slices these two lines out of this file rather than copying them — so it cannot pass against a
  # stale duplicate of the predicate.
  # 🔓 is NON-terminal by construction: predicate 6 rejects only ▶/✔, and the ⛔/⏸ latches match their own
  # glyphs, so adding it changes exactly one thing — which comment is `last`. count_non_quota_attempts
  # counts ▶ only (the reduce passes every other glyph through untouched), so a 🔓 spends no retry budget.
  # Added to ALL FOUR copies of `marks` in this file. They are hand-duplicated and had already drifted
  # apart (💭 is in the explain copy at :878 and in none of the others; the explain `last_marker` at :956
  # counts ⚠ as terminal where predicate 6 does not). That drift is a separate defect, deliberately not
  # folded into a dispatch fix — but a fifth divergence is not the way to fix it either.
  # #4392 — A REOPEN OUTRANKS EVERY MARKER OLDER THAN IT. Predicate 6 below asks what the LAST marker is;
  # for months it asked that of every marker the issue had ever carried, including ones written in a
  # previous life. Reopening is not a comment: it is an explicit statement that the issue is NOT finished,
  # made after the marker that said it was. So a ✔/▶/⛔ from before the last ReopenedEvent is not the last
  # word — it is the last word of a lifecycle that has already ended.
  # This is not a hypothetical. #4179 reopened 20+ groupers closed while children were still open, and
  # every one of them that carried a ✔ was reborn permanently undispatchable — the one-way door #4179
  # existed to heal, re-created by the healing. Measured on the live board 2026-08-05: 4 of the 13 issues
  # predicate 6 rejected on a terminal marker (#3293 #3100 #3098 #3097) had a reopen POSTDATING that
  # marker; 12 open issues carried a reopen at all.
  # 🔴 This CANNOT re-dispatch genuinely finished work, which is the objection that kept predicate 6
  # untouched (`:553`): finished work is not reopened. The gate is not "ignore the ✔", it is "ignore
  # markers a human or a healer has since overruled by hand".
  # Scope is deliberately narrow: `marks` itself is UNCHANGED, so `count_non_quota_attempts` below and the
  # ⏸ park latch still see the full history. A reopen must not refund a retry budget that three real runs
  # already spent — that is a different question, and the answer to it is not obviously yes.
  def reopened_at: (.timelineItems.nodes[0].createdAt // null);
  def live_marks: reopened_at as $ro | [marks[] | select($ro == null or (.createdAt > $ro))];
  # OPEN direct children = total - completed. `completed` is every CLOSED child, not just the ones closed
  # as done, so this is the open count exactly (verified 8/8 on the live board + two all-not-planned
  # parents). Defaults to 0 so an issue the API returns no summary for stays dispatchable — fail OPEN,
  # because a filter that fails closed on a missing field would silently drain the whole queue.
  def open_subissues: ((.subIssuesSummary.total // 0) - (.subIssuesSummary.completed // 0));
  # never_started (#7969 item 3) - a ✘ that says the run died within $nsec seconds AND produced no artifact
  # never read the brief (OAuth expired, entitlement dark, 429 at turn 1): #7968 was parked at the cap by
  # three such runs in 5-103s and the park comment then blamed the brief. The ✘ comment carries
  # "failed after Ns" (task-runner.sh attempt line) and "produced no artifact"; both must hold, so a fast
  # failure that DID push work, or a slow real failure, still counts. Fails toward counting: no
  # "failed after Ns" text -> counts as a real attempt.
  def never_started($b):
    ($b | test("^\\s*✘")) and ($b | test("produced no artifact"))
    and (($b | capture("failed after (?<n>[0-9]+)s") | .n | tonumber) // 999) < $nsec;
  def count_non_quota_attempts:
    # Count ▶ markers, but exclude those whose run ended in a quota failure — an issue must not spend its
    # retry budget on an outage that was never about the work.
    #
    # 🔴 2026-08-03: this exclusion was DEAD CODE. It required the 🪫 body to contain "quota/rate-limit",
    # but that string only ever appears in ERR_CLASS (task-runner.sh:387), which goes into the ✘ FAILURE
    # comment — never into the 🪫 comment, whose body reads "🪫 quota-exhausted — `<master>` (<prov>) hit a
    # hard limit…" (task-runner.sh:1013). So the test never matched and EVERY quota-failed run charged an
    # attempt. Compounding: on a fleet-wide blackout the sweeper burns three attempts per issue in ~15
    # minutes and parks it, so a transient outage permanently removes work from autonomous dispatch.
    # The 🪫 glyph is itself the quota signal — it is written for nothing else — so match the glyph.
    # We iterate backwards through markers: when we see 🪫, we skip the preceding ▶.
    reduce ([marks | reverse[]] | .[]) as $m ({skip_next: 0, count: 0};
      if ($m.body | test("^\\s*🪫")) or never_started($m.body) then
        {skip_next: 1, count: .count}  # Flag to skip the next ▶ we see
      elif $m.body | test("^\\s*▶") then
        if .skip_next == 1 then
          {skip_next: 0, count: .count}  # Skip this ▶, it ended in quota failure
        else
          {skip_next: 0, count: (.count + 1)}  # Count this ▶
        end
      else
        {skip_next: .skip_next, count: .count}
      end
    ) | .count;
  # parked_title (#4826) — is this issue DECLARED non-dispatchable by its own title?
  # The convention is a LEADING TAG RUN: `[INTERACTIVE - the operator + …] [DO NOT DISPATCH] the real title`.
  # So the marker is looked for only inside the run of bracketed tags the title STARTS with, never in
  # the sentence after it. That distinction is not cosmetic - it is the difference between an issue that
  # says "do not dispatch me" and one that talks ABOUT dispatching, and this fleet has both:
  #   #4482 "Hold a VERIFY task whose parent Feature is [DO NOT DISPATCH]"  <- the FIX for this defect
  #   #4480 "A parked [DO NOT DISPATCH] Feature is auto-filed VERIFY child is still dispatchable"
  # A bare substring test holds both, and #4482 has in fact been stuck since 2026-08-05 with a dispatch
  # refusal comment on it - the repair blocked by the thing it repairs. Anchoring also GAINS a case the
  # substring form misses: #4720 `[DO NOT DISPATCH - input for the next deck plan]`, whose bracket carries
  # trailing words so it never matched the literal `[DO NOT DISPATCH]`.
  # Measured over all 100 open issues, 2026-08-09: 22 declarations held, 4 prose mentions released.
  def parked_title: ((.title | [match("^\\s*(\\[[^\\]]*\\]\\s*)+").string] | first // "")
                     | test("DO NOT DISPATCH|INTERACTIVE"));
  .[]
  | select((field("Status") // "") == "Todo" or (field("Status") // "") == "")
  # 🔴 A BLANK Lane is ROUTABLE, and an off-box lane is not (the operator, 2026-08-22: *"MASTER AGENTS ARE
  # NOT ASSIGNED TO A PORTFOLIO! THEY ARE PORTFOLIO AGNOSTIC!"*). The `*)` branch of pick_master has
  # offered any healthy master to any lane since 2026-08-03; this filter was the half that still
  # said "No Lane = unroutable", so a row with no Lane sat Todo forever while four masters idled.
  # It is the null case ONLY: `agent` is a named box no sweeper can reach and stays out.
  | select(field("Lane") as $l | $l == null or $l == "" or ($masters | index($l) != null))
  # Predicate 2b (#4826) - the title convention, enforced where the queue is BUILT.
  # dispatch.sh:1519 already refuses to start such a run, and says in the refusal comment it posts that
  # *"this title convention has no enforcement anywhere else in the pipeline"*. That was exact: the
  # sweeper still SELECTED the issue, spent a dispatch slot on it, and only then got the refusal. Measured
  # 2026-08-09 on #4825 - retitled with the marker at 20:05, selected and refused at 20:07:33 anyway.
  # The lane says WHICH box; the title says whether any box at all.
  | select(parked_title | not)
  | select(.parent == null or .parent.state == "OPEN")
  # Predicate 11 — the grouper check (#4063). Open children means the children ARE the work; dispatching
  # the parent alongside them runs the same brief twice. Absent summary (older API shape) reads as 0.
  | select(open_subissues == 0)
  # Predicate 12 (#8670) - a Feature exists before its children do; give them time to be filed.
  | select(settling | not)
  | select([.blockedBy.nodes[]? | select(.state == "OPEN")] | length == 0)
  | select([.labels.nodes[].name] | any(. as $x | ($hold | index($x)) != null) | not)
  | select([.labels.nodes[].name] | any(startswith("workflow:") or startswith("stuck:")) | not)
  | select([.assignees.nodes[].login] | all(. as $a | ($mlogins | index($a)) != null))
  # NOTE: this jq program is inside a SINGLE-QUOTED shell string, so no apostrophes in these comments.
  # ⏸ is the attempt-cap latch — but it must be RELEASABLE. Until 2026-08-03 this asked only "does a ⏸
  # exist anywhere in the last 25 comments", which made a park permanent: nothing a human or a fix could
  # write would clear it, so the issue silently left autonomous dispatch until the comment scrolled out of
  # the window. That was load-bearing on the wrong side — 4 of 5 parked issues had been parked by the
  # dead-code quota bug (3 quota-deaths each, zero real work failures) with no way back.
  # ANCHORED TO A LINE START (#6417, 2026-08-20). A bare test("UNPARK") is a SUBSTRING match, so a comment
  # that merely EXPLAINS the release protocol releases the latch. Measured on #6417: the run that blocked it
  # wrote the standard latch comment - whose own text is "comment UNBLOCK in all caps" - a later comment
  # quoted that protocol back, and the sweeper read the quotation as the token (last UNBLOCK index 3 > last
  # blocked index 2) and re-dispatched an issue whose blocker was untouched, 41 minutes after it latched.
  # Requiring the token at the START of a line keeps every real release working - a releaser types it first,
  # with or without a trailing reason - while prose ABOUT the protocol, always mid-sentence or backticked,
  # no longer fires. Blast radius measured over all 46 open board issues before landing: exactly one value
  # changed anywhere, #6417 not_blocked true->false; no not_parked value changed on any issue.
  # All THREE sites move together (predicate 5, the --explain mirror, and the announcer is_parked), because
  # the announcer note below is right that one file must not hold two readings of one convention.
  # The un-park token is the literal UNPARK written AFTER the last pause. It must NOT be a bare warn glyph:
  # task-runner writes that routinely (no-artifact, open-PR, pushed-no-PR - task-runner.sh:499-522), so
  # keying on it would make an issue permanently un-parkable after one such run. UNPARK is written by
  # nothing else. Compare positions, not existence.
  | select(
      ([.comments.nodes[] | select(.body | strip_headings | test("^\\s*⏸"))] | length == 0)
      or (([.comments.nodes | to_entries[] | select(.value.body | test("(^|\n)[ \t]*UNPARK\\b")) | .key] | last // -1)
          > ([.comments.nodes | to_entries[] | select(.value.body | strip_headings | test("^\\s*⏸")) | .key] | last // -1))
    )
  # ⛔ (blocked) is the human-only-action or missing-input latch — and like ⏸, it must be RELEASABLE.
  # Until this fix, ⛔ had no documented release path, making it a permanent terminal state.
  # The unblock token is the literal UNBLOCK written AFTER the last ⛔. Same rationale as UNPARK:
  # compare positions, not existence, so a deliberate release after the blocker is cleared always works.
  | select(
      ([.comments.nodes[] | select(.body | strip_headings | test("^\\s*⛔"))] | length == 0)
      or (([.comments.nodes | to_entries[] | select(.value.body | test("(^|\n)[ \t]*UNBLOCK\\b")) | .key] | last // -1)
          > ([.comments.nodes | to_entries[] | select(.value.body | strip_headings | test("^\\s*⛔")) | .key] | last // -1))
    )
  # Predicate 6: terminal markers that stop re-dispatch (▶ = run in progress, ✔ = shipped, ⛔ = blocked).
  # 🔴 A stopped-run mark (see #7167) is in `marks` above but is deliberately NOT terminal here.
  # Both halves are load-bearing: left OUT of `marks`, the stopped run own ▶ stays the last mark and
  # latches the issue undispatchable forever with nothing running; made TERMINAL here, the same thing
  # happens. In `marks` and non-terminal, a stopped run leaves its issue re-dispatchable — and predicate 5
  # live-unit check, not this one, is what stops a third run landing on a surviving sibling.
  # After the release checks above, a trailing ⛔ here means UNBLOCK was NOT written after it, so it is
  # genuinely stuck and should remain undispatchable. Same for ⏸/UNPARK — a trailing ⏸ here means the
  # release token is absent or older than the park.
  | select((live_marks | last) as $lm | $lm == null or ($lm.body | test("^\\s*(▶|✔)") | not))
  # 🔴 `.repo // $repo` — NOT `$repo` (2026-08-14). In project mode the flatten above already stamps each
  # item with its OWN repo from `.content.repository`; taking the global `$repo` here threw that away and
  # every candidate was dispatched as a knowledge issue. Measured live: product-a #262 (P5, the cost
  # view) was handed to dispatch.sh as a bare number, resolved against knowledge, and hit
  # `PRE-FLIGHT FAIL: #262 is CLOSED` — an unrelated NATS issue. The sweeper retried every cycle for ~50
  # minutes and the phase never started. Worse than the stall: with knowledge at #5xxx and product-a at
  # #3xx, a collision would dispatch a master against the WRONG repo issue.
  # `// $repo` keeps repo mode working, where items carry no repo of their own.
  | { n: .number, lane: field("Lane"), prio: (field("Priority") // "P3"),
      attempts: count_non_quota_attempts, title: .title, repo: (.repo // $repo) }
  ' "$BOARD" 2>&1 | jq -c -s 'sort_by((.prio|sub("P";"")|tonumber), .n) | .[]' 2>/dev/null)"

if [ -n "$ONLY_ISSUE" ]; then
  CANDIDATES="$(printf '%s\n' "$CANDIDATES" | jq -c --argjson i "$ONLY_ISSUE" 'select(.n == $i)' 2>/dev/null)"
fi

# ── EXPLAIN MODE: per-issue rejection reasoning ─────────────────────────────────────────────────
if [ "$EXPLAIN_MODE" = 1 ]; then
  log "├─ EXPLAIN: why Todo issues are/aren't dispatchable"
  jq -c --argjson masters '["alpha","bravo","charlie","delta"]' --argjson mlogins "$MASTER_LOGINS" --argjson hold "$HOLD_LABELS" --arg repo "$REPO" \
     --argjson now "$(date +%s)" --argjson settle "$FEATURE_SETTLE_MIN" '
    # Predicate 12 (#8670) - the same definition as the selector above; explain must mirror it (#4826).
    def settling: (.parent == null) and ((.subIssuesSummary.total // 0) == 0) and (.createdAt != null)
      and (($now - (.createdAt | fromdateiso8601)) < ($settle * 60));
    def fields: [.projectItems.nodes[]?.fieldValues.nodes[]?];
    def field($n): [fields[] | select(.field.name==$n) | .name] | first;
    def marks: [.comments.nodes[] | select((.author.login // "") != "gh-account1") | {createdAt, body: (.body | sub("^[ \\t]*#{1,6}[ \\t]+";""))} | select(.body | test("^\\s*(▶|✔|✘|⚠|⛔|🪫|💭|⏹|🔓)"))];
  # strip_headings — remove markdown heading prefix (1-6 # symbols with whitespace) so heading-form
  # markers like `## ⛔ VERIFY #5710` are recognized the same as bare-form `⛔ blocked — …`. Added in
  # #5765 to fix the ⏸/⛔ latches that read .comments.nodes directly; the `marks` definition above was
  # fixed by #5650 but these latches were deliberately left unchanged.
  def strip_headings: sub("^[ \t]*#{1,6}[ \t]+"; "");
    # #4392 — same rule as predicate 6: a marker older than the last reopen belongs to a lifecycle that
    # has ended. Explain must apply it too, or it prints a rejection reason the dispatcher no longer uses.
    def reopened_at: (.timelineItems.nodes[0].createdAt // null);
    def live_marks: reopened_at as $ro | [marks[] | select($ro == null or (.createdAt > $ro))];
    def open_subissues: ((.subIssuesSummary.total // 0) - (.subIssuesSummary.completed // 0));
    # Same definition as predicate 2b above - explain must apply every predicate the dispatcher does, or
    # it prints DISPATCHABLE for an issue the queue silently skips (#4826).
    def parked_title: ((.title | [match("^\\s*(\\[[^\\]]*\\]\\s*)+").string] | first // "")
                       | test("DO NOT DISPATCH|INTERACTIVE"));
    .[]
    | select((field("Status") // "") == "Todo" or (field("Status") // "") == "")
    | {
        n: .number,
        # #5497 — the board spans four repos and their numbering collides: `256` on this board is
        # product-a 256 (a PRODUCT admin cost column) while knowledge 256 is the EC-rehaul issue. A bare
        # number sent a reader to the wrong issue, so every line names the repo it came from. It stays
        # AFTER the number so the documented recipe `--explain | grep " <n>:"` keeps working.
        repo: (.repo // $repo),
        lane: field("Lane"),
        title: .title | .[0:100],
        open_kids: open_subissues,
        age_min: (if .createdAt == null then null else (($now - (.createdAt | fromdateiso8601)) / 60 | floor) end),
        # #4181 — WHICH terminal glyph, and whether a ✔ credits a merged PR. Predicate 6 rejects ▶/✔/⛔
        # identically, so for months every one of them printed the same "last-marker-is-terminal" and the
        # three could not be told apart by reading the output. They are not the same fact:
        #   ⛔ = a human-only step was declared — correct, permanent, leave it alone.
        #   ▶  = a run holds it right now (or a VANISHED ▶, which is #3419 job).
        #   ✔  = the run said it SHIPPED. Every issue explain sees is OPEN, so a ✔ here is a success
        #        marker on work the board still shows as Todo: the issue is now permanently
        #        undispatchable and anything chained behind it is held forever. THE TOMBSTONE.
        # Only the ✔ is a defect, and only the ✔ needed a name. term_pr splits the two remedies:
        # a ✔ that names a merged PR shipped and simply never got closed (close it), while one that
        # names none reported a success it did not achieve (state what is missing, non-terminally).
        # Diagnostic only — explain mode changes no dispatch decision. Predicate 6 IS now narrowed, but
        # only by the reopen rule (#4392): a ✔ nobody has overruled is still terminal, because making the
        # glyph itself non-terminal would re-dispatch genuinely finished work.
        # ⚠ term_pr is a TEXT match on the marker body, not a claim about a PR. It reads any
        # `PR #<n> merged` the runner wrote; it does not check that the PR references THIS issue. The ✔
        # that generated #4392 named PR #3427, which closed a SIBLING (#3397) and had merged four days
        # before that run started — the `closedByPullRequestsReferences` sibling-leak documented at
        # task-runner.sh:209 and since fixed there. Read term_pr as "the marker claims a merged PR",
        # then open the PR and check, exactly as the report body tells the reader to.
        term_glyph: ((live_marks | last) as $lm |
          if $lm == null then ""
          elif ($lm.body | test("^\\s*✔")) then "✔"
          elif ($lm.body | test("^\\s*▶")) then "▶"
          elif ($lm.body | test("^\\s*⛔")) then "⛔"
          else "" end),
        term_pr: ((live_marks | last) as $lm | $lm != null and ($lm.body | test("PR #[0-9]+ merged"))),
        # #4395 — the OTHER ✔. `✔ ROLLUP VERIFIED` is an attestation on an n/n parent Feature awaiting
        # `stuck-pr-sweep.yml`, not a run claiming a ship. It is still terminal to predicate 6 and still
        # correctly rejected, but it is NOT the ✔-TOMBSTONE defect, and `grep ✔-TOMBSTONE` is the report
        # the announcer tells readers to run — so it must not return finished Features.
        # #4828 — and the wording was the wrong discriminator: `✔ VERIFIED (not passed) … Feature stays
        # OPEN` on Feature #4805 matched neither, so it printed as a tombstone. What makes a ✔ harmless
        # here is that the issue is a PARENT — a Feature holds no work of its own, so nothing is stranded
        # by marking one terminal. is_parent is the test; term_rollup only picks which parent label to
        # print. 🔴 Read that as "nothing WORTH dispatching is lost", not "a parent cannot be dispatched":
        # measured 2026-08-14 (#5587), an n/n parent at Status=Todo passes every check above and prints
        # `✓ DISPATCHABLE` — the ✔ is the only thing keeping it out of the queue.
        is_parent: ((.subIssuesSummary.total // 0) > 0),
        term_rollup: ((live_marks | last) as $lm | $lm != null and ($lm.body | test("^\\s*✔\\s*ROLLUP VERIFIED"))),
        # WHICH hold label fired. `has-hold-label` alone named the class and not the member, so the one
        # question anyone asks of this output — "is anything still held by a gate we deleted?" — could
        # only be answered by re-deriving the labels from the API, issue by issue. Feature #6614
        # criterion 4 is literally a grep for a label name in this line (#6624).
        hold_hits: ([.labels.nodes[].name] | map(select(. as $x | ($hold | index($x)) != null)) | join(",")),
        checks: {
          status: ((field("Status") // "") == "Todo" or (field("Status") // "") == ""),
          lane: (field("Lane") as $l | $l == null or $l == "" or ($masters | index($l) != null)),
          not_parked_title: (parked_title | not),
          parent: (.parent == null or .parent.state == "OPEN"),
          no_open_subissues: (open_subissues == 0),
          settled: (settling | not),
          deps: ([.blockedBy.nodes[]? | select(.state == "OPEN")] | length == 0),
          hold_labels: ([.labels.nodes[].name] | any(. as $x | ($hold | index($x)) != null) | not),
          workflow_labels: ([.labels.nodes[].name] | any(startswith("workflow:") or startswith("stuck:")) | not),
          assignees: ([.assignees.nodes[].login] | all(. as $a | ($mlogins | index($a)) != null)),
          not_parked: (([.comments.nodes[] | select(.body | strip_headings | test("^\\s*⏸"))] | length == 0)
            or (([.comments.nodes | to_entries[] | select(.value.body | test("(^|\n)[ \t]*UNPARK\\b")) | .key] | last // -1)
                > ([.comments.nodes | to_entries[] | select(.value.body | strip_headings | test("^\\s*⏸")) | .key] | last // -1))),
          not_blocked: (([.comments.nodes[] | select(.body | strip_headings | test("^\\s*⛔"))] | length == 0)
            or (([.comments.nodes | to_entries[] | select(.value.body | test("(^|\n)[ \t]*UNBLOCK\\b")) | .key] | last // -1)
                > ([.comments.nodes | to_entries[] | select(.value.body | strip_headings | test("^\\s*⛔")) | .key] | last // -1))),
          last_marker: ((live_marks | last) as $lm | $lm == null or ($lm.body | test("^\\s*(▶|✔|⚠)") | not))
        }
      }
    | "\(.n): \(.repo) | \(.lane // "no-lane") | \(.title)" +
      (if .checks | all(. == true) then " ✓ DISPATCHABLE" else
       " ✗ REJECTED: " +
       (if .checks.status == false then "status-not-todo-or-empty " else "" end) +
       (if .checks.lane == false then "lane-not-in-masters " else "" end) +
       (if .checks.not_parked_title == false then "title-says-do-not-dispatch " else "" end) +
       (if .checks.parent == false then "parent-closed " else "" end) +
       (if .checks.no_open_subissues == false then "is-a-grouper:has-open-subissues(\(.open_kids)) " else "" end) +
       (if .checks.settled == false then "childless-root-filed-\(.age_min)m-ago:held-\($settle)m-for-its-children " else "" end) +
       (if .checks.deps == false then "has-open-deps " else "" end) +
       (if .checks.hold_labels == false then "has-hold-label:\(.hold_hits) " else "" end) +
       (if .checks.workflow_labels == false then "has-workflow-label " else "" end) +
       (if .checks.assignees == false then "assignees-not-masters " else "" end) +
       (if .checks.not_parked == false then "is-parked " else "" end) +
       (if .checks.not_blocked == false then "is-blocked " else "" end) +
       (if .checks.last_marker == false then "last-marker-is-terminal:\(.term_glyph) " +
          (if .term_glyph == "✔" then
             (if .is_parent then
                (if .term_rollup then "✔-ROLLUP-ATTESTED:awaiting-stuck-pr-sweep-closure "
                 else "✔-ON-PARENT-FEATURE:awaiting-stuck-pr-sweep-closure " end)
              elif .term_pr then "✔-TOMBSTONE:merged-pr-but-issue-still-open "
              else "✔-TOMBSTONE:no-merged-pr " end)
           else "" end)
        else "" end)
       end)
    ' "$BOARD" 2>/dev/null | while IFS= read -r line; do log "  │ $line"; done
  log "└─ EXPLAIN end"
fi

# Debug: check if CANDIDATES is empty when it shouldn't be
if [ -n "$CANDIDATES" ] && [ "$EXPLAIN_MODE" = 1 ]; then
  FIRST_CAND="$(printf '%s\n' "$CANDIDATES" | head -1)"
  log "  │ DEBUG: first candidate line: ${FIRST_CAND:0:200}"
fi

N_CAND="$(printf '%s' "$CANDIDATES" | grep -c . || true)"

# Combine the three quota signals: the master's OWN state file (authoritative, #3906), the live
# utilization API, and the reactive 🪫 board markers. QUOTA_DARK is first because it is the only one
# read from the process that actually hit the limit — the other two are inferences about it.
ALL_UNHEALTHY=""
for m in $QUOTA_DARK $LIVE_QUOTA_UNHEALTHY $UNHEALTHY; do
  case " $ALL_UNHEALTHY " in *" $m "*) ;; *) ALL_UNHEALTHY="$ALL_UNHEALTHY $m" ;; esac
done

# Build the rate-limited log segment, distinguishing live from reactive sources
RATE_LIMITED_LOG=""
if [ -n "$ALL_UNHEALTHY" ]; then
  DARK_PART=""; LIVE_PART=""; REACTIVE_PART=""
  for m in $ALL_UNHEALTHY; do
    case " $QUOTA_DARK "             in *" $m "*) DARK_PART="$DARK_PART $m" ;; esac
    case " $LIVE_QUOTA_UNHEALTHY "   in *" $m "*) LIVE_PART="$LIVE_PART $m" ;; esac
    case " $UNHEALTHY "              in *" $m "*) REACTIVE_PART="$REACTIVE_PART $m" ;; esac
  done
  RATE_LIMITED_LOG=" · rate-limited:"
  # `exhausted` is the master's own state file — the only one of the three that is not an inference.
  [ -n "$DARK_PART" ] && RATE_LIMITED_LOG="$RATE_LIMITED_LOG (exhausted$DARK_PART)"
  [ -n "$LIVE_PART" ] && RATE_LIMITED_LOG="$RATE_LIMITED_LOG (live$LIVE_PART)"
  [ -n "$REACTIVE_PART" ] && RATE_LIMITED_LOG="$RATE_LIMITED_LOG (reactive$REACTIVE_PART)"
fi
[ "$LIVE_QUOTA_API_OK" = 0 ] && RATE_LIMITED_LOG="$RATE_LIMITED_LOG · quota-api-unreachable"

log "sweep: $N_ISSUES open · $N_CAND dispatchable · in-flight $TOTAL_INFLIGHT ($(for M in $MASTERS; do printf '%s=%s ' "$M" "${INFLIGHT[$M]}"; done))${RATE_LIMITED_LOG}$( [ "$APPLY" = 1 ] || printf ' · DRY RUN')"

# unhealthy_reason <master> → one word from the closed enum: quota-exhausted | entitlement-dark |
# rate-limited. The ONLY three things `ALL_UNHEALTHY` membership can mean (#7160): a master is never
# excluded for merely having work in flight. quota-exhausted/entitlement-dark come from the
# master's OWN state file via `QUOTA_DARK_REASON` (authoritative, #3906); rate-limited covers the two
# signals that are INFERENCES about it — the live utilization API and the reactive 🪫 board markers —
# because neither is a positive read of the master's own state.
unhealthy_reason() {
  local m="$1" r
  r="$(printf '%s\n' "$QUOTA_DARK_REASON" | awk -F'\t' -v m="$m" '$1==m{print $2; exit}')"
  [ -n "$r" ] && { printf '%s' "$r"; return; }
  printf 'rate-limited'
}

# pick_master <lane> → sets `PICK_MASTER` and returns 0 on a free, healthy master; or returns 1 and
# sets `PICK_REASON` to `unhealthy_reason` of the FIRST unhealthy candidate this lane's fixed order
# tried (deterministic, same order the loop below already walks) — what the caller logs (#7160).
# 🔴 BOTH ARE GLOBALS, NEVER `$(pick_master …)` — the caller needs TWO answers (which master, and
# why not), and a function's stdout can only ever carry one. Command substitution also runs the
# function in a SUBSHELL, so a global set *inside* it would silently vanish the moment `$(...)`
# closed — caught live writing this fix's own test before it ever reached sweep-dispatch.sh.
#
# 🔴 2026-08-03 — LANE IS A BOX, NOT A PORTFOLIO. the operator: *"world infrastructure architecture needs to be
# sent to alpha? This is legacy. Master agents should be flexible to be able to handle any type of issue that
# is across world infrastructure, PRODUCT, or raw."*
#
# This function used to treat `alpha` and `product` as "a PORTFOLIO claim, not a preference" and let only
# bravo↔charlie cover for each other. The result was visible the same night: **3 issues held because alpha was
# the only lane tried** while bravo, charlie and product were all healthy and the queue was otherwise empty —
# alpha was quota-dark until 10:38Z, so ALPHA-subject work would have idled for seven hours beside three
# available masters. Subject matter is the **Portfolio** field; it has never been what a lane means.
#
# The lane is still tried FIRST (locality is real: a master that has been in a repo has its clone warm, and
# `product` holds the PRODUCT credentials), but ANY healthy master may now take ANY issue. Order is deterministic —
# lane, then the remaining masters in a fixed order — so behaviour stays reproducible rather than random.
#
# ⚠ `delta` keeps a one-way fence: other masters may take PRODUCT work, but `delta` is preferred for it and is NOT
# offered someone else's queue first, because it is the lane holding live-revenue credentials.
# 🔴 A LANE THAT IS NOT A MASTER IS NOT A LANE (#6624). `jq -r` renders an absent Lane field as the
# four characters `null`, and this loop used to hand that straight back as the chosen master: the caller
# then did `INFLIGHT[null]` and died `unbound variable` under `set -u`, killing the whole cycle. It never
# fired before only because every blank-Lane row was held out of dispatch by `needs:triage` — deleting
# that gate (#6618) made blank Lane reach here for the first time since #6579 declared it routable, and
# the very first dry run crashed at candidate 1 of 14. The lane is a PREFERENCE; an unrecognised one
# (blank, `null`, a retired box) simply expresses none and falls through to the fixed order below.
pick_master() {
  local lane="$1" m
  PICK_MASTER=""; PICK_REASON=""
  case " $MASTERS " in *" $lane "*) ;; *) lane="" ;; esac
  for m in "$lane" $(case "$lane" in
        bravo)  echo "charlie alpha delta" ;;
        charlie) echo "bravo alpha delta" ;;
        alpha)   echo "charlie bravo delta" ;;
        delta)  echo "charlie bravo alpha" ;;
        *)     echo "charlie bravo alpha delta" ;;
      esac); do
    [ -n "$m" ] || continue
    case " $MASTERS " in *" $m "*) ;; *) continue ;; esac
    case " $ALL_UNHEALTHY " in
      *" $m "*) [ -n "$PICK_REASON" ] || PICK_REASON="$(unhealthy_reason "$m")"; continue ;;
    esac
    PICK_MASTER="$m"; return 0
  done
  [ -n "$PICK_REASON" ] || PICK_REASON="rate-limited"
  return 1
}

DISPATCHED=0; PARKED=0; SKIPPED=0; REG_FAILED=0; NO_PLAN=0; LANES_SAID=" "
# #7163 — what the selection loop CHOOSES; the launch phase after it starts them all at once.
SEL_N=(); SEL_M=(); SEL_REPO=(); SEL_TITLE=(); SEL_ATT=()
while read -r C; do
  [ -n "$C" ] || continue
  N="$(printf '%s' "$C" | jq -r '.n')"
  # `// ""` — an absent Lane is empty, never the four characters `null` (see pick_master, #6624).
  LANE="$(printf '%s' "$C" | jq -r '.lane // ""')"
  ATT="$(printf '%s' "$C" | jq -r '.attempts')"
  TITLE="$(printf '%s' "$C" | jq -r '.title' | cut -c1-70)"
  REPO_ISSUE="$(printf '%s' "$C" | jq -r '.repo')"

  # ── The attempt cap. A permanently-failing task must stop being re-dispatched. ──────────────────
  # Counted from the issue's own ▶ comments, so the bound survives a wiped box and cannot drift from
  # what the board shows. At the cap it says so ONCE and never dispatches again — the ⏸ comment is both
  # the announcement and the latch, which is why the candidate filter above excludes issues that have one.
  if [ "$ATT" -ge "$MAX_ATTEMPTS" ]; then
    if [ "$APPLY" = 1 ]; then
      gh issue comment "$N" --repo "$REPO_ISSUE" </dev/null --body "⏸ **Parked by the sweeper — ${ATT} dispatch attempts, still not done.**

The autonomous sweep (\`_infra/scripts/sweep-dispatch.sh\`, riding bravo's \`reconcile-board.timer\`) counts the ▶ markers on this issue: **${ATT}**, at the cap \`SWEEP_MAX_ATTEMPTS=${MAX_ATTEMPTS}\`. **It will not dispatch this issue again.**

This is the bound, working. Three runs that produced nothing mean the brief, the prerequisite or the target is wrong — a fourth identical attempt burns the fleet's quota and hides the defect behind more noise.

**To restart it:** fix the brief, then delete this comment (it is the latch) or dispatch by hand — \`dispatch.sh <master> ${N}\`. A hand dispatch always works; the cap stops the *loop*, never the work." >/dev/null 2>&1 \
        && log "  ⏸ #$N parked at $ATT attempts — $TITLE" \
        || log "  ⏸ #$N parked at $ATT attempts (comment FAILED to post) — $TITLE"
    else
      log "  ⏸ #$N would be PARKED at $ATT attempts — $TITLE"
    fi
    PARKED=$((PARKED+1)); continue
  fi

  # ── No double-dispatch. The unit, not the marker: a run whose reporting layer died is still a run. ─
  case "$LIVE_ISSUES" in *" $N "*) log "  · #$N skipped — a task-$N unit is live"; SKIPPED=$((SKIPPED+1)); continue ;; esac

  # The caps are counted, not narrated. 81 issues were dispatchable on the first live read of this board,
  # so a line per held issue is 79 lines of noise per cycle in a log nobody would then read. Each cap and
  # each held lane says itself ONCE; the totals are in the heartbeat.
  if ! pick_master "$LANE"; then
    case " $LANES_SAID " in *" ${LANE:-«blank»} "*) ;; *) log "  · lane ${LANE:-«blank»}: $PICK_REASON — holding its queue"; LANES_SAID="$LANES_SAID${LANE:-«blank»} " ;; esac
    SKIPPED=$((SKIPPED+1)); continue
  fi
  M="$PICK_MASTER"

  if [ "$APPLY" != 1 ]; then
    log "  → would dispatch #$N to $M (lane $LANE, attempt $((ATT+1))) — $TITLE"
    DISPATCHED=$((DISPATCHED+1)); INFLIGHT[$M]=$(( ${INFLIGHT[$M]} + 1 )); TOTAL_INFLIGHT=$((TOTAL_INFLIGHT+1)); continue
  fi

  # 🔴 SELECTION ONLY — the launch happens AFTER this loop, in parallel (#7163, PLAN-239 P5).
  # This loop must stay SERIAL and must stay free of network calls, because it carries three pieces of
  # state that a subshell would silently destroy:
  #   · LIVE_ISSUES — the anti-double-dispatch guard, read at the top of this body and written here.
  #     A `&`-backgrounded write goes to a subshell and is LOST, which would turn the guard into a no-op
  #     AND leave LIVE_ARR empty for the reaper (measured once: 148 of 148 cycles, zero ☠ lines).
  #   · INFLIGHT[] / TOTAL_INFLIGHT — read-modify-write, feeding the heartbeat the operator reads.
  #   · DISPATCHED / SKIPPED / LANES_SAID — same shape, same reason.
  # Selecting here and launching after keeps every one of them in the parent shell, unchanged.
  SEL_N+=("$N"); SEL_M+=("$M"); SEL_REPO+=("$REPO_ISSUE"); SEL_TITLE+=("$TITLE"); SEL_ATT+=("$ATT")
  DISPATCHED=$((DISPATCHED+1)); INFLIGHT[$M]=$(( ${INFLIGHT[$M]} + 1 )); TOTAL_INFLIGHT=$((TOTAL_INFLIGHT+1))
  LIVE_ISSUES="$LIVE_ISSUES$N "
  continue

done <<< "$CANDIDATES"

# ── THE LAUNCH PHASE — every selected issue starts CONCURRENTLY (#7163, PLAN-239 P5) ──────────────
# Before this, `bash "$DISPATCH" …` sat inside the loop above and BLOCKED. Each call costs several ssh
# round trips plus a git fetch, so N ready issues cost N × the whole path and the cycle's wall-clock was
# the sum of every dispatch. The board could hold four dispatchable issues and start them minutes apart.
#
# 🔴 THIS PHASE IS ONLY SAFE BECAUSE #7162 LANDED FIRST. dispatch.sh used to `sleep 20` whenever another
# master on the same account had a run in flight — a stagger that is a stagger ONLY because the caller is
# serial. Run N of those at once and all N sleep together, then launch in the same instant: it inverts
# into a synchronizer. #7162 deleted it, so these launches are genuinely independent.
#
# 🔴 `</dev/null` ON EVERY CHILD, still. The candidate loop above reads from a here-string; an ssh with
# no redirect consumes its parent's stdin. That once reported `dispatched=1` against 81 candidates.
# Backgrounding does not change it — each child still inherits this shell's stdin.
#
# Results come back through FILES, never variables: a `&` child cannot write its parent's shell state,
# which is the whole reason the selection loop above stayed serial.
if [ "$APPLY" = 1 ] && [ "${#SEL_N[@]}" -gt 0 ]; then
  LAUNCH_DIR="$(mktemp -d)"
  log "  ⇉ launching ${#SEL_N[@]} dispatch(es) in parallel"
  for _i in "${!SEL_N[@]}"; do
    (
      _n="${SEL_N[$_i]}"; _m="${SEL_M[$_i]}"; _r="${SEL_REPO[$_i]}"
      if bash "$DISPATCH" "$_m" "$_n" "$_r" </dev/null >>"$LOG" 2>&1; then
        _rc=0
        bash "$DISPATCH" --register-from-issue "$_n" "$_r" </dev/null >>"$LOG" 2>&1 || _rc=$?
        printf 'ok %s
' "$_rc" > "$LAUNCH_DIR/$_i"
      else
        printf 'fail
' > "$LAUNCH_DIR/$_i"
      fi
    ) &
  done
  wait

  # Collect. The counters were already incremented at SELECTION time (the optimistic case), so this
  # phase only CORRECTS the ones that did not launch — a failed dispatch gives its INFLIGHT slot back
  # and moves to SKIPPED, and its issue leaves LIVE_ISSUES so the next cycle can retry it.
  for _i in "${!SEL_N[@]}"; do
    _n="${SEL_N[$_i]}"; _m="${SEL_M[$_i]}"; _t="${SEL_TITLE[$_i]}"; _a="${SEL_ATT[$_i]}"
    _res="$(cat "$LAUNCH_DIR/$_i" 2>/dev/null || echo fail)"
    case "$_res" in
      ok*)
        log "  → dispatched #$_n to $_m (attempt $((_a+1))) — $_t"
        case "${_res#ok }" in
          0) : ;;                        # registered, or already TIER 1
          3) NO_PLAN=$((NO_PLAN+1)) ;;   # no owning plan — a fact, not a failure (#6616)
          *) REG_FAILED=$((REG_FAILED+1)) ;;
        esac
        ;;
      *)
        # Same reasoning as before: a failed launch is NOT retried inside this cycle. dispatch.sh's
        # pre-flight refuses for real reasons, and hammering turns one bad reason into four bad runs.
        log "    ✘ dispatch.sh failed for #$_n → $_m (see $LOG) — left Todo for the next cycle"
        DISPATCHED=$((DISPATCHED-1)); SKIPPED=$((SKIPPED+1))
        INFLIGHT[$_m]=$(( ${INFLIGHT[$_m]} - 1 )); TOTAL_INFLIGHT=$((TOTAL_INFLIGHT-1))
        LIVE_ISSUES="${LIVE_ISSUES/ $_n / }"
        ;;
    esac
  done
  rm -rf "$LAUNCH_DIR"
fi

# 🔴 LIVE_ARR MUST be assigned BEFORE the reaper, not inside the announcer block below.
# Measured 2026-08-05: it was used by the reaper's jq (`--argjson live "$LIVE_ARR"`) while first being
# assigned ~120 lines later, inside `if [ "$ANNOUNCE" = 1 ]`. Under `set -u` the command substitution died
# on an unbound variable, VANISHED came back empty, and the reaper reported reaped=0 — **148 of 148 cycles,
# zero ☠ lines, never once fired since #3898 introduced it.** Nothing errored: the jq's 2>/dev/null ate it.
# It is the shape this whole fleet keeps hitting — a success signal that is not the thing being measured.
# The announcer re-derives its own copy below; this assignment is the reaper's, and both are cheap.
LIVE_ARR="$(printf '%s\n' $LIVE_ISSUES | jq -R 'select(test("^[0-9]+$")) | tonumber' 2>/dev/null | jq -s -c 'unique' 2>/dev/null)"
case "$LIVE_ARR" in \[*\]) ;; *) LIVE_ARR='[]' ;; esac

# ══ THE REAPER — reset Doing issues whose runs vanished and will never report (#3898) ═══════════════════
#
# When a run is KILLED (session teardown, OOM, reboot), the EXIT trap in task-runner.sh never fires,
# so the issue stays in Status=Doing forever. The sweeper's only consumer is Status=Todo, so these
# issues become invisible to the machine built to consume them.
#
# The reaper finds Doing issues where:
#   - last marker is ▶ (run started)
#   - no live task-* unit exists on any master
#   - the ▶ is old enough (>2 hours by default, to avoid resetting genuinely long runs)
#
# and resets their Status to Todo, making them dispatchable again. The ▶ still counts against
# SWEEP_MAX_ATTEMPTS, so this cannot loop.
# 🔴 REAPER_MINUTES = 120 — MEASURED (#6963). "Avoid resetting genuine long runs" was a precaution
# with no number behind it; the number now exists, and it is the same distribution ANNOUNCE_RUN_MIN
# rests on, because both ask one question: how long can a real run legitimately be silent?
#   bash _infra/scripts/measure-sweeper-constants.sh runs          # 2026-08-28T00:30Z, 600 issues sampled
#   n=296  min=0.30  p50=10.45  p90=24.60  p99=57.98  max=59.53    (minutes, ▶ → ✔/✘ on one issue)
# ZERO of 296 completed runs reached 60 minutes. 120 is 2.0x the longest ever observed, so the reaper
# cannot reset a live run — which is its entire safety requirement. It is also DOUBLY guarded: the age
# test is ANDed with "no live task-* unit on any master", and that probe, not the clock, is the real
# signal. The clock only stops a blinked probe from reaping a run that is genuinely still going.
# ⚠ VALUE UNCHANGED. The measurement would support a smaller number (90 would still be 1.5x the max and
#   would return a killed run to the queue half an hour sooner), but lowering it is a behaviour change
#   to the reaper and #6963's scope fence forbids it. Re-derive before changing: a rise in the turn cap
#   (dispatch.sh TURNS=200) or the arrival of a wall-clock timeout would both move this distribution.
REAPER_MINUTES="${SWEEP_REAPER_MINUTES:-120}"  # 2 hours default — measured basis above
REAPED=0

if [ "$APPLY" = 1 ]; then
  # Same constants as task-runner.sh for Status field updates
  PROJ=PVT_kwDOEZ-Tjc4Bb8OG
  F_STATUS=PVTSSF_lADOEZ-Tjc4Bb8OGzhWow3o
  S_TODO=cbac0e73

  VANISHED="$(jq -c \
    --argjson now "$(date +%s)" --argjson live "$LIVE_ARR" --argjson t_reap "$REAPER_MINUTES" \
    --arg repo "$REPO" '
    def fields: [.projectItems.nodes[]?.fieldValues.nodes[]?];
    def field($n): [fields[] | select(.field.name==$n) | .name] | first;
    def marks: [.comments.nodes[] | select((.author.login // "") != "gh-account1") | {createdAt, body: (.body | sub("^[ \\t]*#{1,6}[ \\t]+";""))} | select(.body | test("^\\s*(▶|✔|✘|⚠|⛔|🪫|⏹|🔓)"))];
    def age($t): (($now - ($t | fromdateiso8601)) / 60 | floor);
    .[]
    | select(field("Status") == "Doing")
    | ((marks | last) // null) as $lm
    | select($lm != null)
    | select($lm.body | test("^\\s*▶"))
    | select(($live | index(.number)) == null)  # no live unit
    | select(age($lm.createdAt) >= $t_reap)
    | {n: .number, age: age($lm.createdAt), created: $lm.createdAt, repo: $repo}
    ' "$BOARD" 2>/dev/null)"

  while read -r V; do
    [ -n "$V" ] || continue
    N="$(printf '%s' "$V" | jq -r '.n')"
    VAGE="$(printf '%s' "$V" | jq -r '.age')"
    REPO_VANISHED="$(printf '%s' "$V" | jq -r '.repo')"

    # Reset Status to Todo (board-project.sh — the GraphQL path; `gh project` needs read:org, #6563)
    OWNER="${REPO_OWNER:-example-org}"
    ITEM_ID=$("$_SD/board-project.sh" item-add 1 --owner "$OWNER" --url "https://github.com/$REPO_VANISHED/issues/$N" --format json 2>/dev/null | jq -r '.id // empty')
    if [ -n "$ITEM_ID" ]; then
      if "$_SD/board-project.sh" item-edit --project-id "$PROJ" --id "$ITEM_ID" --field-id "$F_STATUS" --single-select-option-id "$S_TODO" >/dev/null 2>&1; then
        log "  ☠ reaped #$N — Status Doing→Todo (▶ was ${VAGE}m old, no live unit)"
        REAPED=$((REAPED+1))
      else
        log "  ⚠ reaper FAILED to reset Status for #$N"
      fi
    else
      log "  ⚠ reaper could not get item id for #$N"
    fi
  done <<< "$VANISHED"
fi

# ══ THE ANNOUNCER — a stall nobody is coming for becomes a board issue (#4182) ═══════════════════
#
# Everything above computes, every five minutes, the exact reason each Todo issue is not dispatchable —
# and until this block existed it printed that to a log nobody reads. There was no `gh issue create` and
# no announce path anywhere in this file. Doctrine: *"anything unattended announces itself where the operator
# looks"* and *"silence is the only unacceptable state."*
#
# ── WHAT IS ANNOUNCED: the four that mean NOBODY IS COMING ───────────────────────────────────────
#   parent-closed  a Todo sub-issue whose parent Feature is CLOSED. Predicate 3 rejects it forever; the
#                  one-way door #4179 healed 20 of by hand. #4179 also landed a PARENT-side advisory in
#                  stuck-pr-sweep.yml (one comment on the closed parent, keyed on its closedAt). This is
#                  the CHILD side plus the persistence threshold, which is exactly the split agreed on
#                  #4182: that advisory fires on the EVENT of the close; this fires only once the orphan
#                  has survived $ANNOUNCE_STALL_MIN minutes of it, i.e. once nobody acted on the notice.
#   run-vanished   Status=Doing whose last marker is a ▶ older than $ANNOUNCE_RUN_MIN minutes AND which
#                  has no live `task-<n>` unit on any box. The run died without reporting, so its ✔/✘ is
#                  never coming. `board-reconcile.yml:337` explicitly REFUSES to heal this
#                  (`if (!last || /^▶/.test(...)) continue;`) — it is nobody's job but this one's.
#   tombstone      a ✔ as the last marker on an OPEN LEAF issue (#4181). The success marker is a
#                  gravestone: predicate 6 treats it as terminal, so the issue is permanently
#                  undispatchable and everything chained behind it is held forever. "Last" means since
#                  the last REOPEN (#4392) — a ✔ a reopen has already overruled is nobody being stuck, so
#                  it is not announced. That is the same never-announce reasoning as the list below: the
#                  mechanism released it, and reporting a release trains the operator to ignore the channel.
#                  LEAF is load-bearing (#4828): a parent Feature is not dispatched by anything, so a ✔
#                  on one strands nothing and belongs to the class below.
#   rollup-unclosed  an n/n PARENT Feature whose last marker is any ✔ and which the auto-closer has not
#                  reached in $ANNOUNCE_ROLLUP_MIN minutes — counted from the moment the Feature REACHED
#                  n/n, i.e. its last child closing, not from the ✔ (#6233; the board query cannot carry
#                  that timestamp, so it is re-read per candidate at Property 1c in the filing loop).
#                  Same glyph as tombstone, different fact —
#                  see the block immediately below, which is why it is tested FIRST. The remedy splits on
#                  whether that ✔ is the runner attestation (`✔ ROLLUP VERIFIED`) or something else, but
#                  the class does not: both are a Feature waiting on `stuck-pr-sweep.yml`, never a
#                  gravestone.
#   dead-lane      lane `agent` (a box this sweeper cannot reach), RUNNABLE for $ANNOUNCE_DEADLANE_MIN, on an issue that SOMETHING ELSE
#                  IS BLOCKED ON. A stranded leaf costs one issue and is sometimes correct; a stranded
#                  CHAIN LINK holds its whole tail open forever (#4180).
#
# ── WHY A ROLLUP-ATTESTED FEATURE IS NOT A TOMBSTONE (#4395) ─────────────────────────────────────
# The tombstone class asks "is the last marker a ✔?" and until #4395 that caught two different facts
# wearing one glyph. `task-runner.sh:404` writes `✔ ROLLUP VERIFIED` onto a PARENT Feature the moment
# its last sub-issue closes, and explicitly does NOT close it — closure belongs to `stuck-pr-sweep.yml`
# (#3310), because a parent Feature has no PR OF ITS OWN — not because `Closes #N` cannot reach it. It
# can: any sub-issue's PR body may name the parent's number and GitHub closes it (2026-09-04, #7513 →
# #7500 → the stall #7514). So between the
# attestation and the closer's next successful run, EVERY finished Feature sits open under a ✔.
# That is not a stall. It is the hand-off working, mid-flight.
#
# The remedies are not interchangeable either, which is what makes this worth a class rather than a
# tweak. Tombstone tells the reader: close it, or post a ✘ and set Status back to Todo. Applied to a
# genuinely-finished Feature, the second half is an instruction to write a false ✘ onto verified work.
#
# 🔴 AND THE THRESHOLD MADE IT UNCONDITIONAL. $ANNOUNCE_STALL_MIN is 15 minutes; the closer's observed
# inter-run gap has a MINIMUM of 59 (n=103, see ANNOUNCE_ROLLUP_MIN above). 103 of 103 gaps exceed 15,
# so this did not misfire occasionally — it misfired on every rollup-attested Feature, always, and the
# report was already filed before the closer could plausibly have run. #4395 is that report, about
# #4356: attested 06:16:42Z, announced 06:35:45Z, and the true remedy was "wait".
#
# The fix is NOT silence — an n/n Feature nobody ever closes is a real stall, and its children are
# real orphan-factories (#4390). It is the right threshold plus the right remedy: past $t_rollup the
# closer is not merely late, and the report says "close it", never "post a ✘".
#
# 🔴 #4828 — AND THE DISCRIMINATOR WAS THE WRONG ONE. #4395 fixed the misfire by matching the literal
# string `✔ ROLLUP VERIFIED`, which assumed the runner writes every ✔ a Feature ever carries. It does
# not: a VERIFY sub-issue posts its verdict onto its PARENT. Feature #4805 carried
# `✔ VERIFIED (not passed) — … **Feature stays OPEN.**` — a marker whose own first line says the
# Feature is unfinished — and 16 minutes later it was announced as a tombstone, remedy "close it, or
# post a ✘ and set Status back to Todo". Both halves are wrong on a Feature: it was 2 of 4 acceptance
# criteria short of done, and nothing dispatches a Feature for a ✘ to release.
# The discriminator is PARENT-vs-LEAF, which is a structural fact on the board rather than a phrase
# some master chose. Wording now selects only the REMEDY (attestation present → close it; absent →
# no per-criterion table exists, so grade the acceptance yourself first).
# ── WHAT IS NEVER ANNOUNCED, AND WHY THAT LIST IS AS LOAD-BEARING AS THE ONE ABOVE ───────────────
#   has-open-deps · has-hold-label · is-parked (⏸) · is-a-grouper · `[DO NOT DISPATCH]`/`[INTERACTIVE`
# Every one of those is the mechanism WORKING. An announcer that reports correct holds trains the operator to
# ignore the channel, and a channel the operator ignores is worse than the log nobody reads — it looks like it
# is working. This is also why the cap below LOGS what it drops instead of silently truncating.
#
# ── THE TWO NON-NEGOTIABLE PROPERTIES ────────────────────────────────────────────────────────────
#   1. 🔴 IDEMPOTENT BY TITLE. Every report's title starts with `STALLED #<n> · <class>` and that prefix
#      is matched against the live board BEFORE filing. One open report per (issue, class), however many
#      cycles the stall survives. Without this it is a self-amplifying storm — the CI-budget-storm
#      failure in a new costume. The check reads $BOARD, NOT the search API: the search index lags by
#      seconds-to-minutes and a lagging idempotence check is how you file the same issue twice.
#   2. NO STATE FILE (`:40` — "the fleet's architecture"). Every age above is derived from the board's
#      own timestamps: `parent.closedAt`, the ▶/✔ comment's `createdAt`, the issue's `createdAt`.
#
# WHICH CLASS each shape gets is pinned by `_infra/tests/sweep-announcer-classes.sh` (#4828) — synthetic
# boards through the jq program EXTRACTED FROM THIS FILE, so the test cannot pass against a stale copy.
# It is a gate (guard.yml `sweep-announcer`) because the wrong class prints the wrong REMEDY, and two of
# these remedies instruct the reader to write a false ✘ onto work that is not failing.
#
# ── 🔴 NO REPORT BODY MAY CONTAIN A GITHUB CLOSING KEYWORD FOLLOWED BY #$AN ──────────────────────
# Every remedy below says "close it" and every one of them used to say it as the literal `Close #$AN.`
# That is a defect with a one-hop fuse, and it went off on 2026-08-09: the PR clearing #4828 quoted the
# tombstone remedy VERBATIM — in a blockquote, in order to REFUTE it — and GitHub parsed `close #4805`
# out of the PR body without caring about the quoting. `closingIssuesReferences` resolved to {4828, 4805}
# and the merge closed #4805, the exact outcome the PR existed to prevent. It had to be reopened by hand.
# Quoting the report is not a mistake a reader makes; it is what a report is FOR. So the report must not
# hand them a live keyword: say "close it" and put the number in a command (`gh issue close $AN`), which
# is unambiguous to a human and inert to GitHub. Pinned by `_infra/tests/sweep-announcer-classes.sh`.
#
# ── WHY THE REPORTS PARENT TO A STANDING BUCKET ($ANNOUNCE_PARENT) ───────────────────────────────
# `file-issue.sh --parent` is a hard error if missing (#2615), and the stalled issue's OWN parent cannot
# be used: for parent-closed it is CLOSED by definition, so the report would be born permanently
# undispatchable — the very defect it exists to report. So all reports land in one bucket Feature, which
# carries a HOLD_LABELS label so nothing ever dispatches the bucket itself. If that bucket is not OPEN on
# this cycle's board the announcer says so LOUDLY and files nothing: a report born parent-closed is
# silence with extra steps.
ANNOUNCED=0; ANNOUNCE_HELD=0; ANNOUNCE_CAP_SAID=0; ANNOUNCE_REAPED=0
if [ "$ANNOUNCE" = 1 ]; then

 # ══ THE ANNOUNCEMENT REAPER — a report outlives its own cause, and then costs a dispatch (#5556) ══
 #
 # The announcer above is idempotent (one open report per issue+class) but it has no way to RETRACT.
 # A report is an ordinary board issue in lane `bravo`/`charlie`/…, so once its cause clears it does not
 # go quiet — it gets DISPATCHED, and a master spends a run reading a stall that no longer exists.
 # Measured on 2026-08-14: reports #5556 / #5558 / #5560 were filed at 17:59:31–17:59:55Z for blockers
 # #5526 / #5527 / #5528, and `verify-blocker-crossrepo-sweep.sh` closed all three subjects at
 # 18:03:11Z — 3.5 minutes later. Three dispatches, three masters, zero remaining work. Doctrine:
 # *"a status nobody derives is a label that stopped moving."* The announcer derives the stall every
 # cycle; this is the half that derives its ABSENCE.
 #
 # ── IT REAPS ONLY ON A POSITIVE READ, NEVER ON AN ABSENCE ────────────────────────────────────────
 # The tempting rule is "the subject is not in this cycle's stall set → reap". That is an ABSENCE, and
 # an absence here has the blast radius of every open report at once: one partial board read, one API
 # blip, one changed query and the sweeper mass-closes a channel the operator is supposed to trust. So each
 # arm below is a fact READ, and the report's own Acceptance is what the two arms are:
 #   1. the subject issue is CLOSED   — `gh api repos/<subject-repo>/issues/<n> --jq .state` says so,
 #      live, this cycle. Not "missing from $BOARD": $BOARD holds OPEN issues, so absence from it is
 #      equally consistent with a filtered query.
 #   2. the subject is DISPATCHABLE   — it is in THIS cycle's `$CANDIDATES`, the same set the loop
 #      above dispatches from. That is the other half of the Acceptance verbatim, and it covers the
 #      re-parent remedy, where the subject stays open and simply stops being stuck.
 # Anything else — state unreadable, subject still open and still not a candidate, title unparseable —
 # leaves the report open. A report that outlives its cause by a cycle costs one dispatch; a reaper
 # that closes live reports costs the channel.
 #
 # A report currently IN FLIGHT is never reaped: a master is on it and its own PR closes it. Reaping
 # under a running master would have the runner's ✔ land on a closed issue and look like the #4800 shape.
 if [ -s "$BOARD" ]; then
  while read -r RLINE; do
    [ -n "$RLINE" ] || continue
    RN="$(printf '%s' "$RLINE" | jq -r '.n' 2>/dev/null)"
    case "$RN" in ''|*[!0-9]*) continue ;; esac
    RREPO="$(printf '%s' "$RLINE" | jq -r '.repo' 2>/dev/null)"
    case "$RREPO" in ''|null) RREPO="$REPO" ;; esac
    case " $LIVE_ISSUES " in *" $RN "*) continue ;; esac          # a master is on it; its PR closes it
    if ! RSUBJ="$(announce_subject_of "$(printf '%s' "$RLINE" | jq -r '.title' 2>/dev/null)")"; then
      log "  · report #$RN — title does not parse to a subject, left open (deliberate: see announce_subject_of)"
      continue
    fi
    RSREPO="${RSUBJ%% *}"; RSN="${RSUBJ##* }"
    RWHY=""
    RSTATE="$(gh api "repos/$RSREPO/issues/$RSN" --jq '.state' 2>/dev/null || true)"
    if [ "$RSTATE" = "closed" ]; then
      RWHY="its subject \`$RSREPO#$RSN\` is no longer open — \`gh api repos/$RSREPO/issues/$RSN --jq .state\` returned \`closed\` on this cycle"
    elif printf '%s\n' "$CANDIDATES" | jq -e --argjson n "$RSN" --arg r "$RSREPO" \
           'select(.n == $n and ((.repo // "") == $r))' >/dev/null 2>&1; then
      RWHY="its subject \`$RSREPO#$RSN\` is DISPATCHABLE again — it is in this cycle's candidate set, which is the same list the sweep dispatches from"
    else
      continue                                                     # still stuck, or unreadable: leave it
    fi
    if [ "$ANNOUNCE_REAPED" -ge "$ANNOUNCE_MAX_PER_CYCLE" ]; then
      log "  · reap cap reached ($ANNOUNCE_MAX_PER_CYCLE/cycle) — the rest wait for the next cycle, starting with report #$RN"
      break
    fi
    if [ "$APPLY" != 1 ]; then
      log "  ☑ would reap report #$RN — $RWHY"; ANNOUNCE_REAPED=$((ANNOUNCE_REAPED+1)); continue
    fi
    # 🔴 No GitHub closing keyword adjacent to a reference anywhere in this body — same fuse as the
    # report bodies below (#4828, where a quoted remedy closed the issue it was refuting).
    if gh issue comment "$RN" --repo "$RREPO" </dev/null --body "☑ **Reaped by the sweeper — the stall this report announced is gone.**

$RWHY.

Nothing was worked and nothing was dropped: this report was a pointer at a one-way door, and the door
is open. The disposition is on the subject itself, which is where it belongs — read
\`gh api repos/$RSREPO/issues/$RSN/comments --jq '.[-3:][].body'\` for who cleared it and how.

If the stall is somehow still real, the sweep re-derives it from the board every 5 minutes and will
file a fresh report. That is the mechanism working, not a lost signal.

— \`_infra/scripts/sweep-dispatch.sh\`, the announcement reaper (#5556)" >/dev/null 2>&1 \
       && gh issue close "$RN" --repo "$RREPO" --reason completed >/dev/null 2>&1; then
      log "  ☑ reaped report #$RN — $RWHY"
      ANNOUNCE_REAPED=$((ANNOUNCE_REAPED+1))
    else
      log "  ✘ reap FAILED for report #$RN (left open) — $RWHY"
    fi
  done <<< "$(jq -c --arg prefix "$ANNOUNCE_PREFIX" \
               '.[] | select(.title | startswith($prefix)) | {n: .number, title: .title, repo: (.repo // null)}' \
               "$BOARD" 2>/dev/null)"
 fi

 if [ "$(jq --argjson p "$ANNOUNCE_PARENT" '[.[] | select(.number == $p)] | length' "$BOARD" 2>/dev/null || echo 0)" -eq 0 ]; then
  log "  ⚠ ANNOUNCER OFF — the stall bucket #$ANNOUNCE_PARENT is not an OPEN issue on this board."
  log "    Nothing was announced. Re-open it, or point SWEEP_ANNOUNCE_PARENT at a live Feature."
 else
  # Who is depended ON, and by whom — computed from the same page, so the dead-lane class costs no call.
  DEPENDED="$(jq -c '[.[] | .blockedBy.nodes[]?.number] | unique' "$BOARD" 2>/dev/null)"
  DEPS_OF="$(jq -c '[.[] | . as $x | .blockedBy.nodes[]? | {n: $x.number, dep: .number}]' "$BOARD" 2>/dev/null)"
  # LIVE_ISSUES is the same probe predicate 5 uses. It is the STRONG half of the run-vanished test.
  LIVE_ARR="$(printf '%s\n' $LIVE_ISSUES | jq -R 'select(test("^[0-9]+$")) | tonumber' 2>/dev/null | jq -s -c 'unique' 2>/dev/null)"
  # ── VBLOCK — every OPEN, dispatchable VERIFY blocker, keyed by the parent Feature it hangs under ──
  # #7371. A VERIFY that reopens an already-merged task does not only reopen it: `verify-verdict.sh`
  # files ONE BLOCKER SUB-ISSUE PER FAILING CRITERION under the SAME parent Feature first (:769,
  # `BLOCKER — VERIFY #<v> found a FAILING criterion: …`; :550 for the NO-VERDICT shape). Those
  # blockers ARE the queued healing work — they carry a lane, they dispatch, and their PRs are what
  # makes the reopened task closable again. The reopened task itself is a RECEIPT of the failing
  # verification, not work anybody is meant to pick up.
  # So while one of them is open, the `board-terminal-but-reopened` premise below — "no selector in
  # the fleet can see live work" — is FALSE, and the report is noise. Once they all close and the task
  # is still open at a terminal Status, it IS stranded and the next cycle announces it correctly. The
  # predicate delays a true report; it cannot suppress one.
  # The undispatchable-title filter is the same leading-tag-run test the selector uses below: a
  # the operator-gated blocker is not queued work and must not silence a sibling's report indefinitely.
  VBLOCK="$(jq -c '[.[]
      | select((.title // "") | contains("BLOCKER — VERIFY #"))
      | select(.parent.number != null)
      | select((((.title | [match("^\\s*(\\[[^\\]]*\\]\\s*)+").string] | first // ""))
                | test("DO NOT DISPATCH|INTERACTIVE")) | not)
      | {p: .parent.number, n: .number}]' "$BOARD" 2>/dev/null)"
  # Every --argjson below MUST be a well-formed array: a `|| echo '[]'` fallback can APPEND to partial
  # output and produce two JSON documents, which argjson rejects and which reads here as a dead announcer.
  for _v in DEPENDED DEPS_OF LIVE_ARR VBLOCK; do
    case "${!_v}" in \[*\]) ;; *) printf -v "$_v" '%s' '[]' ;; esac
  done
  STALLS="$(jq -c \
    --argjson now "$(date +%s)" --argjson hold "$HOLD_LABELS" --arg prefix "$ANNOUNCE_PREFIX" \
    --argjson announce_parent "$ANNOUNCE_PARENT" --argjson live "$LIVE_ARR" \
    --argjson depended "$DEPENDED" --argjson deps_of "$DEPS_OF" \
    --argjson vblock "$VBLOCK" \
    --arg repo "$REPO" \
    --argjson t_short "$ANNOUNCE_STALL_MIN" --argjson t_run "$ANNOUNCE_RUN_MIN" \
    --argjson t_deadlane "$ANNOUNCE_DEADLANE_MIN" \
    --argjson t_rollup "$ANNOUNCE_ROLLUP_MIN" '
    def fields: [.projectItems.nodes[]?.fieldValues.nodes[]?];
    def field($n): [fields[] | select(.field.name==$n) | .name] | first;
    def marks: [.comments.nodes[] | select((.author.login // "") != "gh-account1") | {createdAt, body: (.body | sub("^[ \\t]*#{1,6}[ \\t]+";""))} | select(.body | test("^\\s*(▶|✔|✘|⚠|⛔|🪫|⏹|🔓)"))];
  # strip_headings — remove markdown heading prefix (1-6 # symbols with whitespace) so heading-form
  # markers like `## ⛔ VERIFY #5710` are recognized the same as bare-form `⛔ blocked — …`. Added in
  # #5765 to fix the ⏸/⛔ latches that read .comments.nodes directly; the `marks` definition above was
  # fixed by #5650 but these latches were deliberately left unchanged.
  def strip_headings: sub("^[ \t]*#{1,6}[ \t]+"; "");
    # #4392 — the announcer MUST use the same marker set as predicate 6, or it files reports about holds
    # that no longer exist. A ✔ overruled by a later reopen is not a tombstone: nothing is stuck, the
    # issue is simply dispatchable again, and a report saying otherwise is the "correct holds" noise the
    # never-announce list above exists to prevent.
    def reopened_at: (.timelineItems.nodes[0].createdAt // null);
    def live_marks: reopened_at as $ro | [marks[] | select($ro == null or (.createdAt > $ro))];
    def open_subissues: ((.subIssuesSummary.total // 0) - (.subIssuesSummary.completed // 0));
    def is_parked:
      (([.comments.nodes[] | select(.body | strip_headings | test("^\\s*⏸"))] | length) > 0)
      and (([.comments.nodes | to_entries[] | select(.value.body | test("(^|\n)[ \t]*UNPARK\\b")) | .key] | last // -1)
           <= ([.comments.nodes | to_entries[] | select(.value.body | strip_headings | test("^\\s*⏸"))  | .key] | last // -1));
    def age($t): (($now - ($t | fromdateiso8601)) / 60 | floor);
    .[]
    # NOTE: single-quoted shell string — no apostrophes in these comments.
    # Never announce an announcement, and never announce the bucket that holds them.
    | select(.title | startswith($prefix) | not)
    | select(.number != $announce_parent)
    # The never-announce list. These are correct holds; reporting them is how a channel gets ignored.
    | select([.labels.nodes[].name] | any(. as $x | ($hold | index($x)) != null) | not)
    | select([.labels.nodes[].name] | any(startswith("workflow:") or startswith("stuck:")) | not)
    # #4826 — the same leading-tag-run definition the dispatcher uses. One file must not hold two
    # readings of one convention, and the substring form silenced the announcer on #4480/#4482, which are
    # ordinary work whose SUBJECT is this marker. They are announceable again.
    | select(((.title | [match("^\\s*(\\[[^\\]]*\\]\\s*)+").string] | first // "")
              | test("DO NOT DISPATCH|INTERACTIVE")) | not)
    | select(.title | test("BUCKET|DO NOT CLOSE") | not)
    | select(open_subissues == 0)
    | select([.blockedBy.nodes[]? | select(.state == "OPEN")] | length == 0)
    | select(is_parked | not)
    | (.number) as $num
    | ((.parent.number // -1)) as $pnum
    | (field("Status") // "") as $st
    | (field("Lane") // "") as $lane
    | ((live_marks | last) // null) as $lm
    # #7371 — "a VERIFY reopened this and its own blockers are still open". Bound ONCE and read by BOTH
    # terminal-Status arms below, because suppressing only the first one is worse than not suppressing:
    # the item then falls through to `board-terminal-but-open`, whose remedy is CLOSE IT — the #4800
    # failure the reopen exists to prevent. Measured on the fixture pair for this issue: guarding only
    # the reopened arm turned report #7371 into a close-it report on the same subject.
    | (([$vblock[] | select(.p == $pnum and .n != $num)] | length) > 0) as $vblocked
    # ONE class per issue, first match wins: two reports about one issue is two things to close.
    # 🔴 parent-closed is the ONLY arm whose age is measured on something OTHER than this issue —
    # every other one reads the createdAt, the updatedAt, or a marker OF THE ISSUE ITSELF. So it alone
    # can announce an issue that is SECONDS old and in active flight, because the clock it reads
    # belongs to the parent (#5497). Measured: product-a 317 was filed 27 minutes AFTER its parent
    # 5358 closed and was worked the whole time — PR 322 merged, the Architect reopened it with a
    # measurement, a second run started — yet the report fired at 15:16:18Z on a 56-minute stall,
    # 3 minutes before PR 327 shipped the work and closed it. The last board activity on the issue at
    # that moment was 5 minutes old. `age(.updatedAt) >= $t_short` is the missing half: STALLED is a
    # claim about THIS issue, so the board must have been silent on it for the threshold too. Anything
    # that touches it — a ▶, a close-out, a Status write, a human comment — is someone handling it.
    | (if   ($st == "Todo") and (.parent != null) and (.parent.state == "CLOSED")
            and (.parent.closedAt != null) and (age(.parent.closedAt) >= $t_short)
            and (age(.updatedAt) >= $t_short)
       then {class: "parent-closed", age: age(.parent.closedAt), ref: .parent.number,
             detail: "its parent Feature #\(.parent.number) has been CLOSED for \(age(.parent.closedAt)) minutes"}
       elif ($st == "Doing") and ($lm != null) and ($lm.body | test("^\\s*▶"))
            and (age($lm.createdAt) >= $t_run) and (($live | index($num)) == null)
       then {class: "run-vanished", age: age($lm.createdAt), ref: 0,
             detail: "its last marker is a ▶ from \(age($lm.createdAt)) minutes ago and NO task-\($num) unit is live on any box"}
       # #4395 — A ROLLUP ATTESTATION IS NOT A TOMBSTONE. It must be tested BEFORE the tombstone arm:
       # both match `^✔`, first-match-wins, and only one of them is a defect. See the block above the
       # class list for the full reasoning and the measurement behind $t_rollup.
       # #4828 — and the arm now matches ANY ✔ on a PARENT, not the literal `✔ ROLLUP VERIFIED`. Keying
       # on the wording assumed the runner writes every ✔ a Feature ever carries; it does not. A VERIFY
       # sub-issue reports its verdict onto its parent, and the one on #4805 read
       # `✔ VERIFIED (not passed) — … **Feature stays OPEN.**` — a comment that says in its own first
       # line that the Feature is not finished, classified as a gravestone 16 minutes later. Parent-ness
       # is the fact that makes a ✔ harmless: predicate 6 terminality only strands work that would
       # otherwise be DISPATCHED, and a Feature never is. attested picks the remedy, not the class.
       elif (($st == "Todo") or ($st == "Doing")) and ($lm != null)
            and ($lm.body | test("^\\s*✔")) and ((.subIssuesSummary.total // 0) > 0)
       then (if age($lm.createdAt) >= $t_rollup
             then {class: "rollup-unclosed", age: age($lm.createdAt), ref: 0,
                   attested: ($lm.body | test("^\\s*✔\\s*ROLLUP VERIFIED")),
                   detail: "it is an n/n Feature whose last marker is a ✔ from \(age($lm.createdAt)) minutes ago, and `stuck-pr-sweep.yml` — the only thing that closes a parent — has not closed it"}
             else empty end)
       # LEAF ONLY (#4828). A ✔ on a parent is the arm above; this one is about an issue a master would
       # otherwise pick up, which is the only place the one-way-door harm is real.
       elif (($st == "Todo") or ($st == "Doing")) and ($lm != null) and ($lm.body | test("^\\s*✔"))
            and ((.subIssuesSummary.total // 0) == 0)
            and (age($lm.createdAt) >= $t_short)
       then {class: "tombstone", age: age($lm.createdAt), ref: 0,
             detail: "a ✔ success marker from \(age($lm.createdAt)) minutes ago is the last word on an issue that is still OPEN"}
       # #9295 — the clock is "runnable since", not "filed since": the later of createdAt and the last
       # blocker closing (ISO-8601 Z strings sort chronologically). An OPEN blocker means not runnable.
       elif ($st == "Todo") and ($lane == "agent")
            and (($depended | index($num)) != null)
            and ([.blockedBy.nodes[]? | select(.state == "OPEN")] | length == 0)
            and (age([.createdAt, (.blockedBy.nodes[]? | .closedAt // empty)] | max) >= $t_deadlane)
       then {class: "dead-lane", age: age([.createdAt, (.blockedBy.nodes[]? | .closedAt // empty)] | max), ref: 0,
             detail: "lane `\($lane)` is dispatched by no box, and \([$deps_of[] | select(.dep == $num) | "#\(.n)"] | join(", ")) is blocked on it"}
       # #5545 — REOPENED FIRST. A terminal Status and an OPEN state disagree; this arm is about WHICH of
       # the two is the stale one, and only a reopen can answer that. When the issue was REOPENED and no
       # `✔` has landed since (`live_marks`, the #4392 rule), the reopen is the newest fact on the record:
       # the work is unfinished and the FIELD is what did not follow. The class below prescribes closing
       # it, and closing a reopened issue re-closes work a verifier just proved unfinished — the exact
       # outcome #4800 exists to prevent. Measured 2026-08-14: VERIFY #257 reopened product-a #263 and
       # #301 at 17:37:44Z/17:38:00Z against failing live criteria, board Status stayed "Done" (nothing
       # writes the inverse — `board-reconcile.yml:344` has `CLOSED → Done` and no `OPEN → Todo`, and it
       # sweeps `knowledge` ONLY, so no product-a item is reconciled at all), and 17 minutes later this
       # announcer filed knowledge #5545 and #5546 telling two masters to run `gh issue close`.
       # Both arms share ONE threshold deliberately: a `reopened` case under the threshold must fall
       # through to NOTHING, never to the arm below, or the guard leaks the destructive remedy back in.
       # #5587 — SPLIT BY PARENT-NESS, the same distinction #4828 drew on the ✔ arm above (leaf ->
       # tombstone, parent -> rollup-unclosed). "The reopen is the live fact, so put the Status back to
       # Todo" is a claim about DISPATCHABLE work: on a leaf that is exactly right, and on a parent it
       # answers the wrong question. The observed case: knowledge #5466 was closed at 14:48:32Z, reopened
       # at 17:25:58Z by the #4179 rule because its VERIFY child #5467 was still open, and that child then
       # closed PASS at 17:54Z — leaving a finished, PASS-verified Feature at 2/2 that this class told a
       # master to set back to Todo.
       # 🔴 And Todo on an n/n parent is NOT inert. MEASURED 2026-08-14 by feeding a synthetic n/n Feature
       # (total 2 / completed 2, Status Todo, lane bravo, no open deps) through the EXPLAIN selector in
       # this same file: it prints `✓ DISPATCHABLE`. There is no is_parent test in `checks` — status,
       # lane, parent-state, no_open_subissues, deps, labels, assignees, markers, and an n/n parent passes
       # every one. So the leaf remedy does not merely fail to help a finished Feature, it queues a master
       # onto one: a Feature has no child work left to do and no PR of its own to write.
       # For a parent the reopen leaves open whether the Feature is FINISHED, not whether it is queued —
       # that is the rollup question, and the rollup remedy.
       # The selector above already guarantees open_subissues == 0, so total > 0 here means n/n exactly.
       # #5604 — CONFIRMED ON A REAL BOARD ITEM, not only the synthetic one. product-a 256 (17/17,
       # Status Done, reopened 18:02:30Z by the #4179 rule) is the second occurrence of this exact shape
       # inside one hour. Both halves were re-measured against the LIVE board rather than a fixture:
       # patching that one item Status to Todo in the fetched board and re-running `--explain --issue 256`
       # printed `✓ DISPATCHABLE`, and the shipped classifier above emitted `parent: true` with the n/n
       # detail for it. A synthetic item can be wrong about the shape; the live item cannot.
       # 🔴 A report already on the board still carries whatever remedy was current when it was WRITTEN.
       # #5604 was filed 18:21:25Z, six minutes before the fix above merged, so its body prescribes the
       # leaf remedy for a parent — Status -> Todo, do not close. A reader who follows a pre-fix report
       # verbatim gets back the defect this arm just removed. Re-derive the class from the shipped file
       # (`--explain`, or the STALLS record) before acting on any report whose body predates it.
       # 🔴 #6420 — "Blocked" IS NOT A TERMINAL STATUS, and both arms below used to treat it as one.
       # Done and Review mean the work FINISHED, so an open state is a missed close and closing it is
       # right. Blocked means the exact opposite: `task-runner.sh:1297` writes it ONLY when the run
       # shipped nothing and declared a blocker, alongside a ⛔ comment carrying an explicit release
       # protocol (comment UNBLOCK in all caps). The class premise below is therefore false for it twice:
       #   1. "The Status says the work is done" — it says the work could not even start.
       #   2. "no selector in the fleet can see it" — `board-reconcile.yml:385` reads EXACTLY
       #      `state === OPEN && Status === Blocked` and, absent a `blocked:*` label, sets it back to Todo
       #      (knowledge#4312). The ⛔ latch then holds it undispatchable but VISIBLE: `--explain` prints
       #      `✗ REJECTED: is-blocked` (predicate 5/6, this file ~line 896). Nothing is stranded.
       # And the announcer ALWAYS won that race: it fires at $ANNOUNCE_STALL_MIN=15 minutes while the
       # board-reconcile full sweep is a 30-minute cron (`11,41 * * * *`), so EVERY ⛔ the fleet ever
       # wrote got announced as a stall, with a destructive remedy, before the healer next ticked.
       # MEASURED, and it already cost us: #6357 — solve the press-and-hold human-verification, a
       # genuine the operator-gate (item 2, a finger on glass) — went Blocked at 2026-08-19T15:05:37Z, was
       # announced by this class as #6366 at 15:25:44Z, and was closed `state_reason: completed` at
       # 15:32:23Z. The closing comment says, in its own second paragraph: "This does not resolve the
       # underlying block: the press-and-hold CAPTCHA still needs the operator at a real device." A live
       # human-only task was stamped COMPLETED by a master who simultaneously recorded that it was not.
       # The same report was filed against #6417 (#6420), where closing it would additionally have let
       # Feature #6410 read n/n against an acceptance criterion its own verifier had shown unmet.
       # Blocked therefore belongs to NEITHER arm. It is a releasable latch with two documented exits
       # (the `blocked:*` label rule above, and UNBLOCK), so it is never silently stuck and needs no
       # report at all — announcing a self-healing transient with an irreversible remedy is strictly
       # worse than silence.
       # 🔴 #7371 — AND NOT WHILE THE VERIFY THAT REOPENED IT STILL HAS OPEN BLOCKERS. Measured, on the
       # only leaf-shaped report this class has ever filed: VERIFY #7319 filed blockers #7360 (14:34:28Z)
       # and #7361 (14:34:37Z) under parent #7313, then reopened its sibling task #7316 (14:35:14Z).
       # THIS SWEEP dispatched both blockers to charlie at 14:38:26Z — and then, at 14:53:41Z, announced
       # #7316 as stalled with the sentence "no selector in the fleet can see live work" while two of its
       # own runs were executing exactly that work. Both PRs merged at 14:56 and #7316 was re-closed at
       # 14:59:02Z, six minutes after the report, by a master who never read it. Same shape as the two
       # defects already fixed in this arm (#5604 parent, #6420 Blocked): the premise "nothing can see
       # this" was false because the work was visible under a DIFFERENT number.
       # `$vblock` above is the sibling set. `.n != $num` keeps a blocker that is itself reopened
       # announceable — it must not silence its own report.
       elif ($st == "Done" or $st == "Review")
            and (reopened_at != null)
            and ($lm == null or ($lm.body | test("^\\s*✔") | not))
            and (age(.updatedAt) >= $t_short)
            and ($vblocked | not)
       then ((((.subIssuesSummary.total // 0) > 0)) as $isparent
             | {class: "board-terminal-but-reopened", age: age(.updatedAt), ref: 0,
                parent: $isparent,
                detail: (if $isparent
                         then "it is a parent Feature at n/n (\(.subIssuesSummary.completed // 0)/\(.subIssuesSummary.total // 0)) that was REOPENED \(age(reopened_at)) minutes ago with no ✔ since, and its board Status is still \"\($st)\" — on a PARENT the reopen does not mean queued work, it leaves open whether the Feature is FINISHED, and nothing has answered that"
                         else "it was REOPENED \(age(reopened_at)) minutes ago and no ✔ has landed since, but its board Status is still \"\($st)\" — the reopen is the live fact and the FIELD is the stale one, so no selector in the fleet can see live work (sweeper reads Todo, reaper reads Doing)" end)})
       # 🔴 AND NOT A REOPEN THE ARM ABOVE JUST DECLINED (#7371). The remedy in this arm is
       # `gh issue close`, and on a task a VERIFY reopened that is the #4800 failure by definition.
       # The arm above already keeps a reopen out of here by matching FIRST; the `$vblocked` predicate
       # opens a hole in that, so the same predicate has to close it — guarding only the arm above
       # turned report #7371 into a CLOSE-IT report on the same subject, measured on its fixture.
       # The excluded set is the PAIR (reopened AND its VERIFY blockers still open), and that
       # deliberately covers the case where a ✔ has landed since the reopen: the arm above declines
       # that one on the ✔, and it arrives here with the verifier still holding live blockers on the
       # parent, which is the same premature close in a later costume. It goes quiet instead. Both
       # halves come back the moment the last blocker closes.
       elif ($st == "Done" or $st == "Review")
            and (age(.updatedAt) >= $t_short)
            and (($vblocked and (reopened_at != null)) | not)
       then {class: "board-terminal-but-open", age: age(.updatedAt), ref: 0,
             detail: "its board Status is \"\($st)\" but GitHub still reports it OPEN — no selector in the fleet can see it (sweeper reads Todo, reaper reads Doing, every announcer class reads one of those)"}
       else empty end) as $c
    # 🔴 `.repo // $repo` — NOT `$repo` (2026-08-14, #5497). Identical defect to the one fixed in the
    # CANDIDATES selector the same day, in the other half of this file: in project mode the flatten
    # stamps each item with its OWN repo and the global `$repo` threw that away, so EVERY report was
    # written as though its subject lived in knowledge. Measured: report #5497 announced
    # product-a #317 as `STALLED #example-org/kb:317`, and every remedy command in its body
    # pointed at knowledge #317 — a DIFFERENT, unrelated, already-closed issue (the opengrep SAST one).
    # A master following that report verbatim acts on the wrong issue in the wrong repo, and the
    # idempotence key collides with a genuine knowledge stall of the same number.
    # `// $repo` keeps repo mode working, where items carry no repo of their own.
    | {n: $num, class: $c.class, detail: $c.detail, age: $c.age, ref: $c.ref,
       attested: ($c.attested // false), parent: ($c.parent // false), lane: $lane,
       prio: (field("Priority") // "P2"), port: (field("Portfolio") // ""), status: $st,
       title: .title, repo: (.repo // $repo)}
    ' "$BOARD" 2>/dev/null)"
  [ -n "$ONLY_ISSUE" ] && STALLS="$(printf '%s\n' "$STALLS" | jq -c --argjson i "$ONLY_ISSUE" 'select(.n == $i)' 2>/dev/null)"

  while read -r S; do
    [ -n "$S" ] || continue
    AN="$(printf '%s' "$S" | jq -r '.n' 2>/dev/null)"
    case "$AN" in ''|*[!0-9]*) continue ;; esac   # a malformed line is skipped, never filed on
    ACLASS="$(printf '%s' "$S" | jq -r '.class')"
    ADETAIL="$(printf '%s' "$S" | jq -r '.detail')"
    AAGE="$(printf '%s' "$S" | jq -r '.age')"
    AREF="$(printf '%s' "$S" | jq -r '.ref')"
    AATTESTED="$(printf '%s' "$S" | jq -r '.attested')"
    APARENT="$(printf '%s' "$S" | jq -r '.parent')"
    ATITLE="$(printf '%s' "$S" | jq -r '.title')"
    ASTATUS="$(printf '%s' "$S" | jq -r '.status')"
    AREPO="$(printf '%s' "$S" | jq -r '.repo')"
    # 🔴 THE REPORT IS FILED IN $REPO; ITS SUBJECT OFTEN IS NOT (#5497). The board spans four repos, so a
    # bare `#317` in a report body renders as knowledge#317 and `gh issue close 317` closes knowledge#317
    # — a different issue that exists. $AQ is the reference that resolves from inside the report: bare
    # when the subject is a $REPO issue, `owner/repo#n` when it is not (GitHub links that form, and it is
    # equally inert to closing-keyword parsing). Every gh command below carries `--repo $AREPO` instead,
    # which is unconditionally correct and needs no reader judgement.
    if [ "$AREPO" = "$REPO" ]; then AQ="#$AN"; else AQ="$AREPO#$AN"; fi

    # ── Property 1: idempotent by title, against the live board (never the lagging search index). ──
    AKEY="$ANNOUNCE_PREFIX$AREPO:$AN · $ACLASS"
    if jq -e --arg k "$AKEY" 'any(.[]; .title | startswith($k))' "$BOARD" >/dev/null 2>&1; then
      log "  · $AQ already announced ($ACLASS) — not filing a second"
      continue
    fi

    # ── Property 1b: the SUBJECT must still be open, re-read LIVE (#5580) ────────────────────────
    # Same reasoning as Property 1 one block up, applied to the other stale input. Every age above is
    # derived from $BOARD, and $BOARD is a snapshot taken at the top of this cycle — so a stall that was
    # real when the page was fetched can be disposed of before the report is written, and the report is
    # then born answering a question nobody is asking. The title check cannot catch it: there is no
    # report to collide with.
    #
    # MEASURED, not precautionary (2026-08-14): PR #5573 closed+unlinked knowledge #5526-#5529 in one
    # action at 18:03Z. Report #5580 was filed at 18:08:40Z about #5529 — CLOSED at 18:03:19Z, five
    # minutes and twenty-one seconds earlier — and cost a dispatched run whose entire finding was
    # "already closed before you asked". Its two siblings are deliberately NOT evidence for this guard:
    # #5558 (17:59:43Z) and #5560 (17:59:55Z) were filed BEFORE their subjects closed at 18:03:14Z /
    # 18:03:16Z, so they were correct at filing and this check would not have fired on either. One
    # preventable report, one API call: paid only for stalls that survived the threshold and are not
    # already announced (observed: 0-1 per cycle).
    #
    # An UNREADABLE state is not a closed state: on any API failure ASTATE is empty and we fall through
    # and file. A detector that cannot check must not report the reassuring answer.
    ASTATE="$(gh api "repos/$AREPO/issues/$AN" --jq .state 2>/dev/null)"
    if [ "$ASTATE" = "closed" ]; then
      log "  · $AQ closed since this cycle's board snapshot ($ACLASS) — stall self-disposed, not filing"
      continue
    fi

    # ── Property 1c: rollup-unclosed is clocked from when the Feature REACHED n/n (#6233) ────────
    # The arm above reads `age($lm.createdAt)` — the age of the ✔ — because that is the only timestamp
    # the cheap board query carries. But `stuck-pr-sweep.yml` CANNOT close a parent with an open child:
    # its invariant guard refuses first (`stuck-pr-sweep.yml:245`). So the ✔'s age answers a question
    # nobody asked. The clock that matters is the moment the LAST child closed — before that, the closer
    # is not late, it is correctly refusing.
    #
    # MEASURED, not precautionary (2026-08-17, report #6233 about Feature #5865). Its ✔ was written
    # 2026-08-16T01:00:08Z. Six minutes later its own VERIFY recorded FAIL and blocker #6229 was filed,
    # holding it off n/n for the next 23 hours — the closer refusing, exactly as designed. #6229 closed
    # at 00:07:33Z; the report fired at 00:12:15Z, **4m42s later**, announcing a "1392 minute" stall
    # against a closer whose last run (23:58:41Z) predated n/n by nine minutes. It cost a dispatched run.
    #
    # 🔴 `.updatedAt` is NOT the missing half here, unlike the parent-closed arm at :1518. Measured on
    # the same subject: child #6229 closed at 00:07:33Z and #5865's own `updated_at` stayed at
    # 2026-08-16T23:41:31Z — a child closing does not touch its parent's timestamp, so an updatedAt
    # guard reads 31 minutes on a Feature that reached n/n 5 minutes ago.
    #
    # 🔴 AND THE CLOCK CANNOT COME FROM THE BOARD QUERY. `subIssues(first:20){nodes{closedAt}}` on the
    # 100-issue page costs 143 points against the 9 it costs today (measured 2026-08-17, back to back,
    # `rateLimit{cost nodeCount}` inline: 9/14000 → 143/223100; `first:100` exceeds the 500k node limit
    # outright). At a 5-minute cycle that is ~3400 of the 5000/hr budget, which is the same "per-issue
    # cost took core to 0/5000" failure the query header at :418 records. So it is paid HERE, per
    # candidate, after the threshold and the idempotence check — observed 0-1 per cycle, like 1b.
    #
    # Fail-open, for the 1b reason: an unreadable or truncated answer files the report. A silenced stall
    # is the failure this announcer exists to prevent. The one thing it will not do is announce a
    # Feature that is not n/n right now.
    if [ "$ACLASS" = "rollup-unclosed" ]; then
      ANNAT="$(gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){subIssues(first:100){totalCount nodes{state closedAt}}}}}' \
        -F o="${AREPO%%/*}" -F r="${AREPO#*/}" -F n="$AN" \
        --jq '.data.repository.issue.subIssues
              | if (.totalCount // 0) == 0 or (.totalCount > (.nodes | length)) then ""
                elif ([.nodes[] | select(.state != "CLOSED")] | length) > 0 then "OPEN-CHILD"
                else ([.nodes[].closedAt] | map(select(. != null)) | max // "") end' 2>/dev/null)"
      if [ "$ANNAT" = "OPEN-CHILD" ]; then
        log "  · $AQ has an OPEN child in the live re-read ($ACLASS) — not n/n, the closer is correctly refusing, not filing"
        continue
      fi
      if [ -n "$ANNAT" ]; then
        NNAGE=$(( ( $(date +%s) - $(date -u -d "$ANNAT" +%s 2>/dev/null || echo 0) ) / 60 ))
        if [ "$NNAGE" -ge 0 ] && [ "$NNAGE" -lt "$ANNOUNCE_ROLLUP_MIN" ]; then
          log "  · $AQ reached n/n only $NNAGE min ago (threshold $ANNOUNCE_ROLLUP_MIN) — the ✔ is older, the closer is not late, not filing"
          continue
        fi
        # The report quotes the honest clock, not the ✔'s age.
        [ "$NNAGE" -ge 0 ] && AAGE="$NNAGE" \
          && ADETAIL="it has been an n/n Feature since its last sub-issue closed $NNAGE minutes ago (its ✔ is older), and \`stuck-pr-sweep.yml\` — the only thing that closes a parent — has not closed it"
      fi
    fi

    # The storm bound. It says what it dropped: a silent truncation reads as "that was everything".
    if [ "$ANNOUNCED" -ge "$ANNOUNCE_MAX_PER_CYCLE" ]; then
      ANNOUNCE_HELD=$((ANNOUNCE_HELD+1))
      [ "$ANNOUNCE_CAP_SAID" = 1 ] || { log "  · announce cap reached ($ANNOUNCE_MAX_PER_CYCLE/cycle) — the rest wait for the next cycle, starting with $AQ ($ACLASS)"; ANNOUNCE_CAP_SAID=1; }
      continue
    fi

    # Lane: the stalled issue's own box when that box exists; otherwise spread deterministically rather
    # than piling every report onto one master. A report about a dead lane cannot inherit the dead lane.
    A_LANE="$(printf '%s' "$S" | jq -r '.lane')"
    case " $MASTERS " in
      *" $A_LANE "*) ;;
      *) MARR=($MASTERS); A_LANE="${MARR[$(( AN % ${#MARR[@]} ))]}" ;;
    esac
    A_PRIO="$(printf '%s' "$S" | jq -r '.prio')"
    case "$A_PRIO" in P0|P1|P2|P3) ;; *) A_PRIO=P2 ;; esac
    # 🔴 The `*)` arm WAS SILENT — an unmapped Portfolio display name filed the stall report under World
    # Infrastructure and reported success, so a live board option missing from this list was drift nothing
    # announced. It still falls back to `wi` (a report must be filed somewhere) but now SAYS so (#8301);
    # an issue with no Portfolio at all is the one quiet case, because that is not drift. A new
    # option — or a rename — gets its arm changed in the same change.
    # 🔴 THAT RULE WAS BROKEN ONCE ALREADY (#8301): the sixth option (`SF`, renamed `net` by PLAN-308) got
    # no arm, so every stall report about a net issue was filed under World Infrastructure. `net` and the
    # sixth, `Talent` (PLAN-345), are both explicit now; `Cleaning` (PLAN-377) got its arm with its option.
    # Six live options, six arms, `wi` named — RAW's arm went with its option when RAW folded into WI (#8996).
    case "$(printf '%s' "$S" | jq -r '.port')" in
      "PRODUCT Research")  A_PORT=product ;;
      GOVCON)          A_PORT=govcon ;;
      net)             A_PORT=net ;;
      Talent)          A_PORT=talent ;;
      Cleaning)        A_PORT=cleaning ;;
      "World Infrastructure"|""|null) A_PORT=wi ;;
      *)               A_PORT=wi
                       log "  ⚠ stall report for $AQ: Portfolio '$(printf '%s' "$S" | jq -r '.port')' has no arm in sweep-dispatch.sh — filed under wi. Add the arm." ;;
    esac

    # The disposition this report will be graded on. Class-agnostic by default — "dispatchable OR closed"
    # is the right pair for a stalled WORK issue. A class whose own `How to clear it` block prescribes a
    # different remedy overrides it in its arm below: an Acceptance that cannot be met by following the
    # body is a defect, and the master then has to either fudge a criterion or take a banned action
    # (#6680 — `rollup-unclosed` bans BOTH of the default pair, then asks for a third thing).
    A_ACCEPT="- $AQ is either dispatchable (\`--explain\` shows it \`✓ DISPATCHABLE\`) or deliberately closed/retitled with
  the reason stated ON $AQ.
- This report is closed, naming which disposition was taken."

    case "$ACLASS" in
      parent-closed)
        A_HEAD="its Feature is closed, so nothing will ever dispatch it"
        A_FIX="Dispose of $AQ deliberately — exactly one of:
- **close it** if the work is obsolete (that is a real answer, and the commonest one) — \`gh issue close $AN --repo $AREPO\`;
- **re-parent** it under a live Feature (\`<live-feature-repo>\` is the repo the NEW Feature lives in, usually \`$REPO\`) —
  \`gh api -X POST repos/<live-feature-repo>/issues/<live-feature>/sub_issues -F sub_issue_id=\$(gh api repos/$AREPO/issues/$AN --jq .id)\`;
- **reopen the parent Feature #$AREF** if it was closed while its children were still real work.

🔴 **Before reopening, check whether $AQ is HELD — and if it is, declare the hold as a dependency.**
A deliberate hold and \`parent-closed\` are indistinguishable from here, and both stop dispatch, so a child
held only by prose in its own title (\`… HELD until #N closes\`) has been resting on this rejection by
accident. Reopening the parent releases it into the very next sweep and a master is dispatched onto work
whose only correct move is to stop cleanly. Predicate 4 reads GitHub's native issue dependencies, which
hold it SILENTLY (\`has-open-deps\` is never announced) and release themselves the moment the blocker
closes — no label to remember, no poller:
\`\`\`bash
jq -n --argjson id \$(gh api repos/<blocker-repo>/issues/<blocker> --jq .id) '{issue_id:\$id}' \\
  | gh api -X POST repos/$AREPO/issues/$AN/dependencies/blocked_by --input -
\`\`\`
Measured on #6948 (2026-08-27): titled \`HELD until PLAN-230 F6 closes\`, blocked_by its own W2/W3/W4 —
all closed — so the reopen this report asked for would have dispatched it while #6852 was still open.

Predicate 3 rejects every sub-issue of a CLOSED Feature, so until one of those happens $AQ is permanently
undispatchable no matter what its Status says."
        A_THRESH="the stall had to survive \$ANNOUNCE_STALL_MIN=$ANNOUNCE_STALL_MIN minutes (the default, 15, is three consecutive 5-minute cycles). #4179 also posts a one-time advisory on the CLOSED PARENT the moment it closes; this fires only if that notice went unacted-on for three cycles." ;;
      run-vanished)
        A_HEAD="a run vanished mid-flight and its ✔/✘ is never coming"
        A_FIX="The run that posted that ▶ is gone: no \`task-$AN\` unit exists on any box, and \`task-runner.sh\`
posts its ✔/✘ from an exit trap — so no close-out will ever arrive. **Convert the vanished ▶ and re-queue:**
1. Post a \`✘\` (or \`⚠\`) close-out on $AQ naming what is actually on disk. Predicate 6 deliberately EXCLUDES
   \`✘\`, so this is what makes the issue dispatchable again; leaving a bare ▶ as the last marker does not.
2. Set Status back to \`Todo\` on the board.
The ▶ still counts against \`SWEEP_MAX_ATTEMPTS\`, so this cannot loop. If the work actually landed and only
the reporting died, close it (\`gh issue close $AN --repo $AREPO\`) instead. \`board-reconcile.yml:337\` refuses to heal this case on purpose."
        A_THRESH="the ▶ had to be \$ANNOUNCE_RUN_MIN=$ANNOUNCE_RUN_MIN minutes old AND no live unit. The unit probe is the real signal; the 2h only stops a genuinely long run being called dead by a probe that blinked." ;;
      tombstone)
        A_HEAD="a ✔ on an open issue is a gravestone"
        A_FIX="A \`✔\` means the run said it SHIPPED, and predicate 6 treats it as terminal — so $AQ is now
permanently undispatchable and anything chained behind it is held forever (#4181). Which remedy depends on
whether a merged PR exists:
- **A PR merged** → the run finished and simply never closed the issue. **Close it:** \`gh issue close $AN --repo $AREPO\`.
- **No merged PR** → the ✔ reported a success it did not achieve. Post a \`✘\`/\`⚠\` saying what is actually
  missing and set Status back to \`Todo\`, so the last marker stops being terminal.

Do NOT quietly delete the ✔ — the record of what the run claimed is the evidence.
\`sweep-dispatch.sh --explain | grep ✔-TOMBSTONE\` splits these two cases for the whole board."
        A_THRESH="the ✔ had to be \$ANNOUNCE_STALL_MIN=$ANNOUNCE_STALL_MIN minutes old (the default, 15, is three cycles), so a PR that merges seconds after its ✔ never trips it." ;;
      rollup-unclosed)
        if [ "$AATTESTED" = true ]; then
          A_HEAD="an attested n/n Feature the auto-closer never came back for"
          A_MARKER="carrying \`✔ ROLLUP VERIFIED\`. That marker is the attestation, not a close"
        else
          # #4828 — the same fact without the attestation. The ✔ on the Feature was written by something
          # other than the runner rollup (a VERIFY sub-issue reporting its verdict onto its parent is the
          # observed case), so there is NO per-criterion table to read and the first instruction below —
          # confirm the criteria yourself — is the whole job, not a formality.
          A_HEAD="an n/n Feature under an unattested ✔ that the auto-closer never came back for"
          A_MARKER="whose last marker is a \`✔\` that is **not** the runner rollup attestation — so no
per-criterion table exists on it and nothing here has confirmed the Feature is actually finished"
        fi
        A_FIX="$AQ is a **parent Feature at n/n** $A_MARKER: a parent has no PR OF ITS OWN, so
\`stuck-pr-sweep.yml\` (#3310) is the only thing that is *supposed* to close one. It has not, for $AAGE
minutes. (\`Closes #N\` CAN still reach a parent — a sub-issue's PR body naming the parent number closes
it, #7513 → #7500 on 2026-09-04 — so a closed parent is not proof the closer ran.)

🔴 **n/n is not a pass.** Read the \`## Acceptance\` on $AQ and check each criterion against the live
artifact before doing anything else. If ANY criterion is unmet, the remedy is to **file the remaining
work as sub-issues of $AQ** — that takes it off n/n, which is the only thing that stops the closer
treating the empty queue as a finished Feature (#4800; #4749 was closed as complete seven minutes after
its own verifier reported a failing criterion). Closing it is the wrong move in that case, not the safe one.

**Otherwise close it** (\`gh issue close $AN --repo $AREPO\`). The evidence is already on it — read the \`✔\` table and confirm the
criteria are the Feature's own, then close. Then work out why the closer skipped it, because the same
gap orphans everything filed under it afterwards (#4390):
- Is it labelled \`keep-open\`? Then it is a **standing bucket** and must NOT be closed — that is the
  closer working (#4400). Say so here and close this report instead.
- Otherwise check the workflow ran at all: \`gh run list --workflow stuck-pr-sweep.yml --limit 10\`.

🔴 Do NOT post a \`✘\` and re-open this for dispatch. That is the *tombstone* remedy and it does not
apply here: $AQ is a Feature, so it holds no work of its own to dispatch — and clearing the terminal
marker does put it back in the queue (measured #5587: an n/n parent at Todo prints \`✓ DISPATCHABLE\`),
which is a master started on nothing. A false \`✘\` on work that may well be finished is worse than the
stall. Unmet criteria are answered by FILING, per the block above."
        A_THRESH="the Feature had to have been AT n/n — its last sub-issue closed — for \$ANNOUNCE_ROLLUP_MIN=$ANNOUNCE_ROLLUP_MIN minutes (the clock is the last child's close, re-read live per candidate, NOT the ✔'s age: the closer cannot close a parent with an open child, so the ✔'s age answers a question nobody asked — #6233). **This one IS a measurement** (#4395): \`stuck-pr-sweep.yml\` declares a 30-minute cron but GitHub delivers a median of 104 minutes between scheduled runs (n=103, min 59 · p90 203). 300 clears p90 and 102 of 103 observed gaps, so this fires only when the closer is not merely late."
        # A Feature is not a work issue, so neither half of the default pair is reachable here: the body
        # above BANS \`✓ DISPATCHABLE\` outright, and BANS closing while any criterion is unmet. Filing the
        # residual is the prescribed remedy and it is what the default Acceptance had no word for.
        A_ACCEPT="- $AQ is disposed of in exactly ONE of these ways, with the reason stated ON $AQ:
  **(a) the residual is FILED** as sub-issues of $AQ — \`--explain\` then rejects it as
  \`is-a-grouper:has-open-subissues(N)\`, and that IS this criterion met, not a fresh stall;
  **(b) every criterion holds and $AQ is CLOSED**;
  **(c)** $AQ carries \`keep-open\` — a standing bucket the closer is right to skip (#4400), so it stays
  open untouched and this report says so.
  🔴 \`✓ DISPATCHABLE\` is NOT a valid end state for this class — a Feature holds no work of its own, and
  the block above bans putting it back in the queue.
- This report is closed, naming which of (a)/(b)/(c) was taken.
- If the auto-closer was skipping $AQ because it was BROKEN rather than late, the failing run is named
  here (\`gh run list --workflow stuck-pr-sweep.yml --limit 10\`) — a red closer stalls every n/n Feature
  on the board at once, so it is the finding, not a footnote." ;;
      dead-lane)
        A_HEAD="it sits on a lane no box runs, and a chain is waiting on it"
        A_FIX="**Lane is WHICH BOX RUNS IT**, not a portfolio claim. \`agent\` is the operator's laptop;
the sweeper dispatches \`$MASTERS\` and nothing else, so $AQ sits Todo forever looking
queued — and this one is not a stranded leaf, it is a **chain link**: everything above is blocked on it.
- **Re-lane $AQ** onto a master lane (\`$MASTERS\`) — that is the fix in almost every case.
- **If it genuinely needs the operator's own hands**, it must not be a chain link: retitle it
  \`[INTERACTIVE — …] [DO NOT DISPATCH] …\` and move the dependency edge AROUND it, never through it.
  \`file-issue.sh\` has refused to file this combination since #4180; this one predates that guard or was
  re-laned afterwards."
        A_THRESH="\$ANNOUNCE_DEADLANE_MIN=$ANNOUNCE_DEADLANE_MIN minutes, measured from the later of the issue's creation and its last blocker closing — i.e. how long it has been RUNNABLE and unrouted. 60 is >2x the longest observed Architect-session run on a deliberate lane-\`agent\` chain (#9295)." ;;
      board-terminal-but-reopened)
        A_HEAD="it was reopened but its Status still says done"
        A_FIX="🔴 **Leave $AQ OPEN — do not run \`gh issue close\` on it.** It was REOPENED and no \`✔\` has landed since, so the work is
unfinished and it is the **board field** that is stale — not the open state. Closing it re-closes work a
verifier just proved unfinished, which is the #4800 failure the reopen exists to prevent.

**Set its Status back to Todo** (the project is org \`$REPO_OWNER\` project #${BOARD_NUM:-1}; field and option
ids are resolved by NAME, never hardcoded):
\`\`\`bash
IDS=\"\$(gh api graphql -f query='query(\$o:String!,\$n:Int!){organization(login:\$o){projectV2(number:\$n){id field(name:\"Status\"){...on ProjectV2SingleSelectField{id options{id name}}}}}}' -F o=$REPO_OWNER -F n=${BOARD_NUM:-1})\"
P=\"\$(jq -r .data.organization.projectV2.id <<<\"\$IDS\")\"
F=\"\$(jq -r .data.organization.projectV2.field.id <<<\"\$IDS\")\"
O=\"\$(jq -r '.data.organization.projectV2.field.options[]|select(.name==\"Todo\").id' <<<\"\$IDS\")\"
I=\"\$(gh api graphql -f query='query(\$o:String!,\$r:String!,\$n:Int!){repository(owner:\$o,name:\$r){issue(number:\$n){projectItems(first:5){nodes{id project{id}}}}}}' -F o=${AREPO%%/*} -F r=${AREPO##*/} -F n=$AN --jq \".data.repository.issue.projectItems.nodes[]|select(.project.id==\\\"\$P\\\").id\")\"
gh api graphql -f query='mutation(\$p:ID!,\$i:ID!,\$f:ID!,\$s:String!){updateProjectV2ItemFieldValue(input:{projectId:\$p,itemId:\$i,fieldId:\$f,value:{singleSelectOptionId:\$s}}){projectV2Item{id}}}' -F p=\"\$P\" -F i=\"\$I\" -F f=\"\$F\" -F s=\"\$O\"
\`\`\`
Then re-run \`bash _infra/scripts/sweep-dispatch.sh --explain | grep \" $AN:\"\` and read what it says next.
**A reopened child usually has a closed PARENT too** — the closer that closed the parent is what made the
reopen a dead end, and \`parent-closed\` will be the next rejection. If the parent has open children,
reopen it (#4179): \`gh issue reopen <parent> --repo $AREPO\`.

**The field heals itself on the next \`board-reconcile.yml\` sweep (cron \`11,41\`).** Its \`OPEN + Done → Todo\`
rule fires on the reopen event for \`knowledge\`, and its scheduled \`healForeignReopens()\` pass covers every
other repo on the board (#9069). So this report means either the reopen landed between sweeps (re-run
\`--explain\` after the next \`:11\`/\`:41\` — it may already be \`✓ DISPATCHABLE\`), or that sweep is failing:
read its latest run before flipping the field by hand."
        A_THRESH="the Status had to sit terminal for \$ANNOUNCE_STALL_MIN=$ANNOUNCE_STALL_MIN minutes after the reopen — the same clock as \`board-terminal-but-open\`, deliberately, so a fresh reopen falls through to NOTHING rather than into that class's close-it remedy. **And the parent Feature had to hold no OPEN, dispatchable \`BLOCKER — VERIFY #<v>\` sibling** (#7371): when a VERIFY reopens a merged task it files the healing work as blockers under the same parent, and while one of those is open the work IS visible and this report would be noise."
        # #5587 — SAME CLASS, DIFFERENT REMEDY WHEN THE SUBJECT IS A PARENT. Everything above is about
        # making DISPATCHABLE work visible again. On a parent that answers the wrong question, and the
        # answer is not inert: an n/n Feature at Todo prints `✓ DISPATCHABLE` from the explain selector
        # in this same file (measured 2026-08-14 on a synthetic 2/2 · Todo · lane bravo item — `checks`
        # has no is_parent test), so writing Todo queues a master onto a Feature with no child work left
        # and no PR of its own. Same leaf/parent split #4828 drew on the ✔ arm (tombstone vs
        # rollup-unclosed). The case: knowledge #5466 closed 14:48:32Z, reopened 17:25:58Z by the #4179
        # rule because its VERIFY child #5467 was still open, child closed PASS 17:54Z — a finished,
        # PASS-verified Feature at 2/2 that this class told a master to set back to Todo. On a parent the
        # reopen leaves open whether the Feature is FINISHED: the rollup question, and the rollup remedy.
        if [ "$APARENT" = true ]; then
          A_HEAD="a reopened n/n Feature whose Status still says done"
          A_FIX="$AQ is a **parent Feature at n/n** that was REOPENED while its board Status stayed
\`$ASTATUS\`. The commonest way this happens is the #4179 rule: the Feature was closed while a child —
usually its \`VERIFY\` — was still open, so the check reopened it. Once that child closes the reopen has
done its job and nothing comes back for the parent: a parent has no PR, so \`Closes #N\` structurally
cannot fire on it, and \`stuck-pr-sweep.yml\` (#3310) is the only thing that closes one.

🔴 **Do NOT set its Status to Todo.** That is the LEAF remedy for this class and it is actively wrong on a
parent: an n/n Feature at \`Todo\` passes every dispatch check (\`--explain\` prints it \`✓ DISPATCHABLE\` —
there is no is_parent test among them), so Todo does not surface work, it **queues a master onto a Feature
with no child work left to do and no PR of its own to write.**

🔴 **n/n is not a pass.** Read the \`## Acceptance\` on $AQ and check each criterion against the live
artifact before doing anything else — including the recorded verdict of its \`VERIFY\` child if it has one.
- **A criterion is unmet, or a VERIFY recorded FAIL** → **file the remaining work as sub-issues of $AQ.**
  That takes it off n/n, which is the only thing that stops the closer treating an empty queue as a
  finished Feature (#4800; #4749 was closed as complete seven minutes after its own verifier reported a
  failing criterion). Closing it is the wrong move in that case, not the safe one.
- **Every criterion holds** → **close it:** \`gh issue close $AN --repo $AREPO\`, and state ON $AQ which
  criteria you exercised and what they printed. The terminal Status is then correct rather than stale.
- Labelled \`keep-open\`? Then it is a **standing bucket** and must NOT be closed (#4400) — say so here.

Do NOT post a \`✘\` to make it dispatchable again: that is the *tombstone* remedy for a leaf, nothing
dispatches a Feature, and a false \`✘\` on work that may well be finished is worse than the stall."
        fi ;;
      board-terminal-but-open)
        A_HEAD="its Status says done but it is still open"
        A_FIX="The board Status on $AQ is $ASTATUS — a terminal state — but GitHub reports it OPEN. No fleet selector can see it: the sweeper reads only Todo, the reaper reads only Doing, and every announcer class requires one of those. **Close it:** \`gh issue close $AN --repo $AREPO\`. The Status says the work is done; the open state is just a missed close.

🔴 **Check \`state_reason\` before you close it** — \`gh api repos/$AREPO/issues/$AN --jq .state_reason\`. If it
reads \`reopened\`, this is the WRONG report for it (the \`board-terminal-but-reopened\` class above owns that
case, #5545): the field is what is stale, the remedy is Status→Todo, and closing it re-closes work a
verifier proved unfinished. Say so here and fix the classifier rather than following this paragraph."
        A_THRESH="the Status had to sit at Done/Review for \$ANNOUNCE_STALL_MIN=$ANNOUNCE_STALL_MIN minutes — this excludes genuine transitions where a Status change and a close happen in the same 5-minute cycle. The age is measured from the issue's last update, not its creation, because a terminal Status is the signal." ;;
      *) A_HEAD="stalled"; A_FIX="Investigate $AQ."; A_THRESH="unclassified" ;;
    esac

    A_TITLE="$AKEY — $A_HEAD"
    A_BODY="$(mktemp)"
    cat > "$A_BODY" <<ABEOF
**Filed by \`_infra/scripts/sweep-dispatch.sh\` — the sweeper knew, and this is it saying so (#4182).**

**$AQ** — $ATITLE — has been rejected by the dispatch sweep on every cycle for the same reason:
**\`$ACLASS\`**.

> $ADETAIL

The sweep re-derives this every 5 minutes and will keep rejecting
$AQ until the cause below is cleared — the queue is not slow, it is a **one-way door**. (The SWEEPER is
not coming for it. A direct \`dispatch.sh\` bypasses every predicate here, so a run may still be on it —
which is why the first instruction below is to re-read the issue, not to act on this report.)

## How to clear it
$A_FIX

## Then close THIS issue
The next cycle re-derives the stall from the board. Cleared → nothing is re-filed. Not cleared → this
report comes back, which is the mechanism working, not a duplicate.

## Research before building
- **Re-read $AQ first.** This report was generated at $(ts) and the board moves in minutes:
  \`gh api repos/$AREPO/issues/$AN --jq .title\` + \`gh api repos/$AREPO/issues/$AN/comments --jq '.[-3:][].body'\`.
- Confirm the class still holds: \`bash _infra/scripts/sweep-dispatch.sh --explain | grep " $AN:"\` — and
  check the repo it prints, because the board spans four repos and issue numbers collide across them.
- The classifier is the announcer block at the bottom of \`_infra/scripts/sweep-dispatch.sh\`. **If the class
  is WRONG, that is the defect worth fixing** — fix it there and say so here, rather than working around it.

## Acceptance
$A_ACCEPT

---
⏱ **The threshold that fired this is PROVISIONAL.** $A_THRESH
It is an estimate, not a measurement — doctrine says a limit is a measurement, so it must be re-derived
from a day of observed filing rate (#4182). If this report is noise, say so here: that is the measurement.
ABEOF

    if [ "$APPLY" != 1 ]; then
      log "  📣 would announce $AQ ($ACLASS, stuck ${AAGE}m, → lane $A_LANE $A_PRIO) — $ADETAIL"
      ANNOUNCED=$((ANNOUNCED+1)); rm -f "$A_BODY"; continue
    fi
    if AOUT="$(bash "$FILE_ISSUE" --title "$A_TITLE" --body-file "$A_BODY" --lane "$A_LANE" \
                --priority "$A_PRIO" --portfolio "$A_PORT" --parent "$ANNOUNCE_PARENT" \
                --parallel --repo "$REPO" </dev/null 2>&1)"; then
      log "  📣 announced $AQ ($ACLASS, stuck ${AAGE}m) → $(printf '%s' "$AOUT" | grep -o 'https://github.com/[^ ]*' | tail -1)"
      ANNOUNCED=$((ANNOUNCED+1))
    else
      # A failed filing is NOT retried in-cycle (same reasoning as a failed dispatch): the next cycle is
      # 5 minutes away, the stall is still derivable, and nothing was lost.
      log "  ✘ announce FAILED for $AQ ($ACLASS): $(printf '%s' "$AOUT" | tail -2 | tr '\n' ' ')"
    fi
    rm -f "$A_BODY"
  done <<< "$STALLS"
 fi
fi

beat "ok candidates=$N_CAND dispatched=$DISPATCHED parked=$PARKED held=$SKIPPED reg-failed=$REG_FAILED no-plan=$NO_PLAN reaped=$REAPED announced=$ANNOUNCED announce-reaped=$ANNOUNCE_REAPED$( [ "$ANNOUNCE_HELD" -gt 0 ] && printf ' announce-held=%s' "$ANNOUNCE_HELD") inflight=$TOTAL_INFLIGHT$( [ "$UNIT_PARSE_BROKEN" = 1 ] && printf ' UNIT-PARSE-BROKEN')$( [ "$APPLY" = 1 ] || printf ' DRY-RUN')"
log "sweep done: dispatched=$DISPATCHED parked=$PARKED held=$SKIPPED reg-failed=$REG_FAILED no-plan=$NO_PLAN reaped=$REAPED announced=$ANNOUNCED announce-reaped=$ANNOUNCE_REAPED"
exit 0
