#!/bin/zsh
# Regenerates the README screenshots in docs/images from sample settings (never from your own).
set -euo pipefail
ROOT=${0:A:h:h}
OUT="$ROOT/docs/images"
swift build -c release --product DotlogiSettings --package-path "$ROOT"
SAMPLE=$(mktemp -d)
trap "rm -rf '$SAMPLE'" EXIT
python3 - "$ROOT/config/default.json" "$SAMPLE" <<'PY'
import json, sys
config = json.load(open(sys.argv[1]))
config["profiles"]["com.apple.Safari"] = {
    "modeShift": {"click": "cmd+w", "up": "cmd+t", "down": "cmd+shift+t", "left": "ctrl+tab", "right": "ctrl+shift+tab"}
}
json.dump(config, open(sys.argv[2] + "/config.json", "w"))
json.dump({"pid": 0, "connected": True, "deviceName": "MX Master 3 Mac", "battery": 82, "smartShift": "free",
           "inputMonitoring": True, "accessibility": True, "updatedAt": "2026-01-01T00:00:00Z"},
          open(sys.argv[2] + "/status.json", "w"))
json.dump({"pid": 0, "connected": False, "battery": -1, "inputMonitoring": False, "accessibility": False,
           "lastError": "InputMonitoringRequired", "updatedAt": "2026-01-01T00:00:00Z"},
          open(sys.argv[2] + "/first-run.json", "w"))
PY
mkdir -p "$OUT"
shot() { "$ROOT/.build/release/DotlogiSettings" --snapshot "$OUT/$1.png" --config "$SAMPLE/config.json" --scale 2 "${@:2}"; }
shot buttons --pane buttons --slot gesture --status "$SAMPLE/status.json" --press gesture
shot per-app --pane buttons --slot modeShift --profile com.apple.Safari --status "$SAMPLE/status.json"
shot scrolling --pane scrolling --status "$SAMPLE/status.json"
shot light --pane buttons --slot gesture --appearance light --status "$SAMPLE/status.json"
shot first-run --pane buttons --slot gesture --status "$SAMPLE/first-run.json"
# The app icon, from the same drawing code the installer uses.
swift "$ROOT/scripts/make-icon.swift" "$SAMPLE/icon.iconset"
cp "$SAMPLE/icon.iconset/icon_128x128@2x.png" "$OUT/icon.png"
ls -1 "$OUT"
