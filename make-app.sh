#!/bin/zsh
# Builds Navi.app (release, signed) next to this script, as io.github.remodivito.navi,
# the identifier macOS ties permissions and the Keychain to.
# Permissions (Screen Recording, Microphone, Accessibility) attach to the app.
# Ad-hoc signing changes on every rebuild, so macOS may ask again after one.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=Navi.app
rm -rf "$APP" Navi.app
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Navi "$APP/Contents/MacOS/Navi"
cp Info.plist "$APP/Contents/Info.plist"
# Sparkle (updates), as a framework inside the app. Navi isn't sandboxed, so Sparkle's
# XPC services aren't needed (Sparkle's own advice): left out, nothing extra to sign.
mkdir -p "$APP/Contents/Frameworks"
ditto .build/release/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
otool -l "$APP/Contents/MacOS/Navi" | grep -q "@executable_path/../Frameworks" \
  || install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Navi"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"

mkdir -p "$APP/Contents/Resources"
# The handwriting font for written marks (SIL OFL; its licence travels with it).
cp -R Resources/Fonts "$APP/Contents/Resources/"
cp Resources/Sparkle-LICENSE.txt "$APP/Contents/Resources/"
# The data both platforms share (design tokens, the owl, the tag grammar), read by
# NaviCore at runtime; a debug build reads them from the source tree instead.
cp -R Resources/Shared "$APP/Contents/Resources/"
# The app icon (made by scripts/make-icon.swift).
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Kokoro voice, only when built in (a .with-kokoro file; Navi is text first for
# now): the Misaki phonemizer library, SwiftPM resource bundles, the Core ML
# model bundle, and MLX's prebuilt GPU kernels (from the mlx-metal wheel matching
# mlx-swift's MLX core, since only Xcode can compile them). NAVI_KOKORO_DIR names
# the folder they're in.
KOKORO=${NAVI_KOKORO_DIR:-}
[[ -f .with-kokoro && -z "$KOKORO" ]] && echo "A .with-kokoro file but no NAVI_KOKORO_DIR: building without the Kokoro voice"
if [[ -f .with-kokoro && -n "$KOKORO" ]]; then
  cp .build/release/libMisakiSwift.dylib "$APP/Contents/MacOS/"
  for b in .build/release/*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done
  if [[ -f $KOKORO/bundle/KokoroRuntimeManifest.json ]]; then
    cp -R $KOKORO/bundle "$APP/Contents/Resources/Kokoro"
    mkdir -p "$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
    cp $KOKORO/metal-wheel/mlx/lib/mlx.metallib "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib"
  else
    echo "No Kokoro bundle in $KOKORO/bundle: the app will use the Mac's voices"
  fi
fi
# Sign with the Developer ID when it's installed (hardened runtime and a secure
# timestamp, as notarisation requires; see make-release.sh), else with the local
# self-signed identity so macOS keeps permissions across rebuilds, else ad hoc.
DEVID=$(security find-identity -p codesigning -v | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
LOCAL="ScreenPointer Local Signing"
if [[ -n "$DEVID" ]]; then
  SIGN=(codesign --force --sign "$DEVID" --options runtime --timestamp)
  [[ -f "$APP/Contents/MacOS/libMisakiSwift.dylib" ]] && "${SIGN[@]}" "$APP/Contents/MacOS/libMisakiSwift.dylib"
  # Sparkle's parts inside out: its updater helpers, then the framework.
  "${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
  "${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
  "${SIGN[@]}" "$SPARKLE"
  "${SIGN[@]}" --entitlements Resources/Navi.entitlements --identifier io.github.remodivito.navi "$APP"
  echo "Signed with $DEVID"
elif security find-identity -p codesigning | grep -q "$LOCAL"; then
  [[ -f "$APP/Contents/MacOS/libMisakiSwift.dylib" ]] && codesign --force --sign "$LOCAL" "$APP/Contents/MacOS/libMisakiSwift.dylib"
  codesign --force --deep --sign "$LOCAL" "$SPARKLE"
  codesign --force --sign "$LOCAL" --identifier io.github.remodivito.navi "$APP"
else
  echo "No signing identity: ad-hoc signing (permissions reset on every rebuild)"
  [[ -f "$APP/Contents/MacOS/libMisakiSwift.dylib" ]] && codesign --force --sign - "$APP/Contents/MacOS/libMisakiSwift.dylib"
  codesign --force --deep --sign - "$SPARKLE"
  codesign --force --sign - --identifier io.github.remodivito.navi "$APP"
fi
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Never install a build macOS wouldn't recognise as Navi: a failed or half-finished
# signature makes it a stranger, and every permission is lost until it's signed again.
if ! codesign --verify --deep --strict "$APP" 2>/dev/null \
   || [[ "$(codesign -dv "$APP" 2>&1 | sed -n 's/^Identifier=//p')" != "io.github.remodivito.navi" ]]; then
  echo "Navi.app isn't properly signed, so it wasn't installed (your installed Navi is unchanged)."
  echo "If the keychain asked for your password, run this again and choose Always Allow."
  exit 1
fi
echo "Built $PWD/$APP"
# Install to /Applications, as users run it, and keep macOS knowing only that copy:
# two registered copies of one app made System Settings list or grant the wrong one.
# A running Navi is quit first (replacing a running app upsets its permissions) and
# reopened after. NAVI_NO_INSTALL=1 skips this (make-release.sh sets it).
if [[ -z "${NAVI_NO_INSTALL:-}" ]]; then
  RUNNING=$(pgrep -x Navi || true)
  [[ -n "$RUNNING" ]] && { osascript -e 'quit app id "io.github.remodivito.navi"' 2>/dev/null || true; sleep 1; pkill -x Navi || true; }
  rm -rf /Applications/Navi.app
  ditto "$APP" /Applications/Navi.app
  "$LSREGISTER" -u "$APP" 2>/dev/null || true
  "$LSREGISTER" -f /Applications/Navi.app
  echo "Installed /Applications/Navi.app"
  if [[ -n "$RUNNING" ]]; then open /Applications/Navi.app; echo "Reopened Navi"; fi
else
  "$LSREGISTER" -f "$APP"
fi
