#!/usr/bin/env bash
# dispatch-fleet-claim-race.sh — race two dispatchers at ONE issue and require that only one unit starts.
# (knowledge#7167)
#
# 🔴 THIS TEST TALKS TO REAL SYSTEMD ON fleet-host. It is not a fixture: the thing under test is what
# happens when two processes on two sides of a lock touch four systemd user managers in the same instant,
# and no mock has that property. It uses a FAKE issue number (999167 — never a real issue) and a harmless
# `sleep` as the payload, so it starts no run, posts nothing to the board, and spends no quota.
#
# What it proves, and the measurement it replaces:
#   #6960 made the unit name zero-entropy so systemd refuses a second `task-<n>.service` in the kernel.
#   That is per-USER: `task-7124.service` under `charlie` and under `bravo` are two different names in two
#   different namespaces. On 2026-08-28, #7124 (11s apart), #7125 and #7148 (5s apart) each ran twice,
#   cross-master, and every guard passed both times.
#
#   ✔ case 1 — two dispatchers, two masters, one issue, launched together: exactly one unit, one exit 14.
#   ✔ case 2 — MUTATION CONTROL: the same race with the fleet claim disabled starts BOTH. Without this the
#     suite is green against a claim that does nothing.
#
# Usage: bash _infra/tests/dispatch-fleet-claim-race.sh
set -uo pipefail

BRAVO="${DISPATCH_NOVA_IP:-192.0.2.10}"
DSH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/dispatch.sh"
FAKE=999167
UNIT="task-$FAKE"
A=alpha B=delta
PAYLOAD="systemd-run --user --unit='$UNIT' --collect /usr/bin/sleep 40"
FAIL=0

say() { printf '%s\n' "$*"; }
ok()  { printf '  ✔ %s\n' "$*"; }
bad() { printf '  ✘ %s\n' "$*"; FAIL=1; }

# live_fleet — "<master> <unit>" for every master running $UNIT right now. The same probe the claim uses,
# re-derived here rather than imported, so a claim that lies cannot also grade itself.
live_fleet() {
  ssh -n -o BatchMode=yes -o ConnectTimeout=8 "bravo@$BRAVO" '
    for M in alpha bravo charlie delta; do
      sudo -n -u "$M" env XDG_RUNTIME_DIR=/run/user/$(id -u "$M") \
        systemctl --user list-units --state=active --no-legend --plain "task-*" 2>/dev/null \
        | awk -v m="$M" "{print m\" \"\$1}"
    done' 2>/dev/null | grep -E "(^| )$UNIT\.service\$" || true
}

cleanup() {
  ssh -n -o BatchMode=yes -o ConnectTimeout=8 "bravo@$BRAVO" "
    for M in $A $B; do
      sudo -n -u \$M env XDG_RUNTIME_DIR=/run/user/\$(id -u \$M) systemctl --user stop $UNIT.service 2>/dev/null
      sudo -n -u \$M env XDG_RUNTIME_DIR=/run/user/\$(id -u \$M) systemctl --user reset-failed $UNIT.service 2>/dev/null
    done" >/dev/null 2>&1 || true
  sleep 1
}

race() {   # <allow-dup> → prints "<rcA> <rcB>"
  local allow="$1" outa outb rca=0 rcb=0
  local ta tb; ta="$(mktemp)"; tb="$(mktemp)"
  DISPATCH_ALLOW_DUPLICATE="$allow" bash "$DSH" --claim-script "$A" "$FAKE" "$UNIT" "$PAYLOAD" >"$ta"
  DISPATCH_ALLOW_DUPLICATE="$allow" bash "$DSH" --claim-script "$B" "$FAKE" "$UNIT" "$PAYLOAD" >"$tb"
  ssh -o BatchMode=yes -o ConnectTimeout=8 "bravo@$BRAVO" "bash -s" <"$ta" >/dev/null 2>&1 & local pa=$!
  ssh -o BatchMode=yes -o ConnectTimeout=8 "bravo@$BRAVO" "bash -s" <"$tb" >/dev/null 2>&1 & local pb=$!
  wait "$pa" || rca=$?
  wait "$pb" || rcb=$?
  rm -f "$ta" "$tb"
  printf '%s %s\n' "$rca" "$rcb"
}

say "── case 1: two dispatchers, two masters, ONE issue — launched in the same instant ───────────────"
cleanup
RCS="$(race 0)"; read -r RA RB <<<"$RCS"
LIVE="$(live_fleet)"; N="$(printf '%s' "$LIVE" | grep -c . || true)"
say "  exit codes: $A=$RA $B=$RB"
printf '%s\n' "$LIVE" | sed '/^$/d;s/^/  live: /'
[ "$N" = 1 ] && ok "exactly ONE unit is live fleet-wide (got $N)" \
             || bad "expected exactly 1 live unit fleet-wide, got $N — the race was NOT closed"
if { [ "$RA" = 0 ] && [ "$RB" = 14 ]; } || { [ "$RA" = 14 ] && [ "$RB" = 0 ]; }; then
  ok "one dispatcher launched (0) and the other was refused by the fleet claim (14)"
else
  bad "expected one 0 and one 14; got $A=$RA $B=$RB"
fi
cleanup

say ""
say "── case 2: MUTATION CONTROL — the same race with the fleet claim OFF ────────────────────────────"
say "   (DISPATCH_ALLOW_DUPLICATE=1 removes the fleet check and leaves everything else identical.)"
RCS="$(race 1)"; read -r RA RB <<<"$RCS"
LIVE="$(live_fleet)"; N="$(printf '%s' "$LIVE" | grep -c . || true)"
say "  exit codes: $A=$RA $B=$RB"
printf '%s\n' "$LIVE" | sed '/^$/d;s/^/  live: /'
[ "$N" = 2 ] && ok "control: WITHOUT the claim both masters start (got $N live) — this is the defect (#7167)" \
             || bad "control did not reproduce the defect (got $N live) — case 1 proves nothing"
cleanup

say ""
[ "$FAIL" = 0 ] && { say "PASS — the claim is atomic across masters, and the test can fail."; exit 0; }
say "FAIL — see the ✘ lines above."; exit 1
