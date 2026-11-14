# Signing and the workflow: specification

`scripts/sign_and_notarize.sh` is the interface to signing;
`.github/workflows/sign-mesmer.yml` is the pipeline. `tests/test-sign-and-notarize.sh` checks the script
(notarization itself needs Apple and is covered by the first real run).

## The workflow

Started by hand (`workflow_dispatch`) by the owner. Inputs: `repo` (a choice of the allowlist), `ref`,
optional `base` (an older ref to diff against, default the newest `v*` tag) and `dry_run` (build and vet,
do not sign).

| Job | Secrets | What it does |
|---|---|---|
| `plan` | none | `resolve_source.sh`: allowlist, plain ref, ref rule, one SHA |
| `build-and-vet` | none | builds the SHA with the project's `build_macos.sh`, `verify_plugin.sh`, ClamAV, a run summary, uploads `unsigned-xpl` |
| `codeql` | none | CodeQL C++ (`security-extended`, `build-mode: none`: it reads the source without building it, because tracing the macOS build hung) on the source; any `error`-level result fails the job |
| `sign` | Environment `code-signing` | only if all of the above passed: checks the file's SHA-256 against the vetted one, runs `verify_plugin.sh` again, signs, notarizes, writes `provenance.json`, attests, uploads `signed-plugin` |

Code from the project runs only in the jobs without secrets. The `sign` job runs only this repository's
scripts, and only inspects the plugin (`lipo`, `otool`, `nm`, `codesign`); it never loads or runs it.
There is no manual approval; the automated checks and the source rules are the gate.

Result: the artifact `signed-plugin` (kept 3 days; `unsigned-xpl` and `codeql-sarif` too) holding `BrunnerDirect.xpl` (signed, notarized),
`BrunnerDirect.xpl.sha256` and `provenance.json` (source repository, ref, commit, unsigned and signed
SHA-256, signer, run URL, time). The signed file also has a build provenance attestation:
`gh attestation verify BrunnerDirect.xpl --repo eklynx/mesmer-buildtools`.

## The script

```
scripts/sign_and_notarize.sh --file FILE --out FILE --identity NAME --team-id ID \
    --p12 FILE --p12-password-env VAR --notary-key FILE --notary-key-id ID --notary-issuer ID
```

The input is never modified: the signed copy is `--out`. The password is passed as the name of an
environment variable, never on the command line. Steps: import the certificate into a throwaway
keychain (deleted on every exit, search list restored); `codesign --force --options runtime --timestamp`;
`codesign --verify --strict`; check the signature's authority starts with `Developer ID Application`,
its team is `--team-id`, and the hardened runtime flag is set; zip and `notarytool submit --wait`;
require `Accepted`. A bare plugin cannot be stapled, so Gatekeeper checks Apple online.

Failures print `sign_and_notarize.sh: <reason>`, exit non-zero and leave **no** signed file: a missing
required option, a missing input, certificate or key file, an unset password variable, an input that is
not Mach-O, a certificate that will not import, a failed `codesign`, a wrong authority or team, a missing
hardened runtime flag, or notarization that is not `Accepted` (the notary log is printed).

`--no-notarize`, `--no-timestamp` and `--authority-prefix` exist for tests and dry runs; the workflow
never passes them.

## Checking the secrets

`scripts/check_secrets.sh` and the `check-secrets` workflow (run by hand, in the `code-signing`
Environment) test the stored secrets without signing or notarizing anything. They print only pass/fail
lines and the certificate's expiry date, never a value (the log of a public repository is public).
Tests: `tests/test-check-secrets.sh`.

It checks that: `TEAM_ID`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID` have the right shape and
`SIGNING_IDENTITY` is a `Developer ID Application` name ending in the team id; `NOTARY_API_KEY_P8` is a
whole, readable private key; the `.p12` imports with its password, holds a private key for exactly
`SIGNING_IDENTITY`, has not expired (a note if it expires within 30 days), carries the team id, and was
issued by Apple's Developer ID authority; and Apple accepts the notary key, key id and issuer id together
(a read-only call listing past submissions). Any failure exits non-zero.

## Expiry reminder

The `cert-expiry` workflow runs every Monday (14:00 UTC) and can be run by hand. Its `check` job (the
`code-signing` Environment) runs `check_secrets.sh` and reports only the whole days left and the expiry
date (`expires_in_days=`, `expires_on=`). Its `remind` job has no secrets and `issues: write`: when 15
days or fewer are left (the `threshold_days` input of a manual run overrides this, to test it) it runs
`scripts/remind_expiry.sh`, which opens an issue labelled `certificate-expiry`, assigned to the repository
owner, so GitHub emails them. At most one reminder issue is open: later runs update it. An expired
certificate gets an "expired" issue (the check itself fails then too, and GitHub emails the person who last
edited the schedule). Tests: `tests/test-remind-expiry.sh` (a fake `gh`).

GitHub disables scheduled workflows in a public repository with no activity for 60 days; a commit or a
manual run restarts them. Apple also emails the account holder before a Developer ID certificate expires.
Binaries already signed with a timestamp stay valid after the certificate expires.

## Calling it from a release workflow

A project's release workflow can use this pipeline without any person starting it. The contract, which a
different signing repository could also follow:

- Start `sign-mesmer.yml` with `repo` (the repository being released) and `ref` (the release commit's full
  SHA). Only the allowlisted repositories are accepted ([source-rules.md](source-rules.md)).
- The run's title is `sign <repo>@<ref>`, so the caller can find its own run among others.
- On success the run uploads the artifact `signed-plugin`: `BrunnerDirect.xpl`, `BrunnerDirect.xpl.sha256`
  and `provenance.json` (`source.repository`, `source.commit`, `notarized`, `signer`, `run`, hashes). The
  caller must check `provenance.json` names the repository and commit it asked for, that the hash matches the
  file, and (`gh attestation verify`) that the file was attested by this repository.
- Any other outcome is a failure the caller must treat as one.

The caller needs a token that may start workflows and read artifacts here: a fine-grained personal access
token for this repository only, with **Actions: read and write** and nothing else. The allowlist does not
authenticate the caller, it limits what a token can make this repository build; a token can never read the
signing key. Artifacts are kept for 3 days, long enough for the caller to fetch them in the same run.
