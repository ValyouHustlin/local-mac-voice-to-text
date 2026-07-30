#!/usr/bin/env bash
# Build a self-contained local Wordhand.app from the Swift package.

set -euo pipefail

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" && /bin/pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && /bin/pwd)"
APP_VERSION="${WORDHAND_VERSION:-0.1.0}"
APP_BUILD="${WORDHAND_BUILD_NUMBER:-1}"
BUILD_CHANNEL="${WORDHAND_BUILD_CHANNEL:-development}"
SIGNING_CONFIG="${WORDHAND_SIGNING_CONFIG:-${HOME}/Library/Application Support/Wordhand/signing-identity}"
SIGNING_IDENTITY="${WORDHAND_CODESIGN_IDENTITY:-}"

if [ -z "${SIGNING_IDENTITY}" ] && [ -f "${SIGNING_CONFIG}" ]; then
    IFS= read -r SIGNING_IDENTITY < "${SIGNING_CONFIG}" || true
fi
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

case "${BUILD_CHANNEL}" in
    development)
        DEFAULT_APP_PATH="${REPO_DIR}/dist/Wordhand Dev.app"
        BUNDLE_IDENTIFIER="com.valyou.wordhand.dev"
        BUNDLE_DISPLAY_NAME="Wordhand Dev"
        ;;
    release)
        DEFAULT_APP_PATH="${REPO_DIR}/dist/Wordhand.app"
        BUNDLE_IDENTIFIER="com.valyou.wordhand"
        BUNDLE_DISPLAY_NAME="Wordhand"
        case "${SIGNING_IDENTITY}" in
            "Developer ID Application:"*) ;;
            *)
                /bin/echo "release builds require an explicit Developer ID Application identity" >&2
                /bin/echo "development builds must use the default development channel" >&2
                exit 78
                ;;
        esac
        ;;
    *)
        /bin/echo "WORDHAND_BUILD_CHANNEL must be development or release" >&2
        exit 64
        ;;
esac

APP_PATH="${WORDHAND_APP_OUTPUT:-${DEFAULT_APP_PATH}}"

case "${APP_PATH}" in
    *.app) ;;
    *)
        /bin/echo "WORDHAND_APP_OUTPUT must end in .app" >&2
        exit 64
        ;;
esac

# Repository build artifacts must never compete with the installed app in
# Spotlight. Do not place this marker beside a caller-supplied output path.
case "${APP_PATH}" in
    "${REPO_DIR}/dist/"*)
        /usr/bin/touch "$(/usr/bin/dirname "${APP_PATH}")/.metadata_never_index"
        ;;
esac

cd "${REPO_DIR}"
/usr/bin/swift build -c release -Xswiftc -warnings-as-errors
BIN_DIR="$(/usr/bin/swift build -c release --show-bin-path)"

if [ -e "${APP_PATH}" ]; then
    /bin/rm -rf "${APP_PATH}"
fi

/bin/mkdir -p \
    "${APP_PATH}/Contents/MacOS" \
    "${APP_PATH}/Contents/Resources"

/usr/bin/ditto "${BIN_DIR}/wordhand" "${APP_PATH}/Contents/MacOS/wordhand"
/bin/chmod 755 "${APP_PATH}/Contents/MacOS/wordhand"
/usr/bin/ditto "${REPO_DIR}/Packaging/Info.plist" "${APP_PATH}/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "${APP_VERSION}" \
    "${APP_PATH}/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "${APP_BUILD}" \
    "${APP_PATH}/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string "${BUNDLE_IDENTIFIER}" \
    "${APP_PATH}/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleDisplayName -string "${BUNDLE_DISPLAY_NAME}" \
    "${APP_PATH}/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleName -string "${BUNDLE_DISPLAY_NAME}" \
    "${APP_PATH}/Contents/Info.plist"

/usr/bin/ditto \
    "${REPO_DIR}/Sources/WordhandCore/Resources/default-vocabulary.json" \
    "${APP_PATH}/Contents/Resources/default-vocabulary.json"

ICON_WORK="$(/usr/bin/mktemp -d /tmp/wordhand-app-icon.XXXXXX)"
trap '/bin/rm -rf "${ICON_WORK}"' EXIT
ICONSET="${ICON_WORK}/AppIcon.iconset"
/bin/mkdir -p "${ICONSET}"
/usr/bin/sips -s format png "${REPO_DIR}/docs/assets/wordhand-icon.svg" \
    --out "${ICON_WORK}/icon-1024.png" >/dev/null

while read -r size filename; do
    /usr/bin/sips -z "${size}" "${size}" "${ICON_WORK}/icon-1024.png" \
        --out "${ICONSET}/${filename}" >/dev/null
done <<'SIZES'
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
SIZES

/usr/bin/iconutil -c icns "${ICONSET}" \
    -o "${APP_PATH}/Contents/Resources/AppIcon.icns"

/usr/bin/plutil -lint "${APP_PATH}/Contents/Info.plist" >/dev/null
/usr/bin/codesign --force --deep --sign "${SIGNING_IDENTITY}" "${APP_PATH}"
/usr/bin/codesign --verify --deep --strict "${APP_PATH}"

/bin/echo "Built ${APP_PATH}"
/bin/echo "Version ${APP_VERSION} (${APP_BUILD})"
/bin/echo "Channel: ${BUILD_CHANNEL}"
/bin/echo "Bundle identifier: ${BUNDLE_IDENTIFIER}"
if [ "${SIGNING_IDENTITY}" = "-" ]; then
    /bin/echo "Signature: local ad hoc"
    /bin/echo "Warning: macOS permissions may reset between ad-hoc development builds." >&2
    /bin/echo "Configure one stable Keychain identity with scripts/configure-local-signing.sh." >&2
else
    /bin/echo "Signature: ${SIGNING_IDENTITY}"
fi
