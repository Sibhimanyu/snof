#!/usr/bin/env bash
# Build a Release .ipa, publish it with a SideStore source, deploy to
# https://snof-ios.web.app. Phones with the source added see an Update in
# SideStore, and the app itself shows a banner (UpdateCheck.swift).
#
#   ./scripts/release.sh "What changed, one line"          # build + deploy
#   ./scripts/release.sh "..." --no-deploy                  # build dist/ only
#
# The marketing version is MARKETING_VERSION in project.yml; bump it by hand
# for a meaningful release. The build number is a UTC timestamp, so it always
# goes up without any state to keep in sync across machines.
#
# Cost: Firebase Hosting (Spark: 10 GB stored, 360 MB/day transfer). Each
# install or update downloads the .ipa once; only the latest is kept.
set -euo pipefail
cd "$(dirname "$0")/.."

NOTES="${1:?usage: release.sh \"release notes\" [--no-deploy]}"
DEPLOY=1; [[ "${2:-}" == "--no-deploy" ]] && DEPLOY=0

SITE="https://snof-ios.web.app"
BUNDLE="$(sed -n 's/^SNOF_BUNDLE_ID *= *//p' Config/App.xcconfig)"
VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' project.yml)"
BUILD="$(date -u +%Y%m%d%H%M)"

# A release must talk to the farm. Without the plist it would ship demo data.
[[ -f SNOF/Firebase/GoogleService-Info.plist ]] || {
  echo "No SNOF/Firebase/GoogleService-Info.plist — run scripts/fetch-firebase-config.sh first." >&2; exit 1; }

# SideStore decides "newer" by comparing marketing versions (0.1.3 > 0.1.2),
# not build numbers. A release with an unchanged MARKETING_VERSION deploys
# fine and then never reaches a phone. Refuse it here instead.
LIVE="$(curl -fsS "$SITE/source.json" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['apps'][0]['version'])" 2>/dev/null || true)"
if [[ -n "$LIVE" && $DEPLOY == 1 ]]; then
  python3 - "$VERSION" "$LIVE" <<'PY' || { echo "MARKETING_VERSION $VERSION is not newer than the live $LIVE — bump it in project.yml, or SideStore will never offer this build." >&2; exit 1; }
import sys
v = lambda s: tuple(int(x) for x in s.split("."))
sys.exit(0 if v(sys.argv[1]) > v(sys.argv[2]) else 1)
PY
fi

echo "==> SNOF $VERSION ($BUILD)"
(cd SNOFCore && swift test >/dev/null 2>&1) || { echo "SNOFCore tests failed — run swift test in SNOFCore" >&2; exit 1; }
xcodegen -q
rm -rf build/Release-iphoneos build/ipa
xcodebuild -project SNOF.xcodeproj -scheme SNOF -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' -derivedDataPath build \
  CURRENT_PROJECT_VERSION="$BUILD" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build -quiet 2>&1 | grep -E "error:" && exit 1 || true

APP="build/Build/Products/Release-iphoneos/SNOF.app"
[[ -d "$APP" ]] || { echo "build produced no app" >&2; exit 1; }

# What must and must not be inside anything published to a public URL.
check() { if eval "$2"; then :; else echo "release check failed: $1" >&2; exit 1; fi; }
check "Firebase config is bundled"        '[[ -f "$APP/GoogleService-Info.plist" ]]'
check "real-name fixture is not bundled"  '[[ ! -e "$APP/mock-farm-real.json" ]]'
check "no service account in the bundle"  '! find "$APP" -iname "*adminsdk*" -o -iname "serviceAccount*.json" | grep -q .'
check "no Debug snapshot hook"            '! strings "$APP/SNOF" | grep -q -- "-snapshot-delay"'
check "build number stamped"              '[[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Info.plist")" == "$BUILD" ]]'
check "sign-in URL scheme set"            '/usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:0:CFBundleURLSchemes:0" "$APP/Info.plist" | grep -q "^com.googleusercontent.apps.[0-9]"'

