#!/usr/bin/env bash
# task-runner.sh <issue#> [repo] — the ALPHA rebuild's entire agent runtime (DR 2026-07-23, C3 / #2285).
#
# One dispatched run per task: announce start on the issue → claude -p under THIS master's own
# subscription OAuth → trap EXIT announces ✔/✘ + the PR link on the same issue. No resident process,
# no heartbeat, no watchdog: liveness = "did my run post its close-out comment on the issue."
# Never --bare (it disables OAuth). --max-turns is the runaway cap.
set -uo pipefail

# ── SHARED-CLONE SYNC (#3961) ──────────────────────────────────────────────────────────────────────
# This used to be one line — `git pull -q --ff-only origin main 2>/dev/null || true` — and BOTH halves
# of that suffix were load-bearing failures. `2>/dev/null` threw away the reason and `|| true` threw
# away the exit code, so a clone that could not sync was indistinguishable from one that did.
#
# 🔴 The shared clone is NOT just "where the script lives". Every master's `~/.claude/rules/` symlinks
# into `<clone>/_process/` (DR 2026-07-23, C5) — same inode — so a frozen clone is
# FROZEN DOCTRINE, and the per-run worktree (#3432) hides it completely: run-workspace.sh builds the
# worktree from a freshly fetched origin/main, so the model's tree is current while the doctrine the
# session loaded is days old. Measured 2026-08-03: alpha ran four merged dispatches off a clone stuck at
# 304bad4e while origin/main was cb64c2a6 — its identity-and-scope.md was 2,464 B against 4,138 B
# everywhere else, i.e. it was missing the #3728/#3902 "before you write needs-the operator" section entirely.
# A master was making needs-the operator calls without the rule that governs them, for two days, silently.
#
# ROOT CAUSE, reproduced not theorised: all five clones are shallow (`--is-shallow-repository` → true).
# Once a shallow clone's graft boundary drifts past the common ancestor, ff-only cannot resolve —
# `fatal: Not possible to fast-forward` / `refusing to merge unrelated histories`. `fetch --depth=1` +
# `reset --hard FETCH_HEAD` RE-ANCHORS the boundary and always resolves, for shallow and deep alike.
#
# Layered, loudest-last: ff-only pull → re-anchor → report. The re-anchor is safe because since #3432
# the shared clone is only an object store + the source of this script; no run works in it. Dirty
# content is stashed first anyway (never discarded), mirroring dispatch.sh's Pre-flight 2.
#
# Sets TASK_CLONE_SYNC_NOTE when the clone is NOT at origin/main after all of it — exported so it
# survives the re-exec below and lands in the ▶ comment. **Silence must not be a possible outcome.**
sync_shared_clone() {
  local d="$1" out rc
  git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || {
    TASK_CLONE_SYNC_NOTE="clone sync SKIPPED — \`$d\` is not a git repository"; return 1; }

  out="$(git -C "$d" pull --ff-only origin main 2>&1)"; rc=$?
  if [ $rc -ne 0 ]; then
    echo "clone-sync: ff-only pull failed in $d (rc=$rc) — re-anchoring the shallow boundary" >&2
    printf '%s\n' "$out" | sed 's/^/clone-sync:   /' >&2
    [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ] &&
      git -C "$d" stash push -u -q -m "auto-stash pre-clone-sync $(date -u +%FT%TZ)" 2>/dev/null || true
    out="$(git -C "$d" fetch --depth=1 origin main 2>&1 && git -C "$d" reset --hard -q FETCH_HEAD 2>&1)"; rc=$?
    if [ $rc -ne 0 ]; then
      TASK_CLONE_SYNC_NOTE="⚠ clone sync FAILED — \`$d\` could not be brought to origin/main; this run grounded itself in doctrine of UNKNOWN age. Last error: \`$(printf '%s' "$out" | tr '\n' ' ' | head -c 300)\`"
      echo "clone-sync: RE-ANCHOR ALSO FAILED in $d — $out" >&2
      return 1
    fi
    echo "clone-sync: re-anchored $d to $(git -C "$d" rev-parse --short HEAD)" >&2
  fi

  # Verify the OUTCOME, never the command's exit code: a pull can exit 0 against a stale remote ref.
  git -C "$d" fetch -q origin main 2>/dev/null || true
  local head remote
  head="$(git -C "$d" rev-parse HEAD 2>/dev/null)"
  remote="$(git -C "$d" rev-parse FETCH_HEAD 2>/dev/null || git -C "$d" rev-parse origin/main 2>/dev/null)"
  if [ -n "$head" ] && [ -n "$remote" ] && [ "$head" != "$remote" ]; then
    TASK_CLONE_SYNC_NOTE="⚠ clone \`$d\` is at \`${head:0:8}\` but origin/main is \`${remote:0:8}\` — doctrine loaded this session may be stale (#3961)"
    return 1
  fi
  return 0
}

# Self-update FIRST (scope addition 2026-07-25): pull our own repo before stale code can run.
# exec-once pattern — NEVER mutate the script a running bash is still reading (mid-run splice hazard):
# pull, then re-exec the fresh version exactly once.
if [ -z "${TASK_RUNNER_UPDATED:-}" ]; then
  _SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  _REPO_DIR="$(cd "$(dirname "$_SELF")/../.." && pwd)"   # _infra/scripts/ -> repo root
  TASK_CLONE_SYNC_NOTE=""
  sync_shared_clone "$_REPO_DIR" || true
  export TASK_CLONE_SYNC_NOTE
  TASK_RUNNER_UPDATED=1 exec bash "$_SELF" "$@"
fi

