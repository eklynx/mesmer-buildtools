#!/usr/bin/env bash
# Tests scripts/verify_plugin.sh against docs/verification.md. Each rule gets a tiny plugin built
# with clang that breaks only that rule; a good plugin passes. macOS only (lipo, otool, nm, clang).
#   tests/test-verify-plugin.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
check() { if [ "$1" -eq 0 ]; then echo "ok   $2"; else echo "FAIL $2"; failures=$((failures+1)); fi; }

[ "$(uname -s)" = "Darwin" ] || { echo "skip: needs macOS"; exit 0; }
command -v clang >/dev/null 2>&1 || { echo "skip: needs clang"; exit 0; }

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/buildtools-test.XXXXXX")"
trap 'rm -rf "$sandbox"' EXIT
verify="$ROOT/scripts/verify_plugin.sh"
XPLM_ID="@executable_path/../../../Resources/plugins/XPLM.framework/XPLM"

# A stand-in XPLM that the test plugins link, with X-Plane's install name.
echo 'void XPLMDebugString(const char* s){(void)s;}' > "$sandbox/xplm.c"
clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -dynamiclib -install_name "$XPLM_ID" -o "$sandbox/XPLM" "$sandbox/xplm.c" || { echo "cannot build the stand-in XPLM"; exit 1; }

cat > "$sandbox/allow.txt" <<EOF
lib $XPLM_ID
lib /usr/lib/libSystem.B.dylib
EOF

# make_plugin NAME "SOURCE" [clang flags...]: builds $sandbox/NAME.xpl as a universal bundle linking the stand-in XPLM.
make_plugin() {
    local name="$1" body="$2"; shift 2
    printf '%s\n' '#include <stdlib.h>' '#include <sys/socket.h>' 'void XPLMDebugString(const char*);' "$body" > "$sandbox/$name.c"
    local flags=(-arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -bundle -undefined dynamic_lookup)
    clang "${flags[@]}" "$@" -o "$sandbox/$name.xpl" "$sandbox/$name.c" "$sandbox/XPLM" 2>/dev/null || echo "(could not build $name)"
}
ENTRY='int XPluginStart(char*a,char*b,char*c){XPLMDebugString("x");return 1;} void XPluginStop(void){} int XPluginEnable(void){return 1;} void XPluginDisable(void){} void XPluginReceiveMessage(int a,int b,void*c){}'

run() { out="$("$verify" "$@" 2>&1)"; code=$?; }
rejects() { # rejects LABEL PATTERN FILE [extra args]
    local label="$1" pattern="$2"; shift 2
    run "$@" --allow "$sandbox/allow.txt"
    [ $code -ne 0 ] && echo "$out" | grep -q -e "$pattern"; check $? "$label"
}

# Spec: --help prints usage and exits 0.
run --help; [ $code -eq 0 ] && echo "$out" | grep -q -- "--allow FILE"; check $? "--help exits 0 and documents --allow"

# Spec: a good plugin passes every check.
make_plugin good "$ENTRY"
run "$sandbox/good.xpl" --allow "$sandbox/allow.txt"
[ $code -eq 0 ] && echo "$out" | grep -q "passed every check"; check $? "a good plugin passes"

# Spec: bad invocations.
run; [ $code -ne 0 ] && echo "$out" | grep -q "no file given"; check $? "no file is rejected"
run "$sandbox/good.xpl"; [ $code -ne 0 ] && echo "$out" | grep -q -e "--allow is required"; check $? "a missing --allow is rejected"
run --bogus; [ $code -ne 0 ] && echo "$out" | grep -q "unknown option: --bogus"; check $? "an unknown option is rejected"
rejects "a missing file is rejected" "no such file" "$sandbox/none.xpl"
echo "just text" > "$sandbox/text.xpl"
rejects "a text file is rejected" "not a Mach-O file" "$sandbox/text.xpl"

# Spec: universal, with exactly arm64 and x86_64.
make_plugin arm_only "$ENTRY" -arch arm64
clang -arch arm64 -mmacosx-version-min=11.0 -bundle -undefined dynamic_lookup -o "$sandbox/arm_only.xpl" "$sandbox/arm_only.c" "$sandbox/XPLM" 2>/dev/null
rejects "a single-slice plugin is rejected" "not universal" "$sandbox/arm_only.xpl"

