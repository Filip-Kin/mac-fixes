#!/bin/bash
# Cut a GitHub release: bump version, build, zip the app, publish as latest.
# Usage: ./release.sh <version>   e.g.  ./release.sh 1.1.0
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: ./release.sh <version>   (e.g. 1.1.0)" >&2
    exit 1
fi
TAG="v$VERSION"

APP="Filip's Mac Fixes.app"
BUILD="build"
ZIP="$BUILD/Filips-Mac-Fixes-$TAG-arm64.zip"

if git rev-parse "$TAG" >/dev/null 2>&1 || gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release $TAG already exists. Bump to a new version." >&2
    exit 1
fi

echo "Setting version to $VERSION in build.sh..."
sed -i '' -E "s|(<key>CFBundleVersion</key>[^<]*<string>)[^<]*(</string>)|\1${VERSION}\2|" build.sh
sed -i '' -E "s|(<key>CFBundleShortVersionString</key>[^<]*<string>)[^<]*(</string>)|\1${VERSION}\2|" build.sh

echo "Building..."
./build.sh

echo "Zipping app bundle..."
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$BUILD/$APP" "$ZIP"

echo "Committing version bump..."
git add build.sh
git commit -q -m "Release $TAG" || echo "(nothing to commit — build.sh already at $VERSION)"
git push

echo "Creating GitHub release $TAG..."
NOTES_FILE="$(mktemp)"
trap 'rm -f "$NOTES_FILE"' EXIT
cat > "$NOTES_FILE" <<MD
Prebuilt app so you do not have to compile from source.

**Requirements:** Apple Silicon Mac. The app is self-signed, not notarised by Apple, so macOS Gatekeeper will block it until you clear the download quarantine (step 2 below).

### Install
1. Download the zip below, unzip it, and move \`$APP\` to \`/Applications\`.
2. Clear the quarantine flag so it will open:
   \`\`\`
   xattr -dr com.apple.quarantine "/Applications/$APP"
   \`\`\`
3. Open it. It runs in the menu bar (no Dock icon).
4. Grant Accessibility and Screen Recording when prompted (System Settings > Privacy & Security).
MD

gh release create "$TAG" "$ZIP#$(basename "$ZIP")" \
    --title "$TAG" --notes-file "$NOTES_FILE" --target main --latest

echo "Done: $(gh release view "$TAG" --json url -q .url)"
