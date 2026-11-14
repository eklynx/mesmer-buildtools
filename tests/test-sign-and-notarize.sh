#!/usr/bin/env bash
# Tests scripts/sign_and_notarize.sh against docs/signing.md. The failure paths need no key and no
# network. The signing path runs with a throwaway self-signed certificate (--no-notarize,
# --no-timestamp, a test authority prefix); it is skipped, loudly, if this Mac will not use one.
# Notarization needs Apple and is covered by the workflow's first real run.
#   tests/test-sign-and-notarize.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
check() { if [ "$1" -eq 0 ]; then echo "ok   $2"; else echo "FAIL $2"; failures=$((failures+1)); fi; }

[ "$(uname -s)" = "Darwin" ] || { echo "skip: needs macOS"; exit 0; }
command -v clang >/dev/null 2>&1 || { echo "skip: needs clang"; exit 0; }

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/buildtools-sign.XXXXXX")"
trap 'rm -rf "$sandbox"' EXIT
sign="$ROOT/scripts/sign_and_notarize.sh"

echo 'int main(void){return 0;}' > "$sandbox/t.c"
clang -arch arm64 -arch x86_64 -o "$sandbox/plugin" "$sandbox/t.c"
echo "not a binary" > "$sandbox/text"
echo "fake" > "$sandbox/fake.p12"
echo "fake" > "$sandbox/key.p8"
export TEST_P12_PASSWORD="secret"

run() { out="$("$sign" "$@" 2>&1)"; code=$?; }
base=(--file "$sandbox/plugin" --out "$sandbox/out/plugin" --identity "X" --team-id "T" --p12 "$sandbox/fake.p12" --p12-password-env TEST_P12_PASSWORD --no-notarize)
rejects() { # rejects LABEL PATTERN args...
    local label="$1" pattern="$2"; shift 2
    run "$@"
    [ $code -ne 0 ] && echo "$out" | grep -q -e "$pattern" && [ ! -e "$sandbox/out/plugin" ]
    check $? "$label"
}

run --help; [ $code -eq 0 ] && echo "$out" | grep -q -- "--p12-password-env"; check $? "--help exits 0 and documents --p12-password-env"
rejects "an unknown option is rejected" "unknown option: --bogus" --bogus
for opt in file out identity team-id p12 p12-password-env; do
    args=()
    [ "$opt" = file ] || args+=(--file "$sandbox/plugin")
    [ "$opt" = out ] || args+=(--out "$sandbox/out/plugin")
    [ "$opt" = identity ] || args+=(--identity X)
    [ "$opt" = team-id ] || args+=(--team-id T)
    [ "$opt" = p12 ] || args+=(--p12 "$sandbox/fake.p12")
    [ "$opt" = p12-password-env ] || args+=(--p12-password-env TEST_P12_PASSWORD)
    rejects "a missing --$opt is rejected" "--$opt is required" "${args[@]}" --no-notarize
done
rejects "missing notary options are rejected unless --no-notarize" "--notary-key, --notary-key-id and --notary-issuer are required" \
    --file "$sandbox/plugin" --out "$sandbox/out/plugin" --identity X --team-id T --p12 "$sandbox/fake.p12" --p12-password-env TEST_P12_PASSWORD
