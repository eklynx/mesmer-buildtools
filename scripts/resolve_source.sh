#!/usr/bin/env bash
# Decide whether a repository and ref may be built and signed, and pin the ref to one commit.
# Specification: docs/source-rules.md (the source of truth for the allowlist and the ref rule).
# Tests: tests/test-resolve-source.sh.
#
#   scripts/resolve_source.sh --repo OWNER/NAME --ref REF [--help]
#
# Prints repo=, ref=, sha= and default_branch= lines (the form GITHUB_OUTPUT takes) and exits 0, or
# prints `resolve_source.sh: <reason>` to stderr and exits non-zero. Needs the gh CLI (a token is
# enough: both repositories are public) and never clones or runs anything from the repository.
set -uo pipefail

# The only repositories that may be built and signed.
ALLOWED_REPOS="antialias/mesmer eklynx/mesmer"
# Repositories that are not mine: their SHA must be on the default branch or carry a tag, so an
# unreviewed contributor branch can never be signed. (My own repository allows any ref.)
RULED_REPOS="antialias/mesmer"

repo=""
ref=""

usage() {
    sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<EOF

  --repo OWNER/NAME   one of: $ALLOWED_REPOS
  --ref REF           a branch, tag or commit SHA of that repository
EOF
}

die() { echo "resolve_source.sh: $*" >&2; exit 1; }
word_in() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --repo|--ref)
            [ $# -ge 2 ] || die "$1 needs a value"
            case "$1" in --repo) repo="$2" ;; --ref) ref="$2" ;; esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

[ -n "$repo" ] || die "--repo is required"
[ -n "$ref" ] || die "--ref is required"
word_in "$repo" "$ALLOWED_REPOS" || die "repository $repo is not on the allowlist ($ALLOWED_REPOS)"
echo "$ref" | grep -E -q '^[A-Za-z0-9][A-Za-z0-9._/-]*$' || die "ref '$ref' has characters a branch, tag or SHA does not"
case "$ref" in *..*) die "ref '$ref' contains '..'" ;; esac
command -v gh >/dev/null 2>&1 || die "the gh CLI is not installed"

sha="$(gh api "repos/$repo/commits/$ref" --jq .sha 2>/dev/null)" || sha=""
echo "$sha" | grep -E -q '^[0-9a-f]{40}$' || die "ref '$ref' does not resolve to a commit in $repo"
default_branch="$(gh api "repos/$repo" --jq .default_branch 2>/dev/null)" || default_branch=""
[ -n "$default_branch" ] || die "could not read $repo's default branch"

if word_in "$repo" "$RULED_REPOS"; then
    status="$(gh api "repos/$repo/compare/$default_branch...$sha" --jq .status 2>/dev/null)" || status=""
    case "$status" in
        identical|behind) ;;   # the commit is on the default branch
        *)
            tagged="$(gh api "repos/$repo/tags" --paginate --jq '.[].commit.sha' 2>/dev/null | grep -F -x -c "$sha")"
            [ "${tagged:-0}" -gt 0 ] || die "$sha is not on $repo's default branch ($default_branch) and has no tag; only reviewed commits are signed"
            ;;
    esac
fi

echo "repo=$repo"
echo "ref=$ref"
echo "sha=$sha"
echo "default_branch=$default_branch"
