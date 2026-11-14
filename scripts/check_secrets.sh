#!/usr/bin/env bash
# Check that the signing secrets are usable, without signing or notarizing anything. Specification:
# docs/signing.md ("Checking the secrets"). Tests: tests/test-check-secrets.sh.
#
#   scripts/check_secrets.sh --p12 FILE --p12-password-env VAR --identity NAME --team-id ID \
#       --notary-key FILE --notary-key-id ID --notary-issuer ID [--skip-apple]
#
# Prints only pass/fail lines and the certificate's expiry date, never a secret, because the log
# of a public repository is public. The certificate goes into a throwaway keychain that is deleted
# on every exit. Written for macOS's stock bash 3.2.
set -uo pipefail

p12="" pw_env="" identity="" team="" notary_key="" key_id="" issuer=""
skip_apple=0

usage() {
    sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    echo
    echo "  --skip-apple   do not call Apple (tests; the workflow never passes it)"
}

die() { echo "check_secrets.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-apple) skip_apple=1; shift ;;
        --help|-h) usage; exit 0 ;;
        --p12|--p12-password-env|--identity|--team-id|--notary-key|--notary-key-id|--notary-issuer)
            [ $# -ge 2 ] || die "$1 needs a value"
            case "$1" in
                --p12) p12="$2" ;; --p12-password-env) pw_env="$2" ;; --identity) identity="$2" ;; --team-id) team="$2" ;;
                --notary-key) notary_key="$2" ;; --notary-key-id) key_id="$2" ;; --notary-issuer) issuer="$2" ;;
            esac
            shift 2 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

failures=0
fail() { echo "FAIL $*"; failures=$((failures+1)); }
pass() { echo "ok   $*"; }

[ "$(uname -s)" = "Darwin" ] || die "this script uses the macOS keychain and must run on macOS"
for need in p12 pw_env identity team notary_key key_id issuer; do
    [ -n "${!need}" ] || die "all options are required (missing: $need)"
done

# The values' shapes.
echo "$team" | grep -E -q '^[A-Z0-9]{10}$' && pass "TEAM_ID is 10 letters or digits" || fail "TEAM_ID is not 10 letters or digits"
case "$identity" in
    "Developer ID Application: "*"($team)") pass "SIGNING_IDENTITY is a Developer ID Application name ending in the team id" ;;
    *) fail "SIGNING_IDENTITY is not 'Developer ID Application: Name ($team)'" ;;
esac
echo "$key_id" | grep -E -q '^[A-Z0-9]{10}$' && pass "NOTARY_KEY_ID is 10 letters or digits" || fail "NOTARY_KEY_ID is not 10 letters or digits"
echo "$issuer" | grep -E -q '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$' && pass "NOTARY_ISSUER_ID is a UUID" || fail "NOTARY_ISSUER_ID is not a UUID"

# The notary key.
if [ -s "$notary_key" ] && head -1 "$notary_key" | grep -q -e '-----BEGIN PRIVATE KEY-----'; then
    /usr/bin/openssl pkey -in "$notary_key" -noout 2>/dev/null && pass "NOTARY_API_KEY_P8 is a readable private key" || fail "NOTARY_API_KEY_P8 does not parse as a private key"
else
    fail "NOTARY_API_KEY_P8 is empty or not a PEM private key (it must be the whole .p8 file)"
fi

# The certificate, in a throwaway keychain.
if [ ! -s "$p12" ]; then
    fail "DEVELOPER_ID_P12_BASE64 did not decode to a file"
elif [ -z "${!pw_env:-}" ]; then
    fail "DEVELOPER_ID_P12_PASSWORD is empty"
else
    work="$(mktemp -d "${TMPDIR:-/tmp}/check-secrets.XXXXXX")"
    keychain="$work/check.keychain-db"
    original="$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')"
    cleanup() {
        # shellcheck disable=SC2086
        security list-keychains -d user -s $original >/dev/null 2>&1
        security delete-keychain "$keychain" >/dev/null 2>&1
        rm -rf "$work"
    }
    trap cleanup EXIT
    kcpw="$(head -c 24 /dev/urandom | base64)"
    security create-keychain -p "$kcpw" "$keychain" >/dev/null 2>&1
    security unlock-keychain -p "$kcpw" "$keychain" >/dev/null 2>&1
    if security import "$p12" -k "$keychain" -P "${!pw_env}" -T /usr/bin/codesign -f pkcs12 >/dev/null 2>&1; then
        pass "the .p12 imports with the password"
        # shellcheck disable=SC2086
        security list-keychains -d user -s "$keychain" $original >/dev/null 2>&1
        found="$(security find-identity -p codesigning "$keychain" 2>/dev/null | grep -F -c "\"$identity\"")"
        [ "${found:-0}" -ge 1 ] && pass "the .p12 holds a private key for the SIGNING_IDENTITY" || fail "the .p12 holds no code-signing identity named exactly SIGNING_IDENTITY"
        cert="$work/cert.pem"
        security find-certificate -c "$identity" -p "$keychain" > "$cert" 2>/dev/null
        if [ -s "$cert" ]; then
            end="$(/usr/bin/openssl x509 -in "$cert" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
            /usr/bin/openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 && pass "the certificate has not expired (expires $end)" || fail "the certificate expired on $end"
            /usr/bin/openssl x509 -in "$cert" -noout -checkend 2592000 >/dev/null 2>&1 || echo "note: the certificate expires within 30 days ($end)"
            subject="$(/usr/bin/openssl x509 -in "$cert" -noout -subject 2>/dev/null)"
            issuer_name="$(/usr/bin/openssl x509 -in "$cert" -noout -issuer 2>/dev/null)"
            echo "$subject" | grep -q "OU *= *$team" && pass "the certificate's team is TEAM_ID" || fail "the certificate's team is not TEAM_ID"
            echo "$issuer_name" | grep -q "Developer ID Certification Authority" && pass "the certificate was issued by Apple's Developer ID authority" || fail "the certificate was not issued by Apple's Developer ID authority"
        else
            fail "could not read the certificate back from the keychain"
        fi
    else
        fail "the .p12 does not import with DEVELOPER_ID_P12_PASSWORD (wrong password or not a PKCS#12 file)"
    fi
fi

# Apple accepts the notary credentials (a read-only call that lists past submissions).
if [ "$skip_apple" -eq 0 ] && [ -s "$notary_key" ]; then
    if xcrun notarytool history --key "$notary_key" --key-id "$key_id" --issuer "$issuer" --output-format json >/dev/null 2>&1; then
        pass "Apple accepts the notary API key, key id and issuer id"
    else
        fail "Apple rejected the notary credentials (key, key id and issuer id must belong together)"
    fi
fi

if [ "$failures" -gt 0 ]; then
    echo "check_secrets.sh: $failures check(s) failed" >&2
    exit 1
fi
echo "check_secrets.sh: every check passed"
