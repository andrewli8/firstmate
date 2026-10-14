#!/usr/bin/env bash
# Live harness: real bin/fm-spawn.sh, real tmux server on a private lab socket,
# real interactive pane shells. Only the Orca app CLI is replaced by a shim that
# does a real git worktree add and types into the lab tmux pane.
set -u
WT=/Users/andrew/.no-mistakes/worktrees/97bc2435f681/01M4XGR4048PZJFW0GV66D2863
SPAWN=$WT/bin/fm-spawn.sh
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"
T() { tmux -L fm-lab "$@"; }
cleanup() { T kill-server 2>/dev/null; chmod -R u+w "$LAB"; rm -rf "$LAB" /tmp/fm-live-*; echo "lab removed: $([ -e "$LAB" ] && echo NO || echo yes)"; }
trap cleanup EXIT
touch "$LAB/state/.last-watcher-beat"
printf 'manual\n' > "$LAB/config/backlog-backend"
printf 'scoped-source\n' > "$LAB/config/launch-env-tmux-session"
printf 'GH_TOKEN\nDROPPED_NAME\n' > "$LAB/config/launch-env-allowlist"
# Scoped source session: holds the token; DROPPED_NAME deliberately unset.
T new-session -d -s scoped-source -x 200 -y 50 'sleep 100000'
T set-environment -t scoped-source GH_TOKEN 'lab-scoped-token'
T set-environment -t scoped-source -r DROPPED_NAME
SOCK=$(T display -p -t scoped-source '#{socket_path}')
FB=$LAB/fakebin; mkdir -p "$FB"
cat > "$FB/orca" <<'SH'
#!/usr/bin/env bash
set -u
D=${LIVE_DIR:?}
tm() { tmux -L fm-lab "$@"; }
case "$1 $2" in
  "status --json") printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n' ;;
  "repo show") exit 1 ;;
  "repo add") printf '{"ok":true,"result":{"repo":{"id":"repo1"}}}\n' ;;
  "worktree create")
    prev=; for a in "$@"; do [ "$prev" = --name ] && name=$a; prev=$a; done
    wt="$D/orca-worktrees/$name"; mkdir -p "$D/orca-worktrees"
    git -C "$D/project" worktree add --quiet -b "orca-$name" "$wt" >&2 || exit 1
    touch "$D/worktree-created"
    printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s"}}}\n' "$name" "$wt" ;;
  "terminal create") printf '{"ok":true,"result":{"terminal":{"handle":"term-1"}}}\n' ;;
  "terminal close") touch "$D/terminal-closed" ;;
  "terminal send")
    text=; enter=0; prev=
    for a in "$@"; do [ "$prev" = --text ] && text=$a; [ "$a" = --enter ] && enter=1; prev=$a; done
    printf '%s|enter=%s\n' "$text" "$enter" >> "$D/terminal.log"
    [ -z "$text" ] || tm send-keys -t pane -l -- "$text"
    case "$text" in *launch.*)
      if [ "${LIVE_HOLD_TEXT:-0}" = 1 ]; then touch "$D/text-delivered"; i=0
        while [ ! -e "$D/release" ] && [ $i -lt 200 ]; do sleep 0.1; i=$((i+1)); done; fi ;;
    esac
    [ "$enter" = 0 ] || tm send-keys -t pane Enter
    printf '{"ok":true}\n' ;;
esac
exit 0
SH
chmod +x "$FB/orca"

# start_pane <shell-cmd>: real interactive shell with errexit and an ambient personal token.
start_pane() {
  T kill-session -t pane 2>/dev/null
  mkdir -p "$LAB/zdot"; : > "$LAB/zdot/.zshrc"
  T new-session -d -s pane -x 200 -y 50 -e GH_TOKEN=pane-personal-token -e DATABASE_URL=pane-personal-db -e ZDOTDIR="$LAB/zdot" "$1"
  sleep 1
  T send-keys -t pane "set -e; PS1='pane\$ '; PROMPT='pane\$ '" Enter
  sleep 0.5
}
pane_alive_check() {  # proves the interactive shell survived
  T send-keys -t pane 'echo SHELL-STILL-ALIVE-$((40+2))' Enter; sleep 0.7
  T capture-pane -p -t pane -S -200 | grep -q 'SHELL-STILL-ALIVE-42' && echo "pane: alive" || echo "pane: DEAD"
}
# run_spawn <dir> <id> [extra env...]: background spawn; prints pid
run_spawn() {
  local d=$1 id=$2; shift 2
  mkdir -p "$LAB/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nLive Orca source check.\n\n## Firstmate spec\nPrint env.\n' > "$LAB/data/$id/brief.md"
  rm -rf "$d/project"; mkdir -p "$d"
  git init -q "$d/project" && git -C "$d/project" commit -q --allow-empty -m init
  cat > "$d/probe.sh" <<P
#!/bin/sh
{ echo "worker GH_TOKEN=\${GH_TOKEN-unset}"; echo "worker DATABASE_URL=\${DATABASE_URL-unset}"; echo "worker DROPPED_NAME=\${DROPPED_NAME-unset}"; echo "worker GIT_CONFIG_NOSYSTEM=\${GIT_CONFIG_NOSYSTEM-unset}"; ls /tmp/fm-$id+*/launch.*.sh 2>/dev/null | sed 's/^/worker sees launch file: /' || true; } > "$d/worker.out"
P
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" FM_SPAWN_NO_GUARD=1 LIVE_DIR="$d" TMUX="$SOCK,0,0" GH_TOKEN=spawner-ambient-token \
    PATH="$FB:$PATH" "$@" python3 -c 'import os,signal,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
    "$SPAWN" "$id" "$d/project" --mode direct-PR --yolo off --backend orca --harness "/bin/sh '$d/probe.sh'" > "$d/spawn.log" 2>&1 &
  PID=$!
}
staged_file() { sed -n "s/.*\. '\(\/[^']*launch\.[^']*\.sh\)'.*/\1/p" "$1/terminal.log" | head -1; }
report() {  # <dir> <id> <status>
  local d=$1 id=$2
  echo "spawn exit status: $3"; echo "--- spawn output"; cat "$d/spawn.log"
  echo "--- terminal sends (text|enter)"; cat "$d/terminal.log" 2>/dev/null
  echo "--- task status"; cat "$LAB/state/$id.status" 2>/dev/null; echo
  local f; f=$(staged_file "$d"); echo "staged launch file: ${f:-none}"; [ -n "$f" ] && { [ -e "$f" ] && echo "launch file: STILL ON DISK" || echo "launch file: removed"; }
  [ -e "$d/terminal-closed" ] && echo "orca terminal: closed" || echo "orca terminal: left open"
  echo "--- worker"; cat "$d/worker.out" 2>/dev/null || echo "worker did not run"
}
. "${SCEN:-/tmp/fmlive-scripts/scenarios.sh}"
