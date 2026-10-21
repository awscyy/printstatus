#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARIZE=false
case "${1:-}" in
    "") ;;
    --notarize) NOTARIZE=true ;;
    *) echo "Usage: bash scripts/build-app.sh [--notarize]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
    echo "Usage: bash scripts/build-app.sh [--notarize]" >&2
    exit 2
fi

IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: The Trustee for Mumu, Lulu & Co. (CZ9S427J86)}"
PROFILE="${NOTARY_PROFILE:-PrintStatus}"
KEYCHAIN="${SIGNING_KEYCHAIN:-$HOME/Library/Keychains/PrintStatus-signing.keychain-db}"
if "$NOTARIZE"; then
    if [ ! -f "$KEYCHAIN" ]; then
        echo "Missing signing keychain: $KEYCHAIN" >&2
        exit 1
    fi
    if [ -z "${SIGNING_KEYCHAIN:-}" ]; then
        security unlock-keychain -p "$(security find-generic-password \
            -a mini -s org.aidans.PrintStatus.signing-keychain -w)" "$KEYCHAIN"
    fi
    if [[ "$IDENTITY" != "Developer ID Application: "* ]] ||
        ! security find-identity -v -p codesigning "$KEYCHAIN" | grep -Fq "\"$IDENTITY\""; then
        echo "Missing signing identity: $IDENTITY" >&2
        echo "Import the Developer ID Application certificate and matching private key first." >&2
        exit 1
    fi
    # Check authentication before spending time building or replacing an existing ZIP.
    xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null
fi

swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
mkdir -p dist
STAGE="$(mktemp -d "$PWD/dist/.build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/PrintStatus.app"
ICONSET="$STAGE/AppIcon.iconset"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONSET"
cp "$BIN_DIR/PrintStatus" "$APP/Contents/MacOS/PrintStatus"
cp Resources/Info.plist "$APP/Contents/Info.plist"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

if "$NOTARIZE"; then
    codesign --force --options runtime --timestamp --keychain "$KEYCHAIN" --sign "$IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGE/PrintStatus.zip"

if "$NOTARIZE"; then
    xcrun notarytool submit "$STAGE/PrintStatus.zip" --keychain-profile "$PROFILE" \
        --wait --output-format json > dist/notarization-submission.json
    SUBMISSION_ID="$(plutil -extract id raw -o - dist/notarization-submission.json)"
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" dist/notarization-log.json
    STATUS="$(plutil -extract status raw -o - dist/notarization-submission.json)"
    if [ "$STATUS" != "Accepted" ]; then
        echo "Apple notarization status: $STATUS. See dist/notarization-log.json." >&2
        exit 1
    fi
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    codesign --verify --deep --strict "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
    # The distributed ZIP must contain the stapled app, not the submitted version.
    rm "$STAGE/PrintStatus.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGE/PrintStatus.zip"
fi

rm -rf dist/PrintStatus.app
mv "$APP" dist/PrintStatus.app
mv "$STAGE/PrintStatus.zip" dist/PrintStatus.zip
if "$NOTARIZE"; then
    echo "Built dist/PrintStatus.zip (universal, Developer ID signed, notarized and stapled)"
else
    echo "Built dist/PrintStatus.zip (universal, ad-hoc signed; use --notarize for distribution)"
fi
