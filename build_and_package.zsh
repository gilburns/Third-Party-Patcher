#!/bin/zsh
#
#  build_and_package.zsh
#
#  Builds the three patcher CLI tools, the PatcherMenu app bundle, and the
#  Available Software app bundle, signs them, assembles a distribution pkg with
#  the LaunchDaemon plist, signs and notarizes the pkg, then staples the ticket.
#
#  Requirements:
#    - Xcode command-line tools installed
#    - Signing identities present in the login keychain
#    - Notarization credentials stored via:
#        xcrun notarytool store-credentials "apple-notary-profile" \
#            --apple-id <you@example.com> --team-id G4MQ57TVLE
#

set -euo pipefail

# ── Signing identities and notarization profile ───────────────────────────────

APP_SIGN_ID="Developer ID Application: Gil Burns (G4MQ57TVLE)"
INSTALLER_SIGN_ID="Developer ID Installer: Gil Burns (G4MQ57TVLE)"
NOTARY_PROFILE="apple-notary-profile"

# ── Derived paths (all relative to this script's directory) ───────────────────

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="$SCRIPT_DIR"
XCODEPROJ="$PROJECT_DIR/Third Party Patcher.xcodeproj"
BUILD_DIR="$PROJECT_DIR/build_output"
DERIVED_DATA="$BUILD_DIR/DerivedData"
RELEASE_DIR="$DERIVED_DATA/Build/Products/Release"
PAYLOAD_DIR="$BUILD_DIR/payload"
SCRIPTS_DIR="$BUILD_DIR/scripts"

LAUNCHDAEMON_LABEL="com.gilburns.patcher.scheduler"
LAUNCHDAEMON_SRC="$PROJECT_DIR/LaunchDaemon/${LAUNCHDAEMON_LABEL}.plist"
INSTALL_BIN_DIR="/usr/local/bin/tpp"
APPLICATIONS_DIR="/Applications"
LAUNCHDAEMON_DIR="/Library/LaunchDaemons"

SCHEMES=(patcher patcherscheduler patcherreport)

# ── Extract version from Constants.swift ─────────────────────────────────────

