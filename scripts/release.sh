#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VERSION:?Set VERSION, for example 0.1.0}"
if [[ "${ALLOW_UNNOTARIZED:-0}" == 1 ]]; then
  unset SIGNING_IDENTITY
else
  : "${SIGNING_IDENTITY:?Set a Developer ID Application signing identity}"
  : "${NOTARY_PROFILE:?Set a notarytool keychain profile}"
fi
: "${GITHUB_REPOSITORY:?Set owner/repository for the download URL}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'VERSION must be x.y.z' >&2; exit 1; }
[[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || exit 1
UNIVERSAL=1 scripts/build-app.sh
archive="dist/SSMV-$VERSION.zip"
ditto -c -k --norsrc --keepParent dist/SSMV.app "$archive"
if [[ "${ALLOW_UNNOTARIZED:-0}" != 1 ]]; then
xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple dist/SSMV.app
xcrun stapler validate dist/SSMV.app
spctl --assess --type execute --verbose dist/SSMV.app
fi
# Stapling changes the bundle: repackage before computing the distribution checksum.
ditto -c -k --norsrc --keepParent dist/SSMV.app "$archive"
checksum="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
mkdir -p dist/Casks
cat > dist/Casks/ssmv.rb <<CASK
# frozen_string_literal: true

cask "ssmv" do
  version "$VERSION"
  sha256 "$checksum"

  url "https://github.com/$GITHUB_REPOSITORY/releases/download/v#{version}/SSMV-#{version}.zip"
  name "SSMV"
  name "So Simple Markdown Viewer"
  desc "Native Markdown viewer with PDF export"
  homepage "https://github.com/$GITHUB_REPOSITORY"

  depends_on macos: :ventura

  app "SSMV.app"

  postflight_steps do
CASK
if [[ "${ALLOW_UNNOTARIZED:-0}" == 1 ]]; then
  cat >> dist/Casks/ssmv.rb <<'CASK'
    # Verify the ad-hoc bundle before allowing it to open.
    run "/usr/bin/codesign", args: ["--verify", "--strict", "{{appdir}}/SSMV.app"]
    run "/usr/bin/xattr", args: ["-d", "-r", "com.apple.quarantine", "{{appdir}}/SSMV.app"]
CASK
fi
cat >> dist/Casks/ssmv.rb <<'CASK'
    # Register document claims on fresh installs, not only after the app is opened.
    run "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
        args: ["-f", "{{appdir}}/SSMV.app"]
  end

  uninstall quit: "io.github.irae.ssmv"

  zap trash: "~/Library/Preferences/io.github.irae.ssmv.plist"
CASK
if [[ "${ALLOW_UNNOTARIZED:-0}" == 1 ]]; then
  cat >> dist/Casks/ssmv.rb <<'CASK'

  caveats <<~EOS
    SSMV is ad-hoc signed and not Apple notarized. After checksum and bundle
    signature checks, this cask removes quarantine from SSMV.app only so it
    can launch. This bypasses Gatekeeper's first-launch check for this app;
    it does not provide Apple notarization or change global security settings.
  EOS
CASK
fi
echo 'end' >> dist/Casks/ssmv.rb
if [[ "${ALLOW_UNNOTARIZED:-0}" == 1 ]]; then
  echo 'Release is ad-hoc signed and NOT notarized. Disclose this in release notes.' >&2
fi
printf '%s  %s\n' "$checksum" "$(basename "$archive")" > "$archive.sha256"
echo "Ready: $archive and dist/Casks/ssmv.rb"
