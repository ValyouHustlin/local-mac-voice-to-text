#!/usr/bin/env bash
# wordhand installer.
#   curl -fsSL https://raw.githubusercontent.com/ValyouHustlin/wordhand/master/scripts/install.sh | sh
#
# Fetches the latest arm64 macOS binary from GitHub Releases, drops it
# in /usr/local/bin.
#
# Apple Silicon only — WhisperKit uses the Apple Neural Engine via CoreML,
# which only ships on M-series chips.

set -euo pipefail

REPO="ValyouHustlin/wordhand"
BIN_NAME="wordhand"
INSTALL_DIR="/usr/local/bin"
ASSET="wordhand-macos-arm64.tar.gz"

red()    { printf "\033[31m%s\033[0m\n" "$*" >&2; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
dim()    { printf "\033[2m%s\033[0m\n" "$*"; }

# 1. sanity
if [ "$(/usr/bin/uname -s)" != "Darwin" ]; then
    red "wordhand is macOS-only (detected $(/usr/bin/uname -s))"
    exit 1
fi

ARCH=$(/usr/bin/uname -m)
if [ "$ARCH" != "arm64" ]; then
    red "wordhand requires Apple Silicon (detected $ARCH)"
    red "the on-device inference engine uses the Apple Neural Engine, which Intel Macs don't have."
    exit 1
fi

# 2. resolve latest release
dim "→ resolving latest release..."
TAG=$(/usr/bin/curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | /usr/bin/grep -E '"tag_name"' \
    | /usr/bin/head -1 \
    | /usr/bin/sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')

if [ -z "${TAG:-}" ]; then
    red "couldn't determine latest release tag"
    exit 1
fi
dim "  ${TAG}"

URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"

# 3. download + extract
TMP=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf "$TMP"' EXIT

dim "→ downloading ${ASSET}..."
/usr/bin/curl -fsSL "$URL" -o "$TMP/${ASSET}"

dim "→ extracting..."
/usr/bin/tar -xzf "$TMP/${ASSET}" -C "$TMP"

if [ ! -f "$TMP/${BIN_NAME}" ]; then
    red "archive did not contain ${BIN_NAME}"
    exit 1
fi

/bin/chmod +x "$TMP/${BIN_NAME}"

# 4. install
SUDO=""
if [ ! -w "$INSTALL_DIR" ]; then
    if [ ! -d "$INSTALL_DIR" ]; then
        dim "→ creating ${INSTALL_DIR} (sudo)..."
        /usr/bin/sudo /bin/mkdir -p "$INSTALL_DIR"
    fi
    SUDO="/usr/bin/sudo"
fi

dim "→ installing to ${INSTALL_DIR}/${BIN_NAME}..."
$SUDO /bin/mv "$TMP/${BIN_NAME}" "${INSTALL_DIR}/${BIN_NAME}"
$SUDO /bin/chmod +x "${INSTALL_DIR}/${BIN_NAME}"

green "✓ wordhand ${TAG} installed at ${INSTALL_DIR}/${BIN_NAME}"
echo
echo "next:"
echo "  wordhand setup                       # grant mic + accessibility"
echo "  wordhand                             # run from this terminal"
echo "  install Wordhand.app for menu bar, Dock, and release-only login launch"
