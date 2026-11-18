# mesmer-buildtools

Builds, vets and signs the macOS plugin of [Mesmer](https://github.com/antialias/mesmer), the X-Plane 12
plugin for Brunner yokes, with the owner's own Developer ID. It is separate from the project on purpose:
the project's workflows can never reach the signing key.

Run the `sign-mesmer` workflow with a repository (`antialias/mesmer` or `eklynx/mesmer`) and a branch or
tag. It builds that exact commit, checks that the result is an X-Plane plugin of the expected shape,
scans the source and the plugin, and only then signs and notarizes it and returns the signed
`BrunnerDirect.xpl` as an artifact.

| Page | What it specifies |
|---|---|
| [docs/signing.md](docs/signing.md) | the workflow's jobs, the signing script, what it returns |
| [docs/verification.md](docs/verification.md) | every check on the plugin |
| [docs/source-rules.md](docs/source-rules.md) | what may be built: the allowlist and the ref rule |
| [docs/setup.md](docs/setup.md) | the one-time certificate, key and repository setup |
| [docs/watch-list.md](docs/watch-list.md) | open upstream issues to keep an eye on |
| [SECURITY.md](SECURITY.md) | the threat model and its limits |

Tests (macOS): `tests/test-verify-plugin.sh`, `tests/test-sign-and-notarize.sh`,
`tests/test-check-secrets.sh`, `tests/test-remind-expiry.sh`, `tests/test-resolve-source.sh`.

Licensed under the Apache License 2.0 (see `LICENSE`).