VERSION=$(grep 'patcherVersion' "$PROJECT_DIR/Shared/Constants.swift" \
    | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' | tr -d '"')
if [[ -z "$VERSION" ]]; then
    print "❌  Could not extract version from Constants.swift" >&2
    exit 1
fi

PKG_OUTPUT="$BUILD_DIR/Third_Party_Patcher-${VERSION}.pkg"

# ── Preflight checks ──────────────────────────────────────────────────────────

print "🔍 Checking prerequisites..."

if ! security find-identity -v -p codesigning | grep -qF "$APP_SIGN_ID"; then
    print "❌  App signing identity not found in keychain: $APP_SIGN_ID" >&2
    exit 1
fi

if ! security find-identity -v | grep -qF "$INSTALLER_SIGN_ID"; then
    print "❌  Installer signing identity not found in keychain: $INSTALLER_SIGN_ID" >&2
    exit 1
fi

if [[ ! -f "$LAUNCHDAEMON_SRC" ]]; then
    print "❌  LaunchDaemon plist not found: $LAUNCHDAEMON_SRC" >&2
    exit 1
fi

print "✅  Prerequisites satisfied — building v${VERSION}"

# ── Clean build directory ─────────────────────────────────────────────────────

rm -rf "$BUILD_DIR"
mkdir -p "$DERIVED_DATA" "$SCRIPTS_DIR"

# ── Build each tool ───────────────────────────────────────────────────────────
#
#  Code signing is disabled here; we sign the binaries ourselves below so we
#  have full control over the codesign flags (hardened runtime, timestamp).

for SCHEME in "${SCHEMES[@]}"; do
    print ""
    print "🔨 Building $SCHEME..."
    LOG="$BUILD_DIR/build_${SCHEME}.log"

    xcodebuild \
        -project    "$XCODEPROJ" \
        -scheme     "$SCHEME" \
        -configuration Release \
        -derivedDataPath "$DERIVED_DATA" \
        ARCHS="arm64 x86_64" \
        ONLY_ACTIVE_ARCH=NO \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        build > "$LOG" 2>&1 || {
            print "❌  Build failed for $SCHEME — see $LOG" >&2
            tail -20 "$LOG" >&2
            exit 1
        }

    [[ -f "$RELEASE_DIR/$SCHEME" ]] || {
        print "❌  Expected binary not found: $RELEASE_DIR/$SCHEME" >&2
        exit 1
    }

    print "✅  $SCHEME built"
done

# ── Build PatcherMenu app bundle ──────────────────────────────────────────────

print ""
print "🔨 Building PatcherMenu..."
LOG="$BUILD_DIR/build_PatcherMenu.log"

xcodebuild \
    -project    "$XCODEPROJ" \
    -scheme     "PatcherMenu" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build > "$LOG" 2>&1 || {
        print "❌  Build failed for PatcherMenu — see $LOG" >&2
        tail -20 "$LOG" >&2
        exit 1
    }

[[ -d "$RELEASE_DIR/PatcherMenu.app" ]] || {
    print "❌  Expected app bundle not found: $RELEASE_DIR/PatcherMenu.app" >&2
    exit 1
}

print "✅  PatcherMenu built"

# ── Build Available Software app bundle ──────────────────────────────────────

print ""
print "🔨 Building Available Software..."
LOG="$BUILD_DIR/build_AvailableSoftware.log"

xcodebuild \
    -project    "$XCODEPROJ" \
    -scheme     "Available Software" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build > "$LOG" 2>&1 || {
        print "❌  Build failed for Available Software — see $LOG" >&2
        tail -20 "$LOG" >&2
        exit 1
    }

[[ -d "$RELEASE_DIR/Available Software.app" ]] || {
    print "❌  Expected app bundle not found: $RELEASE_DIR/Available Software.app" >&2
    exit 1
}

print "✅  Available Software built"

# ── Sign binaries ─────────────────────────────────────────────────────────────
#
#  --options runtime  enables hardened runtime (required for notarization)
#  --timestamp        embeds a secure timestamp (required for notarization)
#  --force            replaces any existing ad-hoc signature from the build

print ""
print "✍️  Signing binaries..."

for SCHEME in "${SCHEMES[@]}"; do
    BINARY="$RELEASE_DIR/$SCHEME"
    codesign \
        --sign "$APP_SIGN_ID" \
        --options runtime \
        --timestamp \
        --force \
        "$BINARY"
    codesign --verify --strict --verbose=1 "$BINARY" 2>&1 \
        | grep -v "^$" || true
    print "✅  Signed $SCHEME"
done

# Sign PatcherMenu.app — binary first (inside-out), then the bundle seal
print ""
print "✍️  Signing PatcherMenu.app..."
APP_BUNDLE="$RELEASE_DIR/PatcherMenu.app"

codesign \
    --sign "$APP_SIGN_ID" \
    --options runtime \
    --timestamp \
    --force \
    "$APP_BUNDLE/Contents/MacOS/PatcherMenu"

codesign \
    --sign "$APP_SIGN_ID" \
    --options runtime \
    --timestamp \
    --force \
    "$APP_BUNDLE"

codesign --verify --strict --verbose=1 "$APP_BUNDLE" 2>&1 \
    | grep -v "^$" || true
print "✅  Signed PatcherMenu.app"

# Sign Available Software.app — binary first (inside-out), then the bundle seal
print ""
print "✍️  Signing Available Software.app..."
AS_BUNDLE="$RELEASE_DIR/Available Software.app"

codesign \
    --sign "$APP_SIGN_ID" \
    --options runtime \
    --timestamp \
    --force \
    "$AS_BUNDLE/Contents/MacOS/Available Software"

codesign \
    --sign "$APP_SIGN_ID" \
    --options runtime \
    --timestamp \
    --force \
    "$AS_BUNDLE"

codesign --verify --strict --verbose=1 "$AS_BUNDLE" 2>&1 \
    | grep -v "^$" || true
print "✅  Signed Available Software.app"

# ── Assemble pkg payload ──────────────────────────────────────────────────────

print ""
print "📁 Assembling package payload..."

mkdir -p "$PAYLOAD_DIR${INSTALL_BIN_DIR}"
mkdir -p "$PAYLOAD_DIR${APPLICATIONS_DIR}"
mkdir -p "$PAYLOAD_DIR${LAUNCHDAEMON_DIR}"

for SCHEME in "${SCHEMES[@]}"; do
    install -m 0755 "$RELEASE_DIR/$SCHEME" "$PAYLOAD_DIR${INSTALL_BIN_DIR}/$SCHEME"
done

# ditto preserves bundle structure, extended attributes, and resource forks
ditto "$RELEASE_DIR/PatcherMenu.app"         "$PAYLOAD_DIR${INSTALL_BIN_DIR}/PatcherMenu.app"
ditto "$RELEASE_DIR/Available Software.app"  "$PAYLOAD_DIR${APPLICATIONS_DIR}/Available Software.app"

install -m 0644 "$LAUNCHDAEMON_SRC" "$PAYLOAD_DIR${LAUNCHDAEMON_DIR}/${LAUNCHDAEMON_LABEL}.plist"

# ── Pre/postinstall scripts ───────────────────────────────────────────────────
#
#  preinstall:  unloads the scheduler before binaries are replaced (safe upgrade)
#  postinstall: loads the scheduler after the new files are in place

cat > "$SCRIPTS_DIR/preinstall" << 'PREINSTALL'
#!/bin/zsh
# Unload the scheduler if it is currently running (handles upgrades).
/bin/launchctl bootout system/com.gilburns.patcher.scheduler 2>/dev/null

# Unload PatcherMenu LaunchAgent for the console user if it is installed.
MENU_PLIST="/Library/LaunchAgents/com.gilburns.patcher.menu.plist"
if [[ -f "$MENU_PLIST" ]]; then
    CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null)
    if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" && "$CONSOLE_USER" != "loginwindow" ]]; then
        CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null)
        if [[ -n "$CONSOLE_UID" ]]; then
            /bin/launchctl bootout gui/${CONSOLE_UID} "$MENU_PLIST" 2>/dev/null
        fi
    fi