ISSUE="${1:?usage: task-runner.sh <issue#> [owner/repo]}"
REPO="${2:-example-org/kb}"
# 200, not 80: measured 2026-07-27 — 11 of 27 transcripts hit the old cap, and real PRODUCT runs cluster at
# 129-163 assistant messages. #2901 died at 80 with nothing merged, then shipped 14/14 in 20.5 min at 200.
#
# RE-MEASURED 2026-08-02 (#3433) — HOLD AT 200. The question was whether the 7 `error_max_turns` failures
# in the mechanism's first 169 runs justify another raise. They do not, and the reason is not "those runs
# were thrashing": NONE OF THEM RAN AT 200. Every max-turns envelope states its own cap verbatim
# (`"errors":["Reached maximum number of turns (N)"]`), and across every dispatch in knowledge +
# product-a there are exactly 8 such events — N=80 (x6), N=110, N=150. All eight were CONVERGING, not
# thrashing: all eight issues are closed, six were finished by the very next re-dispatch (four inside 12
# minutes), and two had ALREADY OPENED THEIR PR when the cap killed them (#2278 died 19s after opening
# PR#2308; #2407's PR#2421 had merged 5.5 min earlier and the run overran on post-merge work). So they are
# evidence FOR the raise that already happened — they are silent about 200.
#
# What 200 itself has done: 131 dispatches at this cap, across all four masters — ZERO error_max_turns. Turns-to-completion on the 25 charlie runs whose transcripts are on-box:
# p50 89, p75 110, p90 146, max 164 — 36 turns of headroom under the cap that has never once bound a run.
# 15 of those 25 exceeded 80, so the raise is load-bearing; a further raise buys nothing measurable and
# only lengthens the runs that were never going to converge. ⚠ 200 is not free of other ceilings: the
# GitHub installation token expires at 1h (see :556) and long runs meet that first.
#
# RE-MEASURE ON EVIDENCE, NEVER INTUITION — the trigger is a close-out carrying the class
# `max-turns -- consumed all 200 turns` that classify_error() below emits. One is a datapoint; three in a
# week means the ceiling moved. Find them without a transcript:
#   gh api --paginate 'repos/example-org/kb/issues/comments?since=<ISO8601>' \
#     --jq '.[]|select(.body|test("Reached maximum number of turns"))|.body[0:160]'
MAXT="${TASK_MAX_TURNS:-200}"
WHO="$(whoami)@$(hostname -s)"
# CLONE is the master's ONE shared checkout — the object store, and the copy of this script that is
# running. WORKDIR is where the MODEL works, and after the isolation block below it is a per-run
# `git worktree`, never the shared clone (#3432: two dispatches to one master shared a tree, and the
# second one's `reset --hard origin/main` pre-flight silently destroyed the first one's work mid-run).
# Resolved to its PHYSICAL path: git records a new worktree's `.git` pointer from the path it resolved
# the repo through, so an aliased CLONE (symlink / moved parent) can mint a pointer naming a path that
# does not exist — #3820, where two runs got workspaces in which every git command died.
CLONE="${TASK_WORKDIR:-$HOME/dev/example-org/kb}"
CLONE="$( cd "$CLONE" 2>/dev/null && pwd -P || printf '%s\n' "$CLONE" )"
WORKDIR="$CLONE"
# 🔴 Declared HERE, before the EXIT trap can ever fire — `set -u` would abort the trap itself on an
# unset name if a run died early. Same reasoning as the retry state at :57.
WS=""; WS_TARGET=""; WS_TARGET_CLONE=""
# #3812 — the process's own exit code, overridden by finish() when the ARTIFACT proves real success
# regardless of $rc (mirrors the "derive the terminal from the artifact, not the exit code" rule at
# :435 — that rule already covered the issue COMMENT; the process exit code was the one place still
# blindly forwarding $rc). Empty = no override, fall back to $rc.
FINISH_EXIT=""
# #7167 — 🔴 A DELIBERATE STOP IS NOT A FAILURE, and only this process can tell the difference.
# `systemctl --user stop task-<n>.service` sends SIGTERM; the trap below re-raises it as `exit 143`, and
# every branch downstream then read 143 as "the run crashed and produced no artifact" → `✘ failed`. On
# 2026-08-28 three issues (#7124 #7125 #7148) had a duplicate run stopped by hand within ~10 minutes, and
# each one's LAST marker became a ✘ describing work that was, at that moment, still succeeding in the
# SURVIVING run — the Architect's monitor classifies a phase by that last marker, so a correct cleanup and
# a real failure were indistinguishable. #7124 CLOSED reading `starts=2 last=✘`.
#
# Declared HERE with FINISH_EXIT for the same reason it is: `set -u` would abort the EXIT trap itself on an
# unset name if a run died before reaching the body.
TERMINAL_POSTED=0    # 1 = THIS PROCESS has already posted its ✔/✘/⚠/⛔/⏹ (see finish()'s guard, #7167)
RUN_STOPPED=0        # 1 = a terminating signal was delivered from OUTSIDE this process
RUN_STOP_SIGNAL=""   # TERM | INT | HUP — which one arrived
RUN_STOP_EVIDENCE="" # what systemd itself said about this unit at the instant the signal landed
# #3523 acceptance 2 — captured HERE, before the ▶ post or any work, so finish() can tell "an artifact THIS
# run produced" from "one that already existed and closed the issue before this dispatch even began" (a
# stale/duplicate dispatch onto an already-closed issue, e.g. two masters racing the same issue, or a manual
# re-dispatch after the merge already landed). GitHub's own PR timestamps are UTC ISO-8601 with a `Z` suffix,
# same shape as this one, so a plain string compare orders them correctly.
RUN_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Run-scoped state (#2613): the ONLY reliable way the runner learns the model's REAL repo+branch when it
# works CROSS-REPO — the model's `cd` happens in its own subprocess, so the runner's cwd never moves and a
# cwd-based `git branch` lookup is dead code for cross-repo runs. The model records repo+branch here; the
# artifact check reads it. Cleared at start so a prior run's state never leaks into this one.
RUN_STATE="$HOME/.claude/state/task-run-$ISSUE.json"
mkdir -p "$(dirname "$RUN_STATE")" 2>/dev/null || true
rm -f "$RUN_STATE" 2>/dev/null || true

# Project V2 constants (from dispatch.sh) — required for Status field updates
PROJ=PVT_kwDOEZ-Tjc4Bb8OG
# Board writes go through board-project.sh, not `gh project` — that CLI refuses client-side without
# read:org/read:discussion, neither of which is in any decided token shape (#6563).
_BOARD_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-project.sh"
F_STATUS=PVTSSF_lADOEZ-Tjc4Bb8OGzhWow3o
S_DOING=c1399a22
S_TODO=cbac0e73
S_BLOCKED=d1090403

# Derive the Claude account this run authenticates as (knowledge#2347). DERIVED, never declared: the
# registry cannot say, because the login a box holds rotates.
if [ -n "${TASK_ACCOUNT:-}" ]; then
  ACCOUNT="${TASK_ACCOUNT:-}"                       # explicit override wins
else
  # Read the REAL logged-in account from the local Claude config (oauthAccount), never hardcode.
  ACCOUNT=$(python3 -c "import json;print((json.load(open('$HOME/.claude.json')).get('oauthAccount') or {}).get('emailAddress',''))" 2>/dev/null)
  [ -z "$ACCOUNT" ] && ACCOUNT="unknown"
fi

# Per-dispatch login override (dispatch.sh DISPATCH_CLAUDE_TOKEN_FILE): a file on THIS box holding a
# long-lived OAuth token. Read here so only a path ever travels in the unit environment.
if [ -n "${TASK_CLAUDE_TOKEN_FILE:-}" ] && [ -r "$TASK_CLAUDE_TOKEN_FILE" ]; then
  CLAUDE_CODE_OAUTH_TOKEN="$(tr -d '[:space:]' < "$TASK_CLAUDE_TOKEN_FILE")"; export CLAUDE_CODE_OAUTH_TOKEN
fi

STATE=running; RESULT=""; SESSION=""
# Retry/classification state (#3417). Initialised HERE, before the EXIT trap can ever fire: finish() reads
# every one of these, and `set -u` would abort the trap itself on an unset name if a run died early.
OUT=""; RUN_TURNS=0; RUN_SUBTYPE=""
ATTEMPT=0; ATTEMPT_LOG=""; RETRY_NOTE=""; ERR_CLASS=""; ERR_TEXT=""
MAX_ATTEMPTS="${TASK_MAX_ATTEMPTS:-3}"
# 30s -> 2m -> 8m. Each gap must outlast the Claude SDK's OWN internal retry ladder, measured at ~212s
# against a first-request 529 (#3399 211s, #3396 212s/215s, #2809 213s -- nothing else in 169 runs sits in
# that band). A shorter gap just re-enters the same degraded window the SDK already spent 3.5 min losing to.
BACKOFFS="${TASK_RETRY_BACKOFFS:-30 120 480}"

# ── Last-moment re-check: was this issue DISPOSED OF during the launch window? (#5788) ────────────
# Two gates already ask this question and both are correct: `sweep-dispatch.sh` holds `test-fixture`
# out of its candidate list (#3789), and `dispatch.sh` refuses a CLOSED issue at pre-flight (#4253).
# Both ran, both did exactly what they were built to do, and both still lost — because neither of them
# is the last moment. THIS run is the measurement (issue #5788, unit `task-5788-1786804561-2943`):
#
#   14:36:01Z  dispatch.sh reads the issue at pre-flight   (the unit-name epoch, 1786804561)
#   14:36:03Z  `test-fixture` applied by the fixture's owner
#   14:36:05Z  issue CLOSED as `not_planned` — "throwaway artifact of #5780's acceptance run"
#   14:36:12Z  systemd starts the unit
#   14:36:15Z  ▶ posted, and a master spent a full session on disposed-of board residue
#
# The window is 14 seconds wide and every second of it is AFTER the last check. dispatch.sh's own note
# says "only this file runs at launch time, so only this file can tell" — true against the sweeper's
# 5-minute cycle, false against itself: the unit start, the `exec` re-entry, the shared-clone sync and
# the credential decrypts all sit between its read and this line. The next statement posts ▶ and hands
# the issue to a model, so this is the genuine point of no return. The check belongs where it can be
# right, not where it was cheap.
#
# Two signals only, and deliberately not the sweeper's whole HOLD_LABELS set. `backlog` or `needs:the operator`
# on a hand-dispatched issue is a judgement call a human may legitimately override at the CLI; CLOSED
# and `test-fixture` are the two that mean *this was disposed of / was never work at all*, and both are
# already refused elsewhere in the pipeline. Re-asking those two here duplicates no policy — it just
# asks them late enough to matter.
#
# 🔴 Writes NOTHING to the board, and returns before the ▶ post, for two independent reasons:
#   1. `trap run_exit_trap EXIT` is not installed until :1170, so no ✔/✘/⚠ can fire from this path.
#   2. ▶/✔/⛔ are TERMINAL to `sweep-dispatch.sh` predicate 6. Any glyph posted here would make the
#      issue permanently undispatchable if it is ever reopened, converting a one-off refusal into a
#      silent leak. #4253 refused to comment for this exact reason; this inherits that verbatim.
#
# 🔴 Fails OPEN. An unreadable `gh` (expired token, network, rate limit) returns empty and the run
# proceeds — a transient read must never kill a legitimate dispatch. Only a positively-read disposal
# stops anything. `DISPATCH_ALLOW_CLOSED=1` overrides both signals, matching dispatch.sh's own escape
# hatch; it is exported into the unit's environment, so a deliberate re-run still works end to end.
#
# Pinned by `_infra/tests/task-runner-disposal-recheck.sh`, which extracts THESE bytes and runs them
# against a stubbed `gh` — never a copy.
disposal_recheck() {   # <issue> <repo> → 0 workable · 1 disposed of (reason on stdout)
  local n="$1" repo="$2" js st fx why
  [ "${DISPATCH_ALLOW_CLOSED:-0}" = "1" ] && return 0
  js="$(gh issue view "$n" --repo "$repo" --json state,labels 2>/dev/null || true)"
  [ -n "$js" ] || return 0
  st="$(printf '%s' "$js" | jq -r '.state // empty' 2>/dev/null)"
  fx="$(printf '%s' "$js" | jq -r '[.labels[]?.name] | index("test-fixture") // empty' 2>/dev/null)"
  why=""
  [ "$st" = "CLOSED" ] && why="it is CLOSED"
  [ -n "$fx" ] && why="${why:+$why and }it carries \`test-fixture\`"
  [ -n "$why" ] || return 0
  printf '%s\n' "$why"
  return 1
}

if DISPOSAL_WHY="$(disposal_recheck "$ISSUE" "$REPO")"; then :; else
  echo "PRE-FLIGHT FAIL (last moment): #$ISSUE was disposed of during the launch window — $DISPOSAL_WHY." >&2
  echo "  dispatch.sh read this issue seconds earlier and it was workable then; it is not now (#5788)." >&2
  echo "  Nothing was posted to the issue: a ▶/✔/⛔ glyph here is terminal to sweep-dispatch.sh predicate 6," >&2
  echo "  which would make the issue permanently undispatchable if it is later reopened." >&2
  echo "  To re-run work on a deliberately-disposed-of issue: DISPATCH_ALLOW_CLOSED=1." >&2
  exit 11   # distinct from dispatch.sh's 10 (its own CLOSED refusal) so the two are tellable apart
fi

# Post ▶ immediately - before any work that could fail (#2362)
# #3961 — the ▶ line now states the CLONE's age, because the doctrine this session loaded came from the
# shared clone's working tree (the `~/.claude/rules` symlinks), not from the per-run worktree. Printing
# the HEAD makes age READABLE instead of assumed, and TASK_CLONE_SYNC_NOTE (set by sync_shared_clone
# above, before the re-exec) makes a failed sync LOUD on the issue instead of silent on the box.
CLONE_HEAD="$(git -C "$CLONE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
CLONE_AGE="doctrine clone \`$CLONE_HEAD\`"
if [ -n "${TASK_CLONE_SYNC_NOTE:-}" ]; then
  CLONE_AGE="$CLONE_AGE
${TASK_CLONE_SYNC_NOTE}"
fi
gh issue comment "$ISSUE" --repo "$REPO" \
  --body "▶ started — \`$WHO\` · account \`$ACCOUNT\` (dispatched run; max-turns $MAXT) · $CLONE_AGE" >/dev/null 2>&1 || true

# --- Artifact discovery (#2613) — a run earns ✔ ONLY with a REAL artifact; rc=0 is NOT sufficient ---
# We DERIVE the artifact from GitHub's own record of the PRs that CLOSE this issue
# (closedByPullRequestsReferences). This is (a) precise — a mere MENTION of the issue by unrelated work does
# NOT count, only a PR that closes it (exactly what the brief instructs the model to open), so a run that
# refused/produced nothing yields EMPTY → ⚠ no-op, not a false ✔ — and (b) repo-agnostic — it returns the
# PR's ACTUAL repo, so a cross-repo PR is found even though the runner's cwd never left $WORKDIR (the
# cross-repo dead-code bug). Verified live on #2613: #2571→PR#2575 merged (✔); #2551 refused→empty (⚠).
# Sets: ART_KIND (pr_merged|pr_open|commits|none), ART_PR_NUM, ART_PR_REPO, ART_PR_URL, ART_DRAFT,
# ART_PR_MERGED_AT (pr_merged only — empty otherwise; #3523 acceptance 2 reads it against $RUN_STARTED_AT).
# ART_PR_CREATED_AT (all PR types — used to verify the PR was created by THIS run, not a previous one).
ART_KIND=none; ART_PR_NUM=""; ART_PR_REPO="$REPO"; ART_PR_URL=""; ART_DRAFT=0; ART_PR_MERGED_AT=""; ART_PR_CREATED_AT=""
# Store the authoritative list of PRs that actually closed this issue (for validation in all paths)
AUTHORITATIVE_CLOSING_PRS=""
discover_artifact() {
  ART_KIND=none; ART_PR_NUM=""; ART_PR_REPO="$REPO"; ART_PR_URL=""; ART_DRAFT=0; ART_PR_MERGED_AT=""
  local owner name nodes pick
  owner="${REPO%%/*}"; name="${REPO##*/}"
  nodes=$(gh api graphql -f query="{repository(owner:\"$owner\",name:\"$name\"){issue(number:$ISSUE){closedByPullRequestsReferences(first:20,includeClosedPrs:true){nodes{number state merged mergedAt createdAt isDraft url headRefName repository{nameWithOwner}}}}}}" \
          --jq '.data.repository.issue.closedByPullRequestsReferences.nodes' 2>/dev/null || echo '[]')
  [ -z "$nodes" ] && nodes='[]'
  # Save the authoritative list for validation - this is the source of truth for which PRs actually closed this issue
  AUTHORITATIVE_CLOSING_PRS="$nodes"

  # Helper: check if a given PR actually closed THIS issue (not just mentioned it)
  # Returns 0 if PR is in the authoritative closing list, 1 otherwise
  # This prevents false positives where a PR mentions the issue number but doesn't close it (#5126)
  pr_actually_closes_issue() {
    local pr_num="$1" pr_repo="$2"
    [ -n "$pr_num" ] && [ -n "$pr_repo" ] || return 1
    printf '%s' "$AUTHORITATIVE_CLOSING_PRS" | jq -e --argjson num "$pr_num" --arg repo "$pr_repo" '
      any(.[] | (.number == $num) and (.repository.nameWithOwner == $repo))
    ' >/dev/null 2>&1
  }

  # Prefer a MERGED PR; else the newest OPEN one. #3489 — an OPEN PR is DISCOVERED here but is NOT shipped:
  # the close-out marks it ⚠ and leaves the issue open. Armed-is-shipped was the assumption that let 15 PRs
  # stack up while every run reported ✔.
  # #3914 (scope widened by the Architect, 2026-08-03) — a VERIFY task's PR audits its parent Feature's
  # sub-issues and its body routinely names several of them ("Closes #3890, #3891, #3892…"), which makes
  # closedByPullRequestsReferences report it against SIBLING issues too. Proven on the wire: PR #3916
  # (branch `verify-3891-feature-3890`, the auditor for #3891/Feature #3890) closed #3892 and #3893 — both
  # of which its own report scored 0/8. A verify-branch PR may only ever be this issue's artifact when the
  # branch's OWN embedded issue number IS this issue (the verify task's own self-close) — never a sibling
  # it merely mentioned. Branch shape is `verify-<N>-...` or `<N>-verify-...` (optionally namespaced,
  # `charlie/3904-verify-feature-3903`); unparseable branches are NOT excluded (fail open, matches
  # verification_evidence()'s own bias at :430 — an unknown shape must never block a genuine close).
  pick=$(printf '%s' "$nodes" | jq -c --argjson iss "$ISSUE" '
    [ .[] | . as $n
      | (($n.headRefName // "")) as $b
      | ( ($b | capture("(^|/)(?<n>[0-9]+)-verify-").n) //
          ($b | capture("(^|/)verify-(?<n>[0-9]+)-").n) // null ) as $owner
      | select( ($owner == null) or ($owner == ($iss|tostring)) )
      | $n
    ] | [.[] | select(.merged==true)][0] // [.[] | select(.state=="OPEN")][-1] // empty' 2>/dev/null)
  if [ -n "$pick" ]; then
    ART_PR_NUM=$(printf '%s' "$pick" | jq -r '.number')
    ART_PR_REPO=$(printf '%s' "$pick" | jq -r '.repository.nameWithOwner')
    ART_PR_URL=$(printf '%s' "$pick" | jq -r '.url')
    ART_PR_MERGED_AT=$(printf '%s' "$pick" | jq -r '.mergedAt // empty')
    ART_PR_CREATED_AT=$(printf '%s' "$pick" | jq -r '.createdAt // empty')
    [ "$(printf '%s' "$pick" | jq -r '.isDraft')" = "true" ] && ART_DRAFT=1
    if [ "$(printf '%s' "$pick" | jq -r '.merged')" = "true" ]; then ART_KIND=pr_merged; else ART_KIND=pr_open; fi
    return 0
  fi
  # Cross-repo fallback: the model recorded its real repo+branch (a cross-repo closing ref does NOT populate
  # closedByPullRequestsReferences, which is same-repo only). Find its PR in that repo by branch.
  if [ -s "$RUN_STATE" ]; then
    local rrepo rbranch rpr
    rrepo=$(jq -r '.repo // empty' "$RUN_STATE" 2>/dev/null)
    rbranch=$(jq -r '.branch // empty' "$RUN_STATE" 2>/dev/null)
    if [ -n "$rrepo" ] && [ -n "$rbranch" ]; then
      rpr=$(gh pr list --repo "$rrepo" --head "$rbranch" --state all --json number,state,url,isDraft,mergedAt,createdAt \
            --jq 'sort_by(.mergedAt // "") | last // empty' 2>/dev/null)
      if [ -n "$rpr" ]; then
        local check_num check_repo check_body
        check_num=$(printf '%s' "$rpr" | jq -r '.number')
        check_repo=$(printf '%s' "$rpr" | jq -r '.repository.nameWithOwner // .repository.name // empty')
        [ -z "$check_repo" ] && check_repo="$rrepo"
        # 🔴 CRITICAL VALIDATION (#5126): verify this PR actually closed THIS issue
        # A PR found by branch name might be unrelated - it could have been merged for a different issue
        # or simply mention this issue number in logs/comments without closing it
        #
        # For cross-repo PRs with bare closing references (e.g., "Closes #5060" instead of
        # "Closes example-org/kb#5060"), GitHub does NOT populate closedByPullRequestsReferences.
        # So AUTHORITATIVE_CLOSING_PRS is empty and we must validate by parsing the PR body instead.
        check_body=$(gh pr view "$check_num" --repo "$check_repo" --json body --jq '.body // ""' 2>/dev/null || echo "")
        if ! printf '%s\n' "$check_body" | grep -iE '\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\b' \
             | grep -qE "#${ISSUE}([^0-9]|\$)"; then
          echo "discover_artifact: cross-repo fallback found ${check_repo}#${check_num} by branch, but it does NOT close #$ISSUE — continuing to other fallbacks (#5130)" >&2
          # Don't return 1 - continue to org-wide search and pushed-branch fallbacks (#5130)
        else
          # Verify-branch ownership (as the org-wide search does): a VERIFY task's PR naming a sibling issue
          if [[ "$rbranch" =~ (^|/)([0-9]+)-verify- ]]; then
            local cowner="${BASH_REMATCH[2]}"
            if [ -n "$cowner" ]; then
              if [ "$cowner" != "$ISSUE" ]; then
                echo "discover_artifact: cross-repo fallback found ${check_repo}#${check_num} by branch, but it's a VERIFY task for a different issue — continuing to other fallbacks (#5130)" >&2
              else
                # VERIFY branch matches this issue - accept it
                ART_PR_NUM="$check_num"; ART_PR_REPO="$check_repo"; ART_PR_URL=$(printf '%s' "$rpr" | jq -r '.url')
                ART_PR_MERGED_AT=$(printf '%s' "$rpr" | jq -r '.mergedAt // empty')
                ART_PR_CREATED_AT=$(printf '%s' "$rpr" | jq -r '.createdAt // empty')
                [ "$(printf '%s' "$rpr" | jq -r '.isDraft')" = "true" ] && ART_DRAFT=1
                if [ "$(printf '%s' "$rpr" | jq -r '.state')" = "MERGED" ]; then ART_KIND=pr_merged; else ART_KIND=pr_open; fi
                return 0
              fi
            fi
          elif [[ "$rbranch" =~ (^|/)verify-([0-9]+)- ]]; then
            local cowner="${BASH_REMATCH[2]}"
            if [ -n "$cowner" ]; then
              if [ "$cowner" != "$ISSUE" ]; then
                echo "discover_artifact: cross-repo fallback found ${check_repo}#${check_num} by branch, but it's a VERIFY task for a different issue — continuing to other fallbacks (#5130)" >&2
              else
                # VERIFY branch matches this issue - accept it
                ART_PR_NUM="$check_num"; ART_PR_REPO="$check_repo"; ART_PR_URL=$(printf '%s' "$rpr" | jq -r '.url')
                ART_PR_MERGED_AT=$(printf '%s' "$rpr" | jq -r '.mergedAt // empty')
                ART_PR_CREATED_AT=$(printf '%s' "$rpr" | jq -r '.createdAt // empty')
                [ "$(printf '%s' "$rpr" | jq -r '.isDraft')" = "true" ] && ART_DRAFT=1
                if [ "$(printf '%s' "$rpr" | jq -r '.state')" = "MERGED" ]; then ART_KIND=pr_merged; else ART_KIND=pr_open; fi
                return 0
              fi
            fi
          else
            # Found a genuine closing reference to THIS issue — accept it
            ART_PR_NUM="$check_num"; ART_PR_REPO="$check_repo"; ART_PR_URL=$(printf '%s' "$rpr" | jq -r '.url')
            ART_PR_MERGED_AT=$(printf '%s' "$rpr" | jq -r '.mergedAt // empty')
            ART_PR_CREATED_AT=$(printf '%s' "$rpr" | jq -r '.createdAt // empty')
            [ "$(printf '%s' "$rpr" | jq -r '.isDraft')" = "true" ] && ART_DRAFT=1
            if [ "$(printf '%s' "$rpr" | jq -r '.state')" = "MERGED" ]; then ART_KIND=pr_merged; else ART_KIND=pr_open; fi
            return 0
          fi
        fi
      fi
    fi
  fi
  # Org-wide fallback: find a PR that MENTIONS this issue anywhere in the org. Requires NOTHING from the
  # model — unlike $RUN_STATE above, which BRIEF step 9 merely ASKS for and which was verified absent on
  # the box during the 2026-07-27 false-✘ cluster. This is the single largest source of false failures:
  # every PRODUCT PR lands in product-a while $REPO is knowledge, and closedByPullRequestsReferences is
  # same-repo only. #2918 produced a pushed branch + an open PR and was still stamped "✘ no artifact".
  #
  # 🔴 This fallback had NEVER once returned a result -- verified on the wire 2026-07-30 (#3417). Two
  # independent bugs were stacked, each individually sufficient to make it dead code:
  #   1. `--state all` is not a valid value for `gh search prs` (it accepts only open|closed, and already
  #      defaults to BOTH). gh exited 1 every single time -> `|| echo '[]'` -> an empty result that is
  #      indistinguishable from an honest "no artifact found".
  #   2. `gh search prs --json state` returns LOWERCASE ("merged"/"open") -- unlike `gh pr list`, which
  #      returns uppercase. The selectors below compared against "MERGED"/"OPEN", so even a corrected
  #      flag would still have matched nothing.
  # This fallback exists precisely to catch the cross-repo case that produced the #2918 false-✘ cluster,
  # so a silently-dead fallback IS the failure it was written to prevent. Proven fixed on the wire:
  # `--match body 2918` now returns product-a#188 + knowledge#2966/#2928.
  local hits
  hits=$(gh search prs --owner "$owner" --match body "$ISSUE" --limit 20 \
         --json number,state,url,repository,isDraft,closedAt,createdAt 2>/dev/null || echo '[]')
  [ -z "$hits" ] && hits='[]'
  # #3914 — this is a bare BODY-TEXT search across the whole org: `gh search prs --match body` matches the
  # ISSUE NUMBER AS A BARE SUBSTRING, no "#" required, no closing keyword required, no branch/repo constraint
  # at all. Proven on the wire (2026-08-03 audit): PR #3909 (a jq-syntax fix, `Closes #3901`) was credited to
  # UNRELATED issue #3898 purely because its body quoted a dispatch-sweep log line that happened to start with
  # the digits "3898:" — zero relation, not even a "#" prefix. And PR #183 (a DIFFERENT repo, product-a)
  # was attributed to knowledge#3893 the same way. `gh search prs --json` has neither headRefName nor a
  # body/`.jq`-selectable subset beyond `body` itself, so BOTH guards below run off one follow-up
  # `gh pr view --json headRefName,body` per CANDIDATE actually being considered — cheap, since normally only
  # the top candidate is ever inspected. `gh search prs --json` returns state lowercase and has no mergedAt —
  # see the note above for why closedAt substitutes.
  #   1. REAL closing reference required: a genuine closing verb (close/closes/fix/fixes/resolve/resolves…)
  #      on the SAME LINE as `#$ISSUE` — not a bare digit run anywhere in the body. Verified against the
  #      fallback's own proof case (product-a#188, "Closes #2918" on its own line) — still matches.
  #   2. Verify-branch ownership (as the main query above): a PR that DOES genuinely write "Closes #A, #B, #C"
  #      because it is the VERIFY task auditing A/B/C is still excluded from every issue except the one its
  #      own branch is FOR — guard 1 alone would not catch this shape (the keyword IS adjacent to #ISSUE).
  local cand_json cnt i cand cnum crepo cfields cbranch cbody cowner
  cand_json=$(printf '%s' "$hits" | jq -c '
    ( [.[] | select((.state|ascii_upcase)=="MERGED")] | sort_by(.closedAt) | reverse ) +
    ( [.[] | select((.state|ascii_upcase)=="OPEN")]   | sort_by(.closedAt) | reverse )' 2>/dev/null)
  [ -z "$cand_json" ] && cand_json='[]'
  cnt=$(printf '%s' "$cand_json" | jq 'length' 2>/dev/null || echo 0)
  pick=""
  for ((i=0; i<cnt; i++)); do
    cand=$(printf '%s' "$cand_json" | jq -c ".[$i]")
    cnum=$(printf '%s' "$cand" | jq -r '.number')
    crepo=$(printf '%s' "$cand" | jq -r '.repository.nameWithOwner // .repository.name // empty')
    [ -z "$crepo" ] && continue
    cfields=$(gh pr view "$cnum" --repo "$crepo" --json headRefName,body \
              --jq '(.headRefName // "") + "" + (.body // "")' 2>/dev/null || echo "")
    cbranch="${cfields%%$'\x01'*}"; cbody="${cfields#*$'\x01'}"
    # The verb must IMMEDIATELY precede the reference — GitHub's own rule — not merely share a line
    # with it. The two-grep same-line test admitted any sentence that used a closing word ABOUT
    # something else while naming this issue. Proven on the wire 2026-08-16: PR #6093 (`Closes #6077`)
    # opened with "This PR **fixes** the failing criterion from VERIFY **#6038**" — verb and `#6038` on
    # one line, but the verb's object is the CRITERION, not the issue. #6093 was credited to #6038,
    # and the `pr_merged` + merged-before-run branch at :1030 then stamped a run that had done real
    # work (it filed blocker #6102) as "⚠ nothing to do — a stale or duplicate dispatch". Same
    # false-marker class as #5949/#5988. Still matches the fallback's own regression case,
    # product-a#188's `Closes #2918`.
    if ! printf '%s\n' "$cbody" \
         | grep -qiE '\b(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]*:?[[:space:]]*#'"${ISSUE}"'([^0-9]|$)'; then
      continue   # no genuine closing reference to THIS issue — a coincidental mention (#3914, #6038)
    fi
    cowner=""
    if [[ "$cbranch" =~ (^|/)([0-9]+)-verify- ]]; then cowner="${BASH_REMATCH[2]}"
    elif [[ "$cbranch" =~ (^|/)verify-([0-9]+)- ]]; then cowner="${BASH_REMATCH[2]}"
    fi
    if [ -n "$cowner" ] && [ "$cowner" != "$ISSUE" ]; then
      continue   # a VERIFY task's PR naming a sibling issue in its body — not this issue's artifact (#3914)
    fi
    # 🔴 CRITICAL VALIDATION (#5126): verify this PR actually closed THIS issue
    # The org-wide search matches the issue number as a substring - it can find PRs that merely mention
    # the issue in logs, comments, or incidental text. Only PRs in the authoritative closing list count.
    #
    # However, AUTHORITATIVE_CLOSING_PRS is empty for cross-repo PRs with bare closing references
    # (e.g., "Closes #5060" instead of "Closes example-org/kb#5060"). In those cases,
    # we trust the body parsing validation above (grep for closing keyword on same line as #$ISSUE).
    local authoritative_count
    authoritative_count=$(printf '%s' "$AUTHORITATIVE_CLOSING_PRS" | jq 'length' 2>/dev/null || echo 0)
    if [ "$authoritative_count" -gt 0 ]; then
      # List is non-empty - validate against it to prevent false positives (#5126)
      if ! pr_actually_closes_issue "$cnum" "$crepo"; then
        echo "discover_artifact: org-wide search found ${crepo}#${cnum} mentioning #$ISSUE, but it does NOT close #$ISSUE — discarding as unrelated (#5126)" >&2
        continue
      fi
    fi
    pick="$cand"
    break
  done
  if [ -n "$pick" ]; then
    ART_PR_NUM=$(printf '%s' "$pick" | jq -r '.number')
    ART_PR_REPO=$(printf '%s' "$pick" | jq -r '.repository.nameWithOwner // .repository.name // empty')
    ART_PR_URL=$(printf '%s' "$pick" | jq -r '.url')
    # `gh search prs` has no mergedAt field — closedAt is the merge time for a MERGED result (a merge is
    # the only way this search's own filter above lets a PR reach that state).
    ART_PR_MERGED_AT=$(printf '%s' "$pick" | jq -r '.closedAt // empty')
    ART_PR_CREATED_AT=$(printf '%s' "$pick" | jq -r '.createdAt // empty')
    [ "$(printf '%s' "$pick" | jq -r '.isDraft')" = "true" ] && ART_DRAFT=1
    if [ "$(printf '%s' "$pick" | jq -r '.state | ascii_upcase')" = "MERGED" ]; then ART_KIND=pr_merged; else ART_KIND=pr_open; fi
    return 0
  fi

  # Last fallback: a PUSHED branch ahead of origin/main in the run's working repo (shipped code, no PR yet).
  local br ahead
  br=$(git -C "$WORKDIR" branch --show-current 2>/dev/null || echo "")
  if [ -n "$br" ] && [ "$br" != main ] \
     && git -C "$WORKDIR" ls-remote --exit-code --heads origin "$br" >/dev/null 2>&1; then
    ahead=$(git -C "$WORKDIR" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
    [ "${ahead:-0}" -gt 0 ] && ART_KIND=commits
  fi
}

# --- Branch evidence (#5988) ----------------------------------------------------------------------
# discover_artifact() above measures exactly ONE thing: "does GitHub report a PR that CLOSES this
# issue". The ⚠ close-out then reported FOUR — "opened no PR, armed no merge, pushed no commits.
# Nothing shipped" — three of which it had never checked. Observed live 2026-08-16 on #5949: PR #5961
# was MERGED (branch `issue-5949-label-alpha-directories`) and its code was in the tree, but the body
# omitted `Closes #5949`, so closedByPullRequestsReferences was legitimately empty and the run was
# stamped "Nothing shipped; the task is NOT done." Six chained phases (P3-P8) sat idle for an hour
# behind a phase that was already done, because a reader sees ⚠ and concludes the work must be redone
# rather than that a REFERENCE is missing.
#
# This function measures the branch INDEPENDENTLY so the marker can state facts instead of inferring
# them from an absence. Same-class prior incidents already documented above: :388 (#2918 — pushed
# branch + open PR stamped "✘ no artifact"), :331 (cross-repo bare closing refs), :284 (armed-is-
# shipped). Root is identical every time: issue state and shipped state can disagree, and the
# close-out narrates the former as if it were the latter.
#
# 🔴 NOTHING here ever feeds ✔. The empty-means-⚠ derivation at :253 is deliberate and correct, and a
# false ✔ is far worse than a confusing ⚠. These functions only ever change the TEXT of a ⚠.
#
# #5988 offered a stronger optional fix — the runner REFUSES to exit without either a closing PR or an
# explicit ⛔ — and left it as this issue's judgement call. DECIDED: not enforced. finish() is a REPORT,
# not a gate: it runs in an EXIT trap after the model is gone, so "refuse to exit" can only mean posting
# a louder marker, which is what this change already does. And several empty runs are CORRECT — the
# already-closed duplicate (:1013), the deliberate refusal (:253) — so a fail-closed rule here would fire
# on correct behaviour, which RULES.md reserves for stable invariants only. The sweeper already
# re-dispatches on ⚠; the defect was never that the marker was too quiet, it was that it was WRONG.
#
# Sets: BEV_BRANCH, BEV_REPO, BEV_AHEAD ("" = NOT MEASURED, never conflate with 0), BEV_PR_NUM,
#       BEV_PR_STATE (MERGED|OPEN|CLOSED), BEV_PR_URL.
BEV_BRANCH=""; BEV_REPO=""; BEV_AHEAD=""; BEV_PR_NUM=""; BEV_PR_STATE=""; BEV_PR_URL=""
branch_evidence() {
  BEV_BRANCH=""; BEV_REPO="$REPO"; BEV_AHEAD=""; BEV_PR_NUM=""; BEV_PR_STATE=""; BEV_PR_URL=""
  local cur _r _b _pr
  cur=$(git -C "$WORKDIR" branch --show-current 2>/dev/null || echo "")
  BEV_BRANCH="$cur"
  # BRIEF step 9 asks a cross-repo run to record its real repo+branch; prefer it when present.
  if [ -s "$RUN_STATE" ]; then
    _r=$(jq -r '.repo // empty' "$RUN_STATE" 2>/dev/null || echo "")
    _b=$(jq -r '.branch // empty' "$RUN_STATE" 2>/dev/null || echo "")
    [ -n "$_r" ] && BEV_REPO="$_r"
    [ -n "$_b" ] && BEV_BRANCH="$_b"
  fi
  { [ -z "$BEV_BRANCH" ] || [ "$BEV_BRANCH" = main ]; } && return 0
  # Commit count is only measurable when the branch we are reporting on is the one checked out here.
  # Left EMPTY otherwise — "unknown" must never be rendered as "zero" (that is the whole defect).
  if [ "$BEV_REPO" = "$REPO" ] && [ -n "$cur" ] && [ "$cur" = "$BEV_BRANCH" ]; then
    BEV_AHEAD=$(git -C "$WORKDIR" rev-list --count origin/main..HEAD 2>/dev/null || echo "")
  fi
  _pr=$(gh pr list --repo "$BEV_REPO" --head "$BEV_BRANCH" --state all \
        --json number,state,url --jq 'sort_by(.number) | last // empty' 2>/dev/null || echo "")
  if [ -n "$_pr" ]; then
    BEV_PR_NUM=$(printf '%s' "$_pr" | jq -r '.number // empty' 2>/dev/null || echo "")
    BEV_PR_STATE=$(printf '%s' "$_pr" | jq -r '.state // empty' 2>/dev/null || echo "")
    BEV_PR_URL=$(printf '%s' "$_pr" | jq -r '.url // empty' 2>/dev/null || echo "")
  fi
  return 0
}

# Renders the measured facts as one sentence. Every claim below is conditioned on the check that
# produced it having actually run — that is the acceptance criterion, not a style preference.
branch_evidence_sentence() {
  if [ -n "$BEV_PR_NUM" ] && [ "$BEV_PR_STATE" = "MERGED" ]; then
    printf '%s' "🔴 **A PR for this run's branch \`$BEV_BRANCH\` IS MERGED — ${BEV_REPO}#${BEV_PR_NUM}: ${BEV_PR_URL}** — it simply does not close #$ISSUE. Code from this run has almost certainly shipped and the board cannot see it. **Recovery: read that PR's diff; if it is this issue's work, close #$ISSUE citing it — do NOT re-run the task.**"
  elif [ -n "$BEV_PR_NUM" ]; then
    printf '%s' "**A PR for this run's branch \`$BEV_BRANCH\` exists and is ${BEV_PR_STATE} — ${BEV_REPO}#${BEV_PR_NUM}: ${BEV_PR_URL}** — it does not close #$ISSUE. Something happened; it just never reached the board."
  elif [ -n "$BEV_AHEAD" ] && [ "$BEV_AHEAD" -gt 0 ] 2>/dev/null; then
    printf '%s' "**Branch \`$BEV_BRANCH\` carries $BEV_AHEAD commit(s) not on origin/main and no PR was found for it** — something happened; it just never reached the board."
  elif [ -n "$BEV_AHEAD" ]; then
    printf '%s' "Both independent checks ran and came back empty: no PR exists for branch \`$BEV_BRANCH\`, and it carries no commits beyond origin/main."
  else
    printf '%s' "No PR exists for branch \`${BEV_BRANCH:-(none)}\`. The branch's commit count could not be measured from this workspace, so whether anything was pushed is UNKNOWN — do not assume it was not."
  fi
}

# The one line that turns an hour of idle chain into a ten-second check (#5988). Suppressed when the
# sentence above ALREADY named a merged PR — there the recovery is concrete, not a thing to go look for.
no_closes_recovery() {
  [ "$BEV_PR_STATE" = "MERGED" ] && return 0
  printf '%s' "**First thing to check: a merged PR for this run's branch whose body omits \`Closes #$ISSUE\`** — that ships the work while leaving the board blind, and it is exactly what happened on #5949 / PR #5961 (2026-08-16). If you find one, read its diff, and if it is this issue's work close #$ISSUE citing it — do NOT re-run the task."
}

# --- Rollup attestation (#3309) -------------------------------------------------------------------
# A Feature has no PR of its own, so `Closes #N` — the entire closing mechanism of this system —
# structurally CANNOT fire on a parent. Measured (#3307): all 5 Feature closures in this repo's history
# were manual (#1103 #3150 #2786 #2865 #2354 — every one `closer=manual`), and #3042 sat at 4/4 with its
# parent OPEN. Two Features DID close cleanly — #3150 (7/7) and #2786 (6/6) — and both did the identical
# thing: the agent that finished the LAST sub-issue wrote a per-criterion verification comment. This makes
# that the only path, instead of a habit two conscientious agents happened to have.
#
# The rollup itself is GitHub's own arithmetic, handed over in ONE field: subIssuesSummary{total completed}.
# Nothing in this fleet had ever read it (`grep -rn subIssuesSummary _infra/` returned 0 before this).
#
# TWO THINGS THIS DELIBERATELY DOES NOT DO:
#  1. It never closes the parent. `stuck-pr-sweep.yml` (#3310) owns closure; this owns the attestation —
#     two mechanisms, so a bug in one cannot silently close work.
#  2. It never AUTHORS the evidence. The per-criterion rows come from the master's own run-state, written
#     only when it actually exercised the artifact. A table this script synthesised from "a PR exists"
#     would be a rubber stamp — and a rubber-stamped ✔ ROLLUP VERIFIED is strictly WORSE than no mechanism
#     at all, because it converts a visible gap into an invisible false close. No honest attestation → we
#     post NOTHING and the sweep loudly surfaces the unattested n/n parent. That is the correct outcome.
#
# Its own state file, NOT $RUN_STATE: that one carries {repo,branch} (the cross-repo artifact lookup) and
# {blocked} — a `printf > $RUN_STATE` for the rollup would clobber them and manufacture a false ✘/Todo.
ROLLUP_STATE="$HOME/.claude/state/task-rollup-$ISSUE.json"
rm -f "$ROLLUP_STATE" 2>/dev/null || true   # a prior run's attestation must never leak into this one

# --- The VERIFY verdict (#4800) --------------------------------------------------------------------
# The mirror image of the attestation above, and the half that was missing: rollup_attest gives a run a
# structured way to say "every criterion is TRUE", and nothing gave it a way to say "this one is FALSE"
# that the board could act on. So a failing criterion lived only as English inside a comment — and on
# 2026-08-09 Feature #4749 was auto-closed as complete seven minutes after VERIFY #4750 posted that one
# of its five criteria was failing, while it still was.
# `verify-verdict.sh` turns that verdict into board structure: a marker comment the auto-closer reads,
# and one OPEN blocker sub-issue per failing criterion under the parent — so the Feature is not n/n.
# Same discipline as the attestation: this script never AUTHORS the verdict. No state file → no verdict,
# and the closer says out loud that none was on record rather than inventing one.
VERIFY_STATE="$HOME/.claude/state/task-verify-$ISSUE.json"
rm -f "$VERIFY_STATE" 2>/dev/null || true   # a prior run's verdict must never leak into this one
rollup_attest() {
  local issue="$ISSUE" repo="$REPO" owner name parent pnum total completed rows n nall q body
  owner="${repo%%/*}"; name="${repo##*/}"
  q="{repository(owner:\"$owner\",name:\"$name\"){issue(number:$issue){parent{number subIssuesSummary{total completed percentCompleted}}}}}"
  parent=$(gh api graphql -f query="$q" --jq '.data.repository.issue.parent // empty' 2>/dev/null || true)
  [ -z "$parent" ] && { echo "rollup: #$issue has no parent Feature — nothing to attest" >&2; return 0; }
  pnum=$(printf '%s' "$parent" | jq -r '.number')
  total=$(printf '%s' "$parent" | jq -r '.subIssuesSummary.total // 0')
  completed=$(printf '%s' "$parent" | jq -r '.subIssuesSummary.completed // 0')
  # The close we just made can lag the rollup by a beat, so re-READ once. This only re-reads GitHub's own
  # count; it never infers it — an n-1/n parent reads n-1/n both times and still posts nothing.
  if [ "${completed:-0}" -lt "${total:-0}" ]; then
    sleep 3
    parent=$(gh api graphql -f query="$q" --jq '.data.repository.issue.parent // empty' 2>/dev/null || true)
    total=$(printf '%s' "$parent" | jq -r '.subIssuesSummary.total // 0')
    completed=$(printf '%s' "$parent" | jq -r '.subIssuesSummary.completed // 0')
  fi
  if [ "${total:-0}" -le 0 ] || [ "${completed:-0}" -ne "${total:-0}" ]; then
    echo "rollup: parent #$pnum is at ${completed}/${total} — the Feature is NOT finished; posting nothing" >&2
    return 0
  fi
  # One attestation per Feature (the sweep only asks whether the string is present).
  # The pattern tolerates a leading markdown heading (#5650): this function writes the marker BARE, but a
  # master attesting by hand writes `## ✔ ROLLUP VERIFIED — …` (22 of the 51 on this board, measured
  # 2026-08-15). Anchored on `^` against a hand-written heading, this dedupe missed every one of them and
  # would post a SECOND attestation under a Feature that already carried a full per-criterion table.
  if gh issue view "$pnum" --repo "$repo" --json comments --jq '.comments[].body' 2>/dev/null \
     | grep -qE '^ *#{0,6} ?✔ ROLLUP VERIFIED'; then
    echo "rollup: parent #$pnum already carries ✔ ROLLUP VERIFIED — nothing to add" >&2
    return 0
  fi
  if [ ! -s "$ROLLUP_STATE" ]; then
    echo "rollup: parent #$pnum is at ${total}/${total} but this run attested nothing ($ROLLUP_STATE absent) — posting NOTHING; the sweep surfaces it" >&2
    return 0
  fi
  # A row with an empty criterion or empty evidence IS the rubber stamp this mechanism exists to prevent,
  # so a single one voids the whole attestation rather than being quietly dropped.
  nall=$(jq -r '[.rollup[]?] | length' "$ROLLUP_STATE" 2>/dev/null || echo 0)
  n=$(jq -r '[.rollup[]? | select(((.criterion//"")|length)>0 and ((.evidence//"")|length)>0)] | length' "$ROLLUP_STATE" 2>/dev/null || echo 0)
  if [ "${nall:-0}" -le 0 ] || [ "${n:-0}" -ne "${nall:-0}" ]; then
    echo "rollup: the attestation in $ROLLUP_STATE is unusable (${n:-0}/${nall:-0} rows carry BOTH a criterion and evidence) — posting NOTHING rather than a rubber stamp" >&2
    return 0
  fi
  rows=$(jq -r '.rollup[] | "| " + ((.criterion|gsub("[|]";"\\|")|gsub("[\r\n]+";" "))) + " | " + ((.evidence|gsub("[|]";"\\|")|gsub("[\r\n]+";" "))) + " |"' "$ROLLUP_STATE" 2>/dev/null)
  [ -z "$rows" ] && { echo "rollup: could not render the attestation table — posting nothing" >&2; return 0; }
  body="✔ ROLLUP VERIFIED — ${completed}/${total} sub-issues closed; the last was #$issue.
Attested by \`$WHO\` · account \`$ACCOUNT\` — the run that exercised the artifact, criterion by criterion:

| Feature acceptance criterion | Evidence (exercised, not read off a close-out) |
|---|---|
$rows

This comment does **NOT** close #$pnum, and it is **not what closes it**. \`stuck-pr-sweep.yml\` owns parent
closure and derives it from sub-issue state alone — this attestation is evidence, never a gate (#3310).
The one thing that DOES hold a Feature open is a recorded VERIFY \`FAIL\` (\`verify-verdict.sh\`, #4800)."
  # DRY-RUN is for exercising this function against real GitHub data without writing to a board.
  if [ "${ROLLUP_DRY_RUN:-0}" = 1 ]; then printf '%s\n' "$body"; return 0; fi
  if ! gh issue comment "$pnum" --repo "$repo" --body "$body" >/dev/null 2>&1; then
    sleep 3
    gh issue comment "$pnum" --repo "$repo" --body "$body" >/dev/null 2>&1 \
      || echo "ERROR: could not post ✔ ROLLUP VERIFIED on parent #$pnum — it is n/n and now unattested" >&2
  fi
  echo "rollup: ✔ ROLLUP VERIFIED posted on parent #$pnum (${completed}/${total}, ${nall} criteria) — NOT closed" >&2
}

# --- Run-output classification (#3417) ------------------------------------------------------------
# `--output-format json` emits a RESULT ENVELOPE ({subtype, num_turns, result, session_id, ...}) for any
# run that reached the model. A first-request API failure -- the 529 that killed #3396/#3399 on
# 2026-07-30 -- never produces one; the whole capture is a bare `API Error: 529 ...` string. So the
# ABSENCE of the envelope IS the proof that zero turns were consumed. That is the load-bearing half of
# the retry gate: it separates "never started" from "ran 137 turns and failed", and only the first of
# those may ever be re-run.
#
# 🔴 The capture is `2>&1`, so the envelope routinely arrives with stderr noise wrapped around it. Verified
# live 2026-07-30: a trailing `SessionEnd hook ... failed` line made a whole-capture `json.load` fail on a
# perfectly SUCCESSFUL run -- which is why `session` silently went missing from close-outs and why they
# dumped 2KB of raw usage JSON instead of the model's own result line. So we scan for the LAST well-formed
# JSON object in the capture instead of parsing the capture as a whole. This one parse feeds BOTH the
# retry gate and the close-out, so the two can never disagree about what the run reported.
parse_run_output() {
  RUN_TURNS=0; RUN_SUBTYPE=""; SESSION=""; RESULT=""
  local env
  env=$(printf '%s' "$OUT" | python3 -c '
import sys, json
raw = sys.stdin.read()
dec = json.JSONDecoder(); best = None; i = 0
while True:
    i = raw.find("{", i)
    if i < 0: break
    try: o, e = dec.raw_decode(raw, i)
    except ValueError: i += 1; continue
    if isinstance(o, dict) and ("num_turns" in o or "session_id" in o or o.get("type") == "result"): best = o
    i = e
if best is None: sys.exit(1)
t = best.get("num_turns") or 0
try: t = int(t)
except Exception: t = 0
print(json.dumps({"turns": t, "subtype": best.get("subtype") or "",
                  "session": best.get("session_id") or "", "result": best.get("result") or ""}))
' 2>/dev/null) || env=""
  if [ -n "$env" ]; then
    RUN_TURNS=$(printf '%s' "$env" | jq -r '.turns // 0')
    RUN_SUBTYPE=$(printf '%s' "$env" | jq -r '.subtype // ""')
    SESSION=$(printf '%s' "$env" | jq -r '.session // ""')
    RESULT=$(printf '%s' "$env" | jq -r '.result // ""')
    case "$RUN_TURNS" in ''|*[!0-9]*) RUN_TURNS=0 ;; esac
  else
    # No envelope anywhere in the capture -- the first-request-529 shape. The raw capture IS the evidence
    # (unchanged from the behaviour this replaces), and its absence is what run_started() reads.
    RESULT="$OUT"
  fi
}

# "Did this run start?" -- asked defensively. A parseable envelope with num_turns>0 is the clean yes; the
# raw presence of the envelope's own keys is the backstop for the case where the CLI prepends a warning
# line and jq cannot parse the capture as a whole. Erring toward STARTED costs at most a retry we could
# have had; erring the other way re-runs work that really happened. Only one of those is recoverable.
run_started() {
  [ "${RUN_TURNS:-0}" -gt 0 ] && return 0
  printf '%s' "$OUT" | grep -qE '"(num_turns|session_id|total_cost_usd)"' && return 0
  return 1
}

# The transient signature set, matched against $OUT (which carries stderr via 2>&1). Deliberately NARROW:
# a false "transient" re-runs a genuine defect three times and buries its cause, which is the exact
# failure mode this change exists to prevent. Bare words like "timeout" are excluded for that reason.
TRANSIENT_RE='(^|[^0-9])(429|500|502|503|504|529)([^0-9]|$)|overloaded|service unavailable|bad gateway|gateway time-?out|internal server error|temporarily unavailable|connection (reset|refused|closed)|econnreset|econnrefused|etimedout|enotfound|eai_again|socket hang up|network error|request timed out|fetch failed'
is_transient() { printf '%s' "$OUT" | grep -qiE "$TRANSIENT_RE"; }
# The honest evidence: the first REAL line that matched, never a paraphrase. Backticks are neutralised so
# a cause cannot break out of the code span it gets rendered in on the issue.
transient_cause() {
  printf '%s' "$OUT" | grep -iE "$TRANSIENT_RE" | head -1 | tr -d '\r' | tr '`' "'" | cut -c1-200
}

# 429 is on the transient list, but a HARD exhaustion is NOT transient by any definition: it will not clear
# in 8 minutes, and retrying it only delays the 🪫 capacity announcement by ~10 min while burning the very
# quota that is exhausted. Defined ONCE here and CALLED by capture_quota(), so the two paths can never
# disagree about what "quota" means — they used to be two hand-copied regex pairs, which is drift by design.
#
# 🔴 THE 5-HOUR SESSION LIMIT COUNTS (#3811). Both clauses were written around the weekly/monthly `[1310]`
# form (`429 ... Weekly/Monthly Limit Exhausted. Your limit will reset at 2026-07-29 11:04:49`) and matched
# NEITHER half of Claude Code's far more frequent session-limit notice:
#     You've hit your session limit · resets 2:30am (UTC)
# — no "429", no "rate limit", and "session limit · resets" is not "limit reset". On 2026-08-02 22:59 UTC
# bravo hit that limit and 20 dispatched runs died inside 34s; every one was classed `transient-api`, no
# `quota-status.json` was ever written, and the OCC rendered a quota-dark master as an ordinary idle one —
# the exact failure #2489 exists to prevent, just one limit-kind narrower than reality.
# Clause A names the KIND of limit; clause B is the evidence it was actually REACHED. The conjunction is
# what keeps an ordinary in-flight 429 retry ("per-minute rate limit ... retrying in 8s") out: it matches A
# and not B.
QUOTA_KIND_RE='429|rate.?limit|session limit|usage limit'
QUOTA_HIT_RE='exhaust|weekly/monthly limit|limit (will )?reset|limit reached|hit your (session|usage) limit|reset(s)?( at)? [0-9]'
is_quota_exhausted() {
  printf '%s' "$OUT" | grep -qiE "$QUOTA_KIND_RE" \
    && printf '%s' "$OUT" | grep -qiE "$QUOTA_HIT_RE"
}

# ── ENTITLEMENT REVOCATION — the OTHER way a login stops working (#2807) ─────────────────────────────
# 2026-07-27, knowledge#2793: `dispatch.sh charlie 2793` died `✘ failed (exit=1)` in EIGHT SECONDS on
#     Your organization has disabled Claude subscription access for Claude Code · Use an Anthropic API
#     key instead, or ask your admin to enable access
# the operator re-logged charlie onto its then-login by hand and the re-dispatch ran fine. Cost: one
# wasted dispatch + a manual re-route; in a walk-away run it is a silent stall.
#
# 🔴 That string matches NOTHING in this file. Measured 2026-08-03 against all three classifiers:
# TRANSIENT_RE no, QUOTA_KIND_RE no, and the auth/config alternation below wants "invalid api key" while
# the notice says "an Anthropic API key" — so the failure landed as `unclassified (exit=$rc)`, the class
# that names nothing. An account whose ENTITLEMENT was revoked is not rate-limited and not misconfigured:
# it is a working login the org has switched off, and the only fix is a rotation onto another login.
#
# Why it gets its own predicate rather than a wider auth/config regex: capture_quota() below writes this
# to the SAME quota-status.json the #3906 pre-flight already reads, so the SECOND dispatch onto a
# switched-off master is refused instead of burned. Reusing that mechanism is the whole point — a second
# state file would be a second thing to go stale. Kept NARROW for the is_transient reason: the phrases
# below are the provider's own entitlement wording, not any sentence containing "disabled".
ENTITLEMENT_RE='disabled (claude )?subscription access|subscription access (has been |is |was )?disabled|ask your admin to enable access|organization has disabled'
is_entitlement_blocked() {
  printf '%s' "$OUT" | grep -qiE "$ENTITLEMENT_RE"
}

# Every ✘ carries an error CLASS and the REAL failure text (#3417 / Feature acceptance 4). Measured over
# the mechanism's 169-run lifetime: 11 of 29 announced failures carried no error detail at all -- the old
# close-out appended only `$RESULT`, which is absent on an error envelope and empty when the CLI dies
# before emitting one. A failure nobody can diagnose after the fact is barely better than a silent one.
classify_error() {
  local rc="${1:-0}"
  ERR_CLASS=""; ERR_TEXT=""
  [ "$rc" -eq 0 ] && return 0
  case "$RUN_SUBTYPE" in
    error_max_turns)        ERR_CLASS="max-turns -- consumed all $MAXT turns (NOT transient; never retried)" ;;
    error_during_execution) ERR_CLASS="run-error -- the run started (${RUN_TURNS} turns) and failed" ;;
  esac
  if [ -z "$ERR_CLASS" ]; then
    if is_quota_exhausted; then ERR_CLASS="quota/rate-limit -- provider limit reached (see the 🪫 comment)"
    elif is_entitlement_blocked; then ERR_CLASS="auth/entitlement -- this login's subscription access is switched off; it needs a ROTATION, not a wait (see the 🔒 comment)"
    elif is_transient; then
      if run_started; then ERR_CLASS="transient-api -- but the run had STARTED (${RUN_TURNS} turns), so it was correctly NOT retried"
      else ERR_CLASS="transient-api -- zero turns consumed"; fi
    elif printf '%s' "$OUT" | grep -qiE 'context.{0,15}(window|length|limit)|prompt is too long|too many tokens'; then ERR_CLASS="context-limit"
    elif printf '%s' "$OUT" | grep -qiE 'unauthorized|invalid api key|authentication|oauth|credit balance|not logged in'; then ERR_CLASS="auth/config"
    elif [ -z "${OUT//[[:space:]]/}" ]; then ERR_CLASS="no-output -- the CLI produced nothing on stdout or stderr (exit=$rc)"
    else ERR_CLASS="unclassified (exit=$rc)"
    fi
  fi
  # The text, in falling order of fidelity -- and NEVER empty. An explicit "emitted nothing" is itself the
  # diagnosis; a blank ✘ is the thing being fixed.
  ERR_TEXT="$RESULT"
  [ -z "${ERR_TEXT//[[:space:]]/}" ] && ERR_TEXT=$(printf '%s' "$OUT" | tr -d '\r' | tail -c 1200)
  [ -z "${ERR_TEXT//[[:space:]]/}" ] && ERR_TEXT="(the CLI emitted nothing at all -- no stdout, no stderr, exit=$rc)"
  return 0
}

# #3062 Change 3 — the ` · UNVERIFIED` LABEL. A merged-but-never-exercised ✔ must read differently on the
# board from a verified one. 🔴 LABEL, NEVER A GATE: this function only ever appends text to $mark_details.
# It cannot fail a run, block a merge, or reopen an issue — `operating-system.md` forbids that class, which
# false-blocked docs and auto-reverted its own cleanup.
#
# #3744 shipped Changes 1+2 and SKIPPED this one on the premise that "the runner's only signal is the
# model's own final message ($RESULT), which is as self-reported as the ✔ it would label." That premise is
# false, and the skip was correct only for the source it considered. Claude Code writes a full tool-call
# transcript to ~/.claude/projects/<cwd-slug>/<session_id>.jsonl, and parse_run_output already captures
# $SESSION from the result envelope. So the runner CAN read what the run DID rather than what it SAID —
# evidence of an ACTION, not a claim about one. Verified 2026-08-02 against a real dispatched transcript
# (be6b5178…, 16 Bash / 3 Read / 2 Edit tool_use records, jq-parseable).
#
# Biased hard toward NOT labelling. A missed UNVERIFIED costs nothing; a false UNVERIFIED stamped on good
# work discredits the label and it stops being read at all. Hence: no transcript, unreadable transcript, or
# unparseable transcript ⇒ NO label. Unknown is not the same as unverified, and only one of those is a
# claim. The match set is deliberately BROAD for the same reason — every extra pattern makes the label
# rarer, never commoner.
VERIFY_RE='(^|[^a-z-])(curl|wget|playwright|puppeteer|chromium|headless|vitest|jest|pytest|shellcheck|tsc|bash -n|npm (run )?(test|build|typecheck|lint|start|dev)|pnpm( run)? (test|build|typecheck|lint)|yarn (test|build|typecheck)|go test|cargo (test|build)|make (test|check|build)|python3? -m (pytest|unittest|http)|node |deno |gh api|gh pr (checks|diff|view)|gh run (view|watch|list)|gh workflow (run|view)|docker (run|compose|build)|systemctl (status|is-active|is-enabled)|journalctl|dig |nslookup|openssl s_client|psql|sqlite3|wrangler|vercel|screenshot|render)'

# Returns the label suffix on stdout — empty string means "say nothing". Never returns nonzero in a way any
# caller acts on; every failure mode falls through to the empty string.
verification_evidence() {
  local _f _tx
  [ -z "${SESSION:-}" ] && return 0                       # no session id → unknown → no label
  _f=$(find "$HOME/.claude/projects" -maxdepth 3 -name "${SESSION}.jsonl" -print -quit 2>/dev/null)
  [ -z "$_f" ] || [ ! -r "$_f" ] && return 0              # no/unreadable transcript → unknown → no label
  _tx=$(jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use")
               | (.name + " " + (.input|tostring))' "$_f" 2>/dev/null)
  [ -z "${_tx//[[:space:]]/}" ] && return 0               # unparseable/empty → unknown → no label
  printf '%s' "$_tx" | grep -qiE "$VERIFY_RE" && return 0 # the run exercised something → no label
  printf ' · **UNVERIFIED** — this run made no tool call that exercised a live artifact (no build, test, curl, render or API read in its transcript). The PR merged; nothing observed it work. Advisory label only — nothing was blocked, failed, or reopened.'
}

# #3914 — SCOPE WIDENED (the Architect, 2026-08-03): a genuine, non-zero-turn run can still close the
# WRONG thing by shipping a markdown REPORT about the work instead of the work itself. Proven on the wire:
# #3892/#3893 closed on a PR whose only content was a verification report titled "0/8 criteria"; #3907 and
# #3910 closed on triage/verification docs while the hook they were meant to delete was still registered
# and the branches they were meant to recover were still unmerged. Deliberately biased toward NOT firing —
# same posture as verification_evidence() at :430 — a missed docs-only PR costs nothing; a false one on a
# genuine doc-deliverable task (a spec, a decision record) discredits the check. It fires ONLY on the
# conjunction of (a) every changed path in the PR is `.md` AND (b) the issue's own Acceptance section names
# a concrete non-markdown artifact.
docs_only_pr() {
  local repo="$1" pr="$2" paths
  paths=$(gh pr view "$pr" --repo "$repo" --json files --jq '.files[].path' 2>/dev/null)
  [ -z "$paths" ] && return 1                          # unreadable → fail OPEN, never block a real close
  printf '%s\n' "$paths" | grep -qvE '\.md$' && return 1  # any non-.md path → not docs-only
  return 0
}
# Concrete non-markdown deliverable indicators — a file extension, a live URL, or an explicit destructive/
# deploy verb naming an action a markdown file cannot itself be. Kept narrow deliberately: this is a LABEL
# gate on the runner's own artifact-attribution step (which already exists), not a new PreToolUse content
# gate on the model's own work — operating-system.md's "no content-keyword gate" bar is about the latter.
#
# 🔴 #6927 — DO NOT LOOSEN THIS REGEX to silence a false alarm. It was never wrong; it was being fed the
# wrong text and asked a question it cannot answer. Loosening it silences the REAL warnings (#3892/#3893/
# #3907/#3910 — reports shipped in place of the work) and fixes neither misfire mode below. Every #6927
# change is to what the regex is fed and to when the result is believed; the pattern itself is untouched.
ACCEPTANCE_NONMD_RE='\.(pdf|png|jpe?g|json|ya?ml|sh|sql|zip)\b|\b(pdf|png|jpe?g|screenshot)\b|https?://|\bdelete\b|\bdeploy\b|\brender\b'

# #6927 — WHICH `## Acceptance` SECTION. The old awk took the FIRST one, which on a VERIFY body is the
# PARENT FEATURE'S block, quoted verbatim by `file-issue.sh --feature` above the VERIFY's own. Measured on
# #6834 (the one wire-confirmed misfire): its body carries `## Acceptance` twice, at line 12 (the parent's,
# product-a criteria) and at line 77 (its own), and the first block plus the template prose that follows
# it is what tripped the regex on the word `render`. The issue's OWN acceptance is the LAST such section —
# on a body with exactly one (every non-VERIFY issue) LAST and FIRST are the same block, so this changes
# nothing there.
#
# The heading matcher is also aligned with `file-issue.sh:is_acceptance_heading()` (#6712's ONE definition,
# whose other readers are the empty-Acceptance guard and the VERIFY builder): `##`/`###`, any case, an
# optional suffix that starts with a non-alphanumeric character. This is a FOURTH reader of that shape and
# it had silently diverged — it matched only `##` and only `Acceptance` exactly-cased, so `### Acceptance`
# and `## ACCEPTANCE` fell through to the whole-body fallback. Narrowing the fed text can only make this
# check FIRE LESS, which is the direction its stated bias already points.
#
# #7177 — THE HEADING MATCHER IS NOW A DELIBERATE SUPERSET of `file-issue.sh:is_acceptance_heading()`,
# and the extraction moved into `acceptance_section()` because a second reader (mode 4 below) needs the
# same text. That function answers "what does a VERIFY copy verbatim", and its ONE definition must not
# drift. THIS one answers "which lines of this issue state what must be true", and the fleet writes that
# block under TWO headings, not one. Measured 2026-08-28, last 120 issues:
#   for n in $(gh issue list --repo example-org/kb --state all --limit 120 \
#               --json number --jq '.[].number'); do
#     gh issue view "$n" --repo example-org/kb --json body --jq '.body' \
#       | grep -iE '^#{2,3}[[:space:]]+(acceptance|what must be)'; done | sort | uniq -c
#     → 76  ## Acceptance
#       13  ## What must be TRUE when done      ← every hand-filed phase issue in a plan chain
#   (nothing else — the two forms are the whole population)
# #7141 is one of the 13, and because its heading was unrecognised the extractor fell through to the
# WHOLE-BODY fallback and reported `https://` from an artifact link 90 lines above its criteria.
# Recognising the second heading can only NARROW the fed text, so it moves the check in the fires-less
# direction its stated bias already points — and it makes the warning's own sentence ("the issue's
# Acceptance names X") true on those 13 instead of a claim about the entire body.
acceptance_section() {
  local body="$1" section
  section=$(printf '%s' "$body" | awk '
    tolower($0) ~ /^(##|###)[[:space:]]+(acceptance|what must be true)([^a-z0-9].*)?$/ { sec=""; f=1; next }
    /^#/ { if (f) { last=sec; got=1 }; f=0; next }
    f    { sec = sec $0 "\n" }
    END  { if (f) { last=sec; got=1 }; if (got) printf "%s", last }')
  [ -z "${section//[[:space:]]/}" ] && section="$body"
  printf '%s' "$section"
}
acceptance_nonmd_hit() {
  acceptance_section "$1" | grep -oiE "$ACCEPTANCE_NONMD_RE" | head -1
}

# #7177 — MODE 4: THE DELIVERABLE IS OFF-REPO BY CONSTRUCTION, so no diff shape could carry it.
#
# Both readings the warning named are about REPO PATHS — "it never shipped" or "it is a path the work
# READS" — and both assume the deliverable WOULD appear in the diff if it existed. For box-side work that
# assumption is false by construction. #7141 deleted six scripts under `/home/USER/.claude/scripts` and
# `/home/USER/.claude/scripts` and stripped four dead `/home/USER` axes out of `bravo-ops-integrity.sh`,
# all on fleet-host, none of them in any repo. Deleting a file on a box produces NO repo diff, so the
# only committable artifact was the record of the deletion and PR #7170 was legitimately two `.md` files.
#
# The predicate is a CONJUNCTION, and the second half is what keeps the check's value:
#   (a) the acceptance names at least one off-repo location — `ssh`, `scp`, `systemctl`, `journalctl`,
#       `sudo -n`/`sudo -u`, or an absolute path under /home /etc /var /opt /srv /usr; AND
#   (b) it names NO repo-relative path to a non-markdown file. One `_infra/scripts/x.sh` or
#       `apps/web/page.tsx` means the acceptance DOES name something a diff could have carried, the
#       off-repo reading is not available, and the warning stands.
# An absolute path is excluded from (b) by the leading `[^/...]` — `/home/USER/.claude/ops/x.sh` is the
# off-repo shape, not the in-repo one — and `.md` is absent from (b)'s extension list on purpose: a doc
# path is never the deliverable this check is looking for.
ACCEPTANCE_OFFREPO_RE='(^|[^[:alnum:]_-])(ssh|scp|systemctl|journalctl|loginctl|getent|crontab)([^[:alnum:]_-]|$)|(^|[^[:alnum:]_-])sudo[[:space:]]+-[nu]([^[:alnum:]_-]|$)|(^|[^/[:alnum:]_.-])/(home|etc|var|opt|srv|usr)/'
ACCEPTANCE_INREPO_PATH_RE='(^|[^/[:alnum:]_.-])[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+\.(pdf|png|jpe?g|json|ya?ml|sh|sql|zip|ts|tsx|js|jsx|mjs|cjs|py|rb|go|css|scss|html|toml|lock|txt|csv|xml|conf|service|timer|socket)\b'

# No `grep -q` in either test: this file runs under `pipefail` and a `-q` that exits on the first hit can
# leave the upstream `printf` killed by SIGPIPE, which pipefail then reports as a FAILED pipeline — the
# same inversion `pr_has_nonmd()` documents below. Count instead; the input is one issue section.
acceptance_offrepo_only() {
  local section="$1"
  [ -n "${section//[[:space:]]/}" ] || return 1
  [ -n "$(printf '%s' "$section" | grep -oiE "$ACCEPTANCE_OFFREPO_RE" || true)" ] || return 1
  [ -z "$(printf '%s' "$section" | grep -oiE "$ACCEPTANCE_INREPO_PATH_RE" || true)" ]
}

# #6927 / #7177 — THE MISFIRE MODES THAT ARE NOT REGEX PROBLEMS, AND THE ONE THAT IS OUT OF REACH.
#
# `docs_only_pr()` + `acceptance_nonmd_hit()` together answer "the PR is all `.md` and the acceptance names
# something that is not". FOUR ways that conjunction is true while the work is fine:
#
#   1. VERIFY tasks trip on their own template. Handled above (the LAST section) and again below (the
#      `^VERIFY` exemption), because a VERIFY's real deliverable IS a markdown report plus a JSON verdict
#      state file that never enters a PR — the check has nothing correct to say about that shape.
#   2. The acceptance names a file the work READS, not one it produces. `.json` in "resolve the path from
#      `installed_plugins.json`" is an INPUT. Text matching cannot recover produces-vs-consumes, and
#      guessing at it would be the content-keyword gate doctrine forbids. NOT SOLVED — see below.
#   3. The deliverable shipped in ANOTHER REPO. Structural, not incidental: every `process`-subprocess phase
#      splits mechanism → `fleet-plugins`, doctrine + ADR → `knowledge`, and the PR carrying `Closes` is the
#      docs one because that is the repo the issue lives in. Measured on #6925 (2026-08-27): the mechanism
#      was example-org/plugins#70 (the hook script, the 0.57.0 bump, its test), merged 21:46:30Z,
#      five minutes before the knowledge PR — which was legitimately docs-only. `docs_only_pr()` inspects
#      only the closing PR, so it concluded from an absence it could not see past. Handled by
#      `run_shipped_nonmd()`.
#
#   4. The deliverable is OFF-REPO by construction — a file on a box, a systemd unit, a credential in
#      Infisical. No diff shape could carry it, so the absence the check reads as suspicious is the
#      normal shape of that work. Measured on #7141/#7170 (2026-08-28). Handled by
#      `acceptance_offrepo_only()` above.
#
# Mode 2 is left unsolved ON PURPOSE and the warning's own wording was changed to stop asserting it: the
# sentence used to end "the deliverable does not exist yet", which is a conclusion this detector cannot
# support. It now reports the mismatch it measured and names all three readings it cannot separate.

# pr_has_nonmd — did this MERGED PR change at least one non-`.md` path? Unreadable, unmerged, or not a PR
# at all (an issue number picked out of a reference) → false. Same fail-open bias as docs_only_pr().
pr_has_nonmd() {
  local repo="$1" pr="$2" paths
  [ -n "$repo" ] && [ -n "$pr" ] || return 1
  paths=$(gh pr view "$pr" --repo "$repo" --json state,files \
          --jq 'select(.state=="MERGED") | .files[].path' 2>/dev/null) || return 1
  [ -n "$paths" ] || return 1
  # No `grep -q` here: this file runs under `pipefail`, and a `-q` that exits on the first hit can leave
  # the upstream `printf` killed by SIGPIPE, which pipefail then reports as a FAILED pipeline — the check
  # inverts itself exactly when it matched. Count instead; the input is a file list, never large.
  [ -n "$(printf '%s\n' "$paths" | grep -vE '\.md$' || true)" ]
}

# run_shipped_nonmd — MODE 3. Did this run merge non-`.md` work ANYWHERE, not only in the closing PR?
# Two sources, both already load-bearing elsewhere in this file, neither of them a new convention:
#   (a) $RUN_STATE {repo,branch} — BRIEF step 9's cross-repo record, the same field `discover_artifact()`
#       and `branch_evidence()` both read. RUN_STATE is deleted at run start (`rm -f "$RUN_STATE"` beside
#       its definition near the top of this file), so anything in it is provably from THIS run.
#   (b) a fully-qualified `owner/repo#N` reference in the closing PR's own body. `process.md` already
#       REQUIRES the master to name the plugin PR in its close-out, and #6942's body named
#       `example-org/plugins#70` exactly that way. A bare `#N` is deliberately NOT parsed: in a
#       same-repo body it is an issue number far more often than a PR, and each candidate costs an API call.
# Runs only after the conjunction is already true (a handful of calls on the rare warning path, none on the
# ordinary one). Sets DOCS_ONLY_EXEMPT_WHY so the exemption is stated in the log rather than silent.
DOCS_ONLY_EXEMPT_WHY=""
run_shipped_nonmd() {
  local closing_repo="$1" closing_pr="$2" r b n body ref cnt=0
  if [ -s "$RUN_STATE" ]; then
    r=$(jq -r '.repo // empty' "$RUN_STATE" 2>/dev/null)
    b=$(jq -r '.branch // empty' "$RUN_STATE" 2>/dev/null)
    if [ -n "$r" ] && [ -n "$b" ]; then
      n=$(gh pr list --repo "$r" --head "$b" --state merged --json number \
          --jq 'sort_by(.number) | last.number // empty' 2>/dev/null)
      if [ -n "$n" ] && ! { [ "$r" = "$closing_repo" ] && [ "$n" = "$closing_pr" ]; }; then
        if pr_has_nonmd "$r" "$n"; then
          DOCS_ONLY_EXEMPT_WHY="this run also merged ${r}#${n} (recorded in its own run state), which carries non-\`.md\` paths"
          return 0
        fi
      fi
    fi
  fi
  body=$(gh pr view "$closing_pr" --repo "$closing_repo" --json body --jq '.body // ""' 2>/dev/null)
  while read -r ref; do
    [ -n "$ref" ] || continue
    [ "$cnt" -ge 4 ] && break
    r="${ref%%#*}"; n="${ref##*#}"
    [ "$r" = "$closing_repo" ] && [ "$n" = "$closing_pr" ] && continue
    cnt=$((cnt+1))
    if pr_has_nonmd "$r" "$n"; then
      DOCS_ONLY_EXEMPT_WHY="the closing PR names ${r}#${n}, a merged PR carrying non-\`.md\` paths — the other half of this run's work"
      return 0
    fi
  done < <(printf '%s' "$body" | grep -oE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+' | sort -u)
  return 1
}

# docs_only_exempt — the whole suppression decision, in one place. Returns 0 = say nothing.
# Clause 1 reuses `verify-verdict.sh:165`'s predicate VERBATIM (`grep -q '^VERIFY'` on the title
# `file-issue.sh --feature` writes, "VERIFY Feature #N — …"), rather than inventing a second matcher for
# the same population — finish() already calls that script (`bash "$CLONE/_infra/scripts/verify-verdict.sh"`)
# on every close-out, where it gates on exactly this predicate.
# Clause 2 (#7177) is deliberately ordered BEFORE clause 3: it is pure text over a body finish() has
# already read, so it costs no API call, while `run_shipped_nonmd()` costs up to five.
docs_only_exempt() {
  local title="$1" closing_repo="$2" closing_pr="$3" body="${4:-}"
  DOCS_ONLY_EXEMPT_WHY=""
  if printf '%s' "$title" | grep -q '^VERIFY'; then
    DOCS_ONLY_EXEMPT_WHY="this is a VERIFY task — its deliverable IS a markdown report plus a JSON verdict that never enters a PR, and the regex trips on the word \`render\` in its own template (#6834)"
    return 0
  fi
  if [ -n "$body" ] && acceptance_offrepo_only "$(acceptance_section "$body")"; then
    DOCS_ONLY_EXEMPT_WHY="this issue's acceptance grades only OFF-REPO locations (\`ssh\`/\`sudo -n\`/\`systemctl\`, or an absolute path outside any checkout) and names no repo-relative non-\`.md\` path — box-side work produces no diff, so no PR shape could have satisfied the check (#7177)"
    return 0
  fi
  run_shipped_nonmd "$closing_repo" "$closing_pr"
}

# #5530 — DOES THIS PR ASK TO CLOSE THIS ISSUE, IN ITS OWN BODY?
#
# The force-close in finish() fires on ANY merged artifact PR. It was written as belt-and-suspenders for
# the cross-repo case (#4181), where a `Closes example-org/kb#N` cannot reach across repos and
# GitHub therefore never closes the issue itself. But it cannot tell that case apart from a run that
# DELIBERATELY left its issue open — and on 2026-08-14 it silently overrode one.
#
# Blocker #5598 is the hold that keeps Feature #5530 open until its 24 h journal-retention criterion can
# first be MEASURED (the journal's oldest entry is 2026-08-14T17:11:16Z, so 24 h of span first exists at
# 2026-08-15T17:11:16Z — only elapsed time gets there). Its run adjudicated the criterion "unmet, not
# wrong", said so on the issue, and REOPENED it at 18:46:54Z after a closing-keyword accident. This
# force-close shut it again at 18:49:45Z, three minutes later. The run's PR body said `Refs #5598`;
# only its SQUASH COMMIT carried a closing keyword — quoted verbatim out of the very sentence it was
# documenting as a trap. That put the PR in closedByPullRequestsReferences, which made it the artifact,
# and the runner finished the job the accident started. Three closes, none of them a decision.
#
# That is a ONE-WAY DOOR with no detector: it takes the Feature to n/n, and `stuck-pr-sweep.yml` then
# files it as complete over a criterion its own verifier said was false — exactly #4800, which is the
# defect the blocker mechanism exists to prevent.
#
# TWO tests guard the force-close, because one is not enough — measured, not assumed.
#
# TEST 1, pr_body_closes_issue(): does the PR BODY carry a closing reference to THIS issue?
# 🔴 NOT the line-based test the cross-repo (:273) and org-wide (:374) discovery paths use. Theirs asks
# whether a closing verb appears ANYWHERE ON THE SAME LINE as the issue number, and against the real
# bodies that produced this defect it answers "closes" for both #5616 and #5617 — whose entire subject
# was that they must NOT close #5598. Run it yourself and it prints `CLOSES` for both. This test mirrors
# GitHub's OWN rule instead: the keyword must sit IMMEDIATELY BEFORE the reference. That is what makes
# the sentence "this does NOT close #5598" a closing reference — the parser sees `close #5598` and never
# reads the `NOT`. Matching GitHub exactly is the point: the runner must agree with the platform about
# what the PR asked for. The optional `owner/repo` prefix is the fully-qualified cross-repo form #4181
# depends on, so that case still force-closes; a deliberate `Refs #N` matches nothing. An unreadable or
# empty body fails OPEN (treated as "asks to close"), matching docs_only_pr()'s bias — an unknown shape
# must never block a genuine close.
#
# 🔴 THE ONE SHAPE WHERE THE REGEX BELOW DID NOT MATCH GITHUB, AND IT COST 4d20h (#6986, knowledge#7537).
# The header above says "matching GitHub exactly is the point". It was one shape short: GitHub does NOT
# parse a keyword inside a CODE SPAN, and this grep read the raw body and did. PR #6667's body carried
# the keyword next to #5609 inside backticks — prose ABOUT the keyword, which is what a doc-PR on this
# subject always produces. GitHub answered `closingIssuesReferences: []`; this grep answered "closes";
# `_leave_open` stayed empty and finish() force-closed #5609, the standing-hygiene routing bucket, on
# 2026-08-23. Nothing had a routing target until 2026-08-27 and every fleet-notify alert in the window
# filed unparented.
#
# So the answer is no longer computed here. `closing-keyword-check.sh --binds` is the ONE implementation
# of "what will GitHub close", with a fixture per shape (_infra/tests/closing-keyword-check.sh) and the
# code-span rule re-verified live against PR #6667. The grep is kept as the fallback for a clone where
# the checker is missing — its bias (over-closing) is the pre-existing behaviour, so a checker that
# cannot be found can only leave things exactly as they were.
pr_body_closes_issue() {
  local repo="$1" pr="$2" body checker bodyf rc
  body=$(gh pr view "$pr" --repo "$repo" --json body --jq '.body // ""' 2>/dev/null) || return 0
  [ -z "$body" ] && return 0

  checker="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/closing-keyword-check.sh"
  if [ -x "$checker" ]; then
    bodyf="$(mktemp)" || return 0
    printf '%s' "$body" > "$bodyf"
    bash "$checker" --binds "$ISSUE" --file "$bodyf" >/dev/null 2>&1; rc=$?
    rm -f "$bodyf"
    return "$rc"
  fi

  printf '%s' "$body" | grep -qiE \
    '\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\b[[:space:]]*:?[[:space:]]*([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#'"${ISSUE}"'([^0-9]|$)'
}

# TEST 2, reopened_after_merge(): did someone REOPEN this issue after that PR merged?
# Test 1 alone would not have caught this defect, because by GitHub's own rule #5617 DID carry a closing
# reference — an accidental one, quoted verbatim out of the sentence it was documenting as a trap. What
# distinguishes the accident from an intention is what happened NEXT: the run read the close, judged it
# wrong, and reopened the issue at 18:46:54Z. A reopen that POSTDATES the merge is a decision that has
# already overruled that close, and the runner must not undo it 3 minutes later.
#
# This is not a new idea — it is `sweep-dispatch.sh`'s predicate 6 rule (`:750`, `live_marks`), applied
# to the same evidence: "a marker from before the last ReopenedEvent is not the last word, it is the last
# word of a lifecycle that has already ended." Scope is deliberately narrow: only a reopen NEWER than the
# artifact stops the close, so the #4179 case (a healer reopened a grouper, then real work shipped) still
# closes normally. Threshold is the merge time, falling back to this run's start when the discovery path
# could not supply one. Unreadable → returns false, i.e. force-close proceeds (fail open, as above).
reopened_after_merge() {
  local since="${ART_PR_MERGED_AT:-$RUN_STARTED_AT}" ro
  [ -n "$since" ] || return 1
  ro=$(gh api graphql -f query="{repository(owner:\"${REPO%%/*}\",name:\"${REPO#*/}\"){issue(number:$ISSUE){timelineItems(last:1,itemTypes:[REOPENED_EVENT]){nodes{... on ReopenedEvent{createdAt}}}}}}" \
       --jq '.data.repository.issue.timelineItems.nodes[0].createdAt // empty' 2>/dev/null) || return 1
  [ -n "$ro" ] || return 1
  [[ "$ro" > "$since" ]]
}

# #6564 — a run that declares blocked=true must not leave its issue closed when GitHub's Closes keyword
# auto-closes it at merge. Returns "REOPEN" if the issue should be reopened, "NOOP" otherwise.
# This is a READ-ONLY decision function — the actual reopen is performed by the caller.
# Parameters: $1 = blocked field value from RUN_STATE, $2 = current issue state from GitHub
should_reopen_blocked_issue() {
  local blocked="$1"
  local issue_state="$2"

  # Fail open: if we can't read the state, don't block anything (return NOOP)
  [ "$blocked" = "true" ] || { echo "NOOP"; return 0; }  # not blocked → NOOP
  [ "$issue_state" = "CLOSED" ] || { echo "NOOP"; return 0; }  # not closed → NOOP

  # blocked=true AND issue is CLOSED → this is the #5297 case, reopen it
  echo "REOPEN"
}

# #6864 — does this run's `blocked: true` declaration still stand once discover_artifact has spoken?
#
# The BLOCKED signal is a CONJUNCTION (#2866): the run DECLARED blocked AND no artifact was found.
# The declaration alone is just a model saying so; the artifact half is a fact the model does not
# author. That is right, and it is kept — a run that ships a PR OF ITS OWN and says blocked is ✔.
#
# 🔴 ONE NARROWING (#6864). The artifact half only counts when the artifact is THIS RUN'S. GitHub's
# `closedByPullRequestsReferences` binds a merged PR to an issue FOREVER — a reopen does not unbind
# it — so an issue closed once by a `Closes` keyword and then reopened carries that PR into every
# future run's discover_artifact. `ART_KIND` is `pr_merged` before the run has done anything, and the
# conjunction silently discards the declaration of every run that follows. finish() ALREADY knows
# such a PR is not this run's: at the `pr_merged` arm it says so in as many words — "created before
# this run started, so it cannot be this run's artifact" (#5128) — and marks ⚠. The same PR was
# therefore simultaneously "not this run's artifact" for the marker and "this run's artifact" for the
# blocked test. This function removes that contradiction; it does not weaken the conjunction.
#
# MEASURED, 2026-08-27. #6864 (this issue) is a VERIFY blocker that must stay OPEN until Feature #6851
# executes, which is itself gated on #6850. Its adjudicating run declared `blocked: true` naming #6850,
# and its PR #6899 — whose body said "deliberately does NOT close #6864" — closed it anyway, because
# GitHub parses the verb and not the negation (#6863). The issue was reopened, the declaration was
# dropped by the conjunction, Status went back to Todo, and the next sweep dispatched a master onto an
# issue with provably nothing to do. Two of its four sibling blockers are bound the same way:
#   #6860 OPEN closedBy=#6897(merged=true)   #6861 OPEN closedBy=#6896(merged=true)
# Without this, each is a permanent re-dispatch loop: no run can ever reach ⛔ on them.
#
# Parameters: $1 = ART_KIND, $2 = ART_PR_CREATED_AT, $3 = RUN_STARTED_AT
# Echoes STANDS (the declaration is the truth of this run) or DROPPED (this run shipped its own work).
blocked_declaration_stands() {
  local kind="$1" pr_created="$2" run_started="$3"

  # No artifact at all — the original #2866 case, unchanged.
  [ "$kind" = none ] && { echo "STANDS"; return 0; }

  # An artifact that predates this run is not this run's. Same test finish() uses at the `pr_merged`
  # arm (#5128). Fail CLOSED on a missing timestamp: an artifact we cannot date is treated as this
  # run's own, which preserves today's behaviour rather than widening it on absent data.
  if [ -n "$pr_created" ] && [ -n "$run_started" ] && [[ "$pr_created" < "$run_started" ]]; then
    echo "STANDS"; return 0
  fi

  echo "DROPPED"
}

# Write the board Status field for this issue. Extracted (#5530) from the non-closing path at the bottom
# of finish() so the deliberate-left-open path can reuse the identical write instead of copying it —
# an issue the runner declines to close must still come off `Doing`, or the reaper reads it as a run
# still in flight.
set_board_status() {
  local opt_id="$1" name="$2" item_id
  item_id=$("$_BOARD_SH" item-add 1 --owner "${REPO%%/*}" \
            --url "https://github.com/$REPO/issues/$ISSUE" --format json 2>/dev/null | jq -r '.id // empty')
  if [ -z "$item_id" ]; then
    echo "WARNING: Failed to get item id for #$ISSUE" >&2
    return 1
  fi
  if ! "$_BOARD_SH" item-edit --project-id "$PROJ" --id "$item_id" \
       --field-id "$F_STATUS" --single-select-option-id "$opt_id" >/dev/null 2>&1; then
    echo "WARNING: Failed to set Status=$name on issue #$ISSUE" >&2
    return 1
  fi
}

finish() {
  # 🔴 The rc is a PARAMETER, not `$?` (#3817). It was `local rc=$?` until run_exit_trap() was introduced
  # 25 minutes earlier by #3812 — and that wrapper's own first line, `local _orig_rc=$?`, is a command
  # whose exit status is 0, so by the time it called finish() the real code was already gone. Verified
  # live: `w(){ local o=$?; f; }` with `exit 3` → f() sees 0, the bare `trap 'f'` form sees 3. Every branch
  # below that reads $rc therefore took its rc=0 path: a genuinely failed run posted
  # "⚠ no artifact — run exited cleanly" instead of "✘ failed (exit=N)", and the whole `**error class:**`
  # block (#3417 — the reason 11 detail-free ✘ were fixed at all) never rendered. The fallback keeps a
  # direct `finish` call working the way it always did.
  local rc="${1-$?}"

  # Idempotence: skip if this run already posted a terminal (#2362). ⚠ (no-op) is terminal too (#2613).
  # ⛔ (blocked) is terminal too (#2866).
  # Check for our own ▶ + terminal from this $WHO signature AFTER our own ▶
  # #3653 — the same call now also fetches the issue's own state. `⚠ no artifact` used to read identically
  # for two opposite situations: a run that FAILED to do its job, and a duplicate run against an issue that
  # was already finished (the #3567 case). "Is the issue closed" is a fact GitHub holds, not something the
  # model declares, so the runner can tell them apart on its own — no extra API call, no new state file.
  local _fin issue_state issue_body issue_title
  # #6927 — `title` rides the SAME read that already fetches comments/state/body: the docs-only guard needs
  # it for the `^VERIFY` exemption, and adding a field to an existing call costs no extra API round-trip.
  _fin=$(gh issue view "$ISSUE" --repo "$REPO" --json comments,state,body,title 2>/dev/null || true)
  issue_state=$(printf '%s' "$_fin" | jq -r '.state // ""' 2>/dev/null || true)
  issue_body=$(printf '%s' "$_fin" | jq -r '.body // ""' 2>/dev/null || true)
  issue_title=$(printf '%s' "$_fin" | jq -r '.title // ""' 2>/dev/null || true)
  # #7167 — 🔴 THE GUARD IS PROCESS-LOCAL NOW, AND IT HAD TO BE. It used to suppress this run's terminal
  # whenever the issue's LAST comment was a terminal glyph containing this master's own $WHO string —
  # which is also exactly what a DIFFERENT run on the same master leaves behind. Measured live on fixture
  # #7189, two runs on one issue (the real double-dispatch shape): the reaped copy posted ⏹, and when the
  # SURVIVOR was stopped it read that ⏹ as "already posted" and said nothing at all. It then exited 143,
  # systemd marked the unit failed, and `OnFailure=fleet-notify@` announced `✘ the run died without
  # reporting` — a false ✘ manufactured by the very guard meant to prevent duplicate markers, on the run
  # that mattered. The same shape silences a re-dispatch onto an issue whose previous run's marker is
  # still last, which doctrine calls the one unacceptable outcome.
  #
  # What the guard is actually FOR is a second entry into finish() within THIS process. A flag set on the
  # way out is that, exactly, and nothing else can set it. The `.comments[-1]` read the old guard needed
  # is gone with it; the same `gh issue view` above still supplies issue_state/body/title, so no API call
  # was added or removed.
  if [ "${TERMINAL_POSTED:-0}" = 1 ]; then
    echo "finish: this run already posted its terminal marker on #$ISSUE — not posting a second (#7167)" >&2
    return 0
  fi

  # Derive the terminal from the ACTUAL artifact, NOT the exit code (#2613 root cause: rc=0 with zero
  # artifacts was being stamped ✔). A merged/armed PR is ✔ even on nonzero exit (#2362/#2448 preserved);
  # a clean exit with NOTHING shipped is ⚠ no-op — never ✔, never silence.
  discover_artifact

  # #3914 — a run that consumed ZERO TURNS never executed a single tool call, so it is STRUCTURALLY
  # IMPOSSIBLE for it to have created a branch, opened a PR, or pushed a commit. Any artifact
  # discover_artifact() finds for a zero-turn run is therefore, by construction, SOMEONE ELSE'S work that
  # happened to merge in the same window — proven on the wire 2026-08-03: two runs died in 5s on
  # `You've hit your session limit` (RUN_TURNS=0, no result envelope at all) and still got credited with
  # PR #3909 (unrelated sweeper code, same repo) and product-a PR #183 (a DIFFERENT REPO) — both
  # attributed by the org-wide/cross-repo fallbacks, which have no way to know the run never touched
  # anything. run_started() is already the fleet's own definition of "did this run do anything" (used by
  # the retry gate above); reusing it here closes the gap at its source instead of re-deriving per-fallback
  # heuristics. A run that legitimately shipped — even one that died on quota AFTER consuming turns — is
  # unaffected: RUN_TURNS reflects turns actually consumed, and #3812's rc-independent ✔ still applies.
  if ! run_started && [ "$ART_KIND" != none ]; then
    echo "finish: RUN_TURNS=0 (this run never started) but discover_artifact found $ART_KIND ${ART_PR_REPO:-}#${ART_PR_NUM:-} — discarding as UNRELATED to this run (#3914)" >&2
    ART_KIND=none; ART_PR_NUM=""; ART_PR_URL=""; ART_PR_MERGED_AT=""; ART_PR_CREATED_AT=""; ART_DRAFT=0
  fi

  # BLOCKED detection (#2866) — a stalled task must be visibly distinct from an unstarted one.
  # The signal is a CONJUNCTION, deliberately: the run DECLARED blocked in its run-state AND
  # discover_artifact — which asks GitHub, not the model, what PRs close this issue — found nothing
  # THIS RUN CREATED. The declaration alone is just a model saying so; the artifact half is a fact the
  # model does not author, so a run that "says blocked" while having shipped its own PR is ✔, never
  # Blocked. `blocked_declaration_stands()` is that second half, and its #6864 narrowing — a merged PR
  # bound to the issue before this run started is not this run's artifact — is documented there.
  # RUN_STATE is deleted at run start (:31), so a true here is provably from THIS run.
  # No declaration + no artifact stays ⚠ → Todo: an unexplained empty run is retryable, not blocked.
  local blocked=0 block_reason=""
  if [ -s "$RUN_STATE" ] \
     && [ "$(jq -r '.blocked // false' "$RUN_STATE" 2>/dev/null)" = "true" ] \
     && [ "$(blocked_declaration_stands "$ART_KIND" "$ART_PR_CREATED_AT" "$RUN_STARTED_AT")" = "STANDS" ]; then
    blocked=1
    block_reason=$(jq -r '.reason // ""' "$RUN_STATE" 2>/dev/null | tr '\n' ' ' | cut -c1-500)
    [ -z "$block_reason" ] && block_reason="(no reason recorded — see the run's own comment above)"
  fi

  # #6564 — SELF-HEAL: a blocked run must not leave its issue closed.
  # When GitHub's `Closes` keyword closes an issue (by merging a PR with `Closes #N`) and the run
  # declares `blocked: true`, the runner reopens the issue and states it in the close-out comment.
  # This prevents the #5297 failure pattern: the PRODUCT master (then `agent-product`, renamed `gh-account5` on 2026-08-28) declared blocked but the issue was already
  # closed by PR #5309, leaving the issue CLOSED with no open tracking item for nine days.
  local reopened_by_blocked=0
  if [ "$blocked" -eq 1 ] && [ "$issue_state" = "CLOSED" ]; then
    if gh issue reopen "$ISSUE" --repo "$REPO" >/dev/null 2>&1; then
      reopened_by_blocked=1
      echo "finish: reopened #$ISSUE — the run declared blocked: true but the issue was CLOSED (likely by a PR's Closes keyword). A blocked run must not leave its issue closed (#6564)." >&2
    else
      sleep 3
      if gh issue reopen "$ISSUE" --repo "$REPO" >/dev/null 2>&1; then
        reopened_by_blocked=1
        echo "finish: reopened #$ISSUE (retry) — the run declared blocked: true but the issue was CLOSED (#6564)." >&2
      else
        echo "ERROR: could not reopen #$ISSUE after declaring blocked: true — the issue stays CLOSED (#6564)." >&2
      fi
    fi
  fi

  local mark mark_details="" should_close=0
  case "$ART_KIND" in
    pr_merged)
      if [ -n "$ART_PR_MERGED_AT" ] && [[ "$ART_PR_MERGED_AT" < "$RUN_STARTED_AT" ]] && ! reopened_after_merge; then
        # #3523 acceptance 2 — this PR merged and closed the issue BEFORE this run even started: a stale or
        # duplicate dispatch onto an issue an earlier run already finished. `closedByPullRequestsReferences`
        # (and its fallbacks) return this PR regardless of which run shipped it, so without this check every
        # re-dispatch onto an already-closed issue earns a fresh "✔ finished" crediting THIS run's own
        # session with someone else's old merge — the exact spurious ✔ the acceptance criterion forbids.
        # #6595 — EXCEPT when the issue was REOPENED after that merge. A reopen is a decision to re-work
        # the issue, and the guard must not self-cancel that work. The reopened_after_merge check reads
        # the issue timeline for the latest REOPENED_EVENT and returns true if it postdates the merge.
        # Never close (already closed); never re-attest the rollup (no NEW $ROLLUP_STATE from this run).
        #
        # #6595 criterion 1 — EXCEPT when the issue was REOPENED after that PR merged. A human reopening
        # the issue is a deliberate decision that the work is incomplete, so a re-dispatch MUST do real work,
        # not self-cancel with "⚠ nothing to do". Without this check, a reopened issue is permanently
        # un-workable: the guard sees "PR merged before run started" and declares it stale, even though the
        # reopen made it fresh again. Test with `reopened_after_merge()`, which reads the issue timeline for
        # a ReopenedEvent newer than the PR merge time.
        if ! reopened_after_merge; then
          mark="⚠ nothing to do — PR #$ART_PR_NUM (${ART_PR_REPO}) already merged and closed this issue before this run started (merged $ART_PR_MERGED_AT, run started $RUN_STARTED_AT) — a stale or duplicate dispatch, not new work from this run."
        fi
      elif [ -n "$ART_PR_CREATED_AT" ] && [[ "$ART_PR_CREATED_AT" < "$RUN_STARTED_AT" ]]; then
        # #5128 — this PR was created BEFORE this run started, so it CANNOT have been created by THIS run.
        # A PR created by a previous run that merges during the current run (or already merged) is NOT
        # this run's artifact — it's someone else's work that this run is claiming credit for.
        # Example: #5119 merged PR #35 (six-step-residue fix), hit quota, and earned ✔ for that PR
        # even though the actual issue work (delete nine skills, build four) never happened.
        # The fix: verify the PR was created BY this run (createdAt >= run started), not just that it
        # merged during the run. Treat this as ⚠ with the reason stated — same treatment as a no-op run.
        mark="⚠ unrelated PR — PR #$ART_PR_NUM (${ART_PR_REPO}) was created ($ART_PR_CREATED_AT) before this run started ($RUN_STARTED_AT), so it cannot be this run's artifact. This run did not create or merge the PR that closed this issue; it is claiming credit for work done by a previous run. Not closing."
        mark_details=" · ${ART_PR_URL}"
      else
        # #5126 acceptance 3 — a quota-exhausted run that merged a PR did NOT finish: it hit a hard quota limit
        # and the PR it merged is unrelated work (scoped as early-phase cleanup or a parallel sweeper run).
        # Report 🪫 (the real terminal state) instead of ✔, and do NOT close the issue.
        if is_quota_exhausted; then
          mark="🪫 quota-exhausted — hit a hard quota limit and cannot continue. PR #$ART_PR_NUM (${ART_PR_REPO}) merged but is unrelated to this run's work (the run died before completing its issue)."
          mark_details=" · ${ART_PR_URL} — This PR is NOT the intended work of this issue."
        else
          local _nonmd="" _dop_effect=""
          docs_only_pr "$ART_PR_REPO" "$ART_PR_NUM" && _nonmd=$(acceptance_nonmd_hit "$issue_body")
          # #6927 — the exemption runs LAST and only once the conjunction is already true, so its API calls
          # are paid on the rare warning path and never on the ordinary close. It is announced on stderr
          # because a check that goes quiet without saying so is indistinguishable from one that never ran.
          if [ -n "$_nonmd" ] && docs_only_exempt "$issue_title" "$ART_PR_REPO" "$ART_PR_NUM" "$issue_body"; then
            echo "finish: docs-only warning SUPPRESSED for #$ISSUE — $DOCS_ONLY_EXEMPT_WHY (#6927 #7177)" >&2
            _nonmd=""
          fi
          if [ -n "$_nonmd" ]; then
            # #3914 — every changed path is `.md` AND the Acceptance section names a concrete non-markdown
            # deliverable: this PR is a REPORT about the work, not the work. Never close on it.
            #
            # #6927 — the sentence used to end "the deliverable does not exist yet. Not closing." Both
            # halves were claims this check cannot make. The first is a CONCLUSION: the named path may be
            # something the work READS (`installed_plugins.json` on #6925), and text matching cannot tell
            # a consumed path from a produced one. The second is an OUTCOME: on the ordinary same-repo
            # shape GitHub's own `Closes #N` closed the issue at merge, seconds before this line runs, and
            # nothing here reopens it — so "Not closing" described a state that was already false as it
            # was written. What this branch actually does is withhold the runner's OWN belt-and-suspenders
            # close and send board Status back to Todo; `$issue_state` is read from GitHub at the top of
            # finish() (the same `gh issue view` that supplies the body), so the real consequence can be
            # stated instead of assumed.
            if [ "$issue_state" = "CLOSED" ]; then
              _dop_effect="The issue is **already CLOSED** — GitHub's own \`Closes\` keyword closed it at merge and no comment can reopen it. The runner is withholding its own close and setting board Status back to \`Todo\`; treat this as a flag to read the PR, not as a hold."
            else
              _dop_effect="The runner is not closing this issue; board Status goes back to \`Todo\`."
            fi
            mark="⚠ docs-only PR — PR #$ART_PR_NUM (${ART_PR_REPO}) changed only \`.md\` files, while the issue's Acceptance names \`$_nonmd\`. That mismatch has three readings this check cannot tell apart: the deliverable never shipped; \`$_nonmd\` is a path the work READS rather than produces; or the deliverable is OFF-REPO by construction — a file on a box, a systemd unit, a credential — and no diff could have carried it. $_dop_effect"
            mark_details=" · ${ART_PR_URL}"
          else
            mark="✔ finished"; mark_details=" · PR #$ART_PR_NUM merged (${ART_PR_REPO}): ${ART_PR_URL}"; should_close=1
          fi
        fi
      fi ;;
    pr_open)
      if [ "$ART_DRAFT" = 1 ]; then
        # A draft is the deliberate stop-for-review hatch (irreversible-class work) — genuinely finished.
        mark="✔ finished"; mark_details=" · DRAFT PR #$ART_PR_NUM open for review (${ART_PR_REPO}): ${ART_PR_URL}"
      else
        # #3489 — an OPEN non-draft PR is NOT finished. This previously said "✔ finished · auto-merge armed",
        # which is how 15 PRs stacked up across three repos while every run reported success. Nothing gates
        # main here (branch protection + rulesets 403), so an unmerged PR means the merge genuinely failed —
        # conflict, or a real build break. Either way the issue stays open and the board keeps it visible.
        mark="⚠ PR #$ART_PR_NUM is OPEN, not merged — the task is NOT done"
        mark_details=" · ${ART_PR_URL} (${ART_PR_REPO}). See the merge-failure comment above for the real error. Fix forward: rebase if conflicted, then \`gh pr merge $ART_PR_NUM --repo ${ART_PR_REPO} --squash --admin\`."
      fi ;;
    commits)
      # #3062 Change 1 — pushed-but-unopened code is UNMERGED and UNDEPLOYED. It used to earn the same
      # ✔ as a shipped feature, which is exactly why "the board says done" and "it works" drifted apart.
      # #5988 — "(no PR opened)" was itself an unmeasured claim of the same class this issue fixes:
      # discover_artifact() reaches this arm whenever no PR CLOSES the issue, which includes the case
      # where a PR exists and merely omits `Closes #N`. Measure it before asserting it.
      branch_evidence
      if [ -n "$BEV_PR_NUM" ]; then
        mark="⚠ commits pushed and a PR exists, but no PR closes #$ISSUE — the board cannot see this work"
        mark_details=" · $(branch_evidence_sentence) $(no_closes_recovery)"
      else
        mark="⚠ pushed, no PR"
        mark_details=" · commits pushed on \`${BEV_BRANCH:-$(git -C "$WORKDIR" branch --show-current 2>/dev/null)}\` and no PR was found for that branch — NOT merged, NOT deployed. The task is not done."
      fi ;;
    *)
      # NO ARTIFACT. rc=0 is not success here — it is a no-op (the refuse/produce-nothing/clean-exit path).
      if [ "$blocked" -eq 1 ]; then
        # #3653 — the wording was "a human-only step", which is now one of two blockers a run can declare.
        # The other is a REQUIRED INPUT THAT DOES NOT EXIST YET (a synthesis task dispatched alongside the
        # tasks producing its inputs). Both are "cannot proceed, nothing left to ship"; both must be
        # Blocked rather than Todo. The reason string is what distinguishes them, and it is already shown.
        mark="⛔ blocked — the run declared a step it could not complete (a human-only action, or a required input that does not exist yet) and had nothing left to ship. Board Status set to **Blocked** (not Todo) so this is visibly distinct from an unstarted task. **To release this block for re-dispatch, post a comment that BEGINS with the word UNBLOCK (all caps, first thing on the line — a trailing reason on the same line is fine) after the blocker is cleared.**"
        mark_details=" · blocker: $block_reason"
        if [ "$reopened_by_blocked" -eq 1 ]; then
          mark_details+="

🔓 **This issue was REOPENED** — the run declared blocked: true but the issue was CLOSED (likely by a PR's \`Closes #N\` keyword when it merged). A blocked run must not leave its issue closed, so the runner reopened it. The board and the transcript now agree (#6564)."
        fi
      elif [ "$rc" -eq 0 ] && [ "$issue_state" = "CLOSED" ]; then
        # #3653 acceptance 2 — "nothing to do" vs "did not do it". The issue was ALREADY CLOSED when this
        # run finished, so an empty run is the correct outcome, not a failure: this is the duplicate-run
        # case (#3567), where the identical ⚠ string sent a reader hunting for a defect that did not exist.
        # Deliberately NOT a ✔: this run shipped nothing and must not be read as having done the work.
        mark="⚠ nothing to do — the issue was already CLOSED when this run finished, so an empty run is the expected outcome (duplicate or superseded dispatch), NOT a failure. No PR was opened because none was needed."
      elif [ "$rc" -eq 0 ]; then
        # #5988 — this used to read "opened no PR, armed no merge, and pushed no commits. Nothing
        # shipped" off a check that measures ONE thing: whether GitHub reports a PR closing this
        # issue. Three of those four claims were never checked, and on #5949 all four were false —
        # PR #5961 was merged, its code live, and the body simply had no `Closes #5949`. The marker
        # now states its own measurement and then reports what branch_evidence() actually found.
        branch_evidence
        mark="⚠ no PR closing #$ISSUE was found — that is the only thing this check measures"
        mark_details=" · $(branch_evidence_sentence) $(no_closes_recovery) If the run instead stopped because a required INPUT was missing, that is a ⛔ blocker it failed to declare (see BRIEF step 6) — never a silent clean exit."
      elif [ "${RUN_STOPPED:-0}" -eq 1 ]; then
        # #7167 — 🔴 THE DELIBERATE STOP. This run received SIG$RUN_STOP_SIGNAL from outside itself, which
        # a crash cannot do: a crashing process exits with its own status, it does not signal itself. So
        # this is not a claim that the WORK failed — it is the record that someone stopped this COPY of it,
        # which is overwhelmingly a duplicate-dispatch cleanup with a sibling run still going.
        #
        # ⏹ is deliberately NOT ✘ and deliberately NOT silent:
        #   · not ✘ — `✘` is what the Architect's monitor and every last-marker reader classify as a failed
        #     phase. On #7124 the ✘ from the reaped copy was the issue's last word while the surviving run
        #     was mid-flight, and the issue then CLOSED reading `starts=2 last=✘`.
        #   · not silent — silence is the one unacceptable outcome (#2619). An issue whose run vanished with
        #     no marker is indistinguishable from one still working.
        # ⏹ is also NOT terminal to `sweep-dispatch.sh` predicate 6 (which latches on ▶/✔ only), so a
        # stopped run leaves the issue re-dispatchable — while predicate 5's fleet-wide live-unit check is
        # what stops a THIRD run landing on top of a survivor. Both halves are needed; neither is enough.
        mark="⏹ stopped — this run was DELIBERATELY STOPPED (SIG${RUN_STOP_SIGNAL:-TERM}, exit=$rc). **NOT a failure**"
        mark_details=" · ${RUN_STOP_EVIDENCE:-no unit state could be read}. A crash exits with its own status; it cannot signal itself, so this run was stopped by something outside it — a \`systemctl --user stop\`, a \`kill\`, or a session shutdown. The usual cause is duplicate-dispatch cleanup, in which case **another run on this issue is still working and its own marker is the one to read**. This comment makes no claim about whether the issue's work succeeded (#7167)."
      else
        mark="✘ failed (exit=$rc) — and produced no artifact"
      fi ;;
  esac

  # #6864 — the marker must agree with the Status this run is about to write. `blocked` can now be 1
  # while ART_KIND is pr_merged/pr_open/commits, because the artifact belongs to an EARLIER run
  # (blocked_declaration_stands()). Every such arm produces a ⚠, which says "nothing here shows THIS
  # run finished" — true, and exactly compatible with ⛔, but it is non-terminal to sweep-dispatch.sh
  # predicate 6 and it never states the UNBLOCK release protocol. Left as a ⚠ the board reads
  # "retryable", which is the loop this fixes. Only ⚠ is rewritten: a ✔ (this run's own PR, or a
  # deliberate draft) and a ✘/🪫 are each their own terminal truth and are never overridden.
  if [ "$blocked" -eq 1 ]; then
    case "$mark" in
      "⚠"*)
        mark_details=" · blocker: $block_reason

The artifact check below is retained because it is true, and it is NOT why this run stopped: ${mark}${mark_details}"
        mark="⛔ blocked — the run declared a step it could not complete and had nothing left to ship. The only PR GitHub reports against this issue was created before this run started, so it is an earlier run's artifact, not this one's (#6864). Board Status set to **Blocked** (not Todo) so this is visibly distinct from an unstarted task. **To release this block for re-dispatch, post a comment that BEGINS with the word UNBLOCK (all caps, first thing on the line — a trailing reason on the same line is fine) after the blocker is cleared.**"
        ;;
      "✔"*)
        # A ✔ is this run's own terminal truth and outranks the declaration — the only ✔ reachable with
        # `blocked` set is the deliberate DRAFT-for-review hatch on a pre-existing PR. Drop the block so
        # the Status write below cannot say Blocked under a marker that says finished.
        blocked=0 ;;
    esac
  fi

  # #3812 — a merged (or draft-for-review) artifact is a real success NO MATTER what $rc says. The CLI can
  # exit nonzero for reasons that have nothing to do with whether the work shipped (measured 2026-08-02: a
  # burst of ~25 runs across bravo/charlie/alpha all hit "session limit" the instant they finished — 45 turns,
  # PR merged, `exit=1` — and every one still tripped systemd's OnFailure, auto-filing a false "unit failed"
  # board issue for work that had already succeeded). $mark is already the artifact-derived truth (:435);
  # this just lets the PROCESS exit code agree with the COMMENT it just posted, instead of the raw CLI exit.
  case "$mark" in
    "✔ finished"*) FINISH_EXIT=0 ;;
    # #7167 — a run that was asked to stop and did is a SUCCESSFUL shutdown, not a failed unit. Exiting
    # 143 makes systemd mark the unit `failed`, and every user service on these boxes carries
    # `OnFailure=fleet-notify@%N.service` (~/.config/systemd/user/service.d/50-onfailure.conf), so a
    # deliberate stop auto-filed a board issue announcing a failure that never happened — the same false
    # signal as the ✘, one layer down.
    "⏹ stopped"*) FINISH_EXIT=0 ;;
  esac

  # #3062 Change 3 — label only the ✔ marks; a ⚠/✘/⛔ already says the run did not finish, so adding
  # UNVERIFIED there is noise. Pure string append to $mark_details: no branch below reads it, so this
  # cannot change should_close, the close call, rollup_attest, the Status field, or the exit code.
  case "$mark" in
    "✔ finished"*) mark_details+="$(verification_evidence)" ;;
  esac

  # #4181 — THE ✔ TOMBSTONE, half one: the ✔ that KNOWINGLY leaves its issue open.
  # `sweep-dispatch.sh` predicate 6 treats ▶/✔/⛔ as terminal, so a ✔ on an issue that stays OPEN makes
  # that issue permanently undispatchable — the success marker becomes a gravestone, and anything chained
  # behind it is held forever. There is exactly one ✔ path here that does not close: a DRAFT PR (the
  # deliberate stop-for-review hatch). That combination is INTENDED, but it was silent, and the
  # non-closing path below then sets Status back to **Todo** — so the board shows a queued task that no
  # sweep cycle can ever pick up, and only a human reading this comment can tell the two apart. Say it.
  # Appended to $mark_details only: no branch below reads it, so this changes no disposition.
  if [ "$should_close" -ne 1 ]; then
    case "$mark" in
      "✔ finished"*) mark_details+="
🪦 **This ✔ leaves #$ISSUE OPEN, which makes it UNDISPATCHABLE** — \`sweep-dispatch.sh\` predicate 6 reads ▶/✔/⛔ as terminal, so no sweep cycle will take this issue again until it is closed or a non-terminal comment lands. Intended here (the draft PR is awaiting review), but stated rather than silent. The whole class: \`sweep-dispatch.sh --explain | grep ✔-TOMBSTONE\` (#4181)." ;;
    esac
  fi

  # #3062 Change 2 — the terminal comment body is built ONCE and reused on BOTH paths below (the close
  # path and the non-closing path). It used to be a bespoke one-line `_close_body` on the close path
  # (no mark_details, no RESULT tail, no error class) — evidence-free, and the exact defect this task
  # exists to fix: "3 of 9 recent close-outs landed with no evidence at all, on the one path that means
  # success." Building it here, before the branch, makes reuse structural rather than a convention to
  # remember to follow next time this function is touched.
  local _body _tail
  _tail=$( [ -n "$RESULT" ] && printf '%s\n' "$RESULT" | tail -c 1500 )
  # #7167 — a ⏹ carries no error class. `classify_error` exists to diagnose a FAILURE; on a deliberate
  # stop it would render "no-output -- the CLI produced nothing on stdout or stderr (exit=143)" under a
  # marker that says the opposite, which is the same false-failure signal in a second place.
  if [ "$ART_KIND" = none ] && [ "$rc" -ne 0 ] && [ "${RUN_STOPPED:-0}" -ne 1 ]; then
    classify_error "$rc"
    _tail="**error class:** ${ERR_CLASS}
\`\`\`
$(printf '%s' "$ERR_TEXT" | tail -c 1500)
\`\`\`"
  fi
  _body="$mark — \`$WHO\` · account \`$ACCOUNT\`$([ -n "$SESSION" ] && echo " · session \`$SESSION\`")$mark_details${RETRY_NOTE:+
$RETRY_NOTE}
$_tail"

  # #4800 — record this run's VERIFY verdict BEFORE either branch below. Deliberately not inside the
  # close path: a verification-only VERIFY task ships no PR and never closes (#4524 is one), and its
  # failing criteria still have to reach the board. `verify-verdict.sh` exits 0 in silence on any issue
  # whose title does not start with VERIFY, so this is a no-op on every other dispatch. Bookkeeping may
  # never kill a run (#3315), hence the `|| true`.
  bash "$CLONE/_infra/scripts/verify-verdict.sh" "$ISSUE" --repo "$REPO" 2>&1 | sed 's/^/  /' >&2 || true

  if [ $should_close -eq 1 ]; then
    # #3532 (Task 9) — root cause of the #3476 silence: the merged PR's own `Closes #N` already auto-
    # closes the issue, seconds before this trap runs. `gh issue close --comment` on an ALREADY-closed
    # issue prints "already closed", returns rc=0 (NOT an error — the `|| {…}` below never fires), and
    # SILENTLY DROPS the comment. Verified live (scratch issue #3533, 2026-08-01): a second
    # `gh issue close --comment` on a closed issue posts nothing. That is exactly #3476's shape — ▶
    # started, PR merged 2m30s later, issue auto-closed by the merge, and this line's comment vanished
    # into the same no-op. Fix: post the FULL terminal comment — the SAME $_body the non-closing path
    # posts below, not a bespoke evidence-free one-liner (#3062 Change 2) — via `gh issue comment`
    # (works on open OR closed issues) FIRST, with the same retry-once-then-loud-error #3417 already
    # uses below; only then attempt the close, whose result is now irrelevant to whether the comment
    # landed — the merge already closed it in the overwhelmingly common case, so this is deliberate
    # belt-and-suspenders, not the terminal signal.
    if ! gh issue comment "$ISSUE" --repo "$REPO" --body "$_body" >/dev/null 2>&1; then
      sleep 3
      if ! gh issue comment "$ISSUE" --repo "$REPO" --body "$_body" >/dev/null 2>&1; then
        echo "ERROR: could not post the '$mark' terminal marker on #$ISSUE after PR merge — the run is now SILENT" >&2
      fi
    fi
    TERMINAL_POSTED=1   # #7167 — this process has spoken; a second entry into finish() must not repeat it

    # #6564 — if this run declared blocked and the issue was auto-closed by GitHub's Closes keyword,
    # reopen it. A run's own decision to leave its issue open outranks a lifecycle keyword.
    local _reopen_blocked="" _rb_body=""
    if [ -s "$RUN_STATE" ]; then
      local _blocked _current_state _reopen_decision
      _blocked=$(jq -r '.blocked // false' "$RUN_STATE" 2>/dev/null || echo "false")
      _current_state=$(gh issue view "$ISSUE" --repo "$REPO" --json state --jq '.state' 2>/dev/null || echo "")
      _reopen_decision=$(should_reopen_blocked_issue "$_blocked" "$_current_state")
      if [ "$_reopen_decision" = "REOPEN" ]; then
        _reopen_blocked="this run declared blocked=true (reason: $(jq -r '.reason // ""' "$RUN_STATE" 2>/dev/null | tr '\n' ' ' | cut -c1-200)), but the issue was auto-closed by GitHub at merge"
        if gh issue reopen "$ISSUE" --repo "$REPO" >/dev/null 2>&1; then
          echo "finish: REOPENED #$ISSUE — $_reopen_blocked (#6564)." >&2
          # Post a marker explaining the reopen
          _rb_body="🔓 **Issue REOPENED — the run declared it blocked and that decision outranks GitHub's auto-close.**

A run that writes \`{\"blocked\":true}\` to its run state is making a deliberate decision to leave its issue open, because it did not complete its work (a human-only step, or a required input that does not exist yet). GitHub's \`Closes\` keyword auto-closes the issue at merge regardless, which overrides the run's own judgment — the #5297 case, where this left the issue closed and untracked for nine days while the token cleanup it was supposed to do remained unfinished.

The runner now detects this case at close-out and reopens the issue, so the board state matches the run's own terminal assessment. The issue remains open and dispatchable until the blocker is cleared."

          if ! gh issue comment "$ISSUE" --repo "$REPO" --body "$_rb_body" >/dev/null 2>&1; then
            sleep 3
            if ! gh issue comment "$ISSUE" --repo "$REPO" --body "$_rb_body" >/dev/null 2>&1; then
              echo "ERROR: could not post the blocked-reopen marker on #$ISSUE — the reopen itself succeeded" >&2
            fi
          fi
        else
          echo "ERROR: failed to reopen #$ISSUE despite blocked=true — the issue will stay closed incorrectly" >&2
        fi
      fi
    fi

    # #5530 — THE PR MUST ASK, AND NOBODY MAY HAVE OVERRULED IT SINCE. Everything below this guard forces
    # the issue shut. The two tests separate "GitHub could not close it" (cross-repo, #4181 — still force
    # it) from "this run chose not to close it, or already undid the close" (a deliberate hold — leave it
    # alone). Without the guard the runner shut blocker #5598 three minutes after its own run reopened it,
    # which would have taken Feature #5530 to n/n and let the auto-closer file it as complete over a
    # criterion its own verifier had just found false.
    local _leave_open="" _lo_body=""
    if ! pr_body_closes_issue "$ART_PR_REPO" "$ART_PR_NUM"; then
      _leave_open="its body carries no closing reference to this issue — it references it without a closing keyword"
    elif reopened_after_merge; then
      _leave_open="this issue was REOPENED after that PR merged, which is a decision that has already overruled the close"
    fi
    if [ -n "$_leave_open" ]; then
      echo "finish: NOT forcing the close of #$ISSUE — $_leave_open (PR #$ART_PR_NUM, ${ART_PR_REPO}) (#5530)." >&2
      # 🔓 IS A MARKER, AND IT IS THE ONE THAT MAKES THIS ISSUE DISPATCHABLE AGAIN (#5598).
      # This comment was first written with no glyph, on the reasoning that "predicate 6 keys on the LAST
      # marker and this issue is meant to stay dispatchable". That had it exactly backwards: with no glyph
      # the comment was invisible to `sweep-dispatch.sh`, so the LAST marker stayed the ✔ posted seconds
      # earlier — which predicate 6 rejects. The issue sat `Todo` on the board, unreachable by every sweep,
      # under this comment asserting the opposite. That is the ✔ TOMBSTONE of #4181, produced by the guard
      # that exists to protect a deliberate hold, and it would have stranded blocker #5598 itself — the
      # hold keeping Feature #5530 open until its 24 h journal criterion can first be MEASURED, which needs
      # to be re-dispatchable after every run that finds it still unmet.
      # 🔓 is now in the marker vocabulary of all four `def marks` copies in sweep-dispatch.sh and is
      # NON-terminal: predicate 6 rejects only ▶/✔, and it charges no retry (the attempt cap counts ▶).
      # `_infra/scripts/test-leave-open-mark.sh` slices predicate 6 out of that file and grades this exact
      # comment against it, with the terminal cases as negative controls.
      #
      # Consequently this post is LOAD-BEARING, not narration: if it fails, the ✔ is the last marker and
      # the issue is silently undispatchable. So it gets the same retry-once-then-say-so treatment as the
      # terminal marker above (#3417) instead of the `|| true` it used to swallow its result with.
      _lo_body="🔓 **Left OPEN deliberately — the runner did not force this issue shut.**

PR #${ART_PR_NUM} (\`${ART_PR_REPO}\`) merged, but ${_leave_open}. The runner used to force the close here anyway, which silently overrode a run's own decision to leave its issue open: on 2026-08-14 it shut blocker #5598 three minutes after that run had reopened it, and closing it would have taken its parent Feature to n/n and let \`stuck-pr-sweep.yml\` file the Feature as complete over a criterion its own verifier had just found false (#4800, #5530).

**A cross-repo artifact still force-closes** — a fully-qualified \`OWNER/REPO#N\` closing reference in the PR body matches this test, which is the #4181 case.

If this issue should in fact be closed, that is a decision to record on it — not a re-dispatch. The board Status has been set back to \`Todo\`, and this comment is itself the marker that keeps the issue dispatchable: 🔓 is in the marker vocabulary \`sweep-dispatch.sh\` reads, and predicate 6 treats it as non-terminal, so the next sweep can take this issue rather than reading the ✔ above as a tombstone (#5598)."
      if ! gh issue comment "$ISSUE" --repo "$REPO" --body "$_lo_body" >/dev/null 2>&1; then
        sleep 3
        if ! gh issue comment "$ISSUE" --repo "$REPO" --body "$_lo_body" >/dev/null 2>&1; then
          echo "ERROR: #$ISSUE was left OPEN deliberately but the 🔓 marker could NOT be posted — the ✔ above is now the last marker, which sweep-dispatch.sh predicate 6 reads as terminal. The issue is Todo and UNDISPATCHABLE until a non-terminal comment lands on it (#5598, #4181)." >&2
        fi
      fi
      set_board_status "$S_TODO" Todo || true
      rollup_attest
      return 0
    fi

    # #6595 criterion 4 — defensive check: do NOT force-close an issue that a human reopened
    # after the PR merged. A reopen is a decision to re-work the issue, and the bot must not
    # override that decision by closing it again. Even if the run earned should_close=1, a
    # reopened issue stays open.
    if reopened_after_merge; then
      _lo_body="🔓 **Left OPEN — issue was REOPENED after PR merged.**

PR #${ART_PR_NUM} (\`${ART_PR_REPO}\`) merged and closed this issue, but it was subsequently REOPENED (a human decision to re-work the issue). The runner is honoring that reopen and NOT closing the issue again — doing so would re-impose the original closure over a deliberate decision to continue the work.

If this issue should in fact be closed, that is a decision to record on it — not a re-dispatch."

      if ! gh issue comment "$ISSUE" --repo "$REPO" --body "$_lo_body" >/dev/null 2>&1; then
        sleep 3
        if ! gh issue comment "$ISSUE" --repo "$REPO" --body "$_lo_body" >/dev/null 2>&1; then
          echo "ERROR: could not post the left-open marker on reopened #$ISSUE" >&2
        fi
      fi
      set_board_status "$S_TODO" Todo || true
      return 0
    fi

    gh issue close "$ISSUE" --repo "$REPO" >/dev/null 2>&1 || true
    # #4181 — THE ✔ TOMBSTONE, half two: the ✔ that MEANT to close and didn't.
    # The line above was written as belt-and-suspenders and swallows its own result, so "closed" was never
    # a fact this function checked — and a ✔ whose close silently no-ops leaves a TERMINAL marker on an
    # OPEN issue, which predicate 6 of sweep-dispatch.sh makes permanently undispatchable. Two real cases,
    # both 2026-07-25: knowledge#2408 (credited app-repo#104) and #2425 (credited app-repo#107). Both PRs were
    # real and merged; both were in ANOTHER repo, and a cross-repo `Closes #N` cannot close an issue here,
    # so neither the merge nor this line ever closed them. They sat Todo-and-unreachable for ten days.
    # Read the issue's REAL state back — never trust the close call's exit code. REST, not `gh issue view`:
    # the GraphQL path 500s on `projectCards` (Projects-classic deprecation) on this repo today.
    local _st
    _st=$(gh api "repos/$REPO/issues/$ISSUE" --jq '.state' 2>/dev/null)
    if [ "$_st" = "open" ]; then
      sleep 3
      gh issue close "$ISSUE" --repo "$REPO" >/dev/null 2>&1 || true
      _st=$(gh api "repos/$REPO/issues/$ISSUE" --jq '.state' 2>/dev/null)
    fi
    if [ "$_st" = "open" ]; then
      # Loud, greppable, and on the issue itself — but DELIBERATELY not starting with a marker glyph.
      # Predicate 6 keys on the LAST marker, and a ⚠ here would re-dispatch work that genuinely shipped.
      # The remedy is a close, not another run; this comment is what makes the stall findable at all.
      echo "ERROR: #$ISSUE is STILL OPEN after a merged-PR ✔ and two close attempts — it is now a ✔ TOMBSTONE (undispatchable). See knowledge#4181." >&2
      gh issue comment "$ISSUE" --repo "$REPO" --body "🪦 **✔ TOMBSTONE — this issue is still OPEN after a merged-PR \`✔\`.**

The close did not land (two attempts). \`sweep-dispatch.sh\` predicate 6 reads a trailing \`✔\` as terminal, so **this issue is now undispatchable** and anything chained behind it is held — while the board still shows it as work. The most common cause is a cross-repo artifact: a \`Closes #N\` in **${ART_PR_REPO}** cannot close an issue in **${REPO}**.

**Remedy:** verify the acceptance against the live artifact, then close it — do NOT re-dispatch; PR #${ART_PR_NUM} (${ART_PR_REPO}) is merged. Whole class: \`sweep-dispatch.sh --explain | grep ✔-TOMBSTONE\` (#4181)." >/dev/null 2>&1 || true
    fi
    # The close above may have just completed the parent Feature — a Feature has no PR, so nothing else in
    # this system can ever notice. GitHub already computed it; ask (#3309). Attests only; never closes.
    rollup_attest
    return 0
  fi

  # Not closing: move Status off Doing using the ProjectV2 field (not a label).
  # Blocked (#2866) when the run declared a blocker and shipped nothing; otherwise back to Todo (retryable).
  # Leave Done to board-reconcile.yml backstop.
  # Make this failure loud - silent failures are what created this issue
  local target_status="$S_TODO" target_name=Todo
  if [ "$blocked" -eq 1 ]; then target_status="$S_BLOCKED"; target_name=Blocked; fi
  # #7167 — a ⏹ writes NO Status at all, and that is the whole point. This run cannot see whether a
  # sibling on ANOTHER master is still working the issue (each master's units live in its own systemd user
  # manager), so `Todo` would be a claim it has no way to check — and on the case this exists for it is
  # FALSE: the survivor is running and `Doing` is correct. Leaving Status alone is right in both
  # directions, because the orphan case (Doing with no live unit anywhere) is ALREADY the defined input of
  # `sweep-dispatch.sh`'s reaper — `REAPER_MINUTES=120`, measured against a longest-ever observed run of
  # ~60 minutes — which resets it to Todo. No new mechanism, and no guess written to the board.
  case "$mark" in
    "⏹ stopped"*)
      echo "finish: NOT writing board Status for #$ISSUE — this run was stopped deliberately and cannot see whether a sibling run on another master survives; the sweeper's reaper owns the orphan case (#7167)" >&2 ;;
    *) set_board_status "$target_status" "$target_name" || true ;;
  esac

  # Post terminal comment for non-closing runs
  # This is the ONLY liveness signal a run emits — doctrine: "silence is the only unacceptable state."
  # It used to end `>/dev/null 2>&1 || true`, the only write in this file that swallowed its own failure,
  # while :174/:190/:193 all log theirs. On 2026-07-27 EIGHT runs closed with no marker at all (#2902
  # #2898 #2868 #2866 #2872 #2916 #2790 #2792), making a silent success indistinguishable from a hang.
  # Retry once, then log LOUDLY. Never `|| true` this one.
  # A failed run with no artifact must never be undiagnosable (#3417): attach the error class + the real
  # failure text, replacing the bare `$RESULT` append that produced 11 detail-free ✘ across 169 runs.
  if ! gh issue comment "$ISSUE" --repo "$REPO" --body "$_body" >/dev/null 2>&1; then
    sleep 3
    if ! gh issue comment "$ISSUE" --repo "$REPO" --body "$_body" >/dev/null 2>&1; then
      echo "ERROR: could not post the '$mark' terminal marker on #$ISSUE — the run is now SILENT" >&2
    fi
  fi
  TERMINAL_POSTED=1     # #7167 — as above
}

# Give the per-run workspaces back (#3432). NOT folded into finish(): finish() has two early `return`
# paths (:361 the already-posted-marker guard, :439 the closing branch), so anything appended to its body
# is skipped on exactly the runs that matter most. A clean workspace is removed; one still holding
# uncommitted work is KEPT and named on stderr — the inverse of the silent wipe this fixes.
release_workspaces() {
  local rw="$CLONE/_infra/scripts/run-workspace.sh"
  [ -f "$rw" ] || return 0
  bash "$rw" release "$CLONE" "$WS" || true
  [ -n "$WS_TARGET_CLONE" ] && bash "$rw" release "$WS_TARGET_CLONE" "$WS_TARGET" || true
  return 0
}
# #3812 — a bare `trap 'finish; release_workspaces' EXIT` cannot change the process's own exit code: bash
# preserves the $? that TRIGGERED the trap as the final exit status unless the trap explicitly `exit`s
# (verified live — a trap function returning 0 does NOT override a preceding `exit 1`). So overriding the
# exit code requires an explicit `exit` INSIDE the trap, which would abort release_workspaces() if placed
# in finish() itself — hence this wrapper: capture the original rc first (before finish() can touch $?),
# run both cleanup steps unconditionally, THEN exit once with finish()'s verdict if it set one.
run_exit_trap() {
  local _orig_rc=$?
  finish "$_orig_rc"          # HAND it over (#3817) — `local _orig_rc=$?` above already reset $? to 0
  release_workspaces
  exit "${FINISH_EXIT:-$_orig_rc}"
}
trap run_exit_trap EXIT
# #2619: bash runs the EXIT trap on normal exit and on a HANDLED signal, NOT on an unhandled SIGTERM
# (which terminates the shell without firing EXIT). `systemd-run --user` stops a unit with SIGTERM→SIGKILL,
# so `systemctl stop`, a RuntimeMaxSec timeout, an OOM kill, or a reboot skip finish() and strand the issue
# in Doing forever. Re-raising each terminating signal as an `exit` makes the EXIT trap fire with a real
# nonzero rc → finish() runs its unchanged artifact-discovery path and posts ✘/⚠ instead of silence.
# finish() is idempotent (:118 checks for its own terminal comment), so a double-fire is safe. SIGKILL
# stays uncoverable by design — that is the open-stranded case board-reconcile.yml exists to catch (#2619).
#
# #7167 — the re-raise now RECORDS that it happened, because `exit 143` alone is indistinguishable from a
# crash by the time finish() reads it. A crash never delivers SIGTERM to itself: this handler runs ONLY
# when something outside asked this run to stop (`systemctl stop`, a `kill`, a session shutdown). That
# fact — not a guess about the exit code — is what finish() keys the ⏹ marker on.
note_stop() {   # <signal-name> — runs INSIDE the signal handler, before the re-raised exit
  RUN_STOPPED=1
  RUN_STOP_SIGNAL="$1"
  # The unit's OWN state, read at the instant the signal lands. systemd moves a unit to `deactivating`
  # when the stop JOB starts — before it sends the signal — so this is the same fact the journal's
  # `Stopping task-<n>.service...` line records, read from the source instead of grepped out of a log this
  # process may not have permission to read. The unit name comes from the cgroup, which is where systemd
  # actually put this process; nothing sets it in the environment.
  # 🔴 A SIGNAL HANDLER MUST NOT DEPEND ON A PIPELINE. This was `sed … /proc/self/cgroup | head -1` and
  # it read EMPTY on one of two otherwise identical live stops (fixture #7189 case 1 vs #7188) — a handler
  # runs at an arbitrary point in the shell's own execution, and a forked pipeline there is a coin flip.
  # `read` is a builtin: no fork, no pipe, nothing to lose the race with. cgroup v2 is one line, and the
  # unit name is whatever follows the last `/`.
  local _u="" _st _cg=""
  read -r _cg < /proc/self/cgroup 2>/dev/null || true
  _u="${_cg##*/}"; _u="${_u%.service}"
  case "$_u" in task-[0-9]*) : ;; *) _u="" ;; esac
  if [ -n "$_u" ]; then
    _st="$(systemctl --user show "$_u.service" -p ActiveState --value 2>/dev/null || true)"
    RUN_STOP_EVIDENCE="unit \`$_u.service\` was \`ActiveState=${_st:-unknown}\` at signal time"
  else
    RUN_STOP_EVIDENCE="not running under a \`task-*.service\` unit (no cgroup match) — the signal still came from outside this process"
  fi
  return 0
}
trap 'note_stop TERM; exit 143' TERM
trap 'note_stop INT;  exit 130' INT
trap 'note_stop HUP;  exit 129' HUP

# RECEIVE (M4, #2286): unread @mentions are injected into this run's brief, then marked read AFTER
# injection — GitHub's durable read-state makes delivery at-least-once (a crashed run before this
# point leaves them unread for the next run). Comms live ON the work items; there is no bus.
MAIL=""
THREADS=$(gh api 'notifications?participating=true&per_page=20' \
  --jq '[.[] | select(.unread and .reason=="mention")] | .[0:5] | .[] | [.id, .subject.latest_comment_url // .subject.url, .subject.title] | @tsv' 2>/dev/null || true)
if [ -n "$THREADS" ]; then
  while IFS=$'\t' read -r tid curl title; do
    [ -n "$curl" ] || continue
    body=$(gh api "$curl" --jq '"[\(.user.login)] \(.body)"' 2>/dev/null | head -c 800 || true)
    MAIL="$MAIL
--- mention in: $title
$body"
    gh api -X PATCH "notifications/threads/$tid" >/dev/null 2>&1 || true
  done <<< "$THREADS"
fi

# ── PER-RUN CHECKOUT ISOLATION (#3432) ─────────────────────────────────────────────────────────────
# The shared clone is now only ever the object store + the source of this script. The model gets its own
# `git worktree`, detached at origin/main, so a peer dispatch's pre-flight `stash push -u` +
# `reset --hard origin/main` (dispatch.sh's "Pre-flight 2") lands on a tree nobody is working in.
#
# Automatic by construction — no master opts in, and no brief mentions it. `git pull --ff-only` on the
# shared clone is GONE with it: the worktree is created FROM a freshly fetched origin/main, so the base
# is current by definition and there is no dirty-tree case for the pull to silently skip.
#
# TASK_NO_ISOLATE=1 restores the old shared-checkout behaviour — the escape hatch for reproducing the
# bug, which is how the concurrency test in the spec proves the fix does something.
if [ "${TASK_NO_ISOLATE:-0}" = 1 ]; then
  echo "WARNING: TASK_NO_ISOLATE=1 — running in the SHARED checkout; a concurrent dispatch to this master can destroy this run's work (#3432)" >&2
  cd "$CLONE"
  sync_shared_clone "$CLONE" || echo "WARNING: ${TASK_CLONE_SYNC_NOTE:-shared-clone sync failed} (#3961)" >&2
else
  WS="$(bash "$CLONE/_infra/scripts/run-workspace.sh" create "$CLONE" "$ISSUE" "$$" 2>/dev/null)"
  [ -n "$WS" ] && [ -d "$WS" ] || WS="$CLONE"          # fail open, never leave the runner with no cwd
  # PRE-FLIGHT (#3820): a directory is only a workspace if git WORKS in it. Two runs were handed trees
  # whose `.git` pointer named a clone path that did not exist; every git command inside them returned
  # `fatal: not a git repository`, so they could not commit or push anything — and the brief gives a
  # model no way to recognise that. Verify (and self-repair) BEFORE the model is told "work here": a run
  # that cannot commit should never start. Still FAIL OPEN — the shared clone is a working repo, so
  # dropping isolation beats refusing to dispatch.
  if ! bash "$CLONE/_infra/scripts/run-workspace.sh" verify "$CLONE" "$WS" 2>/dev/null; then
    echo "WARNING: per-run workspace $WS has no usable git (#3820) — falling back to the SHARED checkout" >&2
    WS="$CLONE"
  fi
  WORKDIR="$WS"
  cd "$WORKDIR"
  # A CROSS-REPO dispatch works a second clone the brief tells the model to `cd` into — the identical
  # collision, one repo over. Isolate that one too and hand the model the literal path (BRIEF step 3),
  # so "cd to that repo's local clone" can no longer mean "into the tree a peer run is mid-edit".
  _TGT_NAME="${REPO##*/}"
  if [ "$_TGT_NAME" != "$(basename "$CLONE")" ] && [ -d "$HOME/dev/example-org/$_TGT_NAME/.git" ]; then
    WS_TARGET_CLONE="$HOME/dev/example-org/$_TGT_NAME"
    WS_TARGET="$(bash "$CLONE/_infra/scripts/run-workspace.sh" create "$WS_TARGET_CLONE" "$ISSUE" "$$" 2>/dev/null)"
    # Same pre-flight as above — the brief hands this path to the model as "cd THERE for that repo", so
    # an unusable one strands the run in the same undiagnosable way, one repo over (#3820).
    if [ -n "$WS_TARGET" ] && [ -d "$WS_TARGET" ] \
       && bash "$CLONE/_infra/scripts/run-workspace.sh" verify "$WS_TARGET_CLONE" "$WS_TARGET" 2>/dev/null; then
      :
    else
      [ -n "$WS_TARGET" ] && echo "WARNING: target-repo workspace $WS_TARGET has no usable git (#3820) — the model will use the shared clone" >&2
      WS_TARGET=""; WS_TARGET_CLONE=""
    fi
  fi
  unset _TGT_NAME
fi
echo "workspace: $WORKDIR${WS_TARGET:+ · target-repo workspace: $WS_TARGET}" >&2

# KIND: a `type:research` issue is a DELEGATED-PLANNING dispatch (#2431) — the deliverable is a grounded
# FINDINGS ARTIFACT (a committed .md), not code. Same runtime, same PR/auto-merge path; only the brief
# differs. Detected from the issue's own label (the source of truth, visible on the board) so a research
# issue dispatched via plain dispatch.sh still gets the research brief.
KIND=code
if gh issue view "$ISSUE" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null | grep -qx 'type:research'; then
  KIND=research
fi

# ── THE GOVERNING SUBPROCESS (#6338, Feature #6336) ────────────────────────────────────────────────
# Subprocess definitions reached a PLANNING session as of plugin 0.43.0 (ADR-202) and a DISPATCHED RUN
# nowhere. `wi/subprocesses/interactive/meeting.md` — the DECIDED · PARKED · OPEN vocabulary, the
# repo-wide supersede pass, seven acceptance criteria — was invisible to the master dispatched to act on
# a meeting. The brief below named the repo CLAUDE.md, the portfolio CLAUDE.md, the issue and its spec
# (both CLAUDE.md pointers since removed — #7799: the root file imported the Architect's bundle).
# Never a subprocess.
#
# The channel is the issue BODY: `file-issue.sh --subprocess NAME` stamps ONE labelled line at the top,
# and this reads it back off GitHub. No board field, no label, no schema change (ADR-6336).
#
# 🔴 RESOLVED AGAINST THE REAL CATALOGUE, NEVER TRUSTED. The name off GitHub is only a name; the PATH
# handed to the model is a file this run confirmed exists in the shared clone THIS turn. A name that
# resolves to zero or several definitions injects NOTHING and says so on stderr — the Feature's NEGATIVE
# is that a wrong subprocess routed confidently is worse than none, because the run will follow it.
# There is no fallback, no placeholder and no inference from title, body text or portfolio: an issue
# with no such line gets the brief it got yesterday, byte for byte.
#
# The line's shape is the one issues were already hand-writing before the flag existed (#6336's own body
# carries it verbatim), so this picks those up too. Anchored at line start on purpose: an issue that
# DISCUSSES the mechanism mid-sentence — this Feature's own tasks do — must not route itself.
SUBPROC_NAME=""; SUBPROC_PATH=""; SUBPROC_ABS=""
_SP_BODY="$(gh issue view "$ISSUE" --repo "$REPO" --json body --jq '.body' 2>/dev/null | tr -d '\r' || true)"
_SP_N="$(printf '%s\n' "$_SP_BODY" | sed -n 's/^\(🔴 \)\{0,1\}\*\*Governed by the `\([a-z0-9-]\{1,\}\)` subprocess\*\*.*/\2/p' | head -1)"
if [ -n "$_SP_N" ]; then
  _SP_HITS=()
  for _sf in "$CLONE"/*/subprocesses/*/"$_SP_N".md; do [ -f "$_sf" ] && _SP_HITS+=("$_sf"); done
  unset _sf
  if [ "${#_SP_HITS[@]}" -eq 1 ]; then
    SUBPROC_NAME="$_SP_N"; SUBPROC_ABS="${_SP_HITS[0]}"; SUBPROC_PATH="${_SP_HITS[0]#"$CLONE"/}"
    echo "subprocess: #$ISSUE is governed by \`$SUBPROC_NAME\` → $SUBPROC_PATH" >&2
  else
    echo "subprocess: #$ISSUE names \`$_SP_N\` but it resolves to ${#_SP_HITS[@]} definitions under $CLONE/*/subprocesses/*/ — injecting NOTHING (#6338)" >&2
  fi
fi
_ISSUE_BODY="$_SP_BODY"   # kept for the standing block below (knowledge#9524) — one `gh issue view`, two readers
unset _SP_BODY _SP_N

# ── THE SHIP PATH (#8717, PLAN-366 P4) ─────────────────────────────────────────────────────────────
# A governing subprocess may name its own ship path in frontmatter (`ship: dev-draft`), and when it does
# that path WINS over BRIEF steps 3 and 5 — the default "branch off main, merge with --admin" is exactly
# what a PRODUCT UI run must NOT do (the operator's word promotes UI; the Architect fast-forwards main). Read off the
# definition this run already resolved, never off the issue body. Only KNOWN values route; an unknown one
# routes nothing and says so (a wrong ship path followed confidently is worse than the default).
#   dev-draft — build on a branch, push that commit to `dev`, verify there, end at a DRAFT PR. The draft
#               is the existing stop-for-review hatch: finish() posts ✔ on it and automerge() never merges.
SHIP_PATH=""
if [ -n "$SUBPROC_ABS" ]; then
  _SHIP="$(awk 'NR==1&&$0!="---"{exit} NR>1&&$0=="---"{exit} NR>1&&/^ship:/{sub(/^ship:[ \t]*/,"");gsub(/[" \t]/,"");print;exit}' "$SUBPROC_ABS")"
  case "$_SHIP" in
    "") ;;
    dev-draft) SHIP_PATH="$_SHIP"; echo "ship-path: \`$SUBPROC_NAME\` names \`ship: $SHIP_PATH\` — it replaces brief steps 3 and 5 (#8717)" >&2 ;;
    *) echo "ship-path: \`$SUBPROC_NAME\` names unknown \`ship: $_SHIP\` — ignoring it, default steps 3 and 5 apply (#8717)" >&2 ;;
  esac
  unset _SHIP
fi

# MERGE AS THE FLEET APP (#3061) — Vercel's COMMIT_AUTHOR_REQUIRED blocked the example.com prod
# deploy twice on 2026-07-27. Cause: with squash disabled a repo mints a NEW merge commit server-side,
# authored by WHOEVER CALLED THE API — unreachable by `git config user.email`. The REST merge endpoint
# takes no author parameter, so the CREDENTIAL is the only lever. Verified on the wire: PR #193 armed by
# example-fleet[bot] deployed READY; #194 armed by gh-account4 was BLOCKED. Exporting the App
# installation token makes every merge site below author as the App.
#
# 🔴 PLACEMENT IS LOAD-BEARING — this MUST stay here, AFTER the `notifications?participating=true` block
# at :249. That endpoint is USER-scoped; an installation token cannot read it, so exporting any earlier
# silently kills @mention delivery between masters. The ▶ comment (:60-61) and `gh issue view` (:270) also
# run earlier and are correct as the user. Sitting immediately before the BRIEF covers all three merge
# sites at once (both BRIEFs + automerge()) because they inherit this same shell.
#
# ⚠ Never `gh auth login --with-token` an App token — that validates via GET /user and 403s. Env-only.
# ⚠ Installation tokens last 1 hour and MAXT=200 runs can exceed that; the existing
#   "⚠ could not arm auto-merge" comment makes expiry loud rather than silent. Re-minting inside
#   automerge() is a follow-up, not this change.
_FLEET_TOK="$(bash "$HOME/.claude/scripts/gh-app-token.sh" 2>&1)"
if [ -z "$_FLEET_TOK" ]; then
  echo "ERROR: gh-app-token.sh produced no output - cannot merge securely" >&2
  RESULT="gh-app-token.sh failed (no output)"; exit 1
fi
if [ "${_FLEET_TOK:0:4}" != "ghs_" ]; then
  echo "ERROR: gh-app-token.sh produced invalid token (starts with '${_FLEET_TOK:0:4}', not 'ghs_'): $_FLEET_TOK" >&2
  RESULT="gh-app-token.sh failed (invalid token)"; exit 1
fi
export GH_TOKEN="$_FLEET_TOK" GITHUB_TOKEN="$_FLEET_TOK"
unset _FLEET_TOK

# BRIEF steps 3 and 5 — the default branch-and-merge path, or the governing subprocess's own (#8717).
if [ -n "$SHIP_PATH" ]; then
STEP3="3. Do the work on a branch. Your cwd is a PER-RUN WORKSPACE ($WORKDIR) — an isolated git worktree already detached at a fresh origin/main. Work THERE and never in $CLONE (#3432).$( [ -n "$WS_TARGET" ] && printf ' This dispatch targets %s — its per-run workspace is %s; cd THERE for that repo, never to another clone of it.' "$REPO" "$WS_TARGET" ) If the work targets a DIFFERENT repo and no workspace was named for it above, cd to that repo's local clone. 🔴 SHIP PATH — the governing subprocess \`$SUBPROC_NAME\` names \`ship: $SHIP_PATH\`, and that REPLACES the default branch-and-merge of this step and step 5 (#8717). Read its ship section (\"Ships through dev\") and follow it exactly: git fetch origin && git switch -c <branch> origin/main in the target repo, build there, push THAT exact commit to \`dev\` (git push --force-with-lease origin <sha>:dev, authored as operator), and verify on https://example.com in a real browser. Never open a PR whose head is \`dev\`. Tick the plan.md checkboxes [ ]->[x] as you complete tasks and commit them with your changes."
STEP5="5. Open a DRAFT PR (gh pr create --draft) from your branch whose body contains 'Closes #$ISSUE' and the dev evidence the subprocess asks for (the dev URL, the /api/version sha, the screenshots), then STOP. 🔴 Under \`ship: $SHIP_PATH\` the DRAFT PR IS the finished run: do NOT merge it, do NOT mark it ready, do NOT push to main — promotion is the operator's word and the Architect's fast-forward, as the subprocess says. The runner reports a draft as ✔ and never merges one; a non-draft PR from this run is converted back to draft, never merged. Do not run gh issue close either — the issue closes when main gets the commit."
else
STEP3="3. Do the work on a branch. Your cwd is a PER-RUN WORKSPACE ($WORKDIR) — an isolated git worktree already detached at a fresh origin/main. Work THERE and never in $CLONE: that shared clone is reset out from under you by any concurrent dispatch to this master (#3432).$( [ -n "$WS_TARGET" ] && printf ' This dispatch targets %s — its per-run workspace is %s; cd THERE for that repo, never to another clone of it.' "$REPO" "$WS_TARGET" ) If the work targets a DIFFERENT repo and no workspace was named for it above, cd to that repo's local clone. Either way FIRST run: git fetch origin && git checkout -B <branch> origin/main — NEVER branch from a stale local main (stale-base PRs arrive CONFLICTING; the 2363/app-repo#88 lesson). 🔴 origin/main CAN ITSELF BE THE STALE ONE: a force-push rewinds it silently and git shows you nothing — on 2026-08-04 brain-charlie's main went back 37 commits and two runs rebuilt on the rewound lineage doing exactly what this line says (#4279). If you are branching in ANY repo other than example-org/kb — a brain repo above all — run bash _infra/scripts/check-lineage-rewind.sh <owner/repo> FIRST; it reads the server-side activity log (the only witness a force-push cannot rewrite) and exits non-zero on an unhealed rewind. If it goes red, reconcile by MERGING before you branch, never by force-pushing the old tip back (that erases whatever landed on top). Tick the plan.md checkboxes [ ]->[x] as you complete tasks and commit them with your changes."
STEP5="5. Open a PR whose body contains 'Closes #$ISSUE', then MERGE IT: gh pr merge <num> --squash --admin. Your job ends at MERGED, not at 'auto-merge armed' — arming and exiting is how 15 PRs stacked up unnoticed. NOTHING gates main (branch protection and rulesets both 403 on this plan tier), so there is no green to wait for. If the merge fails, read the ACTUAL error and act on it: CONFLICTING/DIRTY -> git fetch origin && git rebase origin/main, resolve, then force-push YOUR OWN TOPIC BRANCH BY NAME (git push --force-with-lease origin HEAD:<your-branch>), merge (never open a second PR). 🔴 A force-push is ONLY ever aimed at the branch this run created. NEVER force-push main, and never a bare 'git push --force' — that takes whatever HEAD happens to be, and on 2026-08-11 the shared clone was sitting on main: 501 commits went off the branch in one command and nothing local showed it (#5214); a real build/typecheck/deploy failure -> fix the code (that failure is real); anything else -> retry with --admin. A merge is NEVER a the operator gate and never something to ask about — the operator, 2026-07-21: 'I am never responsible for merging PRs... a block = FIND THE PATH.' Verify state=MERGED before you finish; an open PR means the task is not done."
fi

BRIEF="You are a dispatched master agent. Work issue #$ISSUE of $REPO to completion.
1. Your doctrine is already in context: the harness loaded your class bundle from ~/.claude/rules/ and any CLAUDE.md the target repo carries. Do not go looking for another bundle — ground in the issue, its spec and the real files.
2. Read the issue (gh issue view $ISSUE --repo $REPO --comments) and, if it names one, its committed spec.md + plan.md under <portfolio>/specs/.$( [ -n "$SUBPROC_PATH" ] && printf ' 🔴 THIS ISSUE IS GOVERNED BY THE `%s` SUBPROCESS — read `%s` (absolute: %s) BEFORE you write anything. Its Required READS, Required WRITES and Acceptance are part of the contract of this issue, in addition to the acceptance in the issue body; a governed run that ignores its definition has not done the work.' "$SUBPROC_NAME" "$SUBPROC_PATH" "$SUBPROC_ABS" )
$STEP3
4. Verify against reality (build/run/curl/render whatever the acceptance names) before claiming done.
$STEP5
6. NEVER HALT. If something is ambiguous or a prerequisite is missing: research it with subagents, decide, record the decision, and keep working. 🔴 REQUIRED INPUTS ARE A PRECONDITION YOU CHECK FIRST, NOT SOMETHING YOU WAIT FOR: if your brief or spec tells you to read another task's output (a findings file, a committed artifact, a sibling's PR), test that it exists BEFORE you start, because sibling tasks are dispatched in parallel and yours may have started first. If it is absent, do all the work that does not depend on it, then say so VISIBLY — comment on this issue naming the exact missing path and the issue that produces it — and if that left nothing at all to ship, record it: printf '{\"blocked\":true,\"reason\":\"required input <path> (from #<issue>) does not exist yet — re-dispatch after it lands\"}' > $RUN_STATE. There is NO queue, NO dependency edge and NO background poller in this system: a run that stops to wait for a notification exits silently and nothing ever wakes it (#3653). Waiting is never the move; a visible ⛔ is.  If a residual step genuinely requires a human (a card the fleet does not hold, a physical device action), ESCALATE IT ON THIS ISSUE: comment on #$ISSUE naming the exact human-only action, then continue with everything else and ship every part that does not depend on it. 🔴 You do NOT file an issue for it — a master executes filed work and never files it (the Architect files), and lane agent is unreachable by every sweeper, so a master-filed issue sits Todo forever looking queued. You may still SIGNAL that you hit a human-only atom: if and only if it left you nothing at all to ship, record it so the board shows Blocked rather than Todo: printf '{\"blocked\":true,\"reason\":\"<the exact human-only action, as named in your comment on this issue>\"}' > $RUN_STATE. The signal never replaces the work — comment it, ship the rest, continue.
7. To message another master, @mention its GitHub account in a comment on the relevant issue.
8. Do NOT run \`gh issue close\` — the merge closes this issue (your PR body says 'Closes #$ISSUE'). Closing it yourself (especially on an unverified 'it works' claim) is the #2608 failure. Your job ends at: PR MERGED — not a manual close, and not an armed-but-open PR.
9. If you worked in a repo OTHER than $REPO, record it so the runner can verify your artifact (the runner cannot see a cross-repo PR otherwise): printf '{\"repo\":\"OWNER/NAME\",\"branch\":\"YOUR_BRANCH\"}' > $RUN_STATE — and if your work SPLIT across repos (the mechanism in one, the docs carrying \`Closes\` in $REPO), also name the other PR FULLY QUALIFIED in the closing PR's body: \`example-org/plugins#70\`, never a bare \`#70\` and never only a browser link. That reference is what lets the runner see the half your closing PR does not contain, instead of warning \`⚠ docs-only PR\` at correct work (#6927).
10. ROLLUP ATTESTATION — a parent Feature has no PR OF ITS OWN, so the master that finishes its last task is the ONLY one positioned to attest it. 🔴 PUT \`Closes\` ONLY ON THE SUB-ISSUE YOU WERE DISPATCHED ONTO, NEVER ON THE PARENT FEATURE: GitHub matches the keyword anywhere in your PR body and WILL close the parent, which removes every remaining child from dispatch forever (\`sweep-dispatch.sh\` predicate 3 rejects any sub-issue of a CLOSED Feature). Measured 2026-09-04: PR #7513 aimed the keyword at its parent Feature (#7500) alongside its two real sub-issue lines, closing the Feature and stranding its open VERIFY child #7504 — two auto-filed reports and a dispatched run to undo one line. (Illustrations here never put the keyword next to a live number, because a body quoting this brief would fire it.) So: if you exercised the artifact and every Feature-level acceptance criterion on the PARENT of this issue is genuinely met, write one row per criterion to a SEPARATE state file (NOT $RUN_STATE — that one carries repo/branch/blocked): {\"rollup\":[{\"criterion\":\"<the parent's criterion, verbatim>\",\"evidence\":\"<the command, URL, or output you actually ran that proves it>\"}, ...]} > $ROLLUP_STATE (jq -n or a heredoc). You do NOT need to work out whether you are the last sub-issue — the runner posts \`✔ ROLLUP VERIFIED\` + your table on the parent only when GitHub reports the Feature at n/n, and it never closes the parent. 🔴 If you cannot honestly attest even one criterion, write NOTHING: an unattested n/n Feature gets loudly surfaced by the sweep, which is correct — a rubber-stamped attestation is worse than no mechanism at all.
11. IF THIS ISSUE IS A **VERIFY** TASK (its title starts with \`VERIFY\`), RECORD YOUR VERDICT AS ONE LINE OF JSON — your report's prose is for humans and nothing in this fleet reads English. Write it to a state file of its own (NOT $RUN_STATE, NOT $ROLLUP_STATE): jq -n '{verdict:\"PASS\"}' > $VERIFY_STATE — or, if ANY acceptance criterion of the parent Feature is not met, jq -n '{verdict:\"FAIL\",failing:[{criterion:\"<verbatim from the Feature>\",evidence:\"<the command you ran and exactly what it printed>\",recheck:\"<a command that exits 0 once this criterion is TRUE>\"}]}' > $VERIFY_STATE (one object per failing criterion; a row missing \`criterion\` or \`evidence\` voids the whole verdict). 🔴 ADD \`recheck\` TO EVERY FAILING ROW (#6587): one shell command whose EXIT STATUS is the criterion (\`0\` = true now). It is re-run immediately before the blocker is filed, and if it comes back true NO blocker is filed and the measurement is recorded instead — three of the four stale BLOCKERs measured on 2026-08-22 asserted criteria that had since BECOME TRUE with nothing re-grading them. \`evidence\` is prose and is never executed; \`recheck\` is the only thing that is. On FAIL the runner files ONE BLOCKER SUB-ISSUE per criterion under the parent Feature, which is what keeps that Feature off n/n — without it the parent auto-closes as complete over your own report, which is exactly what happened to #4749 seven minutes after its verifier said a criterion was failing (#4800). A FAIL verdict is a NORMAL, CORRECT outcome of a verification; it costs nothing and blocks nobody's merge. Writing nothing is the only wrong answer.
🔴 **A \`recheck\` must directly measure THIS criterion, not a proxy (#6632).** Two forbidden patterns:
  - **Byte-identical rechecks across multiple criteria** — the tell that you measured a prerequisite, not each criterion itself. \`verify-verdict.sh\` REFUSES this and says so on the issue.
  - **Text-search oracles satisfiable by your own PR** — \`gh pr list --search <number>\` and \`gh issue list --search\` search PR/issue bodies, which your report PR itself will match. This measures whether you filed a report, not whether the criterion is true. Use direct checks (\`git show origin/main:<path>\`, \`gh issue view <n> --json state\`, \`gh pr view <n> --json mergedAt\`) instead.
🔴 **The \`evidence\` field MUST quote the EXACT command you ran and its RAW output, not a prose summary.** A verdict that says \"grep shows 6 entries\" without quoting the actual \`grep\` command and its output is NOT a verdict — it is an unreproducible claim. On 2026-08-11 VERIFY #5116 filed 6 blockers claiming \`LIFECYCLE\` had 6 entries including \`COMMIT\`, but that grep result did not exist on the box it ran on. Every \`evidence\` value must be formatted as:
\`\`\`
<command you ran, verbatim>
<exact raw output from that command>
\`\`\`
If you do not run a command (e.g. you render a page and observe it visually), quote the URL and describe what you observed, but never report a grep/curl/git result without the command+output pair.
🔴 **A FAIL that reopens a CLOSED issue requires an even higher bar.** If the parent Feature was already CLOSED and MERGED (meaning it was previously verified and passed), and your FAIL verdict would REOPEN that correct work, your evidence MUST be quote-exact: the full command line and its complete raw output. A prose summary like \"grep shows X\" is NEVER sufficient for reopening merged work — it reopens correct work and creates noise on the board. The blocker you file is what keeps that Feature off n/n, and a false FAIL on merged work is the worst possible outcome. Before filing such a blocker, ask yourself: \"If another master ran this exact command, would they get the same result?\" If the answer is \"I don't know\" or \"maybe\", DO NOT FILE the blocker — investigate first.
Never write a secret into a tracked file. Never force-push.
$( [ -n "$MAIL" ] && printf 'UNREAD MENTIONS addressed to you (from other masters/the operator — act on them if they affect this task, reply on their issues):%s\n' "$MAIL" )"

# RESEARCH brief (#2431): a type:research dispatch delivers a grounded FINDINGS ARTIFACT, not code. Same PR
# path (the artifact is committed via a Closes-PR, so finish()/automerge() reuse verbatim). Grounding +
# uncertainty are enforced by THIS BRIEF, not a content-gate on the runner — per the fleet's own doctrine
# (operating-system.md: "a gate that blocks on content keywords is forbidden"; understanding over gates).
if [ "$KIND" = research ]; then
BRIEF="You are a dispatched master agent running a DELEGATED RESEARCH job — issue #$ISSUE of $REPO. Your deliverable is a GROUNDED FINDINGS ARTIFACT (a committed .md), NOT code. The Architect will REVIEW your artifact and write the plan; it did not run this fan-out, so your grounding + uncertainty flags are what it relies on.
1. Your doctrine is already in context (your class bundle, from ~/.claude/rules/). Read the issue: gh issue view $ISSUE --repo $REPO. Note its QUESTION, AXES, GROUNDED definition, and OUTPUT PATH.
2. FAN OUT one subagent per AXIS, IN PARALLEL (one message, multiple Agent tool calls). RIGHT-SIZE each: search/enumerate/grep/read-and-report axes → model haiku, effort low; standard research → sonnet; synthesis/judge/architecture axes → the default tier, high effort. A 6-axis sweep is NOT 6× the top tier.
3. GROUND EVERY FINDING. Each claim in the artifact cites a file:line, a command + its output, or a live probe — never recall or a plausible guess. Brief each subagent to 'cite the real source, do NOT speculate; if you cannot verify it, say so.' A finding that INVERTS an assumption is the most valuable kind — surface it.
4. NEVER SWALLOW A FAILED SUBAGENT. If an axis returns nothing or errors, the artifact SAYS 'axis N returned nothing' — never an empty synthesis reported as success.
5. CONTRADICTION IS SIGNAL. If two axes (or your findings vs. the issue's assumption) disagree, surface it as an explicit CONTRADICTION block naming both claims + sources — never average or silently pick one.
6. Write the artifact to the OUTPUT PATH named in the issue. Structure: Question · one finding-block per axis (claim + citations) · CONTRADICTIONS · an explicit UNCERTAINTY / CONFIDENCE section (what is unverified + what the Architect should re-check). Carry subagent CONCLUSIONS into the artifact, not their full transcripts.
7. Commit the artifact on a branch. Open a PR whose body contains 'Closes #$ISSUE', then arm auto-merge: gh pr merge <num> --squash --auto. Comment on the issue a SHORT summary (3–5 lines) + the artifact path — do NOT paste the whole artifact.
8. NEVER HALT. An ambiguous question or a missing prerequisite is research: fan out on it, decide, record the decision in the artifact's UNCERTAINTY section, and keep working. 🔴 If your brief tells you to read another task's output and that file is ABSENT, you were dispatched before your input existed — deliver the artifact for every axis that does not depend on it, name the exact missing path in the artifact AND in a comment on this issue, and declare it blocked if that left nothing to ship. There is no poller: a run that stops to wait exits silently and nothing wakes it (#3653). If a residual step genuinely requires a human (a card the fleet does not hold, a physical device action), ESCALATE IT ON THIS ISSUE: comment on #$ISSUE naming the exact human-only action, then continue and ship the artifact for every axis that does not depend on it. 🔴 You do NOT file an issue for it — a master executes filed work and never files it (the Architect files). You may still SIGNAL a human-only atom: if and only if it left you nothing at all to ship, record it so the board shows Blocked rather than Todo: printf '{\"blocked\":true,\"reason\":\"<the exact human-only action, as named in your comment on this issue>\"}' > $RUN_STATE. To message another master, @mention its GitHub account in a comment on the issue.
9. Do NOT run \`gh issue close\` — the runner closes this issue automatically when your PR merges (closing it yourself on an unverified claim is the #2608 failure). If you worked in a repo OTHER than $REPO, record it: printf '{\"repo\":\"OWNER/NAME\",\"branch\":\"YOUR_BRANCH\"}' > $RUN_STATE
Never write a secret into a tracked file. Never force-push.
$( [ -n "$MAIL" ] && printf 'UNREAD MENTIONS addressed to you (act on them if they affect this task, reply on their issues):%s\n' "$MAIL" )"
fi

# ── THE STANDING BLOCK (knowledge#9524, PLAN-404 P3, Feature knowledge#9519) ─────────────────────────
# A master is dispatched with no session to bind, so neither the per-turn `[standing:<portfolio>]` line nor
# the SubagentStart hook reaches it — and the measured failure was a run asking the operator for a number the KB
# held. `file-issue.sh` stamps `**Portfolio:** <slug>` into every body it files; this reads that line and
# puts the portfolio's standing block at the TOP of the brief. The block is built by the fleet-doctrine
# plugin's `standing-line.sh` — the ONE builder the turn and the subagent hook already use, resolved from
# the PINNED install (`installed_plugins.json`), never a hardcoded version — reading `<dir>/STANDING.yaml`
# in this run's own workspace (a fresh origin/main), so the brief carries what main says now.
# FAIL OPEN: no Portfolio line · an unknown value · no plugin · no file · an unresolvable ref → the brief
# is byte-identical to before, and stderr (the run log) says which.
STANDING_LINE=""
_PF_RAW="$(printf '%s\n' "$_ISSUE_BODY" | sed -n 's/^\*\*Portfolio:\*\*[[:space:]]*//p' | head -1 | tr -d "\"'\`" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]*$//')"
case "$_PF_RAW" in
  "") _PF="" ;;
  wi|alpha|"world infrastructure"|raw) _PF="wi" ;;   # RAW folded into wi (#8996)
  product|"product research"|portfolio-a) _PF="product" ;;
  net|sf) _PF="net" ;;
  govcon|talent|cleaning) _PF="$_PF_RAW" ;;
  *) _PF=""; echo "standing: #$ISSUE names Portfolio '$_PF_RAW', which maps to no portfolio — brief unchanged (#9524)" >&2 ;;
esac
if [ -n "$_PF" ]; then
  _SL=""
  _IP="$HOME/.claude/plugins/installed_plugins.json"
  if [ -r "$_IP" ]; then
    _SLP="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["plugins"]["fleet-doctrine@fleet-doctrine"][0].get("installPath",""))' "$_IP" 2>/dev/null || true)"
    [ -n "$_SLP" ] && [ -r "$_SLP/scripts/standing-line.sh" ] && _SL="$_SLP/scripts/standing-line.sh"
  fi
  [ -z "$_SL" ] && [ -r "$HOME/.claude/plugins/marketplaces/fleet-doctrine/plugins/fleet-doctrine/scripts/standing-line.sh" ] \
    && _SL="$HOME/.claude/plugins/marketplaces/fleet-doctrine/plugins/fleet-doctrine/scripts/standing-line.sh"
  _SKB="$CLONE"; [ -r "$WORKDIR/wi/registry/organization.yaml" ] && _SKB="$WORKDIR"
  if [ -z "$_SL" ]; then
    echo "standing: #$ISSUE is Portfolio $_PF but no fleet-doctrine standing-line.sh is installed on this box — brief unchanged (#9524)" >&2
  else
    STANDING_LINE="$(STANDING_KB="$_SKB" bash "$_SL" "$_PF" || true)"
    if [ -n "$STANDING_LINE" ]; then
      BRIEF="$STANDING_LINE

$BRIEF"
      echo "standing: #$ISSUE Portfolio $_PF — prepended to the brief (${#STANDING_LINE} chars) from $_SKB:" >&2
      printf '%s\n' "$STANDING_LINE" >&2
    else
      echo "standing: #$ISSUE Portfolio $_PF — standing-line.sh printed nothing (no STANDING.yaml in $_SKB, or a ref failed; see above) — brief unchanged (#9524)" >&2
    fi
  fi
  unset _SL _SLP _IP _SKB
fi
unset _PF _PF_RAW _ISSUE_BODY

# --- THE DISPATCHED RUN -- classify-and-retry (#3417) ----------------------------------------------
# This used to be ONE unguarded call, and it is where the entire fleet's work happens. On 2026-07-30 a
# status.claude.com Minor Service Outage killed three dispatched runs with `API Error: 529 Overloaded` on
# their FIRST request -- zero turns consumed, no work attempted -- and each landed in board Status=Todo,
# which nothing in this fleet reads. The tasks were lost until the operator asked why work had stopped.
#
# This is not new machinery: the fleet has fixed this exact class three times already (dispatch.sh:278,
# file-issue.sh:156, stuck-pr-sweep.yml). This is the last call site that never got it.
#
# 🔴 Retry ONLY on the CONJUNCTION of four facts, three of which the model does not author:
#   1. the failure signature is transient (429/5xx/529/Overloaded/network), AND
#   2. it is not a hard provider quota limit (a capacity event, not a blip), AND
#   3. the run NEVER STARTED -- no result envelope, zero turns, AND
#   4. GitHub reports NO artifact for this issue (a run that 529'd AFTER opening a PR is a ✔ -- #2918).
# A run that consumed turns and failed is a genuine DEFECT and must fail on the FIRST attempt: three
# identical failures bury a cause instead of surfacing it. Max 3 attempts, hard cap -- an unbounded retry
# during an outage is a burn-loop.
while :; do
  ATTEMPT=$((ATTEMPT+1))
  _t0=$(date +%s)
  OUT=$(claude -p "$BRIEF" --output-format json --max-turns "$MAXT" 2>&1); rc=$?
  _dur=$(( $(date +%s) - _t0 ))
  parse_run_output
  if [ "$rc" -eq 0 ]; then
    [ "$ATTEMPT" -gt 1 ] && ATTEMPT_LOG="${ATTEMPT_LOG}
- attempt ${ATTEMPT}/${MAX_ATTEMPTS} **succeeded** after ${_dur}s"
    break
  fi

  # Why we would NOT retry. Evaluated so the strongest claim is made first — and a provider limit outranks
  # "the run started" (#3811): the same no-retry outcome, but a truthful reason. All 20 of the 2026-08-02
  # 22:59 session-limit deaths posted "the run STARTED (N turns) -- a real failure is never retried", which
  # reads as a defect in the work when the truth is that the master went dark mid-run and the issue is owed
  # a re-dispatch after the reset, not a rewrite.
  _why=""
  if is_quota_exhausted; then
    _why="a hard provider quota limit, not a transient blip -- the master is dark until reset; the 🪫 capture owns this"
  elif run_started; then
    _why="the run STARTED (${RUN_TURNS} turns${RUN_SUBTYPE:+, $RUN_SUBTYPE}) -- a real failure is never retried"
  elif ! is_transient; then
    _why="the failure is not classified transient"
  elif [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
    _why="attempt cap reached (${MAX_ATTEMPTS}) -- transient: \`$(transient_cause)\`"
  else
    discover_artifact
    [ "$ART_KIND" != none ] && _why="an artifact already exists (${ART_KIND}) -- work that shipped is never re-run"
  fi

  if [ -n "$_why" ]; then
    ATTEMPT_LOG="${ATTEMPT_LOG}
- attempt ${ATTEMPT}/${MAX_ATTEMPTS} failed after ${_dur}s (exit=$rc) -- **not retried**: ${_why}"
    break
  fi

  _sleep=$(printf '%s' "$BACKOFFS" | awk -v i="$ATTEMPT" '{print $i}')
  [ -z "$_sleep" ] && _sleep=480
  ATTEMPT_LOG="${ATTEMPT_LOG}
- attempt ${ATTEMPT}/${MAX_ATTEMPTS} failed after ${_dur}s (exit=$rc) -- transient, zero turns consumed: \`$(transient_cause)\` -> retrying in ${_sleep}s"
  echo "task-runner: attempt $ATTEMPT/$MAX_ATTEMPTS hit a transient failure -- retrying in ${_sleep}s" >&2
  sleep "$_sleep"
done
# Every attempt is VISIBLE on the issue. A run that silently retried three times would be a new kind of
# lie -- the exact opposite of what this Feature is for.
[ -n "$ATTEMPT_LOG" ] && RETRY_NOTE="**attempts: ${ATTEMPT}/${MAX_ATTEMPTS}** (classify-and-retry, #3417)${ATTEMPT_LOG}"

# SELF-MERGE BACKSTOP (the operator 2026-07-24: masters merge their own PRs; the Architect is not a bottleneck).
# The model is briefed to merge, but a run often ends before its PR's checks finish — so the runner
# deterministically finishes the job: find the run's Closes-PR, wait for green (<=10 min), squash-merge.
# DRAFT PRs are skipped (the irreversible-class stop-for-review escape hatch).
automerge() {
  # MERGE the run's Closes-PR. Not "arm and hope" — #3489: arming SUCCEEDS on a clean PR, so the old code
  # posted a cheerful "armed" note and the run reported ✔ while the PR sat open forever. The success path and
  # the stuck path were indistinguishable in the log, which is how 15 PRs accumulated unnoticed across three
  # repos. Nothing on this plan tier can require a check (branch protection + rulesets 403), so waiting on
  # green is waiting on nothing.
  # Repo-agnostic (#2613): discover_artifact finds the PR in its ACTUAL repo — no cwd-branch dead code.
  discover_artifact

  # #3905 Part A — self-PR-open backstop. A run that pushed commits but died before `gh pr create`
  # leaves ART_KIND=commits; open the PR now, then fall through to merge. The SIGKILL recovery case
  # (a run that never reaches automerge() at all) is handled by the stuck-pr-sweep.yml reaper (Part B).
  if [ "$ART_KIND" = commits ]; then
    local br owner repo pr_url
    br=$(git -C "$WORKDIR" branch --show-current 2>/dev/null || echo "")
    if [ -z "$br" ] || [ "$br" = main ]; then
      echo "automerge: ART_KIND=commits but no usable branch found — skipping PR-open backstop" >&2
      return 0
    fi
    owner="${REPO%%/*}"; repo="${REPO##*/}"
    # Try to create the PR. Failure here is OK — the reaper will retry it.
    if pr_url=$(gh pr create --repo "$REPO" --base main --head "$br" --title "Fix #$ISSUE" --body "Closes #$ISSUE" ${SHIP_PATH:+--draft} 2>/dev/null); then
      echo "automerge: opened PR for stranded branch $br — $pr_url" >&2
      # Re-discover so the merge ladder sees the PR
      discover_artifact
    else
      echo "automerge: failed to open PR for branch $br — reaper will retry" >&2
      return 0
    fi
  fi

  [ "$ART_KIND" = pr_open ] || return 0     # merged/nothing to do; commits that failed PR-open also exit here
  [ "$ART_DRAFT" = 1 ] && return 0          # draft = the stop-for-review hatch; never auto-merge
  # #8717 — a run governed by a ship path (`ship: dev-draft`) ends at a DRAFT PR and is promoted by
  # the operator's word, never here. A non-draft PR from such a run is turned back into a draft, so the
  # stop-for-review hatch (finish() ✔ on ART_DRAFT=1) applies instead of a merge.
  if [ -n "$SHIP_PATH" ]; then
    if gh pr ready "$ART_PR_NUM" --repo "$ART_PR_REPO" --undo >/dev/null 2>&1; then
      ART_DRAFT=1
      gh issue comment "$ISSUE" --repo "$REPO" --body "↩ PR #$ART_PR_NUM (${ART_PR_REPO}) converted back to DRAFT — \`$SUBPROC_NAME\` ships by \`ship: $SHIP_PATH\`, so the runner never merges it (#8717)." >/dev/null 2>&1
    else
      echo "automerge: ship path $SHIP_PATH — could not convert PR #$ART_PR_NUM to draft; NOT merging it" >&2
    fi
    return 0
  fi

  local pr="$ART_PR_NUM" repo="$ART_PR_REPO" err=""
  # Escalating attempts. stderr is CAPTURED, never discarded — the old `2>/dev/null` threw away the real
  # reason at the moment it was learned, then guessed "conflict or perms" in the comment.
  #   1. --auto  : let the platform merge on green if checks are actually running
  #   2. plain   : merge now (the common case — no enforceable check to wait for)
  #   3. --admin : the operator authorized this explicitly 2026-07-21 ("a block = FIND THE PATH... never hand it
  #                back to the operator"), with PR #2168 as the worked proof. A merge is git-reversible.
  for flag in "--auto" "" "--admin"; do
    # shellcheck disable=SC2086
    if err=$(gh pr merge "$pr" --repo "$repo" --squash $flag 2>&1); then
      # --auto may only ARM. Confirm the PR is actually MERGED before claiming anything.
      sleep 3
      if [ "$(gh pr view "$pr" --repo "$repo" --json state -q .state 2>/dev/null)" = "MERGED" ]; then
        gh issue comment "$ISSUE" --repo "$REPO" --body "✅ PR #$pr (${repo}) MERGED${flag:+ (\`$flag\`)}" >/dev/null 2>&1
        return 0
      fi
    fi
  done

  # Still open. Report the REAL error and mark the run incomplete — an open PR is unfinished work, and the
  # close-out must not read as success. "needs eyes" is deleted: it manufactured the the operator-deferral he banned.
  local state; state=$(gh pr view "$pr" --repo "$repo" --json mergeStateStatus -q .mergeStateStatus 2>/dev/null)
  local hint=""
  case "$state" in
    DIRTY|CONFLICTING) hint=" — **merge conflict**: rebase onto current main, then merge. Do NOT open a second PR." ;;
    BLOCKED)           hint=" — reported BLOCKED, but no check is enforceable here; retry \`gh pr merge $pr --repo $repo --squash --admin\`." ;;
  esac
  AUTOMERGE_FAILED=1
  gh issue comment "$ISSUE" --repo "$REPO" --body "$(printf '⚠ PR #%s (%s) is STILL OPEN — this issue is NOT done.\n\nmergeStateStatus: `%s`%s\n\nLast error:\n```\n%s\n```' "$pr" "$repo" "${state:-unknown}" "$hint" "${err:-（no output）}")" >/dev/null 2>&1
  return 1
}

# QUOTA-EXHAUSTION CAPTURE (#2489) — a run can die not from a code failure but because THIS master's provider
# reported a hard weekly/monthly limit (HTTP 429, e.g. Claude `[1310][Weekly/Monthly Limit Exhausted. Your limit
# will reset at 2026-07-29 11:04:49]`). That fact — the master CANNOT ACCEPT WORK until the reset — was being
# discarded into a systemd log nobody reads, so the OCC rendered a quota-dark master as an ordinary idle one.
# We persist it to a NON-git state file (~/.claude/state/quota-status.json) that occ-usage-publish.sh collects
# onto the usage feed (the same durable path the OCC already reads), and announce the capacity event on the board.
# PROVIDER-AGNOSTIC: we read the REAL error text + the REAL reset time — never a hardcoded per-provider limit.
QUOTA_STATE="$HOME/.claude/state/quota-status.json"
capture_quota() {
  mkdir -p "$(dirname "$QUOTA_STATE")" 2>/dev/null || true
  # Detect a hard rate/quota-limit signature in the run output — is_quota_exhausted() is the ONE definition
  # (see its comment at the top for why the 5-hour session limit is in it now, #3811).
  #
  # AND the run must have died: `$rc` here is the claude CLI's RAW exit code, before #3807's
  # `RUN_SUBTYPE=success → rc=0` normalisation further down. A provider limit always kills the run (all 20
  # of the 2026-08-02 22:59 captures exited 1), so requiring rc!=0 costs nothing and keeps the widened
  # natural-language signature from firing on a run that merely *discusses* session limits in its output —
  # this very fix's own run being the obvious example. A run that ended cleanly is never quota-dark.
  if [ "$rc" -ne 0 ] && is_quota_exhausted; then
    # The raw error line (trimmed) — the honest evidence, never a paraphrase.
    local raw reset_raw reset_iso reason clock
    raw=$(printf '%s' "$OUT" | grep -iE "$QUOTA_KIND_RE" | head -1 | tr -d '\r' | cut -c1-400)
    # The reset time as stated in the error (e.g. "2026-07-29 11:04:49"). Absent for some providers → honest-unknown.
    reset_raw=$(printf '%s' "$OUT" | grep -oiE 'reset(s)?( at| will be at)? [0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}(:[0-9]{2})?' | head -1 \
                | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}(:[0-9]{2})?' | head -1)
    # Best-effort ISO (the provider states the reset in UTC). null when the error gave no reset → the honest-unknown
    # path: we NEVER fabricate a reset time; the OCC renders "reset time unknown" rather than a made-up one.
    reset_iso=""
    if [ -n "$reset_raw" ]; then
      reset_iso=$(date -u -d "${reset_raw} UTC" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
    else
      # The subscription wording gives a BARE CLOCK TIME and no date — "resets 2:30am (UTC)". Resolve it
      # against today in UTC, and roll forward one day when that instant has already passed: at 23:00Z
      # "resets 2:30am" means TOMORROW's 02:30, and a reset stamped in the PAST is worse than unknown —
      # the OCC would render the master as already recovered while it is still dark.
      clock=$(printf '%s' "$OUT" | grep -oiE 'reset(s)?( at)? [0-9]{1,2}(:[0-9]{2})? ?(am|pm)' | head -1 \
              | grep -oiE '[0-9]{1,2}(:[0-9]{2})? ?(am|pm)' | head -1)
      if [ -n "$clock" ]; then
        reset_raw="$clock (UTC)"
        reset_iso=$(date -u -d "$(date -u +%Y-%m-%d) ${clock} UTC" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
        if [ -n "$reset_iso" ] \
           && [ "$(date -u -d "$reset_iso" +%s 2>/dev/null || echo 0)" -le "$(date -u +%s)" ]; then
          reset_iso=$(date -u -d "$(date -u -d tomorrow +%Y-%m-%d) ${clock} UTC" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
        fi
      fi
    fi
    # The session-limit notice states a CLOCK TIME and no date — "resets 2:30am (UTC)". Resolve it to the NEXT
    # occurrence of that clock time, in UTC, and ONLY when the provider itself wrote the UTC qualifier: the
    # date is arithmetic on the provider's own words, not an invented reset. An unqualified "resets 3pm" has
    # no knowable zone, so it stays raw-only and `resetsAt` stays null — the honest-unknown path above.
    if [ -z "$reset_iso" ]; then
      local clock_raw
      clock_raw=$(printf '%s' "$OUT" | grep -oiE 'resets?( at)? [0-9]{1,2}(:[0-9]{2})? ?(am|pm)? ?\(?UTC\)?' | head -1 | tr -d '\r')
      [ -n "$clock_raw" ] && reset_raw="$clock_raw"     # never overwrite good evidence with an empty match
      case "$clock_raw" in
        *[Uu][Tt][Cc]*)
          clock=$(printf '%s' "$clock_raw" | grep -oiE '[0-9]{1,2}(:[0-9]{2})? ?(am|pm)?' | head -1 | tr -d ' ')
          reset_iso=$(date -u -d "today ${clock} UTC" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
          # already past today → the next occurrence is tomorrow (ISO-8601 Z strings sort lexicographically)
          if [ -n "$reset_iso" ] && [ "$reset_iso" \< "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]; then
            reset_iso=$(date -u -d "tomorrow ${clock} UTC" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
          fi ;;
        *) reset_iso="" ;;
      esac
    fi
    reason=$(printf '%s' "$OUT" | grep -oiE '(weekly/monthly |session |usage )?limit (exhausted|reached)|quota exhausted|session limit|usage limit' | head -1)
    [ -z "$reason" ] && reason="provider limit reached"
    AGENT_KEY="${FLEET_AGENT:-$(whoami)}"
    PROV="${TASK_BACKEND:-claude}"
    jq -n --arg agent "$AGENT_KEY" --arg provider "$PROV" \
          --arg resetsAt "$reset_iso" --arg resetsAtRaw "$reset_raw" \
          --arg reason "$reason" --arg raw "$raw" --arg detectedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{agent:$agent, provider:$provider, exhausted:true,
        resetsAt:(if $resetsAt=="" then null else $resetsAt end),
        resetsAtRaw:(if $resetsAtRaw=="" then null else $resetsAtRaw end),
        reason:$reason, source:"429-capture", detectedAt:$detectedAt, raw:$raw}' \
      > "$QUOTA_STATE.tmp" 2>/dev/null && mv "$QUOTA_STATE.tmp" "$QUOTA_STATE"
    # Announce the fleet-capacity event on the board (idempotent per agent+reset-window): a master going
    # quota-dark for days is a capacity event the operator should see where he watches, not buried in a log.
    local until_txt; until_txt="${reset_iso:-unknown (provider gave no reset time)}"
    gh issue comment "$ISSUE" --repo "$REPO" \
      --body "🪫 quota-exhausted — \`$AGENT_KEY\` ($PROV) hit a hard limit and cannot accept work until **${until_txt}**. Captured to the usage feed; the OCC will render this master as EXHAUSTED (distinct from idle). Ref #2489." >/dev/null 2>&1 || true
    echo "QUOTA-EXHAUSTED: $AGENT_KEY until ${until_txt}" >&2
  elif [ "$rc" -ne 0 ] && is_entitlement_blocked; then
    # #2807 — an ENTITLEMENT revocation, written to the SAME state file so the #3906 pre-flight refuses
    # the next dispatch onto this master. Deliberately NOT a second mechanism: quota_dark_for() already
    # treats `exhausted:true` with `resetsAt:null` as dark-with-unknown-reset, which is exactly true here
    # — a switched-off subscription has no reset time because it is not a clock event. `source` is what
    # distinguishes the two for anything that cares (the pre-flight reads it; the OCC ignores it).
    #
    # It self-heals the same way and only the same way: the master's next CLEAN run deletes the file. For
    # a quota that means the reset landed; for this it means the box was rotated onto a working login and
    # actually completed a run. Nothing here waits for a clock, because nothing about this clears on one.
    local eraw eagent
    eraw=$(printf '%s' "$OUT" | grep -iE "$ENTITLEMENT_RE" | head -1 | tr -d '\r' | cut -c1-400)
    eagent="${FLEET_AGENT:-$(whoami)}"
    jq -n --arg agent "$eagent" --arg provider "${TASK_BACKEND:-claude}" \
          --arg raw "$eraw" --arg detectedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{agent:$agent, provider:$provider, exhausted:true, resetsAt:null, resetsAtRaw:null,
        reason:"subscription access disabled for this login", source:"entitlement-capture",
        detectedAt:$detectedAt, raw:$raw}' \
      > "$QUOTA_STATE.tmp" 2>/dev/null && mv "$QUOTA_STATE.tmp" "$QUOTA_STATE"
    gh issue comment "$ISSUE" --repo "$REPO" \
      --body "🔒 subscription-access disabled — \`$eagent\` is signed into \`${ACCOUNT:-unknown}\`, and that login's Claude Code subscription access is switched off. This is NOT a rate limit: **it does not clear on a reset**, so re-dispatching now fails again in seconds. Rotate the box onto a working login (\`~/.claude.json\` → \`oauthAccount\`); its next clean run clears this automatically. Captured to the same pre-flight state the quota check reads, so the next dispatch is refused rather than burned. Evidence: \`${eraw}\`. Ref #2807." >/dev/null 2>&1 || true
    echo "ENTITLEMENT-BLOCKED: $eagent (${ACCOUNT:-unknown}) — subscription access disabled; needs a login rotation" >&2
  elif [ "$rc" -eq 0 ] && ! is_quota_exhausted && ! is_entitlement_blocked && [ -f "$QUOTA_STATE" ]; then
    # A clean, successful run proves the limit has lifted → clear a stale exhaustion marker (self-healing on reset).
    # "Clean" now means the output ALSO carries no limit signature: rc=0 alone would let a run that ended on a
    # trailing session-limit notice (#3807 saw exactly that shape) delete a marker that is still true.
    rm -f "$QUOTA_STATE" 2>/dev/null || true
  fi
}
capture_quota

# SESSION and RESULT were extracted here by two whole-capture `json.load` one-liners that failed silently
# on any stderr noise (#3417); parse_run_output() now owns both, per attempt, noise-tolerantly.
# rc=0 is NO LONGER sufficient for ✔ (#2613): the terminal is derived from the real artifact in finish().
# STATE is kept only for legacy bookkeeping. automerge() is the backstop that arms an open non-draft PR the
# model opened — a no-op when there is none (a refused/no-artifact run arms nothing and finish() posts ⚠).
[ $rc -eq 0 ] && STATE=done
automerge

# THE UNIT'S OWN EXIT STATUS DRIVES systemd's OnFailure= -> fleet-notify.sh, so a nonzero exit here files a
# `unit failed:` board issue. Two fixes for that landed within two minutes of each other on 2026-08-02,
# from two masters triaging two siblings of the same 23-issue storm (#3807 and #3812). ONE of them is kept.
#
# KEPT — #3812: finish() sets FINISH_EXIT=0 when $mark is the ARTIFACT-derived "✔ finished", and
# run_exit_trap() honours it. The exit code agrees with the comment the same run just posted.
#
# DELETED HERE (#3817) — #3807's `[ "$RUN_SUBTYPE" = success ] && rc=0`. The envelope's subtype is NOT the
# artifact: it says the conversation ended normally, not that anything shipped. In this very storm, all 15
# no-artifact deaths ALSO carried subtype=success — read it off their own close-outs, e.g. #3838
# "the run STARTED (1 turns, success)" and #3073 "(7 turns, success)", both stamped
# `✘ failed (exit=1) — and produced no artifact`. So that line zeroed the exit code for genuine failures:
# no OnFailure alarm at all, and — because finish() also branches on $rc — a ✘ downgraded to
# "⚠ no artifact — run exited cleanly", with the `**error class:**` block silently dropped. It removed the
# alarm this mechanism exists for while fixing a case #3812 already covers exactly. Two overrides for one
# decision is one too many; the artifact is the one that cannot lie (#2613).
exit $rc
