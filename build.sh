#!/bin/sh
# Builds ReSurf.app into build/ and, with --install, puts it next to the other Re apps.
set -e
cd "$(dirname "$0")"
APP=build/ReSurf.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/ReSurf" Sources/*.swift
cp Info.plist "$APP/Contents/"
cp -R Resources/* "$APP/Contents/Resources/"
# ad-hoc, known by its identifier rather than by this build's hash
# signed with the Apple Development certificate in the keychain if there is one (its team in the
# requirement, so the permissions given, Accessibility and the like, outlive rebuilds); ad hoc otherwise
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
if [ -n "$IDENTITY" ]; then
  TEAM=$(security find-certificate -c "$IDENTITY" -p | openssl x509 -noout -subject -nameopt multiline | awk -F'= ' '/organizationalUnitName/ {print $2; exit}')
  codesign --force --timestamp=none -s "$IDENTITY" \
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
