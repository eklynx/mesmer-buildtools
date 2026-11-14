#!/usr/bin/env bash
# Tests scripts/check_secrets.sh against docs/signing.md ("Checking the secrets"). No Apple call
# (--skip-apple) and no real key: a throwaway self-signed certificate stands in, so the Apple-issuer
# check is expected to FAIL on it and every other certificate check to behave as documented.
#   tests/test-check-secrets.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
check() { if [ "$1" -eq 0 ]; then echo "ok   $2"; else echo "FAIL $2"; failures=$((failures+1)); fi; }

[ "$(uname -s)" = "Darwin" ] || { echo "skip: needs macOS"; exit 0; }

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/buildtools-secrets.XXXXXX")"
trap 'rm -rf "$sandbox"' EXIT
script="$ROOT/scripts/check_secrets.sh"
ssl=/usr/bin/openssl
export TEST_PW="pw-9f3a1c"

# A throwaway certificate named like a Developer ID one, a matching p12, and an EC key like a .p8.
cat > "$sandbox/cert.cnf" <<'CNF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Developer ID Application: Test Signer (ABCDE12345)
OU=ABCDE12345
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
"$ssl" req -x509 -newkey rsa:2048 -nodes -days 2 -config "$sandbox/cert.cnf" -keyout "$sandbox/key.pem" -out "$sandbox/cert.pem" >/dev/null 2>&1
"$ssl" pkcs12 -export -inkey "$sandbox/key.pem" -in "$sandbox/cert.pem" -out "$sandbox/test.p12" -passout pass:pw-9f3a1c >/dev/null 2>&1
"$ssl" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$sandbox/key.p8" >/dev/null 2>&1
echo "not a key" > "$sandbox/bad.p8"
IDENT="Developer ID Application: Test Signer (ABCDE12345)"
ISSUER=69a6de6e-4f5e-47e3-e053-5b8c7c11a4d1

run() { out="$("$script" --skip-apple "$@" 2>&1)"; code=$?; }
good=(--p12 "$sandbox/test.p12" --p12-password-env TEST_PW --identity "$IDENT" --team-id ABCDE12345 --notary-key "$sandbox/key.p8" --notary-key-id ABCD123456 --notary-issuer "$ISSUER")
with() { # with OPTION VALUE: the good arguments with one option's value replaced
    local opt="$1" val="$2" args=() i=0
    while [ $i -lt ${#good[@]} ]; do
        if [ "${good[$i]}" = "$opt" ]; then args+=("$opt" "$val"); else args+=("${good[$i]}" "${good[$((i+1))]}"); fi
        i=$((i+2))
    done
    run "${args[@]}"
}
says() { echo "$out" | grep -q -e "$1"; }

run --help; [ $code -eq 0 ] && says "--skip-apple"; check $? "--help exits 0"
run --bogus; [ $code -ne 0 ] && says "unknown option: --bogus"; check $? "an unknown option is rejected"
run --p12 "$sandbox/test.p12"; [ $code -ne 0 ] && says "all options are required"; check $? "missing options are rejected"

run "${good[@]}"
says "ok   the .p12 imports with the password"; check $? "the .p12 imports with the right password"
says "ok   the .p12 holds a private key for the SIGNING_IDENTITY"; check $? "the identity is found in the .p12"
says "ok   the certificate has not expired"; check $? "an unexpired certificate passes"
says "ok   the certificate's team is TEAM_ID"; check $? "the certificate's team matches"
says "ok   NOTARY_API_KEY_P8 is a readable private key"; check $? "a PEM private key passes"
says "FAIL the certificate was not issued by Apple's Developer ID authority"; check $? "a certificate not issued by Apple fails (as a throwaway one must)"
[ $code -ne 0 ]; check $? "the run exits non-zero when any check fails"
days="$(echo "$out" | sed -n 's/^expires_in_days=//p')"
[ -n "$days" ] && [ "$days" -ge 0 ] && [ "$days" -le 2 ]; check $? "it reports the days left for the expiry reminder (the throwaway certificate has 2: got '$days')"
echo "$out" | grep -E -q '^expires_on=[0-9]{4}-[0-9]{2}-[0-9]{2}$'; check $? "it reports the expiry date as YYYY-MM-DD"

export WRONG_PW="nope"
with --p12-password-env WRONG_PW; says "FAIL the .p12 does not import"; check $? "a wrong password fails"
with --identity "Developer ID Application: Someone Else (ABCDE12345)"; says "FAIL the .p12 holds no code-signing identity"; check $? "a different identity name fails"
with --team-id ZZZZZ99999; says "FAIL the certificate's team is not TEAM_ID"; check $? "a different team fails"
with --team-id short; says "FAIL TEAM_ID is not 10"; check $? "a malformed team id fails"
with --notary-key-id short; says "FAIL NOTARY_KEY_ID"; check $? "a malformed key id fails"
with --notary-issuer not-a-uuid; says "FAIL NOTARY_ISSUER_ID"; check $? "a malformed issuer id fails"
with --notary-key "$sandbox/bad.p8"; says "FAIL NOTARY_API_KEY_P8 is empty or not a PEM"; check $? "a file that is not a private key fails"
with --p12 "$sandbox/bad.p8"; says "FAIL the .p12 does not import"; check $? "a file that is not a .p12 fails"
: > "$sandbox/empty.p12"
with --p12 "$sandbox/empty.p12"; says "FAIL DEVELOPER_ID_P12_BASE64 did not decode"; check $? "an empty .p12 fails"

# Nothing secret is printed, and no keychain is left behind.
echo "$out" | grep -q -e "pw-9f3a1c" && r=1 || r=0; check $r "no secret value appears in the output"
security list-keychains -d user | grep -q "check.keychain" && r=1 || r=0; check $r "the temporary keychain is not left in the search list"

[ "$failures" -eq 0 ] && echo "all check_secrets tests passed" || { echo "$failures failed"; exit 1; }
