# One-time setup

You need an Apple Developer Program membership. Nothing here goes through chat or into the
repository: you create the secrets yourself.

1. **Certificate.** In the Apple Developer site create a **Developer ID Application** certificate
   (Certificates, Identifiers & Profiles). Install it, then in Keychain Access export the certificate
   with its private key as a `.p12` with a password. Note its exact name
   (`security find-identity -v -p codesigning`), e.g. `Developer ID Application: Your Name (TEAMID)`,
   and your 10-character team id.
2. **Notary API key.** In App Store Connect, Users and Access, Integrations, create a key (Developer role
   is enough). Download the `.p8` once; note the key id and the issuer id.
3. **Repository settings** (Settings, `eklynx/mesmer-buildtools`): Actions, General: workflow permissions
   read-only; "Require approval for all outside collaborators"; no other collaborators with write access;
   protect `main`.
4. **Environment** `code-signing` (Settings, Environments): deployment branches limited to `main`; no
   required reviewers (the workflow is meant to run unattended; adding a reviewer later is a setting
   change). Then, in a terminal:
   ```
   gh secret set DEVELOPER_ID_P12_BASE64 --env code-signing -R eklynx/mesmer-buildtools < <(base64 -i developer-id.p12)
   gh secret set DEVELOPER_ID_P12_PASSWORD --env code-signing -R eklynx/mesmer-buildtools
   gh secret set NOTARY_API_KEY_P8 --env code-signing -R eklynx/mesmer-buildtools < AuthKey_XXXX.p8
   gh variable set SIGNING_IDENTITY --env code-signing -R eklynx/mesmer-buildtools --body "Developer ID Application: Your Name (TEAMID)"
   gh variable set TEAM_ID --env code-signing -R eklynx/mesmer-buildtools --body TEAMID
   gh variable set NOTARY_KEY_ID --env code-signing -R eklynx/mesmer-buildtools --body KEYID
   gh variable set NOTARY_ISSUER_ID --env code-signing -R eklynx/mesmer-buildtools --body ISSUER-UUID
   ```
5. Delete the `.p12` and `.p8` from your Downloads folder once stored (keep a backup of the certificate
   somewhere private). Use a passkey or hardware key on your GitHub account.

## Running it

Actions, `sign-mesmer`, Run workflow: pick the repository and the branch or tag. Tick `dry_run` first to
see the build and checks without signing. When it finishes, download `signed-plugin` from the run and
put `BrunnerDirect.xpl` into the plugin's `mac_x64/` folder (for a release, repackage with the
project's `src/scripts/package_release.sh --win DIR --mac DIR`: replacing the file inside a published
zip would break that zip's checksum).

## Updating what the plugin may do

If a build fails on a new library or a watched import you have read and accept, add the `lib` or
`symbol` line to `baselines/mesmer-allow.txt` in a commit here. To refresh the import snapshot:
`scripts/verify_plugin.sh BrunnerDirect.xpl --allow baselines/mesmer-allow.txt --print-imports > baselines/mesmer-imports.txt`.
