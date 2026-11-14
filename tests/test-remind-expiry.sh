#!/usr/bin/env bash
# Tests scripts/remind_expiry.sh against docs/signing.md ("Expiry reminder"). No network: a fake `gh`
# records its calls and answers `issue list` from a file. Runs on macOS and Linux.
#   tests/test-remind-expiry.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
check() { if [ "$1" -eq 0 ]; then echo "ok   $2"; else echo "FAIL $2"; failures=$((failures+1)); fi; }

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/buildtools-remind.XXXXXX")"
trap 'rm -rf "$sandbox"' EXIT
remind="$ROOT/scripts/remind_expiry.sh"

mkdir -p "$sandbox/bin"
cat > "$sandbox/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_GH_LOG"
case "$1 $2" in
    "issue list") cat "$FAKE_GH_OPEN" 2>/dev/null ;;
esac
exit 0
FAKE
chmod +x "$sandbox/bin/gh"
export PATH="$sandbox/bin:$PATH"
export FAKE_GH_LOG="$sandbox/calls.log" FAKE_GH_OPEN="$sandbox/open.txt"

run() { : > "$FAKE_GH_LOG"; : > "$FAKE_GH_OPEN"; [ -z "${OPEN:-}" ] || echo "$OPEN" > "$FAKE_GH_OPEN"; out="$("$remind" "$@" 2>&1)"; code=$?; }
base=(--expires 2027-02-01 --threshold 30 --repo eklynx/mesmer-buildtools --assignee eklynx)
calls() { cat "$FAKE_GH_LOG"; }

run --help; [ $code -eq 0 ] && echo "$out" | grep -q -e "--threshold DAYS"; check $? "--help exits 0"
run --bogus; [ $code -ne 0 ] && echo "$out" | grep -q "unknown option: --bogus"; check $? "an unknown option is rejected"
run "${base[@]}"; [ $code -ne 0 ] && echo "$out" | grep -q -e "--days is required"; check $? "a missing --days is rejected"
run --days soon "${base[@]}"; [ $code -ne 0 ] && echo "$out" | grep -q "whole number"; check $? "a non-numeric --days is rejected"
run --days 5 --expires 1 --threshold 30 --repo r --assignee a; [ $code -ne 0 ] && echo "$out" | grep -q "YYYY-MM-DD"; check $? "a malformed date is rejected"

OPEN="" run --days 31 "${base[@]}"
[ $code -eq 0 ] && [ ! -s "$FAKE_GH_LOG" ] && echo "$out" | grep -q "no reminder"; check $? "more than the threshold: no reminder and no gh call"

OPEN="" run --days 30 "${base[@]}"
[ $code -eq 0 ] && calls | grep -q "^issue create " && calls | grep -q -e "--assignee eklynx" && calls | grep -q -e "--label certificate-expiry" && calls | grep -q "expires on 2027-02-01 (30 days left)"; check $? "exactly at the threshold: opens an assigned, labelled issue"

OPEN="" run --days 3 "${base[@]}"
calls | grep -q "label create certificate-expiry"; check $? "the label is created if missing"

OPEN="7" run --days 12 "${base[@]}"
[ $code -eq 0 ] && calls | grep -q "^issue edit 7 " && ! calls | grep -q "^issue create " && calls | grep -q "(12 days left)"; check $? "an open reminder is updated, not duplicated"

OPEN="" run --days -4 "${base[@]}"
[ $code -eq 0 ] && calls | grep -q "expired on 2027-02-01"; check $? "an expired certificate gets an 'expired' issue"

[ "$failures" -eq 0 ] && echo "all remind_expiry tests passed" || { echo "$failures failed"; exit 1; }
