#!/bin/bash
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
PROJECT_NAME="Quotio"
SCHEME="Quotio"
BUILD_DIR="${PROJECT_DIR}/build"
DEBUG_BUNDLE_ID="dev.quotio.desktop.debug"
STABLE_APP_DIR="${HOME}/Applications"
STABLE_APP_PATH="${STABLE_APP_DIR}/Quotio Dev.app"
SIGN_IDENTITY="${QUOTIO_DEV_SIGN_IDENTITY:-Codex Watch Reminder Code Signing}"
ENTITLEMENTS_PATH="${PROJECT_DIR}/Quotio/Quotio.entitlements"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  ${PROJECT_NAME} Debug Build & Launch${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Step 1: Build
echo -e "${BLUE}[1/2]${NC} Building Debug configuration..."

xcodebuild \
    -project "${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -derivedDataPath "${BUILD_DIR}/DerivedData" \
    build \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | while read -r line; do
        if [[ "$line" == *"error:"* ]]; then
            echo -e "  ${RED}✗ ${line}${NC}"
        elif [[ "$line" == *"warning:"* ]]; then
            echo -e "  ${YELLOW}⚠ ${line}${NC}"
        elif [[ "$line" == "** BUILD SUCCEEDED **" ]]; then
            echo -e "  ${GREEN}✓ Build succeeded${NC}"
        elif [[ "$line" == "** BUILD FAILED **" ]]; then
            echo -e "  ${RED}✗ Build failed${NC}"
        fi
    done

# Resolve the built app from Xcode settings so local PRODUCT_NAME overrides
# such as "Quotio Dev" keep this launcher working.
BUILD_SETTINGS=$(xcodebuild \
    -project "${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Debug \
    -derivedDataPath "${BUILD_DIR}/DerivedData" \
    -showBuildSettings)

BUILT_PRODUCTS_DIR=$(echo "${BUILD_SETTINGS}" | awk -F' = ' '$1 ~ /^[[:space:]]*BUILT_PRODUCTS_DIR$/ { print $2; exit }')
FULL_PRODUCT_NAME=$(echo "${BUILD_SETTINGS}" | awk -F' = ' '$1 ~ /^[[:space:]]*FULL_PRODUCT_NAME$/ { print $2; exit }')
EXECUTABLE_NAME=$(echo "${BUILD_SETTINGS}" | awk -F' = ' '$1 ~ /^[[:space:]]*EXECUTABLE_NAME$/ { print $2; exit }')
APP_PATH="${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}"

if [ -z "$BUILT_PRODUCTS_DIR" ] || [ -z "$FULL_PRODUCT_NAME" ] || [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}✗ Failed to find built app${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Built app: ${APP_PATH}${NC}"
echo ""

# Step 2: Stabilize and launch
echo -e "${BLUE}[2/2]${NC} Signing stable debug app and launching ${PROJECT_NAME}..."

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP_PATH}/Contents/Info.plist" 2>/dev/null || true)
if [ "${BUNDLE_ID}" != "${DEBUG_BUNDLE_ID}" ]; then
    echo -e "${RED}✗ Built app has unexpected bundle id: ${BUNDLE_ID:-unknown}${NC}"
    exit 1
fi

mkdir -p "${STABLE_APP_DIR}"
rm -rf "${STABLE_APP_PATH}"
/usr/bin/ditto "${APP_PATH}" "${STABLE_APP_PATH}"
xattr -cr "${STABLE_APP_PATH}" 2>/dev/null || true

if [ -f "${ENTITLEMENTS_PATH}" ]; then
    codesign --force --deep --sign "${SIGN_IDENTITY}" --entitlements "${ENTITLEMENTS_PATH}" "${STABLE_APP_PATH}"
else
    codesign --force --deep --sign "${SIGN_IDENTITY}" "${STABLE_APP_PATH}"
fi

xattr -dr com.apple.quarantine "${STABLE_APP_PATH}" 2>/dev/null || true

# Kill existing Quotio instances so the menu bar cannot show the installed app
# while we are testing the local build.
pkill -x "${PROJECT_NAME}" 2>/dev/null || true
if [ -n "$EXECUTABLE_NAME" ] && [ "$EXECUTABLE_NAME" != "$PROJECT_NAME" ]; then
    pkill -x "${EXECUTABLE_NAME}" 2>/dev/null || true
fi
sleep 0.5

# Launch the stable copy by exact path so Keychain sees a consistent identity.
open -n "${STABLE_APP_PATH}"

echo -e "${GREEN}✓ ${PROJECT_NAME} launched successfully: ${STABLE_APP_PATH}${NC}"
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Done!${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
