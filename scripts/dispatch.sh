#!/usr/bin/env bash
# dispatch.sh <master> <issue#> [repo] — architect hands a master its issue by STARTING the run (DR 2026-07-23, C3).
# Detached transient systemd unit on the master's box: survives SSH disconnect + the laptop sleeping.
# Masters on fleet-host: alpha bravo charlie delta (reached via bravo + sudo). architect dispatches locally.
set -euo pipefail

# Source shared board helpers for parked-title detection
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/shared-board-helpers.sh"

# ── THE REGISTRY READER/WRITER (knowledge#4526, replacing #4521's inline helpers) ───────────────
# 🔴 THE `backlog task` PATH IS DEAD, and this is where it was replaced. Backlog.md 1.49.3 cannot see
# `entries/<YYYY-MM>/` on TWO independent axes with no setting between them — it does not recurse (a task
# at `tasks/2026-08/` is already invisible) and the folder name is compiled into the platform binary. It
# also RECREATES the seven directories #4472 deleted on a merely read-only command, and answers a miss with
# exit 0. Measured against the real binary 2026-08-05.
#
# #4521 first met this with three helpers inlined here. They are gone, and here is why — the point is not
# style, it is that each one reintroduced the defect #4526 was filed about:
#   · `write_registry_refs` ended `>/dev/null 2>&1 || true`, so it ALWAYS returned 0 — the `|| rlog "…
#     failed"` at both call sites could never fire, and a write that could not land was silent again.
#   · `read_registry_refs` ended `2>/dev/null || true`, so a miss and a parse failure arrived as the same
#     empty string.
#   · `create_registry_entry` fell back to `n=0` on an unreadable registry — minting PLAN-1 over 84
#     entries, which is exactly what Backlog.md did and exactly what the issue forbids.
#   · every reference was re-emitted quoted, so an edit rewrote 72 of the 78 entries that carry references
#     (the corpus is mixed: Backlog.md itself wrote `- \'gh:2626\'` on one line and a bare path on the next).
#
# So there is ONE writer, it lives beside this script, and it is exercised by
# `_infra/scripts/test-plan-registry-cli.sh` — 26 assertions over a copy of the real 84 entries, every one
# reading the FILE rather than a return value.

# ── 🔴 ~/.local/bin ON OUR OWN PATH — the THIRD instance of the #3969 class, and the one that bites first.
# The `agent|architect)` branch below already passes `--setenv=PATH="$HOME/.local/bin:$PATH"` to the unit
# it starts, because `systemd-run --user` does not inherit the caller's environment. That fixed the RUNNER
# and left the DISPATCHER broken: on the Architect's box `jq` lives only at `~/.local/bin/jq`, and a
# non-interactive `ssh box 'bash dispatch.sh …'` gets none of it — Ubuntu's ~/.bashrc returns early when
# not interactive, so ~/.local/bin is never prepended. Measured 2026-08-04 dispatching #4227 from
# bravo@fleet-host: `dispatch.sh: line 863: jq: command not found`, exit 127 — the identical error, one
# process earlier, on the identical missing directory. Remote invocation is the NORMAL way another master
# reaches this script, so this path is not an edge case.
# No-op wherever ~/.local/bin is absent or already present; never shadows a system tool it does not hold.
# Written as an `if`, not `[ -d … ] && PATH=…`: under `set -euo pipefail` that AND-list leaves the whole
# `case` exiting 1 on every box that has no ~/.local/bin. It survives only on the POSIX exemption for a
# non-final member of an AND-list — a guarantee no one should have to re-derive to read line 1 of a
# dispatcher. The `if` exits 0 either way.
if [ -d "$HOME/.local/bin" ]; then
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) : ;;
    *) PATH="$HOME/.local/bin:$PATH"; export PATH ;;
  esac
fi

_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The box every non-agent master runs on; hoisted so --count can reach it too. Overridable by env for the
# same reason sweep-dispatch.sh's `SWEEP_NOVA_IP` is (:82): it is how the UNREACHABLE-box path — the most
# important fail-open case in the quota pre-flight (#3906), since a dark box must never block the fleet —
# gets exercised without taking the real box down. The default is unchanged.
BRAVO="${DISPATCH_NOVA_IP:-192.0.2.10}"


# ── STEP n/8 / `active_plan()` — DELETED (#7159) ──────────────────────────────────────────────────
# Two functions lived here and both are gone. They are recorded rather than merely removed because the
# transcript read they shared is the kind of machinery that gets reinvented:
#
#   · `active_plan()` resolved `$HOME/.claude/projects/**/$CLAUDE_CODE_SESSION_ID.jsonl` with a `find`,
#     then `tail -c 8388608 | grep -a | tail -1 | cut` — 8 MiB read and five processes, measured at
#     52-112 ms warm and 472-737 ms cold, to extract a `"planFilePath"` field that NATIVE PLAN MODE
#     records and `bypassPermissions` never does. Doctrine mandates bypassPermissions for every planning
#     session (`doctrine/planning-loop.md`), so the field stopped being written: of the 18 transcripts on
#     the Architect's box after 2026-08-06, ZERO carried it, and every `flip:` line in
#     `~/.claude/state/plan-registry.log` after 2026-08-06T19:32:55Z said `no plan file`, 22 in a row.
#     It was a page-cache-cold 8 MiB read whose answer was the empty string on every modern dispatch.
#
#   · `advance_plan_step()` stamped `STEP n/<total>` onto line 1 of that file. Its ONE call site sat at
#     the bottom of this script and had been COMMENTED OUT since #4319 — so it was unreachable code
#     calling an always-empty resolver. That call site is now a tombstone of its own; search this file
#     for "THE PLAN-FILE HEADER STAMP" before restoring anything.
#
# 🔴 WHAT WENT WITH THEM, and why that is not a behaviour change. `register_plan_dispatched` read
# `active_plan()` for exactly one thing: re-copying the session's plan file into `plans/documents/` to
# "keep the artifact honest, because the plan file just got its STEP 8 stamp". The stamper is the
# unreachable function above — nothing has stamped a plan file since #4873 — so the re-copy was keeping
# honest an edit that no longer happens, from a path that no longer resolves. The ENTRY is resolved from
# the ISSUE (`resolve_plan_entry`, #4464) and never from the session's open plan, so nothing about which
# entry a dispatch stamps depends on any of this.
#
# 🔴 IF YOU ARE ABOUT TO REINTRODUCE A "which plan does this session have open" READ: the answer is
# `~/.claude/state/plan-bind/$CLAUDE_CODE_SESSION_ID`, written by `plan-bind.sh` and already read by
# TIER 3 below. It is a claim the session made about itself, it is one `head -1`, and it works under
# bypassPermissions. NO MTIME FALLBACK — that was #3557's bug and it stays dead.
# ─────────────────────────────────────────────────────────────────────────────────────────────────

