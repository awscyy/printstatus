#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?Usage: publish-release.sh vVERSION}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || exit 2
VERSION="${TAG#v}"
test "$VERSION" = "$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
test "$(git rev-parse HEAD)" = "$(git rev-parse "$TAG^{commit}")"
export GH_REPO="awscyy/printstatus"
ARCHIVE="PrintStatus-$VERSION.zip"
mkdir -p dist

# Published assets are immutable. A retry uses the original ZIP, not a re-signed build.
if gh release view "$TAG" --json isDraft > dist/release.json 2>/dev/null &&
    [ "$(plutil -extract isDraft raw dist/release.json)" = false ]; then
    gh release download "$TAG" --pattern "$ARCHIVE" --dir dist --clobber
else
    bash scripts/build-app.sh --notarize
    cp dist/PrintStatus.zip "dist/$ARCHIVE"
    if gh release view "$TAG" --json isDraft > dist/release.json 2>/dev/null; then
        # Recheck after building: a transient API failure must never overwrite a public asset.
        test "$(plutil -extract isDraft raw dist/release.json)" = true
    else
        gh release create "$TAG" --verify-tag --draft --title "PrintStatus $VERSION" \
            --notes "Native macOS menu-bar status for Prusa Connect. Requires macOS 14 or later; supports Apple silicon and Intel. Developer ID signed, notarized and stapled. Install with: brew install --cask awscyy/taps/printstatus"
    fi
    (cd dist && shasum -a 256 "$ARCHIVE" > SHA256SUMS)
    gh release upload "$TAG" "dist/$ARCHIVE" dist/SHA256SUMS --clobber
    gh release edit "$TAG" --draft=false
    # The cask must hash the bytes GitHub actually serves.
    gh release download "$TAG" --pattern "$ARCHIVE" --dir dist --clobber
fi

VERIFY="$(mktemp -d "$PWD/dist/.verify.XXXXXX")"
trap 'rm -rf "$VERIFY"' EXIT
ditto -x -k "dist/$ARCHIVE" "$VERIFY"
test "$(plutil -extract CFBundleShortVersionString raw "$VERIFY/PrintStatus.app/Contents/Info.plist")" = "$VERSION"
codesign --verify --deep --strict "$VERIFY/PrintStatus.app"
xcrun stapler validate "$VERIFY/PrintStatus.app"
spctl --assess --type execute --verbose=2 "$VERIFY/PrintStatus.app"
for arch in arm64 x86_64; do
    lipo -verify_arch "$arch" "$VERIFY/PrintStatus.app/Contents/MacOS/PrintStatus"
done