fi

exit 0
PREINSTALL

cat > "$SCRIPTS_DIR/postinstall" << 'POSTINSTALL'
#!/bin/zsh
sleep 10
# Load (or reload) the scheduler daemon.
/bin/launchctl bootstrap system /Library/LaunchDaemons/com.gilburns.patcher.scheduler.plist

# Load PatcherMenu LaunchAgent for the console user if it is installed.
MENU_PLIST="/Library/LaunchAgents/com.gilburns.patcher.menu.plist"
if [[ -f "$MENU_PLIST" ]]; then
    CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null)
    if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" && "$CONSOLE_USER" != "loginwindow" ]]; then
        CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null)
        if [[ -n "$CONSOLE_UID" ]]; then
            /bin/launchctl bootstrap gui/${CONSOLE_UID} "$MENU_PLIST"
        fi
    fi
fi

exit 0
POSTINSTALL

chmod +x "$SCRIPTS_DIR/preinstall" "$SCRIPTS_DIR/postinstall"

# ── Build and sign pkg ────────────────────────────────────────────────────────
#
#  pkgbuild --sign produces a signed component pkg.

print ""
print "📦 Building and signing pkg..."

# Create the component plist
pkgbuild --analyze --root "$PAYLOAD_DIR" "$BUILD_DIR/patcher-component.plist"

# Change BundleIsRelocatable to false
plutil -replace BundleIsRelocatable -bool NO "$BUILD_DIR/patcher-component.plist"


pkgbuild \
    --root           "$PAYLOAD_DIR" \
    --scripts        "$SCRIPTS_DIR" \
    --identifier     "com.gilburns.patcher" \
    --version        "$VERSION" \
    --install-location "/" \
    --component-plist "$BUILD_DIR/patcher-component.plist" \
    --sign           "$INSTALLER_SIGN_ID" \
    --timestamp \
    "$PKG_OUTPUT"

print "✅  Signed pkg: $PKG_OUTPUT"

# ── Notarize pkg ──────────────────────────────────────────────────────────────
#
#  --wait polls until Apple returns a result (typically 1–3 minutes).
#  The command exits non-zero if notarization is rejected, which will
#  abort the script via set -e so the staple step is never reached.

print ""
print "🚀 Submitting pkg for notarization (this may take a few minutes)..."

xcrun notarytool submit \
    "$PKG_OUTPUT" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

# ── Staple notarization ticket ────────────────────────────────────────────────

print ""
print "📎 Stapling notarization ticket..."
xcrun stapler staple "$PKG_OUTPUT"

# ── Done ──────────────────────────────────────────────────────────────────────

print ""
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print "✅  Build complete"
print "    Version : $VERSION"
print "    Package : $PKG_OUTPUT"
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