# ── The plan registry: flip this plan's entry to Dispatched, write its refs (#3547, F #3544) ────────
# The entry this flips is created during planning by architect's ~/.claude/hooks/posttooluse-plan-step-emit.sh,
# already `Dispatched` (#4375 deleted `Planned`), on the first tick of the session that owns the plan (#4508).
# Its predecessor — a capture half in `posttooluse-plan-approved.sh` that created the entry at ExitPlanMode —
# was deleted by #4477: it wrote nothing step-emit does not write earlier. Starting a run is the moment the
# plan stops being an intention, and this script is the one place that knows both the plan AND the issue —
# so the flip and the `gh:` reference are written here.
#
# 🔴 REFERENCES ONLY, NEVER STATE. `Executed` is DERIVED at render — all referenced Features closed →
# Executed; zero `gh:` refs → whatever the entry stores. Writing a cached open/closed flag here makes the
# registry a second tracker, the failure doctrine/operating-system.md names outright ("Two trackers cannot
# both be true"). The registry says which issues a plan BECAME; the board says what happened to them.
# Derivation rule: wi/work/reference/occ/plan-status-rules.md (#3548, split #4407).
# The `references` convention: wi/work/reference/occ/plan-registry-format.md.
#
# 🔴 It may not kill the dispatch. `set -euo pipefail` (:5) turns any unguarded failure in here into a DEAD
# DISPATCH — the #3315 bug. Every step returns 0 on a miss (no plan, no clone, no `backlog`, no registry
# config — the last is the common case until #3546 lands) and the call site adds `|| true`.
PLAN_REGISTRY_LOG="${PLAN_REGISTRY_LOG:-$HOME/.claude/state/plan-registry.log}"
rlog() { mkdir -p "$(dirname "$PLAN_REGISTRY_LOG")" 2>/dev/null || true
         printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$PLAN_REGISTRY_LOG" 2>/dev/null || true; }

# This script self-locates (:15 already resolves the registry the same way), so the clone it edits is always
# the clone it was invoked from — no guessing between the Architect's two checkouts.
#   🔴 NOT ~/.claude/knowledge: that symlink is the read-only consumable, `reset --hard`ed every session.
knowledge_dir() { printf '%s' "${KNOWLEDGE_DIR:-$(cd "$_SD/../.." && pwd)}"; }

# The registry CLI ships BESIDE this script, so it is present whenever this script is, and it is resolved
# BY PATH rather than by name (#4526).
#
# 🔴 THERE IS NO FALL-BACK TO `backlog`, and that is the fix, not an oversight. `command -v backlog` on
# fleet-host resolved `backlog@1.4.56` — `osmove/backlog`, an unrelated agent orchestrator with no
# `task edit` at all — for weeks after #4495 corrected package.json, because `node_modules/` is gitignored
# and a merged dependency reaches no box. So the failure had two shapes on two boxes and one symptom.
# Falling back to a CLI that provably cannot read this registry is how five call sites here reported
# success while writing nothing; absent → say so, loudly, and skip.
#   BACKLOG_BIN still overrides, for a caller that genuinely has something else in mind.
backlog_bin() {   # <kb>
  if [ -n "${BACKLOG_BIN:-}" ] && [ -x "${BACKLOG_BIN}" ]; then printf '%s' "$BACKLOG_BIN"; return 0; fi
  [ -x "$_SD/plan-registry-cli.py" ] && { printf '%s' "$_SD/plan-registry-cli.py"; return 0; }
  rlog "registry CLI missing at $_SD/plan-registry-cli.py — every registry write will be skipped (#4526)"
  return 0
}

# ── A WRITE THAT CANNOT LAND MUST BE LOUD (#4526) ────────────────────────────────────────────────
# The message was always the scarce information, and it was always the part being thrown away: every call
# site here was `>/dev/null 2>&1 || rlog "… failed"`, which is how `sweep-reg: task edit PLAN-83 failed`
# sat in the log for days with no way to tell a missing entry from a bad status from a CLI that was not
# the CLI. Now the CLI's own words reach the log and the console.
#
# 🔴 `|| rc=$?` is load-bearing under `set -euo pipefail` (:5): an ASSIGNMENT takes its substitution's
# status, so a bare `REG_OUT="$(…)"` on a non-zero exit KILLS THE DISPATCH — the #3315 bug, in a new place.
# ── THE VERBS ARE `task <id>` AND `task edit`, AND THAT IS MEASURED, NOT REMEMBERED (#4464) ──────
# 🔴 DO NOT "correct" these to `task show` / `task update` / `task add`. Those are the verbs of
# `osmove/backlog@1.4.56` — the unrelated agent orchestrator that `command -v backlog` resolves on
# fleet-host, and the impostor the comment above backlog_bin() names outright. The CLI that actually runs
# here is `_infra/scripts/plan-registry-cli.py`, resolved BY PATH, and its dispatcher (`main()`, the
# `if sub == …` ladder) knows exactly five subcommands — `list refs edit create regen` — then FALLS
# THROUGH to `cmd_show(root, sub)`. So:
#   `task PLAN-84 --plain`  → shows PLAN-84                    ✅ what these call sites use
#   `task show PLAN-84`     → looks up an entry whose id is literally "show" → "task show not found"
#   `task update PLAN-84 …` → falls through to cmd_show too — A READ. The status and every --ref are
#                             silently DISCARDED, and the call still exits 0.
# #4633 made exactly that change on both paths, on the premise "the backlog CLI v1.4.56 has task
# show/update". Measured against the real writer 2026-08-06: the interactive flip resolved the correct
# entry and then died at the read-back, and the sweeper path went from stamping `PLAN-84 → Dispatched
# (+gh:4458)` to stamping NOTHING — five minutes after #4409 fixed that very writer. Both registry
# writers were dead on main until this reverted it.
# The regression test that pins it: `_infra/scripts/test-plan-entry-resolution.sh` (case 4).
REG_OUT=""
reg_cli() {   # <kb> <bin> <args…> → the CLI's status; its own message lands in REG_OUT and in the log
  local kb="$1" bin="$2" rc=0; shift 2
  REG_OUT="$( cd "$kb" && "$bin" "$@" 2>&1 )" || rc=$?
  [ "$rc" -eq 0 ] || rlog "registry: \`${bin##*/} $*\` exited $rc — ${REG_OUT:-<no output>}"
  return "$rc"
}

# CONFIG-DRIVEN, never assumed: `backlog init --backlog-dir` records it, so phase 1 can move the registry
# without touching this script. Empty output = no registry yet → skip.
backlog_registry_dir() {   # <kb>
  local c d
  for c in "$1/backlog.config.yml" "$1/backlog/config.yml" "$1/.backlog/config.yml" \
           "$1/wi/work/plans/config.yml"; do
    [ -f "$c" ] || continue
    d="$(sed -nE 's/^backlog_directory:[[:space:]]*"?([^"#]*[^"# ])"?[[:space:]]*$/\1/p' "$c" | head -1)"
    printf '%s' "${d:-wi/work/plans}"; return 0
  done
}

# ── `plan_slug()` / `artifact_for()` — DELETED (#7159) ────────────────────────────────────────────
# The plan-identity key (#3587: a plan's H1, never its session-scoped basename) and the document-basename
# lookup lived here. Their ONLY caller was the document re-copy in `register_plan_dispatched`, which went
# with `active_plan()` — see the tombstone at the top of this file. The rule itself is NOT lost: it is
# implemented in `~/.claude/hooks/posttooluse-plan-step-emit.sh` (`create_entry`), which is the writer that
# mints a plan's entry and its document in the first place. That hook deliberately never copied these
# functions, so this deletion removes a second copy rather than the rule.

# ── THE DECLARED PHASE COUNT (#4322) — the THIRD verbatim twin of the capture hook's ───────────────
# 14 of 70 registered plans filed ZERO issues and nothing noticed, because nothing ever declared how many
# there were SUPPOSED to be. `--chain` (#4183) files an ordered chain atomically, so the failure mode is
# never "half filed" — it is "the call was never made for phases 4-6". A count declared before the call is
# the only thing that can make that visible, and the OCC compares it against what is actually on the board.
#
# 🔴 DERIVED FROM THE PLAN, NEVER ASKED FOR. The parent Feature's own measurement: a required argument hits
# 100%, an optional flag 17% (`--blocked-by`: 8 of 46). A `--phases N` flag would decay the same way, so
# nothing here asks anyone to declare anything — the plan's own phase headings ARE the declaration.
#
# Both live conventions count, because both are real in the registry today:
#   `### P1 · FleetUsageSummary  DISPATCH`   (2026-08-04 onward — 6 phases, the case that motivated this)
#   `### Task 1 — unbreak the loop`          (the older shape — 35 of 57 tracked artifacts use one or other)
# DISTINCT numbers, so a phase with sub-headings counts once.
#
# 🔴 ZERO MEANS WRITE NOTHING. 23 of 57 tracked artifacts have no phase headings at all (mostly the #3546
# backfill, which recovered plan prose without structure). An absence of structure is not a plan with zero
# phases, and `phases:0` would render as a positive claim about a plan we simply cannot read — the exact
# `Parked · none filed` promotion #3583 removed from this surface. No headings → no `phases:` reference →
# the row renders exactly as it does today.
#
# THE ONLY WRITER of `phases:N`, since #4477 deleted the capture hook that held the second copy (and
# `test-plan-capture.sh` §6, which asserted the two agreed). The step-emit hook deliberately does not
# reintroduce a copy: a plan at step 1-4 usually declares no phase headings yet, so the dispatch flip is
# the first moment the count is worth anything.
plan_phase_count() {   # <plan-file> → distinct declared phases; 0 when the plan declares none
  # The trailing `|| true` is load-bearing under dispatch.sh's `set -euo pipefail`, and it must sit at the
  # END OF THE WHOLE PIPELINE: BOTH greps exit 1 when a plan declares no phases, pipefail propagates that,
  # and `phases="$(plan_phase_count …)"` is an ASSIGNMENT — which takes the substitution's status, so the
  # dispatch aborts. Measured: with `|| true` tucked inside a `{ … }` around the first grep instead, every
  # dispatch of a plan with no phase headings — 23 of 57 tracked artifacts, the COMMON case — died right
  # here. (An `echo "$(plan_phase_count …)"` does NOT reproduce it: there the status is echo's, not the
  # substitution's. The test has to assign.) `wc -l` has already printed a perfectly good 0 by then.
  grep -ohE '^#{2,4}[[:space:]]*\**[[:space:]]*(Task|Phase|Step)[[:space:]]+[0-9]+|^#{2,4}[[:space:]]*\**[[:space:]]*P[0-9]+([^0-9A-Za-z]|$)' \
       "$1" 2>/dev/null | grep -oE '[0-9]+' | sort -un | wc -l | tr -d ' ' || true
}

# One key, carried in the entry's `artifact:` reference — the capture hook writes it, this finds it.
#   Scoped to Backlog.md's own ENTRY directories, never the whole registry dir: the captured plan copies
#   live under it too (artifacts/), as do phase 1's backfilled plan bodies, and a plan that quotes a path
#   would otherwise match itself instead of its entry.
registry_file_for() {   # <kb> <registry-dir> <artifact-basename> → task file path (empty if none)
  local d hit dirs=()
  for d in entries; do [ -d "$1/$2/$d" ] && dirs+=("$1/$2/$d"); done
  [ ${#dirs[@]} -gt 0 ] || return 0
  # Capture's own convention first, then phase 1's backfill convention (`<registry dir>/<plan>.md`, bare and
  # unprefixed) — otherwise dispatching a BACKFILLED plan would create a duplicate entry beside it instead
  # of flipping it. Both patterns are path-anchored: a loose basename match would hit any entry whose
  # description happens to quote a filename.
  hit="$(grep -rlF --include='*.md' -- "/$3" "${dirs[@]}" 2>/dev/null | head -1 || true)"
  [ -n "$hit" ] || hit="$(grep -rlF --include='*.md' -- "$2/$3" "${dirs[@]}" 2>/dev/null | head -1 || true)"
  printf '%s' "$hit"
}

# ── WHOSE Feature is this? (#3665) ────────────────────────────────────────────────────────────────
# The entry below is chosen from the DISPATCHING SESSION's open plan, which is right only while the
# Architect is dispatching the plan it just filed. Dispatch anything OLDER from that same session — a
# follow-up, a re-dispatch, a defect filed against an earlier Feature — and that Feature is appended to
# the new plan's entry, which then claims work it never produced. Measured 2026-08-01: PLAN-62 collected
# FOUR foreign Features in 93 seconds (a9be36bc, ba9afd28, da865fc9, a873787d), and PLAN-15 collected two.
# #3587 fixed the artifact KEY; this is the other axis — which Features an entry claims.
#
# The reliable half of the answer is already in the registry: if some entry ALREADY references this
# Feature, that entry is its home, and this dispatch is a re-dispatch or a sibling task of work already
# recorded. Flip THAT one. One Feature comes from one plan, so a second claimant is always the bug.
#
# ⚠ What this does NOT fix, stated so nobody reads more into it: the FIRST dispatch of a Feature filed by
# an older plan still attaches to whatever plan is open, because nothing links a Feature back to its plan
# until this function writes the link. Closing that needs the plan slug recorded at FILE time
# (`file-issue.sh --feature`), not here. Documented in reference/occ/plan-registry-format.md.
ref_owner() {   # <kb> <registry-dir> <ref> → the entry already carrying this reference (empty if none)
  local d esc dirs=()
  for d in entries; do [ -d "$1/$2/$d" ] && dirs+=("$1/$2/$d"); done
  [ ${#dirs[@]} -gt 0 ] || return 0
  # Whole-line match on the YAML list item, quoted or bare — `gh:356` must never match `gh:3563`, and a
  # reference quoted in an entry's prose is not a claim. `.` is the only ERE metacharacter a ref can carry
  # (a cross-repo `gh:owner/repo.name#N`); everything else in one is literal.
  esc="$(printf '%s' "$3" | sed 's/\./\\./g')"
  grep -rlE --include='*.md' -- "^[[:space:]]*-[[:space:]]*['\"]?${esc}['\"]?[[:space:]]*$" \
       "${dirs[@]}" 2>/dev/null | head -1 || true
}

# ── THE ONE RESOLVER: which entry does this FEATURE belong to? (#4464) ────────────────────────────
# Provenance is a question about the WORK, so it is answered from the ISSUE — never from whichever plan
# the dispatching session happens to have open. That fallback is what stamped `gh:4458` onto PLAN-82 on
# 2026-08-05 ("Kill `Planned`"), a plan that did not produce #4458 and has no relationship to it;
# retracted by hand in bcf7e92a. #3665 named the class, PLAN-62 collected FOUR foreign Features that way
# in 93 seconds, and PLAN-71 collected `gh:3903`. It kept recurring because the RESOLUTION INPUT was
# wrong, not because the code was buggy: a session's open plan file is not evidence about which plan
# produced a given issue.
#
# 🔴 A WRONG REF IS WORSE THAN A MISSING ONE. Every tier below is evidence ABOUT THE FEATURE. When none
# of them answers, this resolves to nothing and the caller LOGS AND COMMENTS why. It never guesses.
#
# 🔴 This is the ONLY copy, and that is the fix for the twins. Two functions were asked to stay in
# lockstep by hand — `register_plan_from_issue` still carries four "same logic as
# register_plan_dispatched" comments, two of them citing line numbers that drifted long ago (":452-458",
# ":528-534"; neither points at what it names). The test that checked the agreement,
# `test-plan-capture.sh` §6, was deleted with the capture hook in 8a42f6572 (#4477), so by the time #4464
# was filed the convention had NO enforcement left at all. Shared code needs none:
# `register_plan_dispatched` (interactive) and `register_plan_from_issue` (sweeper) both call this, so
# they cannot disagree — and a line-number citation cannot rot into a lie about behaviour.
#
# 🔴 SETS GLOBALS, returns 0 always. Deliberately not `f="$(resolve_plan_entry …)"`: command substitution
# runs in a SUBSHELL, so a `RESOLVE_WHY` set inside one would be silently lost — and an ASSIGNMENT takes
# its substitution's status, which under `set -euo pipefail` (:5) is the #3315 dead-dispatch bug.
RESOLVED_ENTRY=""   # the entry file this Feature belongs to; empty = unresolved
RESOLVE_WHY=""      # a human sentence for the log and the refusal comment

resolve_plan_entry() {   # <kb> <registry-dir> <ref> <repo> <feature>
  local kb="$1" rd="$2" ref="$3" repo="$4" feature="$5"
  local f="" meta ftitle fcreated af atitle bf pdoc bst cand t3 n bid bidf bidnote
  local hit rest ws psize prev sz apath i
  local -a cands=() ents=() arts=()
  local -A asz=()
  RESOLVED_ENTRY=""; RESOLVE_WHY=""

  # TIER 1 — an entry ALREADY claims this Feature. One Feature comes from one plan, so an existing
  # claimant is the answer and a second claimant is always the bug. This is also the tier that makes a
  # re-dispatch idempotent: same issue → same entry, whatever plan the new session has open.
  f="$(ref_owner "$kb" "$rd" "$ref")"
  if [ -n "$f" ]; then
    RESOLVED_ENTRY="$f"; RESOLVE_WHY="TIER 1 — $ref already registered in $(basename "$f")"
    return 0
  fi

  meta="$(gh api "repos/$repo/issues/$feature" --jq '{title,created_at}' 2>/dev/null || true)"
  ftitle="$(printf '%s' "$meta" | jq -r '.title // empty' 2>/dev/null || true)"
  fcreated="$(printf '%s' "$meta" | jq -r '.created_at // empty' 2>/dev/null || true)"
  if [ -z "$ftitle" ] || [ -z "$fcreated" ]; then
    RESOLVE_WHY="TIER 2 FAILED — cannot read Feature #$feature from $repo"
    return 0
  fi

  # TIER 2 — a committed plan document whose H1 IS the Feature title. The Feature's own artifact/H1
  # lineage, which is exactly the evidence #4464 asks this to be derived from.
  #
  # 🔴 ONE PROCESS, NOT ONE PER DOCUMENT (#7159). This used to `find | sort` and then fork a `sed` per
  # file to pull each H1 — 233 documents in the live corpus on 2026-08-28, so 233 forks to answer a
  # string comparison, on the tier that MISSES on most dispatches (a plan document's H1 is the PLAN's
  # title, only sometimes byte-identical to the Feature's). `grep -m1` stops at the first matching line
  # PER FILE, which is exactly what the old `sed … | head -1` meant, so the answer is unchanged:
  #   · the pattern is the sed pattern's own left-hand side — `#`, then AT LEAST ONE whitespace (a tab
  #     counts, as it did), then at least one more character. `## Sub` never matches (second byte is not
  #     whitespace) and a bare `# ` never matches (nothing after the space).
  #   · the H1 is not necessarily line 1 — a document may open with an HTML comment — so this is NOT
  #     `awk FNR==1`. First MATCHING line, per file, same as before.
  #   · `-h` is deliberately absent and `--` closes the option list: the filename prefix is the answer.
  #     Document paths carry no `:` (they are `documents/YYYY-MM/[A-Za-z0-9._-]+\.md`, the same shape
  #     TIER 3 asserts below), so `${line%%:*}` splits it unambiguously.
  #   · SORTED, because the old walk was: two documents with the same H1 must resolve to the same one
  #     they resolved to before. `grep` emits in argument order and the glob is sorted, so it already is.
  #   · the H1 text is extracted with PARAMETER EXPANSION, not a second `sed`. A `sed` per output line
  #     would have put all 233 forks straight back — the first cut of this change did exactly that and
  #     `strace -c` still showed 236 `sed` execs. Bash strips it in-process, and the strip is EXACT: on a
  #     line grep has already matched, `s/^#[[:space:]]+(.+)$/\1/` means "drop the `#`, then drop the
  #     longest leading whitespace run that still leaves at least one character" — which is the `ws`/
  #     `body` pair below, including the degenerate `#` + whitespace-only line where POSIX
  #     leftmost-longest hands `(.+)` the final whitespace character.
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    af="${hit%%:*}"
    rest="${hit#*:}"; rest="${rest#\#}"
    ws="${rest%%[![:space:]]*}"; atitle="${rest#"$ws"}"
    [ -n "$atitle" ] || atitle="${rest: -1}"
    [ "$atitle" = "$ftitle" ] || continue
    f="$(registry_file_for "$kb" "$rd" "$(basename "$af")")"
    if [ -n "$f" ]; then
      RESOLVED_ENTRY="$f"
      RESOLVE_WHY="TIER 2 — artifact H1 matches Feature title \"$ftitle\" → $(basename "$f")"
      return 0
    fi
  #   · BOTH globs, buckets first. Every one of the 233 live documents sits in a `YYYY-MM/` bucket (the
  #     step-emit hook writes nothing else) and the old `find` was recursive, so an unbucketed document
  #     must stay visible rather than silently stop resolving. A glob that matches nothing expands to
  #     itself, grep says so on the stderr this discards, and the other glob's matches are unaffected.
  done < <(grep -m1 -HE '^#[[:space:]]+.' -- \
             "$kb/$rd"/documents/*/*.md "$kb/$rd"/documents/*.md 2>/dev/null || true)

  # ── TIER 3 (#4987) — THE DISPATCHING SESSION'S OWN BINDING ────────────────────────────────────────
  # 🔴 PROXIMITY STAYS DEAD. #4861 removed "the newest ref-less entry within 24h" and that removal is
  # correct: nearness in time is not provenance, and it attached `gh:4749` to PLAN-116, a plan that did
  # not produce it. Nothing below guesses, ranks by recency, or looks at any other session's state.
  #
  # What this tier reads instead is a CLAIM the session already made about itself. `plan-bind.sh` writes
  # `~/.claude/state/plan-bind/<CLAUDE_CODE_SESSION_ID>` when a planning session says which plan it owns —
  # doctrine requires that command once per session — and `CLAUDE_CODE_SESSION_ID` is stable across turns
  # and immune to pid reuse (#5196), so a `dispatch.sh` invoked from that session can name THAT file and
  # no other. TIER 1 and TIER 2 are the only tiers that survived #4861, and neither usually holds at
  # dispatch time: the `gh:` ref does not exist yet (that is what this call is about to write), and the
  # plan document's H1 is the PLAN's title, which is only sometimes byte-identical to the Feature's.
  # Measured in `~/.claude/state/plan-registry.log`: since #4861 both dispatches that reached this
  # resolver refused (`gh:4938`, `gh:4976`) and both were repaired by hand (`5be1f4f2`).
  #
  # 🔴 THREE WAYS IT CONTRIBUTES NOTHING, each falling through to the refusal below with its own reason:
  #   · `CLAUDE_CODE_SESSION_ID` unset → this is not a session dispatch (a sweeper, a cron, a bare shell)
  #   · no binding file for that session → the session never said which plan it owns
  #   · the bound plan document does not exist → the binding points to a deleted file
  # It never falls back to "newest", "nearest", or another shell's binding, and an ambiguous match refuses
  # rather than picking one — the whole point of the tier is that the session named its own plan.
  t3=""
  if [ -z "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    t3="TIER 3 contributed nothing — \$CLAUDE_CODE_SESSION_ID is unset, so no dispatching session claims this plan"
  else
    bf="${HOME:-/nonexistent}/.claude/state/plan-bind/$CLAUDE_CODE_SESSION_ID"
    if [ ! -r "$bf" ]; then
      t3="TIER 3 contributed nothing — session $CLAUDE_CODE_SESSION_ID has no plan binding (\`plan-bind.sh --entry <N>\` was never run in it)"
    else
      pdoc="$(head -1 "$bf" 2>/dev/null || true)"
      bst="$(sed -n '2p' "$bf" 2>/dev/null || true)"
      # The binding's line 2 is `pid:<N>` if the session pid was found, or absent otherwise.
      # No starttime validation is performed — the live `plan-bind.sh` writes session_id-keyed bindings
      # without `starttime:` fields (#5196), so that check can only ever reject.
      #
      # ── PREFER THE ID OVER THE PATH (#5774, PLAN-171 criterion 3) ──────────────────────────────
      # 🔴 EVERY LINE BELOW THIS BLOCK DEREFERENCES `$pdoc`, AND `regen` RENAMES IT. `plan-registry-cli.py
      # regen` moves both the local plan file and the KB document and rewrites every reference INSIDE the
      # registry — it contains zero references to `plan-bind`, so this binding keeps naming the old path.
      # The `[ ! -f "$pdoc" ]` guard on the next branch then returned first and this whole tier reported
      # "contributed nothing", silently, for a session that had named its plan perfectly well.
      #
      # `entry:<ID>` (written by `plan-bind.sh` since fleet-doctrine 0.35.0, knowledge#5748) is the key a
      # rename cannot break: an id is not a location. When it is present and RESOLVES we are done here —
      # no file is opened, so neither a renamed nor a deleted plan document can defeat it.
      #
      # 🔴 AN UNRESOLVABLE id DEGRADES TO THE PATH AND SAYS SO — it never refuses. An id can name an entry
      # this clone has not pulled yet, or one `regen` re-minted; the path walk below is still a real
      # answer, and turning a NEW field into a new way to fail would be strictly worse than the
      # path-only behaviour it replaces. The note rides on `$t3`, which is what the refusal comment
      # prints, so the degrade is visible rather than inferred.
      #
      # 🔴 A BINDING WITH NO `entry:` TAKES NONE OF THIS. `plan_bind_entry_id` yields the empty string for
      # an absent field, `$bidnote` stays empty, and the two branches below are byte-for-byte what they
      # were — the migration is backward-compatible by construction, not by a flag.
      bidnote=""
      bid="$(plan_bind_entry_id "$bf")"
      if [ -n "$bid" ]; then
        bidf="$(plan_entry_file_for_id "$kb" "$rd" "$bid")"
        if [ -n "$bidf" ]; then
          RESOLVED_ENTRY="$bidf"
          RESOLVE_WHY="TIER 3 — the dispatching session's own plan binding, BY ID (session $CLAUDE_CODE_SESSION_ID → entry:$bid, which no rename can invalidate) → $(basename "$bidf")"
          return 0
        fi
        bidnote=" (its \`entry:$bid\` names no entry under $rd/entries, so the binding degraded to the path it also carries)"
      fi
      if [ ! -f "$pdoc" ]; then
        t3="TIER 3 contributed nothing — session $CLAUDE_CODE_SESSION_ID is bound to '$pdoc', which does not exist${bidnote}"
      else
        # Which entry is that document's? Two anchors, both on the BOUND file — never on time.
        #   A. an entry whose references name a document with this basename (a `--entry N` binding, and
        #      any binding made directly against the KB copy).
        #   B. content identity: the entry whose referenced document is byte-identical to the bound one.
        #      This is the case the criterion names — the plan document is UNCOMMITTED, so the session is
        #      bound to `~/.claude/plans/<session-slug>.md` while the entry references the KB copy the
        #      step hook made from those same bytes, under a different (title-derived) filename. It is
        #      also `find_entry()`'s own fallback in that hook, and `plan-bind.sh`'s read-back.
        # 🔴 `if` blocks, not `x && cands+=(…)`: under `set -e` (:5) a `&&` list whose FIRST half fails
        # takes the whole list's non-zero status, and that is the #3315 dead-dispatch bug in a new place.
        #
        # 🔴 FALLBACK B IS TWO PROCESSES NOW, NOT ~440 (#7159). It used to loop the entries directory
        # forking a `grep -oE` AND a `cmp` per entry — 219 entries in the live corpus on 2026-08-28 — to
        # find at most one byte-identical file. Same three questions, same order, same answer:
        #   1. ONE `grep -m1 -oH` over every entry yields `<entry>:<artifact-path>` pairs. `-m1` stops at
        #      the first matching LINE per file and `-o` prints every match ON that line; an entry's
        #      `artifact:` reference is one per line, so this is the old `| head -1` verbatim. Argument
        #      order is the glob's, which is the order the old `for` loop used.
        #   2. `cmp` still decides identity — nothing here compares hashes or trusts a size. What the
        #      size does is DECIDE WHO GETS ASKED: ONE `stat` over every candidate artifact, and only the
        #      ones whose byte count equals `$pdoc`'s are handed to `cmp`. Files of different lengths are
        #      never byte-identical, so this cannot change any verdict — and in the live corpus it takes
        #      the `cmp` count from 219 to 0-or-1. Two forks total, plus at most one `cmp`.
        #   3. AMBIGUITY STILL REFUSES. `cands` accumulates every match exactly as before; `n > 1` is
        #      still an ambiguous binding and is still declined rather than guessed.
        cands=()
        f="$(registry_file_for "$kb" "$rd" "$(basename "$pdoc")")"
        if [ -n "$f" ]; then cands+=("$f"); fi
        if [ ${#cands[@]} -eq 0 ]; then
          psize="$(stat -c%s "$pdoc" 2>/dev/null || echo -1)"
          # PASS 1 — one `grep` for every entry's first `artifact:` path. `-m1` stops at the first
          # matching LINE per file and grep emits files in argument order, so `$prev` collapsing the
          # repeats is the old `| head -1` verbatim. Entry paths carry no `:` (`entries/YYYY-MM/*.md`),
          # so `%%:*` splits the prefix unambiguously, exactly as TIER 2 does above.
          ents=(); arts=(); prev=""
          while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            cand="${hit%%:*}"
            [ "$cand" != "$prev" ] || continue
            prev="$cand"
            ents+=("$cand"); arts+=("$kb/${hit#*:}")
          done < <(grep -m1 -oHE "$rd/documents/[0-9]{4}-[0-9]{2}/[A-Za-z0-9._-]+\.md" \
                        -- "$kb/$rd"/entries/*/*.md 2>/dev/null || true)
          # PASS 2 — one `stat` for ALL of those artifacts at once. A path stat cannot read is simply
          # absent from the map, which is the old `[ -f "$kb/$art" ] || continue` by another route.
          if [ ${#arts[@]} -gt 0 ]; then
            # 🔴 `if`, never `[ … ] && asz[…]=…` — the convention this file states two screens up: an
            # `&&` list whose first half fails takes the list's status, and that is the #3315 shape.
            while IFS='|' read -r sz apath; do
              if [ -n "$apath" ]; then asz["$apath"]="$sz"; fi
            done < <(stat -c '%s|%n' -- "${arts[@]}" 2>/dev/null || true)
            for i in "${!arts[@]}"; do
              [ "${asz[${arts[$i]}]:-}" = "$psize" ] || continue
              if cmp -s "$pdoc" "${arts[$i]}"; then cands+=("${ents[$i]}"); fi
            done
          fi
        fi
        n=${#cands[@]}
        if [ "$n" -eq 1 ]; then
          RESOLVED_ENTRY="${cands[0]}"
          RESOLVE_WHY="TIER 3 — the dispatching session's own plan binding (session $CLAUDE_CODE_SESSION_ID → $(basename "$pdoc")) → $(basename "${cands[0]}")${bidnote}"
          return 0
        elif [ "$n" -gt 1 ]; then
          t3="TIER 3 contributed nothing — $n entries claim the bound document $(basename "$pdoc"); an ambiguous binding is refused rather than guessed${bidnote}"
        else
          t3="TIER 3 contributed nothing — no entry references the bound document $(basename "$pdoc") (the step hook has not minted one yet)${bidnote}"
        fi
      fi
    fi
  fi

  RESOLVE_WHY="UNRESOLVED — no entry references $ref (TIER 1), no plan document's H1 is \"$ftitle\" (TIER 2), and $t3. Proximity-based attribution stays removed (#4861); a wrong reference is worse than a missing one."
  return 0
}

# The refusal, shared by both callers: say WHY on the Feature and in the log, stamp nothing, and never
# fail the dispatch. The comment names the command that fixes it, because a refusal nobody can act on is
# just a quieter version of the wrong write.
plan_entry_refusal() {   # <repo> <feature> <ref> <why> <caller-tag>
  local repo="$1" feature="$2" ref="$3" why="$4" tag="$5"
  rlog "$tag: UNRESOLVED for $ref — $why (stamped nothing, #4464)"
  echo "  plan registry: no entry resolved for $ref — $why (nothing stamped)" >&2
  gh issue comment "$feature" --repo "$repo" --body "$(printf '%s\n' \
"**plan registry: could not resolve which plan produced this Feature — nothing was stamped.**" \
"" \
"\`$why\`" \
"" \
"Resolution tried, in order: **TIER 1** an entry already referencing \`$ref\` · **TIER 2** a plan document whose H1 is this Feature's title · **TIER 3** the dispatching session's own plan binding, \`~/.claude/state/plan-bind/\$CLAUDE_CODE_SESSION_ID\` (#4987). Proximity-based attribution — \"the newest ref-less entry within 24h\" — was removed in #4861 and is not among them." \
"" \
"Provenance is resolved from **the issue**, or from a claim the session made about ITSELF — never from whichever plan the dispatching session merely had open. That last fallback is what stamped \`gh:4458\` onto PLAN-82 (#4464). A missing reference is recoverable and visible; a wrong one is neither." \
"" \
"**If this WAS dispatched from the planning session that owns the plan**, TIER 3 found no binding for it. Bind the session once, then re-run the flip:" \
"" \
"\`\`\`bash" \
"~/.claude/plugins/cache/fleet-doctrine/fleet-doctrine/<version>/scripts/plan-bind.sh --entry <N>" \
"bash _infra/scripts/dispatch.sh --register-plan $feature" \
"\`\`\`" \
"" \
"**Otherwise, create or correct the entry and re-run the flip:**" \
"" \
"\`\`\`bash" \
"_infra/scripts/plan-registry-cli.py task create \"<the plan's H1>\" -s Dispatched \\\\" \
"  --ref \"artifact:wi/work/plans/documents/<YYYY-MM>/<YYYY-MM-DD>-<slug>.md\" --ref \"$ref\"" \
"bash _infra/scripts/dispatch.sh --register-plan $feature" \
"\`\`\`" \
"" \
"_The dispatch itself was unaffected — bookkeeping may never kill a launched run (#3315)._")" >/dev/null 2>&1 || true
  return 0
}

# ── The artifact reminder, at the one moment it can still be acted on (#4781) ────────────────────
# Feature #4121 criterion 4 — "every new plan carries its artifact URL in the plan body AND the registry
# entry" — was measurably unmet on 2026-08-09: 23 of the 41 plans created since the criterion existed
# carried nothing, body and entry agreeing in every single case, so the failure is *"nobody wrote it
# anywhere"*. `lint.yml` finding 7 now reports that daily, and a daily report is the wrong clock for a
# per-session step: it reaches a master roughly a day after the session that missed it, addressed to
# whoever happens to read the KB-drift issue rather than to the planner who still has the artifact open.
#
# The point of use is the plan's own dispatch. This is the same fact, said on the Feature, at the moment
# the plan stops being an intention — which is also the last moment the person who made the artifact is
# still around to paste its URL.
#
# 🔴 IT WARNS AND NOTHING ELSE. It never fails, never blocks, and never edits an entry: an artifact is a
# judgement made in a planning session with the operator, so a gate on its absence is a gate on his attention
# (#4781's scope fence). Like every other step in this function it returns 0 on every path — bookkeeping
# may not kill a launched run (#3315).
#
# 🔴 SILENT ON A PLAN THAT CARRIES ITS URL, and that is a requirement, not a nicety: a checker that
# comments on every dispatch is one nobody reads, which is the same as one that never fires.
plan_artifact_warning() {   # <kb> <bin> <id> <feature> <repo>
  local kb="$1" bin="$2" id="$3" feature="$4" repo="$5" out=""
  # No `--check`: an explicit id makes the exit code carry the finding, and a non-zero return from a
  # REPORTER is indistinguishable here from the CLI being broken. The finding is a LINE, so read lines.
  reg_cli "$kb" "$bin" task artifacts "$id" >/dev/null 2>&1 || true
  out="${REG_OUT:-}"
  case "$out" in *NO-ARTIFACT*|*ARTIFACT-CONFLICT*) ;; *) return 0 ;; esac
  rlog "artifact: $id dispatched with no claude.ai artifact URL — warned on #$feature (#4781)"
  echo "  plan registry: ⚠ $id carries no claude.ai artifact URL" >&2
  gh issue comment "$feature" --repo "$repo" --body "$(printf '%s\n' \
"⚠ **\`$id\` was stamped Dispatched with no claude.ai artifact URL.**" \
"" \
"\`\`\`" \
"$(printf '%s' "$out" | grep -E '^(NO-ARTIFACT|ARTIFACT-CONFLICT|artifacts:)' || true)" \
"\`\`\`" \
"" \
"A finished plan is **three** artifacts (\`doctrine/planning-loop.md\`): the registry entry, the plan document, and the claude.ai architecture page the operator actually reads. Without the third, this Feature's row on the OCC renders an honest blank — and a blank cannot be told apart from a plan that deliberately produced nothing." \
"" \
"**If the artifact exists**, put the URL in the plan body *and* on the entry — the entry reference is the only thing that fills the OCC's Artifact column:" \
"" \
"\`\`\`bash" \
"_infra/scripts/plan-registry-cli.py task edit $id --add-ref '<paste the whole claude.ai artifact link>'" \
"\`\`\`" \
"" \
"(Paste the link exactly as claude.ai gave it — \`https://claude.ai/artifact/<id>\` and the older \`https://claude.ai/code/artifact/<uuid>\` are both recognised, with or without a \`<title>-\` slug. This example used to name the long form alone, and the matcher behind it only accepted that one: PLAN-307/311/312 each recorded a real short-form URL and were reported as carrying none anyway — #7900.)" \
"" \
"\`\`\`bash" \
"_infra/scripts/plan-registry-cli.py task refs $id   # read back what landed" \
"\`\`\`" \
"" \
"(\`--add-ref\` APPENDS — it merges under a lock inside the CLI, so it cannot drop a reference another shell just added. \`--ref\` REPLACES the whole list and needs a \`task refs $id\` read-back first; #4997.)" \
"" \
"**If there is no artifact to link**, record which kind of absence it is and the report goes quiet for the right reason — \`artifact:none\` if this plan deliberately produced none (a plan concluding *\"do not build this\"* is complete with nothing to render), \`artifact:unrecorded\` if one existed and its URL is gone:" \
"" \
"\`\`\`bash" \
"_infra/scripts/plan-registry-cli.py task edit $id --add-ref 'artifact:none'" \
"\`\`\`" \
"" \
"🔴 Neither token means *\"not yet\"*. Of the 23 plans that reached this state before the warning existed, **2** were recoverable and **21** were not — a URL nobody writes down in the session is gone (#4781)." \
"" \
"_Advisory. The dispatch was unaffected and nothing here blocks — the URL is a judgement from a planning session, never something a script can supply (#4781)._")" >/dev/null 2>&1 || true
  return 0
}

# ── Push with retry — retries once with fetch+rebase on failure, then exits non-zero ───────────
# Pattern from occ-usage-publish.sh:301-312 — the documented remedy for push failures.
# Usage: push_with_retry <kb> <log-prefix>
# Returns: 0 on success, non-zero on failure (after 2 attempts)
# 🔴 This MUST return non-zero on failure — a silent success is how PLAN-124 became invisible.
push_with_retry() {
  local kb="$1" prefix="$2"
  local push_err

  # 🔴 #7158 — THE STATE CHECK COMES BEFORE THE on-main CHECK, and that order is the point. A clone with
  # a rebase in progress has a DETACHED HEAD, so `--abbrev-ref HEAD` prints `HEAD`, the on-main test is
  # false, and this used to `return 0` — a silent success reported out of a half-finished rebase.
  if git_state_unclean "$kb"; then
    rlog "$prefix: refusing to push — $GIT_STATE_WHY"
    echo "  ⚠ $prefix: push refused — $GIT_STATE_WHY" >&2
    return 1
  fi

  # Only push from main — on a topic branch the commit rides out with the next push
  [ "$(git -C "$kb" rev-parse --abbrev-ref HEAD 2>/dev/null)" = main ] || return 0

  for attempt in 1 2; do
    if push_err="$(git -C "$kb" push -q 2>&1)"; then
      rlog "$prefix: push succeeded"
      return 0
    fi
    rlog "$prefix: push attempt $attempt failed: $push_err"

    # After first attempt, fetch and rebase before retry
    if [ "$attempt" -eq 1 ]; then
      rlog "$prefix: fetching and rebasing origin/main before retry"
      if ! git -C "$kb" fetch origin -q 2>&1; then
        rlog "$prefix: fetch failed"
        echo "  ⚠ $prefix: push failed (fetch failed — ${push_err:-no error message})" >&2
        return 1
      fi
      # 🔴 #7158 — THE REBASE REFUSES A TREE IT SHOULD NOT TOUCH. This clone is SHARED: the Architect's
      # in-flight work lives in it, which is why the registry commit is path-scoped in the first place.
      # `git rebase` itself refuses on a dirty tree, so this changes no outcome — it changes the RECORD,
      # from "rebase failed" (indistinguishable from a conflict) to the actual reason, in the log.
      if ! git -C "$kb" diff --quiet 2>/dev/null || ! git -C "$kb" diff --cached --quiet 2>/dev/null; then
        rlog "$prefix: refusing to rebase — $kb has uncommitted changes (shared clone)"
        echo "  ⚠ $prefix: push failed (refusing to rebase a dirty shared clone — ${push_err:-no error message})" >&2
        return 1
      fi
      if ! git -C "$kb" rebase origin/main -q 2>&1; then
        # 🔴 #7158 — LEAVE NO REBASE STATE BEHIND. A conflicted rebase returns 1 and leaves the clone
        # mid-rebase; the NEXT dispatch's `git add` then inherits that state and every git write after
        # it is wrong. Aborting restores the tip this run found.
        git -C "$kb" rebase --abort >/dev/null 2>&1 || true
        rlog "$prefix: rebase failed — aborted, clone restored to its pre-rebase tip"
        echo "  ⚠ $prefix: push failed (rebase failed and was aborted — ${push_err:-no error message})" >&2
        return 1
      fi
    fi
  done

  rlog "$prefix: push failed after 2 attempts: $push_err"
  echo "  ⚠ $prefix: push failed after 2 attempts — ${push_err:-no error message}" >&2
  return 1
}

# ── The registry commit: one writer at a time, and every failure is READ (#7158) ───────────────
# 🔴 WHAT THIS REPLACES, AND WHY IT REPORTED SUCCESS WHILE COMMITTING NOTHING. Both registration paths
# ended in this shape:
#
#     git -C "$kb" add -- "$rd" >/dev/null 2>&1 || true
#     if ! git -C "$kb" diff --cached --quiet -- "$rd" 2>/dev/null; then …commit… fi
#     return 0
#
# Two dispatches on one box share ONE `.git/index`. One `git add` loses `.git/index.lock`; **`|| true`
# swallows that failure**; `diff --cached` then sees nothing staged for this dispatch, so the `if` is
# false and the function returns 0 HAVING WRITTEN NOTHING. `rlog` had already recorded the `task edit`
# as successful, so the log claims success too. The entry is edited on disk, never committed, never
# pushed — invisible in the OCC, with nothing anywhere saying so (measured 2026-08-28, #7158).
#
# Three repairs, each aimed at one of the three races in that block:
#   1. an exclusive `flock` around add+commit+push, so two of OUR OWN dispatches QUEUE rather than
#      collide. The registry CLI's own `flock` (`plan-registry-cli.py:267`) already serialises the YAML
#      write and is deliberately untouched; this serialises the GIT half, which had no lock at all.
#   2. the add's and the commit's exit status is READ. A collision LOGS, prints a ⚠ on stderr, and
#      returns non-zero. Nothing about a lost lock can reach a caller as success.
#   3. the pathspec is THIS dispatch's own files, never the whole registry directory. `add -- "$rd"`
#      was path-scoped to a directory BOTH dispatches write, so A's commit swept B's edit up under A's
#      message — the content survived and the history lied about which dispatch produced which entry.
#
# 🔴 "Nothing staged" is a REAL no-op here, and it is only distinguishable from a swallowed failure
# because the add's status was read first: add succeeded ⇒ these paths already match HEAD ⇒ a peer that
# held the lock before us committed this same content. That is the one case where writing nothing is
# correct, and it says so in the log rather than being silent.
# 🔴 THE WAIT IS A MEASUREMENT, NOT A PRECAUTION (core-behaviors.md). Measured on fleet-host 2026-08-28:
# a github.com remote round trip is 1.68/1.89/1.93/1.94/2.35 s (`git ls-remote origin -h refs/heads/main`
# ×5), and the whole serialised section is add + commit + push — with `push_with_retry`'s worst path
# (push, fetch, rebase, push) that is four remote ops, ~10 s, plus ~0.7 s of local git. So one holder
# costs ~2-12 s and 120 s is room for roughly 10-60 QUEUED dispatches, an order of magnitude past the
# parallel-dispatch fan-out this Feature is building toward. Raise it with the env var, not a guess.
REGISTRY_COMMIT_WAIT="${REGISTRY_COMMIT_WAIT:-120}"   # seconds to wait for a peer dispatch's git half

GIT_STATE_WHY=""   # why the clone is unwriteable; set by git_state_unclean

git_dir_of() {   # <kb> → absolute .git dir (handles a worktree's `.git` FILE), empty if not a clone
  local g
  g="$(git -C "$1" rev-parse --git-dir 2>/dev/null)" || return 1
  case "$g" in /*) ;; *) g="$1/$g" ;; esac
  printf '%s' "$g"
}

# A clone mid-rebase / mid-merge / mid-cherry-pick is a tree NO dispatch may write into: its HEAD is not
# the branch anyone thinks it is, and a commit landed there is landed onto someone else's conflict.
git_state_unclean() {   # <kb> → 0 (TRUE) when the clone must not be written to; sets GIT_STATE_WHY
  local g
  GIT_STATE_WHY=""
  g="$(git_dir_of "$1")" || { GIT_STATE_WHY="$1 is not a git clone"; return 0; }
  [ -n "$g" ] || { GIT_STATE_WHY="$1 is not a git clone"; return 0; }
  if   [ -d "$g/rebase-merge" ] || [ -d "$g/rebase-apply" ]; then GIT_STATE_WHY="a rebase is in progress in $1"
  elif [ -f "$g/MERGE_HEAD" ];       then GIT_STATE_WHY="a merge is in progress in $1"
  elif [ -f "$g/CHERRY_PICK_HEAD" ]; then GIT_STATE_WHY="a cherry-pick is in progress in $1"
  elif [ -f "$g/REVERT_HEAD" ];      then GIT_STATE_WHY="a revert is in progress in $1"
  else return 1
  fi
  return 0
}

# Usage: commit_registry_paths <kb> <log-prefix> <commit-message> <path>…
# Returns 0 only when the paths are committed (or provably already committed) AND pushed.
commit_registry_paths() {
  local kb="$1" prefix="$2" msg="$3"; shift 3
  local lock rc=0
  [ "$#" -gt 0 ] || { rlog "$prefix: commit_registry_paths called with no paths"; return 1; }

  lock="$(git_dir_of "$kb")" || lock=""
  if [ -z "$lock" ] || ! command -v flock >/dev/null 2>&1 || ! ( : >>"$lock/dispatch-registry.lock" ) 2>/dev/null; then
    # No lock available is NOT a reason to skip the commit — it is a reason to say so. The status
    # checks below are what actually stop a silent success; the lock only stops the collision.
    rlog "$prefix: no cross-dispatch commit lock available — committing unserialised"
    _commit_registry_locked "$kb" "$prefix" "$msg" "$@" || rc=$?
    return $rc
  fi
  lock="$lock/dispatch-registry.lock"

  {
    if flock -w "$REGISTRY_COMMIT_WAIT" 9; then
      _commit_registry_locked "$kb" "$prefix" "$msg" "$@" || rc=$?
    else
      rlog "$prefix: registry commit lock held by a peer dispatch for >${REGISTRY_COMMIT_WAIT}s — NOT committed"
      echo "  ⚠ $prefix: registry NOT committed — a peer dispatch held the commit lock for >${REGISTRY_COMMIT_WAIT}s" >&2
      rc=1
    fi
  } 9>"$lock" || rc=$?
  return $rc
}

_commit_registry_locked() {   # <kb> <log-prefix> <commit-message> <path>…  — call under the flock
  local kb="$1" prefix="$2" msg="$3"; shift 3
  local out committed=0 ahead

  if git_state_unclean "$kb"; then
    rlog "$prefix: refusing to commit — $GIT_STATE_WHY"
    echo "  ⚠ $prefix: registry NOT committed — $GIT_STATE_WHY" >&2
    return 1
  fi

  # 🔴 #8603 — ON main IN A CLONE HOLDING SOMEONE ELSE'S UNCOMMITTED FILES, PUBLISH THROUGH A WORKTREE.
  # A commit made here needs `push_with_retry` to get out, and its one remedy for a refused push is a
  # rebase it (correctly) refuses in a dirty shared clone — so behind + dirty left the commit on local
  # main, the clone DIVERGED, and it could never fast-forward again (the Architect's clone: ahead 53 /
  # behind 232). `plan-registry-publish.sh` commits on a throwaway worktree off origin/main instead and
  # never writes this clone's branch. A CLEAN clone keeps the path below: there the rebase is safe.
  # `-uno` — tracked files only, the same thing `git rebase` refuses on.
  local pub; pub="$(dirname "${BASH_SOURCE[0]}")/plan-registry-publish.sh"
  if [ -f "$pub" ] && [ "$(git -C "$kb" rev-parse --abbrev-ref HEAD 2>/dev/null)" = main ] \
     && [ "$(git -C "$kb" status --porcelain -uno 2>/dev/null | wc -l)" -gt "$(git -C "$kb" status --porcelain -uno -- "$@" 2>/dev/null | wc -l)" ]; then
    if out="$(PLAN_REGISTRY_PUBLISH_LOCKED=1 bash "$pub" "$kb" "$msg" "$@" 2>&1)"; then
      rlog "$prefix: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
      return 0
    fi
    out="$(printf '%s' "${out:-no error message}" | tr '\n' ' ' | cut -c1-300)"
    rlog "$prefix: worktree publish failed — $out"
    echo "  ⚠ $prefix: registry NOT published — $out" >&2
    return 1
  fi

  # 🔴 NO `|| true`. This is the swallow #7158 reports, and reading the status is the whole fix.
  if ! out="$(git -C "$kb" add -- "$@" 2>&1)"; then
    rlog "$prefix: git add failed — ${out:-no error message}"
    echo "  ⚠ $prefix: registry NOT committed — git add failed (${out:-no error message})" >&2
    return 1
  fi

  if git -C "$kb" diff --cached --quiet -- "$@" 2>/dev/null; then
    rlog "$prefix: nothing staged and the add SUCCEEDED — these paths already match HEAD (peer committed them)"
  else
    if ! out="$(git -C "$kb" commit -q -m "$msg" -- "$@" 2>&1)"; then
      rlog "$prefix: commit failed — ${out:-no error message}"
      echo "  ⚠ $prefix: registry NOT committed — git commit failed (${out:-no error message})" >&2
      return 1
    fi
    committed=1
    rlog "$prefix: committed $(git -C "$kb" rev-parse --short HEAD 2>/dev/null) — $*"
  fi

  # Push when we committed, and ALSO when the branch is merely ahead: a peer that committed our content
  # while we waited pushes its own, but a commit stranded by an earlier failed push must still get out.
  ahead="$(git -C "$kb" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
  case "$ahead" in ''|*[!0-9]*) ahead=0 ;; esac
  if [ "$committed" -eq 1 ] || [ "$ahead" -gt 0 ]; then
    if ! push_with_retry "$kb" "$prefix"; then
      rlog "$prefix: push failed (commit is local) — plan may be invisible in OCC until manual push"
      # 🔴 #5122 — non-zero on push failure so the caller knows the entry didn't reach remote.
      return 1
    fi
  fi
  return 0
}

# 🔴 #8603 — A REGISTRY WRITE THAT DID NOT REACH origin/main IS SAID ON THE ISSUE. The ⚠ above goes to
# this process's stderr and the dispatch log, and neither is somewhere the operator looks; the board is. One
# comment, best-effort, carrying the reason the log already holds. Never fails the dispatch.
registry_unpublished_notice() {   # <issue> <repo> <plan-id> <ref>
  local why
  why="$(grep -E ' (flip|sweep-reg): ' "${PLAN_REGISTRY_LOG:-/dev/null}" 2>/dev/null | tail -1 | sed "s#${HOME:-/nonexistent}#~#g" | cut -c1-400)"
  gh issue comment "$1" --repo "$2" --body "⚠ **Plan registry: \`$3\` → Dispatched (+\`$4\`) was written on the dispatching box but did not reach \`origin/main\`**, so the OCC does not show this dispatch under $3 yet.

Last registry log line: \`${why:-<none recorded>}\`

The run itself is unaffected. The next dispatch from that box retries the write.

_Posted by \`dispatch.sh\` because the registry commit or its push failed (#8603). Nothing was stashed, reset or rebased._" >/dev/null 2>&1 || true
  return 0
}

register_plan_dispatched() {   # <issue> <repo>
  local issue="$1" repo="$2" kb bin rd f id feature ref refs a title phases
  local -a paths   # #7158 — the pathspec this dispatch commits. Since #7159 there is no document copy to
                   # add to it: the only path this function writes is the resolved entry.
  local refargs   # #4526 — an undeclared global, shared across the two registration paths
                  # (#4997 dropped `newrefs` with the shell-side merge it accumulated)

  # 🔴 #4873 / #7159 — THERE IS NO SESSION PLAN FILE IN THIS FUNCTION ANY MORE, and nothing here
  # asks which plan the dispatching session has open. Since #4464 the entry is resolved FROM THE ISSUE
  # (`resolve_plan_entry`), and the only thing `$plan` was still read for — re-copying the session's plan
  # document into `plans/documents/` — was keeping honest a `STEP 8` stamp that `advance_plan_step` stopped
  # writing when its call site was disabled. #7159 deleted the resolver, the stamper and the re-copy
  # together; the tombstone at the top of this file has the measurements and says what to use instead.
  #
  # 🔴 IT STILL RETURNS 0 ON EVERY PATH AND STILL SAYS WHY (#3315). A dispatch with no owning plan
  # reaches resolve_plan_entry, which refuses on anything it cannot prove and comments that refusal ON THE
  # FEATURE (plan_entry_refusal) — the failure lands on the board, not in a local log nobody reads.
  kb="$(knowledge_dir)";                 [ -d "$kb/.git" ] || { rlog "flip: no knowledge clone"; return 0; }
  bin="$(backlog_bin "$kb")";            [ -n "$bin" ] || { rlog "flip: backlog CLI absent (#3546 not landed?)"; return 0; }
  rd="$(backlog_registry_dir "$kb")";    [ -n "$rd" ] || { rlog "flip: no backlog config in $kb"; return 0; }
  # 🔴 #4464 — NEVER the dispatching session's own plan’s phase count. The entry this dispatch flips
  # is resolved from the issue, so it is routinely a DIFFERENT plan's entry than the one that session has
  # open — and writing the open plan's count onto it would re-create the very defect being fixed, one
  # field over. The count is re-derived below from the RESOLVED entry's own artifact, exactly as the
  # sweeper twin does it. 0 here means "declare nothing", which is what an unresolvable count must render
  # as (#4322). (#7159: the session's plan file is no longer readable from here at all.)
  phases=0

  # The reference is the FEATURE, not the task: a plan becomes one or more Features, and the derivation
  # rule ("all referenced Features closed → Executed") is a question about Features. Sub-issue parent via
  # the REST endpoint; a dispatch of a Feature itself has no parent and references itself.
  # Bare `gh:N` means "this repo" per the convention doc — so a cross-repo dispatch is qualified instead
  # of being silently mis-resolved as a knowledge issue.
  feature="$(gh api "repos/$repo/issues/$issue/parent" --jq '.number' 2>/dev/null || true)"
  # DIGITS-ONLY, not just non-empty: `gh api` prints the error BODY to stdout on a 404, and a Feature-level
  # dispatch legitimately 404s here ("No parent issue found"). Exercised 2026-08-01 — the unchecked version
  # wrote three garbage references per dispatch, one of them a documentation URL. A non-numeric answer means
  # "no parent", which means this issue IS the Feature.
  case "$feature" in ''|*[!0-9]*) feature="$issue" ;; esac
  if [ "$repo" = "example-org/kb" ]; then ref="gh:$feature"; else ref="gh:$repo#$feature"; fi

  # 🔴 #4464 — THE ENTRY IS RESOLVED FROM THE ISSUE, NEVER FROM `$plan`. What used to stand here was
  # `registry_file_for "$base"` — the entry of whatever plan THIS SESSION had open — with `ref_owner` as a
  # partial correction on top (#3665) and, when that found nothing, a create-as-Dispatched keyed on the
  # session plan's own H1. That last branch IS the reported defect: dispatching #4460 from a session still
  # holding PLAN-82's plan file found no owner for `gh:4458` and so appended it to PLAN-82, a plan that did
  # not produce it (retracted in bcf7e92a). The session's open file was never evidence, so it is gone.
  #
  # The create branch went with it, deliberately. An unregistered plan now gets a REFUSAL naming the
  # `plan-registry-cli.py task create` one-liner rather than an entry invented from whichever document
  # happened to be open — the same trade the rest of this function already makes: "a missed flip is
  # recoverable and visible, a silently wrong write is neither".
  resolve_plan_entry "$kb" "$rd" "$ref" "$repo" "$feature"
  f="$RESOLVED_ENTRY"
  if [ -z "$f" ]; then
    plan_entry_refusal "$repo" "$feature" "$ref" "$RESOLVE_WHY" "flip"
    return 0
  else
    rlog "flip: resolved $ref → $(basename "$f") — $RESOLVE_WHY"
    id="$(sed -nE "s/^id:[[:space:]]*['\"]?([A-Za-z0-9_.-]+)['\"]?[[:space:]]*\$/\1/p" "$f" | head -1)"
    [ -n "$id" ] || { rlog "flip: no id in $f"; return 0; }
    # `--ref` REPLACES the reference list, so the existing refs are read back and re-supplied. A plan
    # routinely dispatches several Features; each dispatch must ADD one, never drop the others.
    # Read back through the CLI, never by parsing the YAML here. The first version used a regex over the
    # frontmatter and it DROPPED a real reference on its first live run (2026-08-01, PLAN-1): a long value
    # is a FOLDED SCALAR — `- >-` on one line, the value indented on the next — which no single-line item
    # pattern matches, and 40 of the 84 live entries carry at least one.
    # #4526 — the read-back's own failure is no longer swallowed: a miss now says which id was not found
    # and how many entries were scanned, instead of arriving as an indistinguishable empty string below.
    if ! reg_cli "$kb" "$bin" task "$id" --plain; then
      echo "  plan registry: cannot read $id back — ${REG_OUT:-<no output>}" >&2
      rlog "flip: refusing to edit $id — read-back failed"; return 0
    fi
    refs="$(printf '%s\n' "$REG_OUT" \
             | sed -n 's/^References:[[:space:]]*//p' | head -1 | tr ',' '\n' \
             | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
    # 🔴 The entry was FOUND by a reference naming this plan, so it provably has one. If the read-back is
    # empty the parse is wrong, and writing would DELETE the entry's references. Refuse the write instead:
    # a missed flip is recoverable and visible, a silently emptied reference list destroys the trace this
    # whole feature exists to keep.
    [ -n "$(printf '%s' "$refs" | tr -d '[:space:]')" ] \
      || { rlog "flip: refusing to edit $id — could not read its references back"; return 0; }
    # #4464 — the phase count comes from THE RESOLVED ENTRY's own plan document, never from the session's
    # open plan. 🔴 #4629 — read the artifact refs from `$refs` (the CLI's own read-back), NEVER with a sed
    # over the raw YAML: the corpus writes a reference three ways — bare, single-quoted, and folded
    # (`- >-` + a continuation) — and a `- artifact:` pattern matches only the bare third of them.
    phases=0
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      case "$a" in *://*) continue ;; esac   # a claude.ai artifact URL is not a plan document
      if [[ "$a" =~ ^/ ]]; then title="$a"; else title="$kb/$rd/$a"; fi
      [ -f "$title" ] || continue
      phases="$(plan_phase_count "$title")" 2>/dev/null || phases=0
      case "$phases" in ''|*[!0-9]*) phases=0 ;; esac
      break
    done < <(printf '%s\n' "$refs" | sed -n 's/^artifact://p')
    # #4322 — every ref EXCEPT a stale `phases:` is re-supplied verbatim; the count is re-derived from the
    # plan as it stands now, so a plan that grew a phase between approval and dispatch declares the new
    # number rather than the one captured hours earlier. A plan that declares NONE keeps whatever the entry
    # already carried: re-deriving 0 must never DELETE a count someone recorded (that would turn a known
    # number into an absence, silently).
    # 🔴 #4629 — the artifact ref is preserved by the RE-SUPPLY LOOP BELOW and nowhere else. #4418 added a
    # second, appended copy to stop it being dropped; the drop it compensated for is gone, so the append
    # only double-wrote — a flip on PLAN-72 turned one `artifact:` ref into two, and the OCC renders the
    # second as a phantom artifact. Do not re-add an append here: `$refs` is the CLI's own read-back, so it
    # already carries EVERY artifact ref (PLAN-73 legitimately has three), unquoted and unfolded.
    # 🔴 #4997 — THE MERGE HAPPENS INSIDE THE CLI NOW, NOT HERE. This used to rebuild the whole list in
    # shell from the read-back above and pass it all back with `--ref`, which REPLACES. Between the
    # read-back and the write, a second architect shell (the operator runs 2-4) could land a reference this
    # call had never seen — and this write then deleted it. Measured on a copy of the live registry:
    # two concurrent dispatches, `gh:99991 PRESENT / gh:99992 LOST`.
    # `--add-ref` appends if absent and `--set-ref` replaces one key, both under an exclusive `flock`
    # held across the CLI's own read — so no window exists between the read and the write at all.
    # `--add-ref` also subsumes the old `[ "$a" = "$ref" ] && continue` dedupe: re-adding a reference
    # that is already there is a no-op, not a second copy.
    refargs=(--add-ref "$ref")
    # `--set-ref phases:N` replaces whatever `phases:` the entry carries, so a plan that grew a phase
    # between approval and dispatch declares the new number. A plan that declares NONE (`phases=0`)
    # passes no flag at all and KEEPS whatever was recorded — re-deriving 0 must never turn a known
    # count into an absence (#4322). `gh:` is deliberately NOT set this way: it is multi-valued, and a
    # plan routinely dispatches several Features.
    if [ "$phases" -gt 0 ]; then refargs+=(--set-ref "phases:$phases"); fi
    if ! reg_cli "$kb" "$bin" task edit "$id" -s Dispatched --plain "${refargs[@]}"; then
      echo "  plan registry: WRITE FAILED for $id — ${REG_OUT:-<no output>}" >&2
      rlog "flip: task edit $id failed"; return 0
    fi
    rlog "flip: $id → Dispatched (+$ref)"
    # 🔴 #7158 — the stdout confirmation moved BELOW the commit. It used to print here, before a commit
    # that could then write nothing, so a swallowed lock collision printed a success line and no failure.
    # #4781 — AFTER the stamp, never before: the warning is about a plan that is now provably being
    # executed, and reporting one for a stamp that then failed to land would be noise about nothing.
    plan_artifact_warning "$kb" "$bin" "$id" "$feature" "$repo" || true
  fi

  # 🔴 #7158 — PATH-SCOPED TO THIS DISPATCH'S OWN FILES, not to `$rd`. The old pathspec was the registry
  # DIRECTORY, which both concurrent dispatches write: A's `commit -- "$rd"` swept B's edit up under A's
  # message, and B then found nothing staged and committed nothing. The resolved entry is exactly what
  # this dispatch changed — and since #7159 it is the ONLY thing: the second element this array used to
  # carry was the plan document this run re-copied, and that re-copy is deleted (see the tombstone at the
  # top of this file). The array shape stays because it is the pathspec's contract, and #7158's guarantee
  # is unchanged: one dispatch commits one dispatch's files.
  paths=("$f")
  if ! commit_registry_paths "$kb" "flip" "plans: dispatch #$issue → Dispatched, +$ref (#3547)" "${paths[@]}"; then
    registry_unpublished_notice "$issue" "$repo" "$id" "$ref"
    # The call site has `|| true` to prevent killing the dispatch (#3315), but the non-zero return and
    # the ⚠ on stderr make the failure visible — which is the whole of #7158.
    return 1
  fi
  echo "  plan registry: $id → Dispatched (+$ref)"
  return 0
}

# ── Sweeper support: update plan registry from issue number (no session context) ─────────────
# Used by sweep-dispatch.sh to write the same registry state that register_plan_dispatched writes.
# Resolves the entry through the shared resolve_plan_entry() ladder, then writes the gh: reference.
# (#4337; #4464 made the resolver shared rather than a second copy.)
#
# "no session context" is no longer what distinguishes this from its twin — since #4464 NEITHER path uses
# session context to choose an entry. What is left is the call contract: this one returns non-zero on an
# unresolved entry so the sweeper can count it, the twin returns 0. Same decision, two callers.
register_plan_from_issue() {   # <issue> <repo>
  local issue="$1" repo="$2" kb bin rd feature ref f id refs a refargs
  local phases artifact_ref artifact_path

  # Get knowledge base location (same logic as register_plan_dispatched)
  kb="$(knowledge_dir)";                 [ -d "$kb/.git" ] || { rlog "sweep-reg: no knowledge clone"; return 1; }
  bin="$(backlog_bin "$kb")";            [ -n "$bin" ] || { rlog "sweep-reg: backlog CLI absent (#3546 not landed?)"; return 1; }
  rd="$(backlog_registry_dir "$kb")";    [ -n "$rd" ] || { rlog "sweep-reg: no backlog config in $kb"; return 1; }

  # Get parent Feature number (same logic as register_plan_dispatched)
  feature="$(gh api "repos/$repo/issues/$issue/parent" --jq '.number' 2>/dev/null || true)"
  case "$feature" in ''|*[!0-9]*) feature="$issue" ;; esac

  # Build gh: reference (same logic as register_plan_dispatched lines 452-458)
  if [ "$repo" = "example-org/kb" ]; then ref="gh:$feature"; else ref="gh:$repo#$feature"; fi

  # 🔴 #4464 — ONE RESOLVER, shared with register_plan_dispatched. This function used to hold the only
  # issue-derived tier ladder in the file while the interactive path resolved from session state. The
  # ladder moved to resolve_plan_entry() verbatim (TIER 1 ref_owner → TIER 2 artifact-H1 == Feature title
  # → TIER 3, now the dispatching session's own plan binding, #4987). Behaviour here is unchanged; the
  # interactive twin is what moved onto it.
  resolve_plan_entry "$kb" "$rd" "$ref" "$repo" "$feature"
  f="$RESOLVED_ENTRY"
  case "$RESOLVE_WHY" in
    "TIER 1 — "*)   # idempotent: already registered, nothing to write
      rlog "sweep-reg: OK — $RESOLVE_WHY"
      echo "  plan registry: $ref already registered in $(basename "$f")"
      return 0 ;;
  esac
  if [ -z "$f" ]; then
    plan_entry_refusal "$repo" "$feature" "$ref" "$RESOLVE_WHY" "sweep-reg"
    # 🔴 EXIT 3 = "THIS FEATURE HAS NO OWNING PLAN", WHICH IS A FACT AND NOT A FAILURE (#6616) ────────
    # This used to `return 1`, and 1 is what sweep-dispatch.sh counts as REG_FAILED — so a Feature that
    # genuinely came from no plan (#6595, a bug found during verification; #5609/#5785/#5908/#5966, the
    # standing-hygiene rows) reported a registration FAILURE on every single dispatch under it, forever.
    # `reg-failed` therefore could not distinguish "the write broke" from "there was nothing to write",
    # which is the same could-not-check-reads-as-broken defect the fleet keeps re-shipping: four of the
    # six Features parenting open work on 2026-08-23 have no plan and never will.
    #
    # 3 is NOT silence. The refusal comment above still lands on the Feature, `rlog` still records it,
    # and the sweeper counts it under its own name (`no-plan=`) on the same heartbeat line — so nothing
    # that was visible before is hidden now, it is simply counted as what it is. Every OTHER return 1 in
    # this function (no clone, no CLI, read-back failed, write failed, commit failed, push failed) is a
    # real registration failure and still reports as one.
    return 3
  fi
  rlog "sweep-reg: OK — resolved $ref → $(basename "$f") — $RESOLVE_WHY"

  # ENTRY FOUND — update with Dispatched status and gh: reference
  id="$(sed -nE "s/^id:[[:space:]]*['\"]?([A-Za-z0-9_.-]+)['\"]?[[:space:]]*\$/\1/p" "$f" | head -1)"
  [ -n "$id" ] || { rlog "sweep-reg: no id in $f"; return 1; }

  # #4526 — the read-back's own failure survives instead of being sent to /dev/null, so the refusal below
  # can say WHICH failure it was rather than "could not read its references back" for every cause.
  if ! reg_cli "$kb" "$bin" task "$id" --plain; then
    rlog "sweep-reg: refusing to edit $id — read-back failed"; return 1
  fi
  refs="$(printf '%s\n' "$REG_OUT" \
           | sed -n 's/^References:[[:space:]]*//p' | head -1 | tr ',' '\n' \
           | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
  [ -n "$(printf '%s' "$refs" | tr -d '[:space:]')" ] \
    || { rlog "sweep-reg: refusing to edit $id — could not read its references back"; return 1; }

  # Derive phases from the plan document the entry points at, if one of its artifact refs is a path that
  # exists. 🔴 #4629 — read the refs from `$refs` (the CLI's own read-back), NEVER with a sed over the raw
  # YAML: the corpus writes a reference three ways — bare, single-quoted (`emit_ref` under 80 cols), and
  # folded (`- >-` + a continuation line) — and a `- artifact:` pattern matches only the bare third of it.
  # Measured on the live registry: PLAN-72 (bare) matched, PLAN-16 (quoted) and PLAN-92/73 (folded) did not.
  # The read-back is already unquoted and unfolded, so all three forms resolve and no quote can be captured.
  phases=0
  while IFS= read -r artifact_ref; do
    [ -n "$artifact_ref" ] || continue
    case "$artifact_ref" in *://*) continue ;; esac   # a claude.ai artifact URL is not a plan document
    if [[ "$artifact_ref" =~ ^/ ]]; then
      artifact_path="$artifact_ref"
    else
      artifact_path="$kb/$rd/$artifact_ref"
    fi
    [ -f "$artifact_path" ] || continue
    phases="$(plan_phase_count "$artifact_path")" 2>/dev/null || phases=0
    case "$phases" in ''|*[!0-9]*) phases=0 ;; esac
    break
  done < <(printf '%s\n' "$refs" | sed -n 's/^artifact://p')

  # 🔴 #4997 — same conversion as the flip path above, and for the same reason: this rebuilt the whole
  # list in shell and wrote it back with `--ref` (a REPLACE), so anything a concurrent shell landed
  # between the read-back and the write was deleted. `--add-ref`/`--set-ref` merge inside the CLI, under
  # a lock that covers its own read. Every reference the entry already carries is preserved by NOT being
  # mentioned — including all three of PLAN-73's artifact refs, which #4629 had to protect explicitly
  # when the list was rebuilt by hand.
  refargs=(--add-ref "$ref")
  if [ "$phases" -gt 0 ]; then refargs+=(--set-ref "phases:$phases"); fi
  if ! reg_cli "$kb" "$bin" task edit "$id" -s Dispatched --plain "${refargs[@]}"; then
    echo "  plan registry: WRITE FAILED for $id — ${REG_OUT:-<no output>}" >&2
    rlog "sweep-reg: task edit $id failed"; return 1
  fi
  rlog "sweep-reg: OK $id → Dispatched (+$ref)"
  # #7158 — the stdout confirmation moved BELOW the commit, same reason as the flip path.
  # #4781 — the sweeper is how MOST plans are stamped, so the reminder has to live on both paths or it
  # reaches the smaller half of dispatches. Same call, same silence on a plan that carries its URL.
  plan_artifact_warning "$kb" "$bin" "$id" "$feature" "$repo" || true

  # Commit and push the registry update — same helper as the flip path, so the two cannot drift again
  # (#7158; they were verbatim copies of the swallowing block, and both swallowed).
  if ! commit_registry_paths "$kb" "sweep-reg" "plans: dispatch #$issue → Dispatched, +$ref (#4337)" "$f"; then
    registry_unpublished_notice "$issue" "$repo" "$id" "$ref"
    return 1
  fi
  echo "  plan registry: $id → Dispatched (+$ref)"
  return 0
}

# Dry-run hook, same shape as `--resolve` (:146): `dispatch.sh --register-plan <issue> [repo]` runs the
# flip WITHOUT launching anything. Two jobs — it makes #3547's acceptance ("exercise both transitions")
# repeatable by anyone at any time instead of only observable by starting a real run, and it is how a plan
# dispatched before this landed gets its entry without a fake dispatch. Exercising the production function
# itself, never a copy: a test that runs a duplicate proves nothing about the path that runs.
if [ "${1:-}" = "--register-plan" ]; then
  register_plan_dispatched "${2:?usage: dispatch.sh --register-plan <issue#> [owner/repo]}" \
                           "${3:-example-org/kb}"
  exit $?
fi

# Sweeper support: register plan from issue number (no session context) (#4337)
# Usage: dispatch.sh --register-from-issue <issue#> [repo]
if [ "${1:-}" = "--register-from-issue" ]; then
  register_plan_from_issue "${2:?usage: dispatch.sh --register-from-issue <issue#> [owner/repo]}" \
                           "${3:-example-org/kb}"
  exit $?
fi
# ─────────────────────────────────────────────────────────────────────────────────────────────────

# ── dispatch-count.cache: the `· N running` the operator's statusline renders (#3365) ─────────────────────
# statusline.sh reads $HOME/.claude/state/dispatch-count.cache and NEVER counts dispatches itself: the
# statusLine debounce is 300ms and an in-flight script is CANCELLED by the next trigger, so an ssh on the
# render path renders NOTHING AT ALL (#3357). It reads the file, and omits the field when the file is
# missing or older than 60s. That contract was correct — but NOTHING IN THE FLEET EVER WROTE THE FILE, so
# `· N running` had never once appeared. This script is the one place that knows a dispatch just started,
# so the count is written here, AFTER the launch. A snapshot, not a subscription: the statusline discards
# it at 60s, so a count that goes stale is omitted rather than believed.
#   · The count is live `task-*` units across every master — agent locally, the rest in ONE ssh to bravo —
#     matching `systemctl --user list-units 'task-*'` (#3357's acceptance). Master list is the literal
#     this file already switches on at the dispatch case below; there is no second source to disagree with.
#   · Every failure is swallowed and the function always returns 0. Bookkeeping must NEVER be able to kill
#     a dispatch: `set -euo pipefail` (:5) turns a transient failure inside a command substitution into a
#     dead dispatch, which is #3315 in this same file.
#
# #3419 — the SECOND line of that same file: `stalled=<n> failed=<n>`.
# `N running` alone cannot show the fleet's #1 loss. Silent death is 25.4% of all 169 dispatches, and a
# dead run is precisely the one that STOPS being a live task-* unit — so the count above goes DOWN when a
# run dies, which reads identically to a run finishing. The two numbers that distinguish them are derived
# here, off the render path, in ONE GraphQL call, and written into the SAME cache file (no second state
# file, no new service, no new channel — the scope fence of #3415).
#   · stalled = Doing issues whose newest run-marker is a ▶ older than STALE_VANISHED_MINUTES, or
#     that have NO marker at all. This is a TERMINAL-ONLY signal — the board half was DELETED by
#     #3569 after measuring 100 settled dispatches and finding zero genuine deaths in the sample.
#     board-reconcile.yml's sweepStaleDoing() now ONLY heals terminal-marker-but-stuck-Status cases
#     (it SKIPS ▶-only items at line 336), so the terminal and the board can now disagree.
#   · failed  = the newest marker is ✘/⚠/⛔/🪫 within the last 6h — every announced failure. The board
#     no longer posts a "⚠ run vanished" notice (that sweeper was deleted by #3569), so a silent
#     death shows up ONLY in the stalled count, NOT in the failed count.
#   · If the query fails, line 2 is OMITTED ENTIRELY — never `stalled=0`. statusline.sh's invariant 2 is
#     "never render a default or placeholder"; a fabricated zero in the signal built to eliminate
#     fabricated values is the #3365 bug all over again. Line 1 is written regardless, unchanged.
write_dispatch_count() {
  local n_local n_remote total dir nodes health
  n_local="$(systemctl --user list-units --no-legend --plain 'task-*' 2>/dev/null \
             | awk '$3=="active"' | wc -l || true)"
  # -n is load-bearing: without it this ssh reads the caller's stdin and swallows it (caught live — it ate
  # the rest of the shell script that invoked `--count`). Nothing here needs stdin.
  n_remote="$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "bravo@$BRAVO" \
      'for M in alpha bravo charlie delta; do sudo -u $M XDG_RUNTIME_DIR=/run/user/$(id -u $M) \
         systemctl --user list-units --no-legend --plain "task-*" 2>/dev/null; done' 2>/dev/null \
      | awk '$3=="active"' | wc -l || true)"
  total=$(( ${n_local:-0} + ${n_remote:-0} ))
  dir="$HOME/.claude/state"
  mkdir -p "$dir" 2>/dev/null || true

  # The 100 most-recently-updated OPEN issues: an item stranded in Doing was updated when it ENTERED
  # Doing, so it is always inside that window (the repo carries ~142 open issues). ~10 GraphQL points.
  # The GitHub App installation token when one is mintable, else whatever gh is already logged in as.
  # Measured 2026-07-30: the agent box — the ONE box that renders this statusline — was sitting on an
  # exhausted GraphQL limit for its user ("API rate limit already exceeded for user ID ..."), which would
  # have made line 2 absent most of the time and the whole field invisible. task-runner.sh:387 already
  # reaches for this same token for its board work; the App carries its own limit. Never printed.
  local _tok
  _tok="$(bash "$HOME/.claude/scripts/gh-app-token.sh" 2>/dev/null || true)"
  [ "${_tok:0:4}" = "ghs_" ] || _tok=""

  nodes="$(GH_TOKEN="${_tok:-${GH_TOKEN:-}}" gh api graphql -F o="${DISPATCH_BOARD_OWNER:-example-org}" -F r="${DISPATCH_BOARD_REPO:-knowledge}" -F a=null -f query='
    query($o:String!,$r:String!,$a:String){ repository(owner:$o,name:$r){ issues(states:OPEN,first:100,after:$a,orderBy:{field:UPDATED_AT,direction:DESC}){ nodes{
      number
      comments(last:15){ nodes{ body createdAt } }
      projectItems(first:2){ nodes{ updatedAt fieldValues(first:20){ nodes{ ... on ProjectV2ItemFieldSingleSelectValue{ name field{ ... on ProjectV2FieldCommon{ name } } } } } } }
    } } } }' --jq '.data.repository.issues.nodes' 2>/dev/null || true)"
  health=""
  if [ -n "$nodes" ]; then
    health="$(printf '%s' "$nodes" | jq -r --argjson n "${STALE_VANISHED_MINUTES:-90}" --argjson now "$(date +%s)" '
      [ .[] | . as $i
        | ([$i.projectItems.nodes[0].fieldValues.nodes[]? | select(.field.name=="Status") | .name] | first) as $st
        | ($i.projectItems.nodes[0].updatedAt // null) as $iu
        | ([$i.comments.nodes[] | select(.body | test("^\\s*(▶|✔|✘|⚠|⛔|🪫|⏹)"))] | last) as $l
        | { st:$st, iu:$iu, m:(if $l then ($l.body | ltrimstr(" ") | .[0:1]) else null end),
            age:(if $l then ($now - ($l.createdAt|fromdateiso8601)) else null end),
            iage:(if $iu then ($now - ($iu|fromdateiso8601)) else null end) } ]
      | { stalled: ([ .[] | select(.st=="Doing") | select(
            (.m=="▶" and .age >= ($n*60)) or (.m==null and .iage != null and .iage >= ($n*60))) ] | length),
          failed:  ([ .[] | select(.m != null) | select(.m as $mk | ["✘","⚠","⛔","🪫"] | index($mk)) | select(.age <= 21600) ] | length) }
      | "stalled=\(.stalled) failed=\(.failed)"' 2>/dev/null || true)"
  fi

  if [ -n "$health" ]; then
    printf '%s\n%s\n' "$total" "$health" > "$dir/dispatch-count.cache" 2>/dev/null || true
  else
    printf '%s\n' "$total" > "$dir/dispatch-count.cache" 2>/dev/null || true
  fi
  echo "dispatch-count.cache = $total live task-* units (agent $n_local + masters $n_remote)${health:+ · $health}"
  return 0
}

# Refresh hook, same shape as --resolve above: `dispatch.sh --count` writes the cache and exits. Lets the
# writer be exercised for real without consuming a master run, and gives the operator a manual refresh.
if [ "${1:-}" = "--count" ]; then
  write_dispatch_count
  exit 0
fi
# ─────────────────────────────────────────────────────────────────────────────────────────────────

# ── Account-aware dispatch (#3420) ──────────────────────────────────────────────────────────────
# The trap this defeats: charlie and product were dispatched 5 seconds apart onto the SAME Claude account
# — dispatch.sh had no way to know they shared it, so nothing staggered them.
# Nothing here has ever known the ACCOUNT a master actually authenticates as, and the registry can't say
# — it rotates (organization.yaml's
# own cost_model block says so now, corrected during this same task: "THE LOGIN A BOX IS ON IS DERIVED,
# NEVER DECLARED" — product's own entry used to claim a stable ops@example.com email that was never
# once observed on the box; see this PR's body for the measured mismatch, acceptance #6).
#
# The one trustworthy source is what each box is ACTUALLY logged in as, and it does not need an ssh at
# all: usage-feed.sh already reads it from `~/.claude.json`'s `oauthAccount.emailAddress` (the exact same
# field task-runner.sh reads live at run start, for the exact same reason) every 10 minutes, and
# occ-usage-publish.sh (bravo, `*:3/10`) already COLLECTS every box's copy and commits it to THIS repo at
# `_infra/occ-feeds/usage/<master>.json` — max age ~14 min (its own timer's DoD). No new state file
# (#3415's scope fence): this reads a file the fleet already publishes, and unlike an ssh+sudo probe it
# works for ANY caller with a repo clone, not only one holding bravo's cross-master sudo rights.
#
# account_for <master> → the account this master's LAST PUBLISHED feed carries — the same field
# task-runner.sh derives its own ACCOUNT var from, so the two answers agree. Prints "unknown" (never
# guesses) if the feed is missing or unparseable.
account_for() {
  local master="$1" feed="$_SD/../occ-feeds/usage/$1.json"
  [ -f "$feed" ] || { echo unknown; return 0; }
  jq -r '.account // "unknown"' "$feed" 2>/dev/null || echo unknown
}

# ── IS THAT ACCOUNT READING STILL CURRENT? (#7974, completing what #7983 landed) ────────────────
# account_for() answers "what account did this box's LAST PUBLISHED feed carry" — a published fact, and
# therefore one with an age. A publisher that stops (box off, timer dead, occ-usage-publish.sh wedged)
# leaves the LAST login frozen in the feed with nothing marking it as old: exactly what let delta's
# pre-rotation login read as current for hours (knowledge#7973's root cause, verbatim in
# `fleet-usage-feeds.ts`'s `accountFresh` comment). Anything that merely DISPLAYS the account can live
# with that; anything that GROUPS on it cannot, because a stale reading groups two boxes that no longer
# share a login and the quota spread below would then darken a box that is perfectly healthy — a FALSE
# BLOCK, the one outcome #3906's fail-open design says is worse than a wasted run.
#
# 🔴 THE VALUE IS NEVER BLANKED, ONLY FLAGGED — the same split P1 shipped on the OCC side. `account_for()`
# keeps returning the string (blanking it would delete the box from the account grouping entirely — the
# $33.0K-of-$44.4K orphaning defect that derivation exists to fix, see `fleet-usage-feeds.ts:330`); this
# predicate is how a CONSUMER says "I cannot trust that" instead.
#
# THE BOUND IS A MEASUREMENT, NOT A PRECAUTION, and it is P1's bound reused rather than a second one
# invented: `STALE_UTIL_MS = 90 * 60_000` in `apps/web/lib/fleet-usage-feeds.ts`, which gates the OCC's
# `accountFresh` off the same `fetchedAt` stamp this reads. One bar, both surfaces — a shell check and a
# renderer that disagreed about "current" would be two answers to one question.
#   · cycle, measured on this box 2026-09-26: `systemctl --user cat usage-feed.timer` → base
#     `OnCalendar=*:0/10` with a `10-cadence.conf` drop-in of `OnCalendar=*:0/20`, i.e. 10–20 min.
#   · live outer age of all 7 committed feeds, 2026-09-26T06:10:13Z: 10.0 · 10.1 · 10.1 · 10.1 · 10.1 ·
#     10.2 · 10.0 min. P1's own sweep 15 min earlier saw a worst case of 34.4 min.
#   · 90 min is therefore 4.5–9 missed cycles and ~2.6x the worst age ever observed — the same 3-miss
#     margin STALE_UTIL_MS and STALE_USAGE_MS are both sized for, not a round number.
# NOT `STALE_USAGE_MS` (3 h): that bar is sized for the hourly ccusage tier, and against a 10–20 min
# cycle it is 9–18 missed cycles. Detection latency is the entire point of this gate.
ACCOUNT_STALE_S="${DISPATCH_ACCOUNT_STALE_S:-5400}"   # 90 min — see above; the override is for tests.

# account_fresh <master> → 0 when that master's published feed is recent enough for its `.account` to
# count as CURRENT, 1 otherwise. Prints nothing. Every failure mode (no feed, no `fetchedAt`, a stamp
# `date` cannot parse, an age past the bar) returns 1, so the caller's fail-open branch is the default.
account_fresh() {
  local feed="$_SD/../occ-feeds/usage/$1.json" ts t now
  [ -f "$feed" ] || return 1
  ts="$(jq -r '.fetchedAt // empty' "$feed" 2>/dev/null || true)"
  [ -n "$ts" ] || return 1
  t="$(date -u -d "$ts" +%s 2>/dev/null)" || return 1
  now="$(date -u +%s)"
  [ "$t" -le "$now" ] || return 0        # a stamp in the FUTURE is clock skew, not staleness
  [ $(( now - t )) -le "$ACCOUNT_STALE_S" ] || return 1
  return 0
}

# probe_inflight → one line per master: "<master> <live-task-unit-count>". Unlike the account (a
# published fact), LIVE process state cannot be a committed file without going stale the instant a run
# starts or ends — so this half still needs the real-time probe, the SAME ssh+sudo shape
# write_dispatch_count's n_remote and sweep-dispatch.sh's UNITS probe already use (ONE round trip for all
# four, never four connections). `sudo -n`: over a non-interactive ssh with no pty, a missing NOPASSWD
# rule must fail fast and empty, never hang on a password prompt nothing can answer.
probe_inflight() {
  ssh -n -o BatchMode=yes -o ConnectTimeout=8 "bravo@$BRAVO" '
    for M in alpha bravo charlie delta; do
      N=$(sudo -n -u "$M" env XDG_RUNTIME_DIR="/run/user/$(id -u "$M")" \
            systemctl --user list-units --state=active --no-legend --plain "task-*" 2>/dev/null | wc -l)
      echo "$M ${N:-0}"
    done
  ' 2>/dev/null || true
  # `|| true` is load-bearing (same idiom as write_dispatch_count's n_remote above): under
  # `set -euo pipefail`, an unresolvable ssh (e.g. this caller holds no bravo key) must degrade the
  # concurrency check honestly, never propagate a probe failure into a dead dispatch (#3315's exact bug).
  return 0
}

# ── THE ISSUE-KEYED LIVE-RUN GUARD (#4484 · Feature #4475) ───────────────────────────────────────
# probe_inflight() above answers "HOW MANY units is this master running" and throws the names away, so
# the one question that matters here — "is one of them THIS ISSUE" — could not be asked. On 2026-08-05
# #4460 was dispatched to charlie twice, 14s apart, and both runs went the whole way to a PR on the same
# component. The second dispatch's own probe_inflight call SAW the first unit
# (`sudo -u charlie … list-units --state=active … task-*` at 17:51:34Z, journald on fleet-host) — it just
# had no notion of issue identity, so it printed the non-blocking "same-master concurrency (safe since
# #3432)" line at :1444 and launched anyway. The data was already in hand; nobody keyed it.
#
# 🔴 Why sweep-dispatch.sh's predicate 5 did not catch it, re-derived this session from the primary
# sources rather than assumed (full evidence: #4475):
# the two launches did NOT straddle two sweeper probes. The 17:51:11Z cycle dispatched #4460 exactly ONCE
# (`sweep-dispatch.log:7013`, `dispatched=1`) and the second launch appears NOWHERE in that log. Its whole
# pre-flight chain (fleet-host journald 17:51:31→17:51:35Z, unit `task-4460-1785952285-13229`) is preceded
# by ssh sessions from 192.0.2.20 — workstation, the Architect's box — while the first launch's chain
# (17:51:17→17:51:20Z, unit `task-4460-1785952271-24247`) came from 192.0.2.10, fleet-host itself.
# The second dispatch was a DIRECT `dispatch.sh charlie 4460` that never entered the sweeper's candidate
# loop, so predicate 5 had no opportunity to fire at all. A guard living only in the consumer cannot see
# the hand path — the same lesson the blocked-dependency pre-flight above already learned (#3937).
#
# live_units_for_issue <master> <issue> → the ACTIVE `task-<issue>-*.service` unit name(s) on the box that
# master runs on, one per line. Nothing printed = no evidence of a live run, which is ALSO what every
# failure mode prints: no ssh, no sudo, no systemd, unreadable output. This guard FAILS OPEN by
# construction — a bookkeeping failure must never stop the fleet (#3420's hard stop), and a refusal is
# only ever a POSITIVE read of a live unit.
#
# Scoped to the TARGET master, matching the Feature's acceptance ("a live run for that master") and the
# two dispatch branches below, which are themselves per-box. Fleet-wide duplicates (#3895 ran on product and
# charlie at once) stay with sweep-dispatch.sh's LIVE_ISSUES, which is fleet-wide by construction.
live_units_for_issue() {
  local master="$1" issue="$2" units="" u n
  case "$master" in
    agent|architect)
      # Local, exactly like the `agent` dispatch branch's own `systemd-run --user`: the Architect
      # dispatches on its own box, so its live units are this box's live units.
      units="$(systemctl --user list-units --state=active --no-legend --plain 'task-*' 2>/dev/null \
               | awk '{print $1}' || true)" ;;
    *)
      # ONE round trip, the same ssh+sudo shape probe_inflight() uses. `-n` so this never eats the
      # caller's stdin (sweep-dispatch.sh reads its candidates from a here-string); BatchMode so a
      # missing key fails fast and EMPTY instead of hanging; ConnectTimeout so a dark box is bounded.
      # shellcheck disable=SC2029  # $master is expanded HERE on purpose: the target is this side's.
      units="$(ssh -n -o BatchMode=yes -o ConnectTimeout=8 "bravo@$BRAVO" \
        "sudo -n -u '$master' env XDG_RUNTIME_DIR=/run/user/\$(id -u '$master') \
           systemctl --user list-units --state=active --no-legend --plain 'task-*' 2>/dev/null \
         | awk '{print \$1}'" 2>/dev/null || true)" ;;
  esac
  [ -n "$units" ] || return 0
  # 🔴 The issue number is EXTRACTED from the unit name with sweep-dispatch.sh:362's exact pattern, not
  # matched with a `task-$issue-*` glob and never inferred from a timestamp window. dispatch.sh has
  # already changed this name once — `task-<issue>-<epoch>` → `task-<issue>-<epoch>-<RANDOM>` (9d006cbc,
  # 2026-08-02) — and the sweeper's then-exact two-segment regex silently stopped matching, leaving its
  # anti-double-dispatch check unable to fire for a day. `(-.*)?` makes every suffix segment opaque.
  while read -r u; do
    [ -n "$u" ] || continue
    n="$(printf '%s' "$u" | sed -nE 's/^task-([0-9]+)(-.*)?\.service$/\1/p')"
    if [ -n "$n" ] && [ "$n" = "$issue" ]; then printf '%s\n' "$u"; fi
  done <<< "$units"
  return 0
}

# fleet_units_for_issue <issue> → "<master> <unit>" for EVERY master on fleet-host running this issue.
#
# #7167 — 🔴 live_units_for_issue() above asks ONE master, and the duplicate this fleet actually produces
# is CROSS-master. Measured 2026-08-28, three times in ten minutes:
#   #7124  charlie 13:39:22 · bravo 13:39:33   — 11s apart, both live
#   #7125  (first start)  · delta            — both live
#   #7148  charlie 13:49:26 · bravo 13:49:31   —  5s apart, both live
# #6960 made the unit name zero-entropy so systemd refuses a second `task-<n>.service` IN THE KERNEL —
# but a systemd USER manager is per-user, so `task-7124.service` under `charlie` and under `bravo` are two
# different names in two different namespaces and neither refusal can ever fire. The per-master guard was
# structurally unable to see any of the three.
#
# ONE ssh round trip for all four, the same ssh+sudo shape probe_inflight() and live_units_for_issue()
# already use, and FAILS OPEN by construction for the same reason they do: no ssh, no sudo, no systemd,
# unreadable output all print nothing, and nothing printed is never a refusal. A bookkeeping failure must
# never stop the fleet (#3420).
fleet_units_for_issue() {
  local issue="$1" raw
  # shellcheck disable=SC2016  # every expansion below is deliberately evaluated on the REMOTE side
  raw="$(ssh -n -o BatchMode=yes -o ConnectTimeout=8 "bravo@$BRAVO" '
    for M in alpha bravo charlie delta; do
      sudo -n -u "$M" env XDG_RUNTIME_DIR=/run/user/$(id -u "$M") \
        systemctl --user list-units --state=active --no-legend --plain "task-*" 2>/dev/null \
        | awk -v m="$M" "{print m\" \"\$1}"
    done' 2>/dev/null || true)"
  [ -n "$raw" ] || return 0
  # Same extraction as live_units_for_issue(): the issue number is PARSED out of the unit name with
  # sweep-dispatch.sh:362's pattern, never matched with a `task-$issue-*` glob — every suffix segment is
  # opaque, so both the zero-entropy name and a DISPATCH_ALLOW_DUPLICATE one resolve.
  local m u n
  while read -r m u; do
    [ -n "$u" ] || continue
    n="$(printf '%s' "$u" | sed -nE 's/^task-([0-9]+)(-.*)?\.service$/\1/p')"
    if [ -n "$n" ] && [ "$n" = "$issue" ]; then printf '%s %s\n' "$m" "$u"; fi
  done <<< "$raw"
  return 0
}

# fleet_claim_prologue <master> <issue> → the bravo-side preamble that makes the claim ATOMIC ACROSS MASTERS.
#
# #7167 — the race this closes, measured: guard-to-launch in dispatch.sh is 26-27s (#6960's own timings),
# and two dispatchers reading the board in the same second both pass every pre-flight before either one
# launches. Any check that runs BEFORE the launch, however wide, has a window it cannot close; #7124's was
# 11 seconds and #7148's was 5.
#
# So the check moves INSIDE the lock, and the lock is held across the check AND the launch. Both dispatch
# paths — the sweeper running locally as `bravo`, and a hand dispatch arriving over ssh from the Architect's
# box — execute this as the SAME unix user on the SAME box, so one flock serialises them. The loser's probe
# then SEES the winner's unit (systemd-run has already returned by the time the lock is released) and
# refuses. There is no window left: the state the loser reads is the state the winner wrote.
#
# 🔴 FAILS OPEN, deliberately, in both halves. If flock cannot be taken in time the launch proceeds
# unserialised and says so; if the probe cannot read a box it prints nothing and nothing is refused. A
# duplicate run costs one session; a dispatcher that refuses to start work because a lock file was
# unwritable costs the fleet.
fleet_claim_prologue() {
  local master="$1" issue="$2"
  # The two values the remote side cannot learn on its own. ssh forwards no environment, so
  # DISPATCH_ALLOW_DUPLICATE is carried here explicitly or the escape hatch silently stops working.
  printf "CLAIM_ISSUE='%s'\nCLAIM_MASTER='%s'\nCLAIM_ALLOW_DUP='%s'\n" \
    "$issue" "$master" "${DISPATCH_ALLOW_DUPLICATE:-0}"
  # Everything below is a QUOTED heredoc — nothing in it is expanded on this side, so there is no
  # backslash ladder to get wrong. It reads only the three variables printed above.
  cat <<'PRO'
LOCK="${DISPATCH_CLAIM_LOCK:-$HOME/.claude/state/fleet-dispatch-claim.lock}"
mkdir -p "$(dirname "$LOCK")" 2>/dev/null || true
if exec 9>"$LOCK" 2>/dev/null; then
  flock -w "${DISPATCH_CLAIM_WAIT:-45}" 9 ||
    echo "claim: could not take $LOCK within ${DISPATCH_CLAIM_WAIT:-45}s — proceeding UNSERIALISED (fails open, #7167)" >&2
else
  echo "claim: could not open $LOCK — proceeding UNSERIALISED (fails open, #7167)" >&2
fi
if [ "$CLAIM_ALLOW_DUP" = "1" ]; then
  echo "claim: DISPATCH_ALLOW_DUPLICATE=1 — the fleet-wide claim is off for this dispatch (#7167)." >&2
else
  CLAIM_HIT="$(for M in alpha bravo charlie delta; do
      sudo -n -u "$M" env XDG_RUNTIME_DIR=/run/user/$(id -u "$M") \
        systemctl --user list-units --state=active --no-legend --plain 'task-*' 2>/dev/null |
        awk -v m="$M" -v want="$CLAIM_ISSUE" '
          { u = $1; n = u
            sub(/\.service$/, "", n); sub(/^task-/, "", n); sub(/-.*$/, "", n)
            if (n == want) print "  live: " m " " u }'
    done)"
  if [ -n "$CLAIM_HIT" ]; then
    echo "REFUSED-DUPLICATE-FLEET: #$CLAIM_ISSUE already has a LIVE run in the fleet — nothing was started." >&2
    printf '%s\n' "$CLAIM_HIT" >&2
    exit 14
  fi
fi
PRO
}

# duplicate_preflight <master> <issue> → 0 = no live run for this issue, 11 = refuse.
# ONE implementation, two callers — the real dispatch path below and the `--preflight-duplicate` dry-run
# hook — for the same reason quota_preflight() has one: two copies drift into disagreeing about what
# "already running" means.
#
# 🔴 Writes NOTHING to the board, same reasoning as the CLOSED and blocked-dependency refusals above: the
# sweeper's eligibility predicate is read out of the run-marker glyphs, so a ⛔/⏸ posted here would turn a
# one-off refusal into permanent ineligibility for an issue whose only problem is that it is ALREADY
# BEING WORKED. The live run posts its own ▶/✔ — the board is already telling the truth.
#
# ⛔ Must NOT block a legitimate re-dispatch after a failed run: `--state=active` excludes `failed`,
# `inactive` and `dead`, and every unit is started `--collect`, so a finished run leaves nothing behind
# to latch on. The guard is a live-process fact, never a history of one.
duplicate_preflight() {
  local master="$1" issue="$2" live
  if [ "${DISPATCH_ALLOW_DUPLICATE:-0}" = "1" ]; then
    echo "NOTE: DISPATCH_ALLOW_DUPLICATE=1 — the issue-keyed live-run guard is off for this dispatch (#4484)." >&2
    return 0
  fi
  # #7167 — FLEET-WIDE, not just $master. Scoping this to the target master made it structurally unable
  # to see the duplicate this fleet actually produces: on 2026-08-28 #7124/#7125/#7148 each had two live
  # runs on TWO DIFFERENT masters, 5-11s apart. The per-master read is still available on its own via
  # `--live-units <master> <issue>`; this predicate now asks the question the failures were shaped like.
  # Still only ONE ssh round trip, and still fails open.
  live="$(fleet_units_for_issue "$issue")"
  [ -n "$live" ] || return 0
  {
    echo "PRE-FLIGHT FAIL: #$issue ALREADY HAS A LIVE RUN in the fleet — refusing to start a second one."
    printf '%s\n' "$live" | sed 's/^/  live unit: /'
    echo "  (This is the EARLY refusal. The atomic one is the flock-held claim at launch — #7167 — which"
    echo "  closes the 26-27s window this check cannot: it exits 14, not 11.)"
    echo "  Two runs on one issue burn two full sessions of one shared quota and race each other to a PR"
    echo "  on the same files (#4460, 2026-08-05: two ~200-turn charlie runs 14s apart, one PR made worthless)."
    echo "  Keyed on the issue number in the unit name — a finished or failed run leaves no active unit, so"
    echo "  a legitimate re-dispatch after a failure is never blocked."
    # #7167 — the remediation must name the master that OWNS the unit, not the one being dispatched to.
    # `$live` is now "<master> <unit>" per line (it is fleet-wide), and pasting the target master here
    # produced `sudo -u delta ... stop alpha task-7167.service` — a command that is wrong twice over.
    local _lm _lu
    _lm="$(printf '%s' "$live" | head -1 | awk '{print $1}')"
    _lu="$(printf '%s' "$live" | head -1 | awk '{print $2}')"
    echo "  If that run is wedged, stop it first — on the master that OWNS it ($_lm), not $master:"
    echo "    ssh bravo@$BRAVO \"sudo -u $_lm XDG_RUNTIME_DIR=/run/user/\\\$(id -u $_lm) systemctl --user stop $_lu\""
    echo "  If MORE THAN ONE unit is listed above, do NOT pick one by eye — that pick was wrong twice on"
    echo "  2026-08-27 and both times it killed the SURVIVING run (#6946/#6947). Resolve it deterministically:"
    echo "    $(basename "$0") --dedupe $_lm $issue --dry-run   # then drop --dry-run"
    echo "  Or, to run a deliberate second copy anyway:"
    echo "    DISPATCH_ALLOW_DUPLICATE=1 $(basename "$0") $master $issue"
  } >&2
  return 11
}

# launch_unit_script <unit> <systemd-run command line> → a self-contained shell script on STDOUT that
# CLAIMS the unit name or refuses, and — the whole point — tells the two refusals apart.
#
# ONE implementation, two callers (the local `agent` branch and the ssh branch below), for the same
# reason duplicate_preflight() and quota_preflight() have one: two copies of a retry policy drift into
# disagreeing about what "already running" means.
#
# 🔴 WHY THIS EXISTS AT ALL. With a zero-entropy unit name (#6960), `systemd-run` refusing the name IS
# the anti-double-dispatch guarantee — kernel-arbitrated, no window. But the SAME refusal, with the SAME
# error string, is what a legitimate retry hits for a few seconds after a previous run FAILED, because
# `--collect` sets CollectMode=inactive-or-failed and systemd unloads on a GC queue rather than
# instantly. Measured on fleet-host 2026-08-27 (systemd 255.4-1ubuntu8.17), 5 trials, exit-1 and SIGKILL:
# 4520 / 3702 / 3484 / 4006 / 3989 / 4343 ms; `systemctl reset-failed` does NOT accelerate it (3.5-4s
# either way). A clean exit or `systemctl stop` frees the name immediately.
#
# So the string cannot be the discriminator and the outcomes must differ. The discriminator is
# ActiveState, read from the box itself:
#   active / activating / reloading → a real live run    → exit 11, refuse, disturb NOTHING
#   anything else (failed, unloaded) → an unloading corpse → reset-failed, wait, retry (bounded)
# A refusal whose text is NOT a name collision is never retried: exit 13 immediately with the box's own
# words, so "user session not lingering" never spends ten seconds impersonating a duplicate.
#
# Defaults are baked into the emitted script, not read from this side's env: the remote half runs under
# `ssh … bash -s`, which forwards no environment. DISPATCH_UNIT_CLAIM_TRIES/WAIT are overridable ON THE
# BOX. 6 × 2s = 10s of waiting, ~2.3× the slowest GC ever measured here.
launch_unit_script() {
  local unit="$1" cmd="$2"
  cat <<EOS
U='$unit'
TRIES=\${DISPATCH_UNIT_CLAIM_TRIES:-6}
WAIT=\${DISPATCH_UNIT_CLAIM_WAIT:-2}
try=1
while :; do
  if ERR="\$($cmd 2>&1)"; then printf '%s\n' "\$ERR"; exit 0; fi
  case "\$ERR" in
    *'already loaded'*|*'already exists'*) : ;;
    *) printf '%s\n' "\$ERR" >&2; exit 13 ;;
  esac
  STATE="\$(systemctl --user show "\$U.service" -p ActiveState --value 2>/dev/null || true)"
  case "\$STATE" in
    active|activating|reloading)
      printf '%s\n' "\$ERR" >&2
      printf 'REFUSED-DUPLICATE: %s.service is ACTIVE (ActiveState=%s) — a live run already owns this issue.\n' "\$U" "\$STATE" >&2
      exit 11 ;;
  esac
  if [ "\$try" -ge "\$TRIES" ]; then
    printf '%s\n' "\$ERR" >&2
    printf 'REFUSED-UNAVAILABLE: %s.service is NOT active (ActiveState=%s) yet its name is still held after %s tries.\n' "\$U" "\${STATE:-unloaded}" "\$TRIES" >&2
    exit 12
  fi
  printf 'launch: %s.service name still held by a finished run (ActiveState=%s) — reset-failed, retry %s/%s in %ss\n' "\$U" "\${STATE:-unloaded}" "\$try" "\$TRIES" "\$WAIT" >&2
  systemctl --user reset-failed "\$U.service" >/dev/null 2>&1 || true
  try=\$((try + 1))
  sleep "\$WAIT"
done
EOS
}

# fleet_claim_launch_script <master> <issue> <unit> <systemd-run cmd> → the WHOLE bravo-side script:
# take the fleet lock, refuse if any master already runs this issue, then hand the unchanged unit-name
# claim to the target master. One ssh, one lock, and the check and the launch are on the same side of it.
fleet_claim_launch_script() {
  local master="$1" issue="$2" unit="$3" cmd="$4"
  fleet_claim_prologue "$master" "$issue"
  # The unit-name claim still runs as the TARGET master under its own systemd user manager — byte for byte
  # the script that has always been piped over ssh. It is EMBEDDED in a quoted heredoc rather than left on
  # stdin behind the prologue: `bash -s` reading from a pipe buffers ahead, so a second script following
  # the first on the same stdin is not reliably readable.
  printf "sudo -u %s XDG_RUNTIME_DIR=/run/user/\$(id -u %s) bash -s <<'__CLAIM_INNER__'\n" "$master" "$master"
  launch_unit_script "$unit" "$cmd"
  printf '__CLAIM_INNER__\n'
}

# launch_fail_report <rc> — the one place a failed launch is explained, shared by both dispatch branches
# for the reason #3521 gave: a launch that fails silently with someone else's exit status tells the
# caller neither that nothing started nor why. Every code below is produced by launch_unit_script()
# except 255, which is ssh's own.
launch_fail_report() {
  local rc="$1"
  echo "DISPATCH FAIL: the run for #$ISSUE was NOT started on $MASTER (exit $rc)." >&2
  case "$rc" in
    11) echo "  11 = REFUSED AS A DUPLICATE. The unit name '$UNIT' is already held by a LIVE run on" >&2
        echo "  $MASTER, and systemd refused the second unit in the kernel. This is the guarantee (#6960)," >&2
        echo "  not a fault: nothing was started, and — unlike the hand de-duplication that killed the" >&2
        echo "  SURVIVING run on #6946 and #6947 — nothing running was disturbed." >&2
        echo "  To run a deliberate second copy anyway:" >&2
        echo "    DISPATCH_ALLOW_DUPLICATE=1 $(basename "$0") $MASTER $ISSUE" >&2 ;;
    14) echo "  14 = REFUSED BY THE FLEET-WIDE CLAIM. Another master is already running #$ISSUE, and the" >&2
        echo "  claim is taken under a flock on fleet-host that both dispatch paths pass through, so the" >&2
        echo "  check and the launch are on the same side of the lock: there is no window to lose (#7167)." >&2
        echo "  The live unit is named above. This is the guarantee, not a fault — nothing was started, and" >&2
        echo "  nothing already running was disturbed. #6960's zero-entropy unit name covers the SAME-master" >&2
        echo "  case in the kernel; this covers the cross-master one, which a per-user namespace cannot." >&2
        echo "  To run a deliberate second copy anyway:" >&2
        echo "    DISPATCH_ALLOW_DUPLICATE=1 $(basename "$0") $MASTER $ISSUE" >&2 ;;
    12) echo "  12 = the name '$UNIT' was held by a run that had already FINISHED and was still unloading," >&2
        echo "  and it was still held after every retry. Measured GC on fleet-host is 3.5-4.5s; this waited" >&2
        echo "  longer than that. Nothing is running under that name — clear it and re-dispatch:" >&2
        echo "    ssh bravo@$BRAVO \"sudo -u $MASTER XDG_RUNTIME_DIR=/run/user/\\\$(id -u $MASTER) systemctl --user reset-failed $UNIT.service\"" >&2 ;;
    13) echo "  13 = systemd-run failed for a reason that is NOT a name collision (user session not" >&2
        echo "  lingering? runner missing? PATH?). The box's own words are printed above — read those, not" >&2
        echo "  this line." >&2 ;;
    255) echo "  255 is ssh's own error code — the connection to bravo@$BRAVO failed; nothing ran on the box," >&2
         echo "  and NOTHING is known about its units." >&2 ;;
    *)  echo "  Unclassified. The box's own words are printed above." >&2 ;;
  esac
}

# dedupe_issue_units <master> <issue> [--dry-run] → resolve coexisting units for one issue
# DETERMINISTICALLY: KEEP THE OLDEST live unit, stop every newer one.
#
# 🔴 Never by eye. On 2026-08-27 the duplicates on #6946 and #6947 were resolved by reading `systemctl`
# output and picking — and the pick was wrong BOTH times: the kill landed on the surviving run (exit=143,
# no artifact), and #6947 then CLOSED on that failure, so the board said done on work that never ran.
#
# Oldest wins because it has done the most work; ordering is `ActiveEnterTimestampMonotonic` (microseconds,
# so a tie is not reachable), never the unit name — which no longer carries a clock at all. With a
# zero-entropy name coexistence is only reachable through DISPATCH_ALLOW_DUPLICATE=1, so this is a repair
# tool, not a routine one. Fails OPEN and prints what it would do first.
dedupe_issue_units() {
  local master="$1" issue="$2" dry="${3:-}" script
  script="$(cat <<EOS
issue='$issue'
dry='$dry'
keep=''
list=''
for u in \$(systemctl --user list-units --state=active --no-legend --plain 'task-*' 2>/dev/null | awk '{print \$1}'); do
  n="\$(printf '%s' "\$u" | sed -nE 's/^task-([0-9]+)(-.*)?\.service\$/\1/p')"
  [ "\$n" = "\$issue" ] || continue
  t="\$(systemctl --user show "\$u" -p ActiveEnterTimestampMonotonic --value 2>/dev/null)"
  case "\$t" in ''|*[!0-9]*) t=0 ;; esac
  list="\$list\$t \$u
"
done
[ -n "\$list" ] || { echo "no live unit for #\$issue"; exit 0; }
sorted="\$(printf '%s' "\$list" | sort -n)"
keep="\$(printf '%s\n' "\$sorted" | head -1 | awk '{print \$2}')"
printf 'keep (oldest): %s\n' "\$keep"
printf '%s\n' "\$sorted" | tail -n +2 | while read -r t u; do
  [ -n "\$u" ] || continue
  if [ "\$dry" = "--dry-run" ]; then printf 'would stop (newer): %s\n' "\$u"
  else printf 'stopping (newer): %s\n' "\$u"; systemctl --user stop "\$u" >/dev/null 2>&1 || true; fi
done
EOS
)"
  case "$master" in
    agent|architect) printf '%s\n' "$script" | bash -s ;;
    *) printf '%s\n' "$script" \
         | ssh -o BatchMode=yes -o ConnectTimeout=10 "bravo@$BRAVO" \
             "sudo -n -u '$master' env XDG_RUNTIME_DIR=/run/user/\$(id -u '$master') bash -s" ;;
  esac
}

# ── QUOTA PRE-FLIGHT (#3906) — never dispatch into a master that is already dark ─────────────────
# 2026-08-02 22:59 UTC: bravo hit its 5-hour session limit and 20 dispatched runs died inside 34 seconds.
# alpha and charlie were then re-dispatched onto the same work between 23:13 and 23:37 and went dark too
# (🪫 on #3603, #3872, #3097). Runs were being dispatched into masters ALREADY KNOWN to be dark —
# `capture_quota()` (task-runner.sh:940) only fires AFTER a run dies, so the knowledge existed and
# nothing read it before starting the next one.
#
# 🔴 THE SWEEPER'S CHECK AND THIS ONE ARE THE SAME CODE, NOT TWO COPIES. sweep-dispatch.sh grew this
# probe first (commits 917cc092/137308e0/ce36f981, ~2026-08-03 00:50); it now calls `--quota-dark` below
# instead of carrying its own ssh block. One implementation, two callers, so they cannot drift into
# disagreeing about what "dark" means — and dispatch.sh is the right home because it is the ONE place
# every dispatch path passes through (the sweeper shells out to it; a human types it).
#
# GROUND TRUTH, not a probe and not a stored copy: task-runner.sh writes
# `$HOME/.claude/state/quota-status.json` the moment it captures a hard limit, with the provider's OWN
# reset time, and DELETES it after a clean run — so the file is self-healing rather than a cached claim
# that can drift. Schema read live 2026-08-03 from all four masters:
#   {"agent":"bravo","provider":"claude","exhausted":true,"resetsAt":"2026-08-03T02:30:00Z",
#    "resetsAtRaw":"2:30am (UTC)","reason":"session limit","source":"429-capture","detectedAt":…,"raw":…}
#
# 🔴 FAILS OPEN, ALWAYS. A false block here is worse than a wasted run: it stops the fleet on a
# bookkeeping failure. Dark is only ever a POSITIVE read of a live exhaustion — no file, no ssh, no
# sudo, no jq, unparseable JSON, `exhausted` not literally true, or a reset that has PASSED all mean
# "not dark". The one non-obvious case is `resetsAt: null` (capture_quota's honest-unknown path, when
# the provider stated no reset time): that counts as dark, exactly as the sweeper has always treated it,
# because an exhaustion with no stated end is still an exhaustion — and DISPATCH_IGNORE_QUOTA=1 is the
# one-line escape so a human is never stuck behind it.
QUOTA_MASTERS="${DISPATCH_QUOTA_MASTERS:-alpha bravo charlie delta}"
QUOTA_STATE_REL=".claude/state/quota-status.json"

# quota_probe <master...> → "<master><TAB><compact-json>" for each master whose state file was READ.
# A master with no file, or that could not be reached, simply produces no line — the fail-open path.
# ONE ssh for every off-box master, the same round-trip shape probe_inflight() above already uses.
quota_probe() {
  local m locals="" remotes=""
  for m in "$@"; do
    case "$m" in
      agent|architect) locals="$locals $m" ;;   # the Architect dispatches locally, so its state is local
      *)                remotes="$remotes $m" ;;
    esac
  done
  for m in $locals; do
    [ -f "$HOME/$QUOTA_STATE_REL" ] || continue
    printf '%s\t%s\n' "$m" "$(jq -c . "$HOME/$QUOTA_STATE_REL" 2>/dev/null || true)"
  done
  [ -n "$remotes" ] || return 0
  # shellcheck disable=SC2029  # $remotes is expanded HERE on purpose: the master list is this side's.
  ssh -n -o BatchMode=yes -o ConnectTimeout=10 "bravo@$BRAVO" "
    for M in $remotes; do
      f=/home/\$M/$QUOTA_STATE_REL
      sudo -n test -f \"\$f\" 2>/dev/null || continue
      printf '%s\t%s\n' \"\$M\" \"\$(sudo -n cat \"\$f\" 2>/dev/null | jq -c . 2>/dev/null || true)\"
    done" 2>/dev/null || true
  return 0
}

# quota_dark_for <master...> → one line per DARK master:
#   "<master><TAB><resetsAt|unknown><TAB><provider><TAB><source><TAB><via>"
# `via` (#7974) is `self` when THIS master's own state file was read, or the name of the account-sibling
# whose marker spread here. Appended, never inserted, for the third time in this function's life: the
# sweeper's `cut -f1` and `--quota-dark-detail`'s `$4` are untouched by it.
# Nothing printed = nothing is provably dark. Always exits 0 — a classification failure is not a block.
#
# #2807 added the 4th field. There are now TWO ways a master is dark and they need OPPOSITE actions: a
# quota (`source: 429-capture`) clears on a clock, so you wait; a revoked entitlement
# (`source: entitlement-capture`, always `resetsAt: null`) never does, so you rotate the login. Both are
# genuinely "cannot accept work", which is why they share this file and this predicate — but a pre-flight
# that told a human to wait out an entitlement revocation would be worse than one that said nothing.
# Appended, never inserted: `cut -f1` (--quota-dark, the sweeper) and `cut -f2/-f3` (quota_preflight) are
# unchanged, so nothing downstream had to learn about this.
#
# 🔴 PLAN-326/#7969 finding 1 — POOL-WIDE DARK, DERIVED LIVE, NEVER A ROSTER. quota-status.json is
# per-master bookkeeping written only AFTER a real dispatch failure (#3906's fail-open design, above) —
# so a master that has not yet attempted a dispatch since the shared account exhausted reports "clear"
# even though the ACCOUNT backing it is dead. Measured live 2026-09-26: all four masters reported clear
# while #7969 showed three real dispatch failures against `delta` on this exact exhaustion minutes
# earlier — because `alpha`/`bravo`/`charlie` (same account, different unix users) had simply not been tried
# yet. Once ANY master is found dark by the direct check above, every OTHER configured master whose
# CURRENT `account_for()` reading matches the dark master's is dark too, for the SAME reason and the
# SAME resetsAt/provider/source — derived fresh via account_for() every call, never from a maintained
# list of which boxes share a login (the operator, PLAN-326: "you don't need to keep track of the
# subscriptions, since I frequently login/logout with different accounts"). A wrong/unknown account_for()
# reading never SPREADS darkness — it only fails to, which is the existing fail-open contract unchanged.
quota_dark_for() {
  local now; now="$(date -u +%s)"
  local direct; direct="$(quota_probe "$@" | while IFS="$(printf '\t')" read -r m js; do
    [ -n "$m" ] && [ -n "$js" ] || continue                       # missing / unreadable → NOT dark
    [ "$(printf '%s' "$js" | jq -r '.exhausted // false' 2>/dev/null || true)" = true ] || continue
    local r p s t
    r="$(printf '%s' "$js" | jq -r '.resetsAt // empty' 2>/dev/null || true)"
    p="$(printf '%s' "$js" | jq -r '.provider // "?"'   2>/dev/null || true)"
    s="$(printf '%s' "$js" | jq -r '.source   // "?"'   2>/dev/null || true)"
    # Field 5 is `self` here and the ORIGINATING master name on a spread line (#7974) — see the spread
    # block below for why the refusal needs to tell those two apart.
    if [ -z "$r" ]; then printf '%s\t%s\t%s\t%s\t%s\n' "$m" unknown "$p" "$s" self; continue; fi
    if ! t="$(date -u -d "$r" +%s 2>/dev/null)"; then             # a reset we cannot read is not a reset
      printf '%s\t%s\t%s\t%s\t%s\n' "$m" "$r" "$p" "$s" self; continue
    fi
    if [ "$now" -lt "$t" ]; then printf '%s\t%s\t%s\t%s\t%s\n' "$m" "$r" "$p" "$s" self; fi
  done)"
  [ -n "$direct" ] && printf '%s\n' "$direct"
  [ -n "$direct" ] || return 0
  # Pool spread: for each directly-dark master, darken every OTHER queried master sharing its LIVE
  # account right now — skip one already reported (directly dark, or already spread-to by an earlier
  # iteration of this same loop) so a master on an account with TWO directly-dark siblings is never
  # printed twice — `--quota-dark | cut -f1` feeds the sweeper's ALL_UNHEALTHY list verbatim and a
  # duplicate name there is a real defect, not cosmetic.
  local reported_names; reported_names=" $(printf '%s\n' "$direct" | cut -f1 | tr '\n' ' ')"
  # 🔴 READ ALL FIVE FIELDS. `read` gives the LAST variable the remainder of the line, so reading four
  # off a five-field line put "<source><TAB>self" into `$ds` — which re-split on output and made every
  # spread line claim `via=self` (plus a phantom 6th field). Caught by this fix's own live test, not by
  # inspection; `$dvia` is read and discarded on purpose, since a spread never spreads onward.
  local dm dr dp ds dvia dacct qm qacct
  while IFS="$(printf '\t')" read -r dm dr dp ds dvia; do
    [ -n "$dm" ] || continue
    dacct="$(account_for "$dm")"
    [ "$dacct" != unknown ] || continue   # never spread from an unknown reading
    # …and never from a STALE one (#7974). Both sides are gated, because the grouping is only as true as
    # the OLDER of the two readings: a frozen feed on EITHER box invents a shared login that no longer
    # exists. Failing this check never darkens anything — it only declines to, which is #3906's
    # fail-open contract unchanged and is why the gate cannot itself stop the fleet.
    account_fresh "$dm" || continue
    for qm in "$@"; do
      [ "$qm" != "$dm" ] || continue
      case "$reported_names" in *" $qm "*) continue ;; esac   # already reported — no duplicate
      qacct="$(account_for "$qm")"
      if [ "$qacct" = "$dacct" ] && account_fresh "$qm"; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$qm" "$dr" "$dp" "$ds" "$dm"
        reported_names="$reported_names$qm "
      fi
    done
  done <<EOF
$direct
EOF
  return 0
}

# quota_preflight <master> → 0 to proceed, 9 to refuse. THE production refusal — the main flow below and
# the `--preflight-quota` hook both call THIS function, never a copy of it (same discipline as
# --register-plan: a test that runs a duplicate proves nothing about the path that runs).
#
# 🔴 IT WRITES NO BOARD COMMENT, DELIBERATELY. The two glyphs that fit the shape are both TERMINAL to
# sweep-dispatch.sh: ⛔ is in its "last marker" stop set (predicate 6) and ⏸ is its park latch
# (predicate 8) — either one would remove the issue from autonomous dispatch PERMANENTLY over a
# condition that clears itself in minutes. A transient capacity fact belongs on stderr, where the human
# or the sweeper that asked for the dispatch is reading. The 🪫 comment the runner already posts on a
# real death is the board-visible half; this is the cheap pre-check, not a second announcement.
quota_preflight() {
  local master="$1" ask="" dark dark_names line m resets prov src via local_txt path avail=""
  if [ "${DISPATCH_IGNORE_QUOTA:-0}" = "1" ]; then
    echo "QUOTA: DISPATCH_IGNORE_QUOTA=1 — skipping the quota pre-flight for '$master' (#3906 override)." >&2
    return 0
  fi
  # One probe answers both questions: is THIS master dark, and which masters are not. Deduped, because
  # $master is usually already in $QUOTA_MASTERS and a repeated name would probe the same file twice.
  ask="$QUOTA_MASTERS"
  case " $ask " in *" $master "*) ;; *) ask="$ask $master" ;; esac
  # shellcheck disable=SC2086  # $ask is a deliberate word list
  dark="$(quota_dark_for $ask)"
  line="$(printf '%s\n' "$dark" | awk -v m="$master" -F'\t' '$1==m{print; exit}')"
  [ -n "$line" ] || return 0
  resets="$(printf '%s' "$line" | cut -f2)"; prov="$(printf '%s' "$line" | cut -f3)"
  src="$(printf '%s' "$line" | cut -f4)"; via="$(printf '%s' "$line" | cut -f5)"
  [ -n "$via" ] || via=self
  # 🔴 The membership test MUST wrap both sides in spaces — the same `case " $ALL_UNHEALTHY " in` idiom
  # sweep-dispatch.sh uses. Without the LEADING space the first name in the list never matches its own
  # pattern, and a dark master gets recommended as available: caught in this fix's own first live run,
  # which offered `bravo` as an alternative to `alpha` while bravo was itself hard-limited until 02:30Z.
  dark_names=" $(printf '%s\n' "$dark" | cut -f1 | tr '\n' ' ')"
  for m in $QUOTA_MASTERS; do
    [ "$m" = "$master" ] && continue
    case "$dark_names" in *" $m "*) ;; *) avail="$avail $m" ;; esac
  done
  # the operator reads clock times, not Zulu. America/Denver is the fleet's established local zone — verified
  # against his own Claude `/settings` render (specs/3294-occ-real-data/3444-producer.md:39). `%Z` prints
  # whatever that zone REALLY is on the date in question (MST or MDT), so the label can never be a lie.
  # The weekday is part of it: a 02:30Z reset is the PREVIOUS evening in Denver, and a bare "8:30 PM"
  # next to a 2026-08-03 timestamp reads as tonight rather than last night.
  local_txt=""
  if [ "$resets" != unknown ]; then
    local_txt="$(TZ="${DISPATCH_TZ:-America/Denver}" date -d "$resets" '+%a %-I:%M %p %Z' 2>/dev/null || true)"
  fi
  # 🔴 NAME THE FILE THAT ACTUALLY HOLDS THE MARKER, NOT THE ONE THIS MASTER WOULD HAVE HAD (#7974).
  # A spread-dark master has NO state file of its own — the pool's marker is on `$via`'s box. Printed
  # against `$master` it sent a human to a path that does not exist, under a sentence promising "cleared
  # by that master's next clean run" that its own clean run cannot do. Measured in this fix's own live
  # test: `--preflight-quota bravo` cited `/home/USER/.claude/state/quota-status.json` while the only
  # markers in the fleet were alpha's and charlie's.
  # `via` is the SENTINEL `self` on a direct read, never a username — resolve it before it becomes a path
  # (it printed `/home/USER/.claude/...` in this fix's first live test run).
  local holder="$master"; [ "$via" = self ] || holder="$via"
  case "$holder" in agent|architect) path="$HOME/$QUOTA_STATE_REL" ;; *) path="/home/$holder/$QUOTA_STATE_REL" ;; esac
  {
    # #2807 — the refusal must name WHICH kind of dark, because the two have opposite remedies and a
    # human told to "wait for the reset" on a switched-off login waits forever.
    if [ "$src" = entitlement-capture ]; then
      echo "PRE-FLIGHT FAIL: '$master' is ENTITLEMENT-DARK — this login's Claude Code subscription access"
      echo "  is switched off (#2807). This is NOT a rate limit and it will NOT clear on a reset:"
      echo "  a run started now is rejected in ~8 seconds and charges the issue an attempt for it."
      echo "  master:  $master ($prov, currently signed in as $(account_for "$master"))"
      echo "  fix:     rotate this box onto a working login; its next CLEAN run clears the marker itself."
    else
      echo "PRE-FLIGHT FAIL: '$master' is QUOTA-DARK — its provider limit is still in force (#3906)."
      echo "  A run started now dies in seconds having done nothing, and charges the issue an attempt for it."
      echo "  master:  $master ($prov)"
      if [ "$resets" = unknown ]; then
        echo "  resets:  UNKNOWN — the provider stated no reset time when the limit was captured."
      else
        echo "  resets:  $resets${local_txt:+  ·  $local_txt}"
      fi
    fi
    if [ "$via" = self ]; then
      echo "  source:  $path (${src:-?}, written by task-runner.sh capture_quota, cleared by that master's next clean run)"
    else
      # The POOL half of the refusal (#7974). Without it the human reads "bravo is dark", goes looking for
      # bravo's marker and finds nothing; the actionable fact is that the ACCOUNT is dark and which box
      # proved it — and that rotating THIS box's login is a real remedy, which it never is for a self-dark
      # master.
      echo "  why:     POOL — '$master' has no marker of its own. It is signed in as"
      echo "           $(account_for "$master"), the same account as '$via', whose limit WAS captured."
      echo "           Grouping derived live from the published usage feeds at check time, not a roster."
      echo "  source:  $path (${src:-?}, written by task-runner.sh capture_quota on '$via'; cleared when"
      echo "           '$via' next runs clean, or when this box rotates onto another login)"
    fi
    if [ -n "$avail" ]; then
      echo "  available now:$avail  — dispatch this issue to one of these instead."
    else
      # #2807 — "wait for the earliest reset" is advice a master with no reset can never act on.
      if [ "$src" = entitlement-capture ]; then
        echo "  available now: NONE of [$QUOTA_MASTERS] — every master is dark, and THIS one is not waiting on a clock."
      else
        echo "  available now: NONE of [$QUOTA_MASTERS] — the whole fleet is dark. Wait for the earliest reset."
      fi
    fi
    echo "  Override (e.g. this master has since rotated onto another account):"
    echo "    DISPATCH_IGNORE_QUOTA=1 $(basename "$0") $master <issue#>"
  } >&2
  return 9
}

# Dry-run hooks, same shape as --resolve/--count/--account: inspect the quota picture, or exercise the
# REAL refusal, without consuming a master run.
#   --quota-dark [master...]         machine-readable: the dark master names, one per line (what the
#                                     sweeper reads to build ALL_UNHEALTHY)
#   --quota-dark-detail [master...]  machine-readable: "<master><TAB><reason>", reason ∈ the closed
#                                     enum `quota-exhausted` | `entitlement-dark` (#7160) — what the
#                                     sweeper reads to LOG the real condition, not a running-vs-idle guess
#   --quota      [master...]  human table: every master, dark or clear, with its reset
#   --preflight-quota <master>  runs quota_preflight() itself — exit 0 = would dispatch, 9 = refused
if [ "${1:-}" = "--quota-dark" ]; then
  # `${*:-...}` then an UNQUOTED expansion, matching --quota below: `"${@:-$QUOTA_MASTERS}"` collapses the
  # default into ONE argument containing spaces, which only works by accident (the remote `for` re-splits
  # it) and would silently mis-route a local master name.
  shift; QM="${*:-$QUOTA_MASTERS}"
  # shellcheck disable=SC2086  # $QM is a deliberate word list
  quota_dark_for $QM | cut -f1; exit 0
fi
if [ "${1:-}" = "--quota-dark-detail" ]; then
  shift; QM="${*:-$QUOTA_MASTERS}"
  # shellcheck disable=SC2086  # $QM is a deliberate word list
  # source field 4 is `429-capture` (a real limit, clears on a clock) or `entitlement-capture` (a
  # switched-off login, never clears itself) — see quota_dark_for's own comment for why they need
  # opposite remedies. This just renames the source into the two enum words the sweeper's log wants.
  quota_dark_for $QM | awk -F'\t' '{
    reason = ($4 == "entitlement-capture") ? "entitlement-dark" : "quota-exhausted"
    print $1"\t"reason
  }'
  exit 0
fi
if [ "${1:-}" = "--quota" ]; then
  shift
  QM="${*:-$QUOTA_MASTERS}"
  DARK="$(quota_dark_for $QM)"
  for M in $QM; do
    L="$(printf '%s\n' "$DARK" | awk -v m="$M" -F'\t' '$1==m{print; exit}')"
    if [ -n "$L" ]; then printf '%-6s dark   resets=%s provider=%s source=%s via=%s\n' "$M" "$(printf '%s' "$L" | cut -f2)" "$(printf '%s' "$L" | cut -f3)" "$(printf '%s' "$L" | cut -f4)" "$(printf '%s' "$L" | cut -f5)"
    else
      # "clear" is a claim about the pool only if the account feeds behind the spread are fresh; a stale
      # feed (e.g. a laptop clone that has not pulled) makes the spread decline silently, so say so.
      if account_fresh "$M"; then printf '%-6s clear\n' "$M"
      else printf '%-6s clear  (UNVERIFIED: account feed stale >%ss — pull the knowledge clone; pool-wide dark is not checked)\n' "$M" "$ACCOUNT_STALE_S"; fi
    fi
  done
  exit 0
fi
if [ "${1:-}" = "--preflight-quota" ]; then
  quota_preflight "${2:?usage: dispatch.sh --preflight-quota <master>}"; exit $?
fi

# Dry-run hooks for the issue-keyed live-run guard (#4484), same shape and same reason as the quota pair
# above: the ONLY honest way to exercise a refusal whose trigger is "a real run is happening right now" is
# to ask it about a real run, and doing that by dispatching one twice would burn the exact quota slot the
# guard exists to protect.
#   --live-units <master> <issue>        the ACTIVE task-<issue>-* unit name(s) on that master, one per line
#   --preflight-duplicate <master> <issue>  runs duplicate_preflight() itself — 0 = would dispatch, 11 = refused
#   --dedupe <master> <issue> [--dry-run]   deterministic repair for coexisting units: keep the OLDEST
#                                           live unit, stop every newer one (#6960 — never pick by eye)
if [ "${1:-}" = "--live-units" ]; then
  live_units_for_issue "${2:?usage: dispatch.sh --live-units <master> <issue#>}" \
                       "${3:?usage: dispatch.sh --live-units <master> <issue#>}"
  exit 0
fi
if [ "${1:-}" = "--preflight-duplicate" ]; then
  duplicate_preflight "${2:?usage: dispatch.sh --preflight-duplicate <master> <issue#>}" \
                      "${3:?usage: dispatch.sh --preflight-duplicate <master> <issue#>}"
  exit $?
fi
# --claim-script <master> <issue> <unit> <systemd-run cmd> → print the exact bravo-side script the launch
# below pipes over ssh, and exit. Same reason every other `--` hook here exists (#7167): the ONLY honest
# way to exercise a claim whose whole point is what happens when two dispatchers collide is to collide two
# of them for real, and doing that through a real dispatch would burn two sessions. This prints the real
# bytes — `_infra/tests/dispatch-fleet-claim-race.sh` races two copies of them against real systemd.
if [ "${1:-}" = "--claim-script" ]; then
  fleet_claim_launch_script "${2:?usage: dispatch.sh --claim-script <master> <issue#> <unit> <cmd>}" \
                            "${3:?usage: dispatch.sh --claim-script <master> <issue#> <unit> <cmd>}" \
                            "${4:?usage: dispatch.sh --claim-script <master> <issue#> <unit> <cmd>}" \
                            "${5:?usage: dispatch.sh --claim-script <master> <issue#> <unit> <cmd>}"
  exit 0
fi
if [ "${1:-}" = "--dedupe" ]; then
  dedupe_issue_units "${2:?usage: dispatch.sh --dedupe <master> <issue#> [--dry-run]}" \
                     "${3:?usage: dispatch.sh --dedupe <master> <issue#> [--dry-run]}" "${4:-}"
  exit $?
fi
# ─────────────────────────────────────────────────────────────────────────────────────────────────

# Dry-run hook, same shape as --resolve/--count above: `dispatch.sh --account [master]` prints
# "<master> <account> <live-count>" for every master (or just one) and exits — lets the account
# resolution be inspected without a live dispatch, and is how acceptance #2 ("paste the resolution") is
# exercised on demand.
if [ "${1:-}" = "--account" ]; then
  INFLIGHT="$(probe_inflight)"
  for M in alpha bravo charlie delta; do
    [ -n "${2:-}" ] && [ "$M" != "${2}" ] && continue
    N="$(printf '%s\n' "$INFLIGHT" | awk -v m="$M" '$1==m{print $2}')"
    # 4th field appended (#7974): the account string alone cannot say whether it is CURRENT, and this
    # hook is the surface #7974's acceptance compares against a live `jq .account` read. `fresh`/`STALE`
    # is the same bar quota_dark_for's grouping uses and the OCC's `accountFresh` renders — one answer.
    if account_fresh "$M"; then F=fresh; else F=STALE; fi
    printf '%s %s %s %s\n' "$M" "$(account_for "$M")" "${N:-unreachable}" "$F"
  done
  exit 0
fi
# ─────────────────────────────────────────────────────────────────────────────────────────────────

MASTER="${1:?usage: dispatch.sh <master> <issue#> [owner/repo]}"
ISSUE="${2:?usage: dispatch.sh <master> <issue#> [owner/repo]}"
REPO="${3:-example-org/kb}"
# 🔴 THE UNIT NAME CARRIES NO ENTROPY, AND THAT ABSENCE IS THE ANTI-DOUBLE-DISPATCH GUARANTEE (#6960).
#
# It used to be `task-<issue>-<epoch>-<RANDOM>`. The suffix was added 2026-08-03 when SWEEP_MAX_PER_CYCLE
# went 2→8 and two dispatches inside one second built the same name; "systemd refuses the second" was read
# as the bug. It was the FIX. Entropy made two units for ONE issue LEGAL, so nothing but a timing check
# stood between two runs — and a timing check has a window it cannot close.
#
# Measured on #6946, 2026-08-27 (fleet-host journald + ~bravo/.claude/logs/sweep-dispatch.log:10542):
#   22:05:53 sweeper stamps a unit · 22:05:55 duplicate_preflight → no unit → PASS
#   22:06:00 hand stamps a unit    · 22:06:01 duplicate_preflight → STILL no unit → PASS
#   22:06:02 both hit the shared-account stagger and sleep 20s
#   22:06:22 systemd-run (sweeper) · 22:06:27 systemd-run (hand) — 5s apart, BOTH LIVE
# Guard-to-launch is 26-27s; the two unguarded windows overlap for 21 of them. #6947 was identical. Both
# duplicates were killed by hand, both kills hit the SURVIVING run (exit=143, no artifact), and #6947
# CLOSED on that failure — the board said done on work that never ran.
#
# `task-<issue>` makes the second unit ILLEGAL rather than merely unwanted: systemd refuses it in the
# kernel, atomically, with no window at all. duplicate_preflight() above STAYS as defence in depth — it is
# belt-and-braces now rather than the only guard, and it is still the half that can explain the refusal
# before any board bookkeeping is written.
#
# The retry-after-failure regression this could have caused is measured and handled at
# launch_unit_script(): a failed unit's name frees itself in 3.5-4.5s, and the launch waits it out.
#
# DISPATCH_ALLOW_DUPLICATE=1 is the documented escape hatch for a deliberate second copy, and a
# zero-entropy name would silently make that flag a lie. It — and only it — restores a suffix. Every
# reader of this name is already suffix-OPAQUE (`^task-([0-9]+)(-.*)?\.service$`: live_units_for_issue()
# above, sweep-dispatch.sh's LIVE_ISSUES, the reaper's LIVE_ARR, the announcer's), so both forms resolve —
# verified, not assumed, in this issue's PR.
if [ "${DISPATCH_ALLOW_DUPLICATE:-0}" = "1" ]; then
  UNIT="task-${ISSUE}-dup-$(date +%s)-${RANDOM}"
else
  UNIT="task-${ISSUE}"
fi

# ── Pre-flight: issue must exist in the specified repo (#3065) ─────────────────────────────────────
# A dispatch that dispatched nothing must not exit 0. The repo arg names where the ISSUE lives
# (default example-org/kb), NOT the repo the work touches — the brief tells the master that.
# 🔴 `body` rides THIS read (#7161, PLAN-239 P3). It used to be a SECOND `gh issue view` on the same
# issue ~115 lines below, for the red-baseline check — one whole network round trip to re-fetch a field
# this call could have carried for free. Same reasoning `finish()` already applies at its own read:
# adding a field to an existing call costs no extra round trip.
ISSUE_JSON="$(gh issue view "$ISSUE" --repo "$REPO" --json number,title,state,body 2>/dev/null || true)"
if [ -z "$ISSUE_JSON" ]; then
  echo "PRE-FLIGHT FAIL: issue #$ISSUE does not exist in $REPO." >&2
  echo "  The repo arg names where the ISSUE lives (default example-org/kb)," >&2
  echo "  NOT the repo the work touches — the brief tells the master that." >&2
  exit 4
fi

# ── Pre-flight: refuse to dispatch a CLOSED issue (#4253) ─────────────────────────────────────────
# Every caller dispatches from a candidate list it read EARLIER. sweep-dispatch.sh selects with
# `issues(states:OPEN…)`, so it can never *choose* a closed issue — but between that read and this
# launch it ssh-probes four boxes for live task units and quota state, and the cycle it belongs to fires on
# a 5-minute timer. The list is stale by construction; only this file runs at launch time, so only this
# file can tell.
#
# Measured, not assumed (doctrine: a limit is a measurement). #4253 — a sweeper-filed stall report on
# fixture #4252 — was closed by the fixture's owner at 2026-08-04T21:15:45Z. dispatch.sh started for it
# at 21:16:31Z (its unit `task-4253-1785878191-13309`; `date -u -d @1785878191`), **46 seconds after the
# close**, and a master ran a full session on an issue that was already disposed of. Nothing in the
# pipeline noticed: the existence check above asked only whether the issue EXISTS, and a closed issue
# exists. That run's only possible output is a PR saying `Closes #N` on an issue that is already closed.
#
# 🔴 Writes NOTHING to the board — same reasoning as the blocked-dependency guard below. A ⛔/⏸ glyph
# here would be read by the sweeper's own last-marker predicate, converting a one-off refusal into
# permanent ineligibility if the issue is later reopened; and a comment on a closed issue is noise on
# a decision someone already made deliberately.
#
# The override exists for the real re-run case: reopening an issue is the normal path, but a deliberate
# `DISPATCH_ALLOW_CLOSED=1 dispatch.sh <master> <n>` re-runs work on an issue that stays closed.
ISSUE_STATE="$(printf '%s' "$ISSUE_JSON" | jq -r '.state // empty')"
if [ "$ISSUE_STATE" = "CLOSED" ] && [ "${DISPATCH_ALLOW_CLOSED:-0}" != "1" ]; then
  echo "PRE-FLIGHT FAIL: #$ISSUE is CLOSED in $REPO — refusing to start a run on finished work." >&2
  echo "  Title: $(printf '%s' "$ISSUE_JSON" | jq -r '.title // empty')" >&2
  echo "  Callers dispatch from a candidate list read before this moment; only this check is at launch time." >&2
  echo "  If the work is real again, REOPEN the issue — or override once with DISPATCH_ALLOW_CLOSED=1." >&2
  exit 10   # a code of its own, distinct from every other pre-flight refusal in this script
fi

# ── Pre-flight: refuse to dispatch an INTERACTIVE-only issue (#3797 lesson) ────────────────────────
# #3073 is titled "[INTERACTIVE — the operator + agent-product] [DO NOT DISPATCH] ..." — quoted verbatim and unchanged; that account was renamed `agent-product` → `gh-account5` on 2026-08-28 (knowledge#7137).
# It is a working session for a credential only the operator can hand over.
# It is never a task a master can finish alone. Nothing enforced that
# marker: bravo's self-directed loop dispatched it anyway (task-3073-1785711449, 2026-08-02), burning a
# session-limited run on a run that could only ever stall waiting on the operator, and confusing "the run
# failed" with "the issue is unstartable by design" — two different problems that need two different
# responses. "DO NOT DISPATCH" is a title convention (grep across the repo turns up no label for it), so
# the marker is checked here, the one place every dispatch path — manual or self-directed — must pass
# through.
ISSUE_TITLE="$(printf '%s' "$ISSUE_JSON" | jq -r '.title // empty')"
if is_parked_title "$ISSUE_TITLE"; then
  echo "PRE-FLIGHT FAIL: #$ISSUE is marked DO NOT DISPATCH in its title — refusing to start a run." >&2
  echo "  Title: $ISSUE_TITLE" >&2
  echo "  This is an interactive-only work item (usually a credential handoff only the operator can do)." >&2
  echo "  Work it directly with the operator in a session instead of dispatching a master onto it." >&2
  gh issue comment "$ISSUE" --repo "$REPO" --body "⛔ **Dispatch refused — this issue is marked DO NOT DISPATCH.**

A dispatch attempt for \`$MASTER\` was blocked at pre-flight (dispatch.sh, #3797). This title convention has no enforcement anywhere else in the pipeline, so a self-directed master's board-work loop can otherwise pick it up like any other open issue and burn a run on work it can never finish alone.

If this issue is ready to be worked by a master now, remove \`DO NOT DISPATCH\` from the title first." >/dev/null 2>&1 || true
  exit 8
fi

# ── Pre-flight: refuse to dispatch into a QUOTA-DARK master (#3906) ───────────────────────────────
# Placed HERE on purpose: after the issue exists (so the message can name real work) and BEFORE any
# board write below. Refusing after `--add-assignee` + `Status=Doing` would strand the issue in Doing
# with no run behind it — the exact leak Feature #3903 exists to close. quota_preflight() itself is
# defined with the other probes above; it fails open on every unreadable case and exits 9 only on a
# positively-read live exhaustion.
quota_preflight "$MASTER" || exit $?

# ── Pre-flight: refuse to dispatch a BLOCKED issue (#3791 lesson, landed under #3937) ──────────────
# Feature #3691 exists because starting an issue whose blocker is still open drives two masters into the
# same files — #3641 and #3637 both rewrote the OCC's World Infrastructure section, and the sweeper's
# predicate #4 ("every blockedBy dependency is CLOSED") was built to stop exactly that. But that guard
# landed in the CONSUMER only. This file — the path EVERY hand and batch dispatch takes, and the one the
# sweeper itself shells out to — had no notion of dependencies at all, so the bound the Feature paid for
# was bypassed by the more common caller.
# Caught the way these are supposed to be caught: on 2026-08-02 a batch dispatch started a master run on
# #3791, a TEST FIXTURE whose blocker #3788 was open and whose body says "do not dispatch by hand." The
# sweeper had correctly ignored it all evening; nothing stood between the hand path and the collision.
#
# 🔴 This refusal writes NOTHING to the board — no comment, and above all no run-marker glyph. The
# sweeper's eligibility predicate is READ OUT OF THOSE GLYPHS: ⏸ is its permanent park latch and ⛔ is
# excluded by its last-marker check, so a pre-flight that announced itself with either would convert a
# one-off refusal into permanent ineligibility and poison the very predicate it is guarding.
#
# Fails OPEN on an unreadable answer, deliberately, and the TYPE CHECK is what makes that work: `gh api`
# prints its 404/error BODY to STDOUT, so a failed call yields a JSON OBJECT rather than the empty string.
# A "non-empty" test would read an error as a blocker and refuse every dispatch the moment the endpoint
# hiccuped — a guard that fails closed on its own outage is an outage.
BLOCKERS="$(gh api "repos/$REPO/issues/$ISSUE/dependencies/blocked_by" 2>/dev/null \
  | jq -r 'if type=="array" then [.[] | select(.state=="open") | "#\(.number)"] | join(" ") else empty end' 2>/dev/null || true)"
if [ -n "$BLOCKERS" ] && [ "${DISPATCH_IGNORE_BLOCKERS:-0}" != "1" ]; then
  echo "PRE-FLIGHT FAIL: #$ISSUE is blocked by an OPEN dependency: $BLOCKERS" >&2
  echo "  This is the sweeper's predicate #4, applied to the hand path too. Close the blocker first." >&2
  echo "  If the edge itself is wrong, remove it — or override once with DISPATCH_IGNORE_BLOCKERS=1." >&2
  exit 8
fi

# ── Pre-flight: refuse to start a SECOND run for an issue already running (#4484 · Feature #4475) ──
# Placed HERE deliberately: after every free local/API check, so the one ssh round trip it costs is only
# spent on a dispatch that would otherwise proceed — and BEFORE the red-baseline check and all board
# bookkeeping below, both of which write to the board. Refusing after a ⏸ comment or after
# `Status=Doing` would leave a mark for a run that never started, on an issue that is already running.
# The implementation and its full reasoning live at duplicate_preflight() above; it fails OPEN on every
# unreadable case and returns 11 only on a positively-read ACTIVE unit for this exact issue number.
duplicate_preflight "$MASTER" "$ISSUE" || exit $?

# ── Pre-flight: refuse to dispatch INTO a red baseline (#2925 lesson) ─────────────────────────────
# On 2026-07-27 product-a's main CI was red for 14h13m (tsc TS2307). Every master dispatched during
# that window inherited an unmergeable baseline, burned its full turn budget, and was stamped ✘ for work
# that was actually correct. Nothing in the system checked. Now it does.
# Scoped deliberately: the TARGET repo is the one named in the ISSUE BODY (masters work cross-repo; $REPO
# is where the issue lives, usually knowledge). Advisory-by-default — set DISPATCH_REQUIRE_GREEN=1 to make
# it fatal. Unreadable CI is NEVER treated as red; we only stop on a confirmed failure.
# #7161: reads the body off ISSUE_JSON, fetched once at the existence pre-flight above. No second call.
TARGET_REPO=$(printf '%s' "$ISSUE_JSON" | jq -r '.body // ""' 2>/dev/null \
  | grep -oE 'example-org/(product-a|product-b|personal-agent|brain-agent-delta)' | head -1 || true)
if [ -n "$TARGET_REPO" ] && [ "$TARGET_REPO" != "$REPO" ]; then
  BASELINE=$(gh run list --repo "$TARGET_REPO" --branch main --workflow=ci.yml --limit 1 \
    --json conclusion --jq '.[0].conclusion // empty' 2>/dev/null || true)
  if [ "$BASELINE" = "failure" ]; then
    echo "WARNING: $TARGET_REPO main CI is RED — a master dispatched now inherits an unmergeable baseline." >&2
    gh issue comment "$ISSUE" --repo "$REPO" --body "⏸ **Not dispatched — \`$TARGET_REPO\` main CI is RED.**

A run started now would inherit an unmergeable baseline, burn its turn budget, and be stamped ✘ for work that is actually correct. That is exactly what happened across 2026-07-27 (14h13m red, multiple false failures).

Fix the target repo's main build first, then re-dispatch." >/dev/null 2>&1 || true
    if [ "${DISPATCH_REQUIRE_GREEN:-0}" = "1" ]; then
      echo "ERROR: refusing to dispatch into a red baseline (DISPATCH_REQUIRE_GREEN=1)" >&2
      exit 7
    fi
    echo "         Proceeding anyway (set DISPATCH_REQUIRE_GREEN=1 to make this fatal)." >&2
  fi
fi

# Project V2 constants
PROJ=PVT_kwDOEZ-Tjc4Bb8OG
F_STATUS=PVTSSF_lADOEZ-Tjc4Bb8OGzhWow3o
S_DOING=c1399a22

# Assignment IS the dispatch (DR C1/C3): set the GitHub assignee so the board's lane derives from reality.
case "$MASTER" in
  agent|architect) GH_USER=gh-account1 ;;
  alpha)   GH_USER=gh-account2 ;;
  bravo)  GH_USER=example-fleet ;;
  charlie) GH_USER=gh-account4 ;;
  delta)   GH_USER=gh-account5 ;;
  *)     GH_USER="" ;;
esac
# 🔴 2026-08-03 — ASSIGNMENT IS OFF BY DEFAULT. the operator: "it's really annoying seeing all these emails
# flooding my inbox." Every `--add-assignee` fires a GitHub notification email ("Assigned #2410 to
# @gh-account4"), and at 8 dispatches per sweep cycle that is a flood by design. Ownership is already legible
# without it: the ▶ comment names the master and the box, the Lane field carries the routing, and the live
# `task-<n>-*` unit is the real anti-double-dispatch check (the sweeper keys on the unit and the marker —
# NOT on the assignee), so nothing in the dispatch predicate regresses.
# The assignee filter in sweep-dispatch.sh reads "is a HUMAN on this?" — an unassigned issue passes it, so
# leaving the assignee unset keeps issues dispatchable rather than stranding them.
# Set SWEEP_ASSIGN=1 (or DISPATCH_ASSIGN=1) to restore the old behaviour for a single run.
if [ -n "$GH_USER" ] && [ "${DISPATCH_ASSIGN:-${SWEEP_ASSIGN:-0}}" = "1" ]; then
  if ! gh issue edit "$ISSUE" --repo "$REPO" --add-assignee "$GH_USER" >/dev/null 2>&1; then
    echo "WARNING: failed to set assignee on #$ISSUE" >&2
  fi
fi

# Set Status=Doing on dispatch (required by #2430)
# Use addProjectV2ItemById to get the item id (idempotent, returns existing item if already added)
OWNER="${REPO%%/*}"
# Board bookkeeping is NOT a reason to refuse to start work. file-issue.sh already added the issue to the
# board (field-at-filing is law), item-add is idempotent, and task-runner.sh's copy of this exact logic
# treats the same failure as a WARNING. The two files disagreed; dispatch now matches the runner.
# 2026-07-27: this fatal blocked a P0 dispatch outright — a transient GitHub API error meant the work
# never started, which is strictly worse than a wrong Status field.
ITEM_ID=$("$_SD/board-project.sh" item-add 1 --owner "$OWNER" --url "https://github.com/$REPO/issues/$ISSUE" --format json 2>/dev/null | jq -r '.id // empty' || true)  # || true is load-bearing: with set -euo pipefail, a failed gh kills the dispatch before the WARNING below
if [ -z "$ITEM_ID" ]; then
  echo "WARNING: could not get a board item id for #$ISSUE — dispatching anyway (board-reconcile.yml backstops Status)" >&2
fi
# Set Status to Doing — advisory, same reasoning as the item-add above. board-reconcile.yml is the backstop.
if [ -n "$ITEM_ID" ]; then
  if ! "$_SD/board-project.sh" item-edit --project-id "$PROJ" --id "$ITEM_ID" --field-id "$F_STATUS" --single-select-option-id "$S_DOING" >/dev/null 2>&1; then
    echo "WARNING: failed to set Status=Doing on #$ISSUE — dispatching anyway" >&2
  fi
fi

case "$MASTER" in
  agent|architect)
    # 🔴 --setenv=PATH IS LOAD-BEARING (#3511 criterion 5). `systemd-run --user` does NOT inherit the
    # caller's environment — the unit gets the systemd USER MANAGER's PATH, which on the Architect's box is
    # the stock `/usr/local/sbin:…:/snap/bin` and does NOT include `~/.local/bin`. Both `jq` AND the
    # `claude` binary itself live only there (`/home/USER/.local/bin/{jq,claude}`; nothing in /usr/bin),
    # so every dispatch to `agent` died before it could start. Measured on that box 2026-08-03 under a real
    # `systemd-run --user` unit: `jq → MISSING`, `claude → MISSING`, everything else resolved from /usr/bin.
    # The one dispatch ever attempted there — `task-3484` on 2026-07-30T23:05:33 — exited 127 in 16s on
    # `task-runner.sh: line 426: jq: command not found`, and the box's whole user journal (back to
    # 2026-07-12) contains no other task-runner invocation and no `~/.claude/worktrees` was ever created.
    # The remote branch below never hit this because it goes through `sudo -u $MASTER` on bravo, where jq and
    # claude are on the system PATH. This is a fix, not a fallback chain: one PATH, no probing, no retry.
    LAUNCH_RC=0
    LAUNCH_OUT="$(launch_unit_script "$UNIT" \
      "systemd-run --user --unit='$UNIT' --collect --setenv=PATH='$HOME/.local/bin:$PATH' bash '$HOME/dev/example-org/kb/_infra/scripts/task-runner.sh' '$ISSUE' '$REPO'" \
      | bash -s 2>&1)" || LAUNCH_RC=$?
    [ -z "$LAUNCH_OUT" ] || printf '%s\n' "$LAUNCH_OUT" >&2
    [ "$LAUNCH_RC" = 0 ] || { launch_fail_report "$LAUNCH_RC"; exit "$LAUNCH_RC"; }
    ;;
  alpha|bravo|charlie|delta)
    RUNNER="/home/$MASTER/dev/example-org/kb/_infra/scripts/task-runner.sh"
    # Pre-flight: a missing/stale runner must fail HERE, loudly — never as a silent dead unit (R4;
    # learned from the first alpha dispatch: stale clone -> 127 exit visible only in journalctl).
    #
    # 🔴 #3521 — REACHABILITY AND CONTENTS ARE TWO DIFFERENT FAILURES, AND ONLY THE REMOTE SIDE CAN TELL
    # THEM APART. The old form was `ssh … "sudo -u $MASTER test -f '$RUNNER'" || { echo "…its knowledge
    # clone is stale…"; }` — it read ANY non-zero exit as "the file is missing". But ssh exits non-zero
    # for its OWN failures too (auth, host down, Tailscale off, key rotated), long before a remote command
    # runs. Hit live 2026-07-31 dispatching product on #3457 from bravo@fleet-host: ssh printed
    # `Permission denied (publickey)` and this printed "task-runner.sh missing on product — its knowledge clone
    # is stale" while the file was present and executable (`-rwxrwxr-x … 54650 Jul 31 06:18`). Acting on
    # that message means pulling an already-current clone and re-dispatching into the identical failure.
    #
    # So the diagnosis is driven by what the REMOTE SIDE ACTUALLY SAID, not by an exit code: the remote
    # command always exits 0 and prints one of three tokens. No token back ⇒ nothing ran on the far end ⇒
    # the box is unreachable and NOTHING is known about its clone, so no clone claim may be made.
    # (Exit 255 is only ssh's *convention* for its own errors — a remote command is free to exit 255 too,
    # so an exit-code test would still conflate the two. A token a dead ssh cannot fabricate does not.)
    # ssh flags, matching probe_inflight()/write_dispatch_count(): `-n` so this never eats the caller's
    # stdin (that bug is documented at n_remote above), BatchMode so a missing key fails fast instead of
    # hanging on a prompt nothing can answer, ConnectTimeout so a dark host is a bounded failure.
    PREFLIGHT_ERR="$(mktemp)"
    trap 'rm -f "$PREFLIGHT_ERR"' EXIT
    # shellcheck disable=SC2029
    PREFLIGHT_OUT="$(ssh -n -o BatchMode=yes -o ConnectTimeout=8 "bravo@$BRAVO" \
      "if ! sudo -n -u $MASTER true 2>/dev/null; then echo SUDO_DENIED;
       elif sudo -n -u $MASTER test -f '$RUNNER'; then echo RUNNER_OK;
       else echo RUNNER_MISSING; fi" 2>"$PREFLIGHT_ERR" || true)"
    case "$PREFLIGHT_OUT" in
      *RUNNER_OK*) : ;;                                   # reachable AND current — the only pass
      *RUNNER_MISSING*)                                   # the check RAN and found no file: the real stale clone
        echo "PRE-FLIGHT FAIL: $RUNNER missing on $MASTER — its knowledge clone is stale. Pull it, then re-dispatch." >&2
        exit 3 ;;
      *SUDO_DENIED*)                                      # reachable, but this caller cannot become $MASTER
        echo "PRE-FLIGHT FAIL: reached bravo@$BRAVO but 'sudo -u $MASTER' was denied — the pre-flight never inspected $MASTER's clone, so nothing is known about it (this is NOT a stale clone)." >&2
        echo "  Fix the NOPASSWD sudo rule for bravo → $MASTER on that box, then re-dispatch." >&2
        exit 5 ;;
      *)                                                  # ssh never reached the remote command at all
        echo "PRE-FLIGHT FAIL: cannot reach bravo@$BRAVO — the box $MASTER runs on. The pre-flight never ran, so nothing is known about $MASTER's clone (this is NOT a stale clone)." >&2
        if [ -s "$PREFLIGHT_ERR" ]; then sed 's/^/  ssh: /' "$PREFLIGHT_ERR" >&2; else echo "  ssh: (no stderr; exit was silent)" >&2; fi
        echo "  Check: is the host up, is Tailscale connected, and is THIS caller's pubkey in bravo's authorized_keys? (2026-07-31: bravo dispatching from fleet-host was ssh-ing to itself with no key of its own.)" >&2
        exit 4 ;;
    esac
    rm -f "$PREFLIGHT_ERR"; trap - EXIT
    # Pre-flight 2 (#2382): every WORK clone on the box must be on a CURRENT, CLEAN main before the run
    # starts. Two proven failures came from skipping this: alpha's #2363 branched off a stale clone twice
    # (both PRs arrived CONFLICTING), and charlie spent 15 min building #2382 on a days-old feature branch
    # with dirty files. A clone that is dirty gets its WIP STASHED (never discarded) and is then reset to
    # origin/main — silently skipping a dirty clone is what let this recur.
    # #2490: the sync set is knowledge + app-repo + the TARGET repo — a dispatch into a THIRD repo (e.g.
    # #3432: this `stash push -u` + `reset --hard origin/main` is what DESTROYED a concurrent peer run's
    # work — it ran inside the ONE checkout that run was live in. It is safe to keep ONLY because
    # task-runner.sh now hands every run its own `git worktree` (run-workspace.sh) and never works the
    # clone itself. 🔴 So this loop must stay pointed at the CLONE and nothing else: a `git worktree
    # remove`/`prune --expire=now` added here would delete live peer workspaces and reinstate the bug.
    # #2490: the sync set is knowledge + app-repo + the TARGET repo — a dispatch into a THIRD repo (e.g.
    # product-c) must find its clone current-and-clean too. A MISSING target clone is CLONED ON DEMAND
    # here (proven 2026-07-25: product-c was never on any box, so a bare dispatch would land with no
    # clone and the runner's "cd to that repo's clone" would fail). The old `|| continue` silently skipped
    # exactly this case.
    TARGET_NAME="${REPO#*/}"; OWNER="${REPO%%/*}"
    # 🔴 `knowledge` IS NOT IN THIS LIST (#7161, PLAN-239 P3, the operator's call 2026-08-28). The runner owns
    # it: `task-runner.sh:sync_shared_clone()` does `pull --ff-only`, then VERIFIES the outcome by
    # comparing HEAD to FETCH_HEAD rather than trusting an exit code — strictly more careful than the
    # blind fetch+reset below — and it runs AFTER launch, so its cost sits inside the run instead of
    # serially in front of it. Measured 2026-08-28: the knowledge clone was fetched THREE times in ~5s
    # per dispatch (here, then sync_shared_clone, then run-workspace.sh before the worktree).
    # ⚠ The tradeoff, stated: a stale knowledge clone now fails INSIDE the run rather than before it.
    # Acceptable because the runner sets TASK_CLONE_SYNC_NOTE and surfaces it in the ▶ comment (#3961) —
    # visible on the issue either way, and the runner is the half that can actually prove it.
    REPO_LIST="app-repo"
    case " $REPO_LIST " in *" $TARGET_NAME "*) ;; *) REPO_LIST="$REPO_LIST $TARGET_NAME" ;; esac
    # 🔴 FLAGS (#7161). This was the ONLY ssh in the file with no `-n`, no `BatchMode` and no
    # `ConnectTimeout`, while the other eight carry all three. Consequences, all real: with no timeout a
    # hung fetch blocks the WHOLE sweep cycle, because sweep-dispatch.sh calls this synchronously; with
    # no `-n` it eats the caller's stdin — the exact bug documented at write_dispatch_count (":1129").
    # `timeout 180` bounds the remote side too: a git fetch that cannot finish in 3 minutes is a fault,
    # not slowness, and the caller learns so instead of hanging.
    # shellcheck disable=SC2029
    timeout 180 ssh -n -o BatchMode=yes -o ConnectTimeout=8 "bravo@$BRAVO" "for R in $REPO_LIST; do
        D=/home/$MASTER/dev/example-org/\$R
        if ! sudo -u $MASTER test -d \$D/.git; then
          if sudo -u $MASTER git -C /home/$MASTER/dev/example-org clone -q https://github.com/$OWNER/\$R.git 2>/dev/null; then
            echo \"  [\$R] cloned on demand\"
          else
            echo \"  [\$R] MISSING and clone FAILED — dispatch into \$R will fail\" >&2; continue
          fi
        fi
        # #7161: skip a clone already AT origin/main. Cheap check (one ls-remote vs one full fetch), and
        # it still syncs whenever it is stale — the correctness case (#3961) is untouched.
        LR=\$(sudo -u $MASTER git -C \$D ls-remote origin -h refs/heads/main 2>/dev/null | cut -f1)
        LH=\$(sudo -u $MASTER git -C \$D rev-parse HEAD 2>/dev/null)
        if [ -n \"\$LR\" ] && [ \"\$LR\" = \"\$LH\" ] && [ -z \"\$(sudo -u $MASTER git -C \$D status --porcelain)\" ]; then
          echo \"  [\$R] already at origin/main \${LH:0:8} — sync skipped\"; continue
        fi
        if ! sudo -u $MASTER git -C \$D fetch -q origin 2>&1; then
          echo \"  [\$R] FETCH FAILED — the reset below can only reach a STALE origin/main (#3961)\" >&2
        fi
        if [ -n \"\$(sudo -u $MASTER git -C \$D status --porcelain)\" ]; then
          sudo -u $MASTER git -C \$D stash push -u -q -m \"auto-stash pre-dispatch-$ISSUE\" 2>/dev/null || true
          echo \"  [\$R] dirty -> WIP stashed\"
        fi
        sudo -u $MASTER git -C \$D checkout -q main 2>/dev/null || true
        # #3961: never swallow this. A shallow clone whose graft boundary has drifted past the common
        # ancestor cannot resolve origin/main at all; \`fetch --depth=1\` + \`reset --hard FETCH_HEAD\`
        # re-anchors the boundary. Silence here is what froze alpha's doctrine for two days.
        if ! sudo -u $MASTER git -C \$D reset -q --hard origin/main 2>&1; then
          echo \"  [\$R] reset to origin/main failed — re-anchoring the shallow boundary (#3961)\" >&2
          sudo -u $MASTER git -C \$D fetch --depth=1 origin main 2>&1 &&
          sudo -u $MASTER git -C \$D reset -q --hard FETCH_HEAD 2>&1 ||
          echo \"  [\$R] ⚠ CLONE SYNC FAILED — \$MASTER will run on doctrine of UNKNOWN age\" >&2
        fi
        H=\$(sudo -u $MASTER git -C \$D rev-parse HEAD 2>/dev/null); O=\$(sudo -u $MASTER git -C \$D rev-parse origin/main 2>/dev/null)
        if [ -n \"\$H\" ] && [ \"\$H\" != \"\$O\" ]; then
          echo \"  [\$R] ⚠ STILL NOT AT origin/main: \${H:0:8} vs \${O:0:8} (#3961)\" >&2
        fi
        echo \"  [\$R] \$(sudo -u $MASTER git -C \$D log --oneline -1)\"
      done" || {
      # #3521, item 2 — the sibling pre-flight, same shape, same treatment. Every clone-level diagnosis in
      # the loop above is printed BY THE REMOTE SIDE, so it can only appear if ssh got there. An ssh-level
      # failure here therefore says nothing about any clone, and under `set -euo pipefail` it used to abort
      # the whole dispatch with no message at all — a silent exit is a milder version of the same defect
      # (the reader is told nothing rather than told the wrong thing).
      echo "PRE-FLIGHT FAIL: lost the connection to bravo@$BRAVO while syncing $MASTER's clones — the sync did not complete, so the clones' state is UNKNOWN (this is NOT a report that they are stale)." >&2
      echo "  Re-dispatch once the box is reachable; the sync is idempotent." >&2
      exit 4
    }

    # ── The shared-account stagger is GONE (#7162, PLAN-239 P2, 2026-08-28) ────────────────────
    # What stood here: `probe_inflight()` (one ssh), then `sleep 20` whenever any OTHER master on the
    # same account had a run in flight. All four masters share one Claude account, so once the fleet
    # was doing anything at all, EVERY subsequent dispatch paid a flat 20 seconds.
    #
    # 🔴 IT COULD NOT DO THE JOB ITS OWN COMMENT CLAIMED. That comment argued from measured swap
    # pressure at 4 concurrent runs — but a stagger does not lower concurrency, it reaches the same
    # load 20 seconds later. It defended a memory problem with a mechanism that cannot affect memory.
    #
    # 🔴 AND THE COLLISION IT WAS FILED FOR IS ALREADY FIXED, BETTER. #3420 was two dispatches landing
    # 5s apart with nothing aware. #6960 gave every unit a zero-entropy name (`task-<issue>`), so a
    # double-dispatch now dies ATOMICALLY IN THE KERNEL — systemd refuses the second unit. The original
    # job is done by a stronger mechanism; what remained here was dead sleep.
    #
    # 🔴 AND IT INVERTED UNDER PARALLELISM, which is why it had to go BEFORE #7163 (P5). A stagger is a
    # stagger only because the caller is serial: run N dispatches concurrently and all N sleep 20s
    # TOGETHER, then launch in the same instant. It becomes a synchronizer — the exact opposite of its
    # purpose. Parallel dispatch with this still in place would have been worse than no change at all.
    #
    # `probe_inflight()` survives for `--account` (:1843), which reports contention as INFORMATION.
    # Nothing on the dispatch path reads it: same-master concurrency is unlimited by design, and the
    # OCC's `N run` column is where that number belongs.

    # Per-dispatch login override: DISPATCH_CLAUDE_TOKEN_FILE=<path ON THE MASTER'S BOX> makes this run
    # authenticate with the long-lived OAuth token in that file (task-runner.sh exports it as
    # CLAUDE_CODE_OAUTH_TOKEN) instead of the box's own ~/.claude login -- the escape hatch for a box whose
    # login is quota-dark while another seat is clear. Only the PATH travels in the unit environment, never
    # the secret. DISPATCH_ACCOUNT_LABEL=<email> is the account the ▶/✔ comments should name.
    TURNS="${DISPATCH_MAX_TURNS:-200}"  # big checklists need more than the default cap (11/27 runs hit 80)
    # The claim-or-refuse script runs ON THE BOX, fed over ssh STDIN to `bash -s` — one round trip, and
    # the retry that covers systemd's measured ~4s unload of a failed unit happens where the units are
    # rather than as a second ssh. Feeding stdin here also means this ssh cannot eat the caller's
    # (the bug `-n` documents at n_remote above).
    #
    # #3521, item 2 — the launch itself. `set -euo pipefail` made a failure here exit silently with ssh's
    # status, so the caller saw no "dispatched" line and no reason either. Every exit code is now named,
    # and the box's own words are printed before the interpretation.
    LAUNCH_RC=0
    # 🔴 NO `-n` ON THIS ONE, DELIBERATELY (#7161): the claim script is fed to `bash -s` on stdin, so
    # `-n` would send it /dev/null and launch nothing. BatchMode + ConnectTimeout + an outer timeout are
    # safe and were missing; a launch that cannot connect must fail fast, not hang the sweep cycle.
    # shellcheck disable=SC2029
    LAUNCH_OUT="$(fleet_claim_launch_script "$MASTER" "$ISSUE" "$UNIT" \
      "systemd-run --user --unit='$UNIT' --collect --setenv=TASK_BACKEND=claude --setenv=TASK_MAX_TURNS=$TURNS${DISPATCH_CLAUDE_TOKEN_FILE:+ --setenv=TASK_CLAUDE_TOKEN_FILE='$DISPATCH_CLAUDE_TOKEN_FILE'}${DISPATCH_ACCOUNT_LABEL:+ --setenv=TASK_ACCOUNT='$DISPATCH_ACCOUNT_LABEL'} bash '$RUNNER' '$ISSUE' '$REPO'" \
      | timeout 120 ssh -o BatchMode=yes -o ConnectTimeout=8 "bravo@$BRAVO" "bash -s" 2>&1)" || LAUNCH_RC=$?
    [ -z "$LAUNCH_OUT" ] || printf '%s\n' "$LAUNCH_OUT" >&2
    [ "$LAUNCH_RC" = 0 ] || { launch_fail_report "$LAUNCH_RC"; exit "$LAUNCH_RC"; }
    ;;
  *) echo "unknown master: $MASTER" >&2; exit 2 ;;
esac

# ── THE PLAN-FILE HEADER STAMP — REMOVED (#4319, and its machinery deleted by #7159) ─────────────
# `advance_plan_step 8 "DISPATCHED"` stood here and wrote `STEP 8/8 · DISPATCHED` onto line 1 of the
# dispatching session's plan file. the operator removed it on 2026-08-05 (knowledge#4319): the plan markdown
# carries no status at all any more. Measured the day it was removed, the file said `STEP 6/8 · SPEC`
# while the registry said `step:4` — one plan asserting two different steps at once, because the header
# had TWO writers (the approval hook stamped 6, this line stamped 8) and NOTHING wrote 7, so it could
# only ever be correct by accident; and the sweeper — now the primary dispatcher — never reached this
# line at all, freezing the header at 6 while the work completed.
#
# The call was left commented out for two months. #7159 deleted the function it named, and the
# transcript resolver under it, because a disabled call site kept an always-empty 8 MiB read alive in a
# hot path. The step lives in ONE place: the registry's `step:N@<iso>` ref, rendered by the OCC's
# Planning section. 🔴 Do not restore a second writer for it.

# The registry half of the same stamp (#3547): flip this plan's entry to Dispatched and write its `gh:`
# reference. It resolves the entry from the ISSUE (#4464), so it needs nothing from this session at all.
# `|| true` because bookkeeping may never kill a launched dispatch (#3315).
register_plan_dispatched "$ISSUE" "$REPO" || true

# The unit is up, so it is countable: refresh the count the statusline renders (#3365). After the launch
# for the same reason — a count that includes a dispatch that never started is the same lie.
write_dispatch_count >/dev/null 2>&1 || true

echo "dispatched #$ISSUE ($REPO) → $MASTER as $UNIT — watch the issue for ▶/✔ comments"