# Spec: a loadable bundle, not a plain dynamic library.
printf '%s\n' 'void XPLMDebugString(const char*);' "$ENTRY" > "$sandbox/dylib.c"
clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -dynamiclib -undefined dynamic_lookup -o "$sandbox/dylib.xpl" "$sandbox/dylib.c" "$sandbox/XPLM" 2>/dev/null
rejects "a dynamic library that is not a bundle is rejected" "not a loadable bundle" "$sandbox/dylib.xpl"

# Spec: all five X-Plane entry points are exported.
make_plugin no_stop 'int XPluginStart(char*a,char*b,char*c){XPLMDebugString("x");return 1;} int XPluginEnable(void){return 1;} void XPluginDisable(void){} void XPluginReceiveMessage(int a,int b,void*c){}'
rejects "a missing XPluginStop is rejected" "missing exports: _XPluginStop" "$sandbox/no_stop.xpl"

# Spec: it links XPLM, and only allowed libraries.
printf '%s\n' 'void XPLMDebugString(const char*);' "$ENTRY" > "$sandbox/noxplm.c"
clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -bundle -undefined dynamic_lookup -o "$sandbox/noxplm.xpl" "$sandbox/noxplm.c" 2>/dev/null
rejects "a plugin that does not link XPLM is rejected" "does not link XPLM.framework" "$sandbox/noxplm.xpl"
make_plugin extra_lib "$ENTRY" -lz
rejects "an extra linked library is rejected" "links libraries that are not on the allow file: /usr/lib/libz" "$sandbox/extra_lib.xpl"

# Spec: denied calls fail even when the allow file lists them.
make_plugin spawns "$ENTRY int run_it(void){return system(\"true\");}"
rejects "an import of system() is rejected" "imports denied calls: _system" "$sandbox/spawns.xpl"
{ cat "$sandbox/allow.txt"; echo "symbol _system"; } > "$sandbox/allow-system.txt"
run "$sandbox/spawns.xpl" --allow "$sandbox/allow-system.txt"
[ $code -ne 0 ] && echo "$out" | grep -q "imports denied calls: _system"; check $? "a denied call stays rejected even if the allow file lists it"

# Spec: watched imports fail unless the allow file lists the symbol.
make_plugin dials "$ENTRY int dial(int s,const struct sockaddr* a,socklen_t l){return connect(s,a,l);}"
rejects "an unlisted connect() import is rejected" "imports not on the allow file: _connect" "$sandbox/dials.xpl"
{ cat "$sandbox/allow.txt"; echo "symbol _connect"; } > "$sandbox/allow-connect.txt"
run "$sandbox/dials.xpl" --allow "$sandbox/allow-connect.txt"
[ $code -eq 0 ]; check $? "a watched import passes once the allow file lists it"

# Spec: the deployment target is the expected one (default 11.0).
make_plugin newer "$ENTRY" -mmacosx-version-min=12.0
rejects "a different deployment target is rejected" "deployment target" "$sandbox/newer.xpl"
run "$sandbox/newer.xpl" --allow "$sandbox/allow.txt" --min-os 12.0
[ $code -eq 0 ]; check $? "--min-os accepts the matching target"

# Spec: new imports since the last good build are noted, never a failure.
"$verify" "$sandbox/good.xpl" --allow "$sandbox/allow.txt" --print-imports > "$sandbox/snapshot.txt"
run "$sandbox/good.xpl" --allow "$sandbox/allow.txt" --imports-snapshot "$sandbox/snapshot.txt"
[ $code -eq 0 ] && echo "$out" | grep -q "note: no new imports"; check $? "an unchanged import list is noted"
echo "_puts" > "$sandbox/smaller.txt"
run "$sandbox/good.xpl" --allow "$sandbox/allow.txt" --imports-snapshot "$sandbox/smaller.txt"
[ $code -eq 0 ] && echo "$out" | grep -q "note: imports not in the last good build"; check $? "new imports are a note, not a failure"

[ "$failures" -eq 0 ] && echo "all verify_plugin tests passed" || { echo "$failures failed"; exit 1; }
