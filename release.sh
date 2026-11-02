#!/bin/zsh
# Builds the app, zips it and publishes a GitHub release tagged v<VERSION>. The app's updater
# downloads the .zip asset from the latest release.
set -e
cd "$(dirname "$0")"
VERSION=$(cat VERSION)
./build-app.sh
ZIP=build/LLMMemCleaner-$VERSION.zip
rm -f "$ZIP"
ditto -c -k --keepParent build/LLMMemCleaner.app "$ZIP"
gh release create "v$VERSION" "$ZIP" --title "LLM Mem Cleaner $VERSION" --notes "${1:-LLM Mem Cleaner $VERSION}"
echo "Released v$VERSION"
