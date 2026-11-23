#!/bin/sh
# Builds ReSurf.app into build/ and, with --install, puts it next to the other Re apps.
set -e
cd "$(dirname "$0")"
APP=build/ReSurf.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# for every Mac from macOS 13 on, Apple silicon and Intel both
for ARCH in arm64 x86_64; do
  swiftc -O -module-name ReSurf -target $ARCH-apple-macos13.0 -o "build/ReSurf-$ARCH" Sources/*.swift
done
lipo -create -output "$APP/Contents/MacOS/ReSurf" build/ReSurf-arm64 build/ReSurf-x86_64
rm -f build/ReSurf-arm64 build/ReSurf-x86_64
cp Info.plist "$APP/Contents/"
cp -R Resources/* "$APP/Contents/Resources/"
# ad-hoc, known by its identifier rather than by this build's hash
# Signed as well as the keychain allows: with a Developer ID Application certificate for others' Macs (the
# hardened runtime and a timestamp, as notarizing wants); else with an Apple Development one (this Mac); else ad
# hoc. The team is in the requirement, so the permissions given (Accessibility and the like) outlive rebuilds.
# the symbols only a debugger reads left out, so the download stays small
strip -x "$APP/Contents/MacOS/ReSurf"
IDENTITIES=$(security find-identity -v -p codesigning)
IDENTITY=$(echo "$IDENTITIES" | awk -F'"' '/Developer ID Application/ {print $2; exit}')
RUNTIME="--options runtime --timestamp"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(echo "$IDENTITIES" | awk -F'"' '/Apple Development/ {print $2; exit}')
  RUNTIME="--timestamp=none"
fi
if [ -n "$IDENTITY" ]; then
  TEAM=$(security find-certificate -c "$IDENTITY" -p | openssl x509 -noout -subject -nameopt multiline | awk -F'= ' '/organizationalUnitName/ {print $2; exit}')
  codesign --force $RUNTIME -s "$IDENTITY" \
    -r="designated => identifier \"com.artursavytskyi.resurf\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\"" "$APP"
else
  codesign --force -s - -r='designated => identifier "com.artursavytskyi.resurf"' "$APP"
fi
if [ "$1" = "--install" ]; then
	DEST=/Applications/ReSpace
	[ -d "$DEST" ] || DEST=/Applications
	osascript -e 'quit app id "com.artursavytskyi.resurf"' 2>/dev/null || true
	sleep 1
	rm -rf "$DEST/ReSurf.app"
	cp -R "$APP" "$DEST/"
fi