mkdir -p build/ipa/Payload dist
cp -R "$APP" build/ipa/Payload/
IPA="SNOF-$VERSION-$BUILD.ipa"
rm -f dist/*.ipa
(cd build/ipa && COPYFILE_DISABLE=1 zip -qry "../../dist/$IPA" Payload)
SIZE=$(stat -f%z "dist/$IPA")
SHA=$(shasum -a 256 "dist/$IPA" | cut -d' ' -f1)
cp SNOF/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png dist/icon.png

python3 - "$VERSION" "$BUILD" "$NOTES" "$SITE/$IPA" "$SIZE" "$SHA" "$BUNDLE" "$SITE" <<'PY'
import json, sys, datetime
version, build, notes, url, size, sha, bundle, site = sys.argv[1:]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
v = {"version": version, "buildVersion": build, "date": now, "localizedDescription": notes,
     "downloadURL": url, "size": int(size), "sha256": sha, "minOSVersion": "18.0"}
source = {
  "name": "SNOF", "identifier": "com.sibhiorchards.snof.source",
  "subtitle": "Sibhi Natural Orchards and Farms", "website": site,
  "iconURL": f"{site}/icon.png", "tintColor": "#7BA37F",
  "apps": [{
    "name": "SNOF", "bundleIdentifier": bundle, "developerName": "Sibhi Natural Orchards",
    "subtitle": "The farm, live", "localizedDescription":
      "Live Home Assistant state from the farm, device control for controllers, and irrigation reports. Sign in with the Google account on the farm allowlist.",
    "iconURL": f"{site}/icon.png", "tintColor": "#7BA37F", "category": "utilities",
    # SideStore needs these top-level as well as in versions.
    "version": version, "versionDate": now, "versionDescription": notes,
    "downloadURL": url, "size": int(size),
    "versions": [v], "appPermissions": {"entitlements": [], "privacy": {}},
  }],
  "news": [],
}
json.dump(source, open("dist/source.json", "w"), indent=2)
PY

# The page a phone lands on: one tap adds the source to SideStore.
cat > dist/index.html <<HTML
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark light"><title>SNOF for iPhone</title>
<style>
body{font:16px/1.5 -apple-system,system-ui,sans-serif;margin:0;background:#111;color:#e9e9e9}
main{max-width:520px;margin:0 auto;padding:40px 20px}
img{width:72px;height:72px;border-radius:16px;border:1px solid #363636}
h1{font-size:28px;margin:16px 0 4px}p{color:#9b9b9b}
a.btn{display:block;text-align:center;padding:14px;border-radius:12px;background:#e9e9e9;color:#111;
font-weight:600;text-decoration:none;margin:20px 0 10px}
a.alt{display:block;text-align:center;color:#e9e9e9;padding:10px}
code{background:#1a1a1a;border:1px solid #272727;border-radius:6px;padding:2px 6px;word-break:break-all}
</style></head><body><main>
<img src="icon.png" alt=""><h1>SNOF</h1>
<p>Version $VERSION ($BUILD). $(printf '%s' "$NOTES" | sed 's/&/\&amp;/g; s/</\&lt;/g')</p>
<a class="btn" href="sidestore://source?url=$SITE/source.json">Add to SideStore</a>
<a class="alt" href="$IPA">Download the .ipa</a>
<p>Needs SideStore on the phone first. Or add this source in SideStore by hand:<br><code>$SITE/source.json</code></p>
</main></body></html>
HTML

echo "==> dist/$IPA ($((SIZE / 1024 / 1024)) MB)"
if [[ $DEPLOY == 1 ]]; then
  firebase deploy --only hosting --project snof-live --config firebase.json -m "SNOF $VERSION ($BUILD)"
  echo "==> $SITE/source.json now offers $VERSION ($BUILD)"
fi
