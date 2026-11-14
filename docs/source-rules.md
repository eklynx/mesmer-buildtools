# Source rules: specification

`scripts/resolve_source.sh` decides what the workflow may build and pins it to one commit.
`tests/test-resolve-source.sh` checks each statement (with a fake `gh`).

```
scripts/resolve_source.sh --repo OWNER/NAME --ref REF
```

On success it prints `repo=`, `ref=`, `sha=` and `default_branch=` lines (the `GITHUB_OUTPUT`
form) and exits 0. On failure it prints `resolve_source.sh: <reason>` and exits non-zero, before any
build or any secret is involved.

## Rules

1. **Allowlist.** Only `antialias/mesmer` and `eklynx/mesmer`. Anything else, including a look-alike
   name, is refused.
2. **Plain refs.** A ref starts with a letter or digit and holds only letters, digits, `.`, `_`, `-`
   and `/`, with no `..`. Options, spaces, quotes and shell characters are refused.
3. **A real branch or tag, never a SHA.** The ref must be the name of a branch or tag that exists in
   that repository itself (checked through the refs API, which answers only for the repository's own refs).
   A bare commit SHA, full or abbreviated, is refused: GitHub can resolve a commit that exists only in
   another fork of the repository's network through the parent's API, so a SHA proves nothing about where
   the commit came from.
4. **One commit.** The name is resolved to a commit and the build uses that SHA, never the name, so a
   branch that moves during the run cannot change what is signed. A caller that knows the commit it wants
   (a release) checks the finished plugin's `provenance.json` names that commit.
5. **Ref rule for `antialias/mesmer`.** It is not the owner's repository, so its SHA must be on its
   default branch or carry a tag. An unreviewed contributor branch is never signed. `eklynx/mesmer`
   (the owner's own) accepts any ref.

To sign another repository, change `ALLOWED_REPOS` (and `RULED_REPOS`) in the script, the `repo`
choice list in the workflow, and this page together.
