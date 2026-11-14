#!/usr/bin/env bash
# Tests scripts/resolve_source.sh against docs/source-rules.md. No network: a fake `gh` answers from
# files in the sandbox. Runs on macOS and Linux.
#   tests/test-resolve-source.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
check() { if [ "$1" -eq 0 ]; then echo "ok   $2"; else echo "FAIL $2"; failures=$((failures+1)); fi; }

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/buildtools-resolve.XXXXXX")"
trap 'rm -rf "$sandbox"' EXIT
resolve="$ROOT/scripts/resolve_source.sh"
SHA_MAIN=1111111111111111111111111111111111111111
SHA_TAGGED=2222222222222222222222222222222222222222
SHA_LOOSE=3333333333333333333333333333333333333333

# A fake gh: `gh api PATH [--paginate] --jq EXPR`. It answers by PATH; $FAKE_GH_DIR holds the answers.
mkdir -p "$sandbox/bin" "$sandbox/answers"
cat > "$sandbox/bin/gh" <<'EOF'
#!/usr/bin/env bash
path="$2"
file="$FAKE_GH_DIR/$(echo "$path" | tr '/.' '__')"
[ -f "$file" ] || exit 1
cat "$file"
EOF
chmod +x "$sandbox/bin/gh"
export FAKE_GH_DIR="$sandbox/answers"
export PATH="$sandbox/bin:$PATH"
answer() { printf '%s\n' "$2" > "$FAKE_GH_DIR/$(echo "$1" | tr '/.' '__')"; }

# antialias/mesmer: main is $SHA_MAIN; $SHA_TAGGED is tagged but not on main; $SHA_LOOSE is a loose branch.
answer "repos/antialias/mesmer/commits/main" "$SHA_MAIN"
answer "repos/antialias/mesmer/commits/v1.0.0" "$SHA_TAGGED"
answer "repos/antialias/mesmer/commits/contrib" "$SHA_LOOSE"
answer "repos/antialias/mesmer" "main"
answer "repos/antialias/mesmer/compare/main...$SHA_MAIN" "identical"
answer "repos/antialias/mesmer/compare/main...$SHA_TAGGED" "diverged"
answer "repos/antialias/mesmer/compare/main...$SHA_LOOSE" "ahead"
answer "repos/antialias/mesmer/tags" "$SHA_TAGGED"
# eklynx/mesmer: any ref.
answer "repos/eklynx/mesmer/commits/wip" "$SHA_LOOSE"
answer "repos/eklynx/mesmer" "main"

run() { out="$("$resolve" "$@" 2>&1)"; code=$?; }

run --help; [ $code -eq 0 ] && echo "$out" | grep -q -- "--repo OWNER/NAME"; check $? "--help exits 0 and documents --repo"
run --ref main; [ $code -ne 0 ] && echo "$out" | grep -q -e "--repo is required"; check $? "a missing --repo is rejected"
run --repo antialias/mesmer; [ $code -ne 0 ] && echo "$out" | grep -q -e "--ref is required"; check $? "a missing --ref is rejected"
run --bogus; [ $code -ne 0 ] && echo "$out" | grep -q "unknown option: --bogus"; check $? "an unknown option is rejected"

run --repo someone/else --ref main
[ $code -ne 0 ] && echo "$out" | grep -q "not on the allowlist"; check $? "a repository off the allowlist is rejected"
run --repo antialias/mesmer-evil --ref main
[ $code -ne 0 ] && echo "$out" | grep -q "not on the allowlist"; check $? "a look-alike repository name is rejected"
for bad in '--upload-pack=x' 'a b' 'a..b' 'x;y' '$(id)'; do
    run --repo eklynx/mesmer --ref "$bad"
    [ $code -ne 0 ] && echo "$out" | grep -q -E "characters a branch|contains '..'|needs a value|unknown option"; check $? "the ref '$bad' is rejected"
done
run --repo eklynx/mesmer --ref nosuchbranch
[ $code -ne 0 ] && echo "$out" | grep -q "does not resolve to a commit"; check $? "a ref that does not resolve is rejected"

run --repo antialias/mesmer --ref main
[ $code -eq 0 ] && echo "$out" | grep -q "^sha=$SHA_MAIN$" && echo "$out" | grep -q "^repo=antialias/mesmer$"; check $? "antialias main resolves to its commit"
run --repo antialias/mesmer --ref v1.0.0
[ $code -eq 0 ] && echo "$out" | grep -q "^sha=$SHA_TAGGED$"; check $? "an antialias tag off main is allowed"
run --repo antialias/mesmer --ref contrib
[ $code -ne 0 ] && echo "$out" | grep -q "not on antialias/mesmer's default branch"; check $? "an untagged antialias branch off main is rejected"
run --repo eklynx/mesmer --ref wip
[ $code -eq 0 ] && echo "$out" | grep -q "^sha=$SHA_LOOSE$"; check $? "any eklynx ref is allowed"

[ "$failures" -eq 0 ] && echo "all resolve_source tests passed" || { echo "$failures failed"; exit 1; }
