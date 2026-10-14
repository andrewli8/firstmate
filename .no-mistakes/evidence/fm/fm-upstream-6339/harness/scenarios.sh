wait_for() { local i=0; while ! eval "$1" && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done; }
SHELLS=("/opt/homebrew/bin/bash --norc --noprofile -i" "/bin/bash --norc --noprofile -i" "/bin/zsh -f -i")
n=0
for sh in "${SHELLS[@]}"; do
  n=$((n+1))
  echo; echo "########## S1 happy path, pane: $sh (set -e)"
  start_pane "$sh"; d=$LAB/run/s1-$n; id=live-ok-$n
  run_spawn "$d" "$id"; pid=$PID; wait "$pid"; st=$?
  sleep 1; report "$d" "$id" "$st"; pane_alive_check
  echo "--- pane screen (tail)"; T capture-pane -p -t pane | grep -v '^$' | tail -4 | cut -c1-160

  echo; echo "########## S2 TERM after launch text delivered, before Enter; pane: $sh (set -e)"
  start_pane "$sh"; d=$LAB/run/s2-$n; id=live-enter-$n
  run_spawn "$d" "$id" LIVE_HOLD_TEXT=1; pid=$PID
  wait_for "[ -e '$d/text-delivered' ]"; f=$(staged_file "$d"); echo "before signal: launch file $([ -e "$f" ] && echo present || echo absent)"
  kill -TERM "$pid"; wait "$pid"; st=$?; touch "$d/release"; sleep 0.5
  echo "operator now presses Enter in the Orca terminal (line was already typed)"; T send-keys -t pane Enter; sleep 1
  report "$d" "$id" "$st"; pane_alive_check
  echo "--- pane screen (tail)"; T capture-pane -p -t pane | grep -v '^$' | tail -4 | cut -c1-200
done

echo; echo "########## S3 HUP while pane is busy (launch delivered with Enter, not yet consumed); pane: bash set -e"
start_pane "${SHELLS[0]}"; T send-keys -t pane 'sleep 4' Enter; sleep 0.3
d=$LAB/run/s3; id=live-consume
run_spawn "$d" "$id"; pid=$PID
wait_for "grep -q 'enter=1' '$d/terminal.log' 2>/dev/null"; sleep 0.3
f=$(staged_file "$d"); echo "before signal: launch file $([ -e "$f" ] && echo present || echo absent)"
kill -HUP "$pid"; wait "$pid"; st=$?; sleep 5
report "$d" "$id" "$st"; pane_alive_check
echo "--- pane screen (tail)"; T capture-pane -p -t pane | grep -v '^$' | tail -4 | cut -c1-200

echo; echo "########## S4 INT in the window right after the launch file is published, before any send"
start_pane "${SHELLS[0]}"; d=$LAB/run/s4; id=live-publish
mkdir -p "$d/sb"; cat > "$d/sb/sleep" <<SH
#!/bin/sh
if [ "\$1" = 0.3 ] && [ ! -e '$d/published' ]; then
  for f in /tmp/fm-$id+*/launch.*.sh; do [ -f "\$f" ] || continue; printf '%s\n' "\$f" > '$d/published'
    i=0; while [ ! -e '$d/release' ] && [ \$i -lt 100 ]; do /bin/sleep 0.1; i=\$((i+1)); done; done
fi
exec /bin/sleep "\$@"
SH
chmod +x "$d/sb/sleep"
OLDFB=$FB; FB="$d/sb:$FB"
run_spawn "$d" "$id"; pid=$PID; FB=$OLDFB
wait_for "[ -s '$d/published' ]"; f=$(cat "$d/published"); echo "published: $f ($([ -e "$f" ] && echo present || echo absent))"
kill -INT "$pid"; touch "$d/release"; wait "$pid"; st=$?
report "$d" "$id" "$st"; echo "published file after INT: $([ -e "$f" ] && echo STILL ON DISK || echo removed)"

echo; echo "########## S5 pane never runs the line: consume deadline reclaims (FM_ORCA_LAUNCH_CONSUME_POLLS=10); pane: zsh set -e"
start_pane "${SHELLS[2]}"; T send-keys -t pane 'sleep 6' Enter; sleep 0.3
d=$LAB/run/s5; id=live-deadline
run_spawn "$d" "$id" FM_ORCA_LAUNCH_CONSUME_POLLS=10; pid=$PID; wait "$pid"; st=$?; sleep 5
report "$d" "$id" "$st"; pane_alive_check
echo "--- pane screen (tail)"; T capture-pane -p -t pane | grep -v '^$' | tail -4 | cut -c1-200

echo; echo "########## S6 allowlisted name missing from the source session refuses before Orca allocates"
printf 'GH_TOKEN\nNOT_IN_SESSION\n' > "$LAB/config/launch-env-allowlist"
d=$LAB/run/s6; id=live-missing
run_spawn "$d" "$id"; pid=$PID; wait "$pid"; st=$?
echo "spawn exit status: $st"; cat "$d/spawn.log"
[ -e "$d/worktree-created" ] && echo "orca worktree: CREATED" || echo "orca worktree: not created"
[ -e "$d/terminal.log" ] && echo "terminal input: SENT" || echo "terminal input: none"
grep -rl 'lab-scoped-token' "$d" 2>/dev/null | sed 's/^/token leaked into: /'
