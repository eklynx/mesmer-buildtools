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

Result: the artifact `signed-plugin` (30 days) holding `BrunnerDirect.xpl` (signed, notarized),
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
