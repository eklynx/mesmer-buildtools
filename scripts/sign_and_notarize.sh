#!/usr/bin/env bash
# Sign one plugin file with a Developer ID certificate and have Apple notarize it. Specification:
# docs/signing.md (the source of truth for what this script guarantees and how it fails).
# Tests: tests/test-sign-and-notarize.sh.
#
#   scripts/sign_and_notarize.sh --file FILE --out FILE --identity NAME --team-id ID \
#       --p12 FILE --p12-password-env VAR \
#       --notary-key FILE --notary-key-id ID --notary-issuer ID
#
# The input file is never modified: the signed copy is written to --out. The certificate is
# imported into a throwaway keychain that is deleted on every exit. The file is signed and sent
# to Apple, never run. Written for macOS's stock bash 3.2.
set -uo pipefail

file="" out="" identity="" team="" p12="" pw_env="" notary_key="" notary_key_id="" notary_issuer=""
authority_prefix="Developer ID Application"
notarize=1
timestamp=1

usage() {
    sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<EOF

  --file FILE               the unsigned plugin (a Mach-O file); never modified
  --out FILE                where the signed copy is written
  --identity NAME           the certificate's name, e.g. "Developer ID Application: Name (TEAMID)"
  --team-id ID              the Apple team id the signature must carry
  --p12 FILE                the certificate and private key (a PKCS#12 file)
  --p12-password-env VAR    the NAME of the environment variable holding its password (never the password itself)
  --notary-key FILE         the App Store Connect API key (.p8) for notarytool
  --notary-key-id ID        its key id
  --notary-issuer ID        its issuer id
  --help                    this text

For tests and dry runs only (the release workflow never passes them):
  --no-notarize             sign but do not send to Apple (then the notary options are not needed)
  --no-timestamp            skip Apple's timestamp server
  --authority-prefix TEXT   what the certificate's authority must start with (default "$authority_prefix")
EOF
}

die() { echo "sign_and_notarize.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --no-notarize) notarize=0; shift ;;
        --no-timestamp) timestamp=0; shift ;;
        --help|-h) usage; exit 0 ;;
        --file|--out|--identity|--team-id|--p12|--p12-password-env|--notary-key|--notary-key-id|--notary-issuer|--authority-prefix)
            [ $# -ge 2 ] || die "$1 needs a value"
            case "$1" in
                --file) file="$2" ;; --out) out="$2" ;; --identity) identity="$2" ;; --team-id) team="$2" ;;
                --p12) p12="$2" ;; --p12-password-env) pw_env="$2" ;; --notary-key) notary_key="$2" ;;
                --notary-key-id) notary_key_id="$2" ;; --notary-issuer) notary_issuer="$2" ;; --authority-prefix) authority_prefix="$2" ;;
            esac
            shift 2 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

[ -n "$file" ] || die "--file is required"
[ -n "$out" ] || die "--out is required"
[ -n "$identity" ] || die "--identity is required"
[ -n "$team" ] || die "--team-id is required"
[ -n "$p12" ] || die "--p12 is required"
[ -n "$pw_env" ] || die "--p12-password-env is required"
if [ "$notarize" -eq 1 ]; then
    [ -n "$notary_key" ] && [ -n "$notary_key_id" ] && [ -n "$notary_issuer" ] \
        || die "--notary-key, --notary-key-id and --notary-issuer are required (or --no-notarize for a dry run)"
fi
[ "$(uname -s)" = "Darwin" ] || die "this script signs for macOS and must run on macOS"
for tool in codesign security xcrun ditto lipo; do command -v "$tool" >/dev/null 2>&1 || die "$tool not found"; done
[ -f "$file" ] || die "no such file: $file"
lipo -archs "$file" >/dev/null 2>&1 || die "$file is not a Mach-O file"
[ -f "$p12" ] || die "no such certificate file: $p12"
[ -n "${!pw_env:-}" ] || die "the environment variable $pw_env is empty or not set"
if [ "$notarize" -eq 1 ]; then [ -f "$notary_key" ] || die "no such notary key file: $notary_key"; fi

work="$(mktemp -d "${TMPDIR:-/tmp}/sign.XXXXXX")" || die "cannot make a temporary folder"
keychain="$work/signing.keychain-db"
original_keychains="$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')"
cleanup() {
    # shellcheck disable=SC2086
    security list-keychains -d user -s $original_keychains >/dev/null 2>&1
    security delete-keychain "$keychain" >/dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT

kc_password="$(head -c 24 /dev/urandom | base64)"
security create-keychain -p "$kc_password" "$keychain" || die "could not create the temporary keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$kc_password" "$keychain" || die "could not unlock the temporary keychain"
security import "$p12" -k "$keychain" -P "${!pw_env}" -T /usr/bin/codesign -f pkcs12 >/dev/null 2>&1 \
    || die "could not import $p12 (wrong password or not a PKCS#12 file)"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kc_password" "$keychain" >/dev/null 2>&1 \
    || die "could not allow codesign to use the imported key"
# shellcheck disable=SC2086
security list-keychains -d user -s "$keychain" $original_keychains >/dev/null 2>&1

mkdir -p "$(dirname "$out")"
cp "$file" "$out" || die "could not copy $file to $out"

ts_flag="--timestamp"
[ "$timestamp" -eq 1 ] || ts_flag="--timestamp=none"
codesign --force --options runtime "$ts_flag" --keychain "$keychain" --sign "$identity" "$out" \
    || { rm -f "$out"; die "codesign failed (is --identity the certificate's exact name?)"; }
codesign --verify --strict --verbose=2 "$out" || { rm -f "$out"; die "the signature does not verify"; }

details="$(codesign -dvv "$out" 2>&1)"
authority="$(echo "$details" | awk -F= '/^Authority=/{print $2; exit}')"
signed_team="$(echo "$details" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
case "$authority" in "$authority_prefix"*) ;; *) rm -f "$out"; die "signed by '$authority', not a '$authority_prefix' certificate" ;; esac
[ "$signed_team" = "$team" ] || { rm -f "$out"; die "signed by team '$signed_team', expected '$team'"; }
echo "$details" | grep -q "flags=0x[0-9a-f]*(runtime)" || { rm -f "$out"; die "the hardened runtime flag is not set"; }
echo "signed: $authority, team $signed_team"

if [ "$notarize" -eq 1 ]; then
    ditto -c -k "$out" "$work/notarize.zip" || { rm -f "$out"; die "could not zip the file for notarization"; }
    result="$(xcrun notarytool submit "$work/notarize.zip" --key "$notary_key" --key-id "$notary_key_id" --issuer "$notary_issuer" --wait --output-format json 2>&1)"
    status="$(echo "$result" | plutil -extract status raw -o - - 2>/dev/null)"
    id="$(echo "$result" | plutil -extract id raw -o - - 2>/dev/null)"
    if [ "$status" != "Accepted" ]; then
        [ -n "$id" ] && xcrun notarytool log "$id" --key "$notary_key" --key-id "$notary_key_id" --issuer "$notary_issuer" 2>&1 | head -60
        rm -f "$out"
        die "Apple did not accept the file (status: ${status:-unknown}); no signed file is left"
    fi
    echo "notarized: Apple accepted submission $id (a bare plugin cannot be stapled; Gatekeeper checks Apple online)"
fi

echo "$(shasum -a 256 "$out" | awk '{print $1}')  $(basename "$out")"
