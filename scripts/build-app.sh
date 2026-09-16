#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  swift build -c "$configuration" --arch arm64 --arch x86_64
  binary_dir="$(swift build -c "$configuration" --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c "$configuration"
  binary_dir="$(swift build -c "$configuration" --show-bin-path)"
fi
mkdir -p "$PWD/dist"
final_app="$PWD/dist/SSMV.app"
previous_build=0
if [[ -f "$final_app/Contents/Info.plist" ]]; then
  previous_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$final_app/Contents/Info.plist")"
fi
[[ "$previous_build" =~ ^[0-9]+$ ]] || previous_build=0
bundle_build="${BUILD_NUMBER:-$((previous_build + 1))}"
[[ "$bundle_build" =~ ^[0-9]+$ ]] || { echo 'BUILD_NUMBER must be an integer' >&2; exit 1; }
# Assemble and sign a fresh bundle before replacing the old, verified app.
staging_dir="$(mktemp -d "$PWD/dist/.ssmv-build.XXXXXX")"
cleanup() {
  if [[ -d "$staging_dir/previous.app" && ! -e "$final_app" ]]; then
    mv "$staging_dir/previous.app" "$final_app"
  fi
  rm -rf "$staging_dir"
}
trap cleanup EXIT
app_path="$staging_dir/SSMV.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/SSMV" "$app_path/Contents/MacOS/SSMV"
cp "$binary_dir/SSMVCLI" "$app_path/Contents/MacOS/SSMVCLI"
if [[ "$configuration" == release ]]; then
  strip -S "$app_path/Contents/MacOS/SSMV" "$app_path/Contents/MacOS/SSMVCLI"
fi
icon_hash="$(shasum -a 256 Resources/AppIcon.icns | cut -c 1-12)"
icon_name="AppIcon-$icon_hash"
cp Resources/AppIcon.icns "$app_path/Contents/Resources/$icon_name.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$app_path/Contents/Resources/"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $icon_name" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $bundle_build" "$app_path/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$app_path/Contents/Info.plist"
fi
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$app_path/Contents/MacOS/SSMVCLI"
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$app_path"
else
  codesign --force --sign - "$app_path/Contents/MacOS/SSMVCLI"
  codesign --force --sign - "$app_path"
fi
codesign --verify --strict "$app_path"
if [[ -e "$final_app" ]]; then
  mv "$final_app" "$staging_dir/previous.app"
fi
mv "$app_path" "$final_app"
echo "Built $final_app (build $bundle_build, icon $icon_hash)"
