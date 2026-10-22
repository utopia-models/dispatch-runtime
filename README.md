# dispatch-runtime

The dispatch layer of a small agent fleet: four Claude Code "masters" (separate unix users on one Linux
host) take work from a GitHub Projects board. A sweeper picks eligible issues, `dispatch.sh` launches one
`systemd --user` transient unit per issue, and `task-runner.sh` runs the agent to a merged PR and reports
the outcome back on the issue. Nothing is resident between runs.

Author: Tyler Youk ([tyleryouk.com](https://tyleryouk.com), [docs.utopiamodels.ai](https://docs.utopiamodels.ai)).

This is an extraction from a private repository, published to be read. It is not a package: the scripts
expect the fleet's board, its GitHub App and its host layout, and they will not run unchanged anywhere
else. Names are replaced (see "What was scrubbed").

## The race this repo is mostly about

Two dispatchers could start the same issue twice. The sweeper and a hand dispatch both run a
read-then-act guard: read the board and the running units, then launch. In `dispatch.sh` the time between
that read and the launch measured **26 to 27 seconds**. Two dispatchers that read in the same second both
see "nobody is running this" and both launch. Observed in production: three issues each ran twice, the
two launches 11 s, 5 s and 5 s apart, and every guard passed both times.

### Why a unit name is not a mutex here

The first fix made the unit name zero-entropy: the run for issue 7124 is always `task-7124.service`, and
`systemd-run` refuses a second unit with a name that is already loaded. That closes the race for one
master, in the kernel, with no window.

It does not close it across masters. Each master is a different unix user, and `systemctl --user` talks
to that user's own systemd user manager. Unit names are scoped per manager, so `task-7124.service` under
`alpha` and `task-7124.service` under `bravo` are two different names in two different namespaces. Both
launches succeed.

### The fix: one `flock`, held across the probe and the launch

Both dispatch paths execute their launch as the same unix user on the same host, so a single lock file
serialises them. The fleet-wide check moves inside the lock, and the lock is held until `systemd-run` has
returned:

```bash
exec 9>"$HOME/.claude/state/fleet-dispatch-claim.lock"
flock -w "${DISPATCH_CLAIM_WAIT:-45}" 9          # wait for the other dispatcher, if any
# probe every master's user manager for a live task-<issue> unit → exit 14 if one exists
# otherwise launch the unit under the target master, still holding fd 9
```

The loser's probe now runs after the winner's unit exists, so it sees it and exits 14. The read and the
write are on the same side of the lock and there is no window left. The lock fails open on purpose: if it
cannot be taken, the launch proceeds and says so, because a duplicate run costs one session while a
dispatcher that refuses all work because a lock file is unwritable costs the whole fleet.

The code is `fleet_claim_prologue()` and `fleet_claim_launch_script()` in
[`scripts/dispatch.sh`](scripts/dispatch.sh).

### The test, and why it has a mutation control

[`tests/dispatch-fleet-claim-race.sh`](tests/dispatch-fleet-claim-race.sh) races two dispatchers for two
different masters at one fake issue against the host's real systemd (the payload is `sleep 40`; no agent
runs). It asserts exactly one live unit fleet-wide and exit codes `0` and `14`.

Case 2 runs the same race with the claim disabled and requires that **both** units start. A test that
passes with the fix removed proves nothing; this one is required to fail without it.

## Files

| path | what it does |
|---|---|
| `scripts/sweep-dispatch.sh` | the scheduler: reads the board, applies the eligibility predicates (open, not held, parent not closed, attempt cap, quota state), picks a healthy master, calls `dispatch.sh` |
| `scripts/dispatch.sh` | pre-flight checks, the fleet-wide claim above, and the `systemd-run --user` launch of `task-<issue>` under the chosen master |
| `scripts/task-runner.sh` | what runs inside the unit: per-run git worktree, the agent prompt, the close-out comment and the merge backstop |
| `tests/dispatch-fleet-claim-race.sh` | the race test and its mutation control |
| `systemd/reconcile-board.{service,timer}` | the 5-minute timer the sweeper rides on |
| `systemd/reconcile-board.service.d/10-sweep-dispatch.conf` | the drop-in that adds the sweep to that timer; no new timer, service or cron entry |

Other details documented in the comments:

- **Quota state.** The live usage API named one exhausted account while all four were rate-limited, and
  the board's markers lag by one failed run. The sweeper reads a state file the runner writes when it
  captures a 429 and deletes after a clean run, so the file heals itself. (`sweep-dispatch.sh`,
  "AUTHORITATIVE quota state")
- **Disposal re-check.** A pre-flight read an issue 14 s before its run started; the issue had been
  closed in between. The runner asks "closed? throwaway?" again immediately before it announces itself.
  (`task-runner.sh`, `disposal_recheck`)
- **Status markers in headings.** The scheduler read run state from status glyphs at column 1. Agents
  posted them inside a markdown heading in 22 of 51 comments, so finished work looked unfinished.

## What was scrubbed

Replaced by pattern before publishing, then audited with a deny-list grep (zero hits) and
`gitleaks` 8.24.3:

- Host name, tailnet IPs (now `fleet-host`, `192.0.2.x`), and absolute home paths (`/home/USER`).
- Unix and GitHub account names of the masters (now `alpha`, `bravo`, `charlie`, `delta`, `gh-accountN`),
  the GitHub App bot account, and the GitHub org and repo names (now `example-org/kb` and similar).
- Product and personal domains, product repo names, and email addresses (`example.com`).
- Personal names, and one comment block about a personal mailbox.

Issue numbers such as `#7167` are left in as cross-references; they point at a private tracker.

## License

MIT.
