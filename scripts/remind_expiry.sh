#!/usr/bin/env bash
# Open (or update) a GitHub issue when the signing certificate is close to expiry. Specification:
# docs/signing.md ("Expiry reminder"). Tests: tests/test-remind-expiry.sh.
#
#   scripts/remind_expiry.sh --days N --expires YYYY-MM-DD --threshold DAYS --repo OWNER/NAME --assignee USER
#
# Holds no secret: the days and date come from check_secrets.sh, and only the gh CLI with a token
# that may write issues is needed. At most one reminder issue is open at a time.
set -uo pipefail

days="" expires="" threshold="" repo="" assignee=""
LABEL="certificate-expiry"

usage() {
    sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() { echo "remind_expiry.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --days|--expires|--threshold|--repo|--assignee)
            [ $# -ge 2 ] || die "$1 needs a value"
            case "$1" in --days) days="$2" ;; --expires) expires="$2" ;; --threshold) threshold="$2" ;; --repo) repo="$2" ;; --assignee) assignee="$2" ;; esac
            shift 2 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

for need in days expires threshold repo assignee; do [ -n "${!need}" ] || die "--$need is required"; done
echo "$days" | grep -E -q '^-?[0-9]+$' || die "--days must be a whole number"
echo "$threshold" | grep -E -q '^[0-9]+$' || die "--threshold must be a whole number"
echo "$expires" | grep -E -q '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || die "--expires must be YYYY-MM-DD"
command -v gh >/dev/null 2>&1 || die "the gh CLI is not installed"

if [ "$days" -gt "$threshold" ]; then
    echo "the certificate expires on $expires, in $days days: more than $threshold, no reminder"
    exit 0
fi

if [ "$days" -lt 0 ]; then
    title="Developer ID certificate expired on $expires"
    lead="The Developer ID Application certificate **expired on $expires**. New builds cannot be signed until it is replaced."
else
    title="Developer ID certificate expires on $expires ($days days left)"
    lead="The Developer ID Application certificate expires on **$expires**, in **$days days**. Signing stops working then; binaries already signed with a timestamp stay valid."
fi
body="$lead

To renew: create a new Developer ID Application certificate in the Apple Developer site, export it with its private key as a .p12, and replace the \`DEVELOPER_ID_P12_BASE64\` and \`DEVELOPER_ID_P12_PASSWORD\` secrets and the \`SIGNING_IDENTITY\` variable of the \`code-signing\` Environment if its name changed ([docs/setup.md](../blob/main/docs/setup.md)). Then run the \`check-secrets\` workflow to confirm.

This issue is kept up to date by the \`cert-expiry\` workflow and can be closed once the certificate is renewed."

gh label create "$LABEL" --repo "$repo" --color B60205 --description "The signing certificate is close to expiry" >/dev/null 2>&1 || true
existing="$(gh issue list --repo "$repo" --label "$LABEL" --state open --json number --jq '.[0].number' 2>/dev/null)"
if [ -n "$existing" ]; then
    gh issue edit "$existing" --repo "$repo" --title "$title" --body "$body" >/dev/null || die "could not update issue #$existing"
    echo "updated issue #$existing: $title"
else
    gh issue create --repo "$repo" --title "$title" --body "$body" --label "$LABEL" --assignee "$assignee" >/dev/null || die "could not create the issue"
    echo "opened an issue: $title"
fi
