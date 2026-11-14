#!/usr/bin/env bash
# Check that a file is an X-Plane macOS plugin of the shape Mesmer ships, without running it.
# Specification: docs/verification.md (the source of truth for every rule and failure here).
# Tests: tests/test-verify-plugin.sh.
#
#   scripts/verify_plugin.sh FILE --allow FILE [--imports-snapshot FILE] [--min-os V] [--print-imports] [--help]
#
# Pure inspection with lipo, otool and nm: the file is never loaded or executed, so it is safe
# to run on an untrusted build next to a signing key. Written for macOS's stock bash 3.2.
set -uo pipefail

REQUIRED_EXPORTS="_XPluginStart _XPluginStop _XPluginEnable _XPluginDisable _XPluginReceiveMessage"
# Never acceptable in this plugin, whatever the allow file says.
DENIED_SYMBOLS="_system _popen _fork _vfork _execl _execle _execlp _execv _execve _execvp _posix_spawn _posix_spawnp _ptrace"
# Capabilities a plugin should not gain unnoticed: a match fails unless the allow file lists the symbol.
WATCH_PATTERN='^(_connect|_getaddrinfo|_gethostbyname2?|_sendto|_sendmsg|_dlopen|_dlsym|_SecItem[A-Za-z]*|_SecKey[A-Za-z]*|_CFHTTP[A-Za-z]*|_CFURLConnection[A-Za-z]*|_CFReadStreamCreateForHTTPRequest|_CFStreamCreatePairWithSocketToHost)$'

file=""
allow=""
snapshot=""
min_os="11.0"
print_imports=0

usage() {
    sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<EOF

  FILE                     the .xpl to check
  --allow FILE             the allow file: the libraries it may link ("lib PATH") and the watched symbols it may import ("symbol NAME")
  --imports-snapshot FILE  optional: a list of the imports the last good build had; new ones are reported as notes, never failures
  --min-os V               the deployment target it must have (default $min_os)
  --print-imports          print the arm64 slice's undefined symbols (to make a snapshot) and exit
  --help                   this text
EOF
}

die() { echo "verify_plugin.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --allow|--imports-snapshot|--min-os)
            [ $# -ge 2 ] || die "$1 needs a value"
            case "$1" in --allow) allow="$2" ;; --imports-snapshot) snapshot="$2" ;; --min-os) min_os="$2" ;; esac
            shift 2 ;;
        --print-imports) print_imports=1; shift ;;
        --help|-h) usage; exit 0 ;;
        -*) usage >&2; die "unknown option: $1" ;;
        *) [ -z "$file" ] || die "more than one file given"; file="$1"; shift ;;
    esac
done

[ -n "$file" ] || die "no file given"
[ "$(uname -s)" = "Darwin" ] || die "this script inspects Mach-O files and must run on macOS"
for tool in lipo otool nm; do command -v "$tool" >/dev/null 2>&1 || die "$tool not found"; done
[ -f "$file" ] || die "no such file: $file"

archs="$(lipo -archs "$file" 2>/dev/null)" || die "$file is not a Mach-O file"
archs="$(echo "$archs" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"

if [ "$print_imports" -eq 1 ]; then
    nm -arch arm64 -u "$file" 2>/dev/null | awk '{print $NF}' | sort -u
    exit 0
fi

[ -n "$allow" ] || die "--allow is required"
[ -f "$allow" ] || die "no such allow file: $allow"

failures=0
fail() { echo "FAIL $*"; failures=$((failures+1)); }
pass() { echo "ok   $*"; }
word_in() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; } # word_in WORD "LIST OF WORDS"

[ "$archs" = "arm64 x86_64" ] && pass "universal: $archs" || fail "not universal arm64 + x86_64 (slices: $archs)"

allowed_libs="$(awk '$1=="lib"{print $2}' "$allow")"
allowed_symbols="$(awk '$1=="symbol"{print $2}' "$allow" | tr '\n' ' ')"

for arch in arm64 x86_64; do
    word_in "$arch" "$archs" || continue

    kind="$(otool -arch "$arch" -hv "$file" 2>/dev/null | awk 'f{print; exit} /magic/{f=1}')"
    case " $kind " in *" BUNDLE "*) pass "$arch: a loadable bundle" ;; *) fail "$arch: not a loadable bundle (header: $kind)" ;; esac

    exports="$(nm -arch "$arch" -gU "$file" 2>/dev/null | awk '$2=="T"{print $3}' | tr '\n' ' ')"
    missing=""
    for sym in $REQUIRED_EXPORTS; do word_in "$sym" "$exports" || missing="$missing $sym"; done
    [ -z "$missing" ] && pass "$arch: exports the X-Plane plugin entry points" || fail "$arch: missing exports:$missing"

    libs="$(otool -arch "$arch" -L "$file" 2>/dev/null | tail -n +2 | awk '{print $1}')"
    bad=""
    xplm=0
    for lib in $libs; do
        echo "$allowed_libs" | grep -F -x -q -- "$lib" || bad="$bad $lib"
        case "$lib" in */XPLM.framework/XPLM) xplm=1 ;; esac
    done
    [ -z "$bad" ] && pass "$arch: links only allowed libraries" || fail "$arch: links libraries that are not on the allow file:$bad"
    [ "$xplm" -eq 1 ] && pass "$arch: links XPLM" || fail "$arch: does not link XPLM.framework"

    imports="$(nm -arch "$arch" -u "$file" 2>/dev/null | awk '{print $NF}' | sort -u)"
    denied=""
    watched=""
    for sym in $imports; do
        word_in "$sym" "$DENIED_SYMBOLS" && denied="$denied $sym"
        if echo "$sym" | grep -E -q "$WATCH_PATTERN" && ! word_in "$sym" "$allowed_symbols"; then watched="$watched $sym"; fi
    done
    [ -z "$denied" ] && pass "$arch: imports none of the denied calls" || fail "$arch: imports denied calls:$denied"
    [ -z "$watched" ] && pass "$arch: no unlisted network, loader or keychain imports" || fail "$arch: imports not on the allow file:$watched"

    minos="$(otool -arch "$arch" -l "$file" 2>/dev/null | awk '/LC_BUILD_VERSION/{b=1} b&&/platform/{p=$2} b&&/minos/{print p" "$2; exit}')"
    [ "$minos" = "1 $min_os" ] && pass "$arch: macOS deployment target $min_os" || fail "$arch: deployment target is '$minos' (platform minos), want '1 $min_os' (macOS $min_os)"
done

if [ -n "$snapshot" ]; then
    if [ -f "$snapshot" ]; then
        new="$(nm -arch arm64 -u "$file" 2>/dev/null | awk '{print $NF}' | sort -u | comm -13 "$snapshot" - | tr '\n' ' ')"
        if [ -n "$new" ]; then echo "note: imports not in the last good build: $new"; else echo "note: no new imports since the last good build"; fi
    else
        echo "note: no import snapshot at $snapshot"
    fi
fi

if [ "$failures" -gt 0 ]; then
    echo "verify_plugin.sh: $failures check(s) failed for $file" >&2
    exit 1
fi
echo "verify_plugin.sh: $file passed every check"
