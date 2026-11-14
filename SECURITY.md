# Security

This repository holds the signing pipeline for Mesmer's macOS plugin. Its design: code from the
project never runs in a job that can see the signing key, only the allowlisted repositories can be
built, and only the owner can start a run. See [docs/signing.md](docs/signing.md) and
[docs/source-rules.md](docs/source-rules.md).

What it does **not** promise: that signed code is harmless. Automated checks cannot catch deliberately
malicious code that uses only the allowed libraries and imports. There is no manual approval step, by the
owner's choice; the allowlist, the ref rule, the import checks, CodeQL, ClamAV and Apple's notarization
are the gates.

Report a problem privately through GitHub's "Report a vulnerability" on this repository.
