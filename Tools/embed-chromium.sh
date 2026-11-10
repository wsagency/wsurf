#!/bin/bash
# SPDX-FileCopyrightText: 2026 wsagency
# SPDX-License-Identifier: BUSL-1.1
set -euo pipefail

# CefSwift is vendored (Packages/CefSwift, patches in its WSURF-PATCHES.md). The CEF framework it downloads goes to its gitignored
# .cef/ folder, so a new worktree downloads it once, unless WSURF_CEF_PACKAGE names a package folder that already holds it.
package="${WSURF_CEF_PACKAGE:-$SRCROOT/Packages/CefSwift}"
# D4 (the out-of-process Chromium service): with the build setting WSURF_CHROMIUM_OOP_BUILD=YES the script also builds and
# assembles Contents/XPCServices/WSurf Chromium.xpc, and the CEF framework and the five helpers live only inside it (Chromium's
# helper sandbox reads only inside its browser process's main bundle). Unset, or any other value, the script does exactly what
# it did before the service existed: same commands, same bundle, same fingerprint.
oop=
[[ "${WSURF_CHROMIUM_OOP_BUILD:-}" != YES ]] || oop=YES
if [[ -n "$oop" ]]; then
    # The service is ad hoc and has no entitlements, so it is for DEBUG, test and staged builds only. Developer ID signing,
    # the hardened runtime and the entitlements are the owner's signing change (D4-S).
    if [[ "${CONFIGURATION:-}" == Release || "${EXPANDED_CODE_SIGN_IDENTITY:--}" != - ]]; then
        echo "error: WSURF_CHROMIUM_OOP_BUILD=YES needs the owner's signing PR (D4-S): it builds only ad hoc, never Release or with a signing identity." >&2
        exit 1
    fi
fi
if [[ ! -f "$package/CEF_VERSION.json" ]]; then
    echo "error: CefSwift package not found at $package." >&2
    exit 1
fi

version=$(/usr/bin/plutil -extract cef raw -o - "$package/CEF_VERSION.json")
framework="$package/.cef/dist/${version}_macosarm64_minimal/Release/Chromium Embedded Framework.framework"
if [[ ! -d "$framework" ]]; then
    # Three tries: a hosted runner's DNS lookup can fail (curl exit 6, CI run 41750081081), which curl's own --retry does not
    # retry. The download resumes a partial file and is checked against its SHA-1, so a retry costs time, never correctness.
    for attempt in 1 2 3; do
        /usr/bin/xcrun swift package --package-path "$package" \
            --allow-writing-to-package-directory --allow-network-connections all \
            cef download --platform macosarm64 --flavor minimal && break
        [[ "$attempt" -lt 3 ]] || exit 1
        echo "warning: CEF download attempt $attempt failed; retrying in 15s." >&2
        sleep 15
    done
fi

scratch="$DERIVED_FILE_DIR/ChromiumHelper"
/usr/bin/xcrun swift build --package-path "$package" --scratch-path "$scratch" \
    --configuration release --product cef-helper
bin=$(/usr/bin/xcrun swift build --package-path "$package" --scratch-path "$scratch" \
    --configuration release --show-bin-path)
helper="$bin/cef-helper"
service=
if [[ -n "$oop" ]]; then
    /usr/bin/xcrun swift build --package-path "$package" --scratch-path "$scratch" \
        --configuration release --product wsurf-chromium-service
    service="$bin/wsurf-chromium-service"
fi
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
servicePlist=
if [[ -n "$oop" ]]; then
    # Ad hoc, no entitlements, no hardened runtime and no privacy keys (those are the owner's, D4-S). The id carries the test or
    # stage suffix of the app. The text is part of the fingerprint, so a change to it is applied by the next build.
    servicePlist=$(cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WSurf Chromium</string>
<key>CFBundleIdentifier</key><string>${PRODUCT_BUNDLE_IDENTIFIER}.chromium</string>
<key>CFBundleName</key><string>WSurf Chromium</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
<key>CFBundleVersion</key><string>${CURRENT_PROJECT_VERSION}</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>XPCService</key><dict>
<key>ServiceType</key><string>Application</string>
<key>JoinExistingSession</key><true/>
<key>RunLoopType</key><string>NSRunLoop</string>
</dict>
</dict></plist>
PLIST
    )
    plistHash=$(printf '%s' "$servicePlist" | /usr/bin/shasum -a 256)
    fingerprint="$fingerprint|oop|${plistHash%% *}"
