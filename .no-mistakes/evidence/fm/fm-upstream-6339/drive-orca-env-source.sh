#!/usr/bin/env bash
# Live drive of real bin/fm-spawn.sh --backend orca against: a real tmux server
# (private socket, scoped session holding synthetic "scoped" values), and an
# orca CLI shim whose terminals are real shells in a second private tmux server
# that holds synthetic "personal" credentials (stand-in for the Orca app,
# which is not driven to avoid mutating the operator's running Orca state).
set -u
WT=$1; SCEN=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
TD=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
cleanup() {
  TMUX_TMPDIR="$TD" tmux kill-server 2>/dev/null
  TMUX_TMPDIR="$TD" tmux -L orcasim kill-server 2>/dev/null
  "$WT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
  git -C "$LAB/project" worktree prune 2>/dev/null
  rm -rf "$LAB" /tmp/fm-lab-orca-"$SCEN"+* 2>/dev/null
}
trap cleanup EXIT
printf 'manual\n' > "$LAB/config/backlog-backend"
mkdir -p "$LAB/project" "$LAB/fb" "$LAB/out"
git -C "$LAB/project" init -q && git -C "$LAB/project" -c user.email=a@b -c user.name=t commit -q --allow-empty -m init
cat > "$LAB/fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
S() { TMUX_TMPDIR="$FM_SIM_TD" tmux -L orcasim "$@"; }
arg() { local want=$1 prev=; shift; for a in "$@"; do [ "$prev" = "$want" ] && { printf '%s' "$a"; return; }; prev=$a; done; }
case "$1 $2" in
  "status --json") echo '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}' ;;
  "repo show") exit 1 ;;
  "repo add") echo '{"ok":true,"result":{"repo":{"id":"repo1"}}}' ;;
  "worktree create") n=$(arg --name "$@"); wt="$FM_SIM_LAB/orca-wt/$n"; mkdir -p "$FM_SIM_LAB/orca-wt"
    git -C "$FM_SIM_LAB/project" worktree add -q -b "orca-$n" "$wt" >&2 || exit 1
    printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s"}}}\n' "$n" "$wt" ;;
  "worktree show") echo '{"ok":true,"result":{"worktree":{"path":"x"}}}' ;;
  "terminal create")
    # Orca terminal environment: app + shell startup, with personal credentials.
    S new-session -d -s term -x 200 -y 50 -c "$FM_SIM_LAB" \
      env -i HOME="$FM_SIM_LAB/user-home" PATH="$PATH" TERM=xterm USER="$USER" \
      GH_TOKEN=personal-token GH_CONFIG_DIR=personal-gh DATABASE_URL=personal-db LANG=personal-lang \
      GIT_CONFIG_NOSYSTEM=0 /bin/bash --norc --noprofile -i
    echo '{"ok":true,"result":{"terminal":{"handle":"term-1"}}}' ;;
  "terminal send")
    t=$(arg --text "$@"); [ -z "$t" ] || { S send-keys -t term -l "$t"; printf '%s\n' "$t" >> "$FM_SIM_LAB/out/terminal-input.log"; }
    case " $* " in *" --enter "*) S send-keys -t term Enter ;; esac
    echo '{"ok":true}' ;;
  "terminal read") c=$(S capture-pane -p -t term | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')
    printf '{"ok":true,"result":{"tail":%s}}\n' "$c" ;;
  "terminal close") S kill-session -t term 2>/dev/null; echo '{"ok":true}' ;;
  *) echo '{"ok":true}' ;;
esac
SH
chmod +x "$LAB/fb/orca"
cat > "$LAB/probe.sh" <<EOF
#!/bin/sh
for n in GH_TOKEN GH_CONFIG_DIR DATABASE_URL LANG GIT_CONFIG_NOSYSTEM SSH_AUTH_SOCK; do
  eval "v=\\\${\$n-<unset>}"; printf '%s=%s\\n' "\$n" "\$v"
