# Releases

Use **master**. `.github/workflows/release.yml` uses the built-in `GITHUB_TOKEN`;
no personal token is needed for release assets in this repository.

## GitHub setup

Enable Actions and allow the pinned official `actions/checkout`,
`upload-artifact`, and `download-artifact` actions. The repository/organization
must permit the publish job's `contents: write` permission.

With repository Actions variable `NOTARIZE_RELEASES` unset or `false`, builds are
ad hoc signed and clearly marked **unnotarized**. Users may need to approve their
first launch in macOS. Managed Macs may prohibit that exception.

## Developer ID signing and notarization

For normal Gatekeeper installation, use an Apple Developer Program membership
and a **Developer ID Application** certificate including its private key. Add
these repository Actions secrets:

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | Base64 of an exported Developer ID Application `.p12` including the private key |
| `MACOS_CERTIFICATE_PASSWORD` | Password used to export the `.p12` |
| `MACOS_SIGNING_IDENTITY` | Exact Developer ID Application identity name or its certificate SHA-1 |
| `APPLE_ID` | Apple ID authorized for the developer team |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for that Apple ID |
| `APPLE_TEAM_ID` | Apple Developer Program team ID |

Set Actions **variable** `NOTARIZE_RELEASES` to `true`. Credentials belong in
repository secrets, never in source, workflow YAML, issues, or release assets.

The workflow imports the certificate into a temporary keychain, signs the app
with hardened runtime and a secure timestamp, notarizes/staples the app, then
packages/signs/notarizes/staples the DMG. Checksums are computed after stapling.
An `always()` step restores the keychain search list and removes temporary
credentials. Missing credentials or rejected notarization fail the release;
requested notarization never falls back silently to an unnotarized build.

Apple references: [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
and [customizing the workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Publish

1. Update `CFBundleShortVersionString` in `Info.plist` (numeric `major.minor.patch`),
   increment `CFBundleVersion`, and update `CHANGELOG.md`.
2. Run:

   ```sh
   bash test.sh
   bash build.sh
   bash package-dmg.sh
   bash Tools/verify-package.sh
   ```

3. Commit reviewed changes on **master** and push. For the prepared version:

   ```sh
   git push origin master
   git tag v1.0.0
   git push origin v1.0.0
   ```

4. The tag must match `Info.plist`. CI tests/builds on Intel and Apple Silicon.
   The release job creates a draft, uploads the universal DMG, `SHA256SUMS.txt`
   and `RELEASE-INFO.txt`, then publishes. Re-runs can finish a draft; an already
   published release is left unchanged. Fix published builds with a new version.

Before tagging, run the Release workflow manually from **master** to validate
the build/sign/package path. Manual runs upload artifacts without publishing.

Download the DMG and checksums into one directory and verify:

```sh
shasum -a 256 --check SHA256SUMS.txt
```

For a notarized release:

```sh
xcrun stapler validate CONNECT6Link-1.0.0-universal.dmg
```

The app targets macOS 13+, not older releases. Do not claim support for additional
firmware without protocol and hardware validation. CI runs on both CPU types;
USB behavior still requires a real CONNECT 6.

Private builds before this public release used a different app identifier.
Before replacing one, turn off its Open at login setting and quit it. The new
app migrates the saved linking mode; enable Open at login again after installing
the public build in Applications.