fi
contents="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
resources="$contents/Resources"
# Where the framework and the helpers go: the app's Frameworks, or with the service the service's, and only there.
frameworks="$contents/Frameworks"
xpc="$contents/XPCServices/WSurf Chromium.xpc"
[[ -z "$oop" ]] || frameworks="$xpc/Contents/Frameworks"
stamp="$DERIVED_FILE_DIR/ChromiumBundle.fingerprint"
# The service executable's hash as built: codesign rewrites the copy in the bundle, so the bundle cannot be compared to it.
serviceStamp="$DERIVED_FILE_DIR/ChromiumService.sha256"
serviceHash=
[[ -z "$oop" ]] || { serviceHash=$(/usr/bin/shasum -a 256 "$service"); serviceHash=${serviceHash%% *}; }

sign() {
    /usr/bin/codesign --force "${signOptions[@]}" --sign "$identity" "$@"
}

if [[ -f "$stamp" && "$(cat "$stamp")" == "$fingerprint" \
    && -d "$frameworks/Chromium Embedded Framework.framework" \
    && -x "$frameworks/WSurf Helper (Renderer).app/Contents/MacOS/WSurf Helper (Renderer)" ]]; then
    # A change to the service's code alone is not in the fingerprint, which names what the rest of the bundle was made from: it
    # replaces the service's executable and seals the .xpc again, and the framework and the helpers keep their signatures.
    if [[ -n "$oop" && "$(cat "$serviceStamp" 2>/dev/null)" != "$serviceHash" ]]; then
        cp -f "$service" "$xpc/Contents/MacOS/WSurf Chromium"
        sign "$xpc"
        printf '%s' "$serviceHash" > "$serviceStamp"
    fi
    exit 0
fi

if [[ -n "$oop" && ( -e "$contents/Frameworks/Chromium Embedded Framework.framework" || -e "$contents/Frameworks/WSurf Helper.app" ) ]]; then
    echo "error: $contents/Frameworks already holds a CEF framework or helpers from a build without the service; the one-copy layout needs its own DerivedData (build/DD-oop, see Tools/run-chromium-oop-tests.sh)." >&2
    exit 1
fi

mkdir -p "$frameworks" "$resources"
/usr/bin/ditto "$framework" "$frameworks/Chromium Embedded Framework.framework"
# Before the first sign, so the framework's seal covers exactly what ships. ditto only adds files, so a list that changed since the
# last embed is applied from the full set again, never from the previous result.
/bin/bash "$SRCROOT/Tools/prune-chromium-locales.sh" "$frameworks/Chromium Embedded Framework.framework/Versions/A/Resources" "$locales"
cp -f "$package/LICENSE" "$resources/CefSwift.LICENSE.txt"
cp -f "$package/Sources/CCef/LICENSE.CEF.txt" "$resources/Chromium.LICENSE.txt"

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

if [[ -n "$oop" ]]; then
    # WSurf Chromium.xpc runs CEF's browser process, windowless, out of WSurf's process. Signed last, over its own framework and
    # helpers, which are signed above.
    mkdir -p "$xpc/Contents/MacOS"
    cp -f "$service" "$xpc/Contents/MacOS/WSurf Chromium"
    printf '%s\n' "$servicePlist" > "$xpc/Contents/Info.plist"
    sign "$xpc"
    printf '%s' "$serviceHash" > "$serviceStamp"
fi
printf '%s' "$fingerprint" > "$stamp"