rejects "a missing input file is rejected" "no such file" --file "$sandbox/none" --out "$sandbox/out/plugin" --identity X --team-id T --p12 "$sandbox/fake.p12" --p12-password-env TEST_P12_PASSWORD --no-notarize
rejects "a non-Mach-O input is rejected" "is not a Mach-O file" --file "$sandbox/text" --out "$sandbox/out/plugin" --identity X --team-id T --p12 "$sandbox/fake.p12" --p12-password-env TEST_P12_PASSWORD --no-notarize
rejects "a missing certificate file is rejected" "no such certificate file" --file "$sandbox/plugin" --out "$sandbox/out/plugin" --identity X --team-id T --p12 "$sandbox/none.p12" --p12-password-env TEST_P12_PASSWORD --no-notarize
rejects "an unset password variable is rejected" "is empty or not set" --file "$sandbox/plugin" --out "$sandbox/out/plugin" --identity X --team-id T --p12 "$sandbox/fake.p12" --p12-password-env NOT_SET_ANYWHERE --no-notarize
rejects "a missing notary key file is rejected" "no such notary key file" --file "$sandbox/plugin" --out "$sandbox/out/plugin" --identity X --team-id T --p12 "$sandbox/fake.p12" --p12-password-env TEST_P12_PASSWORD --notary-key "$sandbox/none.p8" --notary-key-id K --notary-issuer I
rejects "a bad certificate file is rejected" "could not import" "${base[@]}"

# The signing path, with a throwaway certificate. A self-signed certificate has no Apple team, so
# codesign reports the team as 'not set'; the tests expect exactly that, and a different expected
# team must be refused.
ssl=/usr/bin/openssl
cat > "$sandbox/cert.cnf" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Buildtools Test Signer
OU=TESTTEAM01
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
if "$ssl" req -x509 -newkey rsa:2048 -nodes -days 2 -config "$sandbox/cert.cnf" -keyout "$sandbox/key.pem" -out "$sandbox/cert.pem" >/dev/null 2>&1 \
   && "$ssl" pkcs12 -export -inkey "$sandbox/key.pem" -in "$sandbox/cert.pem" -out "$sandbox/test.p12" -passout pass:secret >/dev/null 2>&1; then
    run --file "$sandbox/plugin" --out "$sandbox/signed/plugin" --identity "Buildtools Test Signer" --team-id "not set" \
        --p12 "$sandbox/test.p12" --p12-password-env TEST_P12_PASSWORD --no-notarize --no-timestamp --authority-prefix "Buildtools Test"
    if [ $code -eq 0 ]; then
        echo "$out" | grep -q "signed: Buildtools Test Signer, team not set"; check $? "signs with the throwaway certificate and reports the authority and team"
        codesign --verify --strict "$sandbox/signed/plugin" 2>/dev/null; check $? "the signed copy verifies"
        cmp -s "$sandbox/plugin" "$sandbox/signed/plugin" && r=1 || r=0; check $r "the signed copy differs from the input"
        codesign --verify "$sandbox/plugin" 2>/dev/null && r=1 || r=0; check $r "the input file was not modified"
        rm -rf "$sandbox/signed"
        run --file "$sandbox/plugin" --out "$sandbox/signed/plugin" --identity "Buildtools Test Signer" --team-id WRONGTEAM1 \
            --p12 "$sandbox/test.p12" --p12-password-env TEST_P12_PASSWORD --no-notarize --no-timestamp --authority-prefix "Buildtools Test"
        [ $code -ne 0 ] && echo "$out" | grep -q "expected 'WRONGTEAM1'" && [ ! -e "$sandbox/signed/plugin" ]; check $? "a signature from the wrong team is rejected and removed"
        rm -rf "$sandbox/signed"
        run --file "$sandbox/plugin" --out "$sandbox/signed/plugin" --identity "Buildtools Test Signer" --team-id "not set" \
            --p12 "$sandbox/test.p12" --p12-password-env TEST_P12_PASSWORD --no-notarize --no-timestamp
        [ $code -ne 0 ] && echo "$out" | grep -q "not a 'Developer ID Application' certificate" && [ ! -e "$sandbox/signed/plugin" ]; check $? "a certificate that is not a Developer ID is rejected by default"
    else
        echo "skip: this Mac would not sign with a throwaway certificate:"; echo "$out" | tail -3
    fi
else
    echo "skip: could not make a throwaway certificate"
fi
security list-keychains -d user | grep -q "signing.keychain" && r=1 || r=0; check $r "the temporary keychain is not left in the search list"

[ "$failures" -eq 0 ] && echo "all sign_and_notarize tests passed" || { echo "$failures failed"; exit 1; }
