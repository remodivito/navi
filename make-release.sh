#!/bin/zsh
# Builds Navi.app for release: signed with the Developer ID (make-app.sh), notarised
# by Apple and stapled, so it opens on any Mac without Gatekeeper's warning.
# Leaves dist/Navi-<version>.dmg (the download: Navi beside an Applications shortcut
# to drag it onto, signed, notarised and stapled), dist/Navi-<version>.zip, and
# dist/appcast.xml, the update feed Sparkle reads (signed with Navi's EdDSA key).
#
# To publish: make a GitHub release on remodivito/navi tagged v<version> and attach the
# DMG and appcast.xml. Installed copies find it at releases/latest/download/appcast.xml.
# Raise CFBundleVersion in Info.plist for every release: Sparkle compares that number.
#
# The update key: Sparkle's generate_keys made it once, into the login Keychain
# ("Private key for signing Sparkle updates"). Keep a backup
# (.build/artifacts/sparkle/Sparkle/bin/generate_keys -x <file>, somewhere safe and
# offline): without it, installed copies can never be updated again.
#
# Once, before the first release (it asks for an app-specific password from
# appleid.apple.com and keeps it in the Keychain; nothing is written here):
#   xcrun notarytool store-credentials "navi-notary" --apple-id <your Apple ID> --team-id <your Team ID>
set -euo pipefail
cd "$(dirname "$0")"
PROFILE=${NOTARY_PROFILE:-navi-notary}

# The disk image: Navi and a shortcut to Applications, in a window drawn in Navi's ink
# (Resources/dmg-background.png, from scripts/make-dmg-background.swift) with the arrow
# between them. Finder lays the window out on a read-write image, which is then
# compressed. Finder asks once whether Terminal may control it: allow it.
#   make_dmg <Navi.app> <out.dmg>
make_dmg() {
  local app=$1 out=$2
  local work; work=$(mktemp -d)
  local stage="$work/stage" rw="$work/Navi-rw.dmg"
  mkdir -p "$stage/.background"
  ditto "$app" "$stage/Navi.app"
  ln -s /Applications "$stage/Applications"
  # One picture at both resolutions, so the window is sharp on Retina screens.
  tiffutil -cathidpicheck Resources/dmg-background.png Resources/dmg-background@2x.png \
    -out "$stage/.background/background.tiff" >/dev/null
  hdiutil create -volname "Navi" -srcfolder "$stage" -fs HFS+ -format UDRW -ov "$rw" >/dev/null
  local mount; mount=$(hdiutil attach -readwrite -noverify -noautoopen "$rw" | awk -F '\t' '/\/Volumes\// { print $NF }' | tail -1)
  [[ -d "$mount" ]] || { echo "Couldn't mount $rw"; return 1; }
  # Icon centres match the background's drawing; 620×360 of window below a 28-point title bar.
  osascript - "${mount:t}" <<'APPLESCRIPT'
on run argv
  set volumeName to item 1 of argv
  tell application "Finder"
    tell disk volumeName
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set pathbar visible of container window to false
      set bounds of container window to {200, 120, 820, 508}
      set opts to icon view options of container window
      set arrangement of opts to not arranged
      set icon size of opts to 96
      set text size of opts to 13
      set background picture of opts to file ".background:background.tiff"
      set position of item "Navi.app" of container window to {160, 175}
      set position of item "Applications" of container window to {460, 175}
      update without registering applications
      delay 1
      close
    end tell
  end tell
end run
APPLESCRIPT
  sync
  hdiutil detach "$mount" -quiet || { sleep 2; hdiutil detach "$mount" -force -quiet; }
  rm -f "$out"
  hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -o "$out" >/dev/null
  rm -rf "$work"
}

# `./make-release.sh --dmg-only [Navi.app]`: just the disk image, unsigned, to look at
# the window (dist/Navi-preview.dmg). No signing, no notarisation.
if [[ "${1:-}" == "--dmg-only" ]]; then
  mkdir -p dist
  make_dmg "${2:-Navi.app}" dist/Navi-preview.dmg
  echo "Made $PWD/dist/Navi-preview.dmg (unsigned)"
  exit 0
fi

# A release is never a development build: those keep screenshots.
if [[ -f .dev-build ]]; then
  mv .dev-build .dev-build.paused
  trap 'mv .dev-build.paused .dev-build' EXIT
fi

NAVI_NO_INSTALL=1 ./make-app.sh
# (Read the whole output first: grep -q stopping early would fail the pipe under pipefail.)
SIGNATURE=$(codesign -dv --verbose=2 Navi.app 2>&1)
[[ "$SIGNATURE" == *"Authority=Developer ID Application"* ]] \
  || { echo "Navi.app isn't signed with a Developer ID: install the certificate first."; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist 2>/dev/null || echo dev)
mkdir -p dist
ZIP="dist/Navi-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent Navi.app "$ZIP"
echo "Sending $ZIP to Apple for notarisation (usually a few minutes)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple Navi.app
# Zip again so the download carries the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent Navi.app "$ZIP"
spctl --assess --type execute --verbose Navi.app

DMG="dist/Navi-$VERSION.dmg"
make_dmg Navi.app "$DMG"
IDENTITY=$(security find-identity -p codesigning -v | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
echo "Sending $DMG to Apple for notarisation…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

# The update feed: one item, the DMG on this version's GitHub release, with its EdDSA signature.
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Info.plist)
MINOS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" Info.plist)
SIGNED=$(.build/artifacts/sparkle/Sparkle/bin/sign_update "$DMG")   # sparkle:edSignature="…" length="…"
cat > dist/appcast.xml <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Navi</title>
    <item>
      <title>Navi $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINOS</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/remodivito/navi/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/remodivito/navi/releases/download/v$VERSION/Navi-$VERSION.dmg" $SIGNED type="application/octet-stream"/>
    </item>
  </channel>
</rss>
APPCAST
echo "Release ready: $PWD/$DMG (and $PWD/$ZIP, $PWD/dist/appcast.xml)"
