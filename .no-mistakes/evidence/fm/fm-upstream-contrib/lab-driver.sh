#!/usr/bin/env bash
# lab.sh <ref> <label> <count-mode: good|bad|overflow> [shell]
set -u
SRC=/Users/andrew/.no-mistakes/worktrees/12f15a3b55da/01M4W89X8GV39D047914YF2JZ8
REF=$1 LABEL=$2 MODE=$3 PSHELL=${4:-/bin/zsh}
ROOT=$(mktemp -d /tmp/fmgc.XXXXXX); ROOT=$(cd "$ROOT" && pwd -P)
LAB=$ROOT/home; ID="gc$(date +%s | tail -c 6)$RANDOM"
echo "root=$ROOT id=$ID ref=$REF mode=$MODE shell=$PSHELL"
"$SRC/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
git -C "$LAB" init -q -b main; git -C "$LAB" fetch -q "$SRC" "$REF"; git -C "$LAB" checkout -q -f -B main FETCH_HEAD
git -C "$LAB" config user.name lab; git -C "$LAB" config user.email lab@example.invalid
mkdir -p "$LAB/state" "$LAB/data" "$LAB/config" "$LAB/projects" "$ROOT/treehouse"
printf 'tmux\n' > "$LAB/config/backend"; printf 'codex\n' > "$LAB/config/crew-harness"
TMUX_DIR=$("$LAB/bin/fm-lab-home.sh" tmux-dir "$LAB")
# project
seed=$ROOT/seed; mkdir -p "$seed"; git init -q -b main "$seed"; echo hi > "$seed/README.md"
git -C "$seed" add -A; git -C "$seed" -c user.name=lab -c user.email=lab@example.invalid commit -q -m seed
git clone -q --bare "$seed" "$ROOT/notes.git"; git clone -q --bare "$seed" "$ROOT/probe-remote.git"
git clone -q "$ROOT/notes.git" "$LAB/projects/notes"
printf '# Projects\n\n- notes [local-only +yolo] - lab notes\n' > "$LAB/data/projects.md"
OUT=$ROOT/probe.out
cat > "$ROOT/probe.sh" <<P
#!/bin/sh
exec >"$OUT" 2>&1
echo WORKER-RAN
echo "GIT_CONFIG_COUNT=\$GIT_CONFIG_COUNT"
i=0; while [ "\$i" -lt "\${GIT_CONFIG_COUNT:-0}" ]; do eval "echo \"  \$i: \\\$GIT_CONFIG_KEY_\$i=\\\$GIT_CONFIG_VALUE_\$i\""; i=\$((i+1)); done
echo "credential.helper list:"; git config --get-all credential.helper | sed 's/^/  [/; s/\$/]/'
echo "core.hooksPath=\$(git config --get core.hooksPath)"
hooks=\$(git rev-parse --path-format=absolute --git-common-dir)/hooks; mkdir -p "\$hooks"
cat > "\$hooks/pre-push" <<'H'
#!/bin/sh
echo "repo pre-push hook ran (lfs-style credential fill):"
printf 'protocol=https\nhost=lfs.example.com\n\n' | GIT_TERMINAL_PROMPT=0 git credential fill 2>&1 | sed 's/^/  /'
H
chmod +x "\$hooks/pre-push"
echo x >> README.md; git add README.md
git -c user.name=w -c user.email=w@example.invalid commit -q -m "probe commit

Co-Authored-By: Claude <noreply@anthropic.com>"
echo "commit message after strip hook:"; git log -1 --format=%B | sed 's/^/  | /'
echo "push:"; git push -q "$ROOT/probe-remote.git" HEAD:refs/heads/probe 2>&1 | sed 's/^/  /'
echo PROBE-DONE
P
chmod +x "$ROOT/probe.sh"
HELPER='!f() { echo username=scoped-bot; echo password=scoped-token-from-inherited-helper; }; f'
case $MODE in good) CNT=2 ;; bad) CNT=bad ;; overflow) CNT=2147483647 ;; esac
base=(HOME=$HOME USER=$USER LOGNAME=$USER PATH=$PATH SHELL=$PSHELL TERM=xterm-256color LANG=en_US.UTF-8
  TMUX_TMPDIR=$TMUX_DIR TREEHOUSE_ROOT=$ROOT/treehouse FM_BACKEND=tmux DISABLE_AUTOUPDATER=1
  GIT_CONFIG_COUNT=$CNT GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
  GIT_CONFIG_KEY_1=credential.helper "GIT_CONFIG_VALUE_1=$HELPER")
env -i "${base[@]}" tmux -f /dev/null new-session -d -s firstmate -n lab -x 200 -y 50 -c "$ROOT" || exit 1
echo "$ROOT" > /tmp/fmgc-scripts/last-root
(cd "$LAB" && env -i "${base[@]}" FM_HOME="$LAB" "$LAB/bin/fm-brief.sh" "$ID" notes --mode local-only >/dev/null)
python3 - "$LAB/data/$ID/brief.md" <<'PY'
import sys; p=sys.argv[1]; t=open(p).read()
t=t.replace("{TASK}","Lab probe of inherited git config.",1).replace("{FIRSTMATE_SPEC}","Run the probe.",1); open(p,"w").write(t)
PY
(cd "$LAB" && env -i "${base[@]}" FM_HOME="$LAB" "$LAB/bin/fm-tasks-axi.sh" add "$ID" "lab probe" --kind ship --repo notes >/dev/null)
# spawn from inside the lab tmux (so TMUX names the lab socket); the spawner's own env has no GIT_CONFIG override
(cd "$LAB" && env -i "${base[@]:0:11}" TMUX="$(env -i "${base[@]}" tmux display -p '#{socket_path},1,0')" FM_HOME="$LAB" \
  timeout 240 "$LAB/bin/fm-spawn.sh" "$ID" "$LAB/projects/notes" --mode local-only --yolo on --harness "/bin/sh $ROOT/probe.sh") > "$ROOT/spawn.log" 2>&1
echo "spawn exit=$?"; tail -5 "$ROOT/spawn.log"
for i in $(seq 1 30); do grep -q PROBE-DONE "$OUT" 2>/dev/null && break; sleep 1; done
echo "===== probe output ($LABEL) ====="; cat "$OUT" 2>/dev/null || echo "(no probe output: worker never ran)"
echo "===== worker pane ($LABEL) ====="
env -i "${base[@]}" tmux list-windows -a -F '#{window_id} #{window_name}' 
w=$(env -i "${base[@]}" tmux list-windows -a -F '#{window_id} #{window_name}' | awk -v id="$ID" '$2 ~ id {print $1}' | head -1)
[ -n "$w" ] && env -i "${base[@]}" tmux capture-pane -p -J -t "$w" -S -40 | sed '/^$/d' | tail -25
