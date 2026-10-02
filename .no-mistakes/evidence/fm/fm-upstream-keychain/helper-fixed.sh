find_chrome() {
  local candidate
  if [ -n "${FM_CHROME_BIN:-}" ] && [ -x "$FM_CHROME_BIN" ]; then
    printf '%s\n' "$FM_CHROME_BIN"
    return 0
  fi
  for candidate in \
    google-chrome \
    google-chrome-stable \
    chromium \
    chromium-browser \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}
render_export_dom() {
  local chrome=$1 source_file=$2 out_file=$3 pi_version=$4
  local attempt pid status wait_count wait_limit reap_wait log profile report timed_out
  local -a profile_arg
  report="$TMP_ROOT/chrome-render-report.txt"
  wait_limit=${FM_CHROME_RENDER_WAIT_TICKS:-300}
  : >"$report"
  for attempt in 1 2 3; do
    log="$TMP_ROOT/chrome-render-$attempt.err"
    profile="$TMP_ROOT/chrome-home-$attempt"
    rm -rf "$profile"
    mkdir -p "$profile"
    : >"$out_file"
    # Isolate the profile per attempt. On Linux and every other non-Darwin
    # platform an explicit --user-data-dir pointing at a brand-new profile makes
    # Chrome's first-run initialization never complete on at least Google Chrome
    # for Testing 151.0.7922.34: the browser and its renderers start, but
    # --dump-dom never returns, so all three bounded attempts end exit=0
    # timed_out=yes bytes=0 and the DOM assertions below never run at all. A
    # private HOME is Chromium's documented isolation switch there and renders
    # the same document in about a second. macOS derives its profile directory
    # from ~/Library regardless of HOME, so Darwin keeps the explicit
    # --user-data-dir that was this file's original isolation. Either way each
    # attempt starts from the fresh directory removed just above.
    case "$(uname -s)" in
      Darwin) profile_arg=(--user-data-dir="$profile") ;;
      *) profile_arg=() ;;
    esac
    HOME="$profile" XDG_CONFIG_HOME="$profile/.config" XDG_CACHE_HOME="$profile/.cache" \
      "$chrome" \
      ${profile_arg[@]+"${profile_arg[@]}"} \
      --headless=new \
      --disable-gpu \
      --no-sandbox \
      --disable-dev-shm-usage \
      --disable-background-networking \
      --use-mock-keychain \
      --password-store=basic \
      --virtual-time-budget=2000 \
      --dump-dom \
      "file://$source_file" >"$out_file" 2>"$log" &
    pid=$!
    # Check the DOM before Chrome's liveness, so an attempt that writes the
    # complete dump and exits immediately is still read as a success.
    wait_count=0
    while [ "$wait_count" -lt "$wait_limit" ]; do
      grep -Fq '</html>' "$out_file" 2>/dev/null && break
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
      wait_count=$((wait_count + 1))
    done
    timed_out=no
    if [ "$wait_count" -ge "$wait_limit" ]; then
      timed_out=yes
    fi
    kill "$pid" 2>/dev/null || true
    # Chrome can retain --headless=new after --dump-dom completes and ignore TERM,
    # so an unbounded wait can hang after the complete DOM has been captured.
    reap_wait=0
    while kill -0 "$pid" 2>/dev/null && [ "$reap_wait" -lt 20 ]; do
      sleep 0.1
      reap_wait=$((reap_wait + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
    status=0
    wait "$pid" 2>/dev/null || status=$?
    grep -Fq '</html>' "$out_file" 2>/dev/null && return 0
    printf 'attempt %s: exit=%s timed_out=%s bytes=%s stderr=%s\n' \
      "$attempt" "$status" "$timed_out" "$(wc -c <"$out_file" | tr -d ' ')" \
      "$(tail -c 400 "$log" 2>/dev/null | tr '\n' ' ')" >>"$report"
  done
  printf 'chrome=%s chrome_version=%s pi=%s; %s' \
    "$chrome" "$("$chrome" --version 2>&1 | head -1)" "$pi_version" \
    "$(tr '\n' ' ' <"$report")"
  return 1
}
