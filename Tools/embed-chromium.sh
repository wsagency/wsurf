#!/bin/bash
# SPDX-FileCopyrightText: 2026 wsagency
# SPDX-License-Identifier: BUSL-1.1
set -euo pipefail

# CefSwift is vendored (Packages/CefSwift, patches in its WSURF-PATCHES.md). The CEF framework it downloads goes to its gitignored
# .cef/ folder, so a new worktree downloads it once, unless WSURF_CEF_PACKAGE names a package folder that already holds it.
package="${WSURF_CEF_PACKAGE:-$SRCROOT/Packages/CefSwift}"
if [[ ! -f "$package/CEF_VERSION.json" ]]; then
    echo "error: CefSwift package not found at $package." >&2
    exit 1
fi

version=$(/usr/bin/plutil -extract cef raw -o - "$package/CEF_VERSION.json")
framework="$package/.cef/dist/${version}_macosarm64_minimal/Release/Chromium Embedded Framework.framework"
if [[ ! -d "$framework" ]]; then
    /usr/bin/xcrun swift package --package-path "$package" \
        --allow-writing-to-package-directory --allow-network-connections all \
        cef download --platform macosarm64 --flavor minimal
fi

scratch="$DERIVED_FILE_DIR/ChromiumHelper"
/usr/bin/xcrun swift build --package-path "$package" --scratch-path "$scratch" \
    --configuration release --product cef-helper
bin=$(/usr/bin/xcrun swift build --package-path "$package" --scratch-path "$scratch" \
    --configuration release --show-bin-path)
helper="$bin/cef-helper"
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[[ -n "$identity" ]] || identity=-
signOptions=(--options runtime --timestamp)
# Match Xcode's ad-hoc builds; hardened library validation requires a real signing team.
[[ "$identity" != - ]] || signOptions=(--timestamp=none)
# Chromium's own UI strings are one Resources/<name>.lproj/locale.pak per language (55 languages plus 165 gender stubs, 47 MB).
# Only the lproj names in WSURF_CEF_LOCALES (space separated) are kept; Chromium falls back to en-US for a language without a
# pak, and WSurf's own UI is English only. `en` is that fallback and must stay. Set but empty keeps every language.
locales="${WSURF_CEF_LOCALES-en en_GB hr}"
helperHash=$(/usr/bin/shasum -a 256 "$helper")
fingerprint="$version|$identity|${helperHash%% *}|${signOptions[*]}|$PRODUCT_BUNDLE_IDENTIFIER|locales=${locales:-all}"
contents="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
frameworks="$contents/Frameworks"
resources="$contents/Resources"
stamp="$DERIVED_FILE_DIR/ChromiumBundle.fingerprint"

if [[ -f "$stamp" && "$(cat "$stamp")" == "$fingerprint" \
    && -d "$frameworks/Chromium Embedded Framework.framework" \
    && -x "$frameworks/WSurf Helper (Renderer).app/Contents/MacOS/WSurf Helper (Renderer)" ]]; then
    exit 0
fi

mkdir -p "$frameworks" "$resources"
/usr/bin/ditto "$framework" "$frameworks/Chromium Embedded Framework.framework"
# Before the first sign, so the framework's seal covers exactly what ships. ditto only adds files, so a list that changed since the
# last embed is applied from the full set again, never from the previous result.
/bin/bash "$SRCROOT/Tools/prune-chromium-locales.sh" "$frameworks/Chromium Embedded Framework.framework/Versions/A/Resources" "$locales"
cp -f "$package/LICENSE" "$resources/CefSwift.LICENSE.txt"
cp -f "$package/Sources/CCef/LICENSE.CEF.txt" "$resources/Chromium.LICENSE.txt"

sign() {
    /usr/bin/codesign --force "${signOptions[@]}" --sign "$identity" "$@"
}

# CEF ships nested native libraries; sign all of them with the app's identity.
while IFS= read -r -d '' library; do
    sign "$library"
done < <(/usr/bin/find "$frameworks/Chromium Embedded Framework.framework" -type f -name '*.dylib' -print0)
sign "$frameworks/Chromium Embedded Framework.framework"

for suffix in '' ' (Alerts)' ' (GPU)' ' (Plugin)' ' (Renderer)'; do
    name="WSurf Helper$suffix"
    bundle="$frameworks/$name.app"
    mkdir -p "$bundle/Contents/MacOS"
    cp -f "$helper" "$bundle/Contents/MacOS/$name"
    identifier="${PRODUCT_BUNDLE_IDENTIFIER}.helper"
    if [[ -n "$suffix" ]]; then
        kind="${suffix//[ ()]/}"
        identifier="$identifier.$kind"
    fi
    cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$name</string>
<key>CFBundleIdentifier</key><string>$identifier</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
<key>CFBundleVersion</key><string>${CURRENT_PROJECT_VERSION}</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>LSFileQuarantineEnabled</key><true/>
<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
<key>NSCameraUsageDescription</key><string>Only websites you allow can use your camera.</string>
<key>NSMicrophoneUsageDescription</key><string>Only websites you allow can use your microphone.</string>
</dict></plist>
PLIST
    printf APPL???? > "$bundle/Contents/PkgInfo"
    sign --entitlements "$SRCROOT/Tools/chromium-helper.entitlements" "$bundle"
done
printf '%s' "$fingerprint" > "$stamp"
