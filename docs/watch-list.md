# Open issues to keep an eye on

Problems in things this repository depends on that are not ours to fix. Each entry says what it is, where
it shows up, how likely it is to hurt, and what to do when it moves. Check the upstream links now and then,
and whenever a pinned action is updated. Remove an entry once it is resolved.

## `actions/download-artifact` prints a `Buffer()` deprecation warning (DEP0005)

Added 2026-11-18.

**What.** Every download with `actions/download-artifact` v8 prints:

```
(node:NNNN) [DEP0005] DeprecationWarning: Buffer() is deprecated due to security and usability issues.
Please use the Buffer.alloc(), Buffer.allocUnsafe(), or Buffer.from() methods instead.
```

The action's bundle includes `@actions/artifact` 6.2.1, whose extraction chain reaches `unzip-stream` 0.3.4,
then `binary` 0.3.0 and `buffers` 0.1.1. Those still call the deprecated `Buffer()` constructor, and GitHub
runs the action on Node 24, which reports it. The code is the action's, not ours.

**Where it shows up.**
- This repository: `.github/workflows/sign-mesmer.yml`, the step that downloads the built plugin before
  signing (`actions/download-artifact`, pinned to v8.0.2).
- The Mesmer project: `.github/workflows/release.yml`, the `package` job's three "Download the ... plugin"
  steps (same action, same pin).

**Risk.** Low today. It is only a warning, and the downloads succeed. It would become an error if Node
stops accepting the old constructor, or if a workflow sets `--throw-deprecation` in `NODE_OPTIONS` (neither
repository does). A reproduction on Node 26.13.1 still only warns without that flag.

**Upstream.**
- Issue [actions/download-artifact#484](https://github.com/actions/download-artifact/issues/484), open: names the dependency chain above.
- Pull request [actions/download-artifact#490](https://github.com/actions/download-artifact/pull/490), open and not merged: patches those dependencies and adds tests.
- Older reports of the same warning: #283, #305, #327, #381.
- Status on 2026-11-18: v8.0.2 (2026-10-07) is the newest release and still has it.

**What to do when it moves.**
1. When a release of `actions/download-artifact` contains the fix, bump the pinned commit in both
   repositories (this one and Mesmer's `release.yml`), keeping the version in the trailing comment.
2. Run `sign-mesmer` with `dry_run` and a throwaway Mesmer tag, and confirm the warning is gone.
3. If it turns into an error first and no fix is out, the fallback considered is replacing the download
   steps with `gh run download` (no Node involved). The download steps handle the plugin that gets signed, so
   whatever replaces them must keep verifying the artifact's digest, which the action does today.
   Do not pin an unmerged pull request: it would run unreviewed third-party code in the signing pipeline.
