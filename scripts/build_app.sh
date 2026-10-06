#!/bin/bash
# Build Insight.app from the SwiftPM executable.
#
#   ./scripts/build_app.sh                 build + ad-hoc codesign into dist/Insight.app
#   ./scripts/build_app.sh --install       also copy to /Applications
#   ./scripts/build_app.sh --reset-perms   tccutil reset for this bundle id (ad-hoc re-signing
#                                          changes the code signature, which can invalidate
#                                          Accessibility / Screen Recording grants)
#   ./scripts/build_app.sh --debug         debug build, faster iteration

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="release"
INSTALL=0
RESET_PERMS=0
for arg in "$@"; do
	case "$arg" in
		--install) INSTALL=1 ;;
		--reset-perms) RESET_PERMS=1 ;;
		--debug) CONFIG="debug" ;;
		*) echo "unknown flag: $arg" >&2; exit 1 ;;
	esac
done

APP_NAME="Insight"
BUNDLE_ID="com.hsc113.Insight"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> swift build (-$CONFIG)"
swift build -c "$CONFIG" --product "$APP_NAME"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
[ -f "$BIN" ] || { echo "binary not found at $BIN" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------
# The bundle is assembled and signed in a staging directory that is **not** inside a file-provider
# domain, and only then copied into `dist/`.
#
# This matters whenever the repository lives under `~/Documents` (or `~/Desktop`) with iCloud Drive
# syncing on. That directory is a file-provider domain, and its provider re-attaches
# `com.apple.FinderInfo` to the bundle about a second after anything removes it — so `xattr -cr`
# followed by `codesign` fails with
#
#     resource fork, Finder information, or similar detritus not allowed
#
# and it cannot be fixed by clearing the attribute first, because it comes straight back. The
# failure is also intermittent: it depends on how recently the provider looked at the path, so a
# build can succeed all morning and then start failing for no visible reason.
#
# Signing elsewhere and copying the finished bundle in works because a signature seals the
# *contents* of the files, not the extended attributes on the bundle root. Verified: after `ditto`
# into a synced directory the attribute is present again and `codesign --verify` still reports
# "valid on disk". `ditto` rather than `cp -R` because it handles bundles and xattrs correctly.
# ---------------------------------------------------------------------------------------------
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/insight-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

STAGED_APP="$STAGE/$APP_NAME.app"

echo "==> assembling $STAGED_APP"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN" "$STAGED_APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
printf 'APPL????' > "$STAGED_APP/Contents/PkgInfo"

# Localizable.strings (Simplified Chinese) — plain .strings so no genstrings needed.
if [ -d "$ROOT/Resources/zh-Hans.lproj" ]; then
	mkdir -p "$STAGED_APP/Contents/Resources/zh-Hans.lproj"
	cp "$ROOT/Resources/zh-Hans.lproj/"* "$STAGED_APP/Contents/Resources/zh-Hans.lproj/"
fi

# App icon. Prefer the checked-in AI-generated one; fall back to the procedural glyph so a
# fresh clone builds without needing an image model.
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
	cp "$ROOT/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
else
	echo "==> rendering procedural app icon"
	ICON_DIR="$STAGED_APP/Contents/Resources/AppIcon.iconset"
	swift "$ROOT/scripts/make_icon.swift" "$ICON_DIR"
	iconutil -c icns "$ICON_DIR" -o "$STAGED_APP/Contents/Resources/AppIcon.icns"
	rm -rf "$ICON_DIR"
fi

echo "==> codesign (ad-hoc)"
# iconutil and cp both like to leave AppleDouble sidecars and extended attributes behind, and
# codesign refuses to seal a bundle that contains them. Clearing them here sticks, because the
# staging directory has no file provider watching it.
find "$STAGED_APP" -name '._*' -delete 2>/dev/null || true
find "$STAGED_APP" -name '.DS_Store' -delete 2>/dev/null || true
xattr -cr "$STAGED_APP" 2>/dev/null || true
# Non-sandboxed on purpose: macOS 15+ blocks Option+letter global hotkeys for sandboxed apps.
# Staying out of the sandbox keeps the hotkeys working and the app a single compact binary.
codesign --force --sign - --timestamp=none \
	--identifier "$BUNDLE_ID" \
	--options runtime \
	"$STAGED_APP" 2>&1 | sed 's/^/    /'

echo "==> placing into dist/"
rm -rf "$APP"
mkdir -p "$DIST"
ditto "$STAGED_APP" "$APP"

# Verified at the final location, not just in staging — that is the copy the user will run, and it
# is the one that picks the synced directory's extended attributes back up.
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

SIZE="$(du -sh "$APP" | cut -f1 | tr -d ' ')"
echo "==> built $APP  ($SIZE)"

if [ "$RESET_PERMS" -eq 1 ]; then
	echo "==> resetting TCC permissions for $BUNDLE_ID"
	tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
	tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true
	echo "    done — relaunch and re-grant"
fi

if [ "$INSTALL" -eq 1 ]; then
	echo "==> installing to /Applications"
	pkill -x "$APP_NAME" 2>/dev/null || true
	sleep 0.3
	rm -rf "/Applications/$APP_NAME.app"
	ditto "$STAGED_APP" "/Applications/$APP_NAME.app"
	codesign --verify --verbose=1 "/Applications/$APP_NAME.app" 2>&1 | sed 's/^/    /'
	echo "    /Applications/$APP_NAME.app"
fi