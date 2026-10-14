wait_for() { local i=0; while ! eval "$1" && [ $i -lt 400 ]; do sleep 0.1; i=$((i+1)); done; }
launch_entered() { grep -A1 '/launch\.' "$1/terminal.log" 2>/dev/null | sed -n 2p | grep -qx '|enter=1'; }
echo "########## S3 HUP after launch line + Enter delivered while pane busy (not yet consumed); pane: bash set -e"
start_pane "/opt/homebrew/bin/bash --norc --noprofile -i"; T send-keys -t pane 'sleep 25' Enter; sleep 0.3
d=$LAB/run/s3; id=live-consume
run_spawn "$d" "$id"; pid=$PID
wait_for "launch_entered '$d'"; sleep 0.5
f=$(staged_file "$d"); echo "before signal: launch file $([ -e "$f" ] && echo present || echo absent); spawn $(kill -0 $pid 2>/dev/null && echo running || echo exited)"
kill -HUP "$pid"; wait "$pid" 2>/dev/null; st=$?
echo "right after HUP: launch file $([ -e "$f" ] && echo STILL ON DISK || echo removed)"
echo "waiting for the busy pane to free up and run the queued launch line..."; sleep 26
report "$d" "$id" "$st"; pane_alive_check
echo "--- pane screen (tail)"; T capture-pane -p -t pane | grep -v '^$' | tail -4 | cut -c1-200

echo; echo "########## S5 pane never runs the line within the deadline (FM_ORCA_LAUNCH_CONSUME_POLLS=10 ~2s); pane: zsh set -e"
start_pane "/bin/zsh -f -i"; T send-keys -t pane 'sleep 25' Enter; sleep 0.3
d=$LAB/run/s5; id=live-deadline
run_spawn "$d" "$id" FM_ORCA_LAUNCH_CONSUME_POLLS=10; pid=$PID; wait "$pid"; st=$?
f=$(staged_file "$d"); echo "right after spawn exit: launch file $([ -e "$f" ] && echo STILL ON DISK || echo removed)"
echo "waiting for the busy pane to run the queued launch line..."; sleep 26
report "$d" "$id" "$st"; pane_alive_check
echo "--- pane screen (tail)"; T capture-pane -p -t pane | grep -v '^$' | tail -4 | cut -c1-200
