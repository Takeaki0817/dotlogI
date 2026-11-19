#!/bin/zsh
# Builds dotlogI and installs one app, /Applications/dotlogI.app:
#   Contents/MacOS/DotlogiAgent                  the resident process (launchd runs it with `run` at login);
#                                                opened from Finder, it asks for its permissions and opens:
#   Contents/Helpers/dotlogI Settings.app        the settings window (runs only while open)
# Because launchd and Finder start the very same signed executable, the permissions macOS grants to
# "dotlogI" are the ones the resident process uses.
#
#   scripts/install.sh            build, install and (re)start
#   scripts/install.sh uninstall  stop, hand the buttons back to the mouse, remove the app and its permissions
# Set DOTLOGI_LOCAL_SIGNING=1 to sign with a local certificate instead (see scripts/signing.sh and the README).
set -euo pipefail

ROOT=${0:A:h:h}
LABEL=local.dotlogi
APP="/Applications/dotlogI.app"
SETTINGS_APP="$APP/Contents/Helpers/dotlogI Settings.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG_DIR="$HOME/.config/dotlogi"
LOG="$HOME/Library/Logs/dotlogi.log"
DOMAIN="gui/$(id -u)"

# Escapes &, < and > for values written into the plists below.
xml() { local v=${1//&/&amp;}; v=${v//</&lt;}; print -r -- "${v//>/&gt;}"; }

stop() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  # bootout returns before the job is gone; bootstrapping too early fails.
  local i=0
  while launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 && (( i++ < 20 )); do sleep 0.5; done
}

if [[ "${1:-}" == "uninstall" ]]; then
  stop # the agent hands the buttons and the wheel back to the mouse as it exits
  rm -f "$AGENT"
  tccutil reset ListenEvent "$LABEL" >/dev/null 2>&1 || true
  tccutil reset Accessibility "$LABEL" >/dev/null 2>&1 || true
  tccutil reset PostEvent "$LABEL" >/dev/null 2>&1 || true
  rm -rf "$APP"
  echo "Removed $APP, its login agent and its Input Monitoring / Accessibility permissions. $CONFIG_DIR is kept."
  exit 0
fi

swift build -c release --package-path "$ROOT"

# Ad-hoc signing by default: a permission is tied to this exact build, so nothing else can claim it,
# and macOS asks again after an update. Local signing keeps permissions across updates, at a cost
# explained in scripts/signing.sh.
if [[ "${DOTLOGI_LOCAL_SIGNING:-}" == 1 ]]; then
  source "$ROOT/scripts/signing.sh"
  ensure_signing_identity
else
  # Hardened runtime: DYLD_* variables and injected libraries are refused, so nothing else can run
  # inside the agent and borrow its permissions.
  sign_app() { codesign --force --sign - --options runtime --identifier "$2" "$1"; }
fi

# App icon, drawn by scripts/make-icon.swift.
ICONSET="$ROOT/.build/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ROOT/.build/AppIcon.icns"

# Install the config only once; later edits in ~/.config are the user's.
mkdir -p "$CONFIG_DIR"
[[ -f "$CONFIG_DIR/config.json" ]] || cp "$ROOT/config/default.json" "$CONFIG_DIR/config.json"
"$ROOT/.build/release/DotlogiAgent" check

stop
rm -rf "$APP"
# Earlier versions kept the agent here.
rm -rf "$HOME/Library/Application Support/dotlogI/dotlogI Agent.app"

# The settings window, nested inside the app.
mkdir -p "$SETTINGS_APP/Contents/MacOS" "$SETTINGS_APP/Contents/Resources"
cp "$ROOT/.build/release/DotlogiSettings" "$SETTINGS_APP/Contents/MacOS/DotlogiSettings"
cp "$ROOT/.build/AppIcon.icns" "$SETTINGS_APP/Contents/Resources/AppIcon.icns"
cat > "$SETTINGS_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL.settings</string>
  <key>CFBundleName</key><string>dotlogI</string>
  <key>CFBundleDisplayName</key><string>dotlogI</string>
  <key>CFBundleExecutable</key><string>DotlogiSettings</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
sign_app "$SETTINGS_APP" "$LABEL.settings"

# The app itself: its main executable is the agent.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/DotlogiAgent" "$APP/Contents/MacOS/DotlogiAgent"
cp "$ROOT/.build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>dotlogI</string>
  <key>CFBundleDisplayName</key><string>dotlogI</string>
  <key>CFBundleExecutable</key><string>DotlogiAgent</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
sign_app "$APP" "$LABEL" # after the nested app, so the outer signature seals it

mkdir -p "${AGENT:h}"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$(xml "$APP/Contents/MacOS/DotlogiAgent")</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardErrorPath</key><string>$(xml "$LOG")</string>
</dict></plist>
PLIST
# Let Finder and the Dock pick up the app and its icon.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$APP"
touch "$APP"

# An ad-hoc build gets a new identity, so old permission entries no longer apply but still show as
# "on" under the same name. Clear them so opening the app lists a fresh entry to switch on.
if [[ "${DOTLOGI_LOCAL_SIGNING:-}" != 1 ]]; then
  tccutil reset ListenEvent "$LABEL" >/dev/null 2>&1 || true
  tccutil reset Accessibility "$LABEL" >/dev/null 2>&1 || true
  tccutil reset PostEvent "$LABEL" >/dev/null 2>&1 || true
fi

launchctl bootstrap "$DOMAIN" "$AGENT"
echo "Installed $APP. Open it once to grant its permissions. Log: $LOG"
