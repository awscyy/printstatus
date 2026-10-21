# PrintStatus

A native macOS menu-bar app for Prusa Connect. macOS 14+, Apple silicon or Intel.

- **Green:** ready, idle, printing or finished.
- **Yellow:** paused, needs attention, busy, delayed telemetry, sign-in or connection trouble.
- **Red:** printer offline, error or stopped.
- Current job percentage appears beside the dot, including while paused. Previous jobs are not shown as active.
- The popover shows Prusa Connect’s model preview during an active or paused print, when available. Missing or failed previews leave progress visible without an image. Finished, offline and stale jobs never show a retained preview.
- Click the dot for printer name, status, progress, filename and estimated time remaining. Refreshes every 30 seconds and reconnects after sleep. Supports choosing a printer when the account has several.

## Run

Install the signed and notarized app with Homebrew:

```sh
brew install --cask awscyy/taps/printstatus
open -a PrintStatus
```

Update with `brew upgrade --cask awscyy/taps/printstatus`. Alternatively, download the ZIP from [GitHub Releases](https://github.com/awscyy/printstatus/releases/latest), unzip it and move PrintStatus.app into Applications.

The status popover opens automatically on first launch; subsequent launches leave it closed. Choose **Sign in to Prusa Connect** and sign in on Prusa’s own page. The app closes that window after retrieving your printers. Click the menu-bar dot whenever you want to see the status again.

Distribution builds produced with `--notarize` are Developer ID signed, notarized by Apple, and include a stapled ticket for offline verification. The default local development build is only ad-hoc signed; do not use it as the distribution ZIP.

To start automatically, add PrintStatus under **System Settings → General → Login Items**.

## Build and test

Requires Xcode and Swift 6. No third-party dependencies.

```sh
swift test
bash scripts/build-app.sh
open dist/PrintStatus.app
```

## Developer ID distribution

The default build is for local development and remains ad-hoc signed. To produce the distributable ZIP:

```sh
bash scripts/build-app.sh --notarize
```

This requires a **Developer ID Application** identity and matching private key in the signing keychain, plus a validated `notarytool` Keychain profile named `PrintStatus`. Apple Development and Apple Distribution identities do not qualify. The script defaults to team `CZ9S427J86`; `SIGNING_IDENTITY` and `NOTARY_PROFILE` can override the full certificate name and profile name. `SIGNING_KEYCHAIN` can select a different, already-unlocked keychain.

The release path enables hardened runtime, adds Apple's secure timestamp, submits to notarization and waits for acceptance, staples and validates the ticket, and verifies Gatekeeper acceptance. Only then does it replace `dist/PrintStatus.app` and `dist/PrintStatus.zip`. Apple's submission receipt and log are retained in `dist/notarization-submission.json` and `dist/notarization-log.json`. The ZIP is recreated after stapling so it also works offline.

On `mac-mini`, signing uses `~/Library/Keychains/PrintStatus-signing.keychain-db`. Its random password is stored in the login Keychain under `org.aidans.PrintStatus.signing-keychain`, and the script unlocks it automatically. Signing permissions are configured only for this dedicated keychain; existing development and distribution identities are unchanged. The `PrintStatus` notarization profile is also saved in Keychain. No signing secrets are stored in the repository or distribution ZIP.

The Account Holder issued the Developer ID Application certificate using this Mac's CSR. It expires on **19 November 2027**. Keep a secure backup of the signing keychain and its password; renewing the certificate requires Account Holder access. Public certificate and CSR copies are under `~/.config/printstatus/signing/`.

## CI and releases

Pushes to `main` run tests, workflow/script checks, and a universal build on the Mac mini. To release, update both version fields in `Resources/Info.plist`, commit and push to `main`, then push a matching version tag:

```sh
git tag v1.4
git push origin v1.4
```

The Release workflow checks that the tag belongs to `main` and matches the app version, runs tests, signs with Developer ID, waits for notarization, staples, and validates Gatekeeper acceptance. It publishes `PrintStatus-VERSION.zip` and `SHA256SUMS` to a GitHub release, downloads and validates the published ZIP, then updates `Casks/printstatus.rb` in [awscyy/homebrew-taps](https://github.com/awscyy/homebrew-taps) with that ZIP's SHA-256. The tap contains a **cask**, not a source-building formula, because this is a native app bundle.

For a failed release, rerun the job or run the Release workflow manually from `main` with the existing tag. Already-published ZIPs are reused, never replaced; rerunning an older release cannot downgrade the tap. Use a new version/tag to change a published app.

The repository-scoped runner is `mac-mini-printstatus`, labelled `self-hosted`, `macOS`, `ARM64`, `mac-mini`, and `printstatus`. It runs as `mini` through a LaunchAgent from `~/ci/actions-runner-printstatus`, with workspaces in `~/ci/printstatus`. Xcode/Swift, Homebrew, `gh`, `actionlint`, and Ruby must be on its PATH. The existing org runners and their public-repository restriction are unchanged.

Apple credentials remain in this Mac's Keychains. The app release uses the workflow's repository-scoped `GITHUB_TOKEN`. The tap push uses the runner account's existing `gh` Keychain login via Git's credential helper, because organisation policy disables deploy keys. That login needs write access to `awscyy/homebrew-taps`; no personal token or signing key is copied into GitHub Actions secrets.

**Trust boundary:** this is a persistent host with signing and GitHub credentials. Workflows intentionally do not run on pull requests or arbitrary branch pushes. Review contributions before merging; only trusted maintainers should have write access to `main`, tags, and workflows. A separate runner registration scopes scheduling, not OS-level access: it still runs as the same `mini` user.

## Authentication and privacy

The password is entered directly into Prusa’s hosted sign-in page; PrintStatus does not save it. WebKit stores cookies and Prusa’s access/refresh tokens in a dedicated local browser profile. **Sign out** clears that profile’s cookies and website data; it does not sign out other browsers or revoke other devices. No credentials are compiled into the app or included in the ZIP.

The app reads the same **unofficial** `/app/printers` endpoint as the Connect website, using its authenticated session and bearer token. Tokens stay inside WebKit; they are never passed to native code or logged. The official Connect page remains loaded to handle its own session refresh. Prusa can change this API; the app shows errors instead of presenting old data as live. Expired sessions may require signing in again. Only email/password Prusa sign-in is supported in the embedded window; third-party social sign-ins are not supported. The app never sends print, pause, temperature or cancellation commands.

Telemetry older than two minutes is shown as delayed and its percentage is hidden. A failed request hides cached progress immediately. “Last checked” is the last successful cloud request, not the printer’s last telemetry timestamp.

Model previews use the current job’s `preview_url`, fetched inside the same authenticated WebKit session. Only HTTPS URLs on `connect.prusa3d.com` are allowed, and redirects are rejected so authentication headers cannot reach another host. Only image bytes cross into native code. The current image is cached in memory by URL; sign-out clears it. Preview failures retry on the next status refresh without marking the printer unavailable.

## UI verification

```sh
mkdir -p .amp/in/artifacts
swift run PrintStatus --snapshots
```

This debug-only mode renders the real SwiftUI panel with deterministic fixtures (printing, paused, offline, idle, error, network failure and signed out). The release app contains neither these fixtures nor the debug login harness.

To include a model image in fixtures, add `--preview-fixture /path/to/model.png`. With a live session and a current job that has a preview, `--verify-login --verify-preview` verifies image loading, unavailable/unauthorized/corrupt responses, printer switching during a request, and retry recovery. It reads optional login credentials as JSON from stdin (use `{}` for an existing session), captures the live panel, and saves the preview as `.amp/in/artifacts/model-preview.png`. Add `--verify-failures` to also verify status failures and sign-out clearing the cached image; this signs out the test session.

Verify first-launch behavior with two real app launches using an isolated preferences domain (no printer requests or changes to normal app preferences):

```sh
defaults delete org.aidans.PrintStatus.LaunchVerification 2>/dev/null || true
swift run PrintStatus --verify-launch-open
swift run PrintStatus --verify-launch-closed
defaults delete org.aidans.PrintStatus.LaunchVerification
```

The launch checks require an unlocked, unobstructed desktop with a usable menu bar. They exit unsuccessfully if macOS does not expose the status-item window; rendering fixtures alone does not verify automatic opening.

The app icon source is `Resources/AppIcon.png`. The build script generates all standard and Retina icon sizes and bundles the resulting `AppIcon.icns` before signing.
