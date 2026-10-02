#!/usr/bin/env bash
# Drive the real render_export_dom helper (base or fixed) against a real browser
# on macOS and record keychain-related unified-log lines raised during the run.
# usage: keychain-harness.sh <base|fixed> <label> [chrome-bin]
set -u
EV=$(cd "$(dirname "$0")" && pwd)
variant=$1 label=$2
[ -n "${3:-}" ] && export FM_CHROME_BIN=$3
. "$EV/helper-$variant.sh"
TMP_ROOT=$(mktemp -d)
src="$TMP_ROOT/export.html"
cat >"$src" <<'HTML'
<!doctype html><html><head><title>calm export fixture</title></head>
<body><div id="conversation"></div>
<script>document.getElementById("conversation").innerHTML='<div class="user-message">CALM_RENDER_OK</div>';</script>
</body></html>
HTML
chrome=$(find_chrome) || { echo "no chrome"; exit 1; }
ts=$(date '+%Y-%m-%d %H:%M:%S')
if report=$(render_export_dom "$chrome" "$src" "$EV/dom-$label.html" test); then rc=0; else rc=$?; fi
sleep 2
log show --style compact --start "$ts" \
  --predicate '(process == "SecurityAgent" OR process == "securityd" OR process CONTAINS[c] "chrom") AND (eventMessage CONTAINS[c] "keychain")' \
  >"$EV/keychain-log-$label.txt" 2>&1
lines=$(grep -vc -e '^Timestamp' -e '^Filtering' -e '^$' "$EV/keychain-log-$label.txt")
echo "variant=$variant browser=$("$chrome" --version) render_rc=$rc dom_has_marker=$(grep -c CALM_RENDER_OK "$EV/dom-$label.html") keychain_log_lines=$lines private_home_keychains=$(ls "$TMP_ROOT"/chrome-home-1/Library/Keychains 2>/dev/null | tr '\n' ' ')"
[ -n "$report" ] && echo "report: $report"
rm -rf "$TMP_ROOT"
