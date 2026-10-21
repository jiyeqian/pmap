#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PMAP_TEAM_ID:?Set PMAP_TEAM_ID after enrolling in Apple Developer Program}"
: "${PMAP_BUNDLE_ID:?Set PMAP_BUNDLE_ID to the identifier registered in your account}"
: "${PMAP_BUILD_NUMBER:?Set a new numeric PMAP_BUILD_NUMBER}"
: "${PMAP_PRIVACY_POLICY_URL:?Set the deployed HTTPS privacy policy URL}"
[[ "$PMAP_PRIVACY_POLICY_URL" == https://* ]]
[[ "$PMAP_BUILD_NUMBER" =~ ^[0-9]+$ ]]
[[ -z "${PMAP_TEST_FIXTURE:-}" ]] || { echo 'Test fixtures are forbidden in store archives' >&2; exit 1; }
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
./test.sh
./make_icon.sh
xcodebuild -project Pmap.xcodeproj -scheme pmap -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$PWD/.build-store/pmap.xcarchive" \
    DEVELOPMENT_TEAM="$PMAP_TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$PMAP_BUNDLE_ID" \
    CURRENT_PROJECT_VERSION="$PMAP_BUILD_NUMBER" PMAP_PRIVACY_POLICY_URL="$PMAP_PRIVACY_POLICY_URL" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO archive
PMAP_REQUIRE_SANDBOX=1 ./scripts/verify-bundle.sh .build-store/pmap.xcarchive/Products/Applications/pmap.app
echo 'Archive prepared. Open it in Xcode Organizer for distribution validation and submission.'