done > "$LAB/out/worker-env.txt"
ls /tmp/fm-lab-orca-$SCEN+*/launch.*.sh 2>/dev/null > "$LAB/out/launch-files-at-worker-start.txt"
EOF
# scoped tmux session, real tmux, private socket dir
TMUX_TMPDIR="$TD" tmux new-session -d -s scoped-src
TMUX_TMPDIR="$TD" tmux set-environment -t scoped-src GH_TOKEN "scoped-token-with 'quote' \$(touch $LAB/injected)"
TMUX_TMPDIR="$TD" tmux set-environment -t scoped-src GH_CONFIG_DIR scoped-gh
TMUX_TMPDIR="$TD" tmux set-environment -t scoped-src SSH_AUTH_SOCK /scoped/agent.sock
TMUX_TMPDIR="$TD" tmux set-environment -t scoped-src -r LANG
TMUX_TMPDIR="$TD" tmux set-environment -g GLOBAL_ONLY global-value
id=lab-orca-$SCEN
mkdir -p "$LAB/data/$id"
printf '# Task\n## Captain'"'"'s intent\nLive Orca env source check.\n\n## Firstmate spec\nDump env.\n' > "$LAB/data/$id/brief.md"
case "$SCEN" in
  source) printf 'scoped-src\n' > "$LAB/config/launch-env-tmux-session"; printf 'GH_TOKEN\nGH_CONFIG_DIR\nLANG\n' > "$LAB/config/launch-env-allowlist" ;;
  nosource) printf 'GH_TOKEN\nGH_CONFIG_DIR\n' > "$LAB/config/launch-env-allowlist" ;;
  missing-name) printf 'scoped-src\n' > "$LAB/config/launch-env-tmux-session"; printf 'GH_TOKEN\nNOT_IN_SESSION\n' > "$LAB/config/launch-env-allowlist" ;;
  global-only) printf 'scoped-src\n' > "$LAB/config/launch-env-tmux-session"; printf 'GLOBAL_ONLY\n' > "$LAB/config/launch-env-allowlist" ;;
  no-allowlist) printf 'scoped-src\n' > "$LAB/config/launch-env-tmux-session" ;;
  dead-session) printf 'no-such-session\n' > "$LAB/config/launch-env-tmux-session"; printf 'GH_TOKEN\n' > "$LAB/config/launch-env-allowlist" ;;
esac
echo "### scenario=$SCEN"
echo "### config: session=$(cat "$LAB/config/launch-env-tmux-session" 2>/dev/null || echo '<none>') allowlist=$(tr '\n' ' ' < "$LAB/config/launch-env-allowlist" 2>/dev/null || echo '<none>')"
echo "### Orca terminal personal env: GH_TOKEN=personal-token GH_CONFIG_DIR=personal-gh DATABASE_URL=personal-db LANG=personal-lang GIT_CONFIG_NOSYSTEM=0"
echo "### scoped tmux session env:"; TMUX_TMPDIR="$TD" tmux -u show-environment -t =scoped-src | grep -E '^-?(GH_|LANG|SSH_AUTH)' | sed 's/^/    /'
echo "### fm-spawn.sh output:"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u GH_TOKEN \
  FM_HOME="$LAB" TMUX_TMPDIR="$TD" FM_SIM_TD="$TD" FM_SIM_LAB="$LAB" PROBE_OUT_DIR="$LAB/out" PATH="$LAB/fb:$PATH" \
  "$WT/bin/fm-spawn.sh" "$id" "$LAB/project" --mode direct-PR --yolo off --backend orca --harness "/bin/sh '$LAB/probe.sh'" 2>&1 | sed 's/^/    /'
echo "    exit=${PIPESTATUS[0]}"
for i in $(seq 1 30); do [ -f "$LAB/out/worker-env.txt" ] && break; sleep 0.5; done
echo "### orca worktree allocated: $([ -d "$LAB/orca-wt" ] && echo yes || echo no); meta published: $([ -f "$LAB/state/$id.meta" ] && echo yes || echo no)"
echo "### text sent to Orca terminal input:"; sed 's/^/    /' "$LAB/out/terminal-input.log" 2>/dev/null || echo "    <none>"
echo "### worker env (as seen by the launched harness):"; sed 's/^/    /' "$LAB/out/worker-env.txt" 2>/dev/null || echo "    <worker never ran>"
echo "### launch files present when worker started: $(cat "$LAB/out/launch-files-at-worker-start.txt" 2>/dev/null | wc -l | tr -d ' ')"
echo "### launch files left after run: $(ls /tmp/fm-lab-orca-"$SCEN"+*/launch.*.sh 2>/dev/null | wc -l | tr -d ' ')"
echo "### shell injection fired: $([ -e "$LAB/injected" ] && echo YES || echo no)"
